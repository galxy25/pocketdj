import XCTest
@testable import PocketDJ

/// PlayStatsStore — the device-local play tracker (count + last-played per song) the
/// storage manager's soft-cap prune orders by. Times are injected epoch-ms values.
@MainActor
final class PlayStatsStoreTests: XCTestCase {

    private func makeStore() -> (store: PlayStatsStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-playstats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlayStatsStore(fileURL: url), url)
    }

    func testFirstPlayCountsOnce() {
        let (store, _) = makeStore()
        store.notePlayed("s1", at: 1_000)
        XCTAssertEqual(store.playCount("s1"), 1)
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000)
        XCTAssertEqual(store.playCount("other"), 0)
        XCTAssertNil(store.lastPlayedAt("other"))
    }

    /// A re-note inside the 30 s window (seek/restart, or the burned-play double-hook —
    /// rips + coordinator both fire) refreshes lastPlayedAt but does NOT re-count.
    func testRecountWindowAbsorbsDoubleNotes() {
        let (store, _) = makeStore()
        store.notePlayed("s1", at: 1_000)
        store.notePlayed("s1", at: 1_000 + PlayStatsStore.recountWindowMs - 1)
        XCTAssertEqual(store.playCount("s1"), 1)
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000 + PlayStatsStore.recountWindowMs - 1)
        // Past the window → a genuine second listen.
        store.notePlayed("s1", at: 1_000 + 2 * PlayStatsStore.recountWindowMs)
        XCTAssertEqual(store.playCount("s1"), 2)
    }

    /// An out-of-order (older) timestamp never regresses lastPlayedAt.
    func testStaleTimestampDoesNotRegressLastPlayed() {
        let (store, _) = makeStore()
        store.notePlayed("s1", at: 5_000)
        store.notePlayed("s1", at: 4_000)
        XCTAssertEqual(store.lastPlayedAt("s1"), 5_000)
    }

    func testEmptyIdIsIgnored() {
        let (store, _) = makeStore()
        store.notePlayed("", at: 1_000)
        XCTAssertTrue(store.stats.isEmpty)
    }

    func testPersistsAndReloads() {
        let (store, url) = makeStore()
        store.notePlayed("s1", at: 1_000)
        store.notePlayed("s2", at: 2_000)
        let reloaded = PlayStatsStore(fileURL: url)
        XCTAssertEqual(reloaded.playCount("s1"), 1)
        XCTAssertEqual(reloaded.lastPlayedAt("s2"), 2_000)
    }
}
