import Foundation
import Observation
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// THE one place that answers "how many times has this song been played?" — the value the
/// Browser's `#NN` badge renders, the "Plays" sort orders by, the Gem Collector weights by, and
/// the rec engine ranks with.
///
/// Three buckets, added exactly once each:
///
///   1. `baseline` — Apple's lifetime counter as of the last snapshot. The bulk of the signal
///      (~144k plays vs this app's ~900).
///   2. `stats.nonApplePlayCount` — plays PocketDJ made that Apple never saw: rips, stems, vinyl,
///      digital files, local burns, the Mix decks. These accumulate forever; no snapshot can
///      retire them, because no snapshot ever contained them.
///   3. `baseline.provisionalCount` — Apple-Music plays PocketDJ made SINCE the last snapshot.
///      Shown immediately so the badge moves the moment you press play, then retired by the next
///      capture (which now contains them). Adding `stats.playCount` wholesale instead would count
///      every one of these twice the day a capture runs.
///
/// The split is why `PlayStatsStore.notePlayed` carries an `appleCounted` tag at all.
@MainActor
@Observable
final class PlayCountService {

    @ObservationIgnored let baseline: AMPlayBaselineStore
    @ObservationIgnored private let stats: PlayStatsStore

    /// Bumped whenever any bucket changes. Memo keys (the Browse results cache, the row badges)
    /// fold this in — the maps themselves are far too big to diff per render.
    ///
    /// COMPUTED over the baseline's own revision, not mirrored: the baseline can change without
    /// going through this service (an async disk load at launch, a direct import), and a mirrored
    /// counter would leave the Browser sorted by numbers that no longer exist.
    var revision: Int { baseline.revision &+ ownRevision }
    private var ownRevision: Int = 0

    init(baseline: AMPlayBaselineStore, stats: PlayStatsStore,
         runURL: URL? = nil, auditURL: URL? = nil) {
        self.baseline = baseline
        self.stats = stats
        self.runURL = runURL ?? Self.defaultRunURL()
        self.auditURL = auditURL ?? Self.defaultAuditURL()
        // The audit sidecar is a few hundred bytes and is the ONLY thing read at init — the run
        // document (which carries the counts) is decoded lazily, when a run actually resumes, so
        // hydrating "was the last read interrupted?" never costs launch time.
        lastCapture = Self.loadAudit(from: self.auditURL)
    }

    /// The lifetime total for one song. Never negative; 0 for a song nothing has ever played.
    ///
    /// `appleKnowsSong` is the LEGACY join (see `PlayStatsStore.nonApplePlayCount`): plays this
    /// app recorded before it tagged plays by source are unattributable, and for a song Apple has
    /// a counter for they are already inside that counter. Without this, the whole pre-upgrade
    /// history — ~704 songs / 909 plays on the owner's install — is added a second time on top of
    /// the imported 144,517-play snapshot, permanently.
    func combinedPlayCount(_ songId: String) -> Int {
        guard !songId.isEmpty else { return 0 }
        let apple = baseline.count(songId)
        return apple
            + stats.nonApplePlayCount(songId, appleKnowsSong: apple > 0)
            + baseline.provisionalCount(songId)
    }

    /// Apple's own last-played date, when it knows one — strictly reference data for the UI.
    /// Deliberately NOT wired into `PlayStatsStore.lastPlayedAt`: that is the storage manager's
    /// LRP eviction key, and seeding it from Apple would reshuffle the whole downloaded set.
    func applePlayedAt(_ songId: String) -> Double? { baseline.lastPlayed(songId) }

    /// Every song with a non-zero lifetime total, as a plain value map — the snapshot the OFF-MAIN
    /// Browse filter/sort and the Gem Collector sampler take on the main actor and then read from
    /// a detached task.
    func snapshot() -> [String: Int] {
        var out = baseline.countsSnapshot()
        // The same legacy join `combinedPlayCount` makes, in bulk — the two must never disagree,
        // or the badge and the "Plays" sort show different numbers for the same row.
        for (id, n) in stats.nonApplePlayCountsSnapshot(appleKnownSongIds: Set(out.keys)) {
            out[id, default: 0] += n
        }
        for (id, stamps) in baseline.provisional where !stamps.isEmpty {
            out[id, default: 0] += stamps.count
        }
        return out
    }

    // MARK: - Writes (the ONE funnel every play surface goes through)

