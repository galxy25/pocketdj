import XCTest

/// END-TO-END playback integration test — drives the REAL macOS app against REAL
/// production resources (the public S3 rips bucket + the deployed Apple Music index,
/// optionally the online OpenSearch collection). It exists to catch the recurring
/// inline-player play/pause bugs the user keeps hitting: dead slide-out buttons and
/// the row ▶ "freezing" until you click the slide-out.
///
/// SKIPPED BY DEFAULT. It needs network + real catalog data, so it only runs when
/// `PDJ_INTEGRATION_PLAYBACK=1`. Credentials/config come from the ENVIRONMENT (never
/// hardcoded) and are forwarded into the app via `launchEnvironment`:
///   • PDJ_AOSS_ACCESS_KEY_ID / PDJ_AOSS_SECRET_ACCESS_KEY / PDJ_AOSS_REGION /
///     PDJ_AOSS_ENDPOINT / PDJ_AOSS_INDEX  → online search (optional)
///
/// The deterministic, auth-free playable song is "Outta My System"
/// (sng_92ca0cd8da1f): it lives in the Apple Music (Local) catalog AND is already in
/// the PUBLIC rips manifest, so its mp3 streams from public S3 with no rip server and
/// no credentials. The play/pause bug is song-agnostic, so a manifest-cached song is
/// the right deterministic target (see the task note).
final class PlaybackIntegrationUITests: XCTestCase {
    /// The cached, publicly-playable target song.
    private let songId = "sng_92ca0cd8da1f"
    private let songQuery = "Outta My System"

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        // NOTE: do NOT set PDJ_USE_FIXTURE — we want the REAL Apple Music catalog +
        // the live public manifest. launchEnvironment fully defines the app's env.
        app.launchEnvironment["PDJ_INTEGRATION_PLAYBACK"] = "1"  // ephemeral settings store
        app.launchEnvironment["PDJ_TEST_PROBE"] = "1"            // expose player-state in a11y
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"   // launch defaults changed (home/Mix)
        // We resolve the song via ONLINE search (OpenSearch) rather than loading the 30MB
        // / 92k-song Apple Music index locally (that parse takes >120s in the harness and
        // isn't needed: the play/pause bug is song-agnostic and the song is in the PUBLIC
        // rips manifest, so it's playable with no auth). Only the small vinyl source loads
        // locally → `app.state == .loaded` fast → online search returns the cached song.
        // To also exercise the AM source, set PDJ_LOAD_APPLE_MUSIC=1 in this env.

