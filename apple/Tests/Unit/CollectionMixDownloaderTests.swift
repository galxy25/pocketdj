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

    /// A `.pocket` crate and a `.playlist` crate side by side must union exactly like two
    /// pockets do (task #61: `MixSource` gained a `.playlist` case so a playlist can be a Mix
    /// deck source directly, with no convert-to-pocket step first). Pins `MixSource.playlist`'s
    /// `Hashable`/dictionary-key behavior and that the downloader's generic machinery treats it
    /// identically to the existing two kinds — no special-casing anywhere in `begin(sources:)`.
    func testPocketAndPlaylistCratesUnionLikeTwoPockets() async throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let byCrate: [MixSource: [String]] = [
            .pocket("sap"): ["s1", "s2", "shared"],
            .playlist("pls_joy"): ["j1", "j2", "shared"],
        ]
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { byCrate[$0] ?? [] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.declaredMemberCount = { byCrate[$0]?.count ?? 0 }
        d.catalogSongCount = { 100 }

        d.begin(sources: [.pocket("sap"), .playlist("pls_joy")])
        XCTAssertEqual(d.totalCount, 5,
                       "a pocket + a playlist union exactly like two pockets — 3 + 3 minus 1 shared = 5")
        d.cancel()
    }

    // MARK: playlist crate resolves through the SAME catalog walk a pocket/setlist does (task #61)

    /// A REAL playlist (not a stubbed source) resolves through `MixResolver.loadables(for:)`
    /// exactly like a pocket: catalog-resolved, burned-file-only, in PLAYLIST order, deduped.
    /// Before `.playlist` existed on `MixSource`, a user had to duplicate/convert a playlist
    /// into a pocket before Mix would accept it as a crate (the field "sap"/"joy" investigation
    /// that filed task #61); this pins the direct path — no conversion, no materialization.
    func testPlaylistSourceResolvesBurnedTracksInPlaylistOrder() async throws {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let collectionsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixdl-playlist-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: collectionsURL) }
        let collections = CollectionsStore(fileURL: collectionsURL)
        collections.app = app

        let rips = makeRips()
        // sng_3 is deliberately NEVER burned — it must drop out of the resolved loadables
        // exactly like an un-burned pocket member does.
        let burns = try MixBurnFixture.burnStore(ids: ["sng_1", "sng_2"], rips: rips)
        let studioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixdl-playlist-studio-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: studioURL) }
        let studio = StudioStore(fileURL: studioURL)

        let pl = collections.createPlaylist("Evening Set")
        collections.addSong("sng_1", toPlaylist: pl.id)
        collections.addSong("sng_2", toPlaylist: pl.id)
        collections.addSong("sng_3", toPlaylist: pl.id)   // never burned

        let resolver = MixResolver(app: app, collections: collections, burns: burns, studio: studio)
        let loadables = resolver.loadables(for: .playlist(pl.id))

        XCTAssertEqual(loadables.map(\.songId), ["sng_1", "sng_2"],
                       "burned-only, in PLAYLIST order — the un-burned sng_3 drops out")
        XCTAssertEqual(loadables.first?.title, "Neon")
        XCTAssertEqual(loadables.first?.artist, "Aria")

        // The pre-catalog declared count sees all 3 nodes regardless of burn state — mirrors
        // how a pocket's declaredMemberCount is catalog-independent (task #53's diagnostic).
        XCTAssertEqual(collections.declaredMemberCount(for: .playlist(pl.id)), 3)
        XCTAssertEqual(collections.declaredMemberCount(for: .playlist("pls_missing")), 0,
                       "an unknown playlist id declares zero, same as an unknown pocket/setlist")
    }

    // MARK: catalogShortfall — the partial-catalog banner's source (follow-up to task #56)

    /// `catalogShortfall` is the field "two crates → total=1" signature turned into published
    /// state: non-nil exactly when the crates DECLARED more members than resolved (an enabled
    /// source unsynced/still loading on this device), nil whenever `totalCount` already covers
    /// what was declared — a collection that legitimately has fewer resolvable tracks (or a
    /// stale/inconsistent declared reading below `totalCount`) must NOT trip the banner. Cancel
    /// resets it, matching `totalCount`/`downloadedCount`'s own reset.
    func testCatalogShortfallReflectsPartialCatalogAndClearsOnCancel() throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in ["s1", "s2", "s3"] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.catalogSongCount = { 100 }

        // declared > total: 2 of a declared 5 members resolved — a genuine catalog gap.
        d.declaredMemberCount = { _ in 5 }
        d.begin(sources: [.pocket("sap")])
        XCTAssertEqual(d.totalCount, 3)
        let shortfall = d.catalogShortfall
        XCTAssertEqual(shortfall?.declared, 5, "declared > total ⇒ non-nil, names the declared count")
        XCTAssertEqual(shortfall?.total, 3, "…and the resolved count")
        d.cancel()
        XCTAssertNil(d.catalogShortfall, "cancel resets the run's telemetry, shortfall included")

        // declared == total exactly: nothing was dropped for catalog reasons.
        d.declaredMemberCount = { _ in 3 }
        d.begin(sources: [.pocket("sap")])
        XCTAssertNil(d.catalogShortfall, "declared == total ⇒ nothing missing, no banner")
        d.cancel()

        // declared < total: a resolver seam reading LOWER than what actually resolved (stale
        // cache) must never announce a false-positive shortfall either.
        d.declaredMemberCount = { _ in 1 }
        d.begin(sources: [.pocket("sap")])
        XCTAssertNil(d.catalogShortfall, "declared < total never counts as a shortfall")
        d.cancel()

        // No declaredMemberCount seam at all (nil in production tests / an unwired app path):
        // never fabricate a shortfall from an absent diagnostic.
        d.declaredMemberCount = nil
        d.begin(sources: [.pocket("sap")])
        XCTAssertNil(d.catalogShortfall, "no declared-count seam ⇒ no opinion, no banner")
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

