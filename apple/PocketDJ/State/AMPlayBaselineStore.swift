import Foundation
import Observation

/// The Apple Music LIFETIME play-count baseline — the ~56k-song / ~144k-play signal Apple has
/// been accumulating since long before PocketDJ existed. `PlayStatsStore` only knows what this
/// app itself played (~700 songs), so without this the "most played" question has no honest
/// answer.
///
/// ── SET, NEVER ADD ────────────────────────────────────────────────────────────────────────────
/// A capture is a SNAPSHOT of Apple's counters, so `replaceAll` REPLACES the whole map. Importing
/// the same snapshot twice must leave byte-identical state. Feeding these rows into
/// `PlayStatsStore.notePlayed` would be exactly the bug that store's peer-play comment warns
/// about: a counter mutated from a log that can be re-merged, inflating on every replay.
///
/// ── THE DOUBLE-COUNT HAZARD ───────────────────────────────────────────────────────────────────
/// When PocketDJ streams a song through `ApplicationMusicPlayer`, APPLE COUNTS IT TOO. So the next
/// capture already contains that play, and naively adding this app's own count on top would count
/// it twice. The fix is the PROVISIONAL bucket below: an Apple-Music play is recorded here as a
/// TIMESTAMP (not a bare counter) so the badge updates immediately, and each capture drops every
/// provisional timestamp at or before its `capturedAtMs` — precisely the plays the new snapshot
/// has absorbed. Non-Apple plays (rip / stem / vinyl / digital / local file) never enter this
/// bucket; they accumulate permanently in `PlayStatsStore`.
///
/// ── DEVICE-LOCAL, DELIBERATELY ────────────────────────────────────────────────────────────────
/// Persists to Application Support `pocketdj-am-playcounts.json` (the PlayStatsStore durable-JSON
/// pattern: atomic save, decode-on-init, PDJ_USE_FIXTURE seam). It is NOT written into
/// `public/apple-music-index.json` — that is ONE SHARED document every install subscribes to
/// (`MusicSyncClient`: "There are no per-user indexes"), so a catalog-carried baseline would
/// publish the owner's listening history to every other user. It is also NOT registered with
/// `CloudSyncService`: every device can re-derive it from the same Apple ID, and a 56k-row doc in
/// whole-document LWW is pure churn.
@MainActor
@Observable
final class AMPlayBaselineStore {

    /// One song's Apple-side lifetime counter. `lastMs` is Apple's own last-played date; it is
    /// read-only reference data and is deliberately NOT fed into `PlayStatsStore.lastPlayedAt`
    /// (the storage manager sorts LRP eviction by that, and importing Apple's dates would
    /// reshuffle the entire downloaded set).
    struct Entry: Codable, Equatable {
        var n: Int
        var lastMs: Double?
    }

    /// The persisted, versioned document — the SAME shape the Library.xml exporter writes
    /// (`playcounts.json`), so an import is a plain decode.
    ///
    /// `lastPlayedHighWaterMs` was ADDED after v1 shipped and is Optional: synthesized
    /// `decodeIfPresent` already makes that backward-compatible, so the schema version must NOT
    /// be bumped for it (a bump has previously discarded user data in this repo).
    struct Document: Codable {
        var schemaVersion: Int = amPlayBaselineSchemaVersion
        /// Where the capture came from: "library-xml" (the exporter) or "musickit" (on-device).
        var source: String = "musickit"
        /// The PocketDJ source the ids belong to, e.g. "Apple Music (Local)".
        var sourceName: String?
        /// Epoch ms the snapshot was taken. Everything at/below this is already absorbed.
        var capturedAtMs: Double = 0
        var counts: [String: Entry] = [:]
        /// Newest `lastPlayedDate` the last MusicKit walk saw (epoch ms). nil ⇒ the next capture
        /// is a FULL walk. Present ⇒ the walk can stop at the first row at/below it.
        var lastPlayedHighWaterMs: Double?
        /// Apple-Music plays THIS app started that a capture has not yet absorbed, as raw
        /// timestamps per song (see the type doc). Sorted ascending; empty keys are dropped.
        var provisional: [String: [Double]]?
    }

