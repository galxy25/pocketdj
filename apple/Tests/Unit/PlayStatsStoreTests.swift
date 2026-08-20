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

    // ── Skip tracking: the cumulative per-song total ─────────────────────────────────────────

    /// The relaunch-survival requirement: skips accumulate in the aggregate store (the history
    /// log trims; this must not), and a fresh store from the same file carries the total.
    func testNoteSkippedIncrementsCumulativeAndPersists() {
        let (store, url) = makeStore()
        store.notePlayed("s1", at: 1_000)
        store.noteSkipped("s1", at: 2_000)
        store.noteSkipped("s1", at: 3_000)
        XCTAssertEqual(store.skipCount("s1"), 2)
        XCTAssertEqual(store.playCount("s1"), 1, "a skip is not a play")
        let reloaded = PlayStatsStore(fileURL: url)
        XCTAssertEqual(reloaded.skipCount("s1"), 2, "the total survives relaunch")
    }

    /// Belt-and-braces: a skip arriving before any notePlayed creates the row without minting
    /// a phantom play, and keeps the legacy-migration invariant (`preTagPlayCount == 0`).
    func testNoteSkippedOnUnknownSongCreatesRow() {
        let (store, _) = makeStore()
        store.noteSkipped("s_new", at: 1_000)
        XCTAssertEqual(store.skipCount("s_new"), 1)
        XCTAssertEqual(store.playCount("s_new"), 0)
        XCTAssertEqual(store.stats["s_new"]?.preTagPlayCount, 0,
                       "a row this build writes is never mistaken for legacy")
        store.noteSkipped("", at: 1_000)
        XCTAssertNil(store.stats[""], "empty id ignored, like notePlayed")
    }

    /// ADDITIVE-OPTIONAL compat: an old document's row (no `skipCount` key) decodes with the
    /// existing fields untouched and `skipCount` nil, read as 0 — old data is never discarded.
    func testLegacyStatsRowDecodesWithNilSkipCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-stats-legacyskip-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"schemaVersion":1,"appleTaggingMigratedAtMs":500,
         "stats":{"s_old":{"playCount":7,"lastPlayedAt":1000,"appleCount":3,"preTagPlayCount":2}}}
        """
        try Data(legacy.utf8).write(to: url, options: .atomic)
        let store = PlayStatsStore(fileURL: url)
        XCTAssertEqual(store.playCount("s_old"), 7)
        XCTAssertEqual(store.stats["s_old"]?.appleCount, 3)
        XCTAssertNil(store.stats["s_old"]?.skipCount, "absent key decodes to nil, not a crash")
        XCTAssertEqual(store.skipCount("s_old"), 0, "nil reads as zero")
    }

    func testSkipCountsSnapshotOmitsZeroAndNil() {
        let (store, _) = makeStore()
        store.notePlayed("s_played", at: 1_000)      // no skips → nil skipCount
        store.noteSkipped("s_skipped", at: 2_000)
        let snap = store.skipCountsSnapshot()
        XCTAssertEqual(snap, ["s_skipped": 1], "only non-zero totals appear in the snapshot")
    }
}
