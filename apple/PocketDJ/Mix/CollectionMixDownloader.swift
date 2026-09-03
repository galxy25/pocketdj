import Foundation

/// Collection download pipeline for the Mix tab (auto AND manual mixes): when the user picks a
/// COLLECTION to mix, pull its tracks onto the device asynchronously so the decks (which load
/// ONLY on-disk burned files — `MixResolver.isLoadable`) see more of the collection over time.
///
/// ORCHESTRATION ONLY — this type composes the EXISTING primitives and invents no downloader:
///   • `BurnStore.burn` is the download+persist funnel (in-process serial loop on macOS, background
///     `TransferCoordinator` URLSession tasks on iOS/iPadOS) with its own idempotency/freshness;
///   • `RipsStore.ripCollection` + the public manifest poll (the `CollectionRipBurnController`
///     cadence) turn not-yet-ripped songs into burnable ones as the server completes them;
///   • completion/byte telemetry rides two ADDITIVE hooks: `BurnStore.onAnyBurnFinalized` (a file
///     landed via the background path) and `TransferCoordinator.onBytes` (throttled chunk deltas).
///
/// The published surface drives the Mix screen's bottom progress bar: "N of M downloaded", an ETA
/// over the REMAINING manifest-ready tracks (assumed 256 kbps MP3 ⇒ 32 KB per playback-second,
/// divided by a 30 s rolling window of OBSERVED download throughput), and a separate "K ripping"
/// count — server rips are real-time capture, so a byte ETA over them would lie.
///
/// GRACEFUL DEGRADATION: the mix starts over whatever is already downloaded; each landing makes
/// the track eligible immediately — appended to a RUNNING auto-mix of this collection via the
/// existing `autoQueueInsert(.end)`, or, when the auto-mix already ended exhausted
/// (`MixEngine.autoEndedExhausted`), the mix is re-armed with the late arrivals. It never waits
/// for the whole collection and never feeds the decks an un-downloaded track.
///
/// App-scoped (created in `PocketDJApp` next to `MixEngine`, injected via environment): a mix
/// survives leaving the Mix tab, so its download run must too. Nothing here is persisted —
/// re-selecting the collection re-seeds from what's on disk (`begin` IS resume) and
/// `BurnStore.burn`'s freshness check skips finished files, so a relaunch loses nothing.
@MainActor @Observable
final class CollectionMixDownloader {

    // MARK: Published state (the progress bar reads exactly this)

    /// A download run is in flight (drives the bar's visibility together with the counts).
    private(set) var isActive = false
    /// The collection being downloaded (nil ⇒ idle).
    /// The active run's crates. One entry for every surface but the two-deck remote Mix
    /// (CarPlay/TV deck A + B), whose run tracks the UNION of both crates' tracks — the
    /// downloader has ONE burn lane and one progress bar regardless of how many crates feed it.
    private(set) var sources: [MixSource] = []
    /// Compat readout: the first (or only) crate of the active run.
    var source: MixSource? { sources.first }
    /// M — downloadable tracks in the collection (studio/profile items never download).
    private(set) var totalCount = 0
    /// N — tracks whose burned file is on disk.
    private(set) var downloadedCount = 0
    /// Tracks not yet in the rip manifest (server-side real-time capture; excluded from the ETA).
    private(set) var rippingCount = 0
    /// Estimated seconds until the remaining MANIFEST-READY tracks are downloaded; nil until the
    /// throughput window has at least one sample (the bar shows "—").
    private(set) var etaSeconds: Double?
    /// The downloaded subset, published progressively (the eligibility set).
    private(set) var downloadedIds: Set<String> = []

    // MARK: Tunables (test-dialable, mirroring CollectionRipBurnController)

    static var ripPollIntervalMs = 4500
    static var ripPollMaxTicks = 1600     // ~2 h at 4.5 s/tick — never polls forever
    static var idleWaitMs = 500           // burn-lane wait while a user burn owns the store

    /// 256 kbps MP3 ⇒ 32 KB of file per second of playback (the spec's bytes ≈ seconds × 32 KB).
    nonisolated static let bytesPerPlaybackSecond: Double = 32_768
    nonisolated static let fallbackTrackSeconds: Double = 180
    private static let fallbackDurationMs = 180_000

