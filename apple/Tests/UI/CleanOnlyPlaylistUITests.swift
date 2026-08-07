import XCTest

/// The per-playlist "Clean versions only" flow against the seeded fixture playlist
/// (PDJ_SEED_CLEANONLY: "Clean Test" = sng_1 clean · sng_2 explicit WITH a clean id ·
/// sng_6 explicit WITHOUT one). Toggle ON → ▶ Play builds a 2-track queue (Get Down
/// skipped, Pulse substituted-clean); toggle OFF → 3 tracks. PDJ_HOLD_PLAYBACK keeps
/// the run alive without resolving audio (fixture catalogs have no rips/burns).
final class CleanOnlyPlaylistUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_CLEANONLY"] = "1"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    /// The seeded playlist's row on the merged Playlists list.
    private func openCleanTest(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 5))
    }

    /// Flip the ⋯-menu Clean-versions-only toggle (a MENU row, not a Form switch — a
    /// plain tap toggles it and dismisses the menu).
    private func toggleCleanOnly(_ app: XCUIApplication) {
        XCTAssertTrue(app.el("playlist-menu").waitForExistence(timeout: 5))
        app.el("playlist-menu").tap()
        let item = app.descendants(matching: .any).matching(identifier: "playlist-clean-only").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// ▶ Play pushes the Now Playing setlist; return its `setlist-track-<i>` row count
    /// probe results (existence of rows 0…3).
    private func play(_ app: XCUIApplication) {
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 5))
        app.el("playlist-play").tap()
        XCTAssertTrue(app.any("setlist-detail").waitForExistence(timeout: 8))
        XCTAssertTrue(app.any("setlist-track-0").waitForExistence(timeout: 8))
    }

    #if !os(macOS)
    @MainActor
    func testCleanOnlyFiltersQueueThenOffRestoresAll() {
        let app = launch()
        openCleanTest(app)

        // ON → ▶ Play: 2 tracks (sng_6 "Get Down" skipped), the substituted "Pulse" present.
        toggleCleanOnly(app)
        play(app)
        XCTAssertTrue(app.any("setlist-track-1").waitForExistence(timeout: 5))
        XCTAssertFalse(app.any("setlist-track-2").exists, "explicit-without-clean must be skipped")
        XCTAssertTrue(app.staticTexts["Pulse"].firstMatch.exists, "substituted song stays in the set")
        XCTAssertFalse(app.staticTexts["Get Down"].firstMatch.exists)

        // Back to the playlist, toggle OFF, ▶ Play again: all 3 tracks.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 8))
        toggleCleanOnly(app)
        play(app)
        XCTAssertTrue(app.any("setlist-track-2").waitForExistence(timeout: 5), "off ⇒ full queue")
        XCTAssertTrue(app.staticTexts["Get Down"].firstMatch.waitForExistence(timeout: 5))
    }
    #endif
}
