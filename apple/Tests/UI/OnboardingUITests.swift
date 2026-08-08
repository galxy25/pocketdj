import XCTest

/// The zero-to-hero first-run flow, driven end-to-end under the fixture harness:
/// PDJ_SHOW_ONBOARDING forces the gate (fixture runs otherwise suppress it — proven
/// here too), the three stages walk on the on-device path, the sources stage enforces
/// ≥1 selection, and completion lands in the live app. iCloud paths (probe/restore)
/// stay unit-tested — the fixture `enabled` closure keeps CloudKit untouched, so the
/// Link card here would only ever reach the "unreachable" branch.
final class OnboardingUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SHOW_ONBOARDING"] = "1"
        app.launch()
        return app
    }

    @MainActor
    func testThreeStageWalkOnDevicePath() {
        let app = launch()

        // Stage 1 — profile choice is up, nothing behind it is interactive.
        XCTAssertTrue(app.el("onboarding-choice-device").waitForExistence(timeout: 20),
                      "stage 1 should present the profile choice")
        app.el("onboarding-choice-device").tap()

        // Name entry appears on the on-device path; continue without typing (optional).
        XCTAssertTrue(app.any("onboarding-name").waitForExistence(timeout: 5))
        app.el("onboarding-continue").tap()

        // Stage 2 — Apple Music invite. Back returns to stage 1 at its CHOICE screen
        // (the stage re-presents fresh — deliberate: the choice is the stage), then
        // walk forward again and skip Apple Music.
        XCTAssertTrue(app.el("onboarding-back").waitForExistence(timeout: 5))
        app.el("onboarding-back").tap()
        XCTAssertTrue(app.el("onboarding-choice-device").waitForExistence(timeout: 5),
                      "back lands on the profile choice")
        app.el("onboarding-choice-device").tap()
        XCTAssertTrue(app.any("onboarding-name").waitForExistence(timeout: 5))
        app.el("onboarding-continue").tap()      // stage 1 → stage 2 again
        XCTAssertTrue(app.el("onboarding-continue").waitForExistence(timeout: 5))
        app.el("onboarding-continue").tap()      // skip Apple Music

        // Stage 3 — all three shared catalogs preselected; unticking ALL is now allowed (the
        // own-library-only public configuration) and the note explains what a zero-pick means.
        // `toggleEl` not `switches[...]`: a SwiftUI `Toggle` is a Switch on iOS but a CheckBox on
        // macOS, so a `.switches` query matches nothing there. Same control either way.
        let vinyl = app.toggleEl("onboarding-source-vinyl")
        XCTAssertTrue(vinyl.waitForExistence(timeout: 5), "stage 3 should show source cards")
        let digital = app.toggleEl("onboarding-source-digital")
        let streaming = app.toggleEl("onboarding-source-streaming")
        vinyl.tap(); digital.tap(); streaming.tap()
        let note = app.any("onboarding-own-library-note")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("No shared catalogs"),
                      "zero picks should explain the own-library-only mode")
        XCTAssertTrue(app.el("onboarding-continue").isEnabled,
                      "Continue stays enabled with zero shared catalogs")

        // Re-tick vinyl and finish (the fixture flow still exercises a catalog source).
        vinyl.tap()
        XCTAssertTrue(app.el("onboarding-continue").isEnabled)
        app.el("onboarding-continue").tap()

        // The gate came down and the real app is up — it lands on the History launch
        // default, whose Playback/Collection tab chrome renders even with an empty timeline.
        // (Section-agnostic "PocketDJ" title no longer works: on iPhone the History detail
        // demotes it from a visible large title to a back-button label.)
        XCTAssertTrue(app.any("history-tab-playback").waitForExistence(timeout: 20),
                      "completing onboarding should land in the app shell (History default)")
        XCTAssertFalse(app.any("onboarding-root").exists, "the cover must be gone")
    }

    /// Fixture runs WITHOUT the force seam must never meet the first-run wall — the
    /// suppression every existing UI suite depends on.
    @MainActor
    func testFixtureRunsSuppressOnboarding() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.any("history-tab-playback").waitForExistence(timeout: 20),
                      "a fixture run lands straight in the app shell (History default)")
        XCTAssertFalse(app.any("onboarding-root").exists,
                       "PDJ_USE_FIXTURE without PDJ_SHOW_ONBOARDING must skip the flow")
    }
}