        // Forward online-search creds from the RUN's environment, if present. Play/pause
        // doesn't need them (the song plays from public S3), but wiring them lets the
        // same harness also exercise online search when supplied.
        let env = ProcessInfo.processInfo.environment
        for key in ["PDJ_AOSS_ACCESS_KEY_ID", "PDJ_AOSS_SECRET_ACCESS_KEY",
                    "PDJ_AOSS_REGION", "PDJ_AOSS_ENDPOINT", "PDJ_AOSS_INDEX"] {
            if let v = env[key] { app.launchEnvironment[key] = v }
        }
        self.app = app
        return app
    }

    // MARK: - Probe helpers

    /// The probe static text whose value is "playing"/"paused".
    private var stateProbe: XCUIElement { app.staticTexts["player-state"] }

    /// Poll the probe until it reads `expected` (or fail). XCUITest re-queries each
    /// `.value` read, so this reflects the live `PlayerEngine.isPlaying`.
    private func assertState(_ expected: String, _ message: String,
                             timeout: TimeInterval = 6, file: StaticString = #file, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (stateProbe.value as? String) ?? (stateProbe.label)
            if last == expected { return }
            usleep(150_000)
        }
        XCTFail("\(message): expected player-state==\(expected) but was \(last)", file: file, line: line)
    }

    // MARK: - The test

    func testInlinePlayerPlayPauseAcrossSurfaces() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PDJ_INTEGRATION_PLAYBACK"] == "1",
                          "integration test — needs real production resources")

        let app = makeApp()
        app.launch()

        // 1. Wait for the browser shell to render (the search-mode toolbar toggle is
        // always present), then switch to Songs (⌘2) and turn ON online search. We do
        // NOT load the 30MB / 92k-song Apple Music index — only the small vinyl source
        // loads, so the catalog reaches `.loaded` fast and OpenSearch resolves the song.
        let searchMode = app.el("search-mode")
        XCTAssertTrue(searchMode.waitForExistence(timeout: 30),
                      "browser never rendered (search-mode toggle absent).\nA11Y TREE:\n\(app.debugDescription)")
        app.selectKind(songs: true)              // ⌘2
        searchMode.tap()                          // on-device → online (OpenSearch)

        // 2. Focus the search field (⌘L) + type the query, retrying — the catalog may
        // still be loading on the first attempt (online results only render once loaded),
        // and on macOS the first ⌘L can land before the field is hittable. The retry loop
        // absorbs both. OpenSearch returns the cached song → its row carries `row-play-<id>`.
        let rowPlay = app.el("row-play-\(songId)")
        var typed = false
        for _ in 0..<8 {
            app.activate()
            app.typeKey("l", modifierFlags: .command)   // ⌘L → focus search field
            app.typeKey("a", modifierFlags: .command)   // select-all + replace any prior text
            app.typeKey(.delete, modifierFlags: [])
            app.typeText(songQuery)
            // Online search is debounced + a network round-trip → give it room.
            if rowPlay.waitForExistence(timeout: 20) { typed = true; break }
        }
        if !typed {
            XCTFail("row ▶ for \(songId) (\(songQuery)) never appeared after 8 online-search attempts.\n"
                    + "A11Y TREE:\n\(app.debugDescription)")
            return
        }
        XCTAssertTrue(waitUntilHittable(rowPlay, timeout: 30),
                      "row ▶ never became enabled/hittable — song not recognized as cached.\n"
                      + "A11Y TREE:\n\(app.debugDescription)")

        // Baseline: nothing is playing yet.
        XCTAssertTrue(stateProbe.waitForExistence(timeout: 5), "player-state probe missing")
        assertState("paused", "before first play")

        // 3a. ROW ▶ — first tap kicks off play (resolves the public S3 mp3, loads engine).
        rowPlay.tap()
        assertState("playing", "row ▶ first tap should start playback", timeout: 30)

        // 3b. ROW ▶ again — now a pause toggle. Back-to-back taps must each register.
        rowPlay.tap()
        assertState("paused", "row ▶ second tap should pause")

        rowPlay.tap()
        assertState("playing", "row ▶ third tap should resume (back-to-back works)")

        // 4. The slide-out inline player appeared once the song became now-playing. Its
        // presence is signalled by its own controls (the panel container deliberately
        // carries NO accessibility id — a container id propagates to every child on macOS
        // and clobbers their ids). The toggle is the panel's play/pause control.
        let toggle = app.el("player-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 8),
                      "slide-out player-toggle never appeared.\nA11Y TREE:\n\(app.debugDescription)")
        // The button ACTION must actually fire — `toggleCount` (a probe incremented inside
        // PlayerEngine.toggle()) distinguishes a dead-button hit-test bug from a state bug.
        let togglesBefore = self.toggleCount()
        toggle.tap()
        XCTAssertTrue(waitForToggleCount(greaterThan: togglesBefore, timeout: 4) > togglesBefore,
                      "slide-out toggle action never fired (toggleCount stuck at \(togglesBefore)) — the button is dead to taps.")
        assertState("paused", "slide-out toggle should pause")
        toggle.tap()
        assertState("playing", "slide-out toggle should resume")
        toggle.tap()
        assertState("paused", "slide-out toggle back-to-back (pause again)")
        toggle.tap()
        assertState("playing", "slide-out toggle back-to-back (resume again)")

        // 4b. CHEVRON — collapses/expands the panel. The scrubber lives only in the
        // expanded body, so its presence is our collapse signal. Playback unaffected.
        let chevron = app.el("player-chevron")
        XCTAssertTrue(chevron.waitForExistence(timeout: 5), "player-chevron missing")
        let scrubber = app.sliders["player-seek"]
        let wasExpanded = scrubber.exists
        chevron.tap()
        // The panel should toggle its expanded body.
        if wasExpanded {
            XCTAssertTrue(waitUntil(timeout: 4) { !self.app.sliders["player-seek"].exists },
                          "chevron should collapse the expanded body")
        } else {
            XCTAssertTrue(waitUntil(timeout: 4) { self.app.sliders["player-seek"].exists },
                          "chevron should expand the body")
        }
        assertState("playing", "chevron must not change playback")
        chevron.tap()   // toggle back
        assertState("playing", "chevron toggle-back must not change playback")

        // 4c. CLOSE — stops playback AND clears the now-playing panel.
        let close = app.el("player-close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "player-close missing")
        close.tap()
        assertState("paused", "close should stop playback")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.el("player-toggle").exists },
                      "close should clear the inline player / now-playing panel")
    }

    /// Read the `player-toggles` probe (how many times `PlayerEngine.toggle()` ran).
    private func toggleCount() -> Int {
        let e = app.staticTexts["player-toggles"]
        return Int((e.value as? String) ?? e.label) ?? 0
    }

    private func waitForToggleCount(greaterThan n: Int, timeout: TimeInterval) -> Int {
        var last = n
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            last = toggleCount()
            if last > n { return last }
            usleep(150_000)
        }
        return last
    }

    // MARK: - Small waits

    private func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            usleep(150_000)
        }
        return cond()
    }

    private func waitUntilHittable(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { el.exists && el.isHittable && el.isEnabled }
    }
}
