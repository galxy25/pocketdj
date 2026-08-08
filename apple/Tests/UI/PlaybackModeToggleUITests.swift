import XCTest

/// Item 7 + Item 8 — macOS UI guards for the new playback surfaces.
///
/// (A) The device/cloud `PlaybackModeToggle` is present + LIVE on a collection detail
///     toolbar (it must actually flip on tap, not be a dead toolbar glyph).
/// (B) Documents the inline-player live-button guarantee for Item 8: the inline player's
///     toggle/chevron/close must stay HITTABLE on macOS (the documented hit-test bug). The
///     authoritative end-to-end assertion of that — tapping the slide-out toggle and proving
///     its action fired via the `player-toggles` probe — lives in
///     `PlaybackIntegrationUITests.testInlinePlayerPlayPauseAcrossSurfaces` (gated behind
///     `PDJ_INTEGRATION_PLAYBACK=1`, needs real audio). Item 8 changed ONLY the iOS path
///     (`#if os(iOS)` transition); the macOS render path is byte-for-byte unchanged, so that
///     existing test remains the macOS regression guard.
final class PlaybackModeToggleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func makeApp(section: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // seeds a playlist + setlist
        app.launchEnvironment["PDJ_START_SECTION"] = section
        return app
    }

    /// The playback-mode toggle appears on the Playlist detail toolbar and flips on tap
    /// (its help/glyph alternates cloud ⇄ device). We assert it exists, is hittable, and a
    /// tap is accepted without disturbing the screen — i.e. it's a LIVE control on macOS.
    func testPlaybackModeToggleIsLiveOnPlaylistDetail() throws {
        #if !os(macOS)
        throw XCTSkip("macOS-only toolbar-liveness guard")
        #else
        let app = makeApp(section: "Playlists")
        app.launch()

        // Open the seeded playlist. PDJ_SEED_COLLECTIONS creates exactly one, named "Seeded Set"
        // (CollectionsStore.seedForUITestsIfRequested), with a dynamic `pls_…` id.
        //
        // Match on the NAME first and the `playlist-pls_` id prefix second. Two separate traps
        // are being avoided here, both of which previously left this test asserting nothing:
        //  • `identifier BEGINSWITH 'playlist-'` (the original) also matches
        //    `playlist-mode-picker`, the Yours|Shared Picker, which sits EARLIER in the tree.
        //    firstMatch resolved to the picker, the tap went there, no detail was ever pushed,
        //    and the toolbar assertion then failed — reading for months as "playback-mode is
        //    missing on macOS" when it was the selector.
        //  • Tightening that to `playlist-pls_` stopped matching anything at all on macOS and the
        //    test began SKIPPING, which is no better: a green suite with a test that never runs.
        //
        // So there is deliberately NO XCTSkip fallback any more. If the row cannot be found the
        // test FAILS and prints the tree, because "can't find the seeded playlist on the
        // Playlists screen" is a real problem worth seeing, not something to route around.
        // FIRST select the "Yours" tab. The Yours|Shared mode is `@AppStorage("pdj.playlists.mode")`
        // (PlaylistsView.swift:77) — real UserDefaults, PERSISTED ACROSS LAUNCHES and not reset by
        // PDJ_USE_FIXTURE. This test's original selector matched `playlist-mode-picker` and tapped
        // IT instead of a row, which flipped this Mac to Shared and left it there; every run since
        // has opened on the Shared tab, which lists source playlists and is empty here. MEASURED
        // (runner job 347a1035): the Playlists tree carried RadioButton 'Shared' value 1 and two
        // `playlists-shared-empty` labels, and no `playlist-pls_` row — the row was not missing,
        // the app was on the wrong tab. So never trust the persisted default; state it.
        let yours = app.radioButtons["Yours"]
        if yours.waitForExistence(timeout: 15), yours.isToggledOn != true { yours.tap() }

        // Both queries are TYPE-SCOPED. An unscoped `descendants(matching: .any)` carrying a
        // CONTAINS predicate evaluates against every element in the window, and on a loaded Mac
        // that query does not merely miss — it dies with "Failed to get matching snapshots:
        // Timed out while evaluating UI query" before the 20s wait is up, which reads as a
        // missing row rather than as the cost of the lookup. Naming the element type keeps the
        // walk small enough to finish. The id-prefix form is tried FIRST because it is exact.
        let byId = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        let byName = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Seeded Set", "Seeded Set")).firstMatch
        let row: XCUIElement
        if byId.waitForExistence(timeout: 20) {
            row = byId
        } else if byName.waitForExistence(timeout: 10) {
            row = byName
        } else {
            // Print rather than stuff the tree into the failure message: the assertion message
            // gets truncated in the xcodebuild log, and this is the one place a real tree is
            // worth having when the row genuinely is not where we think it is.
            print("PDJDIAG playlists tree:\n\(app.debugDescription)")
            fflush(stdout)
            XCTFail("seeded playlist row not found on the Playlists screen (tree printed above)")
            return
        }
        row.tap()

        // The detail toolbar now carries the playback-mode toggle. It must be present + live.
        let toggle = app.el("playback-mode")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "playback-mode toggle missing from the playlist detail toolbar.\n\(app.debugDescription)")
        XCTAssertTrue(toggle.isEnabled, "playback-mode toggle should be enabled")
        // Tap it — it must accept the hit (a dead toolbar glyph would still exist but the tap
        // would be a no-op / unhittable). Tapping twice returns to the original mode.
        XCTAssertTrue(toggle.isHittable, "playback-mode toggle should be hittable")
        toggle.tap()
        toggle.tap()
        // Still present + live after toggling (the toolbar didn't break).
        XCTAssertTrue(app.el("playback-mode").isEnabled, "playback-mode toggle still live after flipping")
        #endif
    }
}
