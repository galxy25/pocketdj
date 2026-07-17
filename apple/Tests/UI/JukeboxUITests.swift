import XCTest

/// XCUITests for the Jukebox Hero tab — presence, the create form, the ⌘J shortcut
/// (hardware-keyboard platforms), and the Settings ▸ Jukebox Hero section. Uses the
/// isolated fixture store (PDJ_USE_FIXTURE) and lands directly on the section
/// (PDJ_START_SECTION uses the enum rawValue "Jukebox Hero"). No jukebox is ever
/// STARTED here — that would hit the network; the create form is the test surface.
final class JukeboxUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(section: String = "Jukebox Hero") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = section
        app.launch()
        return app
    }

    /// The tab lands on the create form: name field + Start button, no session UI.
    func testJukeboxTabShowsCreateForm() {
        let app = launch()
        XCTAssertTrue(app.textFields["jukebox-name"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["jukebox-start"].exists)
        XCTAssertFalse(app.buttons["jukebox-end"].exists, "no session yet ⇒ no live controls")
    }

    /// ⌘J from another section switches to Jukebox Hero. macOS-only, matching the
    /// house pattern (XCUIHelpers): keyboard chords are synthesized only where a
    /// hardware keyboard is native — simulators exercise the tab via the sidebar.
    func testCommandJSwitchesToJukebox() {
        #if os(macOS)
        let app = launch(section: "Browser")
        _ = app.wait(for: .runningForeground, timeout: 10)
        app.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(app.textFields["jukebox-name"].waitForExistence(timeout: 10))
        #endif
    }

    /// Settings gains the Jukebox Hero section (URL + token + test button).
    func testSettingsHasJukeboxSection() {
        let app = launch(section: "Settings")
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        var tries = 0
        let test = app.buttons["settings-jukebox-test"]
        while !test.exists && tries < 12 {
            #if os(macOS)
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
            #else
            app.swipeUp()
            #endif
            tries += 1
        }
        XCTAssertTrue(test.exists)
    }
}
