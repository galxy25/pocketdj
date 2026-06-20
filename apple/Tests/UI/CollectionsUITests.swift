import XCTest

/// XCUITests for Pockets, Playlists, and the Setlist (Play → frozen) flow. One
/// multiplatform UI-test target (iPhone, iPad, Mac) against the bundled fixture
/// catalog with an isolated, freshly-cleared collections store (PDJ_USE_FIXTURE),
/// landing directly on a section (PDJ_START_SECTION).
///
/// Alert TextField typing + in-content button taps work on iOS; the deeper create/
/// rename/delete interactions are kept iOS-only (`#if !os(macOS)`) like the other
/// suites, because the macOS alert/keyboard path isn't reliably drivable headlessly.

// MARK: - Pockets

final class PocketsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Pockets"
        app.launch()
        return app
    }

    func testEmptyStateShowsCreate() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testCreateOpenRenameDeletePocket() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 15))
        app.buttons["new-pocket"].tap()

        // Create alert → type a name → Create.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("Soul")
        app.alerts.buttons["Create"].tap()

        // A pocket row appears (id pocket-<id>); open it.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pocket-pkt_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.otherElements["pocket-detail"].waitForExistence(timeout: 5)
                      || app.collectionViews["pocket-detail"].waitForExistence(timeout: 1)
                      || app.navigationBars["Soul"].waitForExistence(timeout: 5))

        // Rename via the detail menu.
        app.buttons["pocket-menu"].tap()
        app.buttons["rename-pocket"].tap()
        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap()
        renameField.typeText(" Crate")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Soul Crate"].waitForExistence(timeout: 5))

        // Delete via the detail menu → confirmation → pops back to the list.
        app.buttons["pocket-menu"].tap()
        app.buttons["delete-pocket"].tap()
        let confirm = app.buttons.matching(identifier: "delete-pocket-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 5))
    }
    #endif
}

// MARK: - Playlists

final class PlaylistsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    func testEmptyStateShowsCreate() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testCreateChapterRenameDeletePlaylist() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
        app.buttons["new-playlist"].tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("BBQ")
        app.alerts.buttons["Create"].tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["BBQ"].waitForExistence(timeout: 5))

        // Add a chapter.
        app.buttons["add-chapter"].tap()
        let chapField = app.textFields.firstMatch
        XCTAssertTrue(chapField.waitForExistence(timeout: 5))
        chapField.tap(); chapField.typeText("Encore")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Encore"].waitForExistence(timeout: 5))

        // Rename the playlist via the detail menu.
        app.buttons["playlist-menu"].tap()
        app.buttons["rename-playlist"].tap()
        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap(); renameField.typeText(" Mix")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["BBQ Mix"].waitForExistence(timeout: 5))

        // Delete via the detail menu → confirmation → pops back to the list.
        app.buttons["playlist-menu"].tap()
        app.buttons["delete-playlist"].tap()
        let confirm = app.buttons.matching(identifier: "delete-playlist-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 5))
    }
    #endif
}

// MARK: - Setlist (Play → frozen)

final class SetlistUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // seed "Seeded Set" w/ sng_1
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    func testSeededPlaylistVisible() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testPlayBuildsSetlistWithTrack() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["playlist-play"].waitForExistence(timeout: 5))
        app.buttons["playlist-play"].tap()

        // The frozen Setlist detail appears and lists at least one track.
        XCTAssertTrue(app.otherElements["setlist-detail"].waitForExistence(timeout: 8)
                      || app.staticTexts["setlist-stats"].waitForExistence(timeout: 1)
                      || app.navigationBars.element.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["setlist-track-0"].waitForExistence(timeout: 5)
                      || app.staticTexts.matching(NSPredicate(format: "identifier == 'setlist-track-0'")).firstMatch.exists)
    }
    #endif
}

// MARK: - Index playlists ("From your sources")

/// The fixture has no source playlists, so we only assert the section/affordance
/// is absent (it's an empty optional) — the wiring is exercised by unit tests.
final class IndexPlaylistsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNoSourcePlaylistsInFixture() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
        // Fixture carries no `playlists`, so the "From your sources" section is hidden.
        XCTAssertFalse(app.staticTexts["From your sources"].exists)
    }
}
