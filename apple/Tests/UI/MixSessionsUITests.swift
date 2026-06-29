import XCTest

/// Visual + nav smoke test for the Mix-tab session/steppers/gain features. Launches on the Mix tab,
/// drives a few stepper/effect/crossfader actions (which record session events even with empty
/// decks), then walks Mix → Sessions list → a session's replay timeline. Writes a PNG of each screen
/// to /tmp so the renders can be eyeballed, and asserts the key controls exist (so a layout/runtime
/// regression fails the build).
final class MixSessionsUITests: XCTestCase {

    func testMixSteppersToolbarAndSessionReplayRender() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        app.launch()

        // --- Mix tab: decks, steppers, gain, session toolbar ---
        XCTAssertTrue(app.buttons["mix-sessions"].firstMatch.waitForExistence(timeout: 20),
                      "Mix tab session toolbar button should exist")
        #if !os(macOS)   // macOS uses .toolbarTitleMenu (no a11y id); iOS uses a principal button
        XCTAssertTrue(firstWith("mix-session-title").waitForExistence(timeout: 5),
                      "centered session name (principal toolbar item) should render")
        #endif
        XCTAssertTrue(firstWith("deck-A-vol").waitForExistence(timeout: 5), "Vol slider should exist")
        XCTAssertTrue(app.buttons["deck-A-tempo-inc"].firstMatch.exists, "Tempo + stepper should exist")
        XCTAssertTrue(app.buttons["deck-A-vol-inc"].firstMatch.exists, "Vol + stepper should exist")
        save(app, "01-mix-tab")

        // Generate session events (no track needed — setters fire + record regardless).
        tapN("deck-A-tempo-inc", 3)
        tapN("deck-A-vol-inc", 5)          // push gain past 100% → boost styling
        tapIfExists("deck-A-fx-reverb")     // toggle an effect
        tapN("deck-B-pitch-inc", 2)
        if firstWith("crossfader").exists { firstWith("crossfader").adjust(toNormalizedSliderPosition: 0.7) }
        save(app, "02-mix-after-actions")

        // --- Sessions list ---
        app.buttons["mix-sessions"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mix-sessions-list"].waitForExistence(timeout: 8)
                      || firstWithPrefix("mix-session-row-").waitForExistence(timeout: 4),
                      "Sessions list should render")
        save(app, "03-sessions-list")

        // --- A session's replay timeline ---
        let row = firstWithPrefix("mix-session-row-")
        if row.waitForExistence(timeout: 4) {
            row.tap()
            XCTAssertTrue(app.buttons["mix-replay-playpause"].firstMatch.waitForExistence(timeout: 6),
                          "Replay controls should render")
            save(app, "04-session-replay")
        }
    }

    // MARK: - Helpers

    private var app: XCUIApplication { XCUIApplication() }

    /// First element of any type whose identifier equals `id` (element type differs per platform).
    private func firstWith(_ id: String) -> XCUIElement {
        XCUIApplication().descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func firstWithPrefix(_ prefix: String) -> XCUIElement {
        XCUIApplication().descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }
    private func tapN(_ id: String, _ n: Int) {
        let b = XCUIApplication().buttons[id].firstMatch
        guard b.waitForExistence(timeout: 2) else { return }
        for _ in 0..<n where b.isHittable { b.tap() }
    }
    private func tapIfExists(_ id: String) {
        let e = firstWith(id)
        if e.waitForExistence(timeout: 2), e.isHittable { e.tap() }
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name; att.lifetime = .keepAlways; add(att)
    }
}
