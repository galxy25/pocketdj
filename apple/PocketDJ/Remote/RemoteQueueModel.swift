import Foundation

/// The HOST's authoritative session state — a pure value. Every command from every participant
/// (and every change the host's own user makes in the ordinary Now Playing UI, translated into
/// commands) is applied HERE; speakers then reconcile their local player against the resulting
/// state. Keeping it a plain struct (no player, no transport) is what makes "everyone converges
/// on the same revision" unit-testable.
struct RemoteQueueModel: Equatable {
    var rows: [RemoteRow] = []
    var index = 0
    var isPlaying = false
    /// Song-relative position at `anchor` (a shared-clock ms instant).
    var positionMs = 0
    var anchor: Double = 0
    var repeatMode: RepeatMode = .off
    var shuffleEnabled = false
    /// The pre-shuffle upcoming order (rids) — restored when shuffle turns off.
    var canonicalUpcoming: [String]?
    /// Bumped on every applied change.
    var revision = 0
    /// Origin name shown on the remote surface ("Golden Hour Rooftop").
    var sourceName: String?

    /// Rows before / after the current one carried in a state broadcast (the window).
    static let windowBehind = 20
    static let windowAhead = 200

    var currentRow: RemoteRow? { rows.indices.contains(index) ? rows[index] : nil }
    var upcoming: ArraySlice<RemoteRow> { index + 1 < rows.count ? rows[(index + 1)...] : [] }

    func position(at now: Double) -> Int {
        guard isPlaying else { return positionMs }
        return max(0, positionMs + Int((now - anchor).rounded()))
    }

    /// Re-anchor the running position at `now` (before any change to play state / track).
    private mutating func freeze(at now: Double) {
        positionMs = position(at: now)
        anchor = now
    }

    private mutating func startTrack(at i: Int, now: Double) {
        index = i
        positionMs = 0
        anchor = now
    }

    /// Apply one command. Returns true (and bumps `revision`) when anything changed. `shuffler`
    /// is injectable so tests pin the permutation.
    @discardableResult
    mutating func apply(_ command: RemoteCommand, now: Double,
                        shuffler: ([RemoteRow]) -> [RemoteRow] = { $0.shuffled() }) -> Bool {
        let before = self
        switch command {
        case .play(let newRows, let startIndex):
            guard !newRows.isEmpty else { return false }
            rows = newRows
            canonicalUpcoming = nil
            shuffleEnabled = false
            startTrack(at: max(0, min(startIndex, newRows.count - 1)), now: now)
            isPlaying = true
        case .playNow(let newRows):
            guard !newRows.isEmpty else { return false }
            if rows.isEmpty {
                rows = newRows
                startTrack(at: 0, now: now)
            } else {
                rows.insert(contentsOf: newRows, at: index + 1)
                startTrack(at: index + 1, now: now)
            }
            isPlaying = true
        case .playPause:
            guard currentRow != nil else { return false }
            freeze(at: now)
            isPlaying.toggle()
        case .setPlaying(let on):
            guard currentRow != nil, on != isPlaying else { return false }
            freeze(at: now)
            isPlaying = on
        case .seek(let ms):
            guard currentRow != nil else { return false }
            positionMs = max(0, ms)
            anchor = now
        case .skipNext:
            advance(now: now)
        case .advanced(let fromRid):
            guard currentRow?.rid == fromRid else { return false }
            if repeatMode == .one { positionMs = 0; anchor = now } else { advance(now: now) }
        case .skipPrevious:
            guard currentRow != nil else { return false }
            if position(at: now) > 3_000 || (index == 0 && repeatMode != .all) {
                positionMs = 0; anchor = now   // ⏮ restarts the track first (the lock-screen rule)
            } else {
                startTrack(at: index == 0 ? rows.count - 1 : index - 1, now: now)
            }
        case .jumpTo(let rid):
            guard let i = rows.firstIndex(where: { $0.rid == rid }), i != index else { return false }
            startTrack(at: i, now: now)
            isPlaying = true
        case .enqueueNext(let newRows):
            guard !newRows.isEmpty else { return false }
            if rows.isEmpty { return apply(.play(rows: newRows, startIndex: 0), now: now) }
            rows.insert(contentsOf: newRows, at: index + 1)
            canonicalUpcoming?.insert(contentsOf: newRows.map(\.rid), at: 0)
        case .append(let newRows):
            guard !newRows.isEmpty else { return false }
            if rows.isEmpty { return apply(.play(rows: newRows, startIndex: 0), now: now) }
            rows.append(contentsOf: newRows)
            canonicalUpcoming?.append(contentsOf: newRows.map(\.rid))
        case .remove(let rid):
            // Only an UPCOMING row (the Now Playing rule — the current row is skipped, not removed).
            guard let i = rows.firstIndex(where: { $0.rid == rid }), i > index else { return false }
            rows.remove(at: i)
            canonicalUpcoming?.removeAll { $0 == rid }
        case .move(let rid, let offset):
            guard let i = rows.firstIndex(where: { $0.rid == rid }), i > index else { return false }
            let row = rows.remove(at: i)
            let dest = index + 1 + max(0, min(offset, rows.count - index - 1))
            rows.insert(row, at: dest)
        case .reorder(let rids):
            let wanted = rids.filter { rid in upcoming.contains { $0.rid == rid } }
            let wantedSet = Set(wanted)
            let slots = rows.indices.filter { $0 > index && wantedSet.contains(rows[$0].rid) }
            guard slots.count == wanted.count else { return false }
            let byRid = Dictionary(rows.map { ($0.rid, $0) }, uniquingKeysWith: { a, _ in a })
            for (slot, rid) in zip(slots, wanted) { if let r = byRid[rid] { rows[slot] = r } }
        case .setRepeat(let mode):
            repeatMode = mode
        case .setShuffle(let on):
            guard on != shuffleEnabled else { return false }
            shuffleEnabled = on
            let head = rows.isEmpty ? [] : Array(rows[...index])
            let tail = Array(upcoming)
            if on {
                canonicalUpcoming = tail.map(\.rid)
                rows = head + shuffler(tail)
            } else if let order = canonicalUpcoming {
                let byRid = Dictionary(tail.map { ($0.rid, $0) }, uniquingKeysWith: { a, _ in a })
                var restored = order.compactMap { byRid[$0] }
                let known = Set(order)
                restored += tail.filter { !known.contains($0.rid) }   // added while shuffled
                rows = head + restored
                canonicalUpcoming = nil
            }
        }
        guard self != before else { return false }
        revision = before.revision + 1
        return true
    }

