import Foundation
import Observation
import os

/// THE ONE DECISION MODEL behind accept / reject — a durable, append-only log of every 👍 / 👎 the
/// listener has given a recommendation, wherever they gave it.
///
/// ── WHY ONE STORE AND NOT TWO PATHS ──────────────────────────────────────────────────────────
/// The owner asked for BOTH modes: act on what is playing (now-playing deck, mini bar, CarPlay,
/// widgets, lock screen) and come back to the tile later and work the list. Those are two ENTRY
/// POINTS, not two features. If each grew its own state, a thumbs-down given in the car would not
/// be reflected when the tile was next opened, and that divergence is the obvious defect in a
/// feature shaped like this one. So: every surface writes HERE, every surface reads HERE, and the
/// tile reconciles by reading `verdict(songId:scope:)` at render time — there is nothing to
/// synchronize because there is only one copy. This type is `@Observable`, so a decision recorded
/// from ANY surface bumps `revision` and the open list re-renders without refetching.
///
/// ── A REJECT IS TWO DIFFERENT THINGS, AND KEEPING THEM APART IS THE DESIGN ───────────────────
///   1. **SUPPRESSION** — the owner's rule, verbatim: "when you reject it should go to the bottom
///      as a tombstone for 7 days, of all rejects for this collection or tile." So a rejection is
///      neither a deletion nor a permanent exclusion. It is SCOPED to the list it was given in (a
///      tile IS a collection), it EXPIRES after seven days, and while it lasts the row sinks to the
///      bottom of that list — still on screen, still playable, never vanished.
///   2. **TASTE** — "fed into the recommendation engine as user feedback". That half is global and
///      does not expire; it decays on the same half-life every other recency signal in this app
///      uses, and it only ever SUBTRACTS score (`ZoneEngine.Tuning.rejectionWeight`). It can never
///      remove a song from anywhere.
///
/// The two are deliberately not the same mechanism. Suppression that was global and permanent
/// would let one mis-tap in a moving car ban a song from every surface forever; taste that expired
/// in seven days would mean the engine never actually learns anything.
///
/// ── WHY THE VERDICT OUTLIVES THE TOMBSTONE ───────────────────────────────────────────────────
/// The seven days govern the SINK, not the opinion. After they lapse the song ranks normally again
/// but its 👎 stays lit, because the listener did say it and the lit control is the undo. That is
/// what makes a mis-tap recoverable indefinitely instead of only while it is still doing damage:
/// tap the lit thumb and the row is neutral again (a `cleared` row, not a deletion — see `toggle`).
///
/// ── WHY EXPIRY IS EVALUATED AT READ TIME ─────────────────────────────────────────────────────
/// Never by a scheduled sweep. This app can go weeks between launches, and a sweep that never
/// fires leaves every rejected item buried forever — a silent, permanent exclusion, which is
/// precisely what the 7-day rule exists to prevent. `activeTombstones` therefore derives from the
/// stored stamp on every read, so an app closed for a month expires correctly on the first render
/// after it reopens.
///
/// Persistence follows `PuzzleDecisionStore` exactly — durable JSON, coalesced + generation-guarded
/// saves on a serial writer, atomic writes, the `PDJ_USE_FIXTURE` seam, union-by-id merge after a
/// CloudSync pull. It is deliberately the same skeleton rather than a second invention.
@MainActor
@Observable
final class RecFeedbackStore {

    /// What the listener said. A STRING on the wire (the never-rename-a-shipped-rawValue doctrine).
    enum Verdict: String, Codable, Equatable, Sendable {
        /// 👍 — "more like this". Feeds the taste profile as extra positive evidence.
        case accepted
        /// 👎 — "not this". Sinks the song in THIS list for seven days AND teaches its shape.
        case rejected
        /// The undo: tapping a lit control again. A ROW, not a deletion, so a peer's older opinion
        /// cannot resurrect it through the union merge.
        case cleared
    }

