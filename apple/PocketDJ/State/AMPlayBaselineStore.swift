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
    struct Entry: Codable, Equatable, Sendable {
        var n: Int
        var lastMs: Double?
    }

    /// The persisted, versioned document — the SAME shape the Library.xml exporter writes
    /// (`playcounts.json`), so an import is a plain decode.
    ///
    /// `lastPlayedHighWaterMs` was ADDED after v1 shipped and is Optional: synthesized
    /// `decodeIfPresent` already makes that backward-compatible, so the schema version must NOT
    /// be bumped for it (a bump has previously discarded user data in this repo).
    struct Document: Codable, Sendable {
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
        /// LEGACY, decode-only. Provisional stamps now live in their own tiny sidecar file — a
        /// play must not rewrite a 2.8 MB document (measured: 108.7 ms encode+write for 56,224
        /// rows, versus 0.185 ms for the sidecar). Still decoded so a document written by the
        /// previous build is migrated rather than dropped; `document()` never emits it again.
        var provisional: [String: [Double]]?
    }

    /// The sidecar document — provisional stamps ONLY. Separate file, separate write.
    struct ProvisionalDocument: Codable {
        var schemaVersion: Int = amPlayBaselineSchemaVersion
        var provisional: [String: [Double]] = [:]
    }

    /// What `replaceAll` did, in enough detail for the UI to say something TRUE about it. The Bool
    /// return says only "stored or not"; the remedies for the two refusals are opposite (one wants
    /// an import, the other wants the existing baseline left alone), so the reason is kept here.
    enum ApplyOutcome: Equatable {
        case applied
        /// The read produced no plays at all against a non-empty baseline — the shape a broken
        /// MusicKit read has (`Song.playCount == nil`, forum 739587).
        case rejectedNoPlays
        /// The read produced far fewer songs than the baseline already had. A snapshot that loses
        /// half its rows is a broken read, not a library the user deleted.
        case rejectedCoverageLoss(kept: Int, existing: Int)
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

    /// What the last `replaceAll` decided — read by the Settings copy after a `false`.
    private(set) var lastOutcome: ApplyOutcome = .applied

    /// Has the on-disk document been read yet? `isEmpty` alone cannot answer "is there a baseline"
    /// during the ~70 ms the async launch decode takes — it reads `true` for a store that simply
    /// has not loaded, which is how a spurious full walk gets started against a baseline that
    /// already exists on disk. Every automatic trigger gates on THIS.
    private(set) var hasLoaded = false

    @ObservationIgnored private let fileURL: URL
    /// Sibling of `fileURL` holding ONLY the provisional stamps. See `Document.provisional`.
    @ObservationIgnored private let provisionalURL: URL

    /// Repeated Apple-Music plays of the SAME song inside this window don't record a second
    /// provisional timestamp — a seek/restart isn't a second listen. Matches
    /// `PlayStatsStore.recountWindowMs` so the two stores agree on what "a play" is.
    nonisolated static let recountWindowMs: Double = 30_000

    /// Cap on provisional timestamps kept for ONE song. A capture normally empties this within a
    /// day; the cap only bounds the pathological case of a song looped for months with captures
    /// never run. Dropping the OLDEST is the safe direction: those are the ones a future capture
    /// would have absorbed anyway.
    nonisolated static let maxProvisionalPerSong = 64

    /// Below this many existing rows the coverage guard is inert — a two-row test baseline (or a
    /// library someone genuinely just started) has no "collapse" worth detecting, and guarding it
    /// would only block legitimate small snapshots.
    nonisolated static let coverageGuardFloor = 100

    /// `loadNow: false` skips the synchronous decode so a caller can do it OFF the main actor with
    /// `loadFromDiskAsync()` — the app path, where decoding 2.8 MB costs ~70 ms of launch. Tests
    /// and every other caller keep the straightforward synchronous default.
    init(fileURL: URL = AMPlayBaselineStore.defaultURL(), loadNow: Bool = true) {
        self.fileURL = fileURL
        self.provisionalURL = Self.provisionalURL(for: fileURL)
        if loadNow { loadFromDisk() }
    }

    /// Sidecar path for a given baseline path: `…-am-playcounts.provisional.json`.
    nonisolated static func provisionalURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("provisional.json")
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
            // The sidecar too, or a UI test inherits the previous run's provisional stamps.
            try? FileManager.default.removeItem(at: provisionalURL(for: url))
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
    ///
    /// `observedSongIds` names the songs the producing read ACTUALLY looked at. It exists because
    /// retiring provisional stamps purely by timestamp assumes the snapshot covers everything —
    /// true for an import (the Library.xml exporter joins the catalog at 99.98%) and false for a
    /// MusicKit walk, whose catalog-id-only resolver reaches 83% of the baseline's songs. Retiring
    /// an unobserved song's stamp deletes a play that never made it into any counter: the badge
    /// silently goes backwards and nothing can restore it. nil = "this snapshot covers everything",
    /// which is the import case and the pre-existing behaviour.
    ///
    /// `clearHighWater` exists because `lastPlayedHighWaterMs: nil` already means "leave it
    /// alone" — without an explicit signal there is no way to get BACK to a full walk, so a bogus
    /// mark (see `AppleMusicPlayCountCapture`) would wedge an install into incremental-only for
    /// good.
    @discardableResult
    func replaceAll(counts newCounts: [String: Entry], capturedAtMs: Double,
                    source: String? = nil, sourceName: String? = nil,
                    lastPlayedHighWaterMs: Double? = nil,
                    clearHighWater: Bool = false,
                    observedSongIds: Set<String>? = nil) -> Bool {
        let kept = newCounts.filter { $0.value.n > 0 }
        if kept.isEmpty && !counts.isEmpty {   // never clobber a good baseline
            lastOutcome = .rejectedNoPlays
            return false
        }
        // COVERAGE COLLAPSE. The all-zero guard above only catches a read that returned literally
        // nothing; a read that returned half of what is already stored is the same kind of failure
        // and just as unrecoverable, because a replace has no undo. Floor-gated so a legitimately
        // small baseline (and every test fixture) is never second-guessed.
        if !counts.isEmpty, counts.count >= Self.coverageGuardFloor, kept.count * 2 < counts.count {
            lastOutcome = .rejectedCoverageLoss(kept: kept.count, existing: counts.count)
            return false
        }

        counts = kept
        self.capturedAtMs = capturedAtMs
        if let source { self.source = source }
        if let sourceName { self.sourceName = sourceName }
        if clearHighWater { self.lastPlayedHighWaterMs = nil }
        if let lastPlayedHighWaterMs { self.lastPlayedHighWaterMs = lastPlayedHighWaterMs }
        // Everything this snapshot already contains leaves the provisional bucket — that is the
        // double-count fix. A play that landed AFTER the capture stays, and keeps showing.
        dropProvisional(throughMs: capturedAtMs, observedSongIds: observedSongIds)
        lastOutcome = .applied
        revision &+= 1
        save()
        return true
    }

    /// Merge ONE checkpoint of a RUNNING capture into the live baseline — the thing that makes an
    /// interrupted walk worth something instead of worth nothing.
    ///
    /// ── A MONOTONE PREVIEW, AND ONLY THAT ─────────────────────────────────────────────────────
    /// It RAISES the counts it is handed and touches nothing else. Deliberately absent:
    ///   • the all-zero and coverage guards — a partial IS a fraction of the library by
    ///     definition, and those guards judge a WHOLE snapshot. They still run, once, at commit
    ///     (`replaceAll`), which is the only place a broken read can be recognised as broken;
    ///   • `capturedAtMs`, the high-water mark, and provisional retirement — every one of those is
    ///     a whole-walk decision. A partial that stamped a mark would make a broken read permanent
    ///     (every later walk incremental, the library never re-read); a partial that retired
    ///     provisional stamps would delete plays no counter had absorbed yet, and the badge would
    ///     silently go backwards with no way back;
    ///   • lowering. `max`, not replace, so a checkpoint can never make Browse WORSE than it was
    ///     before the walk started. A genuine Music.app reset lowering a count is a same-source
    ///     SNAPSHOT decision, and is made once, at commit.
    ///
    /// ── SET, NEVER ADD ────────────────────────────────────────────────────────────────────────
    /// `partial` is the run's RUN-TO-DATE total per song, never a delta, so this SETs (via `max`)
    /// rather than accumulating. Re-applying the same checkpoint — a resume that re-reads it, a
    /// retry, a duplicate call — is idempotent: `max(x, x) == x`. Nothing here ever adds to what is
    /// already stored, which is the one invariant the whole design rests on.
    ///
    /// Callers hand over the WHOLE accumulator each time, not the rows since the last checkpoint.
    /// That is what makes the store self-heal: a checkpoint whose background write was coalesced
    /// away (or lost to a kill) is fully carried by the next one.
    ///
    /// Returns how many songs actually moved — 0 means nothing changed and nothing was written.
    @discardableResult
    func mergePartial(_ partial: [String: Entry]) -> Int {
        var changed = 0
        for (songId, entry) in partial where entry.n > 0 {
            let prior = counts[songId]
            let merged = Entry(n: max(prior?.n ?? 0, entry.n),
                               lastMs: AppleMusicPlayCountCapture.maxDate(prior?.lastMs, entry.lastMs))
            if prior != merged {
                counts[songId] = merged
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        revision &+= 1
        saveSoon()
        return changed
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
        // ONLY the sidecar. Rewriting the whole baseline here cost 108.7 ms on the main actor at
        // every track change (measured, 56,224 rows) — several hundred on a phone.
        saveProvisional()
    }

    /// Drop provisional timestamps at/below `throughMs` (the plays a snapshot has absorbed) for
    /// the songs the snapshot actually OBSERVED. `observedSongIds == nil` means it observed
    /// everything — see `replaceAll`.
    /// Pure bookkeeping — no save; callers that mutate persist through their own path.
    private func dropProvisional(throughMs: Double, observedSongIds: Set<String>?) {
        guard !provisional.isEmpty else { return }
        var out: [String: [Double]] = [:]
        for (songId, stamps) in provisional {
            guard observedSongIds?.contains(songId) ?? true else { out[songId] = stamps; continue }
            let kept = stamps.filter { $0 > throughMs }
            if !kept.isEmpty { out[songId] = kept }
        }
        provisional = out
    }

    /// Import a snapshot document verbatim (the Library.xml exporter's `playcounts.json`, or a
    /// re-import of our own file). Same SET semantics + all-zero guard as `replaceAll`.
    /// A high-water mark for an imported snapshot that carries none. The exporter writes Apple's
    /// own `lastMs` per row (56,072 of 56,224 rows in the real file), so the newest of them IS the
    /// point past which the library has not been walked.
    ///
    /// Deriving it is what makes the FIRST refresh after an import INCREMENTAL. Without it the
    /// mark stays nil, the next walk is FULL, and a MusicKit walk — which resolves only songs
    /// carrying an `appleMusicId` — would have replaced the imported baseline with 83.0% of its
    /// songs and 85.0% of its plays (measured on the owner's real data: 46,664 of 56,224 songs,
    /// dropping 9,560 songs / 21,652 plays), reported as a success, with no undo.
    static func derivedHighWater(_ counts: [String: Entry]) -> Double? {
        counts.values.compactMap(\.lastMs).max()
    }

    @discardableResult
    func importDocument(_ doc: Document) -> Bool {
        // An import IS a complete snapshot of its source, so provisional stamps retire by
        // timestamp (observedSongIds nil) — the case the parameter was written to preserve.
        replaceAll(counts: doc.counts, capturedAtMs: doc.capturedAtMs,
                   source: doc.source, sourceName: doc.sourceName,
                   lastPlayedHighWaterMs: doc.lastPlayedHighWaterMs
                       ?? Self.derivedHighWater(doc.counts))
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

    /// Forget the incremental mark so the NEXT capture is a full walk. Non-destructive: the counts
    /// stay. This is the escape hatch from a bogus mark, and it is safe to reach for because a
    /// full walk can no longer replace a baseline from a different source (see `countsToStore`).
    func resetHighWater() {
        guard lastPlayedHighWaterMs != nil else { return }
        lastPlayedHighWaterMs = nil
        revision &+= 1
        save()
    }

    /// Wipe the baseline: reset in-memory state (so the UI updates immediately) and remove the
    /// persisted documents. `try?` swallows a missing file, mirroring `save()`.
    func clear() {
        counts = [:]
        provisional = [:]
        capturedAtMs = 0
        lastPlayedHighWaterMs = nil
        source = "musickit"
        sourceName = nil
        lastOutcome = .applied
        revision &+= 1
        // A checkpoint's background write must not resurrect the document we are deleting.
        writeGeneration &+= 1
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: provisionalURL)
    }

    // MARK: - Persistence

    /// Synchronous decode of both documents. Safe to call once, on a store that has not been
    /// mutated yet — see `loadFromDiskAsync`. Decodes the big document ONCE (it also carries the
    /// legacy provisional field, which the sidecar migration needs).
    private func loadFromDisk() {
        let doc = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
        if let doc { adopt(doc) }
        let side = (try? Data(contentsOf: provisionalURL))
            .flatMap { try? JSONDecoder().decode(ProvisionalDocument.self, from: $0) }
        adoptProvisional(side, legacy: doc?.provisional)
        hasLoaded = true
    }

    /// Decode OFF the main actor, then adopt. The app path: 2.8 MB of JSON costs ~70 ms to decode
    /// (measured), which is launch time spent before the first frame if it happens in `init`.
    ///
    /// Refuses to run against a store that has already been touched — adopting a disk document on
    /// top of live state would resurrect retired provisional stamps.
    func loadFromDiskAsync() async {
        guard revision == 0, counts.isEmpty, provisional.isEmpty else { hasLoaded = true; return }
        let (main, side) = (fileURL, provisionalURL)
        let loaded = await Task.detached(priority: .userInitiated) { () -> (Document?, ProvisionalDocument?) in
            let doc = (try? Data(contentsOf: main)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
            let pro = (try? Data(contentsOf: side)).flatMap { try? JSONDecoder().decode(ProvisionalDocument.self, from: $0) }
            return (doc, pro)
        }.value
        guard revision == 0, counts.isEmpty, provisional.isEmpty else { hasLoaded = true; return }
        if let doc = loaded.0 { adopt(doc) }
        adoptProvisional(loaded.1, legacy: loaded.0?.provisional)
        hasLoaded = true
        revision &+= 1   // the UI's feed keys on this — without it a late load never reaches Browse
    }

    private func adopt(_ doc: Document) {
        counts = doc.counts.filter { $0.value.n > 0 }
        capturedAtMs = doc.capturedAtMs
        source = doc.source
        sourceName = doc.sourceName
        lastPlayedHighWaterMs = doc.lastPlayedHighWaterMs
        // NOT doc.provisional — that field is legacy. `loadProvisional` decides.
    }

    /// The SIDECAR wins whenever it exists. A document written by the previous build carries its
    /// stamps inline; migrate those exactly once, and never again — otherwise every launch would
    /// resurrect stamps a capture has since retired, re-inflating the badge.
    private func adoptProvisional(_ side: ProvisionalDocument?, legacy: [String: [Double]]?) {
        if let side {
            provisional = side.provisional
        } else if let legacy, !legacy.isEmpty {
            provisional = legacy
            saveProvisional()
        }
    }

    /// The document as it would be persisted — the byte-identity invariant's observation point.
    /// `provisional` is deliberately nil: it lives in the sidecar now, and keeping it out of here
    /// is what makes a re-import byte-identical regardless of what has been played since.
    func document() -> Document {
        Document(schemaVersion: amPlayBaselineSchemaVersion, source: source, sourceName: sourceName,
                 capturedAtMs: capturedAtMs, counts: counts,
                 lastPlayedHighWaterMs: lastPlayedHighWaterMs, provisional: nil)
    }

    func provisionalDocument() -> ProvisionalDocument {
        ProvisionalDocument(schemaVersion: amPlayBaselineSchemaVersion, provisional: provisional)
    }

    /// The BIG write — the whole counts map. Stays synchronous on purpose: it only runs on an
    /// explicit capture/import (never per play), and the tests' byte-identity assertions read the
    /// file the instant the call returns.
    private func save() {
        // Any background write still queued now holds a STALE document — invalidate it, or a
        // checkpoint's write could land on top of this one and undo a commit.
        writeGeneration &+= 1
        let enc = JSONEncoder()
        // Deterministic key order: re-importing the same snapshot must produce a BYTE-IDENTICAL
        // file, and JSONEncoder does not otherwise emit dictionary keys in a stable order.
        enc.outputFormatting = .sortedKeys
        if let data = try? enc.encode(document()) { try? data.write(to: fileURL, options: .atomic) }
        saveProvisional()
    }

    /// Serialized, OFF-MAIN document write — the checkpoint path.
    ///
    /// A checkpointed capture writes the whole document ~20 times on a 96k library. At 108.7 ms of
    /// main-actor JSON encoding each (measured, 56,224 rows) doing that synchronously would be two
    /// solid seconds of dropped frames spread across the walk, which is exactly the kind of cost
    /// the rest of this store is written to avoid.
    ///
    /// Chained so two writes can never interleave, generation-stamped so a superseded write skips
    /// itself (a synchronous `save()` or a later checkpoint always wins), and each individual write
    /// is still the same ATOMIC tmp+rename `save()` uses — so an interruption at any instant leaves
    /// a whole, valid document on disk, never a half-written one.
    ///
    /// ONLY the encode runs off-main; the staleness check and the write itself are back ON the
    /// main actor, together. Splitting them was a real, measured race (it flaked 1 run in 4): a
    /// checkpoint's task read "still current", the main actor then finished the walk and committed
    /// synchronously, and the checkpoint's older bytes landed on top of the commit — the file held
    /// one chunk while memory held the whole library. The encode is the expensive half (~109 ms at
    /// 56k rows); the write of the encoded bytes is single-digit ms, which is what the main actor
    /// pays here, ~20 times across a multi-minute walk.
    private func saveSoon() {
        writeGeneration &+= 1
        let gen = writeGeneration
        let doc = document()          // value snapshot taken HERE, on the main actor
        let url = fileURL
        let prior = writeChain
        writeChain = Task.detached(priority: .utility) { [weak self] in
            await prior?.value
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            guard let data = try? enc.encode(doc) else { return }
            await MainActor.run {
                guard let self, self.writeGeneration == gen else { return }   // superseded
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Await whatever background write is outstanding. The seam the tests read the file through,
    /// and the flush the app takes on the way to the background.
    func flushPendingWrites() async { await writeChain?.value }

    @ObservationIgnored private var writeChain: Task<Void, Never>?
    /// Bumped by every write attempt; a queued background write whose stamp is no longer current
    /// carries a superseded document and skips.
    @ObservationIgnored private(set) var writeGeneration: Int = 0

    /// The SMALL write — the per-play hot path (0.185 ms measured, versus 108.7 ms for `save()`).
    private func saveProvisional() {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        if provisional.isEmpty {
            try? FileManager.default.removeItem(at: provisionalURL)
            return
        }
        if let data = try? enc.encode(provisionalDocument()) {
            try? data.write(to: provisionalURL, options: .atomic)
        }
    }
}

let amPlayBaselineSchemaVersion = 1
