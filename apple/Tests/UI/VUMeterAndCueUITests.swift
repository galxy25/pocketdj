import XCTest

/// Visual + nav verification for the new Mix VU meter (with its pre/post-fader context menu) and
/// the Performance ▸ Cues transport (play/pause + scrub). Writes a PNG of each screen so the renders
/// can be eyeballed, and asserts the key controls exist so a layout/runtime regression fails the
/// build. (The Mix cue-jump row needs a BURNED + cued track, which the fixture can't provide — Mix
/// only loads on-device burned files — so it is verified on-device, not here.)
final class VUMeterAndCueUITests: XCTestCase {

    /// VU meter renders on both decks; long-press / right-click reveals the Pre/Post-fader toggle.
    func testVUMeterAndPrePostMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        // Pin the classic side-by-side board so BOTH deck VU meters sit at the top, deterministically
        // (the iOS default is now the stacked layout). See MixDeckLayoutUITests for the layouts.
        app.launchEnvironment["PDJ_MIX_DECK_LAYOUT"] = "sideBySide"
        app.launch()

        let vu = firstWith("deck-A-vu")
        XCTAssertTrue(vu.waitForExistence(timeout: 25),
                      "Deck A VU meter should render above the volume slider")
        XCTAssertTrue(firstWith("deck-B-vu").exists, "Deck B VU meter should render")
        save(app, "01-mix-vu-meters")

        // Open the pre/post-fader context menu. macOS opens a `contextMenu` on a RIGHT-CLICK —
        // a synthesized long press does NOT produce one there — so `openContextMenu()` splits
        // rightClick (Mac) from press-and-hold (iOS/iPadOS).
        vu.openContextMenu()
        let pre = app.buttons["deck-A-vu-pre"].firstMatch
        let post = app.buttons["deck-A-vu-post"].firstMatch
        XCTAssertTrue(pre.waitForExistence(timeout: 6), "Long-press reveals the Pre-fader option")
        XCTAssertTrue(post.exists, "Long-press reveals the Post-fader option")
        save(app, "02-vu-prepost-menu")
        pre.tap()                                   // switch deck A to pre-fader
        XCTAssertTrue(firstWith("deck-A-vu").waitForExistence(timeout: 4),
                      "VU meter still renders after switching source")
        save(app, "03-vu-after-pre")
    }

    /// Performance ▸ Cues: selecting a track shows the play/pause + scrub transport under the timeline.
    func testCueTransportRendersInPerformance() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_STUDIO"] = "1"       // 2 cues on sng_1 ("Neon")
        app.launchEnvironment["PDJ_START_SECTION"] = "Performance"
        app.launch()

        // Cues is the 5th sub-tab. The sub-tab control is a `.segmented` Picker, which macOS
        // renders as a RadioGroup — `app.segmentedControls[...]` resolves to nothing there — so
        // the Mac drives it with the app's own ⌘5 shadow button (PerformanceView.tabShortcuts)
        // while iOS taps the segment. Wait on the CONTENT, not the picker, so the assertion is
        // about the tab actually being open on either platform.
        XCTAssertTrue(app.any("studio-tab-picker").waitForExistence(timeout: 25)
                      || app.el("cue-search").waitForExistence(timeout: 5),
                      "Performance sub-tab shell should render")
        app.selectStudioTab("5", label: "Cues")

        // Search + select the seeded track (sng_1 = "Neon", which has 2 seeded cues).
        let search = firstWith("cue-search")
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Cue search field should exist")
        search.tap()
        search.typeText("Neon")
        let row = firstWith("cue-track-row-sng_1")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Seeded track row should appear")
        row.tap()

        XCTAssertTrue(app.buttons["cue-transport-playpause"].firstMatch.waitForExistence(timeout: 8),
                      "Cue transport play/pause button should render under the timeline")
        XCTAssertTrue(firstWith("cue-transport-scrub").exists, "Cue transport scrub bar should render")
        save(app, "04-cue-transport")
    }

    // MARK: - Helpers

    private func firstWith(_ id: String) -> XCUIElement {
        XCUIApplication().descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name; att.lifetime = .keepAlways; add(att)
    }
}
