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
        openNew(app)
        assertToolbar(app, "foryou-new")
        XCTAssertTrue(app.any("foryou-new-play").isEnabled,
                      "the seeded out-now releases make ▶ live, not greyed")
        shoot(app, "tile-toolbar-new-playable")
    }

    /// New's ⋯ is a real menu with a real action in it — "check for new releases now", which the
    /// feed's play-driven lazy trigger otherwise gives no way to ask for.
    @MainActor
    func testNewTileMenuCarriesARealAction() {
        let app = launchOnForYou()
        openNew(app)
        let menu = app.any("foryou-new-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        XCTAssertTrue(app.el("foryou-new-recheck").waitForExistence(timeout: 10),
                      "the ⋯ carries a list-wide action, not an empty sheet of furniture")
        shoot(app, "new-overflow-menu")
    }

    /// **THE DEFECT THIS ROUND FIXED, driven end to end.**
    ///
    /// New's whole transport was enabled on `!outNow.isEmpty` (every out-now release) while ▶
    /// played only the LIVE half. Thumb down every release and ▶ stayed lit over a queue its own
    /// `guard !ids.isEmpty` would refuse — a decoy control. ▶▶ Play All is the one that must stay
    /// live there, because playing the thumbed-down tail is exactly what it is for.
    ///
    /// The PRECONDITION is asserted, not assumed: an earlier review of this screen "reproduced"
    /// the bug against taps that had never landed. The reject's own accessibility label flipping to
    /// "Undo not for me" is the proof that the verdict was recorded AND that the screen redrew —
    /// which it only does because `RecFeedbackStore.derived` is observed (see
    /// `testEveryDerivedReadRegistersAnObservationDependency`).
    @MainActor
    func testThumbingDownEveryReleaseGreysPlayButLeavesPlayAllLive() {
        let app = launchOnForYou()
        openNew(app)
        XCTAssertTrue(app.any("foryou-new-play").waitForExistence(timeout: 15))
        XCTAssertTrue(app.any("foryou-new-play").isEnabled, "starts live — two out-now releases")

        // The fixture's two out-now releases (`ReleaseFeedService.uiFixtureEntries`), by the id a
        // verdict on a RELEASE is filed under (`rel:<albumId>`).
        for releaseId in ["rel:9000000001", "rel:9000000002"] {
            let reject = app.el("rec-reject-\(releaseId)")
            XCTAssertTrue(reject.waitForExistence(timeout: 10), "\(releaseId) is on screen")
            reject.tap()
            expectation(for: NSPredicate(format: "label == %@", "Undo not for me"),
                        evaluatedWith: reject)
            waitForExpectations(timeout: 8) { err in
                XCTAssertNil(err, "the 👎 must LAND and the row must redraw — \(releaseId)")
            }
        }

        expectation(for: NSPredicate(format: "enabled == false"),
                    evaluatedWith: app.any("foryou-new-play"))
        waitForExpectations(timeout: 8) { err in
            XCTAssertNil(err, "▶ must grey out: every release is thumbed down, so its queue is empty")
        }
        XCTAssertFalse(app.any("foryou-new-shuffle").isEnabled, "🔀 plays the same live list as ▶")
        XCTAssertTrue(app.any("foryou-new-play-all").isEnabled,
                      "▶▶ stays live — the thumbed-down tail is precisely what Play All plays")
        shoot(app, "new-toolbar-all-thumbed-down")
    }

    @MainActor
    private func openNew(_ app: XCUIApplication) {
        let new = app.el("foryou-tile-new")
        XCTAssertTrue(new.waitForExistence(timeout: 20))
        new.tap()
        XCTAssertTrue(app.navigationBars["New"].waitForExistence(timeout: 15))
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
    /// ids, same placement — and now the same COUNT as the tile screens. Owner, verbatim: *"always
    /// show play and play all and shuffle."* A playlist has no thumbed-down tail, so its ▶▶ is the
    /// same act as its ▶; rendering it anyway is what keeps the transport from changing shape
    /// between two screens that are meant to be one piece of furniture.
    @MainActor
    func testPlaylistDetailStillFloatsTheSameToolbar() {
        let (app, row) = launchWithAPlaylist("Toolbar")
        row.tap()
        XCTAssertTrue(app.navigationBars["Toolbar"].waitForExistence(timeout: 10))
        assertToolbar(app, "playlist")
        shoot(app, "playlist-toolbar-reference")
    }
    #endif
}