    // MARK: Rolling throughput window (pure — unit-testable with a scripted clock)

    /// 30-second rolling window of observed client download throughput: bytes landed per wall
    /// second, sampled as chunks (iOS `onBytes`) and files (both paths) complete.
    struct ThroughputWindow {
        nonisolated static let span: TimeInterval = 30
        private(set) var samples: [(t: TimeInterval, bytes: Int64)] = []

        mutating func add(bytes: Int64, at t: TimeInterval) {
            samples.append((t: t, bytes: bytes))
            prune(at: t)
        }
        private mutating func prune(at t: TimeInterval) {
            samples.removeAll { $0.t < t - Self.span }
        }
        /// Σ window bytes / actual elapsed span (capped at the window, floored at 1 s so a burst
        /// in the first instant doesn't claim infinite throughput). nil until a sample lands.
        mutating func bytesPerSecond(at t: TimeInterval) -> Double? {
            prune(at: t)
            guard let oldest = samples.first?.t else { return nil }
            let span = max(min(t - oldest, Self.span), 1.0)
            let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
            return Double(total) / span
        }
    }

    /// remaining playback-seconds → ETA seconds at the observed throughput. nil without a sample.
    nonisolated static func etaSeconds(remainingPlaybackSeconds: Double,
                                       bytesPerSecond: Double?) -> Double? {
        guard let bps = bytesPerSecond else { return nil }
        return remainingPlaybackSeconds * bytesPerPlaybackSecond / max(bps, 1)
    }

    /// The progress bar's ETA text: "3m 20s" / "45s", or "—" while the throughput window has no
    /// sample yet (nil). Pure so the bar's exact wording is unit-testable without a view.
    nonisolated static func etaLabel(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
        let t = Int(s.rounded())
        return t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }

    // MARK: Dependencies

    private let engine: MixEngine
    private let burns: BurnStore
    private let rips: RipsStore
    private let transfers: TransferCoordinator?

    /// Catalog/resolver seams, closure-injected like `MixEngine.studioResolve` (the app wires the
    /// real `CollectionsStore`/`MixResolver`; tests script them):
    /// the collection's downloadable song ids (rip funnel order — `CollectionsStore.ripIds`)…
    @ObservationIgnored var resolveRipIds: (@MainActor (MixSource) -> [String])?
    /// …the collection's currently LOADABLE tracks (`MixResolver.loadables(for:)`)…
    @ObservationIgnored var resolveLoadables: (@MainActor (MixSource) -> [MixLoadable])?
    /// …a song's catalog length in seconds (ETA input; manifest `durationMs` is the fallback)…
    @ObservationIgnored var songLengthSeconds: (@MainActor (String) -> Double?)?
    /// …and a song's display title/artist for `BurnStore.burn`'s item tuple.
    @ObservationIgnored var songTitleArtist: (@MainActor (String) -> (title: String, artist: String))?
    /// Injectable clock (tests script the rolling window).
    @ObservationIgnored var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    init(engine: MixEngine, burns: BurnStore, rips: RipsStore, transfers: TransferCoordinator?) {
        self.engine = engine
        self.burns = burns
        self.rips = rips
        self.transfers = transfers
    }

    // MARK: Run internals

    @ObservationIgnored private var orderedIds: [String] = []
    @ObservationIgnored private var trackedIds: Set<String> = []
    @ObservationIgnored private var window = ThroughputWindow()
    /// Serial burn lane (collection order, front-first so early tracks land first). The rip poll
    /// appends ids as their manifest entries flip ready.
    @ObservationIgnored private var burnQueue: [String] = []
    @ObservationIgnored private var driveTask: Task<Void, Never>?
    @ObservationIgnored private var ripPollTask: Task<Void, Never>?

