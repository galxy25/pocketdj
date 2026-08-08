import XCTest

/// XCUITests for the Games tab — the two game cards, the seeded scoreboard, a full
/// puzzle round with REAL audio, and the MwF create/join sheets. Fixture catalog +
/// isolated stores throughout; `PDJ_START_SECTION=Games` lands directly on the tab (the
/// rawValue "Games"). iOS-sim only per house doctrine — macOS XCUITest can't see windows
/// headlessly; its coverage is the unit suites (`PuzzleMacLayoutTests` measures the Mac
/// setup screen's real layout offscreen).
///
/// That doctrine is enforced by the `#if !os(macOS)` fence below (the same form as
/// MultiSelectUITests / CleanOnlyPlaylistUITests / ExplicitPreferenceUITests), not just
/// stated in prose: the flows here `swipeUp()` the lazy puzzle setup Form and `typeText`
/// into the MwF theme field, and on macOS neither resolves a hit point on the Application
/// element, so the class compiled away to nothing but still FAILED the macOS run.
///
/// WHAT THESE TESTS LEARNED (2026-08-08). The round test used to pass against a build the
/// user could not play at all, because it asserted only `exists` + drove the flow with
/// programmatic `swipeTo(...)`:
///   • `exists` is true for an element that is off-screen, clipped, or under another view.
///     Every control assertion here is now HITTABLE + inside the window's frame.
///   • `swipeTo(start)` scrolled the Start row into view for the test. A human with a
///     normal number of playlists never got there — Start was a Form row below every
///     collection. Start must now be reachable with NO scrolling, and the round test
///     seeds 40 collections so a regression can't hide behind a short fixture list.
///   • `PDJ_HOLD_PLAYBACK` froze the sequencer without resolving a source, so "a round
///     ran" was asserted while nothing ever played. The round now runs with REAL seeded
///     burn audio (`PDJ_SEED_BURNS`) and asserts the shared player actually reaches
///     `playing` via the `PDJ_TEST_PROBE` readout.
final class GamesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    #if !os(macOS)

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Games"
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    // MARK: - Helpers

    /// Assert `element` is something a FINGER can use right now: it exists, XCUITest
    /// reports it hittable, and its frame sits inside the app's own frame. `exists` alone
    /// passed on the broken build — an off-screen Form row is still in the a11y tree.
    private func assertUsable(_ element: XCUIElement, _ app: XCUIApplication, _ what: String,
                              file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(what) never appeared",
                      file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(what) exists but is not hittable (frame \(element.frame))",
                      file: file, line: line)
        let screen = app.frame
        XCTAssertTrue(screen.contains(element.frame),
                      "\(what) is outside the screen \(screen): \(element.frame)",
                      file: file, line: line)
    }

    /// Poll the `PDJ_TEST_PROBE` readout of the shared `PlayerEngine` until it reads
    /// `playing`. This is the ONLY honest way to assert "the card on screen makes sound":
    /// it reflects real AVPlayer state, whatever surface started it.
    @discardableResult
    private func waitForPlaying(_ app: XCUIApplication, timeout: TimeInterval = 25) -> Bool {
        let probe = app.staticTexts["player-state"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ((probe.value as? String) ?? probe.label) == "playing" { return true }
            usleep(200_000)
        }
        return false
    }

    private func probeState(_ app: XCUIApplication) -> String {
        let probe = app.staticTexts["player-state"]
        return (probe.value as? String) ?? probe.label
    }

    // MARK: - Games home

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

    // MARK: - The puzzle setup screen

    /// The reported iOS defect: settings are selectable but the game can never be started.
    /// Start must be USABLE the moment the screen opens — no scrolling — even with a long
    /// collection list, which is what buried it as a Form row.
    func testStartIsReachableWithoutScrollingEvenWithManyCollections() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")
        // NO swipeTo here on purpose — that is the crutch that made the old suite green.
        assertUsable(app.el("puzzle-start"), app, "Start Round (with 40 collections, unscrolled)")
        assertUsable(app.any("puzzle-pool-count"), app, "the pool-count readout")
        // Start is correctly INERT until a target is chosen…
        XCTAssertFalse(app.el("puzzle-start").isEnabled, "Start must stay disabled with no target")
        // …and enables once one is, still without scrolling the button anywhere.
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        XCTAssertTrue(app.swipeTo(target), "a target collection lists in the form")
        target.tap()
        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(start.isEnabled, "1 target selected ⇒ Start enables")
        assertUsable(start, app, "Start Round (after picking a target)")
    }

    // MARK: - A real round

    /// A full round: pick a target, Start, hear the song, assign twice, End, read the
    /// summary. Runs with REAL audio (seeded burn files) — the whole point of the round is
    /// that the card on screen is a song you can hear.
    func testPuzzleRoundPlaysAudioAndAssignScoresTwo() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40",
                                 "PDJ_SEED_BURNS": "1",
                                 "PDJ_TEST_PROBE": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")
        XCTAssertEqual(probeState(app), "paused", "nothing plays before the round starts")

        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        XCTAssertTrue(app.swipeTo(target), "the seeded collection lists as a target")
        target.tap()
        let start = app.el("puzzle-start")
        // The pool count must settle >0 before Start enables (debounced async count).
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        assertUsable(start, app, "Start Round")
        XCTAssertTrue(start.isEnabled, "1 target selected + fixture songs match ⇒ Start enables")
        start.tap()

        // Countdown ≤3 s, then the running screen.
        let assign = app.el("puzzle-assign-0")
        XCTAssertTrue(assign.waitForExistence(timeout: 15))
        assertUsable(assign, app, "the assign button")
        assertUsable(app.el("puzzle-skip"), app, "Skip")
        assertUsable(app.el("puzzle-end"), app, "End Round")
        XCTAssertTrue(app.any("puzzle-timer").exists)
        XCTAssertTrue(app.any("puzzle-current").exists, "a song card is on screen")

        // THE CONTRACT: a card on screen is a song you can hear.
        XCTAssertTrue(waitForPlaying(app),
                      "no audio started for the song the round is showing (player-state=\(probeState(app)))")

        assign.tap()
        XCTAssertTrue(app.el("puzzle-assign-0").waitForExistence(timeout: 5))
        // The next card must get audio too — assigning skips the track, and the round has to
        // keep the shared player on the card it is showing.
        XCTAssertTrue(waitForPlaying(app),
                      "audio did not resume for the second card (player-state=\(probeState(app)))")
        app.el("puzzle-assign-0").tap()
        app.el("puzzle-end").tap()

        let summary = app.any("puzzle-summary-score")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("2"), "two assigns = two points (label: \(summary.label))")
        // Ending the round releases the audio it owned.
        let quiet = Date().addingTimeInterval(8)
        while probeState(app) == "playing" && Date() < quiet { usleep(200_000) }
        XCTAssertEqual(probeState(app), "paused", "End Round must stop the round's audio")
        // Back on the Games home the best score reflects the run.
        app.el("puzzle-done").tap()
        let best = app.any("games-best-collectorsPuzzle")
        XCTAssertTrue(best.waitForExistence(timeout: 10))
        XCTAssertTrue(best.label.contains("2"), "scoreboard best updated (label: \(best.label))")
    }

    // MARK: - Music with Friends

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

    #endif
}
