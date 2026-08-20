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

    /// WHEN was this song last played, by anything — the recency axis, and the companion to
    /// `combinedPlayCount`. Newest of Apple's stamp and this app's own; nil when neither knows.
    ///
    /// READ-ONLY IN BOTH DIRECTIONS. It reads `PlayStatsStore.lastPlayedAt` and it must never
    /// write it: that field is the storage manager's LRP eviction key, and seeding it from
    /// Apple's baseline (which reaches 56k songs against this app's ~700) would reshuffle the
    /// whole downloaded set — deleting files the owner never touched. `max` here, no store.
    ///
    /// `max` rather than "Apple wins": this app plays rips, stems, vinyl and Mix decks that Apple
    /// never sees, so for those songs the local stamp is the only true one — and for a song both
    /// know, the later stamp is the correct answer whichever side it came from.
    func lastPlayedAt(_ songId: String) -> Double? {
        guard !songId.isEmpty else { return nil }
        let apple = baseline.lastPlayed(songId)
        guard let local = stats.lastPlayedAt(songId) else { return apple }
        guard let apple else { return local }
        return max(apple, local)
    }

    /// Every song with a known last-played date, as a plain value map — the OFF-MAIN counterpart
    /// to `snapshot()`, taken on the main actor and read from a detached task.
    ///
    /// Sparse by construction: a song absent here has never been played by anything, which is
    /// the same convention `snapshot()` uses for a zero count (see `PlayRecency.score`).
    func lastPlayedSnapshot() -> [String: Double] {
        var out = baseline.lastPlayedSnapshot()
        for (id, ms) in stats.lastPlayedSnapshot() where ms > 0 {
            out[id] = max(out[id] ?? 0, ms)
        }
        return out
    }

    /// Does this device know ANY last-played dates? The round-level applicability question —
    /// distinct from "this song has never been played", which is an honest zero. A device with no
    /// Apple baseline and no local history cannot speak to recency at all, and consumers drop the
    /// term from their denominator rather than scoring every song zero on it.
    /// O(1): both sides are emptiness checks on maps already in memory, never a snapshot build —
    /// this is called once per round setup and per settings keystroke.
    var hasRecencyData: Bool { !baseline.isEmpty || !stats.stats.isEmpty }

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

    /// Record a SKIP (the SkipTracker verdict). Skips are device-local negative signal — no
    /// Apple bucket exists for them, so this is a plain pass-through to the aggregate store.
    func noteSkipped(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        stats.noteSkipped(songId, at: nowMs)
        ownRevision &+= 1
    }

    /// Every song with a non-zero lifetime skip count — the map the rec ranking's dampened
    /// skip penalty is computed from (pair of `snapshot()`).
    func skipCounts() -> [String: Int] { stats.skipCountsSnapshot() }

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

    /// Bumped whenever the run in flight is DISOWNED — `forgetBaseline`, or a re-read that throws
    /// the banked run away. `cancelCapture()` only marks the task cancelled and returns; the walk
    /// observes that at its next page boundary and then UNCONDITIONALLY lands a final checkpoint,
    /// which used to re-merge the counts, rewrite the baseline document `clear()` had just deleted
    /// and recreate the run document — so the "Forget these play counts" button, whose own
    /// confirmation says "There is no undo", silently didn't. A run whose generation is stale now
    /// writes nothing, anywhere.
    @ObservationIgnored private var captureGeneration: Int = 0

    /// The same idea for the run DOCUMENT's background writes: deleting the file bumps this, so a
    /// checkpoint's queued encode cannot land after the delete and resurrect a run the owner
    /// (or "Re-read everything") just discarded. Mirrors `AMPlayBaselineStore.writeGeneration`.
    @ObservationIgnored private var runWriteGeneration: Int = 0

    /// Test seams. The defaults are the real MusicKit pager and the real availability gate; the
    /// unit suite injects a FAKE walk it can interrupt, resume and re-run, which is the only way
    /// to prove any of this without a signed-in 96,000-song library.
    @ObservationIgnored var pagerFactory: @Sendable () -> any AppleMusicPlayCountCapture.LibraryPager = { MusicKitLibraryPager() }
    @ObservationIgnored var captureAvailable: () -> Bool = { AppleMusicPlayCountCapture.isAvailable }
    @ObservationIgnored var pageLimit = AppleMusicPlayCountCapture.defaultPageLimit
    @ObservationIgnored var checkpointRows = AppleMusicPlayCountCapture.defaultCheckpointRows
    /// Ceiling on the ADAPTIVE checkpoint interval. Set equal to `checkpointRows` to pin the
    /// interval, which is what the tests that assert exact checkpoint cursors do.
    @ObservationIgnored var maxCheckpointRows = AppleMusicPlayCountCapture.defaultMaxCheckpointRows

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
    /// MusicKit availability, on being in flight, and on the owner having deliberately cleared the
    /// baseline (otherwise "Forget these play counts" is undone by the next foreground).
    @discardableResult
    func autoCaptureIfNeverCaptured(songs: [IndexSong]) -> Bool {
        guard lastCapture?.clearedByOwnerMs == nil else { return false }
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
    ///
    /// It destroys state, so it must REFUSE FIRST. The guards used to sit inside `startCapture`,
    /// below the two destructive lines: a tap before the catalog finished loading (the Settings
    /// button is only disabled on MusicKit availability, not on an empty catalog) wiped the
    /// incremental mark, deleted a resumable run's banked cursor, started nothing, and made the
    /// button itself disappear — because it is rendered only while a mark exists.
    @discardableResult
    func recaptureEverything(songs: [IndexSong]) -> Bool {
        guard !isCapturing, !songs.isEmpty, captureAvailable() else { return false }
        baseline.resetHighWater()
        deleteRun()
        return startCapture(songs: songs, trigger: "full")
    }

    /// Stop the walk. The walk lands a final checkpoint on its way out, so this LOSES NOTHING —
    /// the next run continues from the cursor.
    func cancelCapture() { runTask?.cancel() }

    /// Delete the run document, and make sure no write already in flight can bring it back.
    private func deleteRun() {
        runWriteGeneration &+= 1
        try? FileManager.default.removeItem(at: runURL)
    }

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
        // Everything this run writes is stamped with the generation it started under, so a
        // `forgetBaseline()` part-way through orphans it instead of racing it.
        let generation = captureGeneration
        let hold = PlayCountBackgroundHold("pocketdj.playcount-capture") { [weak self] in
            // The background window is expiring. CANCEL rather than just ending the assertion:
            // the walk then lands a final checkpoint at its next page boundary, instead of being
            // suspended mid-interval and losing up to a whole interval to a later kill.
            self?.cancelCapture()
        }
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
        // How big the library turned out to be last time it was walked end to end — the
        // denominator "Songs read 12,000" needs to mean anything before the walk finishes.
        if run.libraryRowsEstimate == nil { run.libraryRowsEstimate = lastCapture?.libraryRowsEstimate }
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
                maxCheckpointRows: maxCheckpointRows,
                onProgress: { [weak self] audit in await self?.publishProgress(audit, generation: generation) },
                checkpoint: { [weak self] snapshot in await self?.checkpoint(snapshot, generation: generation) })
            await commit(finished, generation: generation)
        } catch {
            // The walk landed a final checkpoint carrying the cursor AND the reason on its way
            // out, so there is nothing to salvage here and nothing to report that the persisted
            // audit does not already say. The next run resumes.
        }
    }

    /// Per-PAGE progress. In-memory only — no disk, and `Audit` is an O(1) value struct, which is
    /// why this can run every page while `checkpoint` cannot.
    private func publishProgress(_ audit: AppleMusicPlayCountCapture.Audit, generation: Int) {
        guard generation == captureGeneration else { return }
        lastCapture = audit
    }

    /// ONE checkpoint: publish, persist, record. Everything here is idempotent.
    private func checkpoint(_ run: AppleMusicPlayCountCapture.Run, generation: Int) {
        // A run the owner has disowned (Forget, or a re-read that discarded it) writes NOTHING —
        // not the baseline, not the run document, not the audit.
        guard generation == captureGeneration else { return }
        // 1. THE BASELINE, first — a checkpoint Browse never sees is worth nothing. Monotone and
        //    idempotent (see `AMPlayBaselineStore.mergePartial`), and it hands over the WHOLE
        //    run-to-date accumulator rather than a delta, so a write that got coalesced away or
        //    lost to a kill is carried by the next checkpoint.
        if mayMergePartial(run) { baseline.mergePartial(run.counts) }
        // 2. Publish the audit NOW (the UI), and persist it BEHIND the run document (see
        //    `persistRunAndAudit`) so the numbers on screen can never outrun what is on disk.
        lastCapture = run.audit
        persistRunAndAudit(run)
    }

    /// May this checkpoint touch the BASELINE yet?
    ///
    /// `mergePartial` deliberately skips `replaceAll`'s all-zero and coverage guards — a partial
    /// is a fraction of the library by definition and those guards judge a whole snapshot. But
    /// that left a hole: a read the app itself classifies as broken (a full walk that finds 50 of
    /// the 200 songs already stored) had ALREADY raised those 50 rows by the time the commit
    /// refused it, so the baseline was changed while the owner was told "your existing numbers
    /// were kept", with no undo.
    ///
    /// The gate closes it without an undo log: a checkpoint may only touch the baseline when the
    /// run it belongs to CANNOT be refused at commit. Three cases, and two of them are free:
    ///
    ///   • INCREMENTAL walk — commits through `merged()`, which is a superset of what is stored,
    ///     so it can never lose coverage and can never be refused;
    ///   • FULL walk onto a baseline from ANOTHER source — `countsToStore` folds rather than
    ///     replaces, so likewise a superset, likewise unrefusable (this is the owner's imported
    ///     `library-xml` baseline, and the case the source-label fix in `commit` keeps true);
    ///   • FULL walk, same source — the only replacing commit, so it may preview only once it
    ///     already holds at least as many songs as the baseline does. That is exactly the
    ///     condition under which the coverage guard cannot fire (`kept ≥ existing` and
    ///     `kept ≥ added` give `2·kept ≥ existing + added`).
    ///
    /// The case that matters most is free: a FIRST capture runs against an empty baseline, so the
    /// gate is open from the first page — which is the owner's actual bug. A same-source full
    /// RE-read previews only near the end, and loses nothing by it: the counts are already on
    /// screen, and the run document checkpoints regardless, so a resume still costs nothing.
    private func mayMergePartial(_ run: AppleMusicPlayCountCapture.Run) -> Bool {
        guard run.isFullWalk else { return true }
        if !baseline.isEmpty, baseline.source != Self.musicKitSource { return true }
        return run.counts.count >= baseline.songCount
    }

    /// THE FINAL COMMIT. Every WHOLE-WALK decision happens here, exactly once, on a completed run:
    /// the broken-read verdict, the cross-source fold, the high-water mark, and the single
    /// provisional retirement over the union of everything the run observed. None of them may be
    /// made per checkpoint — see `AMPlayBaselineStore.mergePartial` for why each one would be
    /// actively harmful there.
    private func commit(_ run: AppleMusicPlayCountCapture.Run, generation: Int) async {
        guard generation == captureGeneration else { return }   // disowned mid-walk
        var final = run
        let result = run.result
        if result.readNothing {
            // A walk that LISTED rows and read nil for every count is BROKEN, not empty. No
            // counts, and above all NO high-water mark: a mark makes every later walk incremental,
            // so the install could never re-read the library it failed to read.
            final.stopReason = "Apple returned no play counts for the \(result.scanned) "
                + "song\(result.scanned == 1 ? "" : "s") it listed — nothing was changed. "
                + "Import a snapshot file instead."
            await finish(final, generation: generation)
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
        // DID IT FOLD onto a baseline from another source? Then the stored map is a MIXTURE whose
        // reach is that other source's, and re-labelling it "musickit" would be a one-way trap:
        // the next full walk would see the same source, REPLACE instead of fold, and delete the
        // rows only the other source could reach (measured on the owner's data: 9,560 songs /
        // 21,652 plays that no MusicKit walk can resolve). `nil` here means "leave the label
        // alone", so a mixed baseline keeps folding forever — the conservative direction, and the
        // one `countsToStore` already chose for the counts themselves.
        let folded = !existing.isEmpty && existingSource != nil && existingSource != Self.musicKitSource
        let applied = applyCapture(
            counts: counts, capturedAtMs: result.capturedAtMs,
            source: folded ? nil : Self.musicKitSource,
            sourceName: folded ? nil : Config.appleMusicSourceName,
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
        await finish(final, generation: generation)
    }

    /// Close the run out: mark it completed, publish + persist the audit, and drop the (large) run
    /// document. Awaits the write chain first so a queued checkpoint cannot resurrect it.
    private func finish(_ run: AppleMusicPlayCountCapture.Run, generation: Int) async {
        guard generation == captureGeneration else { return }
        var final = run
        final.completed = true
        final.updatedMs = Date().timeIntervalSince1970 * 1000
        await runWriteChain?.value
        guard generation == captureGeneration else { return }   // …and re-check after the await
        deleteRun()   // bumps the write generation, so a queued checkpoint cannot resurrect it
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
    ///
    /// The AUDIT rides the same task, deliberately AFTER the run document. It used to be written
    /// synchronously from `checkpoint`, which meant a kill in the window between the two left an
    /// audit claiming "row 45,000 · 12 checkpoints" while the run document on disk was a whole
    /// interval behind — the one number the owner reads was precisely the one not backed by disk.
    /// Behind, it can only ever UNDERSTATE, and understating is free: the resume re-reads from the
    /// run document's cursor and `mergePartial` is idempotent.
    ///
    /// Generation-stamped like `AMPlayBaselineStore.saveSoon`, so a delete (`deleteRun`) cannot be
    /// undone by a write that was already queued.
    private func persistRunAndAudit(_ run: AppleMusicPlayCountCapture.Run) {
        runWriteGeneration &+= 1
        let gen = runWriteGeneration
        let runURL = self.runURL, auditURL = self.auditURL
        let audit = run.audit
        let prior = runWriteChain
        runWriteChain = Task.detached(priority: .utility) { [weak self] in
            await prior?.value
            guard let data = try? JSONEncoder().encode(run) else { return }
            let auditData = try? JSONEncoder().encode(audit)
            await MainActor.run {
                guard let self, self.runWriteGeneration == gen else { return }   // superseded
                try? data.write(to: runURL, options: .atomic)
                if let auditData { try? auditData.write(to: auditURL, options: .atomic) }
            }
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
    ///
    /// DISOWNING the in-flight run is the load-bearing part, and it is not the same as cancelling
    /// it. `cancelCapture()` returns immediately; the walk notices at its next page boundary and
    /// then lands a final checkpoint unconditionally — which re-merged the counts, rewrote the
    /// baseline document `clear()` had just deleted, and recreated both the run and audit files.
    /// Bumping the generation orphans every write that run has left to make.
    func forgetBaseline() {
        captureGeneration &+= 1
        cancelCapture()
        baseline.clear()
        deleteRun()
        autoCaptureAttempted = true   // …for the rest of this launch
        // …and across relaunches, by RECORDING the clear rather than deleting the audit. Deleting
        // it left an empty baseline and no history, which is precisely the state the first-run
        // auto-capture exists to fix — so the next foreground rebuilt what the owner had just been
        // promised was gone for good.
        let nowMs = Date().timeIntervalSince1970 * 1000
        let cleared = AppleMusicPlayCountCapture.Audit(
            trigger: "forget", startedMs: nowMs, updatedMs: nowMs, completed: true,
            stopReason: "You cleared these play counts on this device.", clearedByOwnerMs: nowMs)
        lastCapture = cleared
        Self.saveAudit(cleared, to: auditURL)
    }
}

/// Holds a UIKit background-task assertion for the lifetime of a capture run, so leaving the
/// foreground (lock, app switch, home swipe) grants a grace window instead of suspending the walk
/// mid-page. That window is what lets the run land a final checkpoint rather than losing
/// everything since the last one — the previous design took no assertion at all, is not a
/// registered BGTask, and gets nothing from the `audio` background mode with no audio rendering,
/// so backgrounding killed the whole walk. Ending twice is guarded; system expiration self-ends.
/// No-op off iOS (macOS does not suspend, and there is no `.background` phase to hook).
///
/// `onExpire` fires FIRST when the system takes the window back. Without it, expiration only ended
/// the assertion and left the walk suspended part-way through an interval, so whatever it had
/// walked since its last checkpoint died with the process — "a home swipe lands a final
/// checkpoint" was luck (a checkpoint happening to fall inside the window), not a guarantee.
/// Cancelling makes it one: the walk stops at its next page boundary and checkpoints on the way
/// out, and the scene's `.background` flush lands the write.
@MainActor
final class PlayCountBackgroundHold {
    #if canImport(UIKit) && !os(macOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String, onExpire: (@MainActor () -> Void)? = nil) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire?()
                self?.end()
            }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #else
    init(_ name: String, onExpire: (@MainActor () -> Void)? = nil) {}
    func end() {}
    #endif
}
