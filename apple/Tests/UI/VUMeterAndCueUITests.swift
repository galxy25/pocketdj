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
        // Identifier across ALL element types, not `buttons[…]`: an opened `contextMenu` is a
        // menu on macOS, whose entries are menu items rather than buttons, so a `.buttons` query
        // can miss an entry that is visibly on screen. Same lookup works for the iOS menu.
        let pre = firstWith("deck-A-vu-pre")
        let post = firstWith("deck-A-vu-post")
        XCTAssertTrue(pre.waitForExistence(timeout: 6), "the context menu offers Pre-fader")
        XCTAssertTrue(post.exists, "the context menu offers Post-fader")
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

        // Cues is the 5th sub-tab (index 4).
        //
        // The iOS branch is the ORIGINAL code, unchanged and deliberately not routed through a
        // shared helper. A first attempt to unify the two platforms here REGRESSED iOS — the
        // suite went from green to "Cue search field should exist" — because the pre-tap wait
        // stopped being a 25s wait on `segmentedControls["studio-tab-picker"]` (which is what
        // gives the Performance tab time to finish rendering) and became a fast type-agnostic
        // match followed by a 5s wait inside the helper. The tap then fired before the picker
        // was ready and the Cues tab never opened. Whatever gets refactored here, the iOS path
        // must keep waiting on the SEGMENTED CONTROL for the full 25s before tapping.
        //
        // macOS gets its own branch because the segmented Picker is not a `segmentedControl`
        // (nor a Button) there — `segmentedControls["studio-tab-picker"]` resolves to nothing,
        // which is this test's macOS failure — so the Mac drives the app's own ⌘5 shadow button
        // (PerformanceView.tabShortcuts) instead of tapping a segment.
        #if os(macOS)
        XCTAssertTrue(app.any("studio-tab-picker").waitForExistence(timeout: 25),
                      "Performance sub-tab picker should render")
        app.activate()
        app.typeKey("5", modifierFlags: .command)
        #else
        let picker = app.segmentedControls["studio-tab-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 25), "Performance sub-tab picker should exist")
        let seg = picker.buttons.element(boundBy: 4)
        if seg.exists { seg.tap() } else { app.buttons["Cues"].firstMatch.tap() }
        #endif

        // Search + select the seeded track (sng_1 = "Neon", which has 2 seeded cues).
        let search = firstWith("cue-search")
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Cue search field should exist")
        search.tap()
        search.typeText("Neon")
        let row = firstWith("cue-track-row-sng_1")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Seeded track row should appear")
        row.tap()

        // `firstWith` (identifier, any type) not `buttons[…]`: this is an image-only
        // `.buttonStyle(.plain)` Button, the same shape as the ♥ that a `.buttons` query fails
        // to resolve on macOS (see FavoritesUITests.heart). Its sibling `cue-transport-scrub`
        // was already looked up this way.
        XCTAssertTrue(firstWith("cue-transport-playpause").waitForExistence(timeout: 8),
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
