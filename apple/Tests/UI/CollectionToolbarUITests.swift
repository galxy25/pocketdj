import XCTest

/// THE SAME SCREEN FURNITURE EVERYWHERE — 📱/☁️ · ▶ · ▶▶ · 🔀 · ⋯.
///
/// Owner, verbatim: *"i dont want a row level play menu, i want the native menu controls that
/// float in too like in a playlist we have the cloud or on device toggle play and shuffle and …
/// menu item for the context menus."* Plus the two corrections that followed: *"always show play
/// and play all and shuffle"*, and *"we want to be able to play or shuffle New as well, that is
/// the equivalent of cloud mode for a collection."*
///
/// Three claims to protect, none of them provable from the unit suite, because all three are about
/// what a navigation bar renders:
///
///  1. **A For You tile screen wears the playlist's toolbar** — from the shared `CollectionToolbar`,
///     so the two screens are the same furniture.
///  2. **New wears it too, live.** It is the tile whose rows he does not own, and it still floats a
///     working ▶ / ▶▶ / 🔀 and the device/cloud toggle that decides how they play.
///  3. **A collection ROW carries no transport.** A round of this shipped ▶/🔀 in the playlist and
///     pocket row context menus and was rejected; a long-press there is for rename/move/delete.
///
/// Screenshots are attached (`keepAlways`) so the toolbars can be compared side by side.
final class CollectionToolbarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchOnForYou() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        // The New tile's ▶ streams; the fixture must never actually start audio.
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
        app.launch()
        let tab = app.el("history-tab-for-you")
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "the fixture seam lights the For You tab")
        tab.tap()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The five items every list screen floats. `any` (not `buttons`) because the mode toggle and
    /// the ⋯ resolve to different element types across platforms.
    private func assertToolbar(_ app: XCUIApplication, _ prefix: String,
                               menu: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.any("\(prefix)-play").waitForExistence(timeout: 15),
                      "▶ floats in the toolbar, not in a row menu", file: file, line: line)
        XCTAssertTrue(app.any("\(prefix)-play-all").exists,
                      "▶▶ Play All beside it — owner: always show all three", file: file, line: line)
        XCTAssertTrue(app.any("\(prefix)-shuffle").exists, "…and 🔀", file: file, line: line)
        XCTAssertTrue(app.any("playback-mode").exists,
                      "the same 📱/☁️ toggle a playlist screen floats", file: file, line: line)
        if menu {
            XCTAssertTrue(app.any("\(prefix)-menu").exists,
                          "…and the ⋯ carrying the context actions", file: file, line: line)
        }
    }

    // ========================================================================
    // MARK: - A tile screen wears the playlist's toolbar
    // ========================================================================

    @MainActor
    func testInDaZoneFloatsTheCollectionToolbar() {
        let app = launchOnForYou()
        let zone = app.el("foryou-tile-zone")
        XCTAssertTrue(zone.waitForExistence(timeout: 20))
        zone.tap()
        assertToolbar(app, "foryou-list")
        shoot(app, "tile-toolbar-in-da-zone")
    }

    /// The ⋯ is the context menu, so it must open and carry something real.
    @MainActor
    func testTheTileMenuCarriesContextActions() {
        let app = launchOnForYou()
        let zone = app.el("foryou-tile-zone")
        XCTAssertTrue(zone.waitForExistence(timeout: 20))
        zone.tap()
        let menu = app.any("foryou-list-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        XCTAssertTrue(app.el("foryou-list-add-all").waitForExistence(timeout: 10),
                      "the ⋯ carries the list-wide actions")
        shoot(app, "tile-overflow-menu")
    }

    /// NEW IS PLAYABLE. Its rows are releases the owner does not own, and streaming them IS the
    /// cloud-mode analogue — so it floats the same live transport, not a status line.
    @MainActor
    func testNewTileFloatsALiveTransport() {
        let app = launchOnForYou()
        let new = app.el("foryou-tile-new")
        XCTAssertTrue(new.waitForExistence(timeout: 20))
        new.tap()
        XCTAssertTrue(app.navigationBars["New"].waitForExistence(timeout: 15))
        // No ⋯ here: every list-wide action New could offer belongs to a row.
        assertToolbar(app, "foryou-new", menu: false)
        XCTAssertTrue(app.any("foryou-new-play").isEnabled,
                      "the seeded out-now releases make ▶ live, not greyed")
        shoot(app, "tile-toolbar-new-playable")
    }

    // ========================================================================
    // MARK: - The playlist screen it copies, and the rows that must stay clean
    // ========================================================================

    #if !os(macOS)
    /// Makes one playlist on the fixture and returns its row.
    @MainActor
    private func launchWithAPlaylist(_ name: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        XCTAssertTrue(app.buttons["new-playlist"].waitForExistence(timeout: 20))
        app.buttons["new-playlist"].tap()
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap(); nameField.typeText(name)
        app.alerts.buttons["Create"].tap()

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        return (app, row)
    }

    /// THE REVERT. A long-press on a collection row manages the list — rename / move / delete —
    /// and offers no transport. Playing it is the detail screen's toolbar's job.
    @MainActor
    func testPlaylistRowMenuCarriesNoTransport() {
        let (app, row) = launchWithAPlaylist("RowMenu")
        row.press(forDuration: 1.2)
        let rename = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'list-rename-'")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "the row menu still manages the list")
        let rowPlay = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'playlist-row-'")).firstMatch
        XCTAssertFalse(rowPlay.exists, "NO row-level play menu — the owner rejected it")
        shoot(app, "playlist-row-menu-management-only")
    }

    /// The reference screen, after the extraction into `CollectionToolbar`: the same items, same
    /// ids, same placement as before — and as the tile screens above. It carries no ▶▶ because its
    /// ▶ already plays the whole playlist from the top; the correction that added Play All was
    /// about the TILES, where ▶ and ▶▶ can genuinely differ.
    @MainActor
    func testPlaylistDetailStillFloatsTheSameToolbar() {
        let (app, row) = launchWithAPlaylist("Toolbar")
        row.tap()
        XCTAssertTrue(app.navigationBars["Toolbar"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.any("playlist-play").waitForExistence(timeout: 10))
        XCTAssertTrue(app.any("playlist-shuffle").exists)
        XCTAssertTrue(app.any("playlist-menu").exists)
        XCTAssertTrue(app.any("playback-mode").exists)
        shoot(app, "playlist-toolbar-reference")
    }
    #endif
}
