import XCTest

/// Recommendation engine UI — the Settings toggle (default OFF), the History ▸ For You tab's
/// gating, and the fixture-driven For You list. All offline: `PDJ_USE_FIXTURE` swaps in a stub
/// transport (PocketDJApp), and `PDJ_REC_FIXTURE=1` serves canned suggestions.
///
/// The Recommendations Settings section and the For You tab are SHARED product code (no
/// `#if os(…)` in `SettingsView.recommendationsSection` or `HistoryView.altTabs`), so the
/// macOS surface is real and shipped. What is iOS-only here is the *driving*: two of the three
/// tests below use `app.swipeUp()` on the Application element, which cannot resolve a hit point
/// on macOS. They carry the repo's `#if !os(macOS)` fence (as `ExplicitPreferenceUITests` and
/// `FavoritesUITests` do); `testForYouTabHiddenWhenDisabled` needs no scrolling and keeps
/// running on macOS, so the class still has a macOS test and `-only-testing:` on it resolves.
///
/// #TOUPDATE: reclaim macOS coverage of the toggle. `SettingsUITests` drives Form Toggles on
/// macOS unfenced (`settings-rip-from-cloud`, `debug-capture-toggle`) using a platform-split
/// scroll — `app.scrollViews.firstMatch.scroll(byDeltaX:deltaY:)` instead of `swipeUp()` — so
/// the "Toggle is a checkBox / `.value` is nil on macOS" reading of the gate failure looks
/// wrong: under `.formStyle(.grouped)` it is a `switch`, and the nil `.value` is most likely
/// the *absent* row of a lazy Form that never scrolled. Adopting `SettingsUITests.scrollDown`
/// here should let both fenced tests run on macOS. Not done in this fix because macOS XCUITest
/// could not be exercised on this machine to prove it (every macOS UI test, including
/// long-green ones, currently dies in `Failed to activate application … Running Background`),
/// and an unverifiable widening is worse than a fence.
final class RecEngineUITests: XCTestCase {
    /// Stop at the first failure. Without this a single broken scroll reports twice (once from
    /// inside the helper, once from the assertion that the un-scrolled element fails), which is
    /// what made the two failures here look like two different broken tests.
    override func setUp() { continueAfterFailure = false }

    #if !os(macOS)
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

    /// Scroll until `element` is in the tree — a SwiftUI Form is lazy, so an off-screen row is
    /// genuinely ABSENT and waiting alone never finds it. `swipeUp()` is the iOS-only idiom
    /// that fences this whole block.
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
    #endif

    /// Cross-platform (iPhone, iPad, Mac): the gating is pure view logic and the tab bar is a
    /// plain `Button` pair on every platform, so nothing here needs scrolling or a Toggle.
    @MainActor
    func testForYouTabHiddenWhenDisabled() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()

        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        XCTAssertFalse(app.el("history-tab-for-you").exists,
                       "engine off (default) → no For You tab from Playback")
        // Switch views — the tab must stay absent from every tab bar. With Unified removed the
        // bar shows EVERY tab (current one filled), so Collection is reachable directly.
        app.el("history-tab-collection").tap()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 5))
        XCTAssertFalse(app.el("history-tab-for-you").exists,
                       "engine off → no For You tab from Collection either")
    }

    #if !os(macOS)
    /// THE SUGGESTED TILE IS GONE, AND ITS CONTENT IS NOW IN In Da Zone.
    ///
    /// Owner, verbatim: *"remove Suggested tile (that is what New and In Da Zone [are])"* and
    /// *"new and in da zone should use the recommendation engine if available, only doing on
    /// device when not enabled."* So this test asserts both halves of one change: no third tile,
    /// and the engine's own rows arriving inside the pinned one.
    ///
    /// The fixture ranking is deliberately made of the BUNDLED CATALOG's ids (`sng_5`, `sng_7`,
    /// `sng_2`, `sng_6` — see `RecommendationService.fixtureForYou`), because the device drops
    /// cloud ids it cannot resolve. Ids from nowhere would shape away to nothing and this test
    /// would silently be driving the on-device fallback while claiming to drive the cloud.
    ///
    /// Fenced with the toggle test: the integration gate reported its predecessor failing on
    /// macOS too. See the `#TOUPDATE` on the class — its macOS status is worth re-checking once
    /// macOS XCUITest can be run again, since nothing in the body is obviously iOS-only.
    @MainActor
    func testTheEngineRanksInDaZoneAndHasNoTileOfItsOwn() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()

        let forYouTab = app.el("history-tab-for-you")
        XCTAssertTrue(forYouTab.waitForExistence(timeout: 20),
                      "the fixture seam lights the For You tab")
        forYouTab.tap()

        let zone = app.el("foryou-tile-zone")
        XCTAssertTrue(zone.waitForExistence(timeout: 15), "In Da Zone is still pinned second")
        XCTAssertFalse(app.el("foryou-tile-suggested").exists,
                       "the Suggested tile was removed — its content lives in the pinned pair now")

        zone.tap()
        // A row from the ENGINE's ranking, resolved against the catalog. `sng_5` is "Blue Note",
        // which the on-device ranking has no particular reason to lead with — what is being proven
        // is that the cloud list reached the tile at all.
        XCTAssertTrue(app.any("foryou-song-sng_5").waitForExistence(timeout: 15),
                      "the engine's rows are what In Da Zone opens on")
    }
    #endif
}
