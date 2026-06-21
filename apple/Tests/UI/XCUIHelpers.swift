import XCTest

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
