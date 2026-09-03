import XCTest

/// The USER'S PATH, end to end: Discover ▸ ＋Add a song you don't own → open it from the
/// on-device Songs list → tap its album → an album PREVIEW with a giant ＋ → tap the ＋ →
/// the whole album lands in the catalog with its metadata.
///
/// Before the fix, this path had TWO dead ends stacked on each other:
///   • a Discover-added song reached the catalog with no album at all — `album-hotlink`
///     didn't render, so there was nothing to tap (repro 2026-08-07); and
///   • the hotlink, where it did render, pushed onto a stack with no destination and
///     painted black.
///
/// Runs against a stub rip server started IN THIS PROCESS (`DiscoverStubServer` — plain HTTP
/// on loopback, which ATS doesn't block, on an OS-assigned port), so it is deterministic,
/// hermetic, and needs no Apple Music subscription. Its URL reaches the app through the
/// `PDJ_RIP_SERVER_URL` launch-environment seam that SettingsStore reads into `ripServerURL`.
/// Setting `PDJ_STUB_URL` on the host overrides it with a server of your own (a real import
/// server, say); nothing needs to be started by hand for a normal run.
final class DiscoverAlbumPreviewUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stub: DiscoverStubServer?

    /// The fixture the stub serves, so the assertions below and the payloads that produce
    /// them cannot drift apart.
    private typealias Fixture = DiscoverStubServer.Fixture

    override func setUpWithError() throws {
        continueAfterFailure = false
        let base: String
        if let external = ProcessInfo.processInfo.environment["PDJ_STUB_URL"], !external.isEmpty {
            base = external
        } else {
            let server = try DiscoverStubServer.start()
            stub = server
            base = server.baseURL
        }
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
        app.launchEnvironment["PDJ_DISABLE_CLOUD_SYNC"] = "1"
        app.launchEnvironment["PDJ_RIP_SERVER_URL"] = base
    }

    override func tearDown() {
        // What the app actually asked the stub for — the difference between "Discover never
        // searched" and "it searched and the row didn't render".
        if let stub, !stub.served.isEmpty {
            let served = XCTAttachment(string: stub.served.joined(separator: "\n"))
            served.name = "stub-requests"
            served.lifetime = .keepAlways
            add(served)
        }
        app?.terminate(); app = nil
        stub?.stop(); stub = nil
    }

    // MARK: helpers

    /// Exists is not enough — the user has to be able to SEE and TAP it.
    private func assertUsable(_ el: XCUIElement, _ what: String, timeout: TimeInterval = 15,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "\(what): never appeared",
                      file: file, line: line)
        XCTAssertTrue(el.isHittable, "\(what): exists but is not hittable (off-screen/covered)",
                      file: file, line: line)
        XCTAssertTrue(app.frame.intersects(el.frame), "\(what): frame is off-screen",
                      file: file, line: line)
    }

    /// Clear whatever is in the search field and type `text`.
    private func retype(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "search field never appeared")
        field.tap()
        if let v = field.value as? String, !v.isEmpty, !v.hasPrefix("Search") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
        }
        field.typeText(text)
    }

    /// Discover ▸ ＋Add "Blue in Green" (the stub's single song hit).
    private func discoverAddTheSong() {
        app.launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 30), "browser never loaded")
        let discover = app.el("Discover")
        XCTAssertTrue(discover.waitForExistence(timeout: 15))
        discover.tap()
        retype("kind of blue")
        XCTAssertTrue(app.any("discover-row-0").waitForExistence(timeout: 30),
                      "no Discover hit rendered — is the stub server up?")
        let add = app.el("discover-add-0")
        assertUsable(add, "Discover ＋ Add")
        add.tap()
        // The row flips to a progress/added state once the add is recorded.
        XCTAssertTrue(app.any("discover-progress-0").waitForExistence(timeout: 30)
                        || app.any("discover-added-0").waitForExistence(timeout: 5),
                      "the ＋ never acknowledged the add")
    }

    /// Leave Discover and open the newly-added song from the on-device Songs list — the
    /// route a real user takes, not a shortcut into the detail view.
    private func openTheAddedSongFromTheCatalog() {
        // "Songs" is AMBIGUOUS: the kind picker's segment is index 0, Discover's scope
        // picker publishes another.
        let kindSongs = app.buttons.matching(identifier: "Songs").element(boundBy: 0)
        XCTAssertTrue(kindSongs.waitForExistence(timeout: 15))
        kindSongs.tap()
        retype(Fixture.trackTitle)
        let title = app.staticTexts[Fixture.trackTitle].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "the added song never appeared in the on-device catalog")
        title.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 15))
    }

    // MARK: the whole path

    func testDiscoverAddedSongLinksToAnAlbumPreviewWithAWorkingPlus() {
        discoverAddTheSong()
        openTheAddedSongFromTheCatalog()

        // 1) The added song now KNOWS its album — this is what didn't exist at all before.
        let hotlink = app.el("album-hotlink")
        assertUsable(hotlink, "album hotlink on a Discover-added song")
        XCTAssertTrue(app.staticTexts[Fixture.albumTitle].firstMatch.exists,
                      "the album's name must be on the detail screen")

        // 2) Tapping it opens the PREVIEW — the screen Levi asked for.
        hotlink.tap()
        XCTAssertTrue(app.any("album-preview").waitForExistence(timeout: 20),
                      "tapping the album must open the album preview, not a blank screen")

        // 3) It is USABLE before you own anything: a giant ＋ and a real track list.
        assertUsable(app.el("album-preview-add"), "the giant ＋")
        XCTAssertTrue(app.any("album-preview-track-0").waitForExistence(timeout: 20),
                      "the preview must show the album's tracks")
        XCTAssertTrue(app.staticTexts[Fixture.otherTrackTitle].firstMatch.exists,
                      "a track the user does NOT own yet must still be listed")

        // 4) The ＋ pulls in the whole album and reports live progress against its tracks —
        //    n/m while the copies are prepared, ⚠ n-of-m if some can't be, ✓ when all are.
        app.el("album-preview-add").tap()
        let progressText = app.staticTexts.containing(NSPredicate(format:
            "label CONTAINS 'Adding' OR label CONTAINS 'ready' OR label CONTAINS 'In your library'"))
            .firstMatch
        XCTAssertTrue(progressText.waitForExistence(timeout: 30),
                      "the ＋ must turn into live n/m progress, not just sit there")
        XCTAssertTrue(app.frame.intersects(progressText.frame), "progress must be on screen")

        // 5) …and the album is now a browsable catalog citizen with its metadata.
        XCTAssertTrue(app.el("album-preview-open").waitForExistence(timeout: 30),
                      "once added, the preview must offer to open the real album")
        app.el("album-preview-open").tap()
        XCTAssertTrue(app.any("album-detail").waitForExistence(timeout: 20),
                      "the added album must open as a real album")
        XCTAssertTrue(app.staticTexts[Fixture.albumTitle].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[String(Fixture.year)].firstMatch.exists,
                      "the album must carry its year — 'fully populate the metadata'")
    }

    /// The other reading of Levi's report: the album name printed on the Discover ROW
    /// ("Miles Davis · Kind of Blue") should itself be tappable. It is — straight to the
    /// same preview, before you've added anything at all.
    func testDiscoverRowAlbumNameOpensThePreviewBeforeAnyAdd() {
        app.launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 30))
        app.el("Discover").tap()
        retype("kind of blue")
        XCTAssertTrue(app.any("discover-row-0").waitForExistence(timeout: 30),
                      "no Discover hit rendered — is the stub server up?")

        let link = app.el("discover-album-link-0")
        assertUsable(link, "the album name on a Discover row")
        link.tap()

        XCTAssertTrue(app.any("album-preview").waitForExistence(timeout: 20),
                      "the row's album name must open the preview")
        assertUsable(app.el("album-preview-add"), "the giant ＋")
        XCTAssertTrue(app.any("album-preview-track-0").waitForExistence(timeout: 20),
                      "the preview must list the album's tracks")
    }

    /// A track of an album added in ALBUM scope must link BACK to that album — the add had
    /// the album id in hand and dropped it, so the track's detail had no album either.
    func testAlbumScopeAddGivesEveryTrackItsAlbum() {
        app.launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 30))
        app.el("Discover").tap()
        // "Albums" is ambiguous too: [0] is the kind picker (hidden here), the LAST match is
        // Discover's own Songs/Albums scope.
        let albumMatches = app.buttons.matching(identifier: "Albums")
        let scope = albumMatches.element(boundBy: max(albumMatches.count - 1, 0))
        XCTAssertTrue(scope.waitForExistence(timeout: 15))
        scope.tap()
        retype("kind of blue")
        XCTAssertTrue(app.any("discover-album-row-0").waitForExistence(timeout: 30),
                      "no Discover ALBUM hit rendered — is the stub server up?")
        let add = app.el("discover-album-add-0")
        assertUsable(add, "Discover album ＋ Add")
        add.tap()

        // Back to the on-device catalog: the provisional album is browsable…
        app.buttons.matching(identifier: "Albums").element(boundBy: 0).tap()
        retype(Fixture.albumTitle)
        let card = app.el("album-\(Fixture.albumId)")        // album-amrec_album_268443788
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the added album never reached the catalog")
        card.tap()

        // …and opening one of its tracks gives a hotlink back to the album we just added.
        let track = app.el("track-\(Fixture.trackSongId)")   // track-amrec_1440857781
        XCTAssertTrue(track.waitForExistence(timeout: 20), "the album's tracks must be listed")
        track.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 15))
        let hotlink = app.el("album-hotlink")
        assertUsable(hotlink, "album hotlink on a track of the album just added")
        hotlink.tap()
        XCTAssertTrue(app.any("album-detail").waitForExistence(timeout: 15),
                      "a track of an added album must link back to that album")
        XCTAssertTrue(app.staticTexts[Fixture.albumTitle].firstMatch.waitForExistence(timeout: 10))
    }
}