// MARK: - 2026-10-30 iPad Auto Mix stall (After Midnight A + Moon Walk B, "404 of 418 … 4 ripping")

extension CollectionMixDownloaderTests {

    /// A downloader over a token-bearing rip server ("https://imac.test", token "tok").
    private func makeAuthedRips(token: String = "tok") -> (RipsStore, SettingsStore) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloaderStubURLProtocol.self]
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://imac.test"
        settings.ripToken = token
        rips.settings = settings
        return (rips, settings)
    }

    private func withRipLaneTunables(stallTicks: Int = 133, retryBase: Int = 2, retryMax: Int = 67,
                                     reprobe: TimeInterval = 120) {
        CollectionMixDownloader.ripStallTicks = stallTicks
        CollectionMixDownloader.ripRetryBaseTicks = retryBase
        CollectionMixDownloader.ripRetryMaxTicks = retryMax
        RipsStore.authReprobeSeconds = reprobe
        addTeardownBlock {
            await MainActor.run {
                CollectionMixDownloader.ripStallTicks = 133
                CollectionMixDownloader.ripRetryBaseTicks = 2
                CollectionMixDownloader.ripRetryMaxTicks = 67
                RipsStore.authReprobeSeconds = 120
            }
        }
    }

    // MARK: Bug 2 — the "partial catalog" was cross-crate overlap

    /// The field numbers verbatim, scaled down: two crates that SHARE members, every member
    /// resolved. The old raw sum (declared 279 + 139 = 418 vs the deduped union 404) announced
    /// "14/418 unresolved — catalog still loading" with nothing missing at all.
    func testOverlappingCratesAreNotAPartialCatalog() throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let byCrate: [MixSource: [String]] = [
            .pocket("after-midnight"): ["s1", "s2", "s3", "s4", "s5"],
            .pocket("moon-walk"): ["s4", "s5", "m1", "m2"],
        ]
        var declared: [MixSource: Int] = [.pocket("after-midnight"): 5, .pocket("moon-walk"): 4]
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { byCrate[$0] ?? [] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.declaredMemberCount = { declared[$0] ?? 0 }
        d.catalogIsLoading = { true }

        d.begin(sources: [.pocket("after-midnight"), .pocket("moon-walk")])
        XCTAssertEqual(d.totalCount, 7, "5 + 4 minus the 2 shared = 7")
        XCTAssertNil(d.catalogShortfall,
                     "overlap is NOT a shortfall — the 2026-10-30 '404 of 418' banner was a false alarm")
        d.cancel()

        // A REAL gap on top of the overlap still surfaces, with the overlap excluded.
        declared[.pocket("moon-walk")] = 6        // 2 Moon Walk members aren't in the catalog
        d.begin(sources: [.pocket("after-midnight"), .pocket("moon-walk")])
        XCTAssertEqual(d.catalogShortfall?.declared, 9, "5 + 6 declared − 2 overlap")
        XCTAssertEqual(d.catalogShortfall?.total, 7)
        XCTAssertTrue(d.catalogStillLoading)
        d.cancel()
    }

    /// Bug 2's recovery half: a run that started on a partial catalog re-resolves when the
    /// catalog lands — ripped late members join the burn lane, un-ripped ones the rip lane,
    /// and the shortfall clears (or flips to the honest "not in this device's catalog" copy).
    func testCatalogReassignFoldsLateMembersIntoTheRun() async throws {
        withRipLaneTunables()
        let (rips, _) = makeAuthedRips()
        rips.setManifest(["late-ripped": .init(key: "rips/late-ripped.mp3", source: "digital", durationMs: 60_000)])
        DownloaderStubURLProtocol.manifestBody = Data(#"{"late-ripped":{"key":"rips/late-ripped.mp3","durationMs":60000}}"#.utf8)
        DownloaderStubURLProtocol.statusCodeByPath["/rips/late-ripped.mp3"] = 404   // keep it in the lane
        DownloaderStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"late-unripped","status":"queued","jobId":"j1"}],
         "counts":{"ready":0,"queued":1,"inflight":0,"unknown":0,"total":1}}
        """.utf8)
        let burns = try MixBurnFixture.burnStore(ids: ["d1"], rips: rips)
        let engine = MixEngine(burns: burns)
        var resolved = ["d1", "n0"]          // n0: resolvable but un-ripped → the run is active
        var loading = true
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in resolved }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.declaredMemberCount = { _ in 5 }
        d.catalogIsLoading = { loading }

        d.begin(source: .pocket("crate"))
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.catalogShortfall?.total, 2)
        XCTAssertTrue(d.catalogStillLoading)
        await wait { DownloaderStubURLProtocol.count(path: "/rip-collection") == 1 }

        // The catalog finishes loading: 2 more members resolve (one ripped, one not); 1 never does.
        resolved = ["d1", "n0", "late-ripped", "late-unripped"]
        loading = false
        d.catalogDidChange()
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.totalCount, 4)
        XCTAssertEqual(d.catalogShortfall?.declared, 5)
        XCTAssertEqual(d.catalogShortfall?.total, 4)
        XCTAssertFalse(d.catalogStillLoading, "catalog loaded ⇒ the honest 'not in this catalog' copy")
        XCTAssertEqual(d.rippingCount, 2, "late-unripped joined n0 in the rip lane")
        await wait { DownloaderStubURLProtocol.count(path: "/rip-collection") == 2 }
        XCTAssertEqual(DownloaderStubURLProtocol.count(path: "/rip-collection"), 2,
                       "exactly one re-POST for the merged ids")
        let sent = DownloaderStubURLProtocol.lastBodyJSON(path: "/rip-collection")?["songIds"] as? [String]
        XCTAssertEqual(sent, ["n0", "late-unripped"], "the re-POST carries every still-pending id")

        // Last member lands in the catalog too → the shortfall clears on the next assign.
        resolved.append("late-3")
        d.catalogDidChange()
        XCTAssertEqual(d.totalCount, 5)
        XCTAssertNil(d.catalogShortfall)
        d.cancel()
    }

    // MARK: Bug 1 — rips never progressed (every call 401'd) yet the bar said "4 ripping"

    func testRefusedRipBatchSurfacesTokenRejectedRetriesAndRecovers() async throws {
        withRipLaneTunables(retryBase: 1, retryMax: 2, reprobe: 0.02)
        let (rips, _) = makeAuthedRips()
        DownloaderStubURLProtocol.statusCodeByPath["/rip-collection"] = 401
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips, ripIds: ["n1", "n2", "n3", "n4"])

        d.begin(source: .pocket("crate"))
        XCTAssertEqual(d.rippingCount, 4)
        await wait { d.laneIssue == .tokenRejected }
        XCTAssertEqual(d.laneIssue, .tokenRejected, "a 401 batch is a credential fault, not '4 ripping'")
        XCTAssertTrue(rips.isAuthRejected)
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: d.rippingCount, issue: d.laneIssue),
                       "· 4 can’t rip — import server rejected this device’s token")
        // Backoff retries keep knocking (no silent one-shot).
        await wait { DownloaderStubURLProtocol.count(path: "/rip-collection") >= 3 }
        XCTAssertGreaterThanOrEqual(DownloaderStubURLProtocol.count(path: "/rip-collection"), 3)

        // The token heals server-side: the next retry is accepted, the issue clears, and the
        // songs land as the manifest flips them.
        DownloaderStubURLProtocol.statusCodeByPath["/rip-collection"] = 200
        DownloaderStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"n1","status":"queued","jobId":"j1"}],
         "counts":{"ready":0,"queued":4,"inflight":0,"unknown":0,"total":4}}
        """.utf8)
        await wait { d.laneIssue == nil }
        XCTAssertNil(d.laneIssue, "an accepted batch clears the rejection for everyone")
        XCTAssertFalse(rips.isAuthRejected)
        for id in ["n1", "n2", "n3", "n4"] { DownloaderStubURLProtocol.statusCodeByPath["/rips/\(id).mp3"] = 404 }
        DownloaderStubURLProtocol.manifestBody = Data(
            #"{"n1":{"key":"rips/n1.mp3"},"n2":{"key":"rips/n2.mp3"},"n3":{"key":"rips/n3.mp3"},"n4":{"key":"rips/n4.mp3"}}"#.utf8)
        await wait { d.rippingCount == 0 }
        XCTAssertEqual(d.rippingCount, 0, "manifest flips moved every id out of the rip lane")
        d.cancel()
    }

    /// Accepted but nothing ever lands (server queue wedged behind a Music.app stall / passive
    /// rips): the watchdog flags it and re-requests instead of polling silently for 2 h.
    func testAcceptedButStalledRipIsFlaggedAndReRequested() async throws {
        withRipLaneTunables(stallTicks: 3)
        let (rips, _) = makeAuthedRips()
        DownloaderStubURLProtocol.bodyByPath["/rip-collection"] = Data("""
        {"results":[{"songId":"n1","status":"queued","jobId":"j1"}],
         "counts":{"ready":0,"queued":1,"inflight":0,"unknown":0,"total":1}}
        """.utf8)
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips, ripIds: ["n1"])

        d.begin(source: .pocket("crate"))
        await wait { d.laneIssue == .ripsStalled }
        XCTAssertEqual(d.laneIssue, .ripsStalled)
        await wait { DownloaderStubURLProtocol.count(path: "/rip-collection") >= 2 }
        XCTAssertGreaterThanOrEqual(DownloaderStubURLProtocol.count(path: "/rip-collection"), 2,
                                    "a stalled batch is re-POSTed (server dedupes healthy jobs)")
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 1, issue: .ripsStalled),
                       "· 1 ripping (stalled — re-requested)")

        DownloaderStubURLProtocol.statusCodeByPath["/rips/n1.mp3"] = 404
        DownloaderStubURLProtocol.manifestBody = Data(#"{"n1":{"key":"rips/n1.mp3"}}"#.utf8)
        await wait { d.rippingCount == 0 && d.laneIssue == nil }
        XCTAssertNil(d.laneIssue, "the first landing clears the stall flag")
        d.cancel()
    }

    /// The burn lane under a rejected token: the miss names the credential, the song STAYS
    /// queued (it lands once the token heals) and the lane parks instead of spending a
    /// guaranteed 401 per track.
    func testBurnLaneParksAndKeepsSongsQueuedWhileTokenRejected() async throws {
        withRipLaneTunables(reprobe: 120)
        let (rips, settings) = makeAuthedRips()
        rips.setManifest([
            "p1": .init(key: "rips/p1.mp3", source: "digital", durationMs: 60_000),
            "p2": .init(key: "rips/p2.mp3", source: "digital", durationMs: 60_000),
        ])
        DownloaderStubURLProtocol.statusCodeByPath["/rips/presign"] = 401
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips, ripIds: ["p1", "p2"])

        d.begin(source: .pocket("crate"))
        await wait { burns.items["p1"]?.state == .error }
        XCTAssertEqual(burns.items["p1"]?.error,
                       "import server rejected this device's token — re-enter it in Settings ▸ Import server")
        XCTAssertEqual(d.laneIssue, .tokenRejected)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(DownloaderStubURLProtocol.count(path: "/rips/presign"), 1,
                       "ONE rejection, then the lane parks (no per-track 401 storm, no double retry)")
        XCTAssertEqual(Set(d.burnQueueForTesting), ["p1", "p2"], "the rejected song stayed queued")

        // Re-typed / credsync-healed token: the rejection clears by construction and the lane resumes.
        DownloaderStubURLProtocol.statusCodeByPath["/rips/presign"] = 200
        settings.ripToken = "healed"
        XCTAssertFalse(rips.isAuthRejected, "a token change clears the rejection immediately")
        await wait { DownloaderStubURLProtocol.count(path: "/rips/presign") >= 2 }
        XCTAssertGreaterThanOrEqual(DownloaderStubURLProtocol.count(path: "/rips/presign"), 2,
                                    "the burn lane resumed after the heal")
        d.cancel()
    }

    // MARK: RipsStore + stream gate auth semantics

    func testPresign401ThrowsUnauthorizedAndRejectionIsTokenScoped() async throws {
        withRipLaneTunables(reprobe: 60)
        let (rips, settings) = makeAuthedRips()
        rips.setManifest(["p1": .init(key: "rips/p1.mp3", source: "digital", durationMs: 60_000)])
        DownloaderStubURLProtocol.statusCodeByPath["/rips/presign"] = 401
        var clock = Date(timeIntervalSince1970: 1_000)
        rips.authNow = { clock }
        do {
            _ = try await rips.presignedURL(for: "p1")
            XCTFail("a 401 presign must throw")
        } catch let e as RipsStore.RipError {
            guard case .unauthorized = e else { return XCTFail("expected .unauthorized, got \(e)") }
        }
        XCTAssertTrue(rips.isAuthRejected)
        XCTAssertTrue(rips.authHoldoff, "inside the re-probe window")

        // The stream gate treats it as a credential hold, not a 60 s "server down".
        let streamer = MixStreamLoader(rips: rips, burns: try MixBurnFixture.burnStore(ids: [], rips: rips))
        XCTAssertFalse(streamer.canStream("p1"), "holdoff gates new streams")
        XCTAssertTrue(streamer.isRipped("p1"), "…but the song stays deferred (ripped), never dropped")

        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(rips.isAuthRejected, "the rejection is sticky for the UI…")
        XCTAssertFalse(rips.authHoldoff, "…but one re-probe is let through after the window")
        XCTAssertTrue(streamer.canStream("p1"))

        settings.ripToken = "different"
        XCTAssertFalse(rips.isAuthRejected, "a different token is not the rejected one")

        // A 2xx clears it outright.
        settings.ripToken = "tok"
        rips.noteAuthStatus(401, token: "tok")
        XCTAssertTrue(rips.isAuthRejected)
        rips.noteAuthStatus(200, token: "tok")
        XCTAssertFalse(rips.isAuthRejected)
    }

    func testRipCollection401ReportsRefusalInsteadOfEmptySuccess() async {
        let (rips, _) = makeAuthedRips()
        DownloaderStubURLProtocol.statusCodeByPath["/rip-collection"] = 401
        let r = await rips.ripCollection(["n1", "n2"])
        XCTAssertEqual(r.refusedStatus, 401)
        XCTAssertTrue(r.unauthorized)
        XCTAssertEqual(r.queued, 0)
        XCTAssertTrue(rips.isAuthRejected)
    }

    // MARK: Pure copy + backoff

    func testLaneCopyAndBackoffArePure() {
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 4, issue: nil), "· 4 ripping")
        XCTAssertNil(CollectionMixDownloader.rippingLabel(count: 0, issue: nil))
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 0, issue: .tokenRejected),
                       "· import server rejected this device’s token",
                       "a rejected token is shown even with nothing left to rip (the burn lane is blocked)")
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 2, issue: .noServer), "· 2 need an import server to rip")
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 3, issue: .ripServerRefused(503)),
                       "· 3 waiting — import server error 503, retrying")
        XCTAssertEqual(CollectionMixDownloader.shortfallCaption(declared: 418, total: 404, stillLoading: true),
                       "Only 404 of 418 songs available on this device — catalog still loading")
        XCTAssertEqual(CollectionMixDownloader.shortfallCaption(declared: 418, total: 404, stillLoading: false),
                       "14 of 418 crate songs aren’t in this device’s catalog — a source may be missing or disabled")
        XCTAssertEqual(CollectionMixDownloader.ripRetryDelayTicks(attempt: 1, base: 2, cap: 67), 2)
        XCTAssertEqual(CollectionMixDownloader.ripRetryDelayTicks(attempt: 3, base: 2, cap: 67), 8)
        XCTAssertEqual(CollectionMixDownloader.ripRetryDelayTicks(attempt: 10, base: 2, cap: 67), 67)
        XCTAssertEqual(CollectionMixDownloader.ripRetryDelayTicks(attempt: 99, base: 2, cap: 67), 67, "no overflow")
    }
}

