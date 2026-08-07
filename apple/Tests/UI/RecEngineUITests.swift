import XCTest

/// Recommendation engine UI — the Settings toggle (default OFF), the History ▸ For You tab's
/// gating, and the fixture-driven For You list. All offline: `PDJ_USE_FIXTURE` swaps in a stub
/// transport (PocketDJApp), and `PDJ_REC_FIXTURE=1` serves canned suggestions.
final class RecEngineUITests: XCTestCase {

    /// Drive a SwiftUI Form Toggle to `on`. A center `.tap()` sometimes lands on the label and
    /// misses the switch, so if the value doesn't flip, tap the trailing thumb (the
    /// xcuitest-form-toggle-tap doctrine).
    private func setToggle(_ toggle: XCUIElement, on: Bool) {
        let want = on ? "1" : "0"
        guard (toggle.value as? String) != want else { return }
        toggle.tap()
        if (toggle.value as? String) != want {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, tries: Int = 10) {
        var n = 0
        while !element.exists && n < tries {
            app.swipeUp()
            n += 1
        }
    }

    @MainActor
    func testSettingsToggleDefaultOffAndFlips() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()

        let toggle = app.switches["rec-engine-toggle"].firstMatch
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Recommendations toggle exists")
        XCTAssertEqual(toggle.value as? String, "0", "the engine ships OFF — the privacy default")

        setToggle(toggle, on: true)
        XCTAssertEqual(toggle.value as? String, "1")

        // ON reveals the section's controls, including the destructive cloud-data delete.
        let deleteRow = app.el("rec-delete-cloud")
        scrollTo(deleteRow, in: app, tries: 4)
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5),
                      "enabling reveals the Delete-cloud-data action")
    }

    @MainActor
    func testForYouTabHiddenWhenDisabled() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()

        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        XCTAssertFalse(app.el("history-tab-for-you").exists,
                       "engine off (default) → no For You tab from Unified")
        // Switch views — the tab must stay absent from every tab bar.
        app.el("history-tab-playback").tap()
        XCTAssertTrue(app.el("history-tab-unified").waitForExistence(timeout: 5))
        XCTAssertFalse(app.el("history-tab-for-you").exists,
                       "engine off → no For You tab from Playback either")
        app.el("history-tab-collection").tap()
        XCTAssertTrue(app.el("history-tab-unified").waitForExistence(timeout: 5))
        XCTAssertFalse(app.el("history-tab-for-you").exists,
                       "engine off → no For You tab from Collection either")
    }

    @MainActor
    func testForYouShowsFixtureSuggestions() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()

        let forYouTab = app.el("history-tab-for-you")
        XCTAssertTrue(forYouTab.waitForExistence(timeout: 20),
                      "the fixture seam lights the For You tab")
        forYouTab.tap()

        XCTAssertTrue(app.any("foryou-row-sng_fix_1").waitForExistence(timeout: 10),
                      "the canned suggestion renders (no catalog resolution required)")
        XCTAssertTrue(app.staticTexts["Neon"].firstMatch.exists)

        // The row's ＋ opens the Add-to-Collection sheet (its Pockets section is unique to it).
        app.el("foryou-add-sng_fix_1").tap()
        XCTAssertTrue(app.staticTexts["Pockets"].firstMatch.waitForExistence(timeout: 10),
                      "tapping ＋ presents the Add to… sheet")
    }
}
