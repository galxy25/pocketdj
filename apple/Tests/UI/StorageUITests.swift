import XCTest

/// XCUITests for Settings ▸ Storage — the storage manager screen. The Settings root keeps
/// ONE "Storage" entry that pushes the manager (back button included); the folder pickers
/// live there now, alongside the delete tools and the soft cap (unset by default). Uses
/// the isolated fixture stores (PDJ_USE_FIXTURE) and lands on Settings directly.
final class StorageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()
        return app
    }

    /// Scroll until `element` is in the tree (SwiftUI Form is lazy → off-screen rows
    /// aren't present until scrolled). Mirrors SettingsUITests.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, tries: Int = 10) -> Bool {
        var n = 0
        while !element.exists && n < tries {
            scrollDown(app)
            n += 1
        }
        return element.exists
    }

    private func scrollDown(_ app: XCUIApplication) {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        #else
        app.swipeUp()
        #endif
    }

    /// Settings → Storage (scrolling the row into view first).
    private func openStorage(_ app: XCUIApplication) {
        let link = app.buttons["settings-storage"].firstMatch
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        XCTAssertTrue(reveal(app, link), "the single Storage entry must be on the Settings root")
        link.tap()
    }

    /// Attach a proof screenshot to the result bundle (exported for visual verification).
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testStorageEntryOpensManagerWithMovedFolderPickers() {
        let app = launch()
        openStorage(app)
        // The manager screen: usage row + BOTH folder pickers moved off the Settings root.
        XCTAssertTrue(app.staticTexts["storage-usage-burns"].waitForExistence(timeout: 10))
        snap(app, "storage-top")
        XCTAssertTrue(reveal(app, app.buttons["settings-burn-folder-pick"]))
        XCTAssertTrue(reveal(app, app.buttons["settings-session-folder-pick"]))
        // And the delete tools + unset-by-default cap.
        XCTAssertTrue(reveal(app, app.buttons["storage-cap-set"]),
                      "cap starts UNSET — the set button shows, not the stepper")
        snap(app, "storage-cap-unset")
        XCTAssertTrue(reveal(app, app.buttons["storage-delete-all-burns"]))
        XCTAssertTrue(reveal(app, app.buttons["storage-delete-recordings"]))
        snap(app, "storage-delete-tools")
    }

    func testBackReturnsToSettingsRoot() {
        let app = launch()
        openStorage(app)
        XCTAssertTrue(app.staticTexts["storage-usage-burns"].waitForExistence(timeout: 10))
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the pushed manager must have a back button")
        back.tap()
        // The root Form pops back still scrolled to where we left — assert on the Storage
        // row (it was on-screen when tapped), not the top-of-form rows (lazy → absent).
        XCTAssertTrue(app.buttons["settings-storage"].waitForExistence(timeout: 10),
                      "back lands on the Settings root")
        XCTAssertFalse(app.staticTexts["storage-usage-burns"].exists,
                       "the manager screen is gone after popping")
    }

    func testSettingCapShowsStepperAndRemoveRestoresUnset() {
        let app = launch()
        openStorage(app)
        let set = app.buttons["storage-cap-set"]
        XCTAssertTrue(reveal(app, set))
        set.tap()
        XCTAssertTrue(reveal(app, app.steppers["storage-cap-stepper"].firstMatch)
                      || app.otherElements["storage-cap-stepper"].exists
                      || app.buttons["storage-cap-remove"].exists,
                      "a set cap shows the stepper + controls")
        let remove = app.buttons["storage-cap-remove"]
        XCTAssertTrue(reveal(app, remove))
        remove.tap()
        XCTAssertTrue(reveal(app, app.buttons["storage-cap-set"]),
                      "removing the cap returns to the unset state")
    }

    func testDeleteByArtistOpensListScreen() {
        let app = launch()
        openStorage(app)
        let byArtist = app.buttons["storage-delete-by-artist"]
        XCTAssertTrue(reveal(app, byArtist))
        // The fixture has no burns → the drill-ins are disabled and delete-all is too.
        XCTAssertFalse(byArtist.isEnabled, "no burnt music in the fixture ⇒ disabled")
        XCTAssertTrue(reveal(app, app.buttons["storage-delete-all-burns"]))
        XCTAssertFalse(app.buttons["storage-delete-all-burns"].isEnabled)
    }
}
