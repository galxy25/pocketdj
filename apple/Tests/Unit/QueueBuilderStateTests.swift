import XCTest
@testable import PocketDJ

/// Queue builder (Now Playing ＋) — the controller behind the builder sheet.
/// Device search rides the BrowseState `refreshExternal` lane (the History
/// precedent, never the shared browse memo); cloud rides the Discover machinery;
/// adds map onto SetlistPlayer's live-edit primitives when a set runs and onto
/// the DRAFT accumulator when idle; Play consumes the draft for the playNow
/// funnel. Cloud adds must record catalog citizenship BEFORE queueing (playNow
/// drops ids absent from `songsById`).
@MainActor
final class QueueBuilderStateTests: XCTestCase {

    // MARK: Fixtures

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.queuebuilder.\(UUID().uuidString)")!
    }

    private func makeBuilder(_ defaults: UserDefaults? = nil) -> QueueBuilderState {
        QueueBuilderState(defaults: defaults ?? makeDefaults())
    }

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    private func makeRips() -> RipsStore {
        RipsStore(ripsBase: URL(string: "https://rips.test")!,
                  session: URLSession(configuration: .ephemeral))
    }

    /// Minimal live-playback stack (the JukeboxTests idiom) — real SetlistPlayer,
    /// no network resolution needed for queue-shape assertions.
    private func makeSequencer() -> SetlistPlayer {
        let rips = makeRips()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
    }

    private func item(_ id: String) -> SetlistPlayer.Item {
        SetlistPlayer.Item(id: id, title: id, artist: "A")
    }

    private func hit(_ storeId: String, title: String = "T", artist: String = "A",
                     durationMs: Int? = 200_000) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: storeId, title: title, artist: artist,
                              durationMs: durationMs, songId: "amrec_\(storeId)")
    }

    // MARK: Device filtering (the refreshExternal lane)

    func testDeviceSearchFiltersAndSortsThroughBrowsePipeline() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.bindExternalBase(app)
        b.songQuery = "neon"
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1"])

        // Clause + sort run through the SAME FilterEngine/SortEngine as the Browser.
        b.songQuery = ""
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        b.browse.clauses = [bpm]
        b.browse.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        await b.refreshDevice(app)
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_4", "sng_6", "sng_2", "sng_1"])
    }

    func testArtistRefineIsReadTimeOverDisplayItems() async {
        let app = await loadedApp()
        let b = makeBuilder()
        b.bindExternalBase(app)
        await b.refreshDevice(app)
        XCTAssertEqual(b.browse.displayItems.count, 7)   // no query: whole catalog
        b.artistQuery = "aria"
        XCTAssertEqual(b.deviceResults.map(\.idString), ["sng_1", "sng_2", "sng_3"])
        // The refine layers on top WITHOUT touching the published rows.
        XCTAssertEqual(b.browse.displayItems.count, 7)
    }

    func testRefineByArtistFoldingAndEdgeCases() throws {
        let items = try TestData.songItems()
        // Case-insensitive…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "COBALT").count, 2)
        // …diacritic-insensitive both directions…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "ária").count, 3)
        // …empty/whitespace = identity…
        XCTAssertEqual(QueueBuilderState.refineByArtist(items, artist: "  ").count, items.count)
        // …and a no-match term yields empty, not everything.
        XCTAssertTrue(QueueBuilderState.refineByArtist(items, artist: "zzz").isEmpty)
    }

    func testDeviceSignatureMovesWithEveryRecomputeInput() async {
        let app = await loadedApp()
        let b = makeBuilder()
        let s0 = b.deviceSignature(app)
        b.songQuery = "x"
        let s1 = b.deviceSignature(app)
        XCTAssertNotEqual(s0, s1)                       // query is in the signature
        b.artistQuery = "y"
        let s2 = b.deviceSignature(app)
        XCTAssertNotEqual(s1, s2)                       // artist refine re-fires the task
        b.browse.sortKeys = [SortKey(field: "bpm", dir: .desc)]
        XCTAssertNotEqual(s2, b.deviceSignature(app))   // sort too
    }

    // MARK: Mode switch

    func testModePersistsAndRoundTrips() {
        let defaults = makeDefaults()
        let b = makeBuilder(defaults)
        XCTAssertEqual(b.mode, .device)                 // fresh default
        b.mode = .cloud
        XCTAssertEqual(makeBuilder(defaults).mode, .cloud)   // restored
        b.mode = .device
        XCTAssertEqual(makeBuilder(defaults).mode, .device)
    }

    func testSwitchingToDeviceCancelsInFlightDiscover() async throws {
        let b = makeBuilder()
        b.mode = .cloud
        b.songQuery = "daft"
        b.refreshCloud(rips: makeRips())                // 400 ms debounce in flight
        b.mode = .device                                // cancels before it fires
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(b.discover.state, .idle)         // the late publish never landed
        XCTAssertTrue(b.discover.hits.isEmpty)
    }

    func testModeSwitchLeavesDeviceBrowseStateIntact() {
        let b = makeBuilder()
        b.songQuery = "neon"
        var c = Clause(field: "bpm", op: .between); c.min = 90; c.max = 130
        b.browse.clauses = [c]
        b.mode = .cloud
        b.mode = .device
        XCTAssertEqual(b.browse.query, "neon")
        XCTAssertEqual(b.browse.clauses.count, 1)
        XCTAssertEqual(b.browse.kind, .song)            // pinned throughout
    }

    // MARK: Add position — running regime (the live-edit primitives)

    func testAddPositionsIntoRunningQueue() {
        let seq = makeSequencer()
        let b = makeBuilder()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: nil)

        b.add([item("e")], at: .bottom, sequencer: seq)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "c", "d", "e"])

        b.add([item("f")], at: .top, sequencer: seq)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "f", "b", "c", "d", "e"])

        // Surprise slot: range is the LIVE tail (right-after-current ... end).
        var seenRange: ClosedRange<Int>?
        b.add([item("g")], at: .random, sequencer: seq, slot: { r in seenRange = r; return r.lowerBound })
        XCTAssertEqual(seenRange, 1...6)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "g", "f", "b", "c", "d", "e"])
        // The running regime never touches the draft.
        XCTAssertTrue(b.draft.isEmpty)
        seq.stop()
    }

    // MARK: Add position — draft regime (idle) + Play hand-off

    func testDraftAccumulatesWithPositionSemantics() {
        let seq = makeSequencer()                       // idle: primitives would no-op
        let b = makeBuilder()

        b.add([item("x")], at: .bottom, sequencer: seq)
        b.add([item("y")], at: .bottom, sequencer: seq)
        XCTAssertEqual(b.draft.map(\.id), ["x", "y"])

        b.add([item("z")], at: .top, sequencer: seq)
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "y"])

        var seenRange: ClosedRange<Int>?
        b.add([item("w")], at: .random, sequencer: seq, slot: { r in seenRange = r; return 2 })
        XCTAssertEqual(seenRange, 0...3)                // anywhere in the draft, inclusive ends
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "w", "y"])
        XCTAssertTrue(seq.queue.isEmpty)                // idle queue untouched
    }

    func testConsumeDraftForPlayReturnsIdsInOrderAndResets() {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.songQuery = "q"; b.artistQuery = "a"
        b.add([item("x"), item("y")], at: .bottom, sequencer: seq)
        b.add([item("z")], at: .top, sequencer: seq)

        let ids = b.consumeDraftForPlay()
        XCTAssertEqual(ids, ["z", "x", "y"])            // the playNow funnel's input, in draft order
        XCTAssertTrue(b.draft.isEmpty)
        XCTAssertEqual(b.songQuery, "")
        XCTAssertEqual(b.artistQuery, "")
        XCTAssertEqual(b.browse.query, "")              // the forward stayed in sync
    }

    func testDraftRemoveAndMove() {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.add([item("x"), item("y"), item("z")], at: .bottom, sequencer: seq)
        b.moveDraft(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(b.draft.map(\.id), ["z", "x", "y"])
        let yUid = b.draft[2].uid
        b.removeDraft(uids: [yUid])
        XCTAssertEqual(b.draft.map(\.id), ["z", "x"])
        b.removeDraft(uids: [UUID()])                   // unknown uid = no-op
        XCTAssertEqual(b.draft.map(\.id), ["z", "x"])
    }

    // MARK: Cloud add (record-before-queue ordering, both regimes)

    /// Seam stub: records call order and lets a test observe builder state AT the
    /// moment `recordProvisional` fires (the ordering contract under test).
    @MainActor
    private final class StubCloudAdder: QueueBuilderCloudAdding {
        var events: [String] = []
        var onRecord: (() -> Void)?
        func recordProvisional(_ hit: RipsStore.DiscoverHit) {
            events.append("record:\(hit.songId)"); onRecord?()
        }
        func performAdd(_ hit: RipsStore.DiscoverHit) async {
            events.append("perform:\(hit.songId)")
        }
    }

    func testCloudAddRecordsProvisionalBeforeDraftInsertThenPerforms() async {
        let seq = makeSequencer()
        let b = makeBuilder()
        let adder = StubCloudAdder()
        b.cloudAdder = adder
        adder.onRecord = { XCTAssertTrue(b.draft.isEmpty, "citizenship must land BEFORE the insert") }

        let task = b.addCloudHit(hit("123"), at: .bottom, sequencer: seq)
        // The synchronous half: recorded, then drafted — perform not yet run.
        XCTAssertEqual(adder.events, ["record:amrec_123"])
        XCTAssertEqual(b.draft.map(\.id), ["amrec_123"])
        // The minted item carries the hit's display + length metadata.
        XCTAssertEqual(b.draft[0].title, "T")
        XCTAssertEqual(b.draft[0].artist, "A")
        XCTAssertEqual(b.draft[0].lengthMs, 200_000)

        await task?.value
        XCTAssertEqual(adder.events, ["record:amrec_123", "perform:amrec_123"])
    }

    func testCloudAddLandsInLiveQueueWhenRunning() async {
        let seq = makeSequencer()
        let b = makeBuilder()
        let adder = StubCloudAdder()
        b.cloudAdder = adder
        seq.play([item("a"), item("b")], sourceSetlistId: nil)

        let task = b.addCloudHit(hit("9"), at: .top, sequencer: seq)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "amrec_9", "b"])
        XCTAssertTrue(b.draft.isEmpty)
        await task?.value
        XCTAssertEqual(adder.events, ["record:amrec_9", "perform:amrec_9"])
        seq.stop()
    }

    func testCloudAddWithoutAdderStillQueues() {
        let seq = makeSequencer()
        let b = makeBuilder()                           // no cloudAdder wired
        let task = b.addCloudHit(hit("7"), at: .bottom, sequencer: seq)
        XCTAssertNil(task)
        XCTAssertEqual(b.draft.map(\.id), ["amrec_7"])
    }

    // MARK: Production adapter (the DiscoverRow.addToCatalog move)

    func testAdapterRecordProvisionalMakesCatalogCitizen() async {
        let app = await loadedApp()
        let rips = makeRips()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-adds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        adds.onAdded = { [weak app] song in app?.injectDiscoverAdd(song) }
        rips.discoverAdds = adds
        let adapter = DiscoverQueueBuilderCloudAdder(app: app, rips: rips, library: nil)

        XCTAssertNil(app.songsById["amrec_123"])
        adapter.recordProvisional(hit("123", title: "New Song", artist: "Someone"))
        // The playNow gate: the id resolves in songsById the moment record returns.
        XCTAssertEqual(app.songsById["amrec_123"]?.name, "New Song")
        XCTAssertEqual(adds.entries.count, 1)

        adapter.recordProvisional(hit("123"))           // idempotent
        XCTAssertEqual(adds.entries.count, 1)

        // A song already in the catalog (any source) records nothing.
        adapter.recordProvisional(RipsStore.DiscoverHit(appleMusicId: "x", title: "Neon",
                                                        artist: "Aria", songId: "sng_1"))
        XCTAssertEqual(adds.entries.count, 1)
    }

    // MARK: Supersede blind spot (H1) — an owned recording must queue its OWN row

    private func indexSong(_ id: String, am: String?, name: String) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": "Roy Woods"]
        if let am { obj["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// A cloud hit for a recording the catalog ALREADY holds (an indexed row claims
    /// the same `appleMusicId`): `recordProvisional`'s supersede yields to the twin,
    /// so `amrec_X` never becomes a citizen — the queued item must carry the twin's
    /// id, or playNow silently drops the song from the set.
    func testCloudAddOfOwnedRecordingQueuesTheIndexedTwinNotTheDeadId() async {
        let app = AppModel()
        app.injectImported(songs: [indexSong("sng_real", am: "999", name: "How You Say My Name")],
                           albums: [])
        XCTAssertEqual(app.songId(forAppleMusicId: "999"), "sng_real")

        let rips = makeRips()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-qbuilder-twin-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        adds.onAdded = { [weak app] song in app?.injectDiscoverAdd(song) }
        rips.discoverAdds = adds
        let adapter = DiscoverQueueBuilderCloudAdder(app: app, rips: rips, library: nil)

        // The adapter's re-resolution, in isolation: dead provisional id → the twin.
        XCTAssertNil(app.songsById["amrec_999"])
        XCTAssertEqual(adapter.resolvedSongId(hit("999")), "sng_real")

        // End-to-end through addCloudHit: the DRAFT holds the live twin id.
        let seq = makeSequencer()
        let b = makeBuilder()
        b.cloudAdder = adapter
        _ = b.addCloudHit(hit("999", title: "How You Say My Name"), at: .bottom, sequencer: seq)
        XCTAssertNil(app.songsById["amrec_999"], "the provisional twin still yields")
        XCTAssertEqual(b.draft.map(\.id), ["sng_real"],
                       "the queued item must carry the id playNow can resolve")

        // A genuinely-new hit is untouched by the re-resolution.
        XCTAssertEqual(adapter.resolvedSongId(hit("1000")), "amrec_1000")
        // …and once a provisional IS a citizen, its own id stays authoritative.
        adapter.recordProvisional(hit("1000", title: "Something New"))
        XCTAssertNotNil(app.songsById["amrec_1000"])
        XCTAssertEqual(adapter.resolvedSongId(hit("1000")), "amrec_1000")
    }

    // MARK: Play failure (H2) — the draft must survive a refused Play

    func testPlayDraftConsumesOnlyOnSuccess() async {
        let seq = makeSequencer()
        let b = makeBuilder()
        b.songQuery = "q"; b.artistQuery = "a"
        b.add([item("x"), item("y")], at: .bottom, sequencer: seq)

        struct Refused: Error {}
        var seen: [String]?
        // Throwing funnel (onboarding veto / every id dropped): NOTHING is consumed.
        let failed = await b.playDraft { ids in seen = ids; throw Refused() }
        XCTAssertFalse(failed)
        XCTAssertEqual(seen, ["x", "y"])
        XCTAssertEqual(b.draft.map(\.id), ["x", "y"], "a failed Play must not lose the draft")
        XCTAssertEqual(b.songQuery, "q")
        XCTAssertEqual(b.artistQuery, "a")

        // Successful funnel: draft + queries reset, caller told to dismiss.
        let played = await b.playDraft { ids in XCTAssertEqual(ids, ["x", "y"]) }
        XCTAssertTrue(played)
        XCTAssertTrue(b.draft.isEmpty)
        XCTAssertEqual(b.songQuery, "")
        XCTAssertEqual(b.artistQuery, "")
    }

    func testPlayDraftEmptyDraftNeverFiresTheFunnel() async {
        let b = makeBuilder()
        let played = await b.playDraft { _ in XCTFail("empty draft must not reach playNow") }
        XCTAssertFalse(played)
    }
}