    // Auto-mix continuation bookkeeping (armed by `noteAutoStarted`).
    @ObservationIgnored private var autoArmed = false
    /// The user pressed ▶/🔀 on a collection with NOTHING downloaded yet, so the engine's
    /// empty-queue guard meant no mix ever started. The FIRST landing starts it (the zero-start
    /// twin of the `autoEndedExhausted` pickup — "never stalls waiting for the whole collection").
    @ObservationIgnored private var autoStartPending = false
    /// `engine.deckGestureGeneration` at arm time: the zero-start pickup only fires while it is
    /// unmoved — any manual deck load/play after ▶ means the DJ took the decks by hand, and a
    /// background landing must never seize them (the exhausted pickup's twin guard lives in the
    /// engine: manual load/play clears `autoEndedExhausted`).
    @ObservationIgnored private var armGestureGeneration = 0
    /// Count of burn attempts that produced no file this run (field-telemetry cap counter).
    @ObservationIgnored private var burnMisses = 0
    /// One-shot: the drive loop's end-of-run second sweep over missed (state=error) tracks.
    @ObservationIgnored private var retriedMisses = false
    @ObservationIgnored private var initialAutoIds: Set<String> = []
    @ObservationIgnored private var appendedIds: Set<String> = []
    @ObservationIgnored private var autoLead: Double = 15
    @ObservationIgnored private var autoFade: Double = 3
    @ObservationIgnored private var autoLabel: String?

    // MARK: Begin / resume

    /// Start (or resume) downloading `source`'s tracks. Idempotent per source: calling again while
    /// the same source is active is a no-op; after a cancel/finish it re-seeds from disk (that IS
    /// the resume path — `BurnStore.burn` skips fresh files, background tasks reconcile at launch).
    /// A DIFFERENT source cancels the old run first (collection switch).
    func begin(source: MixSource) { begin(sources: [source]) }

    /// The multi-crate variant (two-deck remote Mix). Idempotent per source SET; a different
    /// set cancels the old run first. A song in more than one crate is tracked once.
    func begin(sources newSources: [MixSource]) {
        if isActive, self.sources == newSources { return }
        if isActive { cancel() }

        // Studio (`smp_`/`lp_`/`ptn_`/`tk_`) and profile (`pdj_`) items never download — they are
        // device-local by construction. Mirrors the ripIds funnel's own fences. Cross-crate
        // duplicates collapse to their first appearance.
        var seen = Set<String>()
        let ids = newSources.flatMap { resolveRipIds?($0) ?? [] }.filter {
            seen.insert($0).inserted
                && !StudioFactory.isStudioId($0) && !ProfileSourceStore.isProfileSongId($0)
        }
        self.sources = newSources
        burnMisses = 0
        retriedMisses = false
        orderedIds = ids
        trackedIds = Set(ids)
        totalCount = ids.count
        window = ThroughputWindow()
        etaSeconds = nil

        // ONE seed pass over the memoized resolver (never rescan on ticks — BurnStore hot-path
        // lesson): what's already on disk is downloaded; the remainder partitions into the burn
        // lane (manifest-ready) and the rip lane (needs the server's real-time capture).
        downloadedIds = Set(ids.filter { burns.localURL(forSong: $0) != nil })
        downloadedCount = downloadedIds.count
        let remainder = ids.filter { !downloadedIds.contains($0) }
        burnQueue = remainder.filter { rips.cachedURL($0) != nil }
        let needsRip = remainder.filter { rips.cachedURL($0) == nil }
        rippingCount = needsRip.count

        // Field diagnosability (Levi's live TV stall, "0 of 391" with no evidence trail): the
        // partition IS the diagnosis — cached-on-disk vs burn-lane vs rip-lane, plus whether the
        // manifest had even loaded. Telemetry-gated like every routine line.
        DiagLog.shared.telemetry(
            "mixdl", "begin sources=\(newSources.count) total=\(totalCount) onDisk=\(downloadedCount) burnQ=\(burnQueue.count) needsRip=\(needsRip.count) manifest=\(rips.manifest.count)")
        guard totalCount > 0, !remainder.isEmpty else {
            isActive = false        // nothing to do — everything is already on disk
            return
        }
        isActive = true
        installHooks()
        if !needsRip.isEmpty {
            ripPollTask = Task { [weak self] in await self?.ripAndPoll(needsRip) }
        }
        driveTask = Task { [weak self] in await self?.drive() }
    }