    /// Record a play. `backend` decides which bucket it lands in:
    ///   • `.appleMusic` → `PlayStatsStore` (tagged) AND the provisional bucket, so it shows now
    ///     and is retired by the capture that absorbs it.
    ///   • everything else → `PlayStatsStore` only, permanently.
    func notePlayed(_ songId: String, backend: PlaybackBackend?,
                    at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        let apple = backend == .appleMusic
        stats.notePlayed(songId, at: nowMs, appleCounted: apple)
        if apple { baseline.noteApplePlay(songId, at: nowMs) }
        ownRevision &+= 1
    }

    /// Adopt a fresh Apple snapshot (SET semantics — see `AMPlayBaselineStore.replaceAll`).
    /// Returns `false` when the capture was rejected; `baseline.lastOutcome` says why.
    @discardableResult
    func applyCapture(counts: [String: AMPlayBaselineStore.Entry], capturedAtMs: Double,
                      source: String? = nil, sourceName: String? = nil,
                      lastPlayedHighWaterMs: Double? = nil,
                      clearHighWater: Bool = false,
                      observedSongIds: Set<String>? = nil) -> Bool {
        baseline.replaceAll(counts: counts, capturedAtMs: capturedAtMs, source: source,
                            sourceName: sourceName,
                            lastPlayedHighWaterMs: lastPlayedHighWaterMs,
                            clearHighWater: clearHighWater,
                            observedSongIds: observedSongIds)
    }

    // MARK: - The capture run (app-scoped, checkpointed, resumable, auditable)
    //
    // ── WHY THIS LIVES HERE AND NOT IN A VIEW ────────────────────────────────────────────────
    // The trigger used to be a bare `Task {}` inside `AppleMusicSettingsView`, guarded by a
    // view-local `@State` flag. Nothing owned it: navigating away destroyed the status/error
    // display and, worse, reset the in-flight guard, so re-entering the pane started a SECOND
    // 96k-row walk on top of the first (the identical bug the collections sync already fixed by
    // moving its run state app-scoped). Both triggers — the Settings button and the first-run
    // auto capture — now arrive at ONE mechanism, owned by the service, which outlives any view.

    /// The most recent capture run's audit — running, finished, or interrupted. Persisted, so the
    /// owner can answer "did this work?" after a relaunch without a debugger.
    private(set) var lastCapture: AppleMusicPlayCountCapture.Audit?

    /// APP-SCOPED in-flight guard. Not a view's `@State`: that is what let a re-entered Settings
    /// pane start an overlapping walk.
    private(set) var isCapturing = false

    @ObservationIgnored private let runURL: URL
    @ObservationIgnored private let auditURL: URL
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runWriteChain: Task<Void, Never>?

    /// Test seams. The defaults are the real MusicKit pager and the real availability gate; the
    /// unit suite injects a FAKE walk it can interrupt, resume and re-run, which is the only way
    /// to prove any of this without a signed-in 96,000-song library.
    @ObservationIgnored var pagerFactory: @Sendable () -> any AppleMusicPlayCountCapture.LibraryPager = { MusicKitLibraryPager() }
    @ObservationIgnored var captureAvailable: () -> Bool = { AppleMusicPlayCountCapture.isAvailable }
    @ObservationIgnored var pageLimit = AppleMusicPlayCountCapture.defaultPageLimit
    @ObservationIgnored var checkpointRows = AppleMusicPlayCountCapture.defaultCheckpointRows

    /// The source tag every MusicKit walk writes. ONE value for both triggers on purpose: the
    /// auto path used to write "musickit-auto", which made `countsToStore` treat a later manual
    /// walk as a DIFFERENT source and fold where it should have replaced.
    static let musicKitSource = "musickit"

    /// Start — or RESUME — the checkpointed capture.
    ///
    /// Idempotent while one is in flight, and the guard is on the SERVICE, so a re-entered
    /// Settings pane can no longer stack walks. Returns false when it declined (already running,
    /// MusicKit unavailable, catalog not loaded yet).
    ///
    /// `songs` is the catalog the walk resolves Apple's rows against. An EMPTY catalog is refused:
    /// with no resolver every row would come back unresolved, the walk would end with zero counts
    /// but a non-nil `maxLastPlayedMs`, and committing that would stamp a high-water mark with
    /// nothing stored — wedging the install into incremental-only forever.
    @discardableResult
    func startCapture(songs: [IndexSong], trigger: String) -> Bool {
        guard !isCapturing, !songs.isEmpty, captureAvailable() else { return false }
        isCapturing = true
        runTask = Task { [weak self] in await self?.performCapture(songs: songs, trigger: trigger) }
        return true
    }

