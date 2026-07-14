import XCTest
@testable import PocketDJ

/// The app↔widget bridge. The widget process can't read the app's live stores, so the app
/// publishes a `NowPlayingSnapshot` into the shared App Group and the widget's transport
/// buttons route back through `WidgetPlaybackController` (in-process) or the command channel
/// (app quit). These tests cover the codec + the routing without needing a real widget host.
@MainActor
final class WidgetNowPlayingTests: XCTestCase {
    override func tearDown() {
        // Don't leak wired closures across tests.
        WidgetPlaybackController.shared.toggle = nil
        WidgetPlaybackController.shared.next = nil
        WidgetPlaybackController.shared.previous = nil
        super.tearDown()
    }

    // MARK: Snapshot codec

    func testSnapshotRoundTrips() throws {
        let snap = NowPlayingSnapshot(
            isPlaying: true, hasContent: true, title: "Title", artist: "Artist",
            songId: "sng_1", coverVersion: 3,
            upNext: [.init(id: "u1", songId: "sng_2", title: "Two", artist: "A"),
                     .init(id: "u2", songId: "sng_3", title: "Three", artist: "B")])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        XCTAssertEqual(snap, back)
        XCTAssertEqual(back.upNext.count, 2)
        XCTAssertEqual(back.upNext.first?.title, "Two")
    }

    func testEmptySnapshotIsIdle() {
        XCTAssertFalse(NowPlayingSnapshot.empty.hasContent)
        XCTAssertFalse(NowPlayingSnapshot.empty.isPlaying)
        XCTAssertTrue(NowPlayingSnapshot.empty.upNext.isEmpty)
    }

    // MARK: In-process transport routing (widget button → live playback)

    func testTransportIntentsRouteToController() async throws {
        var toggled = 0, nexted = 0, prevved = 0
        WidgetPlaybackController.shared.toggle = { toggled += 1 }
        WidgetPlaybackController.shared.next = { nexted += 1 }
        WidgetPlaybackController.shared.previous = { prevved += 1 }

        _ = try await NowPlayingToggleIntent().perform()
        _ = try await NowPlayingNextIntent().perform()
        _ = try await NowPlayingPreviousIntent().perform()

        XCTAssertEqual(toggled, 1, "toggle intent hit the toggle closure")
        XCTAssertEqual(nexted, 1, "next intent hit the next closure")
        XCTAssertEqual(prevved, 1, "previous intent hit the previous closure")
    }

    /// When no in-process handler is wired (app quit), the intent must NOT crash — it silently
    /// falls back to the command channel (which no-ops if the App Group is unavailable in-sim).
    func testTransportIntentWithoutControllerDoesNotCrash() async throws {
        WidgetPlaybackController.shared.toggle = nil
        _ = try await NowPlayingToggleIntent().perform()   // fallback path — must not throw/crash
    }

    // MARK: Command channel (only when the shared App Group is reachable)

    func testCommandChannelRoundTripsWhenGroupAvailable() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        WidgetCommandChannel.send(.next)
        // Fresh command drains once; a second drain is empty.
        XCTAssertEqual(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970), .next)
        XCTAssertNil(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970))
    }

    func testCommandChannelDropsStaleCommand() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        WidgetCommandChannel.send(.toggle)
        // A drain far in the future exceeds maxAge → the stale command is discarded.
        XCTAssertNil(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970 + 120))
    }
}
