import XCTest

/// App Store screenshot driver — NOT a test of behavior. Launches against the bundled
/// `screenshot-index` fixture (a clearly-invented sample catalog: made-up artists and albums,
/// so nothing personal and no third-party artwork appears in the listing) and walks the
/// screens worth marketing, attaching a full-resolution screenshot of each. Run it on the
/// exact simulators whose sizes App Store Connect requires (iPhone 6.9", iPad 13") and pull
/// the PNGs out of the .xcresult.
final class AppStoreScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(section: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_FIXTURE_RESOURCE"] = "screenshot-index"
        app.launchEnvironment["PDJ_START_SECTION"] = section
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    func testCaptureMarketingScreens() {
        // 1 — Browse: the catalog (albums grid/list with genres/years).
        var app = launch(section: "Browser")
        _ = app.descendants(matching: .any).firstMatch.waitForExistence(timeout: 20)
        sleep(4)   // let the fixture catalog build + rows settle
        shot(app, "screen-01-browse")

        // 2 — Mix: the two-deck board.
        app.terminate()
        app = launch(section: "Mix")
        _ = app.buttons["mix-auto-mode"].firstMatch.waitForExistence(timeout: 20)
        sleep(2)
        shot(app, "screen-02-mix")

        // 3 — Playlists / collections.
        app.terminate()
        app = launch(section: "Playlists")
        _ = app.descendants(matching: .any).firstMatch.waitForExistence(timeout: 20)
        sleep(3)
        shot(app, "screen-03-playlists")

        // 4 — Studio (Producer): pads/sequencer. Section token is pinned as "Performance".
        app.terminate()
        app = launch(section: "Performance")
        _ = app.descendants(matching: .any).firstMatch.waitForExistence(timeout: 20)
        sleep(3)
        shot(app, "screen-04-studio")

        // 5 — History/home (the Now Playing deck home).
        app.terminate()
        app = launch(section: "History")
        _ = app.descendants(matching: .any).firstMatch.waitForExistence(timeout: 20)
        sleep(3)
        shot(app, "screen-05-history")

        app.terminate()
    }
}
