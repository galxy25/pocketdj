import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension XCUIApplication {
    /// Look up an interactive control by accessibility identifier or label.
    /// In-content + sheet controls are plain `Button`/`NavigationLink`, so a
    /// `.buttons` query resolves them on iPhone, iPad, and Mac and stays lazy
    /// (so `waitForExistence` works for controls that appear later).
    func el(_ key: String) -> XCUIElement { buttons[key] }

    /// Look up ANY element (button, static text, scroll view, …) by accessibility
    /// identifier. Used for non-button surfaces like the song-detail ScrollView or a
    /// song row (which is a plain view + `.onTapGesture`, not a Button).
    func any(_ key: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: key).firstMatch
    }

    /// Scroll-aware existence wait for LAZY containers (Form/List): off-screen rows
    /// don't exist in the a11y tree, and splitting a "swipe until exists" loop from a
    /// follow-up `waitForExistence` RACES — under heavy host load a mid-animation
    /// snapshot can report the row, the loop exits, the scroll settles back, and the
    /// wait (which never scrolls) starves for its whole timeout. Seen exactly once on
    /// the puzzle setup form's Start row, 2026-08-07. Alternating short waits with
    /// swipes keeps the scroll and the wait from diverging.
    ///
    /// iOS/iPadOS only IN PRACTICE — `swipeUp()` on the Application element can't resolve
    /// a hit point on macOS, so every swipe throws. It carries no `#if` of its own because
    /// it compiles everywhere and its only callers live inside `#if !os(macOS)` class
    /// fences; a NEW macOS-running caller must fence itself (or take the touch-free path)
    /// rather than un-fence this.
    @discardableResult
    func swipeTo(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }
        for _ in 0..<maxSwipes {
            swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// Bring the home Now Playing deck into view. The deck lives on the sidebar / home
    /// menu; since the launch default became History (2026-07-22), the COMPACT iPhone layout
    /// pushes the History detail IN FRONT of the sidebar, so pop the detail stack back until
    /// the panel shows. Restricted to iPhone on purpose: iPad/macOS use a two-column split
    /// where the sidebar (and its deck) stays visible beside the detail — there is NO back
    /// button, so a blind `navigationBars.buttons.element(boundBy:0)` would resolve to the
    /// sidebar's "+" New Window / a History toolbar button and tap it spuriously (opening a
    /// stray window) while the async session restore is still painting the panel. On those
    /// layouts this is a no-op; the caller's `waitForExistence` rides out the restore.
    /// Returns the panel element so callers can `waitForExistence` on it.
    @discardableResult
    func revealNowPlayingHome() -> XCUIElement {
        let panel = any("now-playing-panel")
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            for _ in 0..<6 where !panel.exists {
                let back = navigationBars.buttons.element(boundBy: 0)
                guard back.waitForExistence(timeout: 3) else { break }  // popped to the sidebar
                back.tap()
            }
        }
        #endif
        return panel
    }

    // Browser actions. On macOS the segmented Picker + window-toolbar buttons
    // aren't drivable via XCUITest, so we use the app's keyboard commands there;
    // on iOS we tap. Keeps one test body working on every platform.

    func selectKind(songs: Bool) {
        #if os(macOS)
        activate()
        typeKey(songs ? "2" : "1", modifierFlags: .command)            // ⌘1 / ⌘2
        #else
        el(songs ? "Songs" : "Albums").tap()
        #endif
    }

    func openFilter() {
        #if os(macOS)
        activate()
        typeKey("f", modifierFlags: [.command, .option])               // ⌥⌘F
        #else
        el("filter-button").tap()
        #endif
    }

    func openSort() {
        #if os(macOS)
        activate()
        typeKey("s", modifierFlags: [.command, .option])               // ⌥⌘S
        #else
        el("sort-button").tap()
        #endif
    }

    func toggleLayout() {
        #if os(macOS)
        activate()
        typeKey("v", modifierFlags: .command)                          // ⌘V
        #else
        el("layout-toggle").tap()
        #endif
    }
}