    /// FIRST-RUN AUTO-CAPTURE. The baseline ships EMPTY, so until something fills it Browse's
    /// "Plays" column ranks by this app's own playback — Levi saw nothing above 9 while his library
    /// holds songs at 54. Requiring a Settings visit to make the feature work at all is a trap: the
    /// number looks authoritative and is simply wrong.
    ///
    /// Gated on `baseline.hasLoaded`, not on `isEmpty` alone: `isEmpty` reads true for the ~70 ms
    /// the async launch decode takes, so the naive check starts a full walk against a baseline that
    /// already exists on disk.
    ///
    /// Safe to call on every foreground — it self-guards on emptiness, on the disk load, on
    /// MusicKit availability and on being in flight.
    @discardableResult
    func autoCaptureIfNeverCaptured(songs: [IndexSong]) -> Bool {
        guard baseline.hasLoaded, baseline.isEmpty, !autoCaptureAttempted else { return false }
        autoCaptureAttempted = true   // one shot per launch, whatever the outcome
        return startCapture(songs: songs, trigger: "auto")
    }

    /// AUTO-RESUME. A run the process died in the middle of banked its cursor and its counts on
    /// disk; pick it back up at launch/foreground so the owner never has to babysit a Settings
    /// screen for a multi-minute walk. Same mechanism, same idempotence.
    @discardableResult
    func resumeCaptureIfInterrupted(songs: [IndexSong]) -> Bool {
        guard baseline.hasLoaded, lastCapture?.isInterrupted == true, !resumeAttempted else { return false }
        resumeAttempted = true
        return startCapture(songs: songs, trigger: "resume")
    }

    /// "Re-read everything from Apple Music": forget the incremental mark AND any banked partial
    /// run, then walk the whole library again. Non-destructive — the counts stay put.
    @discardableResult
    func recaptureEverything(songs: [IndexSong]) -> Bool {
        guard !isCapturing else { return false }
        baseline.resetHighWater()
        try? FileManager.default.removeItem(at: runURL)
        return startCapture(songs: songs, trigger: "full")
    }

    /// Stop the walk. The walk lands a final checkpoint on its way out, so this LOSES NOTHING —
    /// the next run continues from the cursor.
    func cancelCapture() { runTask?.cancel() }

    /// Await the in-flight run (and every write it queued). Tests and the background flush.
    func awaitCapture() async {
        await runTask?.value
        await flushCaptureWrites()
    }

    /// Land every queued checkpoint write. Called on the way to the background, where the app has
    /// seconds rather than minutes.
    func flushCaptureWrites() async {
        await runWriteChain?.value
        await baseline.flushPendingWrites()
    }

    /// Guards the first-run one-shot. Not persisted on purpose: if a capture failed (offline, not
    /// yet authorized), the next launch should get another go — the cost of retrying an empty
    /// baseline is one walk, the cost of never retrying is a permanently wrong column.
    @ObservationIgnored private var autoCaptureAttempted = false
    @ObservationIgnored private var resumeAttempted = false

    // MARK: The run body