    /// Where the verdict was given. Recorded because "rejected while it was playing" and "rejected
    /// while scrolling a list" are different strengths of signal and the server may eventually
    /// weight them apart — but nothing branches on it today, so a new surface only has to add a
    /// case, never a code path.
    enum Surface: String, Codable, Equatable, Sendable {
        case tile           // a For You list row (ASYNC mode)
        case nowPlaying     // the in-app deck / mini bar (SYNC mode)
        case carPlay
        case widget
        case songDetail
    }

    struct Decision: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var at: Double                 // epoch ms
        var songId: String
        /// WHICH LIST this verdict was given in — a collection id, or one of the reserved tile
        /// names (`ForYouTileKind.rawValue`: "zone" / "new" / "suggested"). Deliberately the
        /// collection ID and never its title: a rename must not orphan the feedback recorded
        /// against the list.
        var scope: String
        var verdict: String            // Verdict rawValue
        var surface: String            // Surface rawValue
        /// The song's shape, denormalized at record time. A rejection has to keep working as
        /// negative evidence even when the catalog row is gone (a source toggled off, an Apple
        /// Music id that no longer resolves) — without these the log would silently stop teaching
        /// anything the moment a source was disabled.
        var artistKey: String?
        var genre: String?
        var originInstallId: String?
        /// PER-DEVICE monotonic sequence. The tie-break when two rows share a millisecond.
        ///
        /// It exists because a UUID tie-break — the obvious move — resolves a double-tap by a
        /// random number instead of by TAP ORDER, and the double-tap IS the undo path: reject then
        /// immediately un-reject, both stamped in the same millisecond, and the surviving row is a
        /// coin flip. Sequence makes same-device order exact, and `(at, seq, originInstallId, id)`
        /// keeps a cross-device merge deterministic without pretending two devices share a clock.
        var seq: Int

        init(id: UUID = UUID(), at: Double, songId: String, scope: String, verdict: Verdict,
             surface: Surface, artistKey: String? = nil, genre: String? = nil,
             originInstallId: String? = nil, seq: Int = 0) {
            self.id = id; self.at = at; self.songId = songId; self.scope = scope
            self.verdict = verdict.rawValue; self.surface = surface.rawValue
            self.artistKey = artistKey; self.genre = genre
            self.originInstallId = originInstallId; self.seq = seq
        }

        enum CodingKeys: String, CodingKey {
            case id, at, songId, scope, verdict, surface, artistKey, genre, originInstallId, seq
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            at = try c.decode(Double.self, forKey: .at)
            songId = try c.decode(String.self, forKey: .songId)
            scope = try c.decode(String.self, forKey: .scope)
            verdict = try c.decode(String.self, forKey: .verdict)
            surface = (try? c.decode(String.self, forKey: .surface)) ?? Surface.tile.rawValue
            artistKey = try? c.decode(String.self, forKey: .artistKey)
            genre = try? c.decode(String.self, forKey: .genre)
            originInstallId = try? c.decode(String.self, forKey: .originInstallId)
            // ADDITIVE-OPTIONAL: rows written before `seq` existed decode to 0, which keeps their
            // relative order stable (they all tie and fall through to the id tiebreak, exactly as
            // they did when they were written).
            seq = (try? c.decode(Int.self, forKey: .seq)) ?? 0
        }

