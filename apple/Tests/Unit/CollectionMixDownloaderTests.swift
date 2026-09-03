import XCTest
@testable import PocketDJ

/// `CollectionMixDownloader` — the Mix tab's collection download pipeline. Pure ETA math
/// (rolling window, scripted clock), the seed/partition/drive lifecycle over REAL stores
/// (BurnStore Document fixtures + a stubbed rip server, the CollectionRipBurnController test
/// idiom), progressive auto-mix eligibility + exhaustion pickup against a REAL MixEngine, and
/// cancel/cleanup fan-out (burn stop + background-task cancel + server-side rip cancel).
@MainActor
final class CollectionMixDownloaderTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        DownloaderStubURLProtocol.reset()
        CollectionMixDownloader.ripPollIntervalMs = 10
        CollectionMixDownloader.ripPollMaxTicks = 200
        CollectionMixDownloader.idleWaitMs = 10
    }

    override func tearDown() {
        CollectionMixDownloader.ripPollIntervalMs = 4500
        CollectionMixDownloader.ripPollMaxTicks = 1600
        CollectionMixDownloader.idleWaitMs = 500
        super.tearDown()
    }

    // MARK: Helpers

    private func makeRips(serverURL: String? = nil) -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloaderStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        if let serverURL {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            settings.ripServerURL = serverURL
            settings.ripToken = ""
            rips.settings = settings
        }
        return rips
    }

    private func makeTransfers() -> TransferCoordinator {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixdl-xfer-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TransferCoordinator(fileURL: url, realSession: false)
    }

    private func loadable(_ id: String, lengthMs: Int? = 2_000) -> MixLoadable {
        MixLoadable(songId: id, title: "T-\(id)", artist: "A", bpm: 120,
                    camelot: "8A", key: nil, albumId: nil, lengthMs: lengthMs)
    }

    private func item(_ id: String) -> MixEngine.AutoMixItem {
        .init(loadable: loadable(id), durationMs: 180_000)
    }

    /// Downloader over the given stores, with the catalog/resolver seams scripted.
    private func makeDownloader(engine: MixEngine, burns: BurnStore, rips: RipsStore,
                                transfers: TransferCoordinator? = nil,
                                ripIds: [String],
                                loadables: @escaping () -> [MixLoadable] = { [] },
                                lengthSeconds: [String: Double] = [:]) -> CollectionMixDownloader {
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: transfers)
        d.resolveRipIds = { _ in ripIds }
        d.resolveLoadables = { _ in loadables() }
        d.songLengthSeconds = { lengthSeconds[$0] }
        d.songTitleArtist = { (title: "T-\($0)", artist: "A") }
        return d
    }

    private func wait(timeout: TimeInterval = 5, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: 1 — rolling-window ETA math (scripted clock)

    func testRollingWindowEtaMath() {
        var w = CollectionMixDownloader.ThroughputWindow()
        XCTAssertNil(w.bytesPerSecond(at: 0), "no samples ⇒ no throughput (ETA shows —)")

        w.add(bytes: 1_000_000, at: 0)
        w.add(bytes: 2_000_000, at: 10)
        let bps = w.bytesPerSecond(at: 10)
        XCTAssertEqual(bps ?? -1, 3_000_000 / 10.0, accuracy: 1e-6,
                       "Σ bytes over the ACTUAL elapsed span")

        // Two manifest-ready tracks of 200 s + 100 s remaining at 256 kbps (32 KB/s of playback).
        let eta = CollectionMixDownloader.etaSeconds(remainingPlaybackSeconds: 300, bytesPerSecond: bps)
        XCTAssertEqual(eta ?? -1, 300 * 32_768 / (3_000_000 / 10.0), accuracy: 1e-6)
        XCTAssertNil(CollectionMixDownloader.etaSeconds(remainingPlaybackSeconds: 300,
                                                        bytesPerSecond: nil))

        // t = 41: the t=0 and t=10 samples fall out of the 30 s window; the lone t=41 sample
        // counts over the 1 s floor span.
        w.add(bytes: 1_000_000, at: 41)
        XCTAssertEqual(w.samples.count, 1, "old samples pruned")
        XCTAssertEqual(w.bytesPerSecond(at: 41) ?? -1, 1_000_000, accuracy: 1e-6, "span floor 1 s")
    }

    // MARK: two-crate resolve — union, not collapse (field: tvos-8E34293E "sources=2 total=1")

    /// Two multi-song crates must resolve to the UNION of their rip ids (sum minus the
    /// cross-crate duplicates), never collapse to one. Pins `begin(sources:)`'s dedupe: the
    /// field "sources=2 total=1" was a PARTIAL CATALOG dropping members upstream in
    /// `ripIds(forPocket:)`, not this math — so with the ids present, two 3-song crates sharing
    /// one track give total=5.
    func testTwoMultiSongCratesResolveToUnionNotOne() async throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let byCrate: [MixSource: [String]] = [
            .pocket("sap"): ["s1", "s2", "shared"],
            .pocket("joy"): ["j1", "j2", "shared"],
        ]
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { byCrate[$0] ?? [] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        // Declared-count seam: each crate DECLARES 3, so nothing looks partial here.
        d.declaredMemberCount = { byCrate[$0]?.count ?? 0 }
        d.catalogSongCount = { 100 }

        d.begin(sources: [.pocket("sap"), .pocket("joy")])
        XCTAssertEqual(d.totalCount, 5,
                       "3 + 3 minus the one shared id = 5 — two multi-song crates do NOT collapse to 1")
        d.cancel()
    }

    // MARK: 2 — ETA excludes rip-pending ids (they surface as rippingCount)

    func testEtaExcludesRipPendingAndCountsRipping() async {
        let rips = makeRips()
        rips.setManifest([
            "r1": .init(key: "rips/r1.mp3", source: "digital", durationMs: 100_000),
            "r2": .init(key: "rips/r2.mp3", source: "digital", durationMs: 200_000),
        ])
        // The poll refreshes the manifest from the stub — serve the SAME entries so a tick
        // can't wipe the seeded r1/r2 out from under the partition.
        DownloaderStubURLProtocol.manifestBody = Data(
            #"{"r1":{"key":"rips/r1.mp3","durationMs":100000},"r2":{"key":"rips/r2.mp3","durationMs":200000}}"#.utf8)
        // The burn attempts must fail (this test freezes the remaining set): 404 the audio.
        DownloaderStubURLProtocol.statusCodeByPath["/rips/r1.mp3"] = 404
        DownloaderStubURLProtocol.statusCodeByPath["/rips/r2.mp3"] = 404
        let burns = try! MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips,
                               ripIds: ["r1", "r2", "n1", "n2", "n3"],
                               lengthSeconds: ["r1": 100, "r2": 200])
        d.now = { 100 }   // frozen clock — the window span floors at 1 s

        d.begin(source: .pocket("pkt_test"))
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.totalCount, 5)
        XCTAssertEqual(d.downloadedCount, 0)
        XCTAssertEqual(d.rippingCount, 3, "3 ids not in the manifest = server-side real-time capture")
        XCTAssertNil(d.etaSeconds, "no throughput sample yet")

        d.addThroughputSampleForTesting(bytes: 327_680)   // 327 680 B over the 1 s floor span
        // ETA covers ONLY the 2 manifest-ready tracks (100 s + 200 s): 300 × 32 768 / 327 680 = 30 s.
        XCTAssertEqual(d.etaSeconds ?? -1, 30.0, accuracy: 1e-6)
        XCTAssertEqual(d.rippingCount, 3, "rip-pending ids never enter the byte ETA")
        d.cancel()
    }

    // MARK: 3 — progressive eligibility: landings append to OUR running auto-mix, deduped

    func testProgressiveEligibilityAppendsLandingsOnceToRunningAutoMix() async throws {
        let rips = makeRips()
        let engineBurns = try MixBurnFixture.burnStore(ids: ["m1", "m2"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        var eligible = [loadable("m1"), loadable("m2")]
        let d = makeDownloader(engine: engine, burns: engineBurns, rips: rips,
                               ripIds: ["m1", "m2", "m3", "m4", "m5"],
                               loadables: { eligible })
        d.begin(source: .pocket("pkt_test"))
        XCTAssertEqual(d.downloadedCount, 2, "seed pass finds the on-disk pair")

        engine.startAutoMix([item("m1"), item("m2")], shuffled: false, lead: 15, fade: 3, label: "L")
        guard engine.autoMixing else { throw XCTSkip("no audio device on this test host") }
        d.noteAutoStarted(initialIds: ["m1", "m2"], lead: 15, fade: 3, label: "L")
        XCTAssertEqual(engine.autoQueueCountForTesting, 2)
        let nextToLoad = engine.autoNextToLoadForTesting

        eligible.append(loadable("m3"))
        d.simulateLandingForTesting("m3")
        XCTAssertEqual(engine.autoQueueCountForTesting, 3, "the landing joined the queue")

        d.simulateLandingForTesting("m3")            // duplicate landing — must not double-append
        XCTAssertEqual(engine.autoQueueCountForTesting, 3, "appended exactly once")

        eligible.append(loadable("m4"))              // m1 stays in `eligible` throughout
        d.simulateLandingForTesting("m4")
        XCTAssertEqual(engine.autoQueueCountForTesting, 4)
        XCTAssertEqual(d.appendedIdsForTesting, ["m3", "m4"],
                       "initial ids are never re-appended")
        XCTAssertEqual(engine.autoNextToLoadForTesting, nextToLoad,
                       "end-appends never disturb the committed deck cursor")
        engine.stopAutoMix()
        d.cancel()
    }

    // MARK: 4 — exhaustion pickup: a late landing CONTINUES the mix; a user stop stays stopped

    func testExhaustedAutoMixRestartsOnLandingButUserStopDoesNot() async throws {
        let rips = makeRips()
        let engineBurns = try MixBurnFixture.burnStore(ids: ["e1", "e2"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")

        // The downloader's OWN store only has e1 — e2 is the track that lands late.
        let dlBurns = try MixBurnFixture.burnStore(ids: ["e1"], rips: rips)
        var eligible = [loadable("e1")]
        let d = makeDownloader(engine: engine, burns: dlBurns, rips: rips,
                               ripIds: ["e1", "e2", "e3"],
                               loadables: { eligible })
        d.begin(source: .pocket("pkt_test"))

        engine.startAutoMix([item("e1")], shuffled: false, lead: 15, fade: 3, label: "L")
        XCTAssertTrue(engine.autoMixing)
        d.noteAutoStarted(initialIds: ["e1"], lead: 15, fade: 3, label: "L")

        engine.skipToNext(fadeSeconds: 5)            // skip on the LAST track = exhausted end
        XCTAssertFalse(engine.autoMixing)
        XCTAssertTrue(engine.autoEndedExhausted)

        eligible.append(loadable("e2"))
        d.simulateLandingForTesting("e2")            // e2 finished downloading AFTER the end
        XCTAssertTrue(engine.autoMixing, "the mix CONTINUES with the late arrival")
        XCTAssertEqual(engine.loaded(.a)?.songId, "e2")
        XCTAssertEqual(engine.autoQueueCountForTesting, 1)
        XCTAssertEqual(engine.autoSourceLabel, "L", "same mix identity")

        engine.stopAutoMix()                         // USER stop — the flag must clear
        XCTAssertFalse(engine.autoEndedExhausted)
        eligible.append(loadable("e3"))
        d.simulateLandingForTesting("e3")
        XCTAssertFalse(engine.autoMixing, "a user-stopped mix is never resurrected by a landing")
        XCTAssertFalse(d.appendedIdsForTesting.contains("e3"))
        engine.teardown()
        d.cancel()
    }

    // MARK: 5 — cancel/cleanup fan-out

    func testCancelStopsBurnsCancelsTransfersAndServerRips() async throws {
        let rips = makeRips(serverURL: "https://imac.test")
        rips.setManifest([
            "p1": .init(key: "rips/p1.mp3", source: "digital", durationMs: 60_000),
            "p2": .init(key: "rips/p2.mp3", source: "digital", durationMs: 60_000),
        ])
        DownloaderStubURLProtocol.manifestBody = Data(
            #"{"p1":{"key":"rips/p1.mp3","durationMs":60000},"p2":{"key":"rips/p2.mp3","durationMs":60000}}"#.utf8)
        DownloaderStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"n1","status":"queued","jobId":"j1"}],
         "counts":{"ready":0,"queued":1,"inflight":0,"unknown":0,"total":1}}
        """.utf8)
        DownloaderStubURLProtocol.bodyByPath["/rip-cancel"] = Data("""
        {"results":[{"songId":"n1","status":"canceled"}]}
        """.utf8)
        let transfers = makeTransfers()
        let burns = try MixBurnFixture.burnStore(ids: ["d1", "d2"], rips: rips, transfers: transfers)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips, transfers: transfers,
                               ripIds: ["d1", "d2", "p1", "p2", "n1"])

        d.begin(source: .pocket("pkt_test"))
        XCTAssertEqual(d.downloadedCount, 2)
        XCTAssertEqual(d.rippingCount, 1)
        // The drive enqueues the two manifest-ready ids as background transfers.
        await wait { transfers.records.count == 2 }
        XCTAssertEqual(Set(transfers.records.map(\.songId)), ["p1", "p2"])

        d.cancel()

        XCTAssertTrue(burns.stopRequested, "the burn loop was told to stop")
        XCTAssertTrue(transfers.records.isEmpty, "in-flight background tasks cancelled")
        await wait { DownloaderStubURLProtocol.count(path: "/rip-cancel") == 1 }
        let sent = DownloaderStubURLProtocol.lastBodyJSON(path: "/rip-cancel")?["songIds"] as? [String]
        XCTAssertEqual(sent, ["n1"], "server-side cancel targets exactly the still-queued rip ids")
        XCTAssertFalse(d.isActive)
        XCTAssertEqual(d.totalCount, 0)
        XCTAssertEqual(d.downloadedCount, 0)
        XCTAssertNil(d.etaSeconds)
        XCTAssertTrue(d.downloadedIds.isEmpty)
        // The engine was never touched.
        XCTAssertFalse(engine.autoMixing)
        XCTAssertNil(engine.loaded(.a)); XCTAssertNil(engine.loaded(.b))
    }

    // MARK: 6 — resume-from-disk (begin IS resume; same-source re-begin is a no-op)

    func testBeginSeedsFromDiskResumesAndCompletes() async throws {
        let rips = makeRips()
        rips.setManifest([
            "c4": .init(key: "rips/c4.mp3", source: "digital", durationMs: 2_000),
            "c5": .init(key: "rips/c5.mp3", source: "digital", durationMs: 2_000),
        ])
        DownloaderStubURLProtocol.bodyByPath["/rips/c4.mp3"] = Data(repeating: 7, count: 65_536)
        DownloaderStubURLProtocol.bodyByPath["/rips/c5.mp3"] = Data(repeating: 7, count: 65_536)
        let burns = try MixBurnFixture.burnStore(ids: ["c1", "c2", "c3"], rips: rips)   // 3 of 5 on disk
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips,
                               ripIds: ["c1", "c2", "c3", "c4", "c5"])

        d.begin(source: .pocket("pkt_test"))
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.downloadedCount, 3, "the seed pass counts what's already on disk")
        XCTAssertEqual(d.burnQueueForTesting, ["c4", "c5"], "only the remainder drives")
        XCTAssertEqual(d.rippingCount, 0)

        d.begin(source: .pocket("pkt_test"))         // same source while active — a no-op
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.downloadedCount, 3)
        XCTAssertEqual(d.burnQueueForTesting, ["c4", "c5"], "the run was not restarted")

        await wait { !d.isActive }
        XCTAssertEqual(d.downloadedIds.count, 5, "the two in-process downloads completed the run")
        XCTAssertEqual(d.downloadedCount, 5)
        XCTAssertNotNil(burns.localURL(forSong: "c4"))
        XCTAssertNotNil(burns.localURL(forSong: "c5"))
    }

    // MARK: 7 — ▶ on an all-undownloaded collection: the FIRST landing starts the mix

    func testPlayOnEmptyDownloadedSetStartsMixOnFirstLanding() async throws {
        let rips = makeRips()
        rips.setManifest([
            "z1": .init(key: "rips/z1.mp3", source: "digital", durationMs: 2_000),
            "z2": .init(key: "rips/z2.mp3", source: "digital", durationMs: 2_000),
        ])
        // Freeze the run mid-download: the burn lane's fetches fail, so nothing "lands" except
        // what the test scripts.
        DownloaderStubURLProtocol.statusCodeByPath["/rips/z1.mp3"] = 404
        DownloaderStubURLProtocol.statusCodeByPath["/rips/z2.mp3"] = 404
        // The ENGINE's store has z1's burned file (the mix must genuinely load it once it "lands");
        // the DOWNLOADER's store starts empty — nothing downloaded when the user presses ▶.
        let engineBurns = try MixBurnFixture.burnStore(ids: ["z1"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        let dlBurns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        var eligible: [MixLoadable] = []
        let d = makeDownloader(engine: engine, burns: dlBurns, rips: rips,
                               ripIds: ["z1", "z2"],
                               loadables: { eligible })

        d.begin(source: .pocket("pkt_test"))
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.downloadedCount, 0, "nothing on disk at ▶ time")

        // MixView.startAuto with ZERO loadables: the engine's empty-queue guard means no mix —
        // noteAutoStarted arms the pending start instead.
        d.noteAutoStarted(initialIds: [], lead: 15, fade: 3, label: "L")
        XCTAssertTrue(d.autoStartPendingForTesting)
        XCTAssertFalse(engine.autoMixing)

        eligible = [loadable("z1")]
        d.simulateLandingForTesting("z1")            // the first track finishes downloading
        XCTAssertTrue(engine.autoMixing, "the pressed-▶ mix starts on the first landing")
        XCTAssertEqual(engine.loaded(.a)?.songId, "z1")
        XCTAssertEqual(engine.autoSourceLabel, "L")
        XCTAssertFalse(d.autoStartPendingForTesting, "the pending start fired exactly once")
        XCTAssertTrue(d.appendedIdsForTesting.contains("z1"))

        // A CANCELLED run must never surprise-start a mix later.
        engine.stopAutoMix()
        d.noteAutoStarted(initialIds: [], lead: 15, fade: 3, label: "L")
        XCTAssertTrue(d.autoStartPendingForTesting)
        d.cancel()
        XCTAssertFalse(d.autoStartPendingForTesting)
        eligible = [loadable("z1"), loadable("z2")]
        d.simulateLandingForTesting("z2")
        XCTAssertFalse(engine.autoMixing, "a cancelled run stays silent")
        engine.teardown()
    }

    // MARK: 9 — a late landing must never seize decks the DJ is hand-mixing on

    func testLandingNeverSeizesDecksMidManualMix() async throws {
        let rips = makeRips()
        let engineBurns = try MixBurnFixture.burnStore(ids: ["e1", "e2"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")

        let dlBurns = try MixBurnFixture.burnStore(ids: ["e1"], rips: rips)
        var eligible = [loadable("e1")]
        let d = makeDownloader(engine: engine, burns: dlBurns, rips: rips,
                               ripIds: ["e1", "e2"],
                               loadables: { eligible })
        d.begin(source: .pocket("pkt_test"))

        engine.startAutoMix([item("e1")], shuffled: false, lead: 15, fade: 3, label: "L")
        d.noteAutoStarted(initialIds: ["e1"], lead: 15, fade: 3, label: "L")
        engine.skipToNext(fadeSeconds: 5)            // last track → exhausted end
        XCTAssertTrue(engine.autoEndedExhausted)

        // The DJ takes the decks by hand: loads a track and starts playing it.
        engine.load(songId: "e1", title: "T", artist: "A", bpm: 120,
                    camelot: nil, key: nil, albumId: nil, on: .a)
        engine.play(.a)
        XCTAssertTrue(engine.isRunning)

        eligible.append(loadable("e2"))
        d.simulateLandingForTesting("e2")            // e2 lands mid-performance
        XCTAssertFalse(engine.autoMixing, "a landing must never restart the mix over a manual set")
        XCTAssertEqual(engine.loaded(.a)?.songId, "e1", "the manual deck is untouched")
        XCTAssertTrue(engine.isPlaying(.a), "…and keeps playing")
        engine.teardown()
        d.cancel()
    }

    // MARK: 10 — zero-start arm dies on manual deck activity; cancel disarms the whole arm

    func testPendingZeroStartDiesOnManualDeckActivityAndCancelDisarms() async throws {
        let rips = makeRips()
        rips.setManifest(["z1": .init(key: "rips/z1.mp3", source: "digital", durationMs: 2_000)])
        DownloaderStubURLProtocol.statusCodeByPath["/rips/z1.mp3"] = 404   // freeze the run
        let engineBurns = try MixBurnFixture.burnStore(ids: ["z1"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        let dlBurns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        var eligible: [MixLoadable] = []
        let d = makeDownloader(engine: engine, burns: dlBurns, rips: rips,
                               ripIds: ["z1"],
                               loadables: { eligible })
        d.begin(source: .pocket("pkt_test"))

        d.noteAutoStarted(initialIds: [], lead: 15, fade: 3, label: "L")
        XCTAssertTrue(d.autoStartPendingForTesting)

        // The DJ loads a deck by hand (still paused) while the downloads run.
        engine.load(songId: "z1", title: "T", artist: "A", bpm: 120,
                    camelot: nil, key: nil, albumId: nil, on: .a)

        eligible = [loadable("z1")]
        d.simulateLandingForTesting("z1")
        XCTAssertFalse(engine.autoMixing, "the zero-start arm died with the manual load")
        XCTAssertFalse(d.autoStartPendingForTesting)
        XCTAssertEqual(engine.loaded(.a)?.songId, "z1", "the manually loaded deck is untouched")

        // Cancel kills the WHOLE continuation arm — a re-picked collection's landings can't
        // restart the old mix with no ▶ pressed.
        d.noteAutoStarted(initialIds: ["z1"], lead: 15, fade: 3, label: "L")
        XCTAssertTrue(d.autoArmedForTesting)
        d.cancel()
        XCTAssertFalse(d.autoArmedForTesting, "cancel disarms the continuation, not just the pending start")
        XCTAssertFalse(d.autoStartPendingForTesting)
        engine.teardown()
    }

    // MARK: 8 — the bar's ETA label wording

    func testEtaLabelFormatting() {
        XCTAssertEqual(CollectionMixDownloader.etaLabel(nil), "—", "no throughput sample yet")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(200), "3m 20s")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(45), "45s")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(59.6), "1m 0s", "rounds before the split")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(0), "0s")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(-5), "—", "a negative ETA is a lie — show —")
        XCTAssertEqual(CollectionMixDownloader.etaLabel(.infinity), "—")
    }
}

// MARK: - Stub (the ManifestStubURLProtocol idiom — manifest GET + rip server POSTs + audio GETs)

private final class DownloaderStubURLProtocol: URLProtocol {
    static var manifestBody = Data("{}".utf8)
    static var bodyByPath: [String: Data] = [:]
    static var statusCodeByPath: [String: Int] = [:]
    private static var counts: [String: Int] = [:]
    private static var lastBody: [String: Data] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        manifestBody = Data("{}".utf8)
        bodyByPath = [:]
        statusCodeByPath = [:]
        counts = [:]
        lastBody = [:]
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path] ?? 0
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock(); let data = lastBody[path]; lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        if let body = request.httpBodyStream.flatMap({ Self.readStream($0) }) ?? request.httpBody {
            Self.lastBody[path] = body
        }
        let status = Self.statusCodeByPath[path] ?? 200
        let payload: Data
        if path.hasSuffix("manifest.json") {
            payload = Self.manifestBody
        } else if let b = Self.bodyByPath[path] {
            payload = b
        } else if path.hasSuffix("/rips/presign") {
            // MUST-1: ensureURL's cached fast path asks this first — echo a stub-servable
            // URL (this same protocol answers it too, via the `else` fallback below).
            let song = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            payload = Data(#"{"url":"https://imac.test/rips/\#(song).mp3"}"#.utf8)
        } else {
            payload = Data("{}".utf8)
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
