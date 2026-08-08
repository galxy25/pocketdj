import XCTest

/// XCUITests for the Games tab — the two game cards, the seeded scoreboard, a full
/// held-playback puzzle round (two assigns), and the MwF create/join sheets. Fixture
/// catalog + isolated stores throughout; `PDJ_START_SECTION=Games` lands directly on
/// the tab (the rawValue "Games"). iOS-sim only per house doctrine — macOS XCUITest
/// can't see windows headlessly; its coverage is the unit suites.
final class GamesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Games"
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    func testGamesTabOpensAndShowsCards() {
        let app = launch()
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        XCTAssertTrue(app.any("games-card-friends").exists)
        XCTAssertTrue(app.el("mwf-new").exists)
        XCTAssertTrue(app.el("mwf-join").exists)
        XCTAssertTrue(app.any("games-scoreboard-empty").exists, "no runs yet — empty state shows")
    }

    func testScoreboardSeedRenders() {
        let app = launch(extra: ["PDJ_SEED_GAMES": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        XCTAssertTrue(app.any("games-best-collectorsPuzzle").label.contains("9"),
                      "seeded puzzle best is 9 (5/9/7)")
        XCTAssertTrue(app.any("games-best-musicWithFriends").label.contains("4"),
                      "seeded MwF best is 4")
        XCTAssertTrue(app.any("games-run-collectorsPuzzle-0").exists, "recent run rows render")
        XCTAssertTrue(app.any("games-run-musicWithFriends-0").exists)
    }

    func testPuzzleRoundAssignScoresTwo() {
        let app = launch(extra: ["PDJ_HOLD_PLAYBACK": "1", "PDJ_SEED_COLLECTIONS": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        // Setup: pick the seeded playlist as the target, then start. Form rows are LAZY —
        // off-screen rows don't exist in the a11y tree, so swipe the setup form down to them.
        let targetRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")
        XCTAssertTrue(app.swipeTo(targetRow), "the seeded collection lists as a target")
        targetRow.tap()
        let start = app.el("puzzle-start")
        XCTAssertTrue(app.swipeTo(start, maxSwipes: 6), "Start Round row scrolls into view")
        // The pool count must settle >0 before Start enables (debounced async count).
        let deadline = Date().addingTimeInterval(10)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(start.isEnabled, "1 target selected + fixture songs match ⇒ Start enables")
        start.tap()
        // Countdown ≤3 s, then the running screen (held playback — no audio resolves).
        let assign = app.el("puzzle-assign-0")
        XCTAssertTrue(assign.waitForExistence(timeout: 12))
        XCTAssertTrue(app.any("puzzle-timer").exists)
        assign.tap()
        XCTAssertTrue(app.el("puzzle-assign-0").waitForExistence(timeout: 5))
        app.el("puzzle-assign-0").tap()
        app.el("puzzle-end").tap()
        let summary = app.any("puzzle-summary-score")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("2"), "two assigns = two points (label: \(summary.label))")
        // Back on the Games home the best score reflects the run.
        app.el("puzzle-done").tap()
        let best = app.any("games-best-collectorsPuzzle")
        XCTAssertTrue(best.waitForExistence(timeout: 10))
        XCTAssertTrue(best.label.contains("2"), "scoreboard best updated (label: \(best.label))")
    }

    func testFriendsCreateSheetThemeClamped() {
        let app = launch()
        XCTAssertTrue(app.el("mwf-new").waitForExistence(timeout: 15))
        app.el("mwf-new").tap()
        let theme = app.textViews["mwf-create-theme"].exists
            ? app.textViews["mwf-create-theme"] : app.textFields["mwf-create-theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 10))
        theme.tap()
        theme.typeText(String(repeating: "x", count: 200))
        let counter = app.any("mwf-create-theme-count")
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "144/144", "input hard-clamps at the 144-char theme cap")
    }

    func testFriendsJoinSheetDefaultsProfileName() {
        let app = launch()
        XCTAssertTrue(app.el("mwf-join").waitForExistence(timeout: 15))
        app.el("mwf-join").tap()
        let name = app.textFields["mwf-join-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let value = (name.value as? String) ?? ""
        XCTAssertFalse(value.isEmpty, "the display name prefills from the profile")
    }
}
