import XCTest

/// The home Now Playing element + the new launch defaults.
///
/// Playback state: fixture songs have no rips/burns, so a real run would skip
/// every track and stop before the panel could render — `PDJ_HOLD_PLAYBACK`
/// freezes the sequencer in its running state (queue/index intact, no audio) so
/// the panel's UI is drivable headlessly.
final class NowPlayingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    /// iOS launches to the HOME menu (no section pre-selected) when nothing is
    /// persisted — the menu rows show and no Browser content is loaded. iPhone
    /// only: iPad's split view always shows a detail column beside the sidebar.
    func testIPhoneLaunchesToHomeMenuByDefault() throws {
        #if os(macOS)
        throw XCTSkip("iOS launch default — macOS lands on Mix (covered below)")
        #else
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only home screen")
        app.launch()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 15),
                      "home menu rows should be the landing screen")
        XCTAssertTrue(app.staticTexts["Mix"].exists)
        XCTAssertFalse(app.el("album-alb_1").exists, "Browser must not be pushed by default")
        // No music playing ⇒ no Now Playing element on home.
        XCTAssertFalse(app.any("now-playing-panel").exists)
        #endif
    }

    /// macOS launches on the Mix tab.
    func testMacLaunchesToMixByDefault() throws {
        #if os(macOS)
        app.launch()
        XCTAssertTrue(app.any("mix-tab").waitForExistence(timeout: 15),
                      "macOS should land on the Mix tab")
        #else
        throw XCTSkip("macOS-only launch default")
        #endif
    }

    /// End-to-end panel drive (iPhone + iPad): start the seeded playlist (held
    /// playback), reach the home menu (iPhone pops back; iPad's sidebar is always
    /// up), and exercise the panel — title/artist header, transport buttons, the
    /// add-search (native field: nav-bar drawer on iPhone, LEFT sidebar on iPad),
    /// queue add + remove.
    func testNowPlayingPanelQueueAndAddSearch() throws {
        #if os(macOS)
        throw XCTSkip("panel interactions exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        // Start the seeded playlist (sng_1 "Neon" by Aria) — sequencer runs, held.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 10))
        app.el("playlist-play").tap()

        // Pop back to the home menu (the pushed Now Playing detail → playlist →
        // list → sidebar); the panel appears once the home screen is visible.
        let panel = app.any("now-playing-panel")
        for _ in 0..<5 where !panel.exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "panel should show on home while playing")

        // Title + artist above the record player.
        XCTAssertTrue(app.staticTexts["Neon"].exists)
        XCTAssertTrue(app.staticTexts["Aria"].exists)
        XCTAssertTrue(app.any("np-record").exists)
        attach("now-playing-panel")
        XCTAssertTrue(app.el("np-playpause").exists)
        XCTAssertTrue(app.el("np-previous").exists)
        XCTAssertTrue(app.el("np-next").exists)

        // Add via the NATIVE search control (same UI as the Browser tab) — the
        // field rides the bar at the top, so the keyboard never covers it and the
        // results list stays visible while typing.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "native search field should be in the bar")
        field.tap()
        // iPad's sidebar-placed field sometimes needs a second tap to take
        // keyboard focus before typeText can synthesize events.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
        field.typeText("aria")
        let addPulse = app.el("np-add-song-sng_2")   // "Pulse" by Aria
        XCTAssertTrue(addPulse.waitForExistence(timeout: 8))
        addPulse.tap()
        field.buttons["Clear text"].tap()            // empty query → back to Up next

        // The appended track shows as the first upcoming row; ✕ removes it.
        let queued = app.any("np-queue-0")
        XCTAssertTrue(queued.waitForExistence(timeout: 8), "added song should join Up next")
        XCTAssertTrue(app.staticTexts["Pulse"].exists)
        app.el("np-remove-0").tap()
        XCTAssertFalse(app.any("np-queue-0").waitForExistence(timeout: 2))

        // Albums rank above songs and the album section collapses.
        field.tap()
        field.typeText("night\n")   // Search key dismisses the keyboard, keeps the query
        XCTAssertTrue(app.el("np-add-album-alb_1").waitForExistence(timeout: 8))
        app.el("np-albums-header").tap()             // collapse
        XCTAssertFalse(app.el("np-add-album-alb_1").exists)
        app.el("np-albums-header").tap()             // expand again
        XCTAssertTrue(app.el("np-add-album-alb_1").waitForExistence(timeout: 4))
        attach("add-search-results")

        // ALBUM context menu: long-press the album row → "Add to end" queues the
        // album's WHOLE tracklist, in album order.
        app.staticTexts["Night Drive"].press(forDuration: 0.8)
        let addToEnd = app.buttons["Add to end"]
        XCTAssertTrue(addToEnd.waitForExistence(timeout: 5), "album rows should offer a context menu")
        addToEnd.tap()
        field.buttons["Clear text"].tap()            // back to the deck + queue
        XCTAssertTrue(app.any("np-queue-2").waitForExistence(timeout: 8),
                      "the album's 3 tracks should all join Up next")
        XCTAssertTrue(app.staticTexts["Drift"].exists)

        // Long-press the record → the current song's detail metadata in a sheet —
        // closed by Back (iPhone) or the always-visible ✕ (iPad/macOS).
        let record = app.any("np-record")
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        record.press(forDuration: 0.8)
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 8),
                      "long-pressing the record should open the song detail")
        attach("record-song-detail")
        let back = app.el("np-detail-back")
        let closer = back.waitForExistence(timeout: 2) ? back : app.el("np-detail-close")
        XCTAssertTrue(closer.waitForExistence(timeout: 4), "a visible close control must exist")
        closer.tap()
        XCTAssertFalse(app.any("song-detail").waitForExistence(timeout: 2),
                       "the close control should dismiss the detail sheet")
        #endif
    }

    /// Durable playback session: launching with a persisted mid-set snapshot (the
    /// `PDJ_SEED_PLAYBACK_SESSION` seam writes one to the session file, exercising the REAL
    /// load path) rehydrates the home deck — current song "Pulse", up-next "Drift", played
    /// "Neon" behind the cursor — WITHOUT auto-playing (the probe reads "paused"; the deck
    /// is held until ▶). iPhone/iPad; macOS lands on Mix and can't drive UI headlessly.
    func testRestoredSessionRehydratesDeckWithoutAutoPlay() throws {
        #if os(macOS)
        throw XCTSkip("restore deck exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launchEnvironment["PDJ_TEST_PROBE"] = "1"
        app.launch()

        // iPad restores with the sidebar visible; iPhone lands on the home menu — the
        // panel rides under the menu rows in both shapes, no navigation needed.
        let panel = app.any("now-playing-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 15),
                      "the restored session should bring the Now Playing deck up at launch")

        // Current = the snapshot's index-1 row, rendered from the SELF-CONTAINED snapshot
        // (no catalog lookup — titles/artists come from the session file itself).
        XCTAssertTrue(app.staticTexts["Pulse"].waitForExistence(timeout: 8), "current song title")
        XCTAssertTrue(app.staticTexts["Aria"].exists, "current song artist")
        // Up next = the rows AFTER the cursor (played rows must NOT reappear as upcoming).
        let upNext = app.any("np-queue-0")
        XCTAssertTrue(upNext.waitForExistence(timeout: 8), "the up-next queue is restored")
        XCTAssertTrue(app.staticTexts["Drift"].exists, "index-2 row is up next")
        attach("restored-session-deck")

        // NEVER auto-plays: the shared engine probe must read paused, and stay paused.
        let state = app.staticTexts["player-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        XCTAssertEqual(state.value as? String, "paused", "restore must not start audio")
        sleep(2)
        XCTAssertEqual(state.value as? String, "paused", "…and it stays held until ▶")
        XCTAssertTrue(app.el("np-playpause").exists, "one tap of ▶ would resume")
        #endif
    }

    /// The ⟲ history toggle: the restored session's played row ("Neon" behind the cursor)
    /// is hidden by default, revealed as the "Previously played" section by np-history, and
    /// hidden again by a second tap. State rides @AppStorage, so the test restores the
    /// hidden default at the end.
    func testHistoryToggleRevealsPreviouslyPlayed() throws {
        #if os(macOS)
        throw XCTSkip("history toggle exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()

        let panel = app.any("now-playing-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        let toggle = app.el("np-history")
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "history toggle rides the transport")
        // @AppStorage persists in the simulator across runs — an ABORTED earlier run can
        // leave the section shown. Normalize to hidden first so the assertions below pin
        // toggle behavior, not leftover state.
        if app.any("np-played-0").exists { toggle.tap() }
        XCTAssertFalse(app.any("np-played-0").waitForExistence(timeout: 1), "played list hidden")
        toggle.tap()
        let played = app.any("np-played-0")
        XCTAssertTrue(played.waitForExistence(timeout: 8), "played section appears on toggle")
        XCTAssertTrue(app.staticTexts["Neon"].exists, "the pre-cursor snapshot row is listed")
        attach("np-previously-played")

        toggle.tap()                                 // restore the hidden default
        XCTAssertFalse(app.any("np-played-0").waitForExistence(timeout: 2),
                       "second tap hides the played section again")
        #endif
    }

    /// The iOS mini-player (Levi 2026-07-18): chevron-down collapses the deck to the thin
    /// bottom strip (title + ⏮ ⏯ ⏭ + chevron-up), the menu list takes the freed height,
    /// and chevron-up brings the full deck back. State persists via @AppStorage, so the
    /// test restores the expanded default at the end.
    func testCollapseToMiniBarAndExpandBack() throws {
        #if os(macOS)
        throw XCTSkip("the mini-bar is iOS-only")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()

        let panel = app.any("now-playing-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        let collapse = app.el("np-collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 8), "collapse chevron rides the panel")
        collapse.tap()

        let mini = app.any("np-mini-bar")
        XCTAssertTrue(mini.waitForExistence(timeout: 8), "thin strip replaces the deck")
        XCTAssertFalse(app.any("now-playing-panel").exists, "full panel is gone while collapsed")
        XCTAssertTrue(app.staticTexts["Pulse"].exists, "strip shows the current track title")
        XCTAssertTrue(app.el("np-mini-playpause").exists)
        XCTAssertTrue(app.el("np-mini-previous").exists)
        XCTAssertTrue(app.el("np-mini-next").exists)
        attach("np-mini-bar")

        app.el("np-expand").tap()
        XCTAssertTrue(app.any("now-playing-panel").waitForExistence(timeout: 8),
                      "chevron-up restores the full deck")
        XCTAssertFalse(app.any("np-mini-bar").exists)
        #endif
    }

    /// F10: the Now Playing deck carries the ♥ for the CURRENT track (the reusable
    /// FavoriteToggle, keyed favorite-toggle-<songId>). A tap flips it, does NOT disturb the
    /// deck, and reaches disk — proven by a relaunch that decodes the persisted favorite.
    /// (The lock-screen + CarPlay hearts are not headless-testable; verified on-device.)
    func testNowPlayingDeckFavoriteTogglesAndPersists() throws {
        #if os(macOS)
        throw XCTSkip("deck favorite exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()

        let panel = app.any("now-playing-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        // The current track is "Pulse" (sng_2) — its ♥ rides the transport.
        let heart = app.el("favorite-toggle-sng_2")
        XCTAssertTrue(heart.waitForExistence(timeout: 8), "the deck's current track carries a ♥")
        // Normalize: an aborted earlier run can leave it favorited on disk.
        if heart.label == "Unfavorite" { heart.tap() }
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Favorite", "starts unfavorited")

        app.el("favorite-toggle-sng_2").tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Unfavorite", "one tap favorites the current track")
        // The deck must not have been disturbed by the ♥ tap.
        XCTAssertTrue(app.staticTexts["Pulse"].exists, "the ♥ tap stays on the deck")
        attach("np-deck-favorite")

        // Relaunch KEEPING the favorites document — proves the ♥ reached disk, not just view state.
        app.terminate()
        app.launchEnvironment["PDJ_KEEP_FIXTURE_FAVORITES"] = "1"
        app.launch()
        XCTAssertTrue(app.any("now-playing-panel").waitForExistence(timeout: 15))
        XCTAssertTrue(app.el("favorite-toggle-sng_2").waitForExistence(timeout: 8))
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Unfavorite",
                       "the ♥ was persisted and re-decoded at launch")
        // Clean up: un-favorite so a re-run starts from the base state.
        app.el("favorite-toggle-sng_2").tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Favorite")
        #endif
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
