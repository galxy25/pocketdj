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

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
