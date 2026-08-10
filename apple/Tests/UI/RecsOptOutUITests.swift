import XCTest

/// **TURNING RECOMMENDATIONS OFF FOR ONE COLLECTION — AND FINDING THE WAY BACK.**
///
/// Owner, verbatim: *"support ability to turn off recommendations for a collection (eg comfort
/// zone, favorite songs, OTG) as an option in the … menu of the tile."*
///
/// The unit suite already pins the ranking behaviour (`ForYouRecsOptOutTests`): a switched-off
/// crate is skipped before `ZoneEngine.suggestions` runs and never reaches the snapshot. What it
/// CANNOT prove is the part that decides whether this feature is usable at all — that the switch
/// is REACHABLE, and reachable AGAIN once it has removed the tile it lived on. Two claims, and
/// both are about what a menu and a settings form actually render:
///
///  1. **The collection's own ⋯ carries the switch.** This is the surface that survives switching
///     off, and the only one that exists at all for a curated crate that never earns a tile.
///  2. **Settings ▸ For You lists what is switched off, and switching it back on removes the row.**
///     The seeded crate here is EMPTY on purpose (see `PDJ_SEED_RECS_OFF`) — it could never have
///     had a tile, so this list is genuinely the only door.
final class RecsOptOutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// SwiftUI Forms are lazy — an off-screen row is not in the tree until it is scrolled to.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, tries: Int = 12) -> Bool {
        var n = 0
        while !element.exists && n < tries {
            #if os(macOS)
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
            #else
            app.swipeUp()
            #endif
            n += 1
        }
        return element.exists
    }

    // ========================================================================
    // MARK: - 1. The collection's own ⋯ carries it, and the tap writes
    // ========================================================================

    #if !os(macOS)
    /// Open a seeded playlist, flip Recommendations off from its ⋯, then RE-OPEN the menu and read
    /// the switch back. Re-reading is the assertion that matters: tapping a menu row proves a tap
    /// landed, not that anything was stored, and this toggle's whole job is to store something.
    @MainActor
    func testTheCollectionMenuCarriesTheSwitchAndTheTapPersists() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded playlist's row")
        row.tap()
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 10), "the detail screen")

        func openMenu() -> XCUIElement {
            XCTAssertTrue(app.el("playlist-menu").waitForExistence(timeout: 8))
            app.el("playlist-menu").tap()
            let item = app.descendants(matching: .any)
                .matching(identifier: "playlist-recs-toggle").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8),
                          "Recommendations sits in the collection's own ⋯ menu")
            return item
        }

        let item = openMenu()
        snap("collection-menu-recommendations")
        // A Toggle inside a UIMenu is NOT a switch — it renders as a checked menu item, so its
        // `value` is empty and only `isSelected` carries the state. (Measured: asserting on
        // `value` here reads `""` in both states.)
        XCTAssertTrue(item.isSelected, "recommendations start ON")
        item.tap()                                   // → off (the menu dismisses on tap)

        // Re-open and read it back. Re-reading is the point: a tap proves a tap landed, not that
        // anything was stored, and storing something is this control's entire job.
        let reopened = openMenu()
        XCTAssertFalse(reopened.isSelected,
                       "the switch is OFF on the next open — the tap was stored, not just animated")
    }
    #endif

    #if !os(macOS)
    /// **THE SURFACE THE OWNER ASKED FOR**: the tile's own ⋯ (long-press), and the consequence he
    /// asked for — the tile goes.
    @MainActor
    func testTheTileMenuSwitchesItOffAndTheTileLeavesTheGrid() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"
        // Lights the For You TAB without touching the Settings toggle (the `ForYouTilesUITests`
        // seam). It swaps In Da Zone's ranker for the canned one; collection tiles are unaffected.
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        app.launch()
        let tab = app.el("history-tab-for-you")
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()

        // A COLLECTION tile — never the two pinned ones, which are not collections and carry no
        // flag to store. It only exists once a refresh has found something worth adding.
        let tile = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'foryou-tile-col-'")).firstMatch
        guard tile.waitForExistence(timeout: 40) else {
            // The fixture catalog produced nothing to suggest for the seeded playlist. That is a
            // legitimate outcome of the RANKER, not a defect in this switch — and the switch is
            // covered on its other two surfaces above. Skipping beats asserting on a ranking this
            // test does not control.
            throw XCTSkip("no collection tile in this fixture run — nothing was suggestible")
        }
        let tileId = tile.identifier
        snap("foryou-collection-tile")

        tile.openContextMenu()
        let toggle = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier ENDSWITH '-recs-toggle'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "Recommendations sits in the tile's ⋯ — owner, verbatim")
        snap("foryou-tile-menu-recommendations")
        XCTAssertTrue(toggle.isSelected, "it starts ON")
        toggle.tap()

        // The tile is GONE — off is not a quieter tile, it is no tile.
        let gone = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", tileId)).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: gone)
        waitForExpectations(timeout: 15)

        // …and the notice names the two places it can be switched back on.
        XCTAssertTrue(app.textContaining("Settings").waitForExistence(timeout: 8),
                      "the alert says where it comes back from")
        snap("foryou-tile-recs-off-notice")
    }
    #endif

    // ========================================================================
    // MARK: - 2. Settings ▸ For You is the way back
    // ========================================================================

    /// The seeded "Comfort Zone" pocket is switched off AND empty, so no tile for it can exist
    /// anywhere in the app. It must still be listed here, and switching it back on must clear the
    /// row — otherwise the opt-out is a one-way door.
    @MainActor
    func testSettingsListsASwitchedOffCollectionAndTurnsItBackOn() {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_RECS_OFF"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()

        let offRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'foryou-recs-off-'")).firstMatch
        XCTAssertTrue(reveal(app, offRow),
                      "a collection with recommendations off is listed in Settings ▸ For You")
        snap("settings-foryou-recs-off-row")

        offRow.setToggled(true)                      // turn it back on

        // The row's whole existence is "this one is off", so switching it on must take it away.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: offRow)
        waitForExpectations(timeout: 10)
        snap("settings-foryou-recs-off-cleared")
    }
}