// MARK: - macOS idiom bridges
//
// XCUITest speaks UIKit natively; on macOS the SAME SwiftUI view lands on a different
// AppKit control with a different accessibility shape. These bridges keep ONE test body
// working on every platform instead of forcing an `#if !os(macOS)` fence. The three
// mappings that account for nearly every macOS-only UI-test failure in this repo:
//
//   SwiftUI view            iOS a11y element         macOS a11y element
//   ─────────────────────   ──────────────────────   ────────────────────────────
//   Picker(.segmented)      Button per segment       NOT a Button / SegmentedControl
//   Toggle                  Switch, value "0"/"1"    NOT a Switch; value isn't a String
//   Text                    string in `label`        `label` works for short rows;
//                                                    a wrapped headline does not
//
// SCOPE OF THE EVIDENCE — read this before trusting the right-hand column. What is
// MEASURED (from the macOS failure output in scratchpad/mac-baseline-full.log) is only
// the NEGATIVE half: `buttons["Artists"]`, `segmentedControls["studio-tab-picker"]`,
// `switches["debug-capture-toggle"].value as? String` and a `label CONTAINS` predicate on
// the activity headline each resolve to nothing/nil on macOS while working on iOS. The
// exact AppKit class each one maps TO is not established here, so every bridge below is
// written to be type-AGNOSTIC (match by identifier across all element types, or accept
// label OR value) rather than to bet on a specific replacement type. Don't "tidy" one of
// these into a single concrete query on the strength of this comment.

extension XCUIApplication {

    /// One option of a segmented `Picker`, by its VISIBLE LABEL. On iOS each segment is a
    /// `Button`; on macOS it is measurably NOT one (`buttons["Artists"]` and
    /// `segmentedControls["studio-tab-picker"]` both resolve to nothing there), so the Mac
    /// query is left type-agnostic — match the label across every element type — rather than
    /// betting on a particular AppKit class. Lazy on both, so `waitForExistence` still works
    /// for a picker that appears later.
    ///
    /// PREFER a ⌘-shortcut where the view offers one (`selectKind`, `selectArtists`, and the
    /// Producer sub-tabs' ⌘1–⌘7): those drive the app's own shadow buttons and don't depend on
    /// the segment being hittable at all. Where a test already has a WORKING iOS path, split it
    /// per-platform in the test rather than routing iOS through this — see
    /// VUMeterAndCueUITests, where unifying the two regressed iOS.
    func segment(_ label: String) -> XCUIElement {
        #if os(macOS)
        return descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
            .firstMatch
        #else
        return buttons[label].firstMatch
        #endif
    }

    /// Browser ▸ Artists (the 3rd kind segment). The segmented Picker isn't tappable on macOS,
    /// so use the app's own ⌘3 shadow button — the documented macOS route, same as `selectKind`.
    func selectArtists() {
        #if os(macOS)
        activate()
        typeKey("3", modifierFlags: .command)                          // ⌘3
        #else
        el("Artists").tap()
        #endif
    }

    /// A SwiftUI `Toggle` by accessibility identifier. On macOS it is not a `Switch` (the
    /// baseline shows `switches[…]` present-but-stateless there: `value as? String` is nil),
    /// so match by identifier across ALL element types instead of naming a replacement class.
    func toggleEl(_ key: String) -> XCUIElement {
        #if os(macOS)
        return descendants(matching: .any).matching(identifier: key).firstMatch
        #else
        return switches[key].firstMatch
        #endif
    }

    /// Any element whose VISIBLE TEXT contains `text`, matching `label` OR `value`.
    ///
    /// Why both: on macOS a `label CONTAINS` predicate misses the History activity HEADLINE
    /// ("Added “Running It Up” to AM Mix") while short single-line rows in the SAME list —
    /// `staticTexts["Aria"]`, `staticTexts["sng_ghost_legacy"]` — match by label fine. So it
    /// is NOT a blanket "macOS uses value, iOS uses label" rule; something about the wrapped
    /// headline moves it. Matching both fields is correct either way and costs nothing.
    func textContaining(_ text: String) -> XCUIElement {
        staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    /// Exact visible text, matching `label` OR `value` for the same reason as `textContaining`.
    func textEqual(_ text: String) -> XCUIElement {
        staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", text, text)
        ).firstMatch
    }