    /// Called when an auto-mix over this downloader's collection starts: seeds the append-dedupe
    /// sets (the queue already contains `initialIds`) and captures the mix parameters a later
    /// exhaustion re-arm must reuse. The engine API stays untouched — dedupe lives here.
    func noteAutoStarted(initialIds: Set<String>, lead: Double, fade: Double, label: String?) {
        autoArmed = true
        initialAutoIds = initialIds
        appendedIds = []
        autoLead = lead
        autoFade = fade
        autoLabel = label
        // ▶ on a collection with nothing downloaded yet: the engine's empty-queue guard means no
        // mix started — arm the FIRST landing to start it (the zero-start exhaustion twin).
        autoStartPending = initialIds.isEmpty && !engine.autoMixing
        armGestureGeneration = engine.deckGestureGeneration
    }

    // MARK: Cancel / leave

    /// Tear the run down (mirrors `CollectionRipBurnController.stop`): cancel the drive + poll
    /// tasks, stop the burn loop AND its in-flight background tasks, cancel the server-side jobs
    /// still queued for rip, and clear the published bar state. NEVER touches the engine — a
    /// running mix keeps playing whatever it already has.
    func cancel() {
        driveTask?.cancel(); driveTask = nil
        ripPollTask?.cancel(); ripPollTask = nil
        let pending = orderedIds.filter { !downloadedIds.contains($0) }
        if !pending.isEmpty {
            burns.requestStop()                       // stops the loop + in-flight background tasks
            transfers?.cancelAll(songIds: pending)
            let stillRipping = pending.filter { rips.cachedURL($0) == nil }
            if !stillRipping.isEmpty {
                let rips = self.rips
                Task { await rips.cancelCollection(stillRipping) }
            }
        }
        removeHooks()
        // A cancelled run must never surprise-start (or keep feeding) a mix later: kill the WHOLE
        // continuation arm, not just the pending zero-start — otherwise tab-leave-cancel followed
        // by re-picking the same collection restarts the old mix on a landing with no ▶ pressed.
        autoStartPending = false
        autoArmed = false
        initialAutoIds = []
        appendedIds = []
        autoLabel = nil
        isActive = false
        sources = []
        totalCount = 0
        downloadedCount = 0
        rippingCount = 0
        etaSeconds = nil
        downloadedIds = []
        orderedIds = []
        trackedIds = []
        burnQueue = []
        window = ThroughputWindow()
    }

    /// Mix-tab `.onDisappear` hook: cancel ONLY when no mix is running. A live mix (auto or
    /// manual decks) keeps its downloads feeding the queue across tab switches — this respects
    /// the tab's load-bearing no-teardown-on-disappear rule by touching only the downloader.
    func handleMixLeave(engineActive: Bool) {
        guard !engineActive else { return }
        cancel()
    }

    // MARK: Hooks (completion + byte telemetry)

    private func installHooks() {
        // File landed via the BACKGROUND path (`finalizeBurn` upserted the .ready item). Window
        // bytes for this path arrive via the chunk hook below — adding the whole file here too
        // would double-count throughput.
        burns.onAnyBurnFinalized = { [weak self] songId, _ in
            guard let self, self.isActive, self.trackedIds.contains(songId) else { return }
            self.noteDownloaded(songId)
        }
        // Chunk-level deltas (iOS, throttled ≥0.5 s per task in the coordinator) — a live ETA
        // between file completions.
        transfers?.onBytes = { [weak self] songId, delta in
            guard let self, self.isActive, self.trackedIds.contains(songId), delta > 0 else { return }
            self.window.add(bytes: delta, at: self.now())
            self.recomputeETA()
        }
    }

    private func removeHooks() {
        burns.onAnyBurnFinalized = nil
        transfers?.onBytes = nil
    }

    // MARK: Drive (serial burn lane)

    private func drive() async {
        while !Task.isCancelled {
            if let id = burnQueue.first {
                burnQueue.removeFirst()
                await burnOne(id)
            } else if ripPollTask != nil {
                // The rip lane is still flipping songs ready — idle-wait for it to feed the queue.
                try? await RipsStore.sleep(ms: Self.idleWaitMs)
            } else if !retriedMisses {
                // SECOND SWEEP: a presign-timeout victim stays state=error after its one serial
                // shot (TV field 2026-09-03: cold funnel paths ate the 12 s timeout while warm
                // retries flew). Re-run the misses once now that the lane is idle — structural
                // failures just error again and stand.
                retriedMisses = true
                let missed = orderedIds.filter { !downloadedIds.contains($0) && burns.items[$0]?.state == .error }
                if missed.isEmpty { break }
                DiagLog.shared.telemetry("mixdl", "re-queue \(missed.count) missed for a second sweep")
                burnQueue.append(contentsOf: missed)
            } else {
                break        // queue drained, no more rips coming, second sweep done
            }
        }
        driveTask = nil
    }

