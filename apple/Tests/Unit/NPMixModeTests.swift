import AVFoundation
import Observation
import XCTest
@testable import PocketDJ

/// np-mix-mode PHASE 2 — Now Playing MIX MODE: the toggle (session state), the buffer lane's plan
/// (network × source × window), the disk guard, the status chip, swap-on-land hand-off, durable
/// restore, Mix-tab suspension, toggle-off semantics, the media-services-reset hand-back, and the
/// review SHOULD: the buffer lane never cancels (and so never loses) an explicit Download.
///
///  • Planner / verdicts / indicator: pure tables.
///  • Executor: scripted fetch seams (no network).
///  • Sequencer: the REAL `SetlistPlayer` + coordinator over a scripted rip server
///    (`NPMixStub`: presign → an https S3 URL the AVPlayer streams), landings through the real
///    `BurnStore.adoptStreamedFile` (the buffer lane's adoption).
@MainActor
final class NPMixModeTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!
    private var savedFailDelay: Double = 0
    private var savedRunwayCap: Double = 25

    override func setUp() {
        super.setUp()
        NPMixStub.reset()
        // The scripted S3 URL never loads in AVFoundation: keep the failed-item advance out of the
        // way (the hand-off tests run long before it would fire on a real failure).
        savedFailDelay = PlayerEngine.itemFailedSignalDelay
        PlayerEngine.itemFailedSignalDelay = 600
        // The scripted S3 item can fail in AVFoundation before the test's simulated first audio
        // (which then never fires): let the start window close on its cap instead, quickly.
        savedRunwayCap = SetlistPlayer.startRunwayCapSeconds
        SetlistPlayer.startRunwayCapSeconds = 0.2
    }

    override func tearDown() {
        PlayerEngine.itemFailedSignalDelay = savedFailDelay
        SetlistPlayer.startRunwayCapSeconds = savedRunwayCap
        NowPlayingPrefetcher.blockedCooldown = 120
        NowPlayingPrefetcher.failureCooldown = 120
        super.tearDown()
    }

    // MARK: - Plan (pure)

    private typealias Track = NowPlayingPrefetcher.Track

    private func t(_ id: String, local: Bool = false, fetchable: Bool = true,
                   stems: Set<String> = [], remote: Bool = true) -> Track {
        .init(songId: id, audioId: id, title: id, artist: "A", songLocal: local, songFetchable: fetchable,
              stemsLocal: stems, stemsRemote: remote)
    }

    private func carry(muted: [String] = []) -> StemLockState {
        StemLockState(enabled: true, stemsOn: true, muted: muted.sorted(), volumes: [:])
    }

    private func input(current: Track?, upcoming: [Track], lock: StemLockState = StemLockState(),
                       mix: Bool = true, net: NowPlayingPrefetcher.Network = .unmetered, window: Int = 3,
                       cellular: NPMixCellularPolicy = .nextSong, partial: Bool = false,
                       wanted: Bool = false) -> NowPlayingPrefetchInput {
        NowPlayingPrefetchInput(current: current, upcoming: upcoming, stemLock: lock,
                                mixMode: NPMixModeState(enabled: mix), network: net, window: window,
                                stemLockWindow: 3, cellular: cellular, currentStemsPartial: partial,
                                currentStemsWanted: wanted)
    }

    private func names(_ p: NowPlayingPrefetcher.Plan) -> [String] { p.steps.map(\.description) }

    /// MIX MODE OFF ⇒ byte-for-byte today's Stem Lock plan, across every network, carry and
    /// current-track shape (the regression contract of §2.2).
    func testMixModeOffIsExactlyTheStemLockPlan() {
        let ups: [[Track]] = [
            [t("n1"), t("n2"), t("n3"), t("n4")],
            [t("n1", remote: false), t("n2", local: true, stems: ["vocals"]), t("n3", fetchable: false)],
            [],
        ]
        let carries = [StemLockState(), StemLockState(enabled: true, stemsOn: false), carry(), carry(muted: ["bass", "other"])]
        let currents: [Track?] = [nil, t("cur", local: true, stems: ["vocals"])]
        for net in [NowPlayingPrefetcher.Network.unmetered, .expensive, .constrained, .offline] {
            for up in ups { for c in carries { for cur in currents { for partial in [false, true] {
                let legacy = NowPlayingPrefetcher.plan(current: partial ? cur : nil, upcoming: up, carry: c,
                                                       network: net, window: 3)
                let now = NowPlayingPrefetcher.plan(input(current: cur, upcoming: up, lock: c, mix: false,
                                                          net: net, partial: partial))
                XCTAssertEqual(now, legacy, "net=\(net) carry=\(c.logSummary) partial=\(partial)")
            } } } }
        }
    }

    /// Wi-Fi: the CURRENT ripped stream's song first (so it can hand off), its stems, then each of
    /// the next 3 rows song-then-stems (vocals → drums → other → bass). Row 4 is outside.
    func testWifiBuffersCurrentThenEachRowSongThenAllStems() {
        let p = NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: [t("n1"), t("n2"), t("n3"), t("n4")]))
        XCTAssertEqual(names(p), [
            "song:cur", "vocals:cur", "drums:cur", "other:cur", "bass:cur",
            "song:n1", "vocals:n1", "drums:n1", "other:n1", "bass:n1",
            "song:n2", "vocals:n2", "drums:n2", "other:n2", "bass:n2",
            "song:n3", "vocals:n3", "drums:n3", "other:n3", "bass:n3",
        ])
    }

    /// With the Stem Lock carrying a set: enabled parts in the row's turn, MUTED parts last.
    func testWifiWithLockFetchesEnabledPartsAndMutedLast() {
        let p = NowPlayingPrefetcher.plan(input(current: t("cur", local: true), upcoming: [t("n1")],
                                                lock: carry(muted: ["bass"])))
        XCTAssertEqual(names(p), ["vocals:cur", "drums:cur", "other:cur", "song:n1", "vocals:n1", "drums:n1",
                                  "other:n1", "bass:cur", "bass:n1"])
    }

    /// Local rows fetch only their missing stems; a row whose audio can never be local (Apple
    /// Music only / not ripped) is skipped whole; a row with no stems anywhere gets its song only.
    func testLocalRowsOnlyFetchMissingStemsAndUnfetchableRowsAreSkipped() {
        let p = NowPlayingPrefetcher.plan(input(
            current: t("cur", local: true, stems: Set(StemLock.partPriority)),
            upcoming: [t("am", fetchable: false), t("n2", local: true, stems: ["vocals", "drums"]), t("n3", remote: false)]))
        XCTAssertEqual(names(p), ["other:n2", "bass:n2", "song:n3"])
        // The playing row on Apple Music (not fetchable, not local) is skipped too.
        let am = NowPlayingPrefetcher.plan(input(current: t("cur", fetchable: false), upcoming: [t("n1", remote: false)]))
        XCTAssertEqual(names(am), ["song:n1"])
    }

    /// Cellular (default policy): the current row + the NEXT song only, no speculative stems; the
    /// current row's stems only when asked for; the next row only the lock's enabled parts.
    func testCellularNextSongOnlyStemsOnRequest() {
        let up = [t("n1"), t("n2")]
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .expensive))),
                       ["song:cur", "song:n1"])
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .expensive, wanted: true))),
                       ["song:cur", "vocals:cur", "drums:cur", "other:cur", "bass:cur", "song:n1"],
                       "Stems on for the playing track ⇒ its stems")
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, lock: carry(muted: ["other"]),
                                                             net: .expensive))),
                       ["song:cur", "vocals:cur", "drums:cur", "bass:cur", "song:n1", "vocals:n1", "drums:n1", "bass:n1",
                        "other:cur", "other:n1"],
                       "the lock's set on the current + next rows, muted parts last")
    }

    /// Cellular policy Off ⇒ Mix Mode adds nothing (the lock's own plan stays); Full ⇒ like Wi-Fi.
    func testCellularOffAndFullPolicies() {
        let up = [t("n1"), t("n2")]
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .expensive, cellular: .off)).steps.isEmpty)
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .expensive, cellular: .full)),
                       NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .unmetered)))
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, lock: carry(), net: .expensive, cellular: .off)),
                       NowPlayingPrefetcher.plan(current: nil, upcoming: up, carry: carry(), network: .expensive, window: 3),
                       "Off = exactly the Stem Lock")
    }

    /// Low Data Mode: the current row only, no stems — but a Stem Lock still gets its next
    /// song + enabled stems (Mix Mode never fetches LESS than the lock alone).
    func testLowDataCurrentOnlyButLockStillGetsItsNextTrack() {
        let up = [t("n1"), t("n2")]
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, net: .constrained))), ["song:cur"])
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: up, lock: carry(muted: ["bass"]),
                                                             net: .constrained))),
                       ["song:cur", "song:n1", "vocals:n1", "drums:n1", "other:n1"])
    }

    func testOfflinePlansNothing() {
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(current: t("cur"), upcoming: [t("n1")], lock: carry(), net: .offline)).steps.isEmpty)
    }

    /// The Wi-Fi window follows the setting (1 / 5); a song repeated in the window is planned once.
    func testWindowSizesAndDuplicateRows() {
        let up = (1...6).map { t("n\($0)", remote: false) }
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: nil, upcoming: up, window: 1))), ["song:n1"])
        XCTAssertEqual(names(NowPlayingPrefetcher.plan(input(current: nil, upcoming: up, window: 5))),
                       ["song:n1", "song:n2", "song:n3", "song:n4", "song:n5"])
        let dup = NowPlayingPrefetcher.plan(input(current: t("x", remote: false), upcoming: [t("x", remote: false), t("y", remote: false)]))
        XCTAssertEqual(names(dup), ["song:x", "song:y"])
    }

    func testMixReachTable() {
        XCTAssertNil(NowPlayingPrefetcher.mixReach(network: .offline, cellular: .full, window: 3))
        XCTAssertNil(NowPlayingPrefetcher.mixReach(network: .expensive, cellular: .off, window: 3))
        XCTAssertEqual(NowPlayingPrefetcher.mixReach(network: .unmetered, cellular: .off, window: 10)?.ahead, 10)
        XCTAssertEqual(NowPlayingPrefetcher.mixReach(network: .expensive, cellular: .nextSong, window: 10)?.ahead, 1)
        XCTAssertEqual(NowPlayingPrefetcher.mixReach(network: .constrained, cellular: .full, window: 10)?.ahead, 0)
    }

    // MARK: - Disk verdict (pure)

    func testDiskVerdict() {
        let gb = 1_000_000_000, step = NowPlayingPrefetcher.estimatedStepBytes
        XCTAssertEqual(NowPlayingPrefetcher.diskVerdict(freeBytes: 50 * gb, footprint: 0, capBytes: 2 * gb), .ok)
        XCTAssertEqual(NowPlayingPrefetcher.diskVerdict(freeBytes: 50 * gb, footprint: 2 * gb, capBytes: 2 * gb),
                       .evict(step), "at the cap: free one step's worth")
        XCTAssertEqual(NowPlayingPrefetcher.diskVerdict(freeBytes: gb, footprint: 0, capBytes: 2 * gb),
                       .evict(step), "the 1 GB floor holds AFTER the step")
        XCTAssertEqual(NowPlayingPrefetcher.diskVerdict(freeBytes: gb / 2, footprint: 3 * gb, capBytes: 2 * gb),
                       .evict(gb + step), "the larger shortfall wins")
        XCTAssertEqual(NowPlayingPrefetcher.diskVerdict(freeBytes: nil, footprint: 0, capBytes: 2 * gb), .ok,
                       "an unreadable volume only checks the cap")
    }

    // MARK: - Indicator (pure)

    private func ind(_ mut: (inout NPMixMode.IndicatorInput) -> Void) -> NPMixMode.Indicator {
        var i = NPMixMode.IndicatorInput(enabled: true, running: true, held: false, mixTabLive: false,
                                         engaged: false, stemsLoading: false, mixable: false,
                                         onAppleMusic: false, live: false, offline: false, ripped: true,
                                         deviceMode: false, bufferFraction: nil, buffering: false,
                                         failed: false, storageFull: false)
        mut(&i)
        return NPMixMode.indicator(i)
    }

    func testIndicatorTable() {
        XCTAssertEqual(ind { $0.enabled = false; $0.mixable = true }, .off)
        XCTAssertEqual(ind { $0.running = false }, .off)
        XCTAssertEqual(ind { $0.held = true; $0.mixable = true }, .waiting)
        XCTAssertEqual(ind { $0.mixTabLive = true; $0.engaged = true }, .suspended)
        XCTAssertEqual(ind { $0.engaged = true }, .engaged)
        XCTAssertEqual(ind { $0.engaged = true; $0.stemsLoading = true }, .stemsLoading)
        XCTAssertEqual(ind { $0.mixable = true }, .ready)
        XCTAssertEqual(ind { $0.onAppleMusic = true }, .unavailable("Apple Music only"), "phase 2 never rips / hands off AM")
        XCTAssertEqual(ind { $0.live = true }, .unavailable("Live capture"))
        XCTAssertEqual(ind { $0.buffering = true; $0.bufferFraction = 0.42 }, .buffering(0.42))
        XCTAssertEqual(ind { $0.failed = true }, .unavailable("Download failed"))
        XCTAssertEqual(ind { $0.storageFull = true; $0.buffering = true }, .unavailable("Storage full"))
        XCTAssertEqual(ind { $0.offline = true }, .unavailable("Offline"))
        XCTAssertEqual(ind { $0.ripped = false }, .unavailable("Not ripped"))
        XCTAssertEqual(ind { $0.cellularOff = true }, .unavailable("Cellular — buffering off"))
        XCTAssertEqual(ind { $0.deviceMode = true }, .unavailable("Device mode — downloads only"))
        XCTAssertEqual(NPMixMode.Indicator.buffering(0.429).chipText, "Buffering 42%")
        XCTAssertEqual(NPMixMode.Indicator.buffering(nil).chipText, "Buffering…")
        XCTAssertNil(NPMixMode.Indicator.off.chipText)
        XCTAssertTrue(NPMixMode.Indicator.ready.controlsLive)
        XCTAssertFalse(NPMixMode.Indicator.buffering(0.5).controlsLive)
    }

    // MARK: - Executor: the disk guard

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    /// A step the guard refuses is SKIPPED (reported not-ok, never started) and not retried within
    /// the cooldown; the next step runs; the refused song reads "Storage full".
    func testDiskGuardRefusalSkipsTheStepAndCoolsDown() async {
        let pf = NowPlayingPrefetcher()
        var started: [String] = []
        var finished: [(String, Bool)] = []
        pf.fetchSong = { step in started.append(step.description); return true }
        pf.diskGuard = { step in step.description != "song:big" }
        pf.onStepFinished = { finished.append(($0.description, $1)) }
        let plan = NowPlayingPrefetcher.plan(input(current: nil, upcoming: [t("big", remote: false), t("ok", remote: false)]))
        pf.apply(plan)
        await waitUntil("lane drained") { pf.isIdle && finished.count == 2 }
        XCTAssertEqual(started, ["song:ok"])
        XCTAssertEqual(finished.map(\.0), ["song:big", "song:ok"])
        XCTAssertEqual(finished.map(\.1), [false, true])
        XCTAssertTrue(pf.songBlockedRecently("big"))
        XCTAssertFalse(pf.songFailedRecently("big"))
        // A re-plan inside the cooldown (`ok` is local by now — only `big` is still wanted).
        pf.apply(NowPlayingPrefetcher.plan(input(current: nil, upcoming: [t("big", remote: false)])))
        XCTAssertTrue(pf.isIdle, "the refused step waits out its cooldown")
        XCTAssertEqual(started, ["song:ok"])
    }

    /// A re-plan that drops the step while its guard is still deciding: the stale worker claims
    /// nothing — no fetch, no finish report, no cooldown.
    func testCancelDuringDiskGuardClaimsNothing() async {
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        var fetched = 0, finished = 0
        pf.fetchSong = { _ in fetched += 1; return true }
        pf.diskGuard = { _ in await withCheckedContinuation { gate = $0 } }
        pf.onStepFinished = { _, _ in finished += 1 }
        pf.apply(NowPlayingPrefetcher.plan(input(current: nil, upcoming: [t("a", remote: false)])))
        await waitUntil("guard running") { gate != nil }
        pf.cancelAll()
        gate?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(finished, 0)
        XCTAssertFalse(pf.songBlockedRecently("a"))
        XCTAssertTrue(pf.isIdle)
    }

    // MARK: - Settings + snapshot

    func testMixModeSettingsDefaultsPersistAndOldBlobsDecode() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.npMixBufferAheadEffective, 3)
        XCTAssertEqual(s.npMixCellularPolicy, .nextSong)
        XCTAssertNil(s.npMixModeDefaultOn, "Q4: new sessions start with Mix Mode OFF")
        s.npMixBufferAhead = 5
        s.npMixCellular = NPMixCellularPolicy.full.rawValue
        s.npMixModeDefaultOn = true
        s.persist()
        let again = SettingsStore(defaults: defaults)
        XCTAssertEqual(again.npMixBufferAheadEffective, 5)
        XCTAssertEqual(again.npMixCellularPolicy, .full)
        XCTAssertEqual(again.npMixModeDefaultOn, true)
        again.npMixCellular = "warp-drive"                         // a newer build's value
        XCTAssertEqual(again.npMixCellularPolicy, .nextSong)
        again.npMixBufferAhead = 99
        XCTAssertEqual(again.npMixBufferAheadEffective, 10, "clamped to the picker's max")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsData.default)) as? [String: Any])
        for k in ["npMixBufferAhead", "npMixCellular", "npMixModeDefaultOn"] { obj[k] = nil }
        let old = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.npMixBufferAhead)
        XCTAssertNil(old.npMixModeDefaultOn)
    }

    func testSnapshotCarriesMixModeAndOldSnapshotsDecode() throws {
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_m", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "s1", title: "S1", artist: "A", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 0, isPlaying: false, npMixMode: NPMixModeState(enabled: true), updatedAt: 0)
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: data).npMixMode,
                       NPMixModeState(enabled: true))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["npMixMode"] = nil
        let old = try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.npMixMode, "a pre-Mix-Mode snapshot restores with Mix Mode off")
    }

    // MARK: - Explicit downloads survive the buffer lane (review SHOULD)

    private func makeTransfers() -> TransferCoordinator {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-xfer-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TransferCoordinator(fileURL: url, realSession: false)
    }

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NPMixStub.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://server.test"
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func burnStore(_ rips: RipsStore, items: [BurnStore.BurnItem] = [],
                           transfers: TransferCoordinator? = nil) throws -> BurnStore {
        let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-index-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: indexURL) }
        try JSONEncoder().encode(BurnStore.Document(items: items)).write(to: indexURL)
        let burns = BurnStore(rips: rips, transfers: transfers, fileURL: indexURL)
        burns.appBurnsDirOverride = tempDir("burns")
        return burns
    }

    private func downloadingItem(_ id: String) -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: id, artist: "A", audioFileName: "\(id).mp3", sidecarFileName: "\(id).txt",
                           source: "digital", bpm: nil, musicalKey: nil, camelot: nil, durationMs: nil, startMs: nil,
                           bytes: 0, rippedAt: nil, downloadedAt: 1, state: .downloading, error: nil, wasAppStorage: true)
    }

    /// The user's explicit background Download of `d1` is pending on the iOS transfer lane. The
    /// buffer lane must NOT stream it: opening would cancel the download (`yieldBackgroundDownload`)
    /// and a stream that then failed lost it silently. The download stays queued; a Mix deck's
    /// EXPLICIT open still takes it over (it carries the explicit origin — unchanged behaviour).
    func testBufferLaneNeverCancelsAPendingExplicitDownload() throws {
        let rips = makeRips()
        rips.setManifest(["d1": .init(key: "rips/d1.mp3", source: "digital"), "d2": .init(key: "rips/d2.mp3", source: "digital")])
        let burns = try burnStore(rips, items: [downloadingItem("d1"), downloadingItem("d2")], transfers: makeTransfers())
        let loader = MixStreamLoader(rips: rips, burns: burns, directory: tempDir("ms"))
        XCTAssertTrue(burns.hasPendingExplicitDownload(songId: "d1"))

        XCTAssertNil(loader.open("d1", title: "d1", artist: "A", origin: .buffer), "the buffer lane stands down")
        XCTAssertEqual(burns.items["d1"]?.state, .downloading, "the explicit download is untouched")
        XCTAssertNil(loader.stream(for: "d1"))

        // A failed buffer stream can therefore never be what loses it: nothing was cancelled.
        loader.failStreamForTesting("d1")
        XCTAssertEqual(burns.items["d1"]?.state, .downloading)

        let s = loader.open("d2", title: "d2", artist: "A")       // a Mix deck (explicit)
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.origin.isExplicit ?? false, "an explicit takeover keeps the download explicit")
    }

    /// The lane WAITS on the explicit download instead (true once it lands; false on an error,
    /// a vanished row, or the timeout — the download carries on regardless).
    func testAwaitPendingDownload() async {
        var state: BurnStore.State? = .downloading
        let landed = Task { @MainActor in
            await NowPlayingPrefetcher.awaitPendingDownload(state: { state }, timeout: 5, pollNanos: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        state = .ready
        let ok = await landed.value
        XCTAssertTrue(ok)
        state = .error
        let failed = await NowPlayingPrefetcher.awaitPendingDownload(state: { state }, timeout: 5, pollNanos: 5_000_000)
        XCTAssertFalse(failed)
        state = .downloading
        let timedOut = await NowPlayingPrefetcher.awaitPendingDownload(state: { state }, timeout: 0.05, pollNanos: 5_000_000)
        XCTAssertFalse(timedOut)
    }

    /// The production lane's song fetch, end to end: an explicit download pending ⇒ no stream is
    /// opened, the step resolves when the download lands.
    func testLiveLaneWaitsOnTheExplicitDownloadAndNeverStreamsIt() async throws {
        let rips = makeRips()
        rips.setManifest(["d1": .init(key: "rips/d1.mp3", source: "digital")])
        let burns = try burnStore(rips, items: [downloadingItem("d1")], transfers: makeTransfers())
        let loader = MixStreamLoader(rips: rips, burns: burns, directory: tempDir("ms"))
        let lane = NowPlayingPrefetcher.live(streamer: loader, burns: burns, rips: rips, isCatalogOwner: { false })
        NowPlayingPrefetcher.pendingDownloadWaitSeconds = 0.2
        defer { NowPlayingPrefetcher.pendingDownloadWaitSeconds = 90 }
        let ok = await lane.fetchSong(.song(id: "d1", title: "d1", artist: "A"))
        XCTAssertFalse(ok, "not landed within the wait")
        XCTAssertNil(loader.stream(for: "d1"), "never streamed")
        XCTAssertEqual(burns.items["d1"]?.state, .downloading, "never cancelled")
    }

    // MARK: - Storage: the disk guard admits after evicting the soonest unprotected buffer

    private func storage(_ burns: BurnStore) -> (StorageManager, SettingsStore) {
        let statsURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-stats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: statsURL) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        burns.settings = settings
        return (StorageManager(burns: burns, playStats: PlayStatsStore(fileURL: statsURL), settings: settings), settings)
    }

    private func readyItem(_ id: String) -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: id, artist: "A", audioFileName: "\(id).mp3", sidecarFileName: "\(id).txt",
                           source: "digital", bpm: nil, musicalKey: nil, camelot: nil, durationMs: nil, startMs: nil,
                           bytes: 10, rippedAt: nil, downloadedAt: 1, state: .ready, error: nil, wasAppStorage: true)
    }

    private func hold(_ id: String, expiresInHours h: Double, bytes: Int) -> BurnStore.TemporaryHold {
        let now = Date().timeIntervalSince1970 * 1000
        return BurnStore.TemporaryHold(songId: id, audio: true, stemParts: [], createdAtMs: now,
                                       expiresAtMs: now + h * 3_600_000, audioBytes: bytes, stemBytes: [:])
    }

    func testAdmitBufferStepEvictsSoonestUnprotectedThenAdmits() async throws {
        let burns = try burnStore(RipsStore(), items: [readyItem("a"), readyItem("b"), readyItem("c")])
        let (mgr, settings) = storage(burns)
        settings.npMixBufferCapGB = 1
        let mb600 = 600_000_000
        burns.injectHoldForTesting(hold("a", expiresInHours: 30, bytes: mb600))
        burns.injectHoldForTesting(hold("b", expiresInHours: 10, bytes: mb600))   // soonest
        mgr.freeBytesProvider = { 50_000_000_000 }
        mgr.protectedSongIds = { [] }
        let ok = await mgr.admitBufferStep("song:c")
        XCTAssertTrue(ok)
        XCTAssertNil(burns.temporaryHolds["b"], "soonest expiry evicted")
        XCTAssertNotNil(burns.temporaryHolds["a"], "…and no more than needed")
        // Plenty of room: nothing touched.
        let again = await mgr.admitBufferStep("song:d")
        XCTAssertTrue(again)
        XCTAssertNotNil(burns.temporaryHolds["a"])
    }

    func testAdmitBufferStepRefusesWhenOnlyProtectedBufferRemains() async throws {
        let burns = try burnStore(RipsStore(), items: [readyItem("a")])
        let (mgr, settings) = storage(burns)
        settings.npMixBufferCapGB = 0.5
        burns.injectHoldForTesting(hold("a", expiresInHours: 10, bytes: 600_000_000))
        mgr.freeBytesProvider = { 50_000_000_000 }
        mgr.protectedSongIds = { ["a"] }                 // it's playing
        let ok = await mgr.admitBufferStep("song:z")
        XCTAssertFalse(ok, "over the cap with nothing evictable ⇒ the step is skipped")
        XCTAssertNotNil(burns.temporaryHolds["a"], "the playing song is never evicted")
        // Free space short and NO temporary assets at all: refused without a sweep.
        let empty = try burnStore(RipsStore())
        let (mgr2, _) = storage(empty)
        mgr2.freeBytesProvider = { 200_000_000 }
        let ok2 = await mgr2.admitBufferStep("song:z")
        XCTAssertFalse(ok2)
    }

    // MARK: - Sequencer

    private struct Rig {
        let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
        let coord: PlaybackCoordinator; let seq: SetlistPlayer
    }

    private func makeRig(manifest: [String: RipsStore.ManifestEntry], items: [BurnStore.BurnItem] = [],
                         transfers: TransferCoordinator? = nil) throws -> Rig {
        let rips = makeRips()
        rips.setManifest(manifest)
        let burns = try burnStore(rips, items: items, transfers: transfers)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        addTeardownBlock { @MainActor in seq.stop() }
        return Rig(rips: rips, burns: burns, player: player, coord: coord, seq: seq)
    }

    private func digital(_ ids: [String]) -> [String: RipsStore.ManifestEntry] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, RipsStore.ManifestEntry(key: "rips/\($0).mp3", source: "digital")) })
    }

    private func item(_ id: String, lengthMs: Int? = 240_000) -> SetlistPlayer.Item {
        .init(id: id, title: id, artist: "A", lengthMs: lengthMs)
    }

    /// Start `ids` and wait for row 0 to be STREAMING from its presigned URL (first audio heard,
    /// so the start window is closed — a real stream would have rendered by now).
    private func startStreaming(_ r: Rig, _ ids: [String]) async {
        r.seq.play(ids.map { item($0) })
        await waitUntil("\(ids[0]) streaming") {
            r.rips.nowPlaying?.songId == ids[0] && r.rips.nowPlaying?.url.isFileURL == false
        }
        r.player.simulateFirstAudioForTesting()
        await waitUntil("start window closed") { !r.seq.isStartPending }
    }

    /// The buffer lane's adoption: a finished `.buffer` stream lands as a TEMPORARY burn.
    private func land(_ r: Rig, _ id: String, bytes: Int = 4096) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-land-\(UUID().uuidString).mp3")
        try? Data(repeating: 9, count: bytes).write(to: tmp)
        XCTAssertNotNil(r.burns.adoptStreamedFile(songId: id, title: id, artist: "A", from: tmp, origin: .buffer))
        XCTAssertTrue(r.burns.isTemporary(id), "precondition: a temporary buffer burn")
    }

    /// Mix Mode is SESSION state (Q4): needs a running session, persists, a new session clears it
    /// unless "Start new sessions in Mix Mode" is on, and `stop()` ends it.
    func testMixModeIsSessionScoped() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        r.seq.setMixMode(true)
        XCTAssertFalse(r.seq.mixMode.enabled, "no session ⇒ no-op")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        r.seq.sessionStore = store
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        XCTAssertTrue(r.seq.mixMode.enabled)
        XCTAssertNotEqual(r.seq.mixModeIndicator, .off)
        r.seq.flushSessionSnapshotNow(); store.flush()
        XCTAssertEqual(store.load()?.npMixMode, NPMixModeState(enabled: true), "persisted on toggle")

        r.seq.play([item("b")])
        XCTAssertFalse(r.seq.mixMode.enabled, "a new session starts with Mix Mode OFF")
        r.seq.mixModeSettings = { (3, .nextSong, true) }
        r.seq.play([item("a")])
        XCTAssertTrue(r.seq.mixMode.enabled, "…unless new sessions start in Mix Mode")
        r.seq.stop()
        XCTAssertFalse(r.seq.mixMode.enabled, "stop ends the session — and its Mix Mode")
        XCTAssertEqual(r.seq.mixModeIndicator, .off)
    }

    /// Mix Mode ON over a streaming set plans the current row + the upcoming rows; OFF cancels the
    /// Mix steps at once (nothing else was asked for), and ON again re-plans.
    func testToggleDrivesTheLaneAndOffCancelsMixSteps() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c"]))
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        pf.fetchSong = { _ in await withCheckedContinuation { gate = $0 } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        await startStreaming(r, ["a", "b", "c"])
        XCTAssertTrue(pf.isIdle, "Mix Mode off, no lock: nothing speculative")
        r.seq.setMixMode(true)
        await waitUntil("the current row's song in flight") { pf.inFlight?.description == "song:a" }
        XCTAssertEqual(pf.pending.map(\.description), ["song:b", "song:c"])
        XCTAssertEqual(r.seq.mixModeIndicator, .buffering(nil))
        XCTAssertEqual(r.seq.mixModeBufferStrip().map(\.dot), [.queued, .queued])
        r.seq.setMixMode(false)
        XCTAssertTrue(pf.isIdle, "OFF: the Mix Mode steps leave the lane immediately")
        gate?.resume(returning: false)
        XCTAssertEqual(r.seq.mixModeIndicator, .off)
    }

    /// An UPCOMING row whose explicit Download is already pending is left to that download (no
    /// stream that would cancel it, no wait that would stall the rows behind it).
    func testUpcomingRowWithAPendingExplicitDownloadIsLeftToIt() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c"]), items: [downloadingItem("b")], transfers: makeTransfers())
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        pf.fetchSong = { _ in await withCheckedContinuation { gate = $0 } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        await startStreaming(r, ["a", "b", "c"])
        r.seq.setMixMode(true)
        await waitUntil("buffering a") { pf.inFlight?.description == "song:a" }
        XCTAssertEqual(pf.pending.map(\.description), ["song:c"])
        XCTAssertEqual(r.burns.items["b"]?.state, .downloading)
        gate?.resume(returning: false)
    }

    /// A network-class change re-plans at once: Wi-Fi's 3-ahead window shrinks to cellular's
    /// next song.
    func testNetworkChangeResizesTheWindow() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c", "d"]))
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        var net = NowPlayingPrefetcher.Network.unmetered
        pf.network = { net }
        pf.fetchSong = { _ in await withCheckedContinuation { gate = $0 } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        await startStreaming(r, ["a", "b", "c", "d"])
        r.seq.setMixMode(true)
        await waitUntil("wifi plan") { pf.pending.count == 3 }
        net = .expensive
        pf.onNetworkChange?()
        await waitUntil("cellular plan") { pf.pending.map(\.description) == ["song:b"] }
        XCTAssertEqual(pf.inFlight?.description, "song:a", "the playing row's fetch is kept")
        gate?.resume(returning: false)
    }

    /// SWAP-ON-LAND: the playing stream's identical bytes land as a local file — playback moves
    /// onto it AT THE SAME SONG POSITION (held until seeked), same track, same history play; the
    /// controls go live (`currentTrackMixable`).
    func testHandOffMovesTheStreamOntoTheLocalFileAtTheSamePosition() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        var plays: [String] = []
        r.rips.onPlay = { plays.append($0) }
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        XCTAssertFalse(r.seq.currentTrackMixable)
        land(r, "a")
        r.player.clock.currentTime = 42.5                     // the stream's playhead
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        let np = try XCTUnwrap(r.rips.nowPlaying)
        XCTAssertTrue(np.url.isFileURL, "now on the local file")
        XCTAssertEqual(np.songId, "a")
        XCTAssertEqual(np.seekMs, 42_500, "same position")
        XCTAssertTrue(r.player.holdPlayUntilSeek, "nothing of the file's top sounds before the seek")
        XCTAssertEqual(r.seq.index, 0)
        XCTAssertLessThanOrEqual(plays.filter { $0 == "a" }.count, 1, "no second history play")
        XCTAssertTrue(r.seq.currentTrackMixable, "controls live")
        XCTAssertEqual(r.seq.mixModeIndicator, .ready)
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "again"), "idempotent: already local")
        XCTAssertEqual(r.seq.handOffCount, 1)
    }

    /// End to end through the lane: the `.song(current)` step finishing IS the trigger.
    func testHandOffFiresWhenTheCurrentSongsBufferLands() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        let pf = NowPlayingPrefetcher()
        let burns = r.burns
        pf.fetchSong = { [weak burns] step in
            if case let .song(id, _, _) = step, id == "a", let burns {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-land-\(UUID().uuidString).mp3")
                try? Data(repeating: 9, count: 4096).write(to: tmp)
                _ = burns.adoptStreamedFile(songId: id, title: id, artist: "A", from: tmp, origin: .buffer)
            }
            return true
        }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        await waitUntil("handed off on landing") { r.rips.nowPlaying?.url.isFileURL == true }
        XCTAssertEqual(r.seq.handOffCount, 1)
        XCTAssertEqual(r.seq.index, 0)
    }

    /// A PAUSED stream hands off paused; after the hand-off the end-of-track path is the same as
    /// ever: ONE natural end advances exactly one row (no generation was claimed by the hand-off).
    func testPausedHandOffStaysPausedAndTheEndAdvancesOnce() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c"]))
        await startStreaming(r, ["a", "b", "c"])
        r.seq.setMixMode(true)
        r.player.pause()
        land(r, "a")
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        XCTAssertTrue(r.player.pausedByListener, "the listener's pause survives the hand-off")
        r.player.onTrackEnded?()
        await waitUntil("b starts") { r.rips.nowPlaying?.songId == "b" }
        XCTAssertEqual(r.seq.index, 1, "exactly one advance")
    }

    /// RACES: a hand-off never lands on the wrong row — after a skip (the stale row's landing is
    /// ignored), while the new row's resolve is in flight (refused), on another edition's file,
    /// or too near the song's end. A landing during the resolve is picked up on first audio.
    func testHandOffRefusedAcrossTrackChangeResolveAndNearEnd() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c"]))
        let pf = NowPlayingPrefetcher()
        r.seq.prefetcher = pf
        NPMixStub.hangPresign = ["b"]                         // b's resolve will hang (dead zone)
        await startStreaming(r, ["a", "b", "c"])
        r.seq.setMixMode(true)

        // Near the end: refused.
        land(r, "a")
        r.player.clock.currentTime = 239
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "near-end"))
        XCTAssertFalse(r.rips.nowPlaying?.url.isFileURL ?? true)

        // Skip to b with its presign HANGING: b's resolve is in flight.
        r.seq.skipNext()
        await waitUntil("b resolving") { r.seq.index == 1 && NPMixStub.presigns["b", default: 0] >= 1 }
        land(r, "b")
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "during-resolve"), "refused while the resolve is out")
        // a's stale landing report must not act on b.
        pf.onStepFinished?(.song(id: "a", title: "a", artist: "A"), true)
        XCTAssertEqual(r.seq.index, 1)
        XCTAssertFalse(r.rips.nowPlaying?.url.isFileURL ?? false, "never yanked back onto the skipped row's file")
        XCTAssertEqual(r.seq.handOffCount, 0)
        r.seq.stop()
    }

    /// An analog row streamed as its album SIDE (startMs 60 s into the side) hands off onto its
    /// per-song CUT (starts at 0): the song-relative position carries across.
    func testHandOffMapsAnAnalogSideOntoItsCutAtTheSongPosition() async throws {
        let r = try makeRig(manifest: ["v1": .init(key: "rips/side.mp3", source: "analog", startMs: 60_000),
                                       "v2": .init(key: "rips/side2.mp3", source: "analog")])
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-npmix-cut-\(UUID().uuidString).mp3")
        try Data(repeating: 3, count: 2048).write(to: cut)
        addTeardownBlock { try? FileManager.default.removeItem(at: cut) }
        await startStreaming(r, ["v1", "v2"])
        XCTAssertEqual(r.rips.nowPlaying?.startMs, 60_000)
        r.seq.setMixMode(true)
        r.seq.prefetchedCutFile = { $0 == "v1" ? cut : nil }
        r.player.clock.currentTime = 70.25                     // 10.25 s into the song
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "cut"))
        XCTAssertEqual(r.rips.nowPlaying?.url, cut)
        XCTAssertNil(r.rips.nowPlaying?.startMs, "a cut plays from its own 0:00")
        XCTAssertEqual(r.rips.nowPlaying?.seekMs, 10_250)
    }

    /// A scrub during the hand-off's hold lands where the listener scrubbed (not the old offset).
    func testScrubDuringTheHandOffHoldWins() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 30
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        XCTAssertTrue(r.player.holdPlayUntilSeek)
        r.player.seek(to: 95)
        XCTAssertEqual(r.player.currentTime, 95, accuracy: 1e-9)
    }

    /// DURABLE RESTORE: the flag rides the snapshot, the restore is HELD (no buffering, chip
    /// "Buffers on ▶"), and the first ▶ starts the lane.
    func testRestoreIsHeldAndBufferingStartsOnPlay() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        pf.fetchSong = { _ in await withCheckedContinuation { gate = $0 } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_r", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "a", title: "a", artist: "A", lengthMs: 240_000, repeatCount: nil),
                    .init(songId: "b", title: "b", artist: "A", lengthMs: 240_000, repeatCount: nil)],
            index: 0, positionMs: 5_000, isPlaying: true, npMixMode: NPMixModeState(enabled: true), updatedAt: 0)
        r.seq.restore(from: snap)
        XCTAssertTrue(r.seq.mixMode.enabled)
        XCTAssertEqual(r.seq.mixModeIndicator, .waiting)
        r.seq.replanPrefetch()
        XCTAssertTrue(pf.isIdle, "held: nothing downloads before ▶")
        XCTAssertTrue(r.seq.protectedWindowSongIds().isSuperset(of: ["a", "b"]), "the held window is sweep-protected")
        r.seq.resumeFromHold()
        await waitUntil("buffering after ▶") { pf.inFlight != nil }
        XCTAssertEqual(pf.startedLog.first?.description, "song:a")
        gate?.resume(returning: false)
    }

    /// One DSP surface at a time: a live Mix-tab session SUSPENDS Mix Mode (its lane steps leave,
    /// chip "Paused — Mix tab is live", no hand-off), and the next re-plan after it stops resumes.
    func testMixTabSuspendsAndResumesBuffering() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        let pf = NowPlayingPrefetcher()
        var gates: [CheckedContinuation<Bool, Never>] = []
        pf.fetchSong = { _ in await withCheckedContinuation { gates.append($0) } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        let mixLive = MixLiveFlag()
        r.seq.mixSessionActive = { mixLive.on }
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        await waitUntil("buffering") { pf.inFlight != nil }
        mixLive.on = true
        await waitUntil("suspended: the lane is idle") { pf.isIdle }
        XCTAssertEqual(r.seq.mixModeIndicator, .suspended)
        XCTAssertTrue(r.seq.mixMode.enabled, "Mix Mode itself stays ON")
        land(r, "a")
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "suspended"), "no hand-off while the Mix tab owns DSP")
        mixLive.on = false
        await waitUntil("resumed") { r.seq.mixModeIndicator != .suspended }
        r.seq.replanPrefetch()
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "resumed"))
        for g in gates { g.resume(returning: false) }
    }

    // MARK: - DSP engagement (real NowPlayingDSP over burned WAVs — skipped without audio)

    private func dspRig(_ ids: [String]) throws -> (Rig, NowPlayingDSP) {
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: ids, rips: rips, lengths: Dictionary(uniqueKeysWithValues: ids.map { ($0, 12.0) }))
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return (Rig(rips: rips, burns: burns, player: player, coord: coord, seq: seq), dsp)
    }

    /// TOGGLE OFF keeps the engaged track: the DSP keeps the audio and its controls until the
    /// track ends; the NEXT track plays the plain path (Q2 engage-on-touch, Q9 no carry).
    func testToggleOffKeepsTheEngagedTrackAndTheNextPlaysPlain() async throws {
        let (r, dsp) = try dspRig(["e1", "e2"])
        r.seq.play([item("e1", lengthMs: 12_000), item("e2", lengthMs: 12_000)])
        await waitUntil("e1 playing") { r.rips.nowPlaying?.songId == "e1" }
        r.seq.setMixMode(true)
        XCTAssertEqual(r.seq.mixModeIndicator, .ready, "a local track: controls live, DSP not yet engaged (Q2)")
        XCTAssertFalse(r.seq.mixEngaged)
        r.seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        dsp.setRate(1.2)
        XCTAssertEqual(r.seq.mixModeIndicator, .engaged)
        r.seq.setMixMode(false)
        XCTAssertTrue(r.seq.mixEngaged, "no audible jump mid-song: the DSP keeps the track")
        XCTAssertEqual(dsp.rate, 1.2, accuracy: 1e-9)
        r.seq.skipNext()
        await waitUntil("e2 playing") { r.rips.nowPlaying?.songId == "e2" }
        XCTAssertFalse(r.seq.mixEngaged, "the next track plays the plain path")
        XCTAssertEqual(dsp.rate, 1, accuracy: 1e-9, "tempo doesn't carry (Q9)")
    }

    /// MEDIA SERVICES RESET while engaged: the track goes back to the AVPlayer at the DSP's
    /// position, the engagement is torn down, a paused DSP stays paused.
    func testMediaServicesResetHandsTheEngagedTrackBackToTheAVPlayer() async throws {
        let (r, dsp) = try dspRig(["m1", "m2"])
        r.seq.play([item("m1", lengthMs: 12_000), item("m2", lengthMs: 12_000)])
        await waitUntil("m1 playing") { r.rips.nowPlaying?.songId == "m1" }
        r.seq.setMixMode(true)
        r.seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        if !dsp.isPlaying { dsp.resume() }
        await waitUntil("DSP rendering") { dsp.currentTime > 0.3 }
        dsp.pause()
        let at = dsp.currentTime
        r.seq.handleMediaServicesReset()
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "m1")
        XCTAssertEqual(Double(r.rips.nowPlaying?.seekMs ?? 0) / 1000, at, accuracy: 0.05)
        XCTAssertTrue(r.player.pausedByListener, "paused stays paused")
        XCTAssertEqual(r.seq.index, 0)
    }

    // MARK: - Phase 2 review (adversarial): playback safety of the hand-off

    /// MUST: a hand-off never STARTS audio. An open interruption (call / Siri / another app took
    /// the audio) refuses it outright; an interruption that ended WITHOUT resume (the engine no
    /// longer intends to play, but `pausedByListener` is false) hands off PAUSED.
    func testHandOffNeverStartsAudioAcrossAnInterruption() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 20
        r.player.handleInterruption(began: true, shouldResume: nil)
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "test"), "never reload the engine during a call")
        XCTAssertFalse(r.rips.nowPlaying?.url.isFileURL ?? true)
        r.player.handleInterruption(began: false, shouldResume: false)
        r.player.noteListenerIntent(false)            // the system said don't resume: the set holds
        XCTAssertFalse(r.player.pausedByListener, "precondition: not a listener pause")
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        XCTAssertTrue(r.player.pausedByListener, "a held (not playing) stream hands off PAUSED — the seek must not start it")
    }

    /// SHOULD: ⏯ (lock screen / CarPlay) during the hand-off's seek hold means PAUSE — the engine
    /// reads `.paused` there, and `toggle()` used to call `play()`, sounding the file's top.
    func testTogglePausesDuringTheHandOffHold() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 30
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        XCTAssertTrue(r.player.holdPlayUntilSeek)
        r.player.toggle()
        XCTAssertTrue(r.player.pausedByListener, "⏯ during the hold pauses")
        r.player.toggle()
        XCTAssertFalse(r.player.pausedByListener, "…and ⏯ again resumes (after the seek)")
        XCTAssertTrue(r.player.holdPlayUntilSeek, "the render still waits for the seek")
    }

    /// MUST: the local file the hand-off moved onto FAILING must not skip a song that was
    /// streaming fine — it goes back on the stream at the same position (once; a second failure
    /// advances as ever).
    func testFailedHandOffFileFallsBackToTheStream() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        let streamURL = try XCTUnwrap(r.rips.nowPlaying?.url)
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 42.5
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        r.player.clock.currentTime = 50
        r.player.onTrackFailed?()
        XCTAssertEqual(r.seq.index, 0, "the song is NOT skipped")
        XCTAssertEqual(r.rips.nowPlaying?.url, streamURL, "back on its stream")
        XCTAssertEqual(r.rips.nowPlaying?.seekMs, 50_000, "at the same position")
        r.player.onTrackFailed?()
        await waitUntil("a second failure advances") { r.seq.index == 1 }
    }

    /// The file died before it ever loaded (clock still 0): the stream resumes where the hand-off
    /// left it, not at 0:00.
    func testFallbackBeforeTheLocalFileLoadedResumesAtTheHandOffPoint() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 61
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        r.player.clock.currentTime = 0
        r.player.onTrackFailed?()
        XCTAssertEqual(r.rips.nowPlaying?.seekMs, 61_000)
        XCTAssertEqual(r.seq.index, 0)
    }

    /// SHOULD: nothing renders between the reload and the seek — a locked phone must hold a
    /// background runway across it; first audio ends it.
    func testHandOffHoldsARunwayUntilFirstAudio() async throws {
        let r = try makeRig(manifest: digital(["a", "b"]))
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 30
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        XCTAssertTrue(r.seq.handOffRunwayHeld)
        r.player.simulateFirstAudioForTesting()
        await waitUntil("runway released on first audio") { !r.seq.handOffRunwayHeld }
    }

    /// SHOULD: our own re-stamp is matched by URL AND song — a foreign play of ANOTHER song on the
    /// same file (two songs of one analog side) is a real jump and is adopted.
    func testOwnStampDoesNotHideAForeignPlayOfAnotherSongOnTheSameFile() async throws {
        let r = try makeRig(manifest: digital(["a", "b", "c"]))
        await startStreaming(r, ["a", "b", "c"])
        r.seq.setMixMode(true)
        land(r, "a")
        r.player.clock.currentTime = 30
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        let local = try XCTUnwrap(r.rips.nowPlaying?.url)
        await Task.yield()
        r.rips.setNowPlaying(.init(songId: "b", title: "b", artist: "A", url: local, live: false,
                                   startMs: 120_000, seekMs: 120_000, waveform: nil))
        await waitUntil("the foreign play of b is adopted") { r.seq.index == 1 }
    }

    /// SHOULD: an upcoming row whose explicit Download is pending still gets its STEMS planned
    /// (the download makes it local) — it used to be skipped whole.
    func testUpcomingPendingDownloadStillPlansItsStems() async throws {
        var m = digital(["a", "b"])
        m["b"]?.stems = .init(vocals: "rips/stems/b/vocals.mp3", drums: "rips/stems/b/drums.mp3",
                              bass: "rips/stems/b/bass.mp3", other: "rips/stems/b/other.mp3")
        let r = try makeRig(manifest: m, items: [downloadingItem("b")], transfers: makeTransfers())
        let pf = NowPlayingPrefetcher()
        var gate: CheckedContinuation<Bool, Never>?
        pf.fetchSong = { _ in await withCheckedContinuation { gate = $0 } }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        await startStreaming(r, ["a", "b"])
        r.seq.setMixMode(true)
        await waitUntil("buffering a") { pf.inFlight?.description == "song:a" }
        XCTAssertEqual(pf.pending.map(\.description), ["vocals:b", "drums:b", "other:b", "bass:b"],
                       "b's song is left to its download; its stems are still fetched")
        gate?.resume(returning: false)
    }

    /// MUST: a media-services reset orphans the DSP graph — it is RECREATED, and the next engage
    /// (a control touch / the next Stem Lock track) builds and runs a fresh one.
    func testMediaServicesResetRecreatesTheDSPGraph() async throws {
        let (r, dsp) = try dspRig(["g1", "g2"])
        r.seq.play([item("g1", lengthMs: 12_000), item("g2", lengthMs: 12_000)])
        await waitUntil("g1 playing") { r.rips.nowPlaying?.songId == "g1" }
        r.seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        r.seq.handleMediaServicesReset()
        XCTAssertEqual(dsp.mediaResetRebuilds, 1)
        XCTAssertFalse(dsp.isReady, "the orphaned graph is dropped")
        r.seq.engageMix()
        XCTAssertTrue(dsp.isReady, "a fresh graph is built on the next engage")
        XCTAssertTrue(r.seq.mixEngaged)
        // Not engaged at the reset: the graph is still recreated.
        r.seq.skipNext()
        await waitUntil("g2 playing") { r.rips.nowPlaying?.songId == "g2" }
        XCTAssertFalse(r.seq.mixEngaged)
        r.seq.handleMediaServicesReset()
        XCTAssertEqual(dsp.mediaResetRebuilds, 2)
    }
}

/// A mutable flag the `mixSessionActive` seam reads (observable, so the sequencer's observation
/// fires on a flip exactly like `MixEngine.isRunning`).
@MainActor
@Observable
private final class MixLiveFlag { var on = false }

/// Scripted rip server + S3: presign → an https URL (or hang), everything else → small bytes.
private final class NPMixStub: URLProtocol {
    nonisolated(unsafe) static var hangPresign: Set<String> = []
    nonisolated(unsafe) static var presigns: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        hangPresign = []; presigns = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data, json: Bool = false) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: json ? ["Content-Type": "application/json"] : nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            Self.lock.lock()
            Self.presigns[song, default: 0] += 1
            let hang = Self.hangPresign.contains(song)
            Self.lock.unlock()
            if hang { return }
            respond(200, Data(#"{"url":"https://s3.test/rips/\#(song).mp3?X-Amz-Signature=x"}"#.utf8), json: true)
            return
        }
        respond(200, Data("BYTES".utf8))
    }
}
