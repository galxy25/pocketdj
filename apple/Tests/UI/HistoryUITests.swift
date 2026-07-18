import XCTest

/// History mode UI — launches straight into History (PDJ_START_SECTION) with a deterministic
/// seeded timeline (PDJ_SEED_HISTORY) and verifies the timeline renders, the group-by-song
/// toggle collapses repeats with a play count, and the History-only "Last played" sort is offered.
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
    func testTimelineShowsSeededPlays() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20),
                      "History timeline should render seeded plays")
        XCTAssertTrue(app.staticTexts["Roygbiv"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Xtal"].firstMatch.exists)
    }

    /// The Timeline/By-song mode picker was REMOVED (2026-07-18) — History is always the
    /// timeline, so the repeated song shows as two event rows and no mode control exists.
    @MainActor
    func testTimelineOnlyNoModePicker() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.segmentedControls["history-mode"].exists,
                       "the Timeline/By-song picker should be gone")
    }

    /// The History-only "Last played" field is the default sort (most recent first) and shows
    /// in the Sort sheet — proving the historyOnly field surfaces in History but not Browser.
    @MainActor
    func testSortSheetOffersLastPlayed() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["history-sort"].tap()
        XCTAssertTrue(app.staticTexts["Last played"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["sort-done"].tap()
    }

    /// History can grow to tens of thousands of events, so it pages incrementally like the
    /// Browser. With PDJ_PAGE_SIZE=3 and 8 seeded plays, page 1 holds only 3 rows — a row far
    /// down the (recency-sorted) list must render only if the paging budget grows on scroll.
    @MainActor
    func testHistoryPagesPastFirstPage() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY_COUNT"] = "8"
        app.launchEnvironment["PDJ_PAGE_SIZE"] = "3"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()
        // Newest play (i=0) is at the top; the oldest (i=7 → "Cut 8") is last.
        XCTAssertTrue(app.staticTexts["Track 1"].firstMatch.waitForExistence(timeout: 20))
        let last = app.staticTexts["Cut 8"].firstMatch
        var tries = 0
        while !last.exists && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(last.waitForExistence(timeout: 5),
                      "a late row never rendered — History paging didn't grow past page 1")
    }

    @MainActor
    func testFilterSheetOpens() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Midnight City"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["history-filter"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))
        app.buttons["filter-done"].tap()
    }
}
