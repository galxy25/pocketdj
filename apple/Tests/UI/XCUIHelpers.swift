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
