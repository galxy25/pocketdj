import XCTest

/// DETERMINISTIC on-device repro driver for the MobileOne Mix bug (2026-09-01): Auto mode +
/// the "sap" collection shows the download banner and grows storage, but ▶ Play / Shuffle
/// never produce audio, and loader rows won't load a deck — while the same flow works on
/// other devices against the same server.
///
/// This test deliberately launches with the device's REAL persisted state (no PDJ_USE_FIXTURE
/// — the bug is state-dependent and two months of on-device state is the prime suspect), so it
/// must ONLY run against a device/simulator whose state you're willing to poke. It never
/// asserts the bug away: every step captures a screenshot attachment, and the final asserts
/// are diagnostic (they record what happened rather than failing fast), so one run yields a
/// full picture even when the bug reproduces.
final class MixSapReproUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true   // capture everything even when a step disappoints
    }

    func testAutoMixSapRepro() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"   // REAL state — no fixture seam
        app.launch()

        // --- 1. Mix tab up? ---
        let autoToggle = app.buttons["mix-auto-mode"].firstMatch
        XCTAssertTrue(autoToggle.waitForExistence(timeout: 30), "Mix tab should render")
        shot(app, "01-mix-tab")

        // --- 2. Ensure AUTO mode (the button label reads the CURRENT mode) ---
        if autoToggle.label.contains("Manual") {
            autoToggle.tap()
            _ = app.buttons["mix-auto-play"].firstMatch.waitForExistence(timeout: 5)
        }
        shot(app, "02-auto-mode")

        // --- 3. Pick the "sap" collection from the auto-source menu ---
        let source = any(app, "mix-auto-source")
        XCTAssertTrue(source.waitForExistence(timeout: 10), "collection picker should exist")
        source.tap()
        let sap = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "sap")).firstMatch
        let sapFound = sap.waitForExistence(timeout: 10)
        XCTAssertTrue(sapFound, "a collection named like 'sap' should appear in the picker menu")
        shot(app, "03-source-menu")
        guard sapFound else { return }
        sap.tap()
        shot(app, "04-sap-selected")

        // --- 4. The download bar state, pre-play ---
        let dlBar = any(app, "mix-dl-bar")
        _ = dlBar.waitForExistence(timeout: 10)
        record("pre-play: download bar exists=\(dlBar.exists) label=\(dlBar.exists ? dlBar.label : "-")")

        // --- 5. ▶ Play ---
        let play = app.buttons["mix-auto-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Play should exist")
        record("pre-play: play enabled=\(play.isEnabled)")
        play.tap()
        shot(app, "05-after-play")

        // --- 6. Observe for 2 minutes: is anything actually mixing? ---
        // Signals, all read from the a11y tree (deterministic, no internal access):
        //   • mix-auto-stop-banner — the Auto banner renders only while the auto machine LIVES
        //   • deck-A-seek / deck-B-seek — a deck seek slider exists only with a LOADED track
        //   • mix-dl-bar label — "N of M downloaded · … · K ripping" progress
        for i in 1...12 {
            sleep(10)
            let banner = app.buttons["mix-auto-stop-banner"].firstMatch
            let pause  = app.buttons["mix-auto-pause"].firstMatch
            let deckA  = any(app, "deck-A-seek")
            let deckB  = any(app, "deck-B-seek")
            let bar    = any(app, "mix-dl-bar")
            record("t+\(i * 10)s: banner=\(banner.exists) pause=\(pause.exists) " +
                   "deckA-loaded=\(deckA.exists) deckB-loaded=\(deckB.exists) " +
                   "dlbar=\(bar.exists ? bar.label : "gone")")
            if i % 3 == 0 { shot(app, String(format: "06-t%03ds", i * 10)) }
            // Success short-circuit: a live auto banner + a loaded deck = the mix started.
            if (banner.exists || pause.exists), deckA.exists || deckB.exists {
                shot(app, "07-SUCCESS-mix-live")
                record("RESULT: auto mix went LIVE at t+\(i * 10)s — bug did NOT reproduce")
                return
            }
        }
        shot(app, "07-FAIL-still-dead")
        record("RESULT: 120s after Play — auto machine never went live (bug REPRODUCED)")

        // --- 7. Repro the second symptom: a loader row tap that doesn't load ---
        // Open deck A's track loader; tap the first row; see if the deck gains a track.
        let loadA = app.buttons["deck-A-load"].firstMatch
        if loadA.waitForExistence(timeout: 5) {
            loadA.tap()
            shot(app, "08-loader-open")
            let row = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "mix-loader-row-")).firstMatch
            if row.waitForExistence(timeout: 5) {
                record("loader row: label=\(row.label)")
                row.tap()
                sleep(3)
                shot(app, "09-after-row-tap")
                let deckA = any(app, "deck-A-seek")
                record("after loader tap: deckA-loaded=\(deckA.exists)")
            } else {
                record("loader: no rows found in sheet")
                shot(app, "09-loader-empty")
            }
        }
    }

    // MARK: helpers

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name; att.lifetime = .keepAlways; add(att)
    }
    /// A record both in the test log AND as an attachment (survives xcresult extraction).
    private func record(_ s: String) {
        NSLog("[sap-repro] %@", s)
        let att = XCTAttachment(string: s)
        att.name = "log"; att.lifetime = .keepAlways; add(att)
    }
}
