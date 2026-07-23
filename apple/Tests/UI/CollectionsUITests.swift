import XCTest

/// XCUITests for Pockets, Playlists, and the Setlist (Play → frozen) flow. One
/// multiplatform UI-test target (iPhone, iPad, Mac) against the bundled fixture
/// catalog with an isolated, freshly-cleared collections store (PDJ_USE_FIXTURE),
/// landing directly on a section (PDJ_START_SECTION).
///
/// Alert TextField typing + in-content button taps work on iOS; the deeper create/
/// rename/delete interactions are kept iOS-only (`#if !os(macOS)`) like the other
/// suites, because the macOS alert/keyboard path isn't reliably drivable headlessly.
///
/// NOTE: Pockets are now merged into the Playlists tab. All pocket tests launch via
/// PDJ_START_SECTION=Playlists and use the new-pocket / pocket-* toolbar + row ids
/// that live on the merged PlaylistsView.

// MARK: - Pockets (merged into Playlists tab)

final class PocketsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Pockets now live on the Playlists page — launch there.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    func testEmptyStateShowsCreate() {
        let app = launch()
        // The merged Playlists page shows both new-playlist and new-pocket in the toolbar.
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testCreateOpenRenameDeletePocket() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 15))
        app.buttons["new-pocket"].tap()

        // Create alert → type a name → Create.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("Soul")
        app.alerts.buttons["Create"].tap()

        // A pocket row appears (id pocket-<id>) in the merged list; open it.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pocket-pkt_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.otherElements["pocket-detail"].waitForExistence(timeout: 5)
                      || app.collectionViews["pocket-detail"].waitForExistence(timeout: 1)
                      || app.navigationBars["Soul"].waitForExistence(timeout: 5))

        // Rename via the detail menu.
        app.buttons["pocket-menu"].tap()
        app.buttons["rename-pocket"].tap()
        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap()
        renameField.typeText(" Crate")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Soul Crate"].waitForExistence(timeout: 5))

        // Delete via the detail menu → confirmation → pops back to the merged list.
        app.buttons["pocket-menu"].tap()
        app.buttons["delete-pocket"].tap()
        let confirm = app.buttons.matching(identifier: "delete-pocket-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Back on the merged list — new-pocket button should be visible again.
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 5))
    }

    /// List-level context menu (tap-and-hold a row) → Rename, without opening the pocket.
    func testListContextMenuRenamePocket() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-pocket"].waitForExistence(timeout: 15))
        app.buttons["new-pocket"].tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("Groove")
        app.alerts.buttons["Create"].tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pocket-pkt_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Tap-and-hold to open the row context menu, then tap Rename (id list-rename-<id>).
        row.press(forDuration: 1.2)
        let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'list-rename-pkt_'")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap(); renameField.typeText(" Box")
        app.alerts.buttons["Save"].tap()

        // The renamed pocket row is still in the merged list (we never navigated in).
        XCTAssertTrue(app.staticTexts["Groove Box"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["new-pocket"].exists)
    }
    #endif
}

// MARK: - Playlists

final class PlaylistsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    func testEmptyStateShowsCreate() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testCreateChapterRenameDeletePlaylist() {
        let app = launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
        app.buttons["new-playlist"].tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("BBQ")
        app.alerts.buttons["Create"].tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["BBQ"].waitForExistence(timeout: 5))

        // Add a chapter — now lives in the ⋯ menu (toolbar decluttered to Play/Shuffle/⋯).
        app.buttons["playlist-menu"].tap()
        app.buttons["add-chapter"].tap()
        let chapField = app.textFields.firstMatch
        XCTAssertTrue(chapField.waitForExistence(timeout: 5))
        chapField.tap(); chapField.typeText("Encore")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Encore"].waitForExistence(timeout: 5))

        // Rename the playlist via the detail menu.
        app.buttons["playlist-menu"].tap()
        app.buttons["rename-playlist"].tap()
        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.tap(); renameField.typeText(" Mix")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["BBQ Mix"].waitForExistence(timeout: 5))

        // Delete via the detail menu → confirmation → pops back to the list.
        app.buttons["playlist-menu"].tap()
        app.buttons["delete-playlist"].tap()
        let confirm = app.buttons.matching(identifier: "delete-playlist-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 5))
    }

    /// The name search bar (mirrors the Browser's `.searchable`): a substring query filters
    /// the list to matching playlists / pockets by NAME and flattens the folder hierarchy, so
    /// a match surfaces without expanding folders. Seeds "Seeded Set", creates "BBQ Ribs",
    /// then proves each query shows only its match.
    #if !os(macOS)
    func testNameSearchFiltersPlaylists() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // seeds "Seeded Set"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        // Add a second, distinctly-named playlist so the filter has something to exclude.
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
        app.buttons["new-playlist"].tap()
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("BBQ Ribs")
        app.alerts.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Seeded Set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BBQ Ribs"].waitForExistence(timeout: 5))

        // Search "seeded" (case-insensitive) → only "Seeded Set" remains.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "native search field should be in the bar")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
        field.typeText("seeded")
        XCTAssertTrue(app.staticTexts["Seeded Set"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["BBQ Ribs"].waitForExistence(timeout: 2),
                       "a non-matching playlist is filtered out")

        // Swap the query → the other one shows, the first is gone.
        field.buttons["Clear text"].tap()
        field.typeText("ribs")
        XCTAssertTrue(app.staticTexts["BBQ Ribs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Seeded Set"].waitForExistence(timeout: 2))

        // A no-match query shows the empty-results placeholder.
        field.buttons["Clear text"].tap()
        field.typeText("zzzznope")
        XCTAssertTrue(app.any("playlists-search-empty").waitForExistence(timeout: 5))

        // Clearing the field restores the full, unfiltered list.
        field.buttons["Clear text"].tap()
        XCTAssertTrue(app.staticTexts["Seeded Set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BBQ Ribs"].waitForExistence(timeout: 5))
    }
    #endif

    /// Convert a playlist into a pocket from the same ⋯ menu that holds Rip/Burn/Delete,
    /// then assert we land on the NEW pocket's detail (its `pocket-menu` is unique to
    /// PocketDetailView, so it disambiguates from the same-named playlist screen).
    func testConvertPlaylistToPocketFromMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // seeds "Seeded Set" w/ sng_1
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        // On compact iPhone the detail toolbar overflows — the ⋯ menu (holding Convert /
        // Rip / Burn / Delete, exactly like Delete) collapses behind the system "More"
        // button, where it re-surfaces as an unidentified nested "More" submenu. Drive
        // whichever layout the device presents (iPad shows the ⋯ menu directly).
        let convert = app.buttons["convert-to-pocket"]
        let menu = app.buttons["playlist-menu"]
        if menu.waitForExistence(timeout: 3) {
            menu.tap()
        } else if app.buttons["OverflowBarButtonItem"].waitForExistence(timeout: 3) {
            app.buttons["OverflowBarButtonItem"].tap()
            if menu.waitForExistence(timeout: 3) {
                menu.tap()
            } else {
                // The overflowed ⋯ Menu loses its id and reads as a second "More" button.
                let inner = app.buttons.matching(
                    NSPredicate(format: "label == %@ AND identifier != %@", "More", "OverflowBarButtonItem")
                ).firstMatch
                if inner.waitForExistence(timeout: 3) { inner.tap() }
            }
        }
        XCTAssertTrue(convert.waitForExistence(timeout: 5), app.debugDescription)
        convert.tap()

        // Landed on the converted pocket's detail.
        XCTAssertTrue(app.buttons["pocket-menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["pocket-detail"].waitForExistence(timeout: 5)
                      || app.collectionViews["pocket-detail"].waitForExistence(timeout: 1)
                      || app.navigationBars["Seeded Set"].waitForExistence(timeout: 5))
    }
    #endif
}

