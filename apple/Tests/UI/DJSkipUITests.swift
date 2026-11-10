import XCTest

/// Now Playing ⏭ with DJ Mode on (np-dj-mode §3 "Skip = the Mix tab's Skip"). RELEASE BLOCKER
/// 2026-11-09: a press-highlight `DragGesture(minimumDistance: 0)` on the DJ branch of
/// `NPSkipNextButton` swallowed BOTH tap gestures — ⏭ did nothing with DJ Mode on. Unit tests
/// call `skipNext()` directly and could never see it; this drives the real button.
///
/// Held playback (`PDJ_HOLD_PLAYBACK`): the set runs with no audio, so a DJ skip takes the
/// immediate-advance path — the assertion is that the TAP REACHES `skipNext` (the title moves
/// on by exactly one row; a double-tap is ONE fast skip, never two).
final class DJSkipUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        // The restored 5-row showcase set at row 0, held: a skip moves the index without
        // resolving audio.
        app.launchEnvironment["PDJ_SEED_PLAYBACK_SESSION"] = "showcase"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    private func startSet() {
        app.launch()
        XCTAssertTrue(app.revealNowPlayingHome().waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["np-title"].waitForExistence(timeout: 10))
    }

    /// The showcase rows as the deck titles them under the UI fixture catalog: `sng_5` resolves to
    /// the fixture's "Blue Note"; `sng_24` / `sng_23` aren't in it and keep the snapshot titles.
    static let titles = ["Blue Note", "Tidal", "Sleepwalker's Waltz"]

    private var title: String { app.staticTexts["np-title"].label }

    /// The title becomes `expected` with the deck still on screen (the set still running).
    private func waitForTitle(_ expected: String, _ message: String) {
        let t = app.staticTexts["np-title"]
        let p = NSPredicate(format: "exists == true AND label == %@", expected)
        let ok = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: t)], timeout: 6) == .completed
        XCTAssertTrue(ok, "\(message) (title now: \(t.exists ? t.label : "<deck gone>"))")
    }

    /// DJ Mode on through the record's menu (long-press → "DJ Mode" — `DJModeMenuToggle`).
    private func turnDJOn() {
        let record = app.any("np-record")
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        record.press(forDuration: 1.2)
        let toggle = app.descendants(matching: .any)["np-menu-dj-mode"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the record menu offers DJ Mode")
        toggle.tap()
        let chip = app.el("np-dj-mode")
        if chip.waitForExistence(timeout: 5) {
            XCTAssertEqual(chip.value as? String, "On", "DJ Mode is on")
        }
    }

    /// The ⏭ on the deck — a button with DJ off, a tappable view with DJ on (same id).
    private var next: XCUIElement { app.any("np-next") }

    /// XCUITest reports the deck's transport row as not "hittable" inside its scroll container,
    /// so taps go to ⏭'s centre (nothing is scrolled: the deck and Up next fit on screen).
    private func revealNext() {
        XCTAssertTrue(next.waitForExistence(timeout: 5), "np-next on screen")
    }

    private func tapNext() { next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    private func doubleTapNext() { next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap() }

    /// DJ off: a tap advances one row (unchanged).
    func testTapAdvancesWithDJOff() throws {
        #if os(macOS)
        throw XCTSkip("iOS gesture check")
        #else
        startSet()
        XCTAssertEqual(title, Self.titles[0])
        revealNext()
        tapNext()
        waitForTitle(Self.titles[1], "⏭ advanced one row")
        #endif
    }

    /// DJ on: a single tap advances; a double-tap is ONE (fast) skip — exactly one row.
    func testTapAndDoubleTapSkipWithDJOn() throws {
        #if os(macOS)
        throw XCTSkip("iOS gesture check")
        #else
        startSet()
        turnDJOn()
        XCTAssertEqual(title, Self.titles[0])
        revealNext()
        tapNext()
        waitForTitle(Self.titles[1], "a single tap on ⏭ must skip with DJ Mode on")
        revealNext()
        doubleTapNext()
        waitForTitle(Self.titles[2], "a double-tap on ⏭ is ONE skip with DJ Mode on (never none, never two)")
        #endif
    }
}
