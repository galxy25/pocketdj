import XCTest

/// For You ▸ New — albums vs singles (docs/design/foryou-new-kind-filter.md). One test per user
/// story. `PDJ_NEW_KIND` sets the mode at launch (fixture mode only) so a test that leaves "Albums
/// only" behind can't leak it into the next; `PDJ_NEW_FIXTURE_KINDS=1` adds a newer single
/// (900005) and a mislabelled 1-track "album" (900006) to the default fixture
/// (900001 album, 900002 single, 900003 EP pre-order, liked 9000000004 album).
final class ForYouNewKindUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(kind: String? = nil, kindsFixture: Bool = false, multiFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_REC_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        if let kind { app.launchEnvironment["PDJ_NEW_KIND"] = kind }
        if kindsFixture { app.launchEnvironment["PDJ_NEW_FIXTURE_KINDS"] = "1" }
        if multiFixture { app.launchEnvironment["PDJ_NEW_FIXTURE_MULTI"] = "1" }
        app.launch()
        let tab = app.el("history-tab-for-you")
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        return app
    }

    private func openNew(_ app: XCUIApplication) {
        let new = app.el("foryou-tile-new")
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        XCTAssertTrue(app.navigationBars["New"].waitForExistence(timeout: 10))
    }

    /// Rows are keyed by RELEASE id. The fixture's artist 900_00N ships release 900000000N.
    private func row(_ app: XCUIApplication, _ artistId: Int) -> XCUIElement {
        app.el("new-release-\(artistId - 900_000 + 9_000_000_000)")
    }
    private func release(_ app: XCUIApplication, _ releaseId: String) -> XCUIElement {
        app.el("new-release-\(releaseId)")
    }
    private func gone(_ e: XCUIElement, _ msg: String) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        waitForExpectations(timeout: 10)
    }

    private func pick(_ app: XCUIApplication, _ mode: String) {
        // The toolbar ⋯ from `collectionToolbar(idPrefix: "foryou-new")`.
        let more = app.any("foryou-new-menu")
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let item = app.any("foryou-new-kind-\(mode)")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Show menu offers \(mode)")
        item.tap()
    }

    /// US1 — Levi: only albums.
    @MainActor
    func testAlbumsOnlyHidesSinglesAndCanShowAllAgain() {
        let app = launch(kindsFixture: true)
        openNew(app)
        XCTAssertTrue(row(app, 900_002).waitForExistence(timeout: 10), "Everything shows the single")
        XCTAssertTrue(row(app, 900_005).exists)

        pick(app, "albums")
        XCTAssertTrue(row(app, 900_001).waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, 900_003).exists, "an EP counts as an album")
        gone(row(app, 900_002), "single hidden")
        XCTAssertFalse(row(app, 900_005).exists, "'Fresh Cut - Single' hidden")
        XCTAssertFalse(row(app, 900_006).exists, "the 1-track 'album' is really a single")
        XCTAssertEqual(app.any("new-kind-hidden-footer").value as? String, "3")
        XCTAssertTrue(app.el("foryou-new-play").isEnabled, "an album is out now")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.el("foryou-tile-new").label.contains("Albums"), "the tile says Albums")
        openNew(app)
        let showAll = app.el("new-kind-show-all")
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        showAll.tap()
        XCTAssertTrue(row(app, 900_002).waitForExistence(timeout: 5), "Show all brings the single back")
        gone(app.any("new-kind-hidden-footer"), "footer gone")
    }

    /// The bug this round fixes: an album followed by a NEWER single from the same artist. Under
    /// "Albums only" the album must still be there (the feed used to keep one release per artist).
    @MainActor
    func testAlbumsOnlyKeepsAnAlbumBehindANewerSingle() {
        let app = launch(multiFixture: true)
        openNew(app)
        let single = release(app, "9000000007"), album = release(app, "9000000001")
        XCTAssertTrue(single.waitForExistence(timeout: 10))
        XCTAssertTrue(album.exists)
        XCTAssertLessThan(single.frame.minY, album.frame.minY, "newer single sits above its album")

        pick(app, "albums")
        XCTAssertTrue(album.waitForExistence(timeout: 5), "the album survives a newer single")
        gone(single, "the single is hidden")
        XCTAssertEqual(app.any("new-kind-hidden-footer").value as? String, "2", "900002 + the new single")
        XCTAssertFalse(app.any("new-kind-hidden-caveat").exists, "the caveat is gone")
    }

    /// US2 — only singles; and an honest empty state when none are left.
    @MainActor
    func testSinglesOnlyShowsSinglesAndExplainsWhenNoneAreLeft() {
        let app = launch(kind: "singles")
        openNew(app)
        XCTAssertTrue(row(app, 900_002).waitForExistence(timeout: 10))
        XCTAssertFalse(row(app, 900_001).exists)
        XCTAssertFalse(row(app, 900_003).exists)
        XCTAssertFalse(app.el("new-liked-row-9000000004").exists)
        XCTAssertFalse(app.any("new-release-section-comingSoon").exists)
        XCTAssertEqual(app.any("new-kind-hidden-footer").value as? String, "3", "album + EP + liked album")

        let thumb = app.el("rec-accept-rel:9000000002")
        XCTAssertTrue(thumb.waitForExistence(timeout: 5))
        thumb.tap()
        let empty = app.any("new-kind-empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(empty.value as? String, "No new singles")
        app.el("new-kind-show-all").tap()
        XCTAssertTrue(row(app, 900_001).waitForExistence(timeout: 5))
    }

    /// US3 — albums first, then singles.
    @MainActor
    func testAlbumsFirstPutsEveryAlbumAboveEverySingle() {
        let app = launch(kind: "albumsFirst", kindsFixture: true)
        openNew(app)
        XCTAssertTrue(app.any("new-release-group-albums-outNow").waitForExistence(timeout: 10))
        let singlesHeader = app.any("new-release-group-singles-outNow")
        XCTAssertTrue(singlesHeader.exists)
        let ys = [row(app, 900_001).frame.minY, singlesHeader.frame.minY, row(app, 900_005).frame.minY,
                  row(app, 900_006).frame.minY, row(app, 900_002).frame.minY]
        XCTAssertEqual(ys, ys.sorted(), "album < Singles header < 900005 < 900006 < 900002, got \(ys)")
        XCTAssertFalse(app.any("new-kind-hidden-footer").exists, "albumsFirst hides nothing")
    }
}
