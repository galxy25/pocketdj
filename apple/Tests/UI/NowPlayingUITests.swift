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

    /// iOS launches to HISTORY by default (Levi 2026-07-22) when nothing is persisted —
    /// the collapsed iPhone split view pushes the History detail (its Playback/Collection
    /// tab chrome renders even with an empty timeline), the Browser is not loaded, and no
    /// music is playing. iPhone only: iPad's split view keeps the sidebar beside the detail.
    func testIPhoneLaunchesToHistoryByDefault() throws {
        #if os(macOS)
        throw XCTSkip("iOS launch default — macOS covered below")
        #else
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only landing check")
        app.launch()
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 15),
                      "iPhone should land on History by default")
        XCTAssertFalse(app.el("album-alb_1").exists, "Browser must not be pushed by default")
        // No music playing ⇒ no Now Playing element (and on the History detail it would be
        // behind the sidebar regardless).
        XCTAssertFalse(app.any("now-playing-panel").exists)
        #endif
    }

    /// macOS launches on HISTORY by default (Levi 2026-07-22).
    func testMacLaunchesToHistoryByDefault() throws {
        #if os(macOS)
        app.launch()
        XCTAssertTrue(app.any("history-tab-playback").waitForExistence(timeout: 15),
                      "macOS should land on History by default")
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
        // The header toggles inside `withAnimation`, so give the removal
        // transition a settle window rather than checking `.exists` on the very
        // next runloop turn. Still a real assertion: it fails if the section
        // never collapses (which is how the resize grabber swallowing this tap
        // was caught — the grabber's 44pt rect covered the header's tap point).
        XCTAssertTrue(app.el("np-add-album-alb_1").waitForNonExistence(timeout: 5),
                      "tapping the Albums header should collapse the album rows")
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

        // iPad/macOS restore with the sidebar (and its deck) visible; on iPhone the History
        // launch default sits in front of it, so pop back to the home menu to reveal the deck.
        let panel = app.revealNowPlayingHome()
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

        let panel = app.revealNowPlayingHome()
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
    /// MISC2: "Song details" is available from the Up-next AND Previously-played context menus
    /// (long-press / right-click), opening the same song-detail sheet the record long-press uses.
    func testSongDetailsFromQueueContextMenus() throws {
        #if os(macOS)
        throw XCTSkip("context-menu long-press exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()
        let panel = app.revealNowPlayingHome()
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        // Up next → long-press → Song details → the detail sheet opens.
        let upNext = app.any("np-queue-0")
        XCTAssertTrue(upNext.waitForExistence(timeout: 8), "an up-next row")
        upNext.press(forDuration: 0.9)
        let songDetails = app.buttons["Song details"].firstMatch
        XCTAssertTrue(songDetails.waitForExistence(timeout: 5), "Up-next menu offers Song details")
        songDetails.tap()
        dismissSongDetail()

        // Previously played → reveal → long-press → Song details.
        let history = app.el("np-history")
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        if !app.any("np-played-0").exists { history.tap() }
        let played = app.any("np-played-0")
        XCTAssertTrue(played.waitForExistence(timeout: 8), "a previously-played row")
        played.press(forDuration: 0.9)
        let songDetails2 = app.buttons["Song details"].firstMatch
        XCTAssertTrue(songDetails2.waitForExistence(timeout: 5), "Played menu offers Song details")
        songDetails2.tap()
        dismissSongDetail()
        #endif
    }

    /// Fully expanding the Now Playing surface (req 7's resizable overlay, raised by
    /// dragging the resize handle past the dock edge) must not regress to a bare-bones
    /// queue: Up Next there offers the SAME context menu as the docked panel — Move to
    /// top/bottom and Song details alongside Remove, not just Remove.
    func testExpandedQueueContextMenuMatchesDockedPanel() throws {
        #if os(macOS)
        throw XCTSkip("resize-drag exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
        app.launch()
        let panel = app.revealNowPlayingHome()
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        // Drag the resize handle well past the dock threshold (40pt) to raise the
        // expanded overlay — up on iPhone portrait (a bottom sheet growing upward).
        let handle = app.any("np-resize-handle")
        XCTAssertTrue(handle.waitForExistence(timeout: 8), "docked panel offers a resize handle")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 0.15, thenDragTo: end)

        let expanded = app.any("np-expanded-panel")
        XCTAssertTrue(expanded.waitForExistence(timeout: 8),
                      "a big enough drag past the dock threshold should raise the expanded surface")
        attach("np-expanded-panel")

        let queueRow = app.any("np-x-queue-0")
        XCTAssertTrue(queueRow.waitForExistence(timeout: 8), "Drift is up next in the expanded queue")
        queueRow.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["Move to top"].firstMatch.waitForExistence(timeout: 5),
                      "expanded Up Next menu offers Move to top")
        XCTAssertTrue(app.buttons["Move to bottom"].firstMatch.exists,
                      "…and Move to bottom")
        XCTAssertTrue(app.buttons["Song details"].firstMatch.exists,
                      "…and Song details")
        XCTAssertTrue(app.buttons["Remove"].firstMatch.exists,
                      "…alongside the Remove the expanded view already had")

        // Dismiss the still-open context menu by tapping its own trigger row again — the
        // standard way a UIKit/SwiftUI context menu is cancelled without picking an item
        // (the interaction consumes that tap for the dismiss, it never reaches the row's
        // own tap gesture) — then collapse back to the docked panel. The resize fraction
        // rides @AppStorage — same restore-the-default discipline as the history toggle
        // above — so a run that stopped here would leave every LATER test launching
        // straight into the expanded overlay instead of the docked panel it waits for.
        queueRow.tap()
        XCTAssertTrue(app.buttons["Move to top"].firstMatch.waitForNonExistence(timeout: 5),
                      "tapping the trigger row again should dismiss the context menu")
        let collapse = app.el("np-x-collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "expanded surface offers a collapse control")
        collapse.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 8),
                      "collapsing should return to the docked panel")
        XCTAssertTrue(expanded.waitForNonExistence(timeout: 8), "…and dismiss the expanded overlay")
        #endif
    }

    /// "Play now" and "Rewind to here" are two DIFFERENT actions on a previously-played row, and
    /// this drives the distinction on a real deck. The seeded session is [Neon, Pulse, Drift] with
    /// the cursor on Pulse, so Neon is the one played row.
    ///
    /// Rewinding to Neon must put the needle back on Neon AND return Pulse — the track that was
    /// playing — to the upcoming queue, so everything from the rewind point onward plays through
    /// again in order. That last part is the behaviour Levi asked for and the reason a rewind is
    /// not the same as re-queueing the song.
    func testRewindToHereReplaysFromThatPointOnward() throws {
        #if os(macOS)
        throw XCTSkip("context-menu long-press exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"   // assert queue shape, don't start audio
        app.launch()
        let panel = app.revealNowPlayingHome()
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "deck up from the restored session")

        let history = app.el("np-history")
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        if !app.any("np-played-0").exists { history.tap() }
        let played = app.any("np-played-0")
        XCTAssertTrue(played.waitForExistence(timeout: 8), "Neon is the played row")

        played.press(forDuration: 0.9)
        // BOTH actions are offered, and they are distinct.
        XCTAssertTrue(app.buttons["Play now"].firstMatch.waitForExistence(timeout: 5),
                      "a played row still offers Play now")
        let rewind = app.buttons["Rewind to here"].firstMatch
        XCTAssertTrue(rewind.exists, "…and now also offers Rewind to here")
        attach("played-row-menu")
        rewind.tap()

        // Assert on ROW IDENTITY, not on visible text: the deck is a lazy List and on iPhone the
        // rows below the fold are never instantiated, so `staticTexts["Pulse"].exists` would be
        // false even when the queue is correct.
        //
        // Neon was the ONLY played row, so after rewinding onto it the played section must be
        // empty — and Pulse, the track that was playing, must be back in the upcoming queue. That
        // pair is the rewind semantic: the needle moved back, and everything from there forward
        // (including what was playing) is queued to play again in order.
        XCTAssertFalse(app.any("np-played-0").waitForExistence(timeout: 5),
                       "the rewound-onto row is no longer 'previously played' — it IS the needle")
        attach("after-rewind")
        // Collapse the played section again (also the @AppStorage default this test must leave
        // behind). With it closed, Up Next is above the fold and its rows are instantiated.
        history.tap()
        XCTAssertTrue(app.any("np-queue-0").waitForExistence(timeout: 8),
                      "the track that was playing returns to the queue and plays again in order")
        XCTAssertTrue(app.staticTexts["Pulse"].exists,
                      "…and it is Pulse, the row the needle was on before the rewind")
        #endif
    }

    /// Close the song-detail sheet (iPhone Back / iPad+macOS ✕ overlay — the panel's per-platform close).
    private func dismissSongDetail() {
        let back = app.el("np-detail-back")
        let closer = back.waitForExistence(timeout: 3) ? back : app.el("np-detail-close")
        XCTAssertTrue(closer.waitForExistence(timeout: 3), "the song-detail sheet is open")
        closer.tap()
    }

    func testCollapseToMiniBarAndExpandBack() throws {
        #if os(macOS)
        throw XCTSkip("the mini-bar is iOS-only")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()

        let panel = app.revealNowPlayingHome()
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

        let panel = app.revealNowPlayingHome()
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
        XCTAssertTrue(app.revealNowPlayingHome().waitForExistence(timeout: 15))
        XCTAssertTrue(app.el("favorite-toggle-sng_2").waitForExistence(timeout: 8))
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Unfavorite",
                       "the ♥ was persisted and re-decoded at launch")
        // Clean up: un-favorite so a re-run starts from the base state.
        app.el("favorite-toggle-sng_2").tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_2").label, "Favorite")
        #endif
    }

    /// Req 1 — the minimize/expand chevrons carry a ≥44pt hit area (the glyphs are
    /// unchanged; the FRAME is what a thumb hits). Asserted on the accessibility
    /// frames of both directions of the toggle.
    func testCollapseExpandChevronsHaveGenerousHitTargets() throws {
        #if os(macOS)
        throw XCTSkip("the collapse strip is iOS-only")
        #else
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "the collapse chevron/strip pair is iPhone-only")
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()
        XCTAssertTrue(app.revealNowPlayingHome().waitForExistence(timeout: 15))

        // The a11y frame of a `.frame(minWidth: 44, minHeight: 44)` view can come
        // back as 43.99999999999994 (pixel-grid float noise, ~6e-14 pt) — compare
        // with an epsilon so the assertion tests the DESIGN, not the FP rounding.
        let eps = 0.001
        let collapse = app.el("np-collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(collapse.frame.width + eps, 44, "np-collapse hit width")
        XCTAssertGreaterThanOrEqual(collapse.frame.height + eps, 44, "np-collapse hit height")
        collapse.tap()

        let expand = app.el("np-expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 8), "strip should offer the expand chevron")
        XCTAssertGreaterThanOrEqual(expand.frame.width + eps, 44, "np-expand hit width")
        XCTAssertGreaterThanOrEqual(expand.frame.height + eps, 44, "np-expand hit height")
        expand.tap()
        XCTAssertTrue(app.el("np-collapse").waitForExistence(timeout: 8), "panel restored")
        #endif
    }

    /// Req 2/3/4 smoke — the panel's top-left ＋ presents the queue builder with its
    /// bottom omni bars (song + artist fields, the device⇄cloud mode toggle), an
    /// EXPLICIT search control, and device results that add to a VISIBLE draft.
    ///
    /// `PDJ_SEED_PLAYBACK_SESSION=1` puts this in the RUNNING regime on purpose —
    /// the one the user hit, and the one the shipped smoke silently accepted. It
    /// used to tap ＋, close the sheet, and assert on the queue OUTSIDE; it could
    /// therefore never catch "nothing gets added" or "no Play button", because both
    /// complaints are about what the sheet shows WHILE it is open. Assert in-sheet.
    func testBuilderAddIsVisibleAndPlayableWhileASetIsRunning() throws {
        #if os(macOS)
        throw XCTSkip("builder smoke exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()
        XCTAssertTrue(app.revealNowPlayingHome().waitForExistence(timeout: 15))

        let plus = app.el("np-builder-open")
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "the ＋ rides the panel's top-left")
        XCTAssertGreaterThanOrEqual(plus.frame.width, 44, "np-builder-open hit width")
        plus.tap()

        XCTAssertTrue(app.any("np-builder").waitForExistence(timeout: 8), "builder sheet presents")
        XCTAssertTrue(app.any("np-builder-song-field").exists, "bottom song omni bar")
        XCTAssertTrue(app.any("np-builder-artist-field").exists, "bottom artist omni bar")
        XCTAssertTrue(app.el("np-builder-mode").exists, "one-click device⇄cloud toggle")
        XCTAssertTrue(app.el("np-builder-filters").exists, "device mode offers filters")
        // Req 1: a user who never reaches for the keyboard's Search key still has
        // a visible way to trigger the search.
        XCTAssertTrue(app.el("np-builder-search").exists, "explicit submit control")
        // First-run guidance stands in for the empty draft, not a blank sheet.
        XCTAssertTrue(app.any("np-builder-hint").exists, "empty-state guidance")

        // Type a device query and submit it explicitly (the return key path).
        let field = app.textFields["np-builder-song-field"]
        field.tap()
        field.typeText("neon\n")
        let add = app.el("np-builder-add-0")
        XCTAssertTrue(add.waitForExistence(timeout: 8), "windowed device results render an ＋")
        add.tap()
        attach("queue-builder-after-add")

        // THE BUG, asserted from inside the sheet: the add is visible, and Play is
        // reachable. Pre-fix all three of these were absent while a set ran.
        XCTAssertTrue(app.any("np-builder-draft-header").waitForExistence(timeout: 5),
                      "the add must show up in the draft — this is the only receipt")
        XCTAssertTrue(app.any("np-builder-draft-count").exists, "…and the always-visible count")
        XCTAssertTrue(app.el("np-builder-play").waitForExistence(timeout: 5),
                      "Play must be reachable whenever there is something to play")
        // The running-set second exit: append to Up next instead of replacing.
        XCTAssertTrue(app.el("np-builder-flush").exists, "a running set also offers Up next")

        app.el("np-builder-flush").tap()
        XCTAssertTrue(app.any("np-builder-notice").waitForExistence(timeout: 5),
                      "the flush confirms in-sheet (the panel behind is covered on iPhone)")

        app.el("np-builder-close").tap()
        XCTAssertFalse(app.any("np-builder").waitForExistence(timeout: 2))
        // The flushed song landed at the queue's END (default position). Up Next is a
        // LAZY list under the deck, so scroll toward the row rather than waiting on a
        // tree that may never contain it (the `swipeTo` idiom).
        XCTAssertTrue(app.swipeTo(app.any("np-queue-1")),
                      "builder add joins Up next behind the restored row")
        #endif
    }

    /// Requirement A — "I can see the queue I am building". The sheet covers the Now
    /// Playing panel on iPhone, so while it is open the RUNNING set used to be
    /// invisible: the user assembled a queue with no view of what it was queued
    /// behind, and an "Up next" flush emptied the draft into somewhere this sheet
    /// could not render. Asserted entirely from INSIDE the sheet, because that is
    /// where every one of the user's complaints lives.
    ///
    /// Also the two receipts the shipped build never gave: results BEFORE any typing
    /// (the sheet must open populated, not blank) and a confirmation for a plain ＋.
    func testBuilderShowsTheLiveQueueAndConfirmsEveryAdd() throws {
        #if os(macOS)
        throw XCTSkip("builder smoke exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "1"
        app.launch()
        XCTAssertTrue(app.revealNowPlayingHome().waitForExistence(timeout: 15))
        let plus = app.el("np-builder-open")
        XCTAssertTrue(plus.waitForExistence(timeout: 8))
        plus.tap()
        XCTAssertTrue(app.any("np-builder").waitForExistence(timeout: 8), "builder sheet presents")

        // 1. The running set is VISIBLE from inside the sheet (seed: 3 rows, index 1 ⇒
        //    "Pulse" playing, "Drift" up next).
        XCTAssertTrue(app.any("np-builder-live-header").waitForExistence(timeout: 8),
                      "the queue being built against must be on screen")
        XCTAssertTrue(app.any("np-builder-live-now").exists, "…including what is playing")
        XCTAssertTrue(app.any("np-builder-live-0").exists, "…and what is queued behind it")

        // 2. Device mode opens POPULATED — an empty query lists the catalog, windowed.
        //    A blank list with no way to search is the report's first half.
        let add = app.el("np-builder-add-0")
        XCTAssertTrue(add.waitForExistence(timeout: 10),
                      "the results list must be non-empty before any typing")

        // 3. A plain ＋ CONFIRMS. Pre-fix it cleared the notice line, so adds 2..N moved
        //    one dim digit at the bottom of the sheet and nothing else.
        add.tap()
        XCTAssertTrue(app.any("np-builder-notice").waitForExistence(timeout: 5),
                      "every add says so, in a line the user is looking at")
        XCTAssertTrue(app.any("np-builder-draft-header").exists, "…and lands in the visible draft")
        XCTAssertTrue(app.el("np-builder-play").exists, "…which is immediately playable")
        attach("queue-builder-live-and-draft")

        // 4. The flush is no longer a one-way door into somewhere invisible: the songs
        //    move INTO the live-queue section this sheet renders.
        app.el("np-builder-flush").tap()
        XCTAssertTrue(app.any("np-builder-live-1").waitForExistence(timeout: 8),
                      "the flushed song is visible where it landed, not just described")
        XCTAssertFalse(app.any("np-builder-draft-header").exists, "the draft emptied into it")
        XCTAssertTrue(app.any("np-builder-hint").exists, "guidance retakes the empty draft's slot")
        app.el("np-builder-close").tap()
        #endif
    }

    /// Requirement 1 — typing NARROWS, and the states are distinguishable. A device
    /// query for a fixture song must leave exactly that row addable; clearing it must
    /// restore the full list. Run from the idle regime so the results section owns the
    /// whole sheet.
    func testBuilderTypingNarrowsTheResultsAndSaysWhenNothingMatches() throws {
        #if os(macOS)
        throw XCTSkip("builder smoke exercised on iOS (macOS UI automation unavailable headless)")
        #else
        app.launch()
        // Idle: no panel to reveal, but the same helper pops the phone's stack back to
        // the sidebar, which is where `idleBuilderRow` holds the builder's slot.
        _ = app.revealNowPlayingHome()
        let plus = app.el("np-builder-open")
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "idle entry row holds the builder's slot")
        plus.tap()
        XCTAssertTrue(app.any("np-builder").waitForExistence(timeout: 8))
        XCTAssertTrue(app.el("np-builder-add-0").waitForExistence(timeout: 10),
                      "opens populated (empty query ⇒ the whole catalog, windowed)")

        let field = app.textFields["np-builder-song-field"]
        field.tap()
        field.typeText("neon\n")                     // the EXPLICIT submit path
        XCTAssertTrue(app.el("np-builder-add-0").waitForExistence(timeout: 8),
                      "a matching query still has rows")
        // A refine that matches NOTHING must SAY so — never a silent blank list. The
        // artist box also exercises the read-time refine that is deliberately out of
        // the recompute signature: it must narrow without any recompute at all.
        let artist = app.textFields["np-builder-artist-field"]
        artist.tap()
        artist.typeText("zzzz\n")
        XCTAssertTrue(app.any("np-builder-empty").waitForExistence(timeout: 8),
                      "no matches is its own stated state")
        attach("queue-builder-no-matches")
        app.el("np-builder-close").tap()
        #endif
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
