import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// History multi-select (Levi 2026-08: "multi-select and copy should work with items in the
/// history view"). History used to carry its own share-only `Set<String>`; it now rides the
/// SHARED `RowSelection`, so these mirror `MultiSelectUITests`: Select mode + the selection
/// bar's count/Select-all/Clear, Copy → paste into a playlist, the bar's Add to…, and the
/// per-scope guarantee that an armed History selection never hijacks taps in Browse.
///
/// iPhone + iPad only — macOS XCUITest can't see windows headlessly (memory doctrine), and
/// modifier-clicks aren't headless-drivable anywhere (they're covered by RowSelectionTests).
final class HistorySelectionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    #if !os(macOS)

    /// `PDJ_SEED_HISTORY=fixture` seeds plays of songs that EXIST in the fixture catalog
    /// (sng_2 "Pulse", sng_3 "Drift", sng_4 "Swing Low", newest first), so an add/paste out of
    /// History lands on real catalog songs and the target playlist's count actually moves.
    private func launch(seedCollections: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_HISTORY"] = "fixture"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        if seedCollections { app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1" }
        app.launch()
        return app
    }

    /// Switch to the Playback timeline (selection lives there) and wait for the first row.
    private func showPlayback(_ app: XCUIApplication) {
        XCTAssertTrue(app.el("history-tab-playback").waitForExistence(timeout: 20))
        app.el("history-tab-playback").tap()
        XCTAssertTrue(app.any("history-row-sng_2").waitForExistence(timeout: 10))
    }

    /// Arm Select mode from the toolbar (the touch path; a long-press menu shares its
    /// recognizer with the row's drag lift and is flaky to synthesize — see MultiSelectUITests).
    private func armSelect(_ app: XCUIApplication) {
        let select = app.el("history-select")
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(app.any("selection-bar").waitForExistence(timeout: 5),
                      "arming Select should raise the shared selection bar")
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

    /// Navigate to a sidebar section (iPhone: pop the detail stack first).
    private func gotoSection(_ app: XCUIApplication, _ name: String) {
        let sidebarRow = app.staticTexts[name]
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

    private func openSeededSet(_ app: XCUIApplication) {
        let row = app.staticTexts["Seeded Set"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.any("playlist-detail").waitForExistence(timeout: 5)
                      || app.collectionViews["playlist-detail"].waitForExistence(timeout: 2))
    }

    private func assertStats(_ app: XCUIApplication, prefix: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let stat = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(stat.waitForExistence(timeout: 5), file: file, line: line)
    }

    // MARK: - Tests

    /// Select mode + the shared bar: plain taps toggle, the count tracks, "Select all" takes
    /// the WHOLE filtered universe (3 seeded plays = 3 distinct songs), Clear dismisses.
    func testHistorySelectModeBarCountAndSelectAll() {
        let app = launch()
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        assertCount(app, "1")
        app.any("history-row-sng_3").tap()
        assertCount(app, "2")
        app.el("selection-select-all").tap()
        assertCount(app, "3")
        app.el("selection-clear").tap()
        XCTAssertTrue(app.any("selection-bar").waitForNonExistence(timeout: 5))
    }

    /// A row tapped twice in Select mode toggles back OFF (the shared model's toggle), and
    /// "Deselect all" empties the selection while KEEPING Select mode armed.
    func testHistoryToggleOffAndDeselectAllKeepsSelectMode() {
        let app = launch()
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        assertCount(app, "1")
        app.any("history-row-sng_2").tap()
        assertCount(app, "0")
        app.any("history-row-sng_3").tap()
        assertCount(app, "1")
        app.el("history-select-menu").tap()
        let deselect = app.buttons["history-deselect-all"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5))
        deselect.tap()
        assertCount(app, "0")
        // Still armed: another plain tap selects rather than navigating to song detail.
        app.any("history-row-sng_4").tap()
        assertCount(app, "1")
        XCTAssertFalse(app.any("song-detail").exists, "a Select-mode tap must not navigate")
    }

    /// Copy in History → Paste into a playlist. Proves the History selection serializes to the
    /// shared song pasteboard (`canCopy` needs History registered as the window's active list).
    func testHistoryCopyPastesIntoPlaylist() {
        let app = launch(seedCollections: true)
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        app.any("history-row-sng_3").tap()
        assertCount(app, "2")
        let copy = app.el("selection-copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.isEnabled, "Copy must be live for a History selection")
        copy.tap()
        app.el("selection-clear").tap()          // REQUIRED before tab navigation (⌘C shadow)
        gotoSection(app, "Collections")
        openSeededSet(app)
        app.el("playlist-menu").tap()
        let paste = app.buttons["paste-songs"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        // Seeded sng_1 + pasted sng_2, sng_3.
        assertStats(app, prefix: "3 songs")
    }

    /// The bar's "Add to ▸" — the batch add History never had.
    func testHistorySelectionBarAddToPlaylist() {
        let app = launch(seedCollections: true)
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        app.any("history-row-sng_3").tap()
        assertCount(app, "2")
        app.el("selection-add-to").tap()
        let playlistsMenu = app.any("selection-add-playlists")
        XCTAssertTrue(playlistsMenu.waitForExistence(timeout: 5))
        playlistsMenu.tap()
        // By IDENTIFIER, not label — an inline-expanded submenu's rows aren't guaranteed
        // to publish as Buttons (MultiSelectUITests' documented finding).
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'selection-add-playlist-pls_'"))
            .firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.el("selection-clear").tap()
        gotoSection(app, "Collections")
        openSeededSet(app)
        assertStats(app, prefix: "3 songs")
    }

    /// PER-SCOPE selection: a live History selection must not turn Browse taps into toggles.
    /// (The Browse row still navigates to song detail — the bug the scoped model prevents.)
    func testHistorySelectionDoesNotHijackBrowseTaps() {
        let app = launch()
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        assertCount(app, "1")
        gotoSection(app, "Browser")
        XCTAssertTrue(app.el("Songs").waitForExistence(timeout: 15))
        app.selectKind(songs: true)
        let row = app.any("song-sng_1")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 10),
                      "a plain tap in Browse must still navigate while History holds a selection")
    }

    /// History's Playback rows are the window's active list, so Select all takes History's
    /// universe — and switching to a tab with no song rows (Collection) tears the
    /// registration down instead of leaving ⌘A pointed at rows that aren't on screen.
    func testSelectionBarClearsWhenLeavingPlaybackTab() {
        let app = launch()
        showPlayback(app)
        armSelect(app)
        app.any("history-row-sng_2").tap()
        assertCount(app, "1")
        app.el("history-tab-collection").tap()
        XCTAssertTrue(app.any("selection-bar").waitForNonExistence(timeout: 5),
                      "the bar belongs to the Playback rows — it must not ride other tabs")
    }

    #endif
}