// MARK: - Adversarial-review follow-ups (fix/mix-automix-crate-stall)

extension CollectionMixDownloaderTests {

    /// Review SHOULD 5 (+ the one-audio-owner rule): an exhausted mix is never revived over Now
    /// Playing — neither by a landing while another owner plays, nor by a catalog re-resolve.
    func testExhaustedMixNeverRestartsOverNowPlayingOrFromCatalogEvents() async throws {
        let rips = makeRips()
        let engineBurns = try MixBurnFixture.burnStore(ids: ["e1", "e2", "e3"], rips: rips)
        let engine = MixEngine(burns: engineBurns)
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        let dlBurns = try MixBurnFixture.burnStore(ids: ["e1"], rips: rips)
        var eligible = [loadable("e1")]
        var ripIds = ["e1", "e2"]
        let d = CollectionMixDownloader(engine: engine, burns: dlBurns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in ripIds }
        d.resolveLoadables = { _ in eligible }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        var nowPlaying = true
        d.otherAudioActive = { nowPlaying }
        d.begin(source: .pocket("pkt_test"))
        engine.startAutoMix([item("e1")], shuffled: false, lead: 15, fade: 3, label: "L")
        d.noteAutoStarted(initialIds: ["e1"], lead: 15, fade: 3, label: "L")
        engine.skipToNext(fadeSeconds: 5)
        XCTAssertTrue(engine.autoEndedExhausted)

        // A landing while Now Playing owns the audio: no restart.
        eligible.append(loadable("e2"))
        d.simulateLandingForTesting("e2")
        XCTAssertFalse(engine.autoMixing, "a landing must never start Auto-DJ over Now Playing")

        // A catalog re-resolve (hours later) with Now Playing idle: still no revival.
        nowPlaying = false
        ripIds.append("e3")
        eligible.append(loadable("e3"))
        d.catalogDidChange()
        XCTAssertFalse(engine.autoMixing, "a catalog event never revives an exhausted/finished mix")
        engine.teardown()
        d.cancel()
    }

