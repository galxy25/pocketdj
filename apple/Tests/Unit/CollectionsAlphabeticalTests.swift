import XCTest
@testable import PocketDJ

/// Every picker / menu / remote list of collections reads the A–Z accessors, so "alphabetical
/// by default" holds regardless of creation order (the stored arrays keep creation order).
@MainActor
final class CollectionsAlphabeticalTests: XCTestCase {

    private func makeStore(_ name: String = #function) -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-az-\(name)-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        return CollectionsStore(fileURL: url)
    }

    func testPocketsAndPlaylistsAZIgnoreCaseAndCreationOrder() {
        let store = makeStore()
        for n in ["zebra", "Apple", "mango", "Banana"] { _ = store.createPocket(n) }
        for n in ["Warmup", "afterhours", "Closer"] { _ = store.createPlaylist(n) }
        XCTAssertEqual(store.pocketsAZ.map(\.name), ["Apple", "Banana", "mango", "zebra"])
        XCTAssertEqual(store.playlistsAZ.map(\.name), ["afterhours", "Closer", "Warmup"])
        // Stored order is untouched (creation order) — only the accessors sort.
        XCTAssertEqual(store.pockets.map(\.name), ["zebra", "Apple", "mango", "Banana"])
    }

    func testNumericAwareOrdering() {
        let store = makeStore()
        for n in ["Set 10", "Set 2", "Set 1"] { _ = store.createPlaylist(n) }
        XCTAssertEqual(store.playlistsAZ.map(\.name), ["Set 1", "Set 2", "Set 10"])
    }

    func testAutoMixIntentSourcesAreAlphabeticalWithinKind() {
        let store = makeStore()
        for n in ["Zed", "Alpha"] { _ = store.createPocket(n) }
        for n in ["Yankee", "Bravo"] { _ = store.createPlaylist(n) }
        let names = AutoMixSourceEntity.all(in: store).map(\.name)
        XCTAssertEqual(names, ["Alpha", "Zed", "Bravo", "Yankee"])
    }
}
