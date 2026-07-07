import XCTest

/// The iOS Mix "view mode" (Settings ▸ Mix ▸ Deck layout): stacked (the portrait default),
/// side-by-side, and the single-deck layout with ‹ › switchers that flip between the two decks.
/// Each arrangement is pinned deterministically via the PDJ_MIX_DECK_LAYOUT launch seam. iOS-only —
/// macOS is always side-by-side (the setting is hidden there), so these skip on Mac.
final class MixDeckLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ layout: String) -> XCUIApplication {
        #if !os(macOS)
        XCUIDevice.shared.orientation = .portrait        // the layouts below govern PORTRAIT — pin it
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        app.launchEnvironment["PDJ_MIX_DECK_LAYOUT"] = layout
        app.launch()
        return app
    }

    private func el(_ id: String) -> XCUIElement {
        XCUIApplication().descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Stacked (the default): both decks are mounted, one above the other, and there are no ‹ ›
    /// switchers. Deck B may be below the fold, so scroll to it if needed.
    func testStackedShowsBothDecks() throws {
        #if os(macOS)
        throw XCTSkip("deck layout is an iOS-only setting")
        #else
        let app = launch("stacked")
        XCTAssertTrue(el("deck-A-vu").waitForExistence(timeout: 25), "Deck A should render")
        if !el("deck-B-vu").exists { app.swipeUp() }
        XCTAssertTrue(el("deck-B-vu").waitForExistence(timeout: 5),
                      "Deck B should also render in stacked mode")
        XCTAssertFalse(el("mix-deck-next").exists, "no ‹ › switchers outside single mode")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "mix-stacked"; shot.lifetime = .keepAlways; add(shot)
        #endif
    }

    /// Single: exactly one deck at a time plus ‹ › switchers; EITHER chevron flips to the other deck
    /// (only two decks), so whichever thumb is closer flips it.
    func testSingleDeckSwitchesWithChevrons() throws {
        #if os(macOS)
        throw XCTSkip("deck layout is an iOS-only setting")
        #else
        let app = launch("single")
        XCTAssertTrue(el("deck-A-vu").waitForExistence(timeout: 25), "Deck A shows first")
        XCTAssertFalse(el("deck-B-vu").exists, "Deck B is unmounted in single mode")
        XCTAssertTrue(el("mix-deck-next").exists, "the › switch button should render")
        XCTAssertTrue(el("mix-deck-prev").exists, "the ‹ switch button should render")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "mix-single-deckA"; shot.lifetime = .keepAlways; add(shot)

        el("mix-deck-next").tap()                       // › flips to Deck B
        XCTAssertTrue(el("deck-B-vu").waitForExistence(timeout: 5), "› flips to Deck B")
        XCTAssertFalse(el("deck-A-vu").exists, "Deck A is unmounted after switching")

        el("mix-deck-prev").tap()                       // ‹ flips back to Deck A
        XCTAssertTrue(el("deck-A-vu").waitForExistence(timeout: 5), "‹ flips back to Deck A")
        #endif
    }

    /// Landscape always shows the two-up board — even when the setting is Single — because the
    /// deck-layout setting governs portrait only (there's width for both decks in landscape).
    func testLandscapeForcesSideBySide() throws {
        #if os(macOS)
        throw XCTSkip("deck layout is an iOS-only setting")
        #else
        let app = launch("single")
        XCTAssertTrue(el("deck-A-vu").waitForExistence(timeout: 25), "portrait single: Deck A shows")
        XCTAssertTrue(el("mix-deck-next").exists, "portrait single: ‹ › chevrons present")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(el("deck-B-vu").waitForExistence(timeout: 6),
                      "landscape shows BOTH decks side-by-side even though the setting is Single")
        XCTAssertFalse(el("mix-deck-next").exists, "no single-deck chevrons in landscape")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "mix-landscape-sidebyside"; shot.lifetime = .keepAlways; add(shot)
        #endif
    }
}
