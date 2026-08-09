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

    /// Scroll `element` until it is clear of the PINNED Start bar, then return it.
    ///
    /// `swipeTo` stops as soon as the row EXISTS — and a Form row exists while it is still
    /// drawn underneath the translucent bottom bar, where XCUITest happily reports it
    /// `isHittable` (the bar is a sibling view, not something the frame check knows about)
    /// and every tap lands on the bar instead. That is the same "exists ≠ usable" trap in
    /// miniature, so the helper keeps scrolling until the row's bottom edge is above the
    /// bar's top edge, which is the only state a finger can actually use.
    @discardableResult
    private func scrollClearOfStartBar(_ element: XCUIElement, _ app: XCUIApplication,
                                       file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(app.swipeTo(element), "\(element.identifier) never came into view",
                      file: file, line: line)
        let bar = app.el("puzzle-start")
        for _ in 0..<10 {
            let barTop = bar.exists ? bar.frame.minY : app.frame.maxY
            if element.frame.maxY <= barTop { return element }
            app.swipeUp()
        }
        XCTFail("\(element.identifier) never scrolled clear of the Start bar (row \(element.frame), bar \(bar.frame))",
                file: file, line: line)
        return element
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

    /// Dismiss the Add-to picker via its NAVIGATION BAR's Done, never `app.buttons["Done"]`.
    /// Once the search field has been typed into, the software keyboard is up and a bare
    /// label lookup is AMBIGUOUS — it resolved to the keyboard, the sheet stayed put, and the
    /// round scored 0 while the failure read like a product bug. Scope the query to the bar.
    private func dismissAddPicker(_ app: XCUIApplication) {
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the picker's Done button never appeared")
        done.tap()
    }

    /// The deletion alert's destructive button. Scoped to `alerts` + `firstMatch`: the plain
    /// `app.buttons[…]` lookup came back with MULTIPLE matches and the tap threw.
    private func deleteConfirmButton(_ app: XCUIApplication) -> XCUIElement {
        app.alerts.buttons["games-scoreboard-delete-confirm"].firstMatch
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
    ///
    /// INVERTED 2026-08 (Levi): targets are OPTIONAL now, so Start must also be LIVE with
    /// none selected — this test used to assert the opposite (`isEnabled == false`), which is
    /// exactly the refusal being removed. The pinned-Start-bar reachability assertions around
    /// it are the freshly-repaired regression guard and are unchanged.
    func testStartIsReachableAndLiveWithoutTargets() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")
        // NO swipeTo here on purpose — that is the crutch that made the old suite green.
        assertUsable(app.el("puzzle-start"), app, "Start Round (with 40 collections, unscrolled)")
        assertUsable(app.any("puzzle-pool-count"), app, "the pool-count readout")
        // Start is LIVE with no target at all, once the debounced pool count settles >0.
        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(start.isEnabled, "targets are optional: Start is live with none selected")
        assertUsable(start, app, "Start Round (no targets selected)")
        // …and stays live once one IS selected, still without scrolling the button anywhere.
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        scrollClearOfStartBar(target, app).tap()
        let deadline2 = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline2 { usleep(300_000) }
        XCTAssertTrue(start.isEnabled, "1 target selected ⇒ Start still enabled")
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
        scrollClearOfStartBar(target, app).tap()
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

    // MARK: - Gem Collector: file into ANY collection (no targets required)

    /// THE REQUESTED USER PATH, end to end and with nothing synthetic: open the game, pick NO
    /// target at all, Start, hear the song, tap the CARD, search in the picker, add to a
    /// collection that was never a target — and score. Every control is asserted `assertUsable`
    /// (hittable AND inside the window), because `exists` is what let a broken build ship.
    func testFileIntoAnyCollectionWithNoTargetsScoresAPoint() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40",
                                 "PDJ_SEED_BURNS": "1",
                                 "PDJ_TEST_PROBE": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")

        // NO target selected — the whole point of the change.
        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        assertUsable(start, app, "Start Round (no targets)")
        XCTAssertTrue(start.isEnabled, "targets are optional ⇒ Start is live")
        start.tap()

        // The running screen: with no targets there are no assign buttons, and "File into…"
        // is the ONLY scoring control — so it had better be usable.
        let file = app.el("puzzle-file")
        XCTAssertTrue(file.waitForExistence(timeout: 15), "the File-into button never appeared")
        assertUsable(file, app, "File into… (the only scoring control with no targets)")
        assertUsable(app.el("puzzle-skip"), app, "Skip")
        assertUsable(app.el("puzzle-end"), app, "End Round")
        XCTAssertFalse(app.el("puzzle-assign-0").exists, "no targets ⇒ no one-tap assign buttons")
        XCTAssertTrue(app.any("puzzle-current").exists, "a song card is on screen")
        // THE CONTRACT: a card on screen is a song you can hear.
        XCTAssertTrue(waitForPlaying(app),
                      "no audio started for the song the round is showing (player-state=\(probeState(app)))")

        file.tap()
        // The shared Add-to sheet, with its fuzzy search field.
        let search = app.textFields["add-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the add-to picker never opened")
        assertUsable(search, app, "the picker's search field")
        search.tap()
        search.typeText("Crate")           // the seeded collections are named "Crate <n>"

        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "add-playlist-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the search found no playlist to file into")
        assertUsable(row, app, "a searched collection row")
        row.tap()

        // THE PICKER STAYS OPEN on an add (multi-collection filing, 2026-08-08) — it is the
        // app's one multi-select sheet and Gem Collector no longer self-dismisses out of it.
        XCTAssertTrue(app.textFields["add-search-field"].exists,
                      "the picker must not self-dismiss on the first add")
        dismissAddPicker(app)

        // Dismiss is the settle point: the point lands, the sheet goes, the card advances.
        let score = app.any("puzzle-score")
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        let scored = Date().addingTimeInterval(10)
        while !score.label.contains("1") && Date() < scored { usleep(200_000) }
        XCTAssertTrue(score.label.contains("1"),
                      "filing through the picker scores one point (label: \(score.label))")
        XCTAssertFalse(app.textFields["add-search-field"].exists, "Done dismissed the picker")
        assertUsable(app.el("puzzle-file"), app, "File into… (still usable for the next card)")
    }

    /// THE SECOND REQUESTED PATH (Levi 2026-08-08): "gem collector should let me add the song to
    /// multiple collections". One card, TWO collections, and still exactly one point — the
    /// regression that made this necessary is asserted directly: after the first tap the
    /// picker's search field must STILL EXIST, because the old build nil'd the sheet binding
    /// inside the add callback and there was no way to reach a second collection.
    func testFileOneCardIntoSeveralCollectionsScoresOnce() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40",
                                 "PDJ_SEED_BURNS": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10), "setup form opened")

        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        assertUsable(start, app, "Start Round (no targets)")
        start.tap()

        let file = app.el("puzzle-file")
        XCTAssertTrue(file.waitForExistence(timeout: 15), "the File-into button never appeared")
        let cardBefore = app.any("puzzle-current").label
        file.tap()

        let search = app.textFields["add-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the add-to picker never opened")
        search.tap()
        search.typeText("Crate")           // the seeded collections are named "Crate <n>"

        let rows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "add-playlist-"))
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 10),
                      "the search found no collection to file into")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "need two collections to file into")
        // Identifiers, not indices: the second tap must land on a DIFFERENT collection even if
        // the list re-lays-out after the first add.
        let firstId = rows.element(boundBy: 0).identifier
        let secondId = rows.element(boundBy: 1).identifier
        XCTAssertNotEqual(firstId, secondId)

        assertUsable(app.buttons[firstId], app, "the first collection row")
        app.buttons[firstId].tap()
        XCTAssertTrue(search.exists, "THE REGRESSION: the picker self-dismissed on the first add")
        assertUsable(app.buttons[secondId], app, "the second collection row (only reachable if it stayed open)")
        app.buttons[secondId].tap()

        dismissAddPicker(app)
        let score = app.any("puzzle-score")
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        let scored = Date().addingTimeInterval(10)
        while !score.label.contains("1") && Date() < scored { usleep(200_000) }
        XCTAssertTrue(score.label.contains("1"),
                      "two collections, ONE point (label: \(score.label))")
        XCTAssertNotEqual(app.any("puzzle-current").label, cardBefore,
                          "…and exactly one advance — the next card is up")
    }

    // MARK: - Scoreboard deletion (right-click / long-press)
    //
    // WHAT THE TREE SHOWED (measured 2026-08-08, iPhone 17 Pro): a `List` SECTION HEADER does
    // not deliver a `.contextMenu` on iOS — a 1.2 s press on a "Scoreboard" SECTION HEADER
    // produced no menu at all, with the modifier on the HStack AND with it on the Text. The
    // fix was not to give up on the gesture but to stop using a section header: the title is
    // an ordinary List ROW now, and rows deliver context menus on every platform (the per-game
    // blocks already proved that here). So all THREE press targets the request implies are
    // asserted below on a real device tree — the category header, a game's block, and a run
    // row — plus the ⋯, which stays as the discoverable affordance.

    /// The row's own context menu wipes THAT game and leaves the other alone.
    func testScoreboardGameRowContextMenuDeletesThatGamesRuns() {
        let app = launch(extra: ["PDJ_SEED_GAMES": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        let row = app.any("games-scoreboard-game-collectorsPuzzle")
        XCTAssertTrue(app.swipeTo(row), "the scoreboard's Gem Collector block never came into view")
        assertUsable(row, app, "the Gem Collector scoreboard row")
        row.openContextMenu()

        let delete = app.el("games-scoreboard-delete-collectorsPuzzle")
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "the row's context menu never opened")
        delete.tap()
        let confirm = deleteConfirmButton(app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "a delete this irreversible must confirm")
        confirm.tap()

        let best = app.any("games-best-collectorsPuzzle")
        XCTAssertTrue(best.waitForExistence(timeout: 10))
        let cleared = Date().addingTimeInterval(10)
        while !best.label.contains("0") && Date() < cleared { usleep(200_000) }
        XCTAssertTrue(best.label.contains("0"), "the game's board is empty (label: \(best.label))")
        XCTAssertTrue(app.any("games-best-musicWithFriends").label.contains("4"),
                      "the other game's scores are untouched")
    }

    /// THE LITERALLY-REQUESTED GESTURE: "long press … on the scoreboard category header".
    ///
    /// This test is the reason the title stopped being a `Section` header. Against that build it
    /// FAILS at `waitForExistence` on the menu — iOS delivers no `.contextMenu` from a section
    /// header, so the modifier there was dead code and the header half of the request was
    /// satisfied only by the small ⋯. The title is an ordinary row now and the press works.
    func testScoreboardHeaderRowLongPressDeletesEverything() {
        let app = launch(extra: ["PDJ_SEED_GAMES": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        let header = app.any("games-scoreboard-header")
        XCTAssertTrue(app.swipeTo(header), "the Scoreboard title row never came into view")
        assertUsable(header, app, "the Scoreboard title row")
        header.openContextMenu()

        let deleteAll = app.el("games-scoreboard-delete-all")
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 10),
                      "a long press on the Scoreboard header must open its menu (it does not from a Section header)")
        deleteAll.tap()
        let confirm = deleteConfirmButton(app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "a delete this irreversible must confirm")
        confirm.tap()

        XCTAssertTrue(app.any("games-scoreboard-empty").waitForExistence(timeout: 10),
                      "every run gone ⇒ the empty state returns")
        // …and the title row survives the wipe: it is the section's own heading, not a row that
        // belongs to a run, so it must still be there to press when new runs arrive.
        XCTAssertTrue(app.any("games-scoreboard-header").exists,
                      "the Scoreboard heading stays on an empty board")
        XCTAssertFalse(app.el("games-scoreboard-menu").exists,
                       "…but the ⋯ hides, since there is nothing left to delete")
    }

    /// The header's ⋯ wipes everything and the empty state comes back.
    func testScoreboardHeaderMenuDeletesEverything() {
        let app = launch(extra: ["PDJ_SEED_GAMES": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        let menu = app.el("games-scoreboard-menu")
        XCTAssertTrue(app.swipeTo(menu), "the scoreboard header's ⋯ never came into view")
        assertUsable(menu, app, "the scoreboard header ⋯ menu")
        menu.tap()

        let deleteAll = app.el("games-scoreboard-delete-all")
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 10), "the header menu never opened")
        deleteAll.tap()
        let confirm = deleteConfirmButton(app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(app.any("games-scoreboard-empty").waitForExistence(timeout: 10),
                      "every run gone ⇒ the empty state returns")
        XCTAssertFalse(app.el("games-scoreboard-menu").exists,
                       "…and the ⋯ hides, since there is nothing left to delete")
    }

    /// The long press works anywhere in a game's BLOCK, not just on its best-score row, and it
    /// offers both scopes — "just this one" and "all of them" — which is the second half of the
    /// request. Also pins that the two Delete-All items carry DISTINCT identifiers: the header
    /// menu and a row menu must never put two live elements under one a11y id.
    func testScoreboardRunRowContextMenuOffersBothDeletes() {
        let app = launch(extra: ["PDJ_SEED_GAMES": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        let run = app.any("games-run-collectorsPuzzle-0")
        XCTAssertTrue(app.swipeTo(run), "the recent-run row never came into view")
        assertUsable(run, app, "a recent-run row")
        run.openContextMenu()

        XCTAssertTrue(app.el("games-scoreboard-delete-collectorsPuzzle").waitForExistence(timeout: 10),
                      "a long press on a run row must offer to delete that game's scores")
        XCTAssertTrue(app.el("games-scoreboard-delete-all-from-collectorsPuzzle").exists,
                      "…and to delete every scoreboard")
        XCTAssertFalse(app.el("games-scoreboard-delete-all").exists,
                       "the header menu's item is NOT live at the same time — distinct ids")
    }

    /// Tapping the SONG CARD itself opens the picker (the affordance the user asked for), and
    /// dismissing it without adding costs nothing — no point, and the same card stays.
    func testTappingTheSongCardOpensThePickerAndCancelCostsNothing() {
        let app = launch(extra: ["PDJ_SEED_COLLECTIONS": "40",
                                 "PDJ_SEED_BURNS": "1"])
        XCTAssertTrue(app.any("games-card-puzzle").waitForExistence(timeout: 15))
        app.any("games-card-puzzle").tap()
        XCTAssertTrue(app.any("puzzle-round-length").waitForExistence(timeout: 10))
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        scrollClearOfStartBar(target, app).tap()
        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        start.tap()

        let card = app.any("puzzle-current")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the running card never appeared")
        assertUsable(card, app, "the current-song card")
        // With a target selected the escape hatch is still there, labelled "Other…".
        assertUsable(app.el("puzzle-file"), app, "Other… (the any-collection escape hatch)")
        card.tap()

        XCTAssertTrue(app.textFields["add-search-field"].waitForExistence(timeout: 10),
                      "tapping the song card must open the add-to picker")
        // READ THE CARD *AFTER* THE SHEET IS UP, not before the tap. `PDJ_SEED_BURNS` writes a
        // 2 SECOND tone per song (BurnStore), so an unfiled card expires on its own every two
        // seconds and the round advances — legitimately, via the ticker's drift re-sync. Reading
        // `before` ahead of the tap therefore raced that expiry across the ~1 s XCUITest spends
        // querying and synthesising the tap, and this test flaked with "Drift…" ≠ "Pulse…" while
        // the score assertion below passed, i.e. it failed on the confound and not on the
        // contract. Once `beginFiling` has run the round is FROZEN (`filingSongId != nil` is the
        // ticker's first early exit), so the label read here is the card the sheet is actually
        // filing — which is the thing "cancel is not a skip" is about.
        let filing = app.any("puzzle-current")
        XCTAssertTrue(filing.exists, "the card stays in the tree behind the sheet")
        let before = filing.label
        app.buttons["Done"].firstMatch.tap()

        XCTAssertTrue(app.any("puzzle-current").waitForExistence(timeout: 10))
        XCTAssertTrue(app.any("puzzle-score").label.contains("0"),
                      "cancelling the picker scores nothing")
        XCTAssertEqual(app.any("puzzle-current").label, before,
                       "cancel is not a skip — the same card is still on screen")
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