    private func burnOne(_ id: String) async {
        guard !downloadedIds.contains(id) else { return }
        // A USER-initiated collection burn owns the BurnStore serial loop (its `progress` +
        // `beginRun` counters assume ONE run) — wait for it rather than interleave.
        while burns.progress != nil {
            try? await RipsStore.sleep(ms: Self.idleWaitMs)
            if Task.isCancelled { return }
        }
        let meta = songTitleArtist?(id) ?? (title: id, artist: "")
        _ = await burns.burn([(id: id, title: meta.title, artist: meta.artist)])
        if Task.isCancelled { return }
        if burns.localURL(forSong: id) != nil {
            // IN-PROCESS completion (macOS / already-fresh): the await WAS the download — sample
            // the landed bytes. (Background path: localURL is still nil here; `finalizeBurn` →
            // `onAnyBurnFinalized` completes it later, with bytes sampled by the chunk hook.)
            let bytes = Int64(burns.items[id]?.bytes ?? 0)
            if bytes > 0 { window.add(bytes: bytes, at: now()) }
            noteDownloaded(id)
        } else {
            // Field diagnosability (the TV "0 of 391" hunt): a burn that produced no file is a
            // MISS whose error string names the failing step (presign / manifest / write). The
            // first five stream verbatim, then every 25th — enough to see the shape without
            // flooding a 375-track run.
            burnMisses += 1
            if burnMisses <= 5 || burnMisses % 25 == 0 {
                DiagLog.shared.log("error",
                    "mixdl burn MISS #\(burnMisses) \(id): \(burns.items[id]?.error ?? "no item recorded") state=\(burns.items[id]?.state.rawValue ?? "nil")")
            }
            recomputeETA()
        }
    }

    // MARK: Rip lane (enqueue once + manifest poll, CollectionRipBurnController cadence)

    private func ripAndPoll(_ ids: [String]) async {
        let rips = self.rips
        // `error` category streams immediately and does not need telemetry mode: a rip lane
        // that can't reach the server is exactly the fact a stalled field session must surface.
        if !rips.hasServer {
            DiagLog.shared.log("error", "mixdl rip lane: \(ids.count) tracks need rip but NO SERVER configured (settings.ripServerURL empty on this device)")
        } else {
            DiagLog.shared.telemetry("mixdl", "rip lane start ids=\(ids.count)")
        }
        _ = await rips.ripCollection(ids)
        if Task.isCancelled { return }
        var pending = Set(ids)
        var ticks = 0
        while !pending.isEmpty, ticks < Self.ripPollMaxTicks, !Task.isCancelled {
            ticks += 1
            try? await RipsStore.sleep(ms: Self.ripPollIntervalMs)
            if Task.isCancelled { return }
            await rips.refreshManifest()
            if Task.isCancelled { return }
            // Each id whose manifest entry flipped ready moves into the burn lane (order kept).
            for id in orderedIds where pending.contains(id) && rips.cachedURL(id) != nil {
                pending.remove(id)
                burnQueue.append(id)
            }
            recomputeETA()        // also refreshes rippingCount
        }
        ripPollTask = nil
    }

    // MARK: Landing → progress + progressive eligibility

    private func noteDownloaded(_ id: String) {
        guard isActive, trackedIds.contains(id), !downloadedIds.contains(id) else { return }
        downloadedIds.insert(id)
        downloadedCount = downloadedIds.count
        // First landing = the zero-start moment; then a breadcrumb every 25 so a stall's LAST
        // GOOD position is in the stream without flooding it.
        if downloadedCount == 1 || downloadedCount % 25 == 0 {
            DiagLog.shared.telemetry("mixdl", "landed \(downloadedCount)/\(totalCount) rip=\(rippingCount)")
        }
        recomputeETA()
        continueAutoMixIfArmed()
        if downloadedCount >= totalCount { finishRun() }
    }

