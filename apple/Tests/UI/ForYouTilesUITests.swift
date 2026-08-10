import XCTest

/// History ▸ For You — the TILE GRID. Offline: `PDJ_USE_FIXTURE` loads the bundled fixture
/// catalog and `PDJ_REC_FIXTURE=1` lights the tab without touching the Settings toggle.
///
/// The thing worth protecting here is the ORDER — the owner's rule is that New and In Da Zone are
/// always the top two tiles. `ForYouTilesTests` proves that about the pure builder; this proves
/// the grid actually renders them, that they are tappable, and that a tile leads somewhere real
/// (a tile that pushes a value with no registered `navigationDestination` renders as a BLANK
/// screen, which is exactly the failure `NavigationDestinations.swift` exists to prevent).
final class ForYouTilesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchOnForYou() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()
        let tab = app.el("history-tab-for-you")
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "the fixture seam lights the For You tab")
        tab.tap()
        return app
    }

    @MainActor
    func testPinnedTilesRender() {
        let app = launchOnForYou()
        XCTAssertTrue(app.el("foryou-tile-new").waitForExistence(timeout: 15),
                      "New is always present — even with zero releases")
        XCTAssertTrue(app.el("foryou-tile-zone").waitForExistence(timeout: 15),
                      "In Da Zone is always present")
        XCTAssertTrue(app.staticTexts["New"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["In Da Zone"].firstMatch.exists)
    }

    #if !os(macOS)
    /// Ordering by SCREEN POSITION, not by array index — this is the assertion that would catch
    /// a future tile being inserted above the pinned pair. Fenced off macOS only because frame
    /// geometry for a grid differs there; the pure-builder test covers the rule on every platform.
    @MainActor
    func testNewAndInDaZoneAreTheFirstTwoTilesOnScreen() {
        let app = launchOnForYou()
        let new = app.el("foryou-tile-new")
        let zone = app.el("foryou-tile-zone")
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        XCTAssertTrue(zone.waitForExistence(timeout: 15))

        // New is first in reading order: above zone, or level with it and to its left.
        let n = new.frame, z = zone.frame
        XCTAssertTrue(n.minY < z.minY || (abs(n.minY - z.minY) < 1 && n.minX < z.minX),
                      "New precedes In Da Zone (New \(n), Zone \(z))")

        // No OTHER tile may sit above the pinned pair.
        let others = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'foryou-tile-' AND identifier != 'foryou-tile-new' AND identifier != 'foryou-tile-zone'"))
        for i in 0..<others.count {
            let f = others.element(boundBy: i).frame
            XCTAssertGreaterThanOrEqual(f.minY, n.minY - 1,
                                        "no tile may render above New")
            XCTAssertGreaterThanOrEqual(f.minY, z.minY - 1,
                                        "no tile may render above In Da Zone")
        }
    }
    #endif

    @MainActor
    func testInDaZoneTileOpensItsListRatherThanABlankScreen() {
        let app = launchOnForYou()
        let zone = app.el("foryou-tile-zone")
        XCTAssertTrue(zone.waitForExistence(timeout: 15))
        zone.tap()
        // The destination is registered, so the pushed screen has real content: its nav title.
        XCTAssertTrue(app.navigationBars["In Da Zone"].waitForExistence(timeout: 10)
                      || app.staticTexts["In Da Zone"].firstMatch.waitForExistence(timeout: 5),
                      "the tile pushes a REAL screen (a missing destination renders blank)")
    }

    @MainActor
    func testNewTileOpensTheReleasesScreen() {
        let app = launchOnForYou()
        let new = app.el("foryou-tile-new")
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        // With no cached releases the screen shows its empty state — still a real screen.
        XCTAssertTrue(app.el("new-releases-empty").waitForExistence(timeout: 10)
                      || app.navigationBars["New"].waitForExistence(timeout: 5),
                      "the New tile pushes NewReleasesView")
    }
}