    private func performCapture(songs: [IndexSong], trigger: String) async {
        let hold = PlayCountBackgroundHold("pocketdj.playcount-capture")
        defer {
            hold.end()
            isCapturing = false
            runTask = nil
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        // RESUME whatever is banked, else start fresh against the store's current mark. `since`
        // and `startedMs` are pinned to the ORIGINAL run — moving either mid-walk would change
        // where the walk stops and which provisional plays it is entitled to retire.
        var run = Self.loadRun(from: runURL).flatMap { $0.isResumable ? $0 : nil }
            ?? .starting(since: baseline.lastPlayedHighWaterMs, trigger: trigger, nowMs: nowMs)
        run.completed = false
        run.stopReason = run.cursor > 0
            ? "Picking up where it left off (row \(run.cursor))"
            : "Reading your library…"
        run.updatedMs = nowMs
        lastCapture = run.audit
        Self.saveAudit(run.audit, to: auditURL)

        // 96k rows of index-building is not main-thread work, and it is the one place both
        // triggers used to duplicate the construction.
        let resolve = await Self.makeResolver(songs: songs)
        let pager = pagerFactory()
        do {
            let finished = try await AppleMusicPlayCountCapture.walk(
                pager: pager, run: run, resolve: resolve,
                pageLimit: pageLimit, checkpointRows: checkpointRows,
                checkpoint: { [weak self] snapshot in await self?.checkpoint(snapshot) })
            await commit(finished)
        } catch {
            // The walk landed a final checkpoint carrying the cursor AND the reason on its way
            // out, so there is nothing to salvage here and nothing to report that the persisted
            // audit does not already say. The next run resumes.
        }
    }

    /// ONE checkpoint: publish, persist, record. Everything here is idempotent.
    private func checkpoint(_ run: AppleMusicPlayCountCapture.Run) {
        // 1. THE BASELINE, first — a checkpoint Browse never sees is worth nothing. Monotone and
        //    idempotent (see `AMPlayBaselineStore.mergePartial`), and it hands over the WHOLE
        //    run-to-date accumulator rather than a delta, so a write that got coalesced away or
        //    lost to a kill is carried by the next checkpoint.
        baseline.mergePartial(run.counts)
        // 2. The run document — the cursor + accumulator the next run resumes from.
        saveRunSoon(run)
        // 3. The tiny audit sidecar the app hydrates at launch.
        lastCapture = run.audit
        Self.saveAudit(run.audit, to: auditURL)
    }

    /// THE FINAL COMMIT. Every WHOLE-WALK decision happens here, exactly once, on a completed run:
    /// the broken-read verdict, the cross-source fold, the high-water mark, and the single
    /// provisional retirement over the union of everything the run observed. None of them may be
    /// made per checkpoint — see `AMPlayBaselineStore.mergePartial` for why each one would be
    /// actively harmful there.
    private func commit(_ run: AppleMusicPlayCountCapture.Run) async {
        var final = run
        let result = run.result
        if result.readNothing {
            // A walk that LISTED rows and read nil for every count is BROKEN, not empty. No
            // counts, and above all NO high-water mark: a mark makes every later walk incremental,
            // so the install could never re-read the library it failed to read.
            final.stopReason = "Apple returned no play counts for the \(result.scanned) "
                + "song\(result.scanned == 1 ? "" : "s") it listed — nothing was changed. "
                + "Import a snapshot file instead."
            await finish(final)
            return
        }
        // Read the baseline AT COMMIT TIME, never at walk start. The walk is minutes long; an
        // import, another device's snapshot, or this run's own checkpoints may have landed since,
        // and folding against a pre-walk copy is a multi-minute lost-update window.
        let existing = baseline.counts
        let existingSource = baseline.isEmpty ? nil : baseline.source
        let counts = AppleMusicPlayCountCapture.countsToStore(
            result, existing: existing, existingSource: existingSource,
            newSource: Self.musicKitSource)
        let applied = applyCapture(
            counts: counts, capturedAtMs: result.capturedAtMs,
            source: Self.musicKitSource, sourceName: Config.appleMusicSourceName,
            lastPlayedHighWaterMs: result.highWaterToAdopt,
            // Only the songs this walk actually RESOLVED may have their provisional plays retired,
            // and only here — once, over the union of every checkpoint's observations.
            observedSongIds: result.observedSongIds)
        if applied {
            final.stopReason = "Read \(result.scanned) song\(result.scanned == 1 ? "" : "s") · "
                + "\(counts.count) with plays"
                + (result.unresolved > 0 ? " · \(result.unresolved) not in your catalog" : "")
        } else {
            final.stopReason = Self.rejectionReason(baseline.lastOutcome)
        }
        await finish(final)
    }

    /// Close the run out: mark it completed, publish + persist the audit, and drop the (large) run
    /// document. Awaits the write chain first so a queued checkpoint cannot resurrect it.
    private func finish(_ run: AppleMusicPlayCountCapture.Run) async {
        var final = run
        final.completed = true
        final.updatedMs = Date().timeIntervalSince1970 * 1000
        await runWriteChain?.value
        try? FileManager.default.removeItem(at: runURL)
        lastCapture = final.audit
        Self.saveAudit(final.audit, to: auditURL)
    }

    /// Say WHICH guard refused the commit — the remedies are opposite, so "it didn't work" is not
    /// enough. Mirrors the Settings copy for an import rejection.
    static func rejectionReason(_ outcome: AMPlayBaselineStore.ApplyOutcome) -> String {
        switch outcome {
        case .applied:
            return "Nothing was changed."
        case .rejectedNoPlays:
            return "Apple returned no play counts, so your existing numbers were kept. "
                 + "Import a snapshot file instead."
        case .rejectedCoverageLoss(let kept, let existing):
            return "That read found only \(kept) songs against the \(existing) already stored, "
                 + "which looks like a failed read rather than a smaller library — your existing "
                 + "numbers were kept."
        }
    }

    /// The walk's resolver, built OFF the main actor: exact Apple catalog id first, then the strict
    /// title+artist fallback. FIRST-seen wins, matching `AppModel.songId(forAppleMusicId:)` so a
    /// song present in two sources resolves to the id the rest of the app uses.
    static func makeResolver(songs: [IndexSong]) async -> AppleMusicPlayCountCapture.Resolver {
        await Task.detached(priority: .utility) { () -> AppleMusicPlayCountCapture.Resolver in
            let byCatalogId = Dictionary(songs.compactMap { s in s.appleMusicId.map { ($0, s.id) } },
                                         uniquingKeysWith: { first, _ in first })
            let rows = songs.map { (songId: $0.id, title: $0.name, artist: $0.artist) }
            return AppleMusicPlayCountCapture.resolver(
                byCatalogId: byCatalogId,
                byTitleArtist: AppleMusicPlayCountCapture.titleArtistIndex(rows))
        }.value
    }

    // MARK: Run/audit persistence

    nonisolated static func defaultRunURL() -> URL { supportURL("pocketdj-am-playcount-run.json") }
    nonisolated static func defaultAuditURL() -> URL { supportURL("pocketdj-am-playcount-audit.json") }

    private nonisolated static func supportURL(_ name: String) -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(name)
    }