    /// Progressive eligibility: a landing makes the track mixable NOW. If OUR auto-mix is running,
    /// append every newly-loadable track to the end of its queue (existing `autoQueueInsert`, which
    /// respects `autoNextToLoad`); if the mix already ended exhausted, re-arm it with the late
    /// arrivals so it continues instead of staying silent. Dedupe lives here (`appendedIds`) —
    /// the engine API is untouched.
    private func continueAutoMixIfArmed() {
        guard autoArmed, !sources.isEmpty, let resolve = resolveLoadables else { return }
        var seen = Set<String>()
        let fresh = sources.flatMap { resolve($0) }.filter {
            seen.insert($0.songId).inserted
                && !initialAutoIds.contains($0.songId) && !appendedIds.contains($0.songId)
        }
        guard !fresh.isEmpty else { return }
        if engine.autoMixing {
            autoStartPending = false                                    // a mix is running — nothing pending
            guard engine.autoSourceLabel == autoLabel else { return }   // someone else's mix
            for l in fresh {
                engine.autoQueueInsert(
                    MixEngine.AutoMixItem(loadable: l, durationMs: l.lengthMs ?? Self.fallbackDurationMs),
                    placement: .end)
                appendedIds.insert(l.songId)
            }
        } else if engine.autoEndedExhausted || autoStartPending {
            // A DJ hand-mixing owns the decks — a background landing must never seize them.
            // A playing deck (manual — `autoMixing` is false here) or any deck gesture since the
            // zero-start arm kills the pickup for good. (`autoEndedExhausted` needs no generation
            // check: the engine clears it on any manual load/play.)
            if engine.isRunning ||
                (autoStartPending && engine.deckGestureGeneration != armGestureGeneration) {
                autoStartPending = false
                return
            }
            autoStartPending = false
            for l in fresh { appendedIds.insert(l.songId) }
            engine.startAutoMix(
                fresh.map { MixEngine.AutoMixItem(loadable: $0, durationMs: $0.lengthMs ?? Self.fallbackDurationMs) },
                shuffled: false, lead: autoLead, fade: autoFade, label: autoLabel)
        }
    }

    private func finishRun() {
        driveTask?.cancel(); driveTask = nil
        ripPollTask?.cancel(); ripPollTask = nil
        burnQueue = []
        rippingCount = 0
        etaSeconds = nil
        removeHooks()
        isActive = false
    }

    // MARK: ETA

    /// Recompute the ETA over the remaining MANIFEST-READY tracks (rip-pending ids are excluded —
    /// they surface as `rippingCount` instead) using catalog length ?? manifest duration ?? 180 s.
    private func recomputeETA() {
        var remainingSeconds = 0.0
        var ripping = 0
        for id in orderedIds where !downloadedIds.contains(id) {
            guard rips.cachedURL(id) != nil else { ripping += 1; continue }
            let catalog = songLengthSeconds.flatMap { $0(id) }
            let manifest = (rips.manifest[id]?.durationMs).map { Double($0) / 1000 }
            remainingSeconds += catalog ?? manifest ?? Self.fallbackTrackSeconds
        }
        rippingCount = ripping
        etaSeconds = remainingSeconds > 0
            ? Self.etaSeconds(remainingPlaybackSeconds: remainingSeconds,
                              bytesPerSecond: window.bytesPerSecond(at: now()))
            : nil
    }

    // MARK: Test seams

    /// Script a file landing (the burn-finalized path) without a real download.
    func simulateLandingForTesting(_ id: String, bytes: Int64 = 0) {
        if bytes > 0 { window.add(bytes: bytes, at: now()) }
        noteDownloaded(id)
    }
    /// Feed the rolling window directly + recompute (ETA assertions with a scripted clock).
    func addThroughputSampleForTesting(bytes: Int64) {
        window.add(bytes: bytes, at: now())
        recomputeETA()
    }
    var burnQueueForTesting: [String] { burnQueue }
    var appendedIdsForTesting: Set<String> { appendedIds }
    var autoArmedForTesting: Bool { autoArmed }
    var autoStartPendingForTesting: Bool { autoStartPending }
    var initialAutoIdsForTesting: Set<String> { initialAutoIds }
    var autoLabelForTesting: String? { autoLabel }
}
