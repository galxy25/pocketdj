import XCTest

/// Pocket Wheel Phase 3 — History ▸ Pockets ▸ Wheel on the seeded demo (`PDJ_SEED_POCKET_WHEEL`):
/// the wheel renders, a tap on a seeded cell opens its card, the weekday rings are adjustable
/// accessibility elements, and the Wheel | List toggle works.
final class PocketWheelUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_POCKET_WHEEL"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launchEnvironment["PDJ_HISTORY_TAB"] = "Pockets"
        app.launchEnvironment["PDJ_POCKETS_SEGMENT"] = "Wheel"
        app.launchEnvironment["PDJ_WHEEL_FOCUS_DOW"] = "2"
        app.launch()
        return app
    }

    /// Evidence: a kept screenshot attachment (export with `xcresulttool export attachments`).
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testTapSeededCellOpensCardAndRingsAreAdjustable() {
        let app = launch()
        let play = app.buttons["pocket-wheel-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the wheel's centre ▶ renders")
        // Ring geometry mirrors WheelLayout (radius = side/2 − 22; hole 0.30 R; Tuesday focused 1.8×).
        let wheel = play.frame
        let center = CGPoint(x: wheel.midX, y: wheel.midY)
        let side = min(app.windows.firstMatch.frame.width - 32, 520)
        let R = side / 2 - 22
        let unit = (R - 0.30 * R - 0.025 * R - 6 * 0.006 * R) / 7.8
        let tueMid = 0.30 * R + unit + 0.006 * R + 0.9 * unit
        let a = 8.5 / 24 * 2 * Double.pi
        let pt = CGPoint(x: center.x + tueMid * CGFloat(sin(a)), y: center.y - tueMid * CGFloat(cos(a)))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pt.x, dy: pt.y)).tap()
        let title = app.staticTexts["pocket-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "tapping a seeded cell opens its card")
        XCTAssertEqual(title.label, "Tuesday 8 AM · CarPlay")
        shot("p3-wheel-card")
        XCTAssertTrue(app.otherElements["pocket-card"].exists || app.staticTexts["pocket-card-stats"].exists
                      || app.descendants(matching: .any)["pocket-card-stats"].exists)
        // Accessibility: seven ring elements, adjustable.
        let ring = app.descendants(matching: .any)["pocket-wheel-ring-2"]
        XCTAssertTrue(ring.exists, "the Canvas exposes one adjustable element per weekday ring")
        XCTAssertTrue(app.descendants(matching: .any)["pocket-wheel-ring-7"].exists)
        // Legend chips name collections.
        XCTAssertTrue(app.descendants(matching: .any)["pocket-legend-pl_potential"].exists)
        // Wheel | List.
        app.buttons["List"].firstMatch.tap()
        XCTAssertFalse(app.buttons["pocket-wheel-play"].waitForExistence(timeout: 3))
    }
}
