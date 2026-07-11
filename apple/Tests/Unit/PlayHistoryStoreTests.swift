import XCTest
@testable import PocketDJ

/// PlayHistoryStore — the device-local, APPEND-ONLY play timeline behind History mode.
/// Unlike PlayStatsStore (aggregate), each play is its own event with source + set/mix context.
@MainActor
final class PlayHistoryStoreTests: XCTestCase {

    private func makeStore() -> (store: PlayHistoryStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-playhistory-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlayHistoryStore(fileURL: url), url)
    }

    private func ctx(_ source: PlayHistoryStore.PlaySource, _ name: String? = nil,
                    id: String? = nil) -> PlayHistoryStore.PlayContext {
        PlayHistoryStore.PlayContext(source: source, contextId: id, contextName: name)
    }

    func testRecordsEventWithContext() {
        let (store, _) = makeStore()
        let ev = store.record(songId: "s1", title: "Song One", artist: "Artist",
                              context: ctx(.setlist, "Friday Mix", id: "set_1"), at: 1_000)
        XCTAssertNotNil(ev)
        XCTAssertEqual(store.events.count, 1)
        let e = store.events[0]
        XCTAssertEqual(e.songId, "s1")
        XCTAssertEqual(e.playedAt, 1_000)
        XCTAssertEqual(e.source, .setlist)
        XCTAssertEqual(e.contextName, "Friday Mix")
        XCTAssertEqual(e.contextId, "set_1")
        XCTAssertEqual(e.title, "Song One")
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000)
        XCTAssertEqual(store.playCount("s1"), 1)
    }

    /// The same song played 3× (in different sets) is 3 timeline rows — NOT deduped like the
    /// aggregate stats — as long as each is outside the re-count window.
    func testSameSongMultiplePlaysAreDistinctEvents() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.setlist, "Set A"), at: 1_000)
        store.record(songId: "s1", context: ctx(.mix, "Session 2"),
                     at: 1_000 + PlayHistoryStore.recountWindowMs)
        store.record(songId: "s1", context: ctx(.browser),
                     at: 1_000 + 2 * PlayHistoryStore.recountWindowMs)
        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.playCount("s1"), 3)
        XCTAssertEqual(store.events.map(\.source), [.setlist, .mix, .browser])
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000 + 2 * PlayHistoryStore.recountWindowMs)
    }

    /// A re-note inside the 30 s window (seek/restart, or the burned-play double-hook where
    /// rips + coordinator both fire) collapses to ONE event.
    func testRecountWindowCollapsesDoubleHook() {
        let (store, _) = makeStore()
        let a = store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        let b = store.record(songId: "s1", context: ctx(.browser),
                             at: 1_000 + PlayHistoryStore.recountWindowMs - 1)
        XCTAssertNotNil(a)
        XCTAssertNil(b)                      // deduped
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.playCount("s1"), 1)
    }

    /// An OLDER play of the same song (out-of-order / clock-skew) is a DISTINCT event, not a
    /// window-collapsed re-note — a negative time delta must never read as "within the window".
    func testOutOfOrderOlderPlayIsRecordedAsDistinctEvent() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.mix, "Now"), at: 100_000)
        let older = store.record(songId: "s1", context: ctx(.browser), at: 10_000)   // long before
        XCTAssertNotNil(older)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.playCount("s1"), 2)
        XCTAssertEqual(store.lastPlayedAt("s1"), 100_000)   // last-played never regresses
    }

    func testEmptyIdIsIgnored() {
        let (store, _) = makeStore()
        XCTAssertNil(store.record(songId: "", context: ctx(.browser), at: 1_000))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testPersistsAndReloadsIncludingInstallId() {
        let (store, url) = makeStore()
        store.record(songId: "s1", context: ctx(.setlist, "Set A", id: "set_1"), at: 1_000)
        store.record(songId: "s2", context: ctx(.mix, "Session 1"), at: 2_000)
        let install = store.installId
        let reloaded = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.installId, install)          // stable identity for merge
        XCTAssertEqual(reloaded.events[0].contextName, "Set A")
        XCTAssertEqual(reloaded.playCount("s2"), 1)
        XCTAssertEqual(reloaded.lastPlayedAt("s1"), 1_000)
    }

    /// Event ids are stable + unique — the dedupe key a future cross-profile merge unions on.
    func testEventIdsAreUnique() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        store.record(songId: "s2", context: ctx(.browser), at: 2_000)
        XCTAssertNotEqual(store.events[0].id, store.events[1].id)
    }

    func testClearWipesEventsButKeepsInstall() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        let install = store.installId
        store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.playCount("s1"), 0)
        XCTAssertNil(store.lastPlayedAt("s1"))
        XCTAssertEqual(store.installId, install)
    }
}
