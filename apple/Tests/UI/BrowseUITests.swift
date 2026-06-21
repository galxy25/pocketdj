import XCTest

/// XCUITests for the Browser. Runs on iPhone, iPad, and Mac (one multiplatform
/// UI-test target) against the bundled fixture catalog (PDJ_USE_FIXTURE), so it's
/// offline and deterministic.
///
/// The Albums/Songs segmented Picker, the window-toolbar buttons, and in-sheet
/// Pickers aren't drivable via XCUITest on macOS, so the browser actions go
/// through the app's keyboard commands there (see XCUIHelpers) and the deeper
/// in-sheet interactions are exercised on iOS, where every control is tappable.
final class BrowseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
    }

    // Terminate between tests so each gets a clean, focused instance — on macOS a
    // lingering prior instance makes the next launch flaky (and steals keystrokes).
    override func tearDown() {
        app?.terminate()
        app = nil
    }

    private func launch() -> XCUIApplication {
        app.launch()
        return app
    }

    func testBrowserLoadsAlbums() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        XCTAssertTrue(app.el("album-alb_2").exists)
    }

    func testAlbumNavigationShowsTrackTable() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))
    }

    func testSongDetailFromTrackTable() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let track = app.el("track-sng_1")        // in-content NavigationLink (works on macOS)
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        XCTAssertTrue(app.el("album-hotlink").waitForExistence(timeout: 5))  // links back to the album
        #if !os(macOS)
        // The Edit button lives in the toolbar (not drivable via XCUITest on macOS).
        XCTAssertTrue(app.el("edit-song").exists)
        app.el("edit-song").tap()
        XCTAssertTrue(app.el("save-edit").waitForExistence(timeout: 5))
        #endif
    }

    func testSwitchToSongsListsTracks() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.selectKind(songs: true)
        // The browser song row no longer wraps the whole row in a single NavigationLink
        // Button (that collapsed the inner transport ▶/⤓ buttons so their taps died — the
        // inline-player bug). The nav link now rides in the row's background and the row's
        // own transport ▶ carries the stable per-song id; assert on that (present for every
        // rendered song row on iPhone, iPad, and Mac).
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 5))   // Neon
        XCTAssertTrue(app.el("row-play-sng_7").exists)                         // Slow Burn
    }

    func testLayoutToggleKeepsAlbumsVisible() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.toggleLayout()       // grid ⇄ list
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 3))
    }

    func testFilterSheetOpens() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.openFilter()
        XCTAssertTrue(app.el("add-filter").waitForExistence(timeout: 5))
        #if !os(macOS)
        // In-sheet Pickers + the sheet's toolbar buttons are tappable on iOS.
        app.el("add-filter").tap()
        XCTAssertTrue(app.el("clause-field").waitForExistence(timeout: 3))
        app.el("filter-clear-all").tap()
        XCTAssertFalse(app.el("clause-field").exists)
        app.el("filter-done").tap()
        #endif
    }

    func testSortSheetOpens() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.openSort()
        XCTAssertTrue(app.el("addsort-year").waitForExistence(timeout: 5))
        #if !os(macOS)
        app.el("addsort-year").tap()
        XCTAssertTrue(app.el("sortdir-year").waitForExistence(timeout: 3))
        app.el("sort-clear-all").tap()
        XCTAssertFalse(app.el("sortdir-year").exists)
        app.el("sort-done").tap()
        #endif
    }
}
