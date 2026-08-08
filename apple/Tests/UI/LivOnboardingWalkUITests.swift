import XCTest

/// Screenshot walk for the first-run setup guide (a new public Apple Music user
/// setting the app up from scratch). Each test launches onto one setup surface
/// and saves numbered PNGs so a guide builder can embed them: shots go to
/// PDJ_SHOT_DIR (forward with TEST_RUNNER_PDJ_SHOT_DIR) and also attach to the
/// result bundle. Credentials/endpoints typed into fields come from
/// PDJ_GUIDE_AKID / PDJ_GUIDE_SECRET / PDJ_GUIDE_RIP_URL / PDJ_GUIDE_JUKEBOX_URL
/// (runner env) — placeholders otherwise, so nothing sensitive lives in the repo.
/// Assertions are the minimum needed to know a screen actually rendered.
final class LivOnboardingWalkUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var shotDir: String { env["PDJ_SHOT_DIR"] ?? NSTemporaryDirectory() }
    private var guideAKID: String { env["PDJ_GUIDE_AKID"] ?? "AKIAEXAMPLEKEYID" }
    private var guideSecret: String { env["PDJ_GUIDE_SECRET"] ?? "example-secret-key" }
    private var guideRipURL: String { env["PDJ_GUIDE_RIP_URL"] ?? "https://example.invalid:10000" }
    private var guideJukeboxURL: String { env["PDJ_GUIDE_JUKEBOX_URL"] ?? "https://example.invalid:8443/jukebox" }

    /// Save a PNG to the shot dir AND attach it to the result bundle (fallback).
    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png"))
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

    /// `swipeUp()` on the Application element throws on macOS ("Unable to find hit point for
    /// Application") — there is no touch surface to swipe. Scroll the ScrollView instead, the
    /// same platform split SettingsUITests/StorageUITests already use.
    private func scrollDown(_ app: XCUIApplication) {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        #else
        app.swipeUp()
        #endif
    }

    private func scrollToTop(_ app: XCUIApplication, times: Int = 6) {
        for _ in 0..<times {
            #if os(macOS)
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 160)
            #else
            app.swipeDown()
            #endif
        }
    }

    /// Drive a SwiftUI Form Toggle to `on`. A center `.tap()` sometimes lands on the
    /// label and misses the switch, so if the value doesn't flip, tap the trailing thumb.
    /// State is read through `isToggledOn`, which normalizes iOS's "0"/"1" String against
    /// the NSNumber a macOS CheckBox reports.
    private func setToggle(_ toggle: XCUIElement, on: Bool) {
        toggle.setToggled(on)
    }

    /// Pop the iPhone detail stack back to the home menu (row `key` hittable).
    private func popHome(_ app: XCUIApplication, until key: String) {
        for _ in 0..<6 where !app.buttons[key].isHittable {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 3) else { break }
            back.tap()
        }
    }

    /// Focus a field and type — tap first so typeText has keyboard focus.
    private func type(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(text)
    }

    // MARK: 1 — first-run onboarding (3 stages)

    @MainActor
    func test01OnboardingWalk() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SHOW_ONBOARDING"] = "1"
        app.launch()

        // Stage 1 — profile choice.
        XCTAssertTrue(app.el("onboarding-choice-device").waitForExistence(timeout: 20))
        snap("01-onboarding-profile-choice")
        // The guide recommends "Link with iCloud" on a real iPhone; the sim has no
        // iCloud, so walk the on-device path — the name screen is identical.
        app.el("onboarding-choice-device").tap()
        let name = app.any("onboarding-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        type(name, "Liv")
        snap("02-onboarding-dj-name")
        app.el("onboarding-continue").tap()

        // Stage 2 — Apple Music sign-in invite.
        XCTAssertTrue(app.el("onboarding-back").waitForExistence(timeout: 5))
        snap("03-onboarding-apple-music")
        app.el("onboarding-continue").tap()          // "Not now" in the sim

        // Stage 3 — shared catalogs. Keep vinyl + digital, drop the shared AM catalog.
        // A SwiftUI `Toggle` is a Switch on iOS but a CheckBox on macOS — `toggleEl` resolves
        // either (see XCUIHelpers' macOS idiom bridges).
        let streaming = app.toggleEl("onboarding-source-streaming")
        XCTAssertTrue(streaming.waitForExistence(timeout: 5))
        snap("04-onboarding-sources-all-on")
        streaming.tap()
        snap("05-onboarding-sources-vinyl-digital")
        app.el("onboarding-continue").tap()          // "Start DJing"

        XCTAssertTrue(app.any("history-tab-playback").waitForExistence(timeout: 20))
        snap("06-first-launch-history")
    }

    // MARK: 2 — Settings walk (Apple Music pane, search keys, servers)

    @MainActor
    func test02SettingsWalk() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()

        // Settings root — Profile + Data sources are the first sections.
        XCTAssertTrue(app.el("settings-add-source").waitForExistence(timeout: 20))
        snap("07-settings-root")

        // Apple Music pane, Syncing tab (default): collections verbs up top.
        let amRow = app.el("settings-apple-music")
        XCTAssertTrue(reveal(app, amRow))
        amRow.tap()
        XCTAssertTrue(app.el("am-collections-sync").waitForExistence(timeout: 10))
        snap("08-apple-music-syncing-collections")

        // Favorites — the one toggle to flip: two-way favorites sync ON.
        let fav = app.toggleEl("favorites-sync-gate")
        XCTAssertTrue(reveal(app, fav))
        setToggle(fav, on: true)
        snap("09-favorites-two-way-on")

        // Private syncing — must be OFF for a fresh (public) install.
        let priv = app.toggleEl("am-private-sync")
        XCTAssertTrue(reveal(app, priv))
        XCTAssertEqual(priv.isToggledOn, false, "fresh install should be Public")
        snap("10-private-syncing-off")

        // Credentials tab — the Apple Music "Log in" row. Leave and re-enter the pane
        // so the segmented tab picker is guaranteed on-screen (the Form is long and
        // lazy; scrolling back up is flaky).
        // `goBack()` not `navigationBars.buttons[0]`: MEASURED on macOS — "Failed to tap Button
        // (Element at index 0): No matches found for Descendants matching type NavigationBar".
        // navigationBars is a UIKit concept and does not exist there.
        XCTAssertTrue(app.goBack(), "the Apple Music pane must have a back control")
        XCTAssertTrue(app.el("settings-add-source").waitForExistence(timeout: 10))  // root settled
        XCTAssertTrue(amRow.waitForExistence(timeout: 5))
        amRow.tap()
        let picker = app.any("am-settings-tab")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        var seg = picker.buttons["Credentials"].firstMatch
        if !seg.waitForExistence(timeout: 3) {
            seg = app.segmentedControls.buttons["Credentials"].firstMatch
        }
        if seg.exists {
            seg.tap()
        } else {
            // Two segments — Credentials is the right half.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        }
        // The row-level a11y id swallows the button's own: match by label OR row id.
        let login = app.buttons.matching(
            NSPredicate(format: "label == 'Log in' OR identifier == 'streaming-row-appleMusic'")
        ).firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        snap("11-apple-music-credentials")

        // Back to Settings root → Online search keys. Same reason as above.
        XCTAssertTrue(app.goBack(), "back out of the Apple Music pane")
        let akid = app.any("settings-search-akid")
        XCTAssertTrue(reveal(app, akid))
        type(akid, guideAKID)
        snap("12-online-search-keys")
        let secret = app.any("settings-search-secret")
        type(secret, guideSecret)
        // Return dismisses the keyboard; the green "Configured" badge is live
        // (computed from the two fields) so it shows without tapping Save.
        // Don't synthesize taps in the Save/Clear row: a Form row with multiple
        // borderless buttons can fire the wrong one and Clear blanks the keys.
        app.typeText("\n")
        _ = app.staticTexts["Configured"].waitForExistence(timeout: 5)
        snap("13-online-search-saved")

        // Import server URL + Test connection.
        let ripURL = app.any("settings-rip-url")
        XCTAssertTrue(reveal(app, ripURL))
        type(ripURL, guideRipURL)
        app.typeText("\n")
        let ripTest = app.el("settings-rip-test")
        XCTAssertTrue(reveal(app, ripTest))
        ripTest.tap()
        _ = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'songs' OR label CONTAINS 'Online' OR label CONTAINS 'Unreachable' OR label CONTAINS 'Timed'")
        ).firstMatch.waitForExistence(timeout: 20)
        snap("14-import-server")

        // Jukebox Hero broker URL + Test connection.
        let jukeboxURL = app.any("settings-jukebox-url")
        XCTAssertTrue(reveal(app, jukeboxURL))
        type(jukeboxURL, guideJukeboxURL)
        app.typeText("\n")
        let jukeboxTest = app.el("settings-jukebox-test")
        XCTAssertTrue(reveal(app, jukeboxTest))
        jukeboxTest.tap()
        _ = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Online' OR label CONTAINS 'Unreachable' OR label CONTAINS 'Timed'")
        ).firstMatch.waitForExistence(timeout: 20)
        snap("15-jukebox-server")
    }

    // MARK: 3 — real catalog: My Digital load, home menu, Browser + source filter

    @MainActor
    func test03BrowserRealCatalog() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_INTEGRATION_PLAYBACK"] = "1"
        app.launchEnvironment["PDJ_DISABLE_CLOUD_SYNC"] = "1"   // unsigned build: CKContainer traps
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()

        // Add the shared My Digital catalog from Settings ▸ Data sources.
        let loadDigital = app.el("settings-load-my-digital")
        XCTAssertTrue(reveal(app, loadDigital))
        snap("16-load-my-digital")
        loadDigital.tap()
        // The button disappears once the source is added; the catalog reload it kicks
        // off is heavy (real CDN fetch), so let the UI settle before navigating.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loadDigital)
        wait(for: [gone], timeout: 10)
        scrollToTop(app, times: 8)

        // Home menu (all the tabs in one shot), then into Browser. The sidebar rows
        // are List CELLS (selection-based), not buttons — drive them by static text.
        let browserRow = app.staticTexts["Browser"]
        for _ in 0..<6 where !browserRow.isHittable {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 5) else { break }
            back.tap()
            _ = browserRow.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(browserRow.waitForExistence(timeout: 30))
        snap("17-home-menu")
        browserRow.tap()

        // The real vinyl catalog streams down from the CDN — give it time.
        XCTAssertTrue(app.el("filter-button").waitForExistence(timeout: 90))
        _ = app.any("results-count").waitForExistence(timeout: 60)
        snap("18-browser-albums")

        app.selectKind(songs: true)
        _ = app.any("results-count").waitForExistence(timeout: 30)
        snap("19-browser-songs")

        // Filter to one source: Field "Source" · is · "My Vinyl".
        app.openFilter()
        let add = app.el("add-filter")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Field'")).firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            let source = app.buttons["Source"].firstMatch
            if source.waitForExistence(timeout: 5) { source.tap() }
            let value = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Value'")).firstMatch
            if value.waitForExistence(timeout: 5) {
                value.tap()
                let vinyl = app.buttons["My Vinyl"].firstMatch
                if vinyl.waitForExistence(timeout: 5) { vinyl.tap() }
            }
        }
        snap("20-filter-source-vinyl")
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        _ = app.any("results-count").waitForExistence(timeout: 30)
        snap("21-browser-vinyl-only")

        // Discover — the serverless Apple Music search tab.
        let discover = app.el("Discover")
        if discover.waitForExistence(timeout: 5) {
            discover.tap()
            _ = app.any("discover-hint").waitForExistence(timeout: 10)
            snap("22-discover")
        }
    }

    // MARK: 4 — Collections: the Shared tab (source playlists)

    @MainActor
    func test04CollectionsShared() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_INTEGRATION_PLAYBACK"] = "1"
        app.launchEnvironment["PDJ_DISABLE_CLOUD_SYNC"] = "1"   // unsigned build: CKContainer traps
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        // Yours | Shared is a `.segmented` Picker → a RadioGroup of RadioButtons on macOS,
        // Buttons on iOS. `segment(_:)` picks the right element type per platform.
        let shared = app.segment("Shared")
        XCTAssertTrue(shared.waitForExistence(timeout: 60))
        shared.tap()
        _ = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'source-group-'")
        ).firstMatch.waitForExistence(timeout: 60)
        snap("23-collections-shared")
    }

    // MARK: 5 — Jukebox Hero: the Start-a-jukebox screen

    @MainActor
    func test05JukeboxStart() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Jukebox Hero"
        app.launch()

        XCTAssertTrue(app.el("jukebox-start").waitForExistence(timeout: 20))
        snap("24-jukebox-start")
    }
}
