import XCTest

/// Settings ▸ Apple Music ▸ Explicit versions — the 'Prefer explicit versions' toggle
/// flips and STICKS across a pane exit/re-entry (persistence rides the pane's
/// onDisappear persist). Value-driven Form-Toggle driving with the trailing-thumb
/// coordinate fallback (the Form-Toggle center-tap trap).
final class ExplicitPreferenceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Scroll until `element` exists (SwiftUI Form is lazy — off-screen rows absent).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, tries: Int = 10) -> Bool {
        var n = 0
        while !element.exists && n < tries {
            app.swipeUp()
            n += 1
        }
        return element.exists
    }

    /// Drive a SwiftUI Form Toggle to `on`. A center `.tap()` sometimes lands on the
    /// label and misses the switch, so if the value doesn't flip, tap the trailing thumb.
    private func setToggle(_ toggle: XCUIElement, on: Bool) {
        let want = on ? "1" : "0"
        guard (toggle.value as? String) != want else { return }
        toggle.tap()
        if (toggle.value as? String) != want {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    #if !os(macOS)
    @MainActor
    func testPreferExplicitToggleFlipsAndSticksAcrossPaneReentry() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()

        // Settings root → the Apple Music pane (Syncing tab is the default).
        let amRow = app.el("settings-apple-music")
        XCTAssertTrue(reveal(app, amRow))
        amRow.tap()

        // The Explicit-versions toggle starts OFF (tri-state UNSET reads false).
        let toggle = app.switches["am-prefer-explicit"].firstMatch
        XCTAssertTrue(reveal(app, toggle))
        XCTAssertEqual(toggle.value as? String, "0", "fresh install reads Off")

        setToggle(toggle, on: true)
        XCTAssertEqual(toggle.value as? String, "1")

        // Leave the pane (fires onDisappear persist) and re-enter — the choice stuck.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.el("settings-add-source").waitForExistence(timeout: 10))   // root settled
        XCTAssertTrue(amRow.waitForExistence(timeout: 5))
        amRow.tap()
        let again = app.switches["am-prefer-explicit"].firstMatch
        XCTAssertTrue(reveal(app, again))
        XCTAssertEqual(again.value as? String, "1", "preference persisted across re-entry")
    }
    #endif
}