        var verdictValue: Verdict? { Verdict(rawValue: verdict) }
    }

    /// What the running queue is a recommendation FOR — the SYNC half's missing half.
    ///
    /// A now-playing surface (deck, mini bar, lock screen, CarPlay, widget) has one track and no
    /// list, so it has to be TOLD which tile that track is a recommendation in. A For You list
    /// stamps this when it hands a queue to the player; a playlist, an album or Browse leaves it
    /// alone and the two controls then hide rather than filing a decision against a tile the
    /// listener never opened.
    ///
    /// PERSISTED, not just held in memory. A widget or lock-screen tap can arrive after a cold
    /// launch — the app was killed, the intent ran in the extension, the command drained on the
    /// next wake — and an in-memory scope is nil by then, so the verdict would be silently dropped
    /// exactly when the listener could least tell.
    struct PlayingScope: Codable, Equatable, Sendable {
        var scope: String
        var songIds: [String]
        var atMs: Double
    }

    struct Document: Codable {
        var schemaVersion: Int = recFeedbackSchemaVersion
        var installId: String
        var decisions: [Decision] = []
        var playing: PlayingScope?
        var seq: Int = 0

        init(schemaVersion: Int = recFeedbackSchemaVersion, installId: String,
             decisions: [Decision] = [], playing: PlayingScope? = nil, seq: Int = 0) {
            self.schemaVersion = schemaVersion; self.installId = installId
            self.decisions = decisions; self.playing = playing; self.seq = seq
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, decisions, playing, seq }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? recFeedbackSchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            decisions = ((try? c.decode([LenientDecision].self, forKey: .decisions)) ?? [])
                .compactMap(\.decision)
                .filter { !$0.songId.isEmpty && !$0.scope.isEmpty }
            playing = try? c.decode(PlayingScope.self, forKey: .playing)
            seq = (try? c.decode(Int.self, forKey: .seq)) ?? 0
        }
    }

    /// One corrupt row must never cost the whole log — the same lenient-decode rule
    /// `PuzzleDecisionStore` uses.
    private struct LenientDecision: Decodable {
        let decision: Decision?
        init(from decoder: Decoder) throws { decision = try? Decision(from: decoder) }
    }

    private(set) var decisions: [Decision] = []
    private(set) var installId: String
    /// Bumped on every change — the ONE thing a view observes to pick up a decision made while it
    /// was closed (from the car, the lock screen, a widget, a peer device's CloudKit pull).
    private(set) var revision = 0

    // MARK: - Tuning

    /// The owner's number. Seven days, evaluated from the stored stamp at read time.
    nonisolated static let tombstoneDays: Double = 7
    nonisolated static let tombstoneMs: Double = tombstoneDays * 86_400_000
    /// Hard row cap (oldest shed first), well above what a human can generate.
    nonisolated static let maxDecisions = 20_000
    nonisolated static let saveDebounce: Duration = .milliseconds(600)

    // MARK: - Storage plumbing (the PuzzleDecisionStore skeleton)

    @ObservationIgnored private let fileURL: URL
    var syncFileURL: URL { fileURL }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave = false
    @ObservationIgnored private let writeQueue =
        DispatchQueue(label: "com.levi.pocketdj.rec-feedback", qos: .utility)
    /// Monotonic write generation, checked INSIDE every queued block: a block already handed to the
    /// serial queue outlives task cancellation, so a stale snapshot must skip its own write rather
    /// than clobber a newer document. Identical rule to `PuzzleDecisionStore`.
    @ObservationIgnored private let writeGeneration = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var nextSeq = 0
    var hasUnsavedChanges: Bool { pendingSave }

    init(fileURL: URL = RecFeedbackStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            decisions = doc.decisions
            installId = doc.installId
            playing = doc.playing
            nextSeq = max(doc.seq, (doc.decisions.map(\.seq).max() ?? 0) + 1)
        } else {
            installId = UUID().uuidString
        }
        rebuildIndex()
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil,
                                                create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-rec-feedback.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-rec-feedback.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // ========================================================================
    // MARK: - Derived state (memoized on `revision`)
    // ========================================================================

    /// Everything the views and the ranking read, derived once per change rather than re-scanned
    /// per row.
    ///
    /// The shape matters: a `decisions.last(where:)` lookup inside a SwiftUI row body is a linear
    /// scan over up to `maxDecisions` rows, evaluated once per row per body pass — ~90 rows on a
    /// zone tile. That is the "derivations in SwiftUI bodies" pattern this app has already had to
    /// fix once, so the derivation lives here and every read is a dictionary hit.
    struct DerivedState: Sendable {
        /// "scope\u{1}songId" → the verdict standing there. `.cleared` resolves to ABSENT, so an
        /// undo really does put the row back to neutral.
        var byScope: [String: Verdict] = [:]
        /// Same key → when that verdict was recorded (the tombstone clock).
        var atByScope: [String: Double] = [:]
        /// songId → latest REJECTED stamp anywhere (the global taste signal — no expiry, decays).
        var rejectedAt: [String: Double] = [:]
        /// songId → latest ACCEPTED stamp anywhere.
        var acceptedAt: [String: Double] = [:]
        /// scope → the songs tombstoned in it, with the stamp (expiry applied at read time).
        var rejectedByScope: [String: [String: Double]] = [:]
    }

    @ObservationIgnored private var derived = DerivedState()

    private static func key(_ scope: String, _ songId: String) -> String { "\(scope)\u{1}\(songId)" }

    /// Latest-wins per `(scope, songId)`; ties broken by `(at, seq, originInstallId, id)` so a
    /// double-tap on ONE device always resolves by tap order and a cross-device merge is still
    /// deterministic.
    private func rebuildIndex() {
        func newer(_ a: Decision, than b: Decision) -> Bool {
            if a.at != b.at { return a.at > b.at }
            if a.seq != b.seq { return a.seq > b.seq }
            let ao = a.originInstallId ?? "", bo = b.originInstallId ?? ""
            if ao != bo { return ao > bo }
            return a.id.uuidString > b.id.uuidString
        }
        var bestScoped: [String: Decision] = [:]
        var bestGlobal: [String: Decision] = [:]
        for d in decisions {
            let k = Self.key(d.scope, d.songId)
            if let cur = bestScoped[k], !newer(d, than: cur) {} else { bestScoped[k] = d }
            if let cur = bestGlobal[d.songId], !newer(d, than: cur) {} else { bestGlobal[d.songId] = d }
        }
        var s = DerivedState()
        for (k, d) in bestScoped {
            guard let v = d.verdictValue, v != .cleared else { continue }
            s.byScope[k] = v
            s.atByScope[k] = d.at
            if v == .rejected { s.rejectedByScope[d.scope, default: [:]][d.songId] = d.at }
        }
        // The GLOBAL taste opinion is the latest verdict for the song in ANY scope. Rejecting a
        // song in one crate and accepting it in another is a real thing a listener can do; the
        // later of the two is what they currently think, and that is what teaches the ranking.
        for (songId, d) in bestGlobal {
            switch d.verdictValue {
            case .rejected: s.rejectedAt[songId] = d.at
            case .accepted: s.acceptedAt[songId] = d.at
            default: break
            }
        }
        derived = s
    }

    // ========================================================================
    // MARK: - Read
    // ========================================================================

    /// The verdict standing for `(songId, scope)`. NOT expiry-gated: the seven days govern the
    /// SINK, not the opinion — see the type doc. That is what keeps the undo control lit and
    /// reachable long after the row has stopped being penalised.
    func verdict(songId: String, scope: String) -> Verdict? {
        derived.byScope[Self.key(scope, songId)]
    }

    /// The verdict this song carries ANYWHERE, for surfaces that have no list context of their own
    /// (Song Detail). Prefer the scoped reader wherever a scope exists.
    func anyVerdict(songId: String) -> Verdict? {
        if derived.rejectedAt[songId] != nil { return .rejected }
        if derived.acceptedAt[songId] != nil { return .accepted }
        return nil
    }

    /// songId → reject stamp, for the tombstones in `scope` still inside their seven days.
    func activeTombstones(scope: String,
                          nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [String: Double] {
        guard let rows = derived.rejectedByScope[scope] else { return [:] }
        // A FUTURE stamp (clock skew, a peer a few hours ahead) is kept rather than dropped: the
        // listener really did reject it, and the window simply reads as full length.
        return rows.filter { nowMs - $0.value < Self.tombstoneMs }
    }

    func isSuppressed(songId: String, scope: String,
                      nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        guard let at = derived.rejectedByScope[scope]?[songId] else { return false }
        return nowMs - at < Self.tombstoneMs
    }

    /// songId → age-decayed strength of the CURRENT global verdict — the ranking's positive and
    /// negative evidence. A judgement from two years ago should not weigh the same as one from this
    /// morning, so it runs on the same half-life every other recency use in this app does
    /// (`PlayRecency`). Floored rather than zeroed: an old, consistent pattern still counts.
    func weights(_ verdict: Verdict,
                 nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [String: Double] {
        let source = verdict == .rejected ? derived.rejectedAt
                   : verdict == .accepted ? derived.acceptedAt : [:]
        return source.mapValues {
            max(0.05, PlayRecency.decay(ageDays: (nowMs - $0) / 86_400_000))
        }
    }

    /// THE RANKING RULE, and the one place the tile list and the tile COUNT must agree.
    ///
    /// Rejected rows SINK TO THE BOTTOM of their own list — never removed, never suppressed
    /// anywhere else. Survivors keep the engine's order exactly (a stable partition), and the sunk
    /// rows sit together at the bottom in REJECT ORDER so a second reject lands below the first.
    ///
    /// ── RE-INJECTION, AND WHY IT IS NOT OPTIONAL ─────────────────────────────────────────────
    /// The engine has already DROPPED the tombstoned songs (`ZoneEngine.Feedback.suppressed`), and
    /// even if it had not, the negative shape would usually push them out of a 90-song cut anyway.
    /// So a rejected row would vanish from the tile — taking the lit 👎 that undoes it with it, and
    /// leaving a mis-tap recoverable only by finding that exact song somewhere else in the app.
    /// Re-adding the scope's live tombstones at the bottom is what guarantees the undo is reachable
    /// for exactly as long as the tombstone lasts, and they fall off by themselves when it expires.
    ///
    /// Pure over `(ids, scope, nowMs)` — a unit test drives the seven days with an injected clock
    /// and never sleeps.
    func rankedIds(_ ids: [String], scope: String,
                   nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [String] {
        let p = partition(ids, scope: scope, nowMs: nowMs)
        return p.live + p.sunk
    }

    /// The same partition, kept APART — for a caller that has to treat the two halves differently
    /// rather than just render them in order. `CollectionPlayMenuItems` is the one that does:
    /// ▶ Play takes the live picks and ▶▶ Play All takes both.
    func partition(_ ids: [String], scope: String,
                   nowMs: Double = Date().timeIntervalSince1970 * 1000)
        -> (live: [String], sunk: [String]) {
        RecFeedbackOrder.sink(ids, tombstones: activeTombstones(scope: scope, nowMs: nowMs))
    }

    /// The number a TILE CARD must show. Exactly `rankedIds(...).count` minus the sunk tail, so the
    /// card's promise ("12 suggestions") and what the list opens on cannot disagree — the defect
    /// that appears the moment two call sites each compute their own count.
    func visibleCount(_ ids: [String], scope: String,
                      nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Int {
        let tombs = activeTombstones(scope: scope, nowMs: nowMs)
        guard !tombs.isEmpty else { return ids.count }
        return ids.reduce(0) { tombs[$1] == nil ? $0 + 1 : $0 }
    }

    /// The `ZoneEngine` projection for one list. Built HERE so every caller gets the same three
    /// maps and nobody re-derives "what does a reject mean" in a view.
    func zoneFeedback(scope: String,
                      nowMs: Double = Date().timeIntervalSince1970 * 1000) -> ZoneEngine.Feedback {
        ZoneEngine.Feedback(accepted: weights(.accepted, nowMs: nowMs),
                            rejected: weights(.rejected, nowMs: nowMs),
                            suppressed: Set(activeTombstones(scope: scope, nowMs: nowMs).keys))
    }

    // ========================================================================
    // MARK: - Write
    // ========================================================================

    /// Record a verdict. Append-only: the log is the audit trail the engine consumes and the thing
    /// a cross-device union merges, so a superseded row is kept rather than deleted.
    @discardableResult
    func record(songId: String, scope: String, verdict: Verdict, surface: Surface,
                artistKey: String? = nil, genre: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Decision? {
        guard !songId.isEmpty, !scope.isEmpty else { return nil }
        nextSeq &+= 1
        let d = Decision(at: nowMs, songId: songId, scope: scope, verdict: verdict,
                         surface: surface, artistKey: artistKey, genre: genre,
                         originInstallId: installId, seq: nextSeq)
        decisions.append(d)
        if decisions.count > Self.maxDecisions {
            decisions.removeFirst(decisions.count - Self.maxDecisions)
        }
        rebuildIndex()
        revision &+= 1
        scheduleSave()
        return d
    }

    /// THE CONTROL'S ACTUAL BEHAVIOUR: tapping 👎 on an already-👎 row CLEARS it; tapping 👍 on a
    /// 👎 row flips it. One function, so the lock screen, the car and the tile cannot disagree
    /// about what a second tap means — and so the instinctive "tap it again to take it back" works
    /// everywhere, which is the only undo a driver can perform.
    ///
    /// Returns the verdict that LANDED (nil = the tap cleared one), so a caller can re-glyph
    /// without re-reading the store.
    @discardableResult
    func toggle(songId: String, to verdict: Verdict, scope: String, surface: Surface,
                artistKey: String? = nil, genre: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Verdict? {
        let next: Verdict = self.verdict(songId: songId, scope: scope) == verdict ? .cleared : verdict
        record(songId: songId, scope: scope, verdict: next, surface: surface,
               artistKey: artistKey, genre: genre, at: nowMs)
        return next == .cleared ? nil : next
    }

    /// Rows at/after `sinceMs`, oldest first — the rec-engine upload's delta window.
    func decisions(sinceMs: Double) -> [Decision] {
        decisions.filter { $0.at >= sinceMs }.sorted { $0.at != $1.at ? $0.at < $1.at : $0.seq < $1.seq }
    }

    // ========================================================================
    // MARK: - The playing scope (what a SYNC accept/reject acts on)
    // ========================================================================

    @ObservationIgnored private(set) var playing: PlayingScope?

    /// Called by a For You list when it hands a queue to the player.
    func beginPlayback(scope: String, songIds: [String],
                       at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        playing = PlayingScope(scope: scope, songIds: songIds, atMs: nowMs)
        revision &+= 1
        scheduleSave()
    }

    /// Playback moved to something that is NOT a recommendation list. Called from the one place
    /// that knows — `CollectionsStore.playNow` — so the scope cannot outlive the queue it describes
    /// and file a later decision against a tile the listener has since left.
    func endPlaybackScope() {
        guard playing != nil else { return }
        playing = nil
        revision &+= 1
        scheduleSave()
    }

    /// The scope `songId` is a recommendation in, if the running queue is a rec queue AND this
    /// track is one of its rows. Membership is checked (not merely "a rec queue is running") so a
    /// track manually queued on top of a zone set cannot be filed against the zone.
    func scope(forPlaying songId: String?) -> String? {
        guard let songId, let playing, playing.songIds.contains(songId) else { return nil }
        return playing.scope
    }

    // ========================================================================
    // MARK: - CloudSync + lifecycle (verbatim PuzzleDecisionStore semantics)
    // ========================================================================

    /// CloudSync write seam: land the pulled payload through the SAME serial queue the coalesced
    /// writer uses, bumping the generation first, so a stale enqueued snapshot either lands BEFORE
    /// the pull or skips itself on the generation check.
    func applyPulledPayload(_ data: Data) {
        writeGeneration.withLock { $0 &+= 1 }
        let url = fileURL
        writeQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    /// Union-by-id merge after a CloudSync pull. Because the log is append-only and the index is
    /// latest-wins, two devices that rejected and re-accepted the same row converge on the later
    /// verdict without either losing its own history.
    @discardableResult
    func reloadFromDisk() -> Bool {
        writeGeneration.withLock { $0 &+= 1 }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for d in doc.decisions where byId[d.id] == nil { byId[d.id] = d; addedFromDisk += 1 }
        let weHoldRowsTheDocLacks = byId.count > doc.decisions.count
        decisions = byId.values.sorted { $0.at != $1.at ? $0.at < $1.at : $0.seq < $1.seq }
        if decisions.count > Self.maxDecisions {
            decisions.removeFirst(decisions.count - Self.maxDecisions)
        }
        nextSeq = max(nextSeq, (decisions.map(\.seq).max() ?? 0) + 1)
        rebuildIndex()
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else {
            if pendingSave, addedFromDisk > 0 { scheduleSave() }
            return false
        }
        save()
        return true
    }

    func clear() {
        decisions = []
        playing = nil
        derived = DerivedState()
        revision &+= 1
        save()
    }

    /// Write any pending coalesced save NOW, synchronously (the scenePhase `.background` flush
    /// doctrine — a suspension→kill must not lose a decision the listener just made in the car).
    func flush() {
        guard pendingSave else { return }
        save()
    }

    private func scheduleSave(debounce: Bool = true) {
        pendingSave = true
        saveTask?.cancel()
        let doc = Document(installId: installId, decisions: decisions, playing: playing, seq: nextSeq)
        let url = fileURL
        let queue = writeQueue
        let generation = writeGeneration
        let gen = generation.withLock { (g: inout Int) -> Int in g &+= 1; return g }
        saveTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: Self.saveDebounce)
                guard !Task.isCancelled else { return }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async {
                    if generation.withLock({ $0 }) == gen { Self.write(doc, to: url) }
                    c.resume()
                }
            }
            guard !Task.isCancelled else { return }
            self?.pendingSave = false
        }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        pendingSave = false
        writeGeneration.withLock { $0 &+= 1 }
        let doc = Document(installId: installId, decisions: decisions, playing: playing, seq: nextSeq)
        let url = fileURL
        writeQueue.sync { Self.write(doc, to: url) }
    }

    private nonisolated static func write(_ doc: Document, to url: URL) {
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: url, options: .atomic) }
    }
}

let recFeedbackSchemaVersion = 1

/// THE SINK RULE, as a pure function over `(ids, tombstones)` — no store, no clock, no actor.
///
/// Extracted so the ordering has exactly ONE implementation. Two call sites needed it in two
/// shapes (concatenated, for rendering; split, for ▶ Play vs ▶▶ Play All), and a second copy of a
/// stable partition is precisely how a card, a list and a play button end up disagreeing about
/// which rows the listener rejected.
enum RecFeedbackOrder {

    /// Survivors keep the engine's order exactly; the tombstoned rows move to the bottom in REJECT
    /// ORDER (so a second reject lands below the first), and any tombstone the engine had already
    /// dropped is RE-ADDED there — otherwise the lit 👎 that undoes a mis-tap would leave the
    /// screen with the row it belongs to.
    static func sink(_ ids: [String], tombstones: [String: Double]) -> (live: [String], sunk: [String]) {
        guard !tombstones.isEmpty else { return (ids, []) }
        var live: [String] = []
        var sunk: [String] = []
        var seen = Set<String>()
        live.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted {
            if tombstones[id] != nil { sunk.append(id) } else { live.append(id) }
        }
        for (id, _) in tombstones where !seen.contains(id) { sunk.append(id) }
        sunk.sort {
            let a = tombstones[$0] ?? 0, b = tombstones[$1] ?? 0
            return a != b ? a < b : $0 < $1
        }
        return (live, sunk)
    }
}

extension RecFeedbackStore {
    /// This store's rows as recommendation-engine events since the engine's cursor. Installed on
    /// `RecommendationService.feedbackProvider` in `PocketDJApp`.
    ///
    /// EVERY verdict rides, including `cleared` — unlike `PuzzleRecEventBridge`, which filters its
    /// stream down to the positive rows because the puzzle wire has no way to express a negative.
    /// This wire does, which is the whole point of it: withholding rejections would upload only
    /// half of what the listener said and leave the cloud ranking recommending back exactly what
    /// was thumbed down. `cleared` rides for the same reason — an undo the server never hears is an
    /// opinion it keeps forever.
    ///
    /// `sinceMs` is the engine's cursor floor, not state kept here, so the projection is idempotent
    /// and safe to call repeatedly with the same floor.
    func recFeedbackEvents(sinceMs: Double) -> [RecFeedbackWire] {
        decisions(sinceMs: sinceMs).map {
            RecFeedbackWire(id: $0.id.uuidString, atMs: $0.at, songId: $0.songId,
                            verdict: $0.verdict, surface: $0.surface, context: $0.scope)
        }
    }
}
