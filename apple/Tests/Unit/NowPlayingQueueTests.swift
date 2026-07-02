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
        seq.removeUpcoming(uids: [seq.upcoming[0].uid])          // removes "c"
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(seq.index, 1)
        XCTAssertEqual(seq.queue[seq.index].id, "b")             // still the same current
        seq.stop()
    }

    /// REGRESSION (review): removal is verified by row IDENTITY, so a ✕ tap that
    /// raced an auto-advance still removes exactly the tapped song — and a uid that
    /// advanced INTO the current slot is no longer eligible (never yank the needle).
    func testRemoveByUidSurvivesQueueAdvancingUnderTheTap() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: "set_1")
        let cUid = seq.upcoming[1].uid                           // "c" rendered at offset 1
        seq.skipNext()                                           // queue shifts under the tap
        seq.removeUpcoming(uids: [cUid])                         // stale render, right song
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d"])

        let dUid = seq.upcoming[0].uid                           // "d"
        seq.skipNext()                                           // "d" becomes the CURRENT track
        seq.removeUpcoming(uids: [dUid])                         // must not touch the needle
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(seq.queue[seq.index].id, "d")
        seq.stop()
    }

    /// REGRESSION (review): a drag that ends against a stale (pre-advance) snapshot
    /// delivers offsets past the live tail — they are clamped/filtered, never a trap.
    func testMoveUpcomingClampsStaleOffsets() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: "set_1")
        seq.skipNext()                                           // tail = [c, d]
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 99)   // stale far drop
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d", "c"])           // clamped to end
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 42), toOffset: 0)   // all-stale source
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "d", "c"])           // no-op, no trap
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

    /// Context-menu re-slotting: "Move to top" bumps an upcoming row to right
    /// after the current track; "Move to bottom" sends it to the end — by
    /// identity, current slot untouched, unknown uids ignored.
    func testMoveUpcomingNextAndToEnd() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b"), item("c"), item("d")], sourceSetlistId: "set_1")
        let dUid = seq.upcoming[2].uid                           // "d"
        seq.moveUpcomingNext(uid: dUid)                          // → right after current
        XCTAssertEqual(seq.queue.map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(seq.queue[seq.index].id, "a")

        seq.moveUpcomingToEnd(uid: dUid)                         // → bottom
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "c", "d"])
        seq.moveUpcomingNext(uid: UUID())                        // unknown uid: no-op
        XCTAssertEqual(seq.queue.map(\.id), ["a", "b", "c", "d"])
        seq.stop()
    }

    /// "Add next" (search context menu) inserts right after the current track,
    /// ahead of the existing tail; ＋/"Add to end" keeps appending.
    func testInsertNextInQueue() {
        let seq = makeSequencer()
        seq.play([item("a"), item("b")], sourceSetlistId: "set_1")
        seq.insertNextInQueue([item("x"), item("y")])
        XCTAssertEqual(seq.queue.map(\.id), ["a", "x", "y", "b"])
        XCTAssertEqual(seq.index, 0)
        XCTAssertEqual(seq.queue[seq.index].id, "a")             // current untouched

        seq.skipNext(); seq.skipNext(); seq.skipNext()           // current = "b" (last)
        seq.insertNextInQueue([item("z")])                       // insert clamps to tail
        XCTAssertEqual(seq.queue.map(\.id), ["a", "x", "y", "b", "z"])

        seq.stop()
        seq.insertNextInQueue([item("q")])                       // idle: no resurrect
        XCTAssertTrue(seq.queue.isEmpty)
    }

    func testEditsAreNoOpsWhenIdleOrNothingUpcoming() {
        let seq = makeSequencer()
        seq.appendToQueue([item("x")])                           // idle ⇒ no resurrect
        XCTAssertTrue(seq.queue.isEmpty)
        XCTAssertFalse(seq.isRunning)

        seq.play([item("a")], sourceSetlistId: "set_1")          // single track ⇒ no tail
        seq.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        seq.removeUpcoming(uids: [seq.queue[0].uid])
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
        XCTAssertEqual(NowPlayingSearch.songs(matching: "aria", in: app.songs).map(\.id),
                       ["sng_1", "sng_2", "sng_3"])              // artist match, catalog order
        XCTAssertEqual(NowPlayingSearch.songs(matching: "get down", in: app.songs).map(\.id),
                       ["sng_6"])                                // both tokens must hit
        XCTAssertTrue(NowPlayingSearch.songs(matching: "get zebra", in: app.songs).isEmpty)
        XCTAssertTrue(NowPlayingSearch.songs(matching: "   ", in: app.songs).isEmpty)
    }

    func testAlbumSearchMatchesNameOrArtist() async {
        let app = await makeApp()
        XCTAssertEqual(NowPlayingSearch.albums(matching: "night drive", in: app.albums).map(\.id),
                       ["alb_1"])
        XCTAssertEqual(NowPlayingSearch.albums(matching: "cobalt", in: app.albums).map(\.id),
                       ["alb_3"])
    }

    /// REGRESSION (review): an exact-name match must surface even when the cap is
    /// already full of earlier catalog rows that merely CONTAIN the query.
    func testRankPrefersExactAndPrefixNameMatches() {
        let items = (0..<30).map { "covers of neon \($0)" } + ["neon nights", "neon"]
        let out = NowPlayingSearch.rank(query: "neon", items: items,
                                        name: { $0 }, artist: { _ in "" }, cap: 5)
        XCTAssertEqual(out.first, "neon")                        // exact beats everything
        XCTAssertEqual(out[1], "neon nights")                    // then name-prefix
        XCTAssertEqual(out.count, 5)                             // cap still applies
        XCTAssertEqual(out[2], "covers of neon 0")               // then catalog order
    }
}