    /// Pop one level of the pushed detail stack. MEASURED: on macOS
    /// `navigationBars.buttons.element(boundBy: 0)` never resolves — that is the whole of
    /// StorageUITests.testBackReturnsToSettingsRoot's failure ("the pushed manager must have a
    /// back button"), while the same lookup works on iOS. So the Mac asks for the back control
    /// by NAME instead of by position in a bar that isn't there.
    ///
    /// Deliberately does NOT fall back to "tap the toolbar's first button" on macOS: that
    /// toolbar also carries New Window / New Playlist / Import, and a blind boundBy-0 tap fires
    /// one of those (the hazard `revealNowPlayingHome` documents). Returns false instead, so a
    /// caller's assertion fails honestly rather than the test wandering into a stray window.
    @discardableResult
    func goBack(timeout: TimeInterval = 5) -> Bool {
        #if os(macOS)
        let back = buttons["Back"].firstMatch
        guard back.waitForExistence(timeout: timeout) else { return false }
        back.tap()
        return true
        #else
        let back = navigationBars.buttons.element(boundBy: 0)
        guard back.waitForExistence(timeout: timeout) else { return false }
        back.tap()
        return true
        #endif
    }
}

extension XCUIElement {

    /// A Toggle's on/off state, normalized: iOS reports the String "0"/"1"; a macOS CheckBox
    /// reports an NSNumber. `nil` when the element exposes no readable state at all.
    var isToggledOn: Bool? {
        if let s = value as? String {
            if s == "1" || s.caseInsensitiveCompare("on") == .orderedSame { return true }
            if s == "0" || s.caseInsensitiveCompare("off") == .orderedSame { return false }
            return nil
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// Drive a Toggle to `on`, tolerating the SwiftUI Form hazard where a centre `.tap()`
    /// lands on the label rather than the switch (see [[xcuitest-form-toggle-tap]]).
    ///
    /// The retry fires ONLY when the state is readable AND still wrong. That guard matters:
    /// `isToggledOn` is nil for an element exposing no readable state, and "nil != on" is true,
    /// so an unguarded retry would tap a second time on a toggle that had ALREADY flipped —
    /// turning it straight back off and failing the very assertion it was meant to satisfy.
    /// One tap and stop is the correct behaviour when we cannot see the state.
    func setToggled(_ on: Bool) {
        guard isToggledOn != on else { return }
        tap()
        if let state = isToggledOn, state != on {
            coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// Open this element's `contextMenu`. macOS opens it on a RIGHT-CLICK; a long press does
    /// not produce one there. iOS/iPadOS use the long press.
    func openContextMenu() {
        #if os(macOS)
        rightClick()
        #else
        press(forDuration: 1.0)
        #endif
    }
}

// MARK: - macOS a11y tree dump (opt-in diagnostic)

/// Writes the real macOS accessibility tree for each screen that carries UI-test debt, so those
/// failures get triaged from EVIDENCE rather than from guesses about how AppKit renders a given
/// SwiftUI view.
///
/// NOT YET EXERCISED: at the time this landed the dump had never completed a run on this Mac
/// (three attempts lost to the AutomationModeUI orphan below and to focus contention), so treat
/// the individual dump bodies as unproven scaffolding rather than as a working tool. Everything
/// the accompanying test fixes rely on was derived from macOS FAILURE OUTPUT plus reading the
/// views — e.g. the `playlist-mode-picker` selector collision came from `PlaylistsView.swift:248`
/// (`playlist-mode-picker`) sitting above `:541` (`playlist-\(pl.id)`) in the same subtree, not
/// from a captured tree.
///
/// OPT-IN: every test skips unless `PDJ_DUMP_DIR` is set, the same shape
/// `BrowseLargeCatalogPerfTests` uses for its network smoke — so a normal suite pays nothing,
/// but the dump is one command away for whoever has an unlocked Mac:
///
///     TEST_RUNNER_PDJ_DUMP_DIR=/tmp/macdump \
///       bash scripts/test-macos.sh build-mactest \
///       -only-testing:PocketDJUITests/MacTreeDumpUITests
///
/// The runner process receives host env vars with the `TEST_RUNNER_` prefix stripped (the same
/// forwarding `LivOnboardingWalkUITests` uses for PDJ_SHOT_DIR), so read the UNPREFIXED name here.
///
/// IF THE RUN DIES WITH "Timed out while enabling automation mode" (60s, before any test body
/// executes), the FIRST thing to check is which launchd session your shell is in:
///
///     launchctl managername          # "Aqua" = fine.  "Background" = nothing here can work.
///
/// An SSH / agent shell lives in a **Background** session with no attachment to the logged-in
/// user's window server. macOS UI automation is then impossible no matter what the code under
/// test does, and every symptom is silent and easy to misread as a product bug:
///   • `screencapture -x` → "could not create image from display"
///   • System Events reports 0 windows for every app
///   • XCUITest dies at "Timed out while enabling automation mode"
///   • `CGSSessionScreenIsLocked` reads true even at an unlocked desk — it is describing a
///     session this process cannot see, so do NOT conclude the Mac is locked from it
///
/// Verified on 2026-08-08 from an agent shell: `launchctl managername` → Background and
/// `screencapture -x` → "could not create image from display", while the user was sitting at an
/// unlocked machine. `launchctl asuser 501 …` would bridge it but needs root. The workable route
/// is `scripts/mac-gui-runner.mjs`, started BY A HUMAN from Terminal.app on the Mac so it
/// inherits the Aqua session, which then runs the suite on the agent's behalf.
///
/// TWO RED HERRINGS, recorded so the next person doesn't re-derive them:
///   • A stale `AutomationModeUI` process. Killing an orphaned one was followed by a run that
///     reached "Running tests…", which looked causal and is what I first wrote down. It was not
///     the root cause — the session type was — and that run still produced nothing.
///   • Screen lock. See the CGSSessionScreenIsLocked note above; the reading is meaningless
///     from a Background session.
///
/// Separately, macOS UI runs need EXCLUSIVE window focus: a concurrent iOS-Simulator XCUITest
/// run produces "Failed to activate application" / "Unable to find hit point for Application",
/// which is contention, not a defect (see [[macos-ui-tests-need-exclusive-display]]). Treat a
/// log containing that string as CONTAMINATED and re-run, rather than triaging its failures.
final class MacTreeDumpUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["PDJ_DUMP_DIR"] == nil,
                      "macOS a11y tree dump — set TEST_RUNNER_PDJ_DUMP_DIR to run")
    }

    private var outDir: String {
        ProcessInfo.processInfo.environment["PDJ_DUMP_DIR"] ?? NSTemporaryDirectory()
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let text = app.debugDescription
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? text.write(toFile: (outDir as NSString).appendingPathComponent("\(name).txt"),
                        atomically: true, encoding: .utf8)
        let att = XCTAttachment(string: text); att.name = name; att.lifetime = .keepAlways; add(att)
    }

    private func app(_ env: [String: String]) -> XCUIApplication {
        let a = XCUIApplication()
        for (k, v) in env { a.launchEnvironment[k] = v }
        a.launch()
        return a
    }

    func testDumpBrowserAndAlbum() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Browser"])
        _ = a.el("album-alb_1").waitForExistence(timeout: 30)
        dump(a, "01-browser")
        a.el("album-alb_1").tap()
        _ = a.staticTexts["3 tracks"].waitForExistence(timeout: 10)
        dump(a, "02-album-detail")
    }

