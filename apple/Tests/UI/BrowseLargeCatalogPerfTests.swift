import XCTest

/// One-off perf/eyeball smoke: load the REAL merged catalog (My Vinyl + Apple Music
/// (Local) ≈ 90k+ songs / 11k+ albums) over the network and confirm switching
/// Albums⇄Songs stays snappy with on-device paging + the results memo. Captures a
/// screenshot at each step and prints the switch latency (grep `PERF`).
///
/// NETWORK-DEPENDENT (downloads ~32 MB), so it's gated behind `PDJ_PERF_SMOKE=1` and
/// never runs in the normal offline suite. Enable with:
///   TEST_RUNNER_PDJ_PERF_SMOKE=1 xcodebuild test … \
///     -only-testing:PocketDJUITests/BrowseLargeCatalogPerfTests
final class BrowseLargeCatalogPerfTests: XCTestCase {

    func testKindSwitchStaysSnappyOnLargeCatalog() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PDJ_PERF_SMOKE"] == "1",
                          "network perf smoke — set TEST_RUNNER_PDJ_PERF_SMOKE=1 to run")

        let app = XCUIApplication()
        app.launchEnvironment["PDJ_LOAD_APPLE_MUSIC"] = "1"   // add the 90k-song source
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
        // No fixture → don't let the device's real persisted playback session restore a deck.
        app.launchEnvironment["PDJ_DISABLE_SESSION_RESTORE"] = "1"
        app.launch()

        // First launch downloads + parses ~32 MB and pre-builds the browse rows; give it room.
        let header = app.any("results-count")
        XCTAssertTrue(header.waitForExistence(timeout: 240), "large catalog never finished loading")
        print("PERF loaded albums count = \(header.value ?? "?")")
        attach(app, "01-albums-loaded")

        func firstRow(songs: Bool) -> XCUIElement {
            let prefix = songs ? "row-play-" : "album-"
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        // Warm the album grid so the first album↔song comparison is fair.
        XCTAssertTrue(firstRow(songs: false).waitForExistence(timeout: 30), "no album rows")

        func switchAndTime(toSongs: Bool, _ label: String) {
            let t0 = Date()
            app.selectKind(songs: toSongs)
            XCTAssertTrue(firstRow(songs: toSongs).waitForExistence(timeout: 60),
                          "\(label): target rows never rendered")
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "PERF %@ = %.3fs (count=%@)", label, dt, app.any("results-count").value as? String ?? "?"))
            attach(app, label)
        }

        switchAndTime(toSongs: true,  "02-albums-to-songs-cold")
        switchAndTime(toSongs: false, "03-songs-to-albums-warm")
        switchAndTime(toSongs: true,  "04-albums-to-songs-warm")
        switchAndTime(toSongs: false, "05-songs-to-albums-warm")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
