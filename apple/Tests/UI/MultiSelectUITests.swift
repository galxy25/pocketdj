import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// Multi-select flows: Browse Select mode + selection bar, copy → paste into a collection,
/// bar Add-to, paste dedup, and collection-detail select/copy. iPhone + iPad only — macOS
/// XCUITest can't see windows headlessly (memory doctrine), and drag-and-drop /
/// modifier-clicks aren't headless-drivable anywhere (they're covered by the
/// RowSelection/SongDrop/addSongs unit tests + the manual checklist).
///
/// NOTE: RootView's ⌘C `Playlists-shadow` is HIDDEN while a copyable selection exists
/// (conditional presence) — these tests clear the selection (or use the sidebar row)
/// before any Collections-tab navigation.
final class MultiSelectUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    #if !os(macOS)

    private func launch(section: String = "Browser", seedCollections: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = section
        if seedCollections { app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1" }
        app.launch()
        return app
    }

    /// Switch Browse to the Songs kind and wait for the first fixture row.
    private func showSongs(_ app: XCUIApplication) {
        XCTAssertTrue(app.el("Songs").waitForExistence(timeout: 15))
        app.selectKind(songs: true)
        XCTAssertTrue(app.any("song-sng_1").waitForExistence(timeout: 10))
    }

    /// Long-press `rowId` until its context menu shows `buttonId`. The row is ALSO a drag
    /// source (`.draggable`), and the drag lift shares the long-press interaction with the
    /// context menu — a single synthesized press occasionally starts a lift instead of
    /// opening the menu (the design's documented iOS risk), so retry a few times.
    /// Returns nil instead of failing so callers can retry the WHOLE gesture.
    private func rowMenuButtonIfPresent(_ app: XCUIApplication, rowId: String,
                                        buttonId: String, attempts: Int = 4) -> XCUIElement? {
        let row = app.any(rowId)
        guard row.waitForExistence(timeout: 10) else { return nil }
        let button = app.buttons[buttonId]
        for attempt in 0..<attempts {
            row.press(forDuration: attempt == 0 ? 1.2 : 0.8)
            if button.waitForExistence(timeout: 4) { return button }
            usleep(500_000)   // let a latched drag lift settle before re-pressing
        }
        return nil
    }

    private func rowMenuButton(_ app: XCUIApplication, rowId: String,
                               buttonId: String,
                               file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if let b = rowMenuButtonIfPresent(app, rowId: rowId, buttonId: buttonId) { return b }
        XCTFail("context-menu button \(buttonId) never appeared for \(rowId)", file: file, line: line)
        return app.buttons[buttonId]
    }

    /// Tap a CONTEXT-MENU item by its screen position instead of by element.
    ///
    /// `XCUIElement.tap()` re-resolves the element AFTER its "wait for app to idle", and a
    /// long-pressed `.draggable` row leaves the app non-idle for the full 60 s timeout — long
    /// enough for the menu to dismiss itself, at which point the tap dies with "No matches
    /// found" and (continueAfterFailure = false) kills the test. Reading `.frame` resolves
    /// against the snapshot that just proved the item exists, and a coordinate tap cannot
    /// fail to resolve — so a menu that vanished under us lands a harmless tap on the list
    /// instead, which the caller detects (no selection bar) and re-drives.
    private func tapCenter(_ app: XCUIApplication, of element: XCUIElement) {
        let f = element.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
    }

    /// Dismiss whatever menu/preview is on screen by tapping a neutral spot (the status-bar
    /// strip): a tap outside a UIKit menu only dismisses it, and with no menu up it hits
    /// nothing actionable. Then undo any navigation a stray tap caused.
    private func dismissTransientUI(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        usleep(400_000)
        if app.any("song-detail").waitForExistence(timeout: 1) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
    }

    /// Long-press a Browse song row → context-menu "Select" — arms Select mode with the row.
    /// The WHOLE gesture retries: the long-press shares its recognizer with the row's drag
    /// lift, so the menu can open and then close under the idle wait (see `tapCenter`). A
    /// cycle that leaves no selection bar is re-driven rather than reported as a product bug.
    private func enterSelectMode(_ app: XCUIApplication, songId: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.any("selection-bar")
        for _ in 0..<3 {
            if let button = rowMenuButtonIfPresent(app, rowId: "song-\(songId)",
                                                   buttonId: "select-song-\(songId)", attempts: 3) {
                tapCenter(app, of: button)
                if bar.waitForExistence(timeout: 8) { return }
            }
            dismissTransientUI(app)
        }
        XCTFail("Select mode never armed for song-\(songId)", file: file, line: line)
    }

    /// Poll the selection-count readout until it shows `expected`.
    private func assertCount(_ app: XCUIApplication, _ expected: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let count = app.staticTexts["selection-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), file: file, line: line)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (count.value as? String) == expected { return }
            usleep(200_000)
        }
        XCTAssertEqual(count.value as? String, expected, file: file, line: line)
    }

    /// Navigate to the Collections tab via the sidebar (iPhone: pop the detail stack first).
    private func gotoCollections(_ app: XCUIApplication) {
        let sidebarRow = app.staticTexts["Collections"]
        if UIDevice.current.userInterfaceIdiom == .phone {
            for _ in 0..<6 where !sidebarRow.isHittable {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                guard back.waitForExistence(timeout: 3) else { break }
                back.tap()
            }
        }
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5))
        sidebarRow.tap()
    }

    /// Open the seeded playlist's detail from the Collections list.
    private func openSeededSet(_ app: XCUIApplication) {
        let row = app.staticTexts["Seeded Set"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.any("playlist-detail").waitForExistence(timeout: 5)
                      || app.collectionViews["playlist-detail"].waitForExistence(timeout: 2))
    }

    /// The playlist-stats row reads "<n> songs · <runtime>".
    private func assertStats(_ app: XCUIApplication, prefix: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let stat = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(stat.waitForExistence(timeout: 5), file: file, line: line)
    }

    func testBrowseSelectModeBarAndSelectAll() {
        let app = launch()
        showSongs(app)
        enterSelectMode(app, songId: "sng_1")
        assertCount(app, "1")
        app.any("song-sng_2").tap()               // select-mode plain tap toggles
        assertCount(app, "2")
        app.el("selection-select-all").tap()      // FULL filtered universe = the fixture's 7
        assertCount(app, "7")
        app.el("selection-clear").tap()
        XCTAssertTrue(app.any("selection-bar").waitForNonExistence(timeout: 5))
    }

    func testCopyInBrowsePasteIntoPlaylist() {
        let app = launch(seedCollections: true)
        showSongs(app)
        enterSelectMode(app, songId: "sng_2")
        app.any("song-sng_3").tap()
        assertCount(app, "2")
        app.el("selection-copy").tap()
        app.el("selection-clear").tap()           // REQUIRED before tab navigation (see header)
        gotoCollections(app)
        openSeededSet(app)
        app.el("playlist-menu").tap()
        let paste = app.buttons["paste-songs"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        // Seeded sng_1 + pasted sng_2, sng_3.
        assertStats(app, prefix: "3 songs")
    }

    func testSelectionBarAddToPlaylist() {
        let app = launch(seedCollections: true)
        showSongs(app)
        enterSelectMode(app, songId: "sng_2")
        app.any("song-sng_3").tap()
        assertCount(app, "2")
        app.el("selection-add-to").tap()
        let playlistsMenu = app.any("selection-add-playlists")
        XCTAssertTrue(playlistsMenu.waitForExistence(timeout: 5))
        playlistsMenu.tap()
        // By IDENTIFIER, not label: the submenu expands inline and its rows are not
        // guaranteed to publish as `Button`s (the label-typed query found nothing while
        // "Seeded Set" was plainly on screen — see the run's screen recording).
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'selection-add-playlist-pls_'"))
            .firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.el("selection-clear").tap()
        gotoCollections(app)
        openSeededSet(app)
        assertStats(app, prefix: "3 songs")
    }

    func testPasteSkipsDuplicates() {
        let app = launch(seedCollections: true)
        showSongs(app)
        enterSelectMode(app, songId: "sng_1")     // sng_1 is already in the seeded playlist
        app.any("song-sng_2").tap()
        assertCount(app, "2")
        app.el("selection-copy").tap()
        app.el("selection-clear").tap()
        gotoCollections(app)
        openSeededSet(app)
        app.el("playlist-menu").tap()
        let paste = app.buttons["paste-songs"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        // Only sng_2 lands — sng_1 dedups against the existing node.
        assertStats(app, prefix: "2 songs")
    }

    func testCollectionDetailSelectAndCopy() {
        let app = launch(section: "Playlists", seedCollections: true)
        openSeededSet(app)
        app.el("playlist-menu").tap()
        let select = app.buttons["select-songs"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        // Tap the (single) seeded song row — select-mode toggle, not navigation.
        // ALSO the regression guard for the row accessibility traits: a row-level
        // `.accessibilityAddTraits(.isButton)` propagates to every descendant element, which
        // re-types the title/artist/BPM/duration labels as Buttons app-wide (and mis-reads
        // them to VoiceOver). If this StaticText stops resolving, that came back.
        let row = app.staticTexts["Neon"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        assertCount(app, "1")
        let copy = app.el("selection-copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()                                // pasteboard contents asserted in unit tests
        app.el("selection-clear").tap()
        XCTAssertTrue(app.any("selection-bar").waitForNonExistence(timeout: 5))
    }

    /// WS-C: the Browse song row's context menu offers "Add to Playlist…" → the shared
    /// AddToCollectionView sheet; adding to the seeded playlist from it works.
    func testBrowseRowAddToPlaylistSheet() {
        let app = launch(seedCollections: true)
        showSongs(app)
        tapCenter(app, of: rowMenuButton(app, rowId: "song-sng_2", buttonId: "add-to-song-sng_2"))
        // The shared sheet: toggle the seeded playlist row, then Done.
        let target = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'add-playlist-pls_'")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.buttons["Done"].tap()
        gotoCollections(app)
        openSeededSet(app)
        assertStats(app, prefix: "2 songs")
    }

    #endif
}