    func testDumpHistoryActivity() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_SEED_ACTIVITY": "1", "PDJ_START_SECTION": "History"])
        _ = a.el("history-tab-collection").waitForExistence(timeout: 30)
        a.el("history-tab-collection").tap()
        Thread.sleep(forTimeInterval: 3)
        dump(a, "03-history-collection")
    }

    func testDumpOnboardingStage3() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_SHOW_ONBOARDING": "1"])
        _ = a.el("onboarding-choice-device").waitForExistence(timeout: 30)
        a.el("onboarding-choice-device").tap()
        _ = a.any("onboarding-name").waitForExistence(timeout: 10)
        a.el("onboarding-continue").tap()
        _ = a.el("onboarding-back").waitForExistence(timeout: 10)
        dump(a, "04-onboarding-stage2")
        a.el("onboarding-continue").tap()
        Thread.sleep(forTimeInterval: 3)
        dump(a, "05-onboarding-stage3")
    }

    func testDumpPlaylistDetail() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_SEED_COLLECTIONS": "1", "PDJ_START_SECTION": "Playlists"])
        Thread.sleep(forTimeInterval: 5)
        dump(a, "06-playlists-root")
        let row = a.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-'")).firstMatch
        if row.waitForExistence(timeout: 20) { row.tap() }
        Thread.sleep(forTimeInterval: 3)
        dump(a, "07-playlist-detail")
    }

    func testDumpSettingsAndStorage() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Settings"])
        _ = a.buttons["settings-add-source"].waitForExistence(timeout: 30)
        dump(a, "08-settings-root-top")
        for _ in 0..<10 where !a.buttons["settings-storage"].exists {
            a.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        }
        dump(a, "09-settings-scrolled")
        a.buttons["settings-storage"].tap()
        _ = a.staticTexts["storage-usage-burns"].waitForExistence(timeout: 15)
        dump(a, "10-storage-manager")
    }

    func testDumpAppleMusicPane() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Settings"])
        _ = a.buttons["settings-add-source"].waitForExistence(timeout: 30)
        let row = a.buttons["settings-apple-music"]
        for _ in 0..<10 where !row.exists {
            a.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        }
        var note = "amRow exists=\(row.exists) hittable=\(row.isHittable)\n"
        row.tap()
        Thread.sleep(forTimeInterval: 4)
        note += "after tap: am-collections-sync exists="
            + "\(a.descendants(matching: .any).matching(identifier: "am-collections-sync").firstMatch.exists)\n"
        try? note.write(toFile: (outDir as NSString).appendingPathComponent("18-am-note.txt"),
                        atomically: true, encoding: .utf8)
        dump(a, "19-am-pane")
    }

    func testDumpCollectionsRoot() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Playlists"])
        Thread.sleep(forTimeInterval: 6)
        dump(a, "20-collections-root")
    }

    func testDumpDebugPane() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Settings"])
        _ = a.buttons["settings-add-source"].waitForExistence(timeout: 30)
        for _ in 0..<10 where !a.buttons["settings-debug"].exists {
            a.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        }
        a.buttons["settings-debug"].tap()
        Thread.sleep(forTimeInterval: 3)
        dump(a, "11-debug-pane")
        let t = a.descendants(matching: .any).matching(identifier: "debug-capture-toggle").firstMatch
        var note = "exists=\(t.exists) type=\(t.elementType.rawValue) value=\(String(describing: t.value)) hittable=\(t.isHittable)\n"
        t.tap()
        Thread.sleep(forTimeInterval: 1)
        note += "afterTap value=\(String(describing: t.value))\n"
        let att = XCTAttachment(string: note); att.name = "12-debug-toggle-note"; att.lifetime = .keepAlways; add(att)
        try? note.write(toFile: (outDir as NSString).appendingPathComponent("12-debug-toggle-note.txt"),
                        atomically: true, encoding: .utf8)
        dump(a, "13-debug-after-toggle")
    }

    func testDumpMixAndPerformance() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_START_SECTION": "Mix",
                     "PDJ_MIX_DECK_LAYOUT": "sideBySide"])
        let vu = a.descendants(matching: .any).matching(identifier: "deck-A-vu").firstMatch
        _ = vu.waitForExistence(timeout: 40)
        dump(a, "14-mix")
        #if os(macOS)
        if vu.exists { vu.rightClick() }
        #endif
        Thread.sleep(forTimeInterval: 2)
        dump(a, "15-mix-after-rightclick")
    }

    func testDumpPerformanceCues() {
        let a = app(["PDJ_USE_FIXTURE": "1", "PDJ_SEED_STUDIO": "1", "PDJ_START_SECTION": "Performance"])
        Thread.sleep(forTimeInterval: 8)
        dump(a, "16-performance")
        #if os(macOS)
        a.activate()
        a.typeKey("5", modifierFlags: .command)
        #endif
        Thread.sleep(forTimeInterval: 3)
        dump(a, "17-performance-cues")
    }
}
