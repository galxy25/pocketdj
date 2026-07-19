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

        // Stage 2 — Apple Music invite; skip ("Not now" is the same continue button).
        XCTAssertTrue(app.el("onboarding-continue").waitForExistence(timeout: 5))
        app.el("onboarding-back").tap()          // back returns to stage 1…
        XCTAssertTrue(app.any("onboarding-name").waitForExistence(timeout: 5))
        app.el("onboarding-continue").tap()      // …and forward again
        app.el("onboarding-continue").tap()      // skip Apple Music

        // Stage 3 — all three sources preselected; untick all ⇒ Continue disabled.
        let vinyl = app.switches["onboarding-source-vinyl"].firstMatch
        XCTAssertTrue(vinyl.waitForExistence(timeout: 5), "stage 3 should show source cards")
        let digital = app.switches["onboarding-source-digital"].firstMatch
        let streaming = app.switches["onboarding-source-streaming"].firstMatch
        vinyl.tap(); digital.tap(); streaming.tap()
        XCTAssertTrue(app.any("onboarding-zero-sources").waitForExistence(timeout: 5),
                      "zero sources should warn")
        XCTAssertFalse(app.el("onboarding-continue").isEnabled,
                       "Continue must be disabled with no sources")

        // Re-tick vinyl and finish.
        vinyl.tap()
        XCTAssertTrue(app.el("onboarding-continue").isEnabled)
        app.el("onboarding-continue").tap()

        // The gate came down and the real app is up (home menu / sidebar).
        XCTAssertTrue(app.staticTexts["PocketDJ"].firstMatch.waitForExistence(timeout: 20),
                      "completing onboarding should land in the app shell")
        XCTAssertFalse(app.any("onboarding-root").exists, "the cover must be gone")
    }

    /// Fixture runs WITHOUT the force seam must never meet the first-run wall — the
    /// suppression every existing UI suite depends on.
    @MainActor
    func testFixtureRunsSuppressOnboarding() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["PocketDJ"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.any("onboarding-root").exists,
                       "PDJ_USE_FIXTURE without PDJ_SHOW_ONBOARDING must skip the flow")
    }
}
