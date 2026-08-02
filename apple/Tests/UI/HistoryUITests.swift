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

    /// Feature (2026-07-22): History is the DEFAULT landing tab on every platform. With a
    /// freshly-cleared store (PDJ_USE_FIXTURE clears lastSection) and NO PDJ_START_SECTION to
    /// pin a section, the app must open straight onto History — proving the launch default,
    /// not a restored/forced section. `history-tab-playback` renders only on the History screen.
    @MainActor
    func testHistoryIsDefaultLandingSection() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        // Deliberately NO PDJ_START_SECTION — this is what proves History is the default.
        app.launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20),
                      "with nothing to restore, the app should land on History by default")
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

    // MARK: R3 — activity rows survive an item this device's catalog can't resolve

    /// The R3 rendering, driven for real. `PDJ_SEED_ACTIVITY` seeds one row per resolution state;
    /// the Collection tab must render all three usefully:
    ///  • resolvable → named from the live catalog,
    ///  • DENORMALIZED (the R3 case — an Apple Music song never indexed on this device) → still
    ///    named, from the record-time title/artist snapshots,
    ///  • bare legacy row → "an unknown item" PLUS the raw id, so it is never a blank row.
    /// Before the fix the first case was the only one that could exist, because the add that
    /// produces the second was never recorded at all.
    @MainActor
    func testCollectionActivityRendersUnresolvableItems() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_ACTIVITY"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()

        XCTAssertTrue(app.el("history-tab-collection").waitForExistence(timeout: 20))
        app.el("history-tab-collection").tap()

        // (2) The R3 row: its id resolves to NOTHING in this catalog, but the snapshots name it.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Running It Up"))
                        .firstMatch.waitForExistence(timeout: 10),
                      "an add of a song this device never indexed must still name the song")
        XCTAssertTrue(app.staticTexts["Aria"].firstMatch.exists,
                      "the denormalized artist should render beneath the headline")

        // (3) The bare legacy row: no title anywhere → an honest placeholder AND the raw id.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "an unknown item"))
                        .firstMatch.exists,
                      "a row with no resolvable item should say so rather than show a bare id as its title")
        XCTAssertTrue(app.staticTexts["sng_ghost_legacy"].firstMatch.exists,
                      "the raw id should still be shown (dimmed) so the row stays traceable")
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
