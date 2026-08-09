import XCTest
@testable import PocketDJ

/// CollectionsStore.historyContext — resolves the Play-History source-kind + name for a
/// sequencer run tagged with `sourceSetlistId`. Album / playlist / pocket / single all realize
/// into the ONE reserved Now Playing setlist, so the kind comes from `nowPlayingSource` (stamped
/// by playNow) while the name is the reserved setlist's (which playNow names after the source).
@MainActor
final class PlayHistoryContextTests: XCTestCase {

    private var heldApp: AppModel?
    override func tearDown() { heldApp = nil; super.tearDown() }

    private func wiredStore() async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-histctx-\(UUID().uuidString).json"))
        s.app = app
        return s
    }

    /// The id the sequencer is tagged with for album/playlist/pocket/single plays.
    private func nowPlayingId(_ s: CollectionsStore) -> String? { s.nowPlayingSetlist()?.id }

    func testPlaylistPlayResolvesToPlaylistKindAndName() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Roadtrip")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.playNow(playlistId: pl.id)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .playlist)
        XCTAssertEqual(ctx.name, "Roadtrip")
    }

    func testPocketPlayResolvesToPocketKindAndName() async {
        let s = await wiredStore()
        let p = s.createPocket("Warmup")
        s.addSong("sng_1", toPocket: p.id)
        s.playNow(pocketId: p.id)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .pocket)
        XCTAssertEqual(ctx.name, "Warmup")
    }

    func testAlbumPlayResolvesToAlbumKindAndName() async {
        let s = await wiredStore()
        s.playNow(songIds: ["sng_1", "sng_2"], name: "Greatest Hits", source: .album)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .album)
        XCTAssertEqual(ctx.name, "Greatest Hits")
    }

    /// A single-song play (`.browser`) carries no set name — the row reads just "Browser".
    func testSingleSongPlayResolvesToBrowserWithNoName() async {
        let s = await wiredStore()
        s.playNow(songIds: ["sng_1"], name: "Some Song", source: .browser)
        let ctx = s.historyContext(forSourceSetlistId: nowPlayingId(s))
        XCTAssertEqual(ctx.source, .browser)
        XCTAssertNil(ctx.name)
    }

    /// nil / unknown source id → a generic set list (defensive default).
    func testNilSourceDefaultsToSetlist() async {
        let s = await wiredStore()
        let ctx = s.historyContext(forSourceSetlistId: nil)
        XCTAssertEqual(ctx.source, .setlist)
        XCTAssertNil(ctx.name)
    }

    // MARK: - Game runs (the composition root's resolver)

    /// A game hands the SHARED sequencer a `puzzle_<roundId>` tag that names no collection, so
    /// the collections lookup alone can only answer (.setlist, nil) — History then labelled every
    /// Gem Collector play "Set list". `PocketDJApp.historyContext` maps the tag first.
    func testPuzzleRunResolvesToTheGameSourceNamedByGameKind() async {
        let s = await wiredStore()
        let tag = "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)"
        let ctx = PocketDJApp.historyContext(forSourceSetlistId: tag, collections: s)
        XCTAssertEqual(ctx.source, .game)
        // Asserted against GameKind.label, not a literal: the point of routing through the enum
        // is that a display rename can't silently drift back out of History.
        XCTAssertEqual(ctx.name, GameKind.collectorsPuzzle.label)
        XCTAssertEqual(ctx.name, "Gem Collector")
    }

    /// The History row's accessory string (HistoryView.contextLabel's composition).
    func testGameRowReadsGameThenTheGameName() async {
        let s = await wiredStore()
        let ctx = PocketDJApp.historyContext(
            forSourceSetlistId: "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)",
            collections: s)
        XCTAssertEqual("\(ctx.source.label) · \(ctx.name ?? "")", "Game · Gem Collector")
    }

    /// The game branch must be a pure ADDITION: every non-game run still resolves exactly as the
    /// collections lookup says, including the reserved Now Playing setlist and the nil default.
    func testNonGameRunsResolveExactlyAsBefore() async {
        let s = await wiredStore()
        guard let sl = s.realize(songIds: ["sng_1"], name: "Friday Night") else {
            return XCTFail("realize failed")
        }

        let direct = PocketDJApp.historyContext(forSourceSetlistId: sl.id, collections: s)
        XCTAssertEqual(direct.source, .setlist)
        XCTAssertEqual(direct.name, "Friday Night")

        let pl = s.createPlaylist("Roadtrip")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.playNow(playlistId: pl.id)
        let np = PocketDJApp.historyContext(forSourceSetlistId: nowPlayingId(s), collections: s)
        XCTAssertEqual(np.source, .playlist)
        XCTAssertEqual(np.name, "Roadtrip")

        let none = PocketDJApp.historyContext(forSourceSetlistId: nil, collections: s)
        XCTAssertEqual(none.source, .setlist)
        XCTAssertNil(none.name)
    }

    /// The RECORD hook's half of the round-trip (PocketDJApp's `recordNonMixHistory` builds this
    /// PlayContext from the run's captured origin): a play attributed to a game round lands in the
    /// log as a game row, so the History timeline reads "Game · Gem Collector".
    /// The CAPTURE half — the sequencer snapshotting this at `play()` from the installed provider
    /// — is `SetlistPlayerTests.testPuzzleRunCapturesTheGameHistoryContext`.
    func testAGamePlayIsRecordedAsAGameRow() async {
        let s = await wiredStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-histctx-game-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let history = PlayHistoryStore(fileURL: url)

        let tag = "\(CollectorsPuzzleEngine.runTagPrefix)\(UUID().uuidString)"
        let origin = PocketDJApp.historyContext(forSourceSetlistId: tag, collections: s)
        history.record(songId: "sng_1", context: .init(source: origin.source, contextId: tag,
                                                       contextName: origin.name),
                       at: 1_000)

        XCTAssertEqual(history.events.first?.source, .game)
        XCTAssertEqual(history.events.first?.contextName, "Gem Collector")
    }

    /// `PlaySource` raw values are PERSISTED tokens. Adding `.game` must not disturb the existing
    /// ones, and a history document written BEFORE the case existed must still decode whole — a
    /// throwing decode reads the log as empty and the next save pushes that emptiness everywhere.
    func testAddingTheGameCaseKeepsOldTokensAndOldDocumentsReadable() throws {
        XCTAssertEqual(PlayHistoryStore.PlaySource.game.rawValue, "game")
        for s in PlayHistoryStore.PlaySource.allCases where s != .game {
            XCTAssertEqual(PlayHistoryStore.PlaySource(rawValue: s.rawValue), s,
                           "pre-existing token \(s.rawValue) must still round-trip")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-histctx-legacy-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // A document as an older build wrote it: no `game` rows, no `originInstallId`.
        let json = """
        {"schemaVersion":1,"installId":"old-device","events":[
          {"id":"\(UUID().uuidString)","songId":"s_a","playedAt":1000,"source":"browser"},
          {"id":"\(UUID().uuidString)","songId":"s_b","playedAt":2000,"source":"setlist",
           "contextId":"set_1","contextName":"Friday Night"}
        ]}
        """
        try Data(json.utf8).write(to: url, options: .atomic)

        let store = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(store.events.map(\.songId), ["s_a", "s_b"])
        XCTAssertEqual(store.events.map(\.source), [.browser, .setlist])
        XCTAssertEqual(store.events[1].contextName, "Friday Night")
    }
}
