import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// The leading "＋ New Window" button on the home sidebar (`RootView.newWindowToolbar`,
/// accessibility id `new-window`). It opens a second window (`openWindow(id:"main")` — the
/// on-screen twin of ⌘N) and is gated on `\.supportsMultipleWindows`, so it must be:
///   • ABSENT on iPhone (can't display two windows), and
///   • PRESENT on iPad (multi-window).
/// visionOS + macOS also show it (verified in-sim; macOS *window counting* lives in
/// `MultiWindowUITests`). iOS-only here — the phone-vs-pad gating is the whole point.
final class NewWindowButtonUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNewWindowButtonGatedByIdiom() throws {
        #if os(iOS)
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launch()

        if UIDevice.current.userInterfaceIdiom == .phone {
            // Single-window device → the button never renders (self-hidden by the gate).
            XCTAssertFalse(app.el("new-window").waitForExistence(timeout: 5),
                           "iPhone must NOT show the New Window button")
        } else {
            // iPad shows the sidebar alongside detail — landscape guarantees the column is
            // on screen regardless of iPad size — so the leading "+" is present.
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.el("new-window").waitForExistence(timeout: 20),
                          "iPad should show the New Window button in the home sidebar")
        }
        #else
        throw XCTSkip("Presence-by-idiom is an iOS concern; macOS window behavior is in MultiWindowUITests")
        #endif
    }
}