    private(set) var counts: [String: Entry] = [:]
    private(set) var capturedAtMs: Double = 0
    private(set) var source: String = "musickit"
    private(set) var sourceName: String?
    private(set) var lastPlayedHighWaterMs: Double?
    private(set) var provisional: [String: [Double]] = [:]

    /// Bumped on every mutation. Views/services fold this into their memo keys so a capture or an
    /// import invalidates a sorted-by-plays result set (the counts themselves are too big to
    /// diff, and `@Observable` can't see into a dictionary read behind a function call).
    private(set) var revision: Int = 0

    @ObservationIgnored private let fileURL: URL

    /// Repeated Apple-Music plays of the SAME song inside this window don't record a second
    /// provisional timestamp — a seek/restart isn't a second listen. Matches
    /// `PlayStatsStore.recountWindowMs` so the two stores agree on what "a play" is.
    nonisolated static let recountWindowMs: Double = 30_000

    /// Cap on provisional timestamps kept for ONE song. A capture normally empties this within a
    /// day; the cap only bounds the pathological case of a song looped for months with captures
    /// never run. Dropping the OLDEST is the safe direction: those are the ones a future capture
    /// would have absorbed anyway.
    nonisolated static let maxProvisionalPerSong = 64

    init(fileURL: URL = AMPlayBaselineStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            adopt(doc)
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-am-playcounts.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real baseline). Mirrors `PlayStatsStore.launchURL`.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-am-playcounts.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: - Reads

    /// Apple's lifetime count for this song (0 when absent). A song Apple has never played is
    /// NOT stored — see `replaceAll` — so absent and zero are the same answer here.
    func count(_ songId: String) -> Int { counts[songId]?.n ?? 0 }

    /// Apple's own last-played date for this song, epoch ms. Reference data only: never seed
    /// `PlayStatsStore.lastPlayedAt` from it (that is the storage prune's eviction key).
    func lastPlayed(_ songId: String) -> Double? { counts[songId]?.lastMs }

    /// Apple-Music plays this app started that the current snapshot has NOT yet absorbed.
    func provisionalCount(_ songId: String) -> Int { provisional[songId]?.count ?? 0 }

    /// Whether a baseline has ever landed — drives the Settings copy ("Import" vs "Re-import").
    var isEmpty: Bool { counts.isEmpty }
    var songCount: Int { counts.count }
    var totalPlays: Int { counts.values.reduce(0) { $0 + $1.n } }

    /// A pure copy for OFF-MAIN work (the Browse pipeline snapshots this on the main actor, then
    /// filters/sorts detached; the puzzle sampler does the same).
    func countsSnapshot() -> [String: Int] { counts.mapValues(\.n) }

    // MARK: - Writes

    /// SET the baseline from a capture. Returns `false` when the capture was REJECTED.
    ///
    /// The rejection guard is the whole reason this returns a Bool: a capture whose rows are ALL
    /// zero is what a broken read looks like (the iOS `Song.playCount == nil` risk — forum 739587
    /// — reads as "every song has zero plays"), and letting that overwrite a good 56k-row baseline
    /// would silently destroy the signal with no way back. An all-zero capture against an EMPTY
    /// baseline is accepted-as-a-no-op: there is nothing to protect and the caller's "nothing was
    /// read" story is the same either way.
    ///
    /// Zero rows are NOT stored. On a LIBRARY-scoped fetch a missing/zero count means "never
    /// played" (measured: non-nil count == non-zero count exactly, 117/117 over 225 songs, and
    /// the Library.xml baseline contains zero `n == 0` rows), so dropping them keeps the document
    /// small and makes absent ≡ zero for every reader.
    @discardableResult
    func replaceAll(counts newCounts: [String: Entry], capturedAtMs: Double,
                    source: String? = nil, sourceName: String? = nil,
                    lastPlayedHighWaterMs: Double? = nil) -> Bool {
        let kept = newCounts.filter { $0.value.n > 0 }
        if kept.isEmpty && !counts.isEmpty { return false }   // never clobber a good baseline

        counts = kept
        self.capturedAtMs = capturedAtMs
        if let source { self.source = source }
        if let sourceName { self.sourceName = sourceName }
        if let lastPlayedHighWaterMs { self.lastPlayedHighWaterMs = lastPlayedHighWaterMs }
        // Everything this snapshot already contains leaves the provisional bucket — that is the
        // double-count fix. A play that landed AFTER the capture stays, and keeps showing.
        dropProvisional(throughMs: capturedAtMs)
        revision &+= 1
        save()
        return true
    }