    /// Review MUST 4: a transport failure on /rip-collection is a FAILED batch (the lane backs
    /// off) — never the ~400-POST per-song fallback reported as success.
    func testRipCollectionTransportFailureIsAFailedBatchNotAPerSongStorm() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://imac.test"
        settings.ripToken = "tok"
        rips.settings = settings
        FailingURLProtocol.reset()

        let r = await rips.ripCollection(["n1", "n2", "n3"])
        XCTAssertEqual(r.refusedStatus, RipsStore.transportFailureStatus)
        XCTAssertFalse(r.unauthorized)
        XCTAssertEqual(FailingURLProtocol.count(path: "/rip"), 0, "no per-song /rip fallback storm")
        XCTAssertEqual(FailingURLProtocol.count(path: "/rip-collection"), 1)
        XCTAssertFalse(rips.isAuthRejected, "a transport failure says nothing about the token")
        XCTAssertEqual(CollectionMixDownloader.rippingLabel(count: 3, issue: .ripServerRefused(RipsStore.transportFailureStatus)),
                       "· 3 waiting — can’t reach the import server, retrying")
    }

    /// The lane under a transport failure: issue set, backoff (bounded request count), no
    /// "accepted" clear.
    func testRipLaneBacksOffOnTransportFailure() async throws {
        withRipLaneTunables(retryBase: 4, retryMax: 4)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://imac.test"
        rips.settings = settings
        FailingURLProtocol.reset()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = makeDownloader(engine: engine, burns: burns, rips: rips, ripIds: ["n1", "n2"])
        d.begin(source: .pocket("crate"))
        await wait { d.laneIssue == .ripServerRefused(RipsStore.transportFailureStatus) }
        XCTAssertEqual(d.laneIssue, .ripServerRefused(RipsStore.transportFailureStatus))
        // 20 ticks at 10 ms with a 4-tick backoff ⇒ ~5 requests, never one per tick.
        try await Task.sleep(nanoseconds: 200_000_000)
        let n = FailingURLProtocol.count(path: "/rip-collection")
        XCTAssertGreaterThanOrEqual(n, 2, "it keeps retrying")
        XCTAssertLessThanOrEqual(n, 12, "…on a backoff, not every tick")
        XCTAssertEqual(FailingURLProtocol.count(path: "/rip"), 0)
        d.cancel()
    }

    /// Review MUST 3: a 401 that comes back for the OLD token after the token was changed
    /// mid-flight must not mark the NEW token rejected.
    func testInFlight401ForOldTokenDoesNotRejectTheNewToken() async throws {
        let (rips, settings) = makeAuthedRips(token: "old-bad")
        rips.setManifest(["p1": .init(key: "rips/p1.mp3", source: "digital", durationMs: 60_000)])
        DownloaderStubURLProtocol.statusCodeByPath["/rips/presign"] = 401
        DownloaderStubURLProtocol.onRequest = { path in
            // The token is re-typed / credsync-healed while the presign is on the wire.
            if path.hasSuffix("/rips/presign") { DispatchQueue.main.sync { MainActor.assumeIsolated { settings.ripToken = "new-good" } } }
        }
        addTeardownBlock { DownloaderStubURLProtocol.onRequest = nil }
        _ = try? await rips.presignedURL(for: "p1")
        XCTAssertEqual(settings.ripToken, "new-good")
        XCTAssertFalse(rips.isAuthRejected, "the 401 is charged to the token it was SENT with")
        settings.ripToken = "old-bad"
        XCTAssertTrue(rips.isAuthRejected, "…which IS recorded as rejected")
    }

    /// Review SHOULD 6: the "still loading" copy flips once the catalog reaches `.loaded`, even
    /// when no member moved (the unchanged-refresh path never re-assigns the catalog).
    func testShortfallCopyFlipsWhenCatalogFinishesLoadingWithoutNewMembers() throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: ["s1"], rips: rips)
        let engine = MixEngine(burns: burns)
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in ["s1"] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.declaredMemberCount = { _ in 3 }
        var loading = true
        d.catalogIsLoading = { loading }
        d.begin(source: .pocket("crate"))
        XCTAssertTrue(d.catalogStillLoading)
        loading = false
        d.catalogDidChange()          // what AppModel.onCatalogLoaded triggers
        XCTAssertEqual(d.catalogShortfall?.declared, 3)
        XCTAssertFalse(d.catalogStillLoading, "loaded ⇒ honest 'not in this catalog' copy")
        d.cancel()
    }
}

/// Every request fails at the transport layer (no HTTP response) — counts paths.
private final class FailingURLProtocol: URLProtocol {
    private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    static func reset() { lock.lock(); counts = [:]; lock.unlock() }
    static func count(path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock(); Self.counts[path, default: 0] += 1; Self.lock.unlock()
        if path.hasSuffix("manifest.json") {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
}

// MARK: - Stub (the ManifestStubURLProtocol idiom — manifest GET + rip server POSTs + audio GETs)

private final class DownloaderStubURLProtocol: URLProtocol {
    static var manifestBody = Data("{}".utf8)
    static var bodyByPath: [String: Data] = [:]
    static var statusCodeByPath: [String: Int] = [:]
    /// Fired (off-main, before the response) with the request path — mid-flight side effects.
    static var onRequest: ((String) -> Void)?
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
        Self.onRequest?(path)
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
