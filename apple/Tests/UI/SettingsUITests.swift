import XCTest

/// XCUITests for the Settings panel — runs on iPhone, iPad, and Mac. Uses an
/// isolated, freshly-cleared settings store (PDJ_USE_FIXTURE) and lands directly
/// on the Settings section (PDJ_START_SECTION). The settings Form is long, so
/// helpers scroll off-screen rows into view before asserting.
final class SettingsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()
        return app
    }

    /// Scroll until `element` is in the tree (SwiftUI Form is lazy → off-screen
    /// rows aren't present until scrolled).
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

    func testSettingsSectionsPresent() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        XCTAssertTrue(reveal(app, app.buttons["settings-rip-test"]))
        XCTAssertTrue(reveal(app, app.buttons["settings-reset"]))
    }

    func testAddSourceAppendsRow() {
        let app = launch()
        let add = app.buttons["settings-add-source"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        let before = app.buttons.matching(identifier: "settings-source-remove").count
        add.tap()
        let after = app.buttons.matching(identifier: "settings-source-remove").count
        XCTAssertEqual(after, before + 1)
    }

    func testLoadAppleMusicAddsSourceAndHidesButton() {
        let app = launch()
        let load = app.buttons["settings-load-apple-music"]
        XCTAssertTrue(load.waitForExistence(timeout: 15))
        let before = app.buttons.matching(identifier: "settings-source-remove").count
        load.tap()
        // Opt-in: the button disappears once Apple Music is loaded…
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: load)
        wait(for: [gone], timeout: 5)
        // …and a source row was appended.
        XCTAssertEqual(app.buttons.matching(identifier: "settings-source-remove").count, before + 1)
    }

    func testLoadMyDigitalAddsSourceAndHidesButton() {
        let app = launch()
        let load = app.buttons["settings-load-my-digital"]
        XCTAssertTrue(reveal(app, load))
        let before = app.buttons.matching(identifier: "settings-source-remove").count
        load.tap()
        // Opt-in: the button disappears once My Digital is loaded…
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: load)
        wait(for: [gone], timeout: 5)
        // …and a source row was appended.
        XCTAssertEqual(app.buttons.matching(identifier: "settings-source-remove").count, before + 1)
    }

    func testRipFromCloudTogglePresent() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        let toggle = app.switches["settings-rip-from-cloud"]
        XCTAssertTrue(reveal(app, toggle), "rip-from-cloud toggle should be in the Rip server section")
        XCTAssertTrue(toggle.isHittable, "the toggle should be tappable")
        // Defaults off (a fresh PDJ_USE_FIXTURE store).
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testEditsExportImportPresent() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        XCTAssertTrue(reveal(app, app.buttons["edits-import"]))
        XCTAssertTrue(app.buttons["edits-export"].exists)
    }

    func testResetShowsConfirmation() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        let reset = app.buttons["settings-reset"]
        XCTAssertTrue(reveal(app, reset))
        reset.tap()
        XCTAssertTrue(app.buttons["settings-reset-confirm"].waitForExistence(timeout: 3))
    }

    /// Easter egg: CONFIRMING the nuclear reset detonates the mushroom-cloud
    /// overlay (decoration only), which removes itself within a few seconds.
    /// iOS-only drive: confirmationDialog buttons aren't reliably tappable via
    /// XCUITest on macOS.
    func testResetConfirmDetonatesMushroomCloud() throws {
        #if os(macOS)
        throw XCTSkip("confirmation-dialog taps are iOS-only in this harness")
        #else
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        let reset = app.buttons["settings-reset"]
        XCTAssertTrue(reveal(app, reset))
        reset.tap()
        XCTAssertTrue(app.buttons["settings-reset-confirm"].waitForExistence(timeout: 3))
        // confirmationDialog exposes the destructive action twice in the a11y tree.
        app.buttons["settings-reset-confirm"].firstMatch.tap()
        let cloud = app.descendants(matching: .any)["nuke-cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 3), "the mushroom cloud should rise")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "mushroom-cloud"; shot.lifetime = .keepAlways; add(shot)
        // And it cleans up after itself (~2.5 s animation).
        for _ in 0..<20 where cloud.exists { usleep(300_000) }
        XCTAssertFalse(cloud.exists, "the cloud should fade away on its own")
        #endif
    }

    /// The Mix section exposes all three crossfade steppers — including the NEW manual-skip fade —
    /// so the Skip-button feature has a configurable fade length. Asserted by accessibility id
    /// (steppers surface differently per platform; the id matches on both).
    func testMixSectionHasCrossfadeAndSkipFadeControls() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        let skip = app.descendants(matching: .any)["settings-automix-skip-fade"]
        XCTAssertTrue(reveal(app, skip), "the new Skip-fade stepper must render in the Mix section")
        XCTAssertTrue(app.descendants(matching: .any)["settings-automix-lead"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-automix-fade"].exists)
        XCTAssertTrue(reveal(app, app.descendants(matching: .any)["settings-mix-cue-channel"]),
                      "the cue-output-channel picker must render in the Mix section")
        XCTAssertTrue(reveal(app, app.switches["settings-mix-beat-pulse"]),
                      "the beat-pulse toggle must render in the Mix section")
        #if os(iOS)
        XCTAssertTrue(reveal(app, app.descendants(matching: .any)["settings-mix-deck-layout"]),
                      "the iOS deck-layout (view-mode) picker must render in the Mix section")
        #endif
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-mix-section"; shot.lifetime = .keepAlways
        add(shot)
    }
}