    /// Record an Apple-Music play THIS app started, as a timestamp the next capture can retire.
    /// Non-Apple playback must never come through here (it accumulates in `PlayStatsStore`).
    func noteApplePlay(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        var stamps = provisional[songId] ?? []
        // A capture already absorbed anything at/below the snapshot — a late-arriving hook for
        // such a play must not resurrect it.
        if nowMs <= capturedAtMs { return }
        if let last = stamps.last, nowMs - last < Self.recountWindowMs { return }
        stamps.append(nowMs)
        if stamps.count > Self.maxProvisionalPerSong {
            stamps.removeFirst(stamps.count - Self.maxProvisionalPerSong)
        }
        provisional[songId] = stamps
        revision &+= 1
        save()
    }

    /// Drop provisional timestamps at/below `throughMs` (the plays a snapshot has absorbed).
    /// Pure bookkeeping — no save; callers that mutate persist through their own path.
    private func dropProvisional(throughMs: Double) {
        guard !provisional.isEmpty else { return }
        var out: [String: [Double]] = [:]
        for (songId, stamps) in provisional {
            let kept = stamps.filter { $0 > throughMs }
            if !kept.isEmpty { out[songId] = kept }
        }
        provisional = out
    }

    /// Import a snapshot document verbatim (the Library.xml exporter's `playcounts.json`, or a
    /// re-import of our own file). Same SET semantics + all-zero guard as `replaceAll`.
    @discardableResult
    func importDocument(_ doc: Document) -> Bool {
        replaceAll(counts: doc.counts, capturedAtMs: doc.capturedAtMs,
                   source: doc.source, sourceName: doc.sourceName,
                   lastPlayedHighWaterMs: doc.lastPlayedHighWaterMs)
    }

    /// Import from raw JSON bytes. Throws on malformed input so the caller can SAY so rather than
    /// silently leaving the old baseline in place; returns `false` on the all-zero rejection.
    @discardableResult
    func importJSON(_ data: Data) throws -> Bool {
        importDocument(try JSONDecoder().decode(Document.self, from: data))
    }

    /// Import from a file on disk (the documented Settings action reads the exporter's output).
    @discardableResult
    func importFile(at url: URL) throws -> Bool {
        try importJSON(try Data(contentsOf: url))
    }

    /// Advance ONLY the incremental walk's high-water mark — used when a capture legitimately
    /// found nothing new (no rows played since the mark) and there is no snapshot to set.
    func noteHighWater(_ ms: Double) {
        guard ms > (lastPlayedHighWaterMs ?? 0) else { return }
        lastPlayedHighWaterMs = ms
        revision &+= 1
        save()
    }

    /// Wipe the baseline: reset in-memory state (so the UI updates immediately) and remove the
    /// persisted document. `try?` swallows a missing file, mirroring `save()`.
    func clear() {
        counts = [:]
        provisional = [:]
        capturedAtMs = 0
        lastPlayedHighWaterMs = nil
        revision &+= 1
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func adopt(_ doc: Document) {
        counts = doc.counts.filter { $0.value.n > 0 }
        capturedAtMs = doc.capturedAtMs
        source = doc.source
        sourceName = doc.sourceName
        lastPlayedHighWaterMs = doc.lastPlayedHighWaterMs
        provisional = doc.provisional ?? [:]
    }

    /// The document as it would be persisted — the byte-identity invariant's observation point.
    func document() -> Document {
        Document(schemaVersion: amPlayBaselineSchemaVersion, source: source, sourceName: sourceName,
                 capturedAtMs: capturedAtMs, counts: counts,
                 lastPlayedHighWaterMs: lastPlayedHighWaterMs,
                 provisional: provisional.isEmpty ? nil : provisional)
    }

    private func save() {
        let enc = JSONEncoder()
        // Deterministic key order: re-importing the same snapshot must produce a BYTE-IDENTICAL
        // file, and JSONEncoder does not otherwise emit dictionary keys in a stable order.
        enc.outputFormatting = .sortedKeys
        if let data = try? enc.encode(document()) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let amPlayBaselineSchemaVersion = 1
