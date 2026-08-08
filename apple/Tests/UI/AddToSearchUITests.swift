import XCTest

/// The Add-to-collection sheet's fuzzy filter (Levi 2026-08: "add a search bar at the top so
/// you can filter the playlists shown by fuzzy text search against the playlist or pocket
/// name"). Driven for real: create a second playlist from inside the sheet, then type a
/// vowel-less query and watch the non-matching row leave.
///
/// iPhone + iPad only — macOS XCUITest can't see windows headlessly (memory doctrine).
final class AddToSearchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    #if !os(macOS)

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"     // "Seeded Set"
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
        app.launch()
        return app
    }

    /// Browse ▸ Songs ▸ first row ▸ song detail ▸ "+" — the plain-button route into the sheet
    /// (no long-press: that gesture shares its recognizer with the row's drag lift and is
    /// flaky to synthesize — MultiSelectUITests documents it).
    private func openAddSheet(_ app: XCUIApplication, songId: String = "sng_1") {
        XCTAssertTrue(app.el("Songs").waitForExistence(timeout: 20))
        app.selectKind(songs: true)
        let row = app.any("song-\(songId)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let addButton = app.el("add-song-to")
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        XCTAssertTrue(app.textFields["add-search-field"].waitForExistence(timeout: 10),
                      "the sheet should open with the filter field pinned at the top")
    }

    /// Playlist rows currently listed in the sheet (`add-playlist-<id>`).
    private func playlistRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'add-playlist-'"))
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["add-search-field"]
        field.tap()
        field.typeText(text)
    }

    /// Poll the visible playlist-row count — SwiftUI re-renders the filtered list a frame or
    /// two after the keystroke lands, and this host is often under heavy load.
    private func assertPlaylistRowCount(_ app: XCUIApplication, _ expected: Int, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while playlistRows(app).count != expected && Date() < deadline { usleep(250_000) }
        XCTAssertEqual(playlistRows(app).count, expected, message, file: file, line: line)
    }

    /// The sheet's toolbar Done — scoped to the navigation bar because the software keyboard
    /// raised by typing publishes a "Done" return key of its own (a bare `buttons["Done"]`
    /// then dies with "Multiple matching elements found").
    private func tapSheetDone(_ app: XCUIApplication) {
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    /// Create "80s Night" from the sheet's own New-playlist row so there are TWO playlists to
    /// filter between.
    private func makeEightiesNight(_ app: XCUIApplication) {
        let field = app.textFields["new-playlist-field"]
        XCTAssertTrue(app.swipeTo(field), "the New playlist row should be reachable")
        field.tap()
        field.typeText("80s Night")
        app.buttons["new-playlist-add"].tap()
        XCTAssertTrue(app.buttons["80s Night"].firstMatch.waitForExistence(timeout: 15),
                      "the new playlist should appear in the Playlists section")
    }

    /// THE request: a vowel-less, space-less query still finds the playlist, and the
    /// non-matching one drops out. Clearing the field brings everything back.
    func testFuzzyQueryFiltersPlaylistRows() {
        let app = launch()
        openAddSheet(app)
        makeEightiesNight(app)
        assertPlaylistRowCount(app, 2, "Seeded Set + 80s Night")

        type(app, "80snght")
        assertPlaylistRowCount(app, 1, "only the fuzzy match should survive")
        XCTAssertTrue(app.buttons["80s Night"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Seeded Set"].firstMatch.exists)

        app.buttons["add-search-clear"].tap()
        XCTAssertTrue(app.buttons["Seeded Set"].firstMatch.waitForExistence(timeout: 15),
                      "clearing the field restores the full list")
        assertPlaylistRowCount(app, 2, "the full list is back")
    }

    /// A query that matches nothing says so (rather than showing an empty sheet), and the
    /// New-playlist row stays available — not finding it is when you want to create it.
    func testNoMatchesMessage() {
        let app = launch()
        openAddSheet(app)
        type(app, "zzzzq")
        XCTAssertTrue(app.staticTexts["add-search-no-matches"].waitForExistence(timeout: 15))
        assertPlaylistRowCount(app, 0, "every playlist row is filtered out")
        XCTAssertTrue(app.textFields["new-playlist-field"].exists)
    }

    /// The filter is a FILTER, not a new way to add: a row that survives a TYPO'd query still
    /// performs the real add — the seeded playlist goes from 1 song to 2.
    func testAddingFromAFilteredRowStillWorks() {
        let app = launch()
        openAddSheet(app, songId: "sng_2")        // NOT the seeded member (that's sng_1)
        type(app, "seedd")                        // typo'd "seeded" → still finds Seeded Set
        // Nothing has been added yet this launch, so there is no Recent section.
        XCTAssertFalse(app.buttons["recent-add-0"].exists)

        let target = playlistRows(app).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()

        // The add landed: the store's MRU now leads with that playlist, so the sheet grows a
        // Recent row for it — and it's the FILTERED Recent list, so the same query still
        // matches it. (Membership itself is asserted by the unit + MultiSelect suites; this
        // test's job is that filtering doesn't break the add.)
        let recent = app.buttons["recent-add-0"]
        XCTAssertTrue(recent.waitForExistence(timeout: 15),
                      "tapping a filtered row must perform the real add")
        // The Recent row names the chapter too ("Seeded Set › Default").
        XCTAssertTrue(recent.label.hasPrefix("Seeded Set"), "unexpected Recent label: \(recent.label)")
        tapSheetDone(app)
    }

    #endif
}