    /// ⏭ / natural end: the next row, wrapping under repeat-all; past the last row the set
    /// stops on its last track (paused at 0), the sequencer's end-of-set behaviour.
    private mutating func advance(now: Double) {
        guard currentRow != nil else { return }
        if index + 1 < rows.count {
            startTrack(at: index + 1, now: now)
        } else if repeatMode == .all, !rows.isEmpty {
            startTrack(at: 0, now: now)
        } else {
            positionMs = 0
            anchor = now
            isPlaying = false
        }
    }

    // MARK: Broadcast

    /// The windowed wire state for revision `revision` (`behind` / `ahead` shrink the window
    /// when the encoded state would exceed the messenger's size budget).
    func state(hostId: String, mode: RemoteSessionMode, sessionId: String, now: Double,
               behind: Int = Self.windowBehind, ahead: Int = Self.windowAhead,
               sessionActive: Bool? = nil) -> RemotePlaybackState {
        let lo = max(0, index - behind)
        let hi = min(rows.count, index + 1 + ahead)
        let window = lo < hi ? Array(rows[lo..<hi]) : []
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: sessionId,
            source: .init(kind: "remote", id: nil, name: sourceName),
            queue: window.map(\.row),
            index: index - lo,
            positionMs: position(at: now),
            isPlaying: isPlaying,
            repeatMode: repeatMode.rawValue,
            shuffleEnabled: shuffleEnabled,
            updatedAt: now)
        return RemotePlaybackState(revision: revision, hostId: hostId, mode: mode, snapshot: snap,
                                   rowIds: window.map(\.rid), windowStart: lo, totalCount: rows.count,
                                   anchorSharedTime: now, sessionActive: sessionActive)
    }

    /// Adopt a received state as the starting model (a hand-over: the new host only knows the
    /// window). `now` is on the NEW host's clock; `positionNow` the position estimated for it.
    init(adopting s: RemotePlaybackState, positionNow: Int, now: Double) {
        rows = s.rows
        index = max(0, min(s.snapshot.index, max(0, rows.count - 1)))
        isPlaying = s.isPlaying
        positionMs = positionNow
        anchor = now
        repeatMode = s.repeatMode
        shuffleEnabled = s.shuffleEnabled
        revision = s.revision
        sourceName = s.snapshot.source.name
    }

    init() {}
}
