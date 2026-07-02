import XCTest
@testable import PocketDJ

/// SetlistPlayer's LIVE queue edits (the Now Playing panel's Up-Next list):
/// `upcoming` / `moveUpcoming` / `removeUpcoming` / `appendToQueue` mutate ONLY the
/// not-yet-played tail — the current track and played history are untouched, so
/// auto-advance's ownership guard and manual-jump adoption keep working — and an
/// append is picked up by the normal advance without any restart. All assertions
/// run synchronously after `play()` (its `playCurrent` runs in a not-yet-started
/// Task), mirroring SetlistPlayerTests' state-only style — no audio involved.
@MainActor
final class NowPlayingQueueTests: XCTestCase {

    private func makeSequencer() -> SetlistPlayer {
        let config = URLSessionConfiguration.ephemeral
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: config))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-npqueue-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
    }

    private func item(_ id: String) -> SetlistPlayer.Item {
        .init(id: id, title: id.uppercased(), artist: "A")
    }

    func testUpcomingIsTheNotYetPlayedTail() {
        let seq = makeSequencer()
        XCTAssertTrue(seq.upcoming.isEmpty)                      // idle ⇒ empty
        seq.play([item("a"), item("b"), item("c")], sourceSetlistId: "set_1")
        XCTAssertEqual(seq.upcoming.map(\.id), ["b", "c"])       // current "a" excluded
        seq.skipNext()
        XCTAssertEqual(seq.upcoming.map(\.id), ["c"])
        seq.skipNext()
        XCTAssertTrue(seq.upcoming.isEmpty)                      // on the last track
        seq.stop()
    }

    func testMoveUpcomingReordersOnlyTheTail() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: "set_1")
        // Move "d" (upcoming offset 2) to the front of the tail (offset 0).
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(seq.queue.map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(seq.index, 0)                             // current untouched
        XCTAssertEqual(seq.queue[seq.index].id, "a")
        seq.stop()
    }

    func testRemoveUpcomingLeavesCurrentAndHistory() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: "set_1")
        seq.skipNext()                                           // current = "b", history = ["a"]
        seq.removeUpcoming(atOffsets: IndexSet(integer: 0))      // removes "c"
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(seq.index, 1)
        XCTAssertEqual(seq.queue[seq.index].id, "b")             // still the same current
        seq.stop()
    }

    func testAppendIsPickedUpByAdvanceAndNeverRestarts() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b")], sourceSetlistId: "set_1")
        seq.appendToQueue([item("e")])
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "e"])
        XCTAssertEqual(seq.index, 0)                             // no restart, no jump
        seq.skipNext(); seq.skipNext()                           // advance into the appended track
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(seq.queue[seq.index].id, "e")
        seq.skipNext()                                           // past the end ⇒ clean stop
        XCTAssertFalse(seq.isRunning)
        XCTAssertTrue(seq.queue.isEmpty)
    }

    func testEditsAreNoOpsWhenIdleOrNothingUpcoming() {
        let seq = makeSequencer()
        seq.appendToQueue([item("x")])                           // idle ⇒ no resurrect
        XCTAssertTrue(seq.queue.isEmpty)
        XCTAssertFalse(seq.isRunning)

        seq.play([item("a")], sourceSetlistId: "set_1")          // single track ⇒ no tail
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        seq.removeUpcoming(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(seq.queue.map(\.id), ["a"])
        XCTAssertEqual(seq.index, 0)
        seq.stop()
    }
}

/// The Now Playing panel's add-search: tokenized name+artist matching where EVERY
/// token must hit, ranked then capped — over the fixture catalog.
@MainActor
final class NowPlayingSearchTests: XCTestCase {

    private func makeApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    func testSongSearchMatchesNameOrArtistAllTokens() async {
        let app = await makeApp()
        XCTAssertEqual(NowPlayingSearch.songs(matching: "aria", app: app).map(\.id),
                       ["sng_1", "sng_2", "sng_3"])              // artist match, catalog order
        XCTAssertEqual(NowPlayingSearch.songs(matching: "get down", app: app).map(\.id),
                       ["sng_6"])                                // both tokens must hit
        XCTAssertTrue(NowPlayingSearch.songs(matching: "get zebra", app: app).isEmpty)
        XCTAssertTrue(NowPlayingSearch.songs(matching: "   ", app: app).isEmpty)
    }

    func testAlbumSearchMatchesNameOrArtist() async {
        let app = await makeApp()
        XCTAssertEqual(NowPlayingSearch.albums(matching: "night drive", app: app).map(\.id),
                       ["alb_1"])
        XCTAssertEqual(NowPlayingSearch.albums(matching: "cobalt", app: app).map(\.id),
                       ["alb_3"])
    }

    func testRankCapsResults() {
        let items = (0..<40).map { "item \($0)" }
        let out = NowPlayingSearch.rank(query: "item", items: items, haystack: { $0 }, cap: 5)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.first, "item 0")                      // stable catalog order
    }
}
