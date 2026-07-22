import XCTest

/// History mode UI — launches straight into History (PDJ_START_SECTION) with a deterministic
/// seeded timeline (PDJ_SEED_HISTORY). Verifies the default Unified view renders the seeded plays,
/// the two-destination tab control swaps correctly, and the Playback-only sort/filter/paging still
/// work once you switch to that tab.
final class HistoryUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()
        return app
    }

    @MainActor
    func testUnifiedShowsSeededPlays() {
        let app = launch()
        // Default view is Unified — the seeded plays appear in the combined timeline.
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20),
                      "Unified History should render seeded plays")
        XCTAssertTrue(app.staticTexts["Roygbiv"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Xtal"].firstMatch.exists)
    }

    /// The tab control shows the two views you're NOT in. From the default Unified view the tabs are
    /// [Playback | Collection] (no Unified tab); tapping Playback swaps them to [Collection | Unified].
    @MainActor
    func testDestinationTabsSwapOnSwitch() {
        let app = launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        // Default Unified: the two destinations are Playback and Collection; Unified itself is hidden.
        XCTAssertTrue(app.el("history-tab-playback").exists)
        XCTAssertTrue(app.el("history-tab-collection").exists)
        XCTAssertFalse(app.el("history-tab-unified").exists,
                       "the current (Unified) view should not appear as a tappable tab")
        // Switch to Playback → the pair becomes Collection + Unified (a way back), Playback hidden.
        app.el("history-tab-playback").tap()
        XCTAssertTrue(app.el("history-tab-unified").waitForExistence(timeout: 5),
                      "switching to Playback should surface a Unified tab to return")
        XCTAssertTrue(app.el("history-tab-collection").exists)
        XCTAssertFalse(app.el("history-tab-playback").exists)
    }

    /// The Timeline/By-song mode picker was REMOVED (2026-07-18) — no such control exists.
    @MainActor
    func testNoLegacyModePicker() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.segmentedControls["history-mode"].exists,
                       "the Timeline/By-song picker should be gone")
    }

    /// Sort/filter drive the Playback timeline only, so they surface after switching to that tab.
    /// The History-only "Last played" field is the default sort and shows in the Sort sheet.
    @MainActor
    func testSortSheetOffersLastPlayedOnPlayback() {
        let app = launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        app.el("history-tab-playback").tap()
        app.buttons["history-sort"].tap()
        XCTAssertTrue(app.staticTexts["Last played"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["sort-done"].tap()
    }

    @MainActor
    func testFilterSheetOpensOnPlayback() {
        let app = launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        app.el("history-tab-playback").tap()
        app.buttons["history-filter"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))
        app.buttons["filter-done"].tap()
    }

    /// The Playback timeline pages incrementally like the Browser. With PDJ_PAGE_SIZE=3 and 8 seeded
    /// plays, page 1 holds only 3 rows — a row far down must render only if the budget grows on scroll.
    @MainActor
    func testPlaybackPagesPastFirstPage() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY_COUNT"] = "8"
        app.launchEnvironment["PDJ_PAGE_SIZE"] = "3"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        app.el("history-tab-playback").tap()
        // Newest play (i=0) is at the top; the oldest (i=7 → "Cut 8") is last.
        XCTAssertTrue(app.staticTexts["Track 1"].firstMatch.waitForExistence(timeout: 10))
        let last = app.staticTexts["Cut 8"].firstMatch
        var tries = 0
        while !last.exists && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(last.waitForExistence(timeout: 5),
                      "a late row never rendered — Playback paging didn't grow past page 1")
    }
}
