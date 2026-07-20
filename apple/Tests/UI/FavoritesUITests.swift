import XCTest

/// XCUITests for the ♥ favorite control and the Browse favorite filter, against the
/// bundled fixture catalog (PDJ_USE_FIXTURE — offline, deterministic, and an isolated
/// freshly-cleared favorites document per run via `FavoritesStore.launchURL`).
///
/// These cover the half that unit tests structurally cannot: that the control is actually
/// REACHABLE and WIRED on each surface. The favorites store logic itself is covered in
/// FavoritesStoreTests; what's asserted here is that a tap on a real row reaches it, that
/// the ♥ does not fire the enclosing NavigationLink, and that the state survives the trip
/// to disk and back on relaunch.
///
/// The Apple Music half is deliberately absent: two-way sync is owner-gated behind
/// `Config.ownerICloudHashes` (which ships empty) and needs a signed-in Apple Music account,
/// so it is not headless-testable and must be verified on-device.
final class FavoritesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    private func launch() -> XCUIApplication {
        app.launch()
        return app
    }

    /// The album track table carries a ♥ per track, and tapping it favorites that track
    /// WITHOUT navigating into the song (the tap-through hazard for a button living inside
    /// a NavigationLink label).
    func testAlbumTrackRowFavoriteTogglesWithoutNavigating() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))

        let heart = app.el("favorite-toggle-sng_1")
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "each album track row has a ♥")
        XCTAssertEqual(heart.label, "Favorite", "starts unfavorited")

        heart.tap()
        // Still on the album screen — the ♥ must not have triggered the row's NavigationLink.
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 3),
                      "tapping ♥ must not navigate into the song detail page")
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Unfavorite", "now favorited")

        app.el("favorite-toggle-sng_1").tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Favorite", "un-♥ returns to the base state")
    }

    /// A ♥ survives a relaunch — i.e. it reached the on-disk document, not just view state.
    func testFavoriteSurvivesRelaunch() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let heart = app.el("favorite-toggle-sng_1")
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        heart.tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Unfavorite")

        // Relaunch WITHOUT re-clearing the fixture document: PDJ_USE_FIXTURE points the
        // store at a fixed temp path that is cleared on construction, so terminate+launch
        // (rather than a fresh install) is what exercises the decode-on-init path.
        app.terminate()
        app.launchEnvironment["PDJ_KEEP_FIXTURE_FAVORITES"] = "1"
        app.launch()
        let card2 = app.el("album-alb_1")
        XCTAssertTrue(card2.waitForExistence(timeout: 15))
        card2.tap()
        XCTAssertTrue(app.el("favorite-toggle-sng_1").waitForExistence(timeout: 5))
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Unfavorite",
                       "the ♥ was persisted and re-decoded at launch")
    }

    #if !os(macOS)
    /// The Browse song list carries the same ♥, and the filter sheet exposes the tri-state
    /// favorite constraint. (iOS only: the Albums/Songs Picker and in-sheet Pickers are not
    /// drivable via XCUITest on macOS — the same limitation BrowseUITests documents.)
    func testSongListFavoriteAndFilterControlExist() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))
        app.selectKind(songs: true)

        let heart = app.el("favorite-toggle-sng_1")
        XCTAssertTrue(heart.waitForExistence(timeout: 10), "the shared song row has a ♥")
        heart.tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Unfavorite")

        // The favorite filter lives in the filter sheet alongside the membership controls.
        app.el("filter-button").tap()
        XCTAssertTrue(app.el("favorite-filter").waitForExistence(timeout: 5),
                      "the filter sheet exposes the favorite constraint in song mode")
    }

    /// END TO END: ♥ a song, then filter to "Favorites only" and assert THAT SONG is the one
    /// left standing. This is the assertion that would have caught a filter reading a
    /// different FavoritesStore instance than the ♥ writes to, or matching on the wrong id
    /// space — both of which look identical from outside ("the filter matches zero songs").
    func testFavoritesOnlyFilterShowsExactlyTheFavoritedSong() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))
        app.selectKind(songs: true)

        // Two songs visible up front; ♥ exactly one of them.
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("row-play-sng_7").exists)
        app.el("favorite-toggle-sng_1").tap()
        XCTAssertEqual(app.el("favorite-toggle-sng_1").label, "Unfavorite")

        // Filter to Favorites only.
        app.el("filter-button").tap()
        let picker = app.el("favorite-filter")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Favorites only"].tap()
        app.buttons["Done"].firstMatch.tap()

        // The ♥'d song survives; the un-♥'d one is filtered out.
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 10),
                      "the favorited song must still be listed")
        XCTAssertFalse(app.el("row-play-sng_7").exists,
                       "a song that was never favorited must be filtered out")
    }
    #endif
}