// MARK: - Setlist (Play → frozen)

final class SetlistUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false }
    // Terminate between tests so each gets a clean launch — back-to-back relaunches in one
    // class otherwise race (a lingering prior instance), an intermittent first-tap flake.
    override func tearDown() { app?.terminate(); app = nil }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // seed "Seeded Set" w/ sng_1
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        self.app = app
        return app
    }

    func testSeededPlaylistVisible() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
    }

    #if !os(macOS)
    func testPlayBuildsSetlistWithTrack() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["playlist-play"].waitForExistence(timeout: 5))
        app.buttons["playlist-play"].tap()

        // The frozen Setlist detail appears and lists at least one track.
        XCTAssertTrue(app.otherElements["setlist-detail"].waitForExistence(timeout: 8)
                      || app.staticTexts["setlist-stats"].waitForExistence(timeout: 1)
                      || app.navigationBars.element.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["setlist-track-0"].waitForExistence(timeout: 5)
                      || app.staticTexts.matching(NSPredicate(format: "identifier == 'setlist-track-0'")).firstMatch.exists)
    }

    /// Tapping a track in a set list (a track list) opens that song's detail — the fix for
    /// "tap does nothing". Uses 📋 Realize (a frozen take, no autostart) to avoid playback.
    func testSetlistTrackTapOpensSongDetail() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        // 📋 Make-set-list now lives in the ⋯ menu (decluttered toolbar).
        XCTAssertTrue(app.buttons["playlist-menu"].waitForExistence(timeout: 5))
        app.buttons["playlist-menu"].tap()
        XCTAssertTrue(app.buttons["playlist-realize"].waitForExistence(timeout: 5))
        app.buttons["playlist-realize"].tap()
        XCTAssertTrue(app.buttons["setlist-track-0"].waitForExistence(timeout: 8))
        // Tap the track's title → the tap-to-open navigates to the song's detail.
        let title = app.staticTexts["Neon"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 5))
    }
    #endif
}

// MARK: - Index playlists ("From your sources")

/// The fixture has no source playlists, so we only assert the section/affordance
/// is absent (it's an empty optional) — the wiring is exercised by unit tests.
final class IndexPlaylistsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNoSourcePlaylistsInFixture() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 15))
        // Fixture carries no `playlists`, so the "From your sources" section is hidden.
        XCTAssertFalse(app.staticTexts["From your sources"].exists)
    }
}

// MARK: - MISC3: collapsible "Your playlists" / "Your Pockets"

/// The two "Your …" sections gained folder-style expand/collapse (persisted via the same
/// UserDefaults store). Seeds a top-level playlist ("Seeded Set") and verifies the header
/// collapses it out of the tree and expands it back.
final class PlaylistsCollapseUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"   // one top-level playlist "Seeded Set"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()
        return app
    }

    #if !os(macOS)
    func testYourPlaylistsCollapsesAndExpands() {
        let app = launch()
        let header = app.descendants(matching: .any)
            .matching(identifier: "your-playlists-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the collapsible Your-playlists header")
        let seeded = app.staticTexts["Seeded Set"]
        XCTAssertTrue(seeded.waitForExistence(timeout: 5), "the seeded playlist shows while expanded")
        // Collapse ⇒ the row leaves the tree.
        header.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: seeded)],
             timeout: 5)
        // Expand ⇒ it returns.
        header.tap()
        XCTAssertTrue(seeded.waitForExistence(timeout: 5), "expanding shows the playlist again")
    }
    #endif
}
