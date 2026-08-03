import XCTest
@testable import PocketDJ

/// ⤓ on a track that hasn't been ripped yet must START the rip and finish the download by itself —
/// durably, so leaving the screen or quitting the app doesn't lose the request.
@MainActor
final class PendingBurnTests: XCTestCase {

    private func makeStore(_ tag: String) -> (BurnStore, URL) {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pending-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (BurnStore(rips: rips, fileURL: url), url)
    }

    /// The whole point: the request outlives the app. A rip can take minutes and the user will
    /// leave — the intent has to be on disk, not in a view's @State.
    func testTheRequestSurvivesARelaunch() {
        let (burns, url) = makeStore("relaunch")
        burns.burnWhenRipped(songId: "s_1", title: "Neon", artist: "Aria")
        XCTAssertTrue(burns.isAwaitingBurn("s_1"))

        // Same file, fresh store — this is what a relaunch does.
        let rips2 = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                              session: URLSession(configuration: .ephemeral))
        let reopened = BurnStore(rips: rips2, fileURL: url)
        XCTAssertTrue(reopened.isAwaitingBurn("s_1"),
                      "a download asked for before a relaunch is still owed afterwards")
        XCTAssertEqual(reopened.pendingAfterRip["s_1"]?.title, "Neon",
                       "identity rides with it, so the burn needs no catalog lookup later")
    }

    /// Asking twice does not queue it twice.
    func testRequestIsIdempotent() {
        let (burns, _) = makeStore("idem")
        burns.burnWhenRipped(songId: "s_1", title: "Neon", artist: "Aria")
        burns.burnWhenRipped(songId: "s_1", title: "Neon", artist: "Aria")
        XCTAssertEqual(burns.pendingAfterRip.count, 1)
    }

    /// A pending song whose rip HASN'T landed stays pending — draining is not the same as giving up.
    func testDrainLeavesUnreadySongsQueued() async {
        let (burns, _) = makeStore("unready")
        burns.burnWhenRipped(songId: "s_missing", title: "Ghost", artist: "A")

        let burned = await burns.drainPendingAfterRip()

        XCTAssertEqual(burned, 0, "no file yet, so nothing to burn")
        XCTAssertTrue(burns.isAwaitingBurn("s_missing"), "…and the request is still owed")
    }

    func testCancelClearsTheRequest() {
        let (burns, _) = makeStore("cancel")
        burns.burnWhenRipped(songId: "s_1", title: "Neon", artist: "Aria")
        burns.cancelPendingBurn(songId: "s_1")
        XCTAssertFalse(burns.isAwaitingBurn("s_1"))
    }

    /// A document written before this feature existed must still decode.
    func testLegacyDocumentWithoutPendingDecodes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pending-legacy-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"schemaVersion":1,"items":[]}"#.utf8).write(to: url, options: .atomic)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: url)
        XCTAssertTrue(burns.pendingAfterRip.isEmpty, "absent key ⇒ nothing pending, not a crash")
    }
}