    /// Under UI tests, isolated + freshly cleared — a stale run would otherwise resume into a test.
    nonisolated static func launchRunURL() -> URL { launchURL(defaultRunURL(), "pdj-uitest-playcount-run.json") }
    nonisolated static func launchAuditURL() -> URL { launchURL(defaultAuditURL(), "pdj-uitest-playcount-audit.json") }

    private nonisolated static func launchURL(_ real: URL, _ name: String) -> URL {
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil else { return real }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    static func loadRun(from url: URL) -> AppleMusicPlayCountCapture.Run? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppleMusicPlayCountCapture.Run.self, from: data)
    }

    static func loadAudit(from url: URL) -> AppleMusicPlayCountCapture.Audit? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppleMusicPlayCountCapture.Audit.self, from: data)
    }

    /// The audit is a few hundred bytes — synchronous is right, and it keeps "what the UI shows"
    /// and "what is on disk" in lockstep at every checkpoint.
    static func saveAudit(_ audit: AppleMusicPlayCountCapture.Audit, to url: URL) {
        if let data = try? JSONEncoder().encode(audit) { try? data.write(to: url, options: .atomic) }
    }

    /// The run document carries the accumulator, so at 56k rows it is megabytes — encode + write
    /// it OFF the main actor, chained so two checkpoints can never interleave, and ATOMICALLY, so
    /// a kill at any instant leaves a whole valid document rather than a truncated one.
    private func saveRunSoon(_ run: AppleMusicPlayCountCapture.Run) {
        let url = runURL
        let prior = runWriteChain
        runWriteChain = Task.detached(priority: .utility) {
            await prior?.value
            if let data = try? JSONEncoder().encode(run) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Import the exporter's `playcounts.json` (or a previously saved snapshot).
    @discardableResult
    func importBaseline(from url: URL) throws -> Bool {
        try baseline.importFile(at: url)
    }

    @discardableResult
    func importBaseline(json data: Data) throws -> Bool {
        try baseline.importJSON(data)
    }

    /// Forget the incremental mark so the next capture re-reads the whole library. Non-destructive
    /// — the counts stay put. This is the way out of a bogus high-water mark (see
    /// `AppleMusicPlayCountCapture.Result.readNothing`).
    func resetHighWater() { baseline.resetHighWater() }

    /// Throw the Apple baseline away entirely. Destructive and irreversible for anything that
    /// can't be re-imported, so every caller must confirm first.
    ///
    /// The banked capture run goes with it: leaving a resumable run behind would let the next
    /// foreground silently re-checkpoint the counts the owner just asked to be gone.
    func forgetBaseline() {
        cancelCapture()
        baseline.clear()
        try? FileManager.default.removeItem(at: runURL)
        try? FileManager.default.removeItem(at: auditURL)
        lastCapture = nil
    }
}

/// Holds a UIKit background-task assertion for the lifetime of a capture run, so leaving the
/// foreground (lock, app switch, home swipe) grants a grace window instead of suspending the walk
/// mid-page. That window is what lets the run land a final checkpoint rather than losing
/// everything since the last one — the previous design took no assertion at all, is not a
/// registered BGTask, and gets nothing from the `audio` background mode with no audio rendering,
/// so backgrounding killed the whole walk. Ending twice is guarded; system expiration self-ends.
/// No-op off iOS (macOS does not suspend, and there is no `.background` phase to hook).
@MainActor
final class PlayCountBackgroundHold {
    #if canImport(UIKit) && !os(macOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #else
    init(_ name: String) {}
    func end() {}
    #endif
}
