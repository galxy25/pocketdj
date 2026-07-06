import XCTest

/// ⌘N → New Window (macOS + iPadOS multi-window). Lets the user run e.g. the Performance surface
/// in one window and the Mix surface in another without switching tabs. The command is wired once
/// in `PocketDJApp` (NewWindowCommands) and gated on `\.supportsMultipleWindows`, so it registers
/// on Mac + iPad but never on iPhone.
///
/// macOS-only assertions: `XCUIApplication.windows` is a Mac window concept and is the crisp,
/// non-flaky way to prove a *new* window actually opened. On iPad the same command path runs but
/// scenes aren't surfaced to XCUITest as countable windows, so the runtime check lives here (the
/// per-window navigation — driving one window to Performance, another to Mix — reuses the existing
/// ⌘P/⌘M section shortcuts already covered by PerformanceUITests within a single window).
final class MultiWindowUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// ⌘N opens exactly one additional, independent window; ⌘P then steers the NEW (frontmost)
    /// window to Performance while the original keeps Mix — the two windows carry independent
    /// per-window section state (RootView's `@State`), which is the whole point of the feature.
    func testCmdNOpensIndependentSecondWindow() throws {
        #if os(macOS)
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.any("mix-tab").waitForExistence(timeout: 20),
                      "macOS should land on the Mix tab in the first window")
        let before = app.windows.count

        app.activate()
        app.typeKey("n", modifierFlags: .command)      // File ▸ New Window

        // Window creation is async — poll briefly for the extra window to register.
        let deadline = Date().addingTimeInterval(10)
        while app.windows.count <= before, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(app.windows.count, before + 1,
                       "⌘N should open exactly one additional window")

        // The new window is frontmost — steer it to Performance. Both surfaces then coexist:
        // the new window shows Performance while the original still shows Mix, proving the
        // section state is per-window and not shared.
        app.typeKey("p", modifierFlags: .command)      // ⌘P → Performance (in the key window)
        XCTAssertTrue(app.any("studio-tab-picker").waitForExistence(timeout: 10),
                      "the new window should switch to Performance independently")
        XCTAssertTrue(app.any("mix-tab").exists,
                      "the original window should still be showing Mix")
        #else
        throw XCTSkip("Window counting is a macOS concept; iPad shares the same New Window command path")
        #endif
    }
}
