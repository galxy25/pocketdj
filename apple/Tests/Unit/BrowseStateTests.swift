import XCTest
@testable import PocketDJ

@MainActor
final class BrowseStateTests: XCTestCase {
    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    func testAppLoadsFromLoader() async {
        let app = await loadedApp()
        XCTAssertEqual(app.state, .loaded)
        XCTAssertEqual(app.albumCount, 3)
        XCTAssertEqual(app.songCount, 7)
        XCTAssertEqual(app.sourceName, "Test Crate")
    }

    func testBaseItemsByKind() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .album
        XCTAssertEqual(b.baseItems(app).count, 3)
        b.kind = .song
        XCTAssertEqual(b.baseItems(app).count, 7)
    }

    func testQueryFiltersSongs() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        b.query = "neon"
        XCTAssertEqual(b.results(app).map(\.idString), ["sng_1"])
    }

    func testResultsPipelineFilterThenSort() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        b.clauses = [bpm]
        b.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        // 110,116,124,128 → sng_4, sng_6, sng_2, sng_1
        XCTAssertEqual(b.results(app).map(\.idString), ["sng_4", "sng_6", "sng_2", "sng_1"])
    }

    func testGenreOptionsAreCategoriesInPriorityOrder() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .album
        // Raw genres Electronic/Jazz/"Funk / Soul" collapse to categories and sort
        // in the PWA's priority order: jazz, funk, electronic.
        XCTAssertEqual(b.options(for: "genre", in: app), ["jazz", "funk", "electronic"])
    }

    func testCamelotOptionsAreWheelOrdered() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        // present camelots: 7A,7B,8A,8B,9A,9B,10A in wheel order
        XCTAssertEqual(b.options(for: "camelot", in: app),
                       ["7A", "7B", "8A", "8B", "9A", "9B", "10A"])
    }

    func testPersistsAndRestoresPrefs() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let b = BrowseState(defaults: defaults)
        b.kind = .song
        b.layout = .list
        b.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]
        b.sortKeys = [SortKey(field: "camelot", dir: .desc)]
        b.persist()

        let restored = BrowseState(defaults: defaults)
        XCTAssertEqual(restored.kind, .song)
        XCTAssertEqual(restored.layout, .list)
        XCTAssertEqual(restored.clauses.first?.field, "bpm")
        XCTAssertEqual(restored.clauses.first?.min, 100)
        XCTAssertEqual(restored.sortKeys.first?.dir, .desc)
    }

    func testActiveFilterCountIgnoresIncomplete() async {
        let b = BrowseState()
        b.clauses = [Clause(field: "bpm", op: .eq, value: ""),          // incomplete
                     Clause(field: "explicit", op: .eq, value: "true")]  // complete
        XCTAssertEqual(b.activeFilterCount, 1)
    }
}
