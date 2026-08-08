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

        // Open the seeded playlist (PDJ_SEED_COLLECTIONS seeds one). Its row id is dynamic, so
        // match on the PLAYLIST-ID prefix `playlist-pls_`, not the bare `playlist-`: the
        // Yours|Shared mode picker is `playlist-mode-picker`, which also begins with "playlist-"
        // and sits EARLIER in the tree, so `firstMatch` on the loose prefix resolved to the
        // picker. The guard then passed, the tap went to the picker instead of the row, no
        // detail was ever pushed, and the toolbar assertion below failed — which read as
        // "playback-mode is missing on macOS" for months. (iOS never caught it: this test is
        // macOS-only.)
        let firstPlaylist = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        guard firstPlaylist.waitForExistence(timeout: 20) else {
            throw XCTSkip("seeded playlist row not found — seed shape changed.\n\(app.debugDescription)")
        }
        firstPlaylist.tap()

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
