import XCTest

/// THE regression that would have caught the blank screen.
///
/// `BrowseUITests` asserted only that `album-hotlink` EXISTS; nothing in the suite had ever
/// TAPPED it. It turned out to push nothing at all: the hotlink dismissed, parked an
/// `IntentRoute`, and RootView re-rooted the stack and staged the append 450 ms later — the
/// push was lost and the user landed on a real stack entry containing no view. Reproduced
/// 2026-08-07 on a plain fixture catalog song ("Neon"), sampled black.
///
/// So every test here TAPS the link and asserts the DESTINATION rendered — plus a pixel
/// sample, because "the pushed screen is blank" passes every existence assertion nobody
/// wrote. Both hotlinks, from the songs list AND from the Now Playing panel's sheet (a
/// different stack, which is where the old routing was least reliable).
final class AlbumHotlinkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Browser"
        app.launchEnvironment["PDJ_DISABLE_CLOUD_SYNC"] = "1"
    }

    override func tearDown() { app?.terminate(); app = nil }

    // MARK: helpers

    /// A control is only real to the user when it is on-screen AND hit-testable. `exists`
    /// alone is satisfied by an off-screen or covered element, which is how a control the
    /// user can't reach still passes a test.
    private func assertUsable(_ el: XCUIElement, _ what: String,
                              timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "\(what): never appeared",
                      file: file, line: line)
        XCTAssertTrue(el.isHittable, "\(what): exists but is not hittable (off-screen/covered)",
                      file: file, line: line)
        let frame = el.frame
        XCTAssertFalse(frame.isEmpty, "\(what): zero-sized frame", file: file, line: line)
        let screen = app.frame
        XCTAssertTrue(screen.intersects(frame), "\(what): frame \(frame) is off-screen \(screen)",
                      file: file, line: line)
    }

    /// The cheap, non-fooling blank-screen assertion. A real PocketDJ screen paints
    /// `Theme.bg` (0x0b0f1a); a pushed stack entry with no registered destination paints
    /// pure black. Sampling the rendered pixels catches "the screen is empty" even when
    /// every identifier assertion someone remembered to write happens to pass.
    private func assertNotBlank(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        #if os(iOS)
        let shot = XCUIScreen.main.screenshot()
        guard let cg = shot.image.cgImage else { return }   // no image ⇒ nothing to claim
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return }
        var colored = 0
        // Sample a coarse grid over the CONTENT area (skip the status bar and the very
        // bottom, which are chrome on every screen).
        let xs = stride(from: w / 6, to: w, by: max(w / 6, 1))
        let ys = stride(from: h / 5, to: (h * 4) / 5, by: max(h / 10, 1))
        for x in xs {
            for y in ys where Self.isPainted(cg, x: x, y: y) { colored += 1 }
        }
        XCTAssertGreaterThan(colored, 0,
                             "\(what): every sampled pixel was pure black — the pushed screen rendered nothing",
                             file: file, line: line)
        #endif
    }

    #if os(iOS)
    /// True when the pixel is anything other than pure black. `Theme.bg` (11,15,26) counts;
    /// (0,0,0) — what a destination-less push paints — does not.
    private static func isPainted(_ cg: CGImage, x: Int, y: Int) -> Bool {
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return true }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        let offset = y * bpr + x * bpp
        guard offset + 2 < CFDataGetLength(data) else { return true }
        return ptr[offset] != 0 || ptr[offset + 1] != 0 || ptr[offset + 2] != 0
    }
    #endif

    private func openNeonFromSongsList() {
        app.launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 30), "browser never loaded")
        // "Songs" is AMBIGUOUS — the kind picker's segment is index 0, the Discover scope
        // picker also publishes one. Take the kind picker's.
        let kindSongs = app.buttons.matching(identifier: "Songs").element(boundBy: 0)
        XCTAssertTrue(kindSongs.waitForExistence(timeout: 10))
        kindSongs.tap()
        let title = app.staticTexts["Neon"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "songs list never rendered")
        title.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 10),
                      "tapping the song row did not open the song detail")
    }

    // MARK: the user's exact path — songs list ▸ song ▸ album

    /// Levi's report, minus the Discover half: open a song whose album has NOT been on this
    /// stack, tap the album, and land on the ALBUM — not on black.
    func testAlbumHotlinkFromSongsListOpensAlbumDetail() {
        openNeonFromSongsList()

        let hotlink = app.el("album-hotlink")
        assertUsable(hotlink, "album hotlink on the song detail")
        hotlink.tap()

        // The DESTINATION must be there. `album-detail` alone could be a coincidence, so
        // assert the album's own controls and its track count too.
        XCTAssertTrue(app.any("album-detail").waitForExistence(timeout: 10),
                      "tapping the album hotlink must open the album — this is the blank-screen bug")
        assertUsable(app.el("album-play"), "album Play button")
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5),
                      "the album's real track table must be on screen")
        assertNotBlank("album detail after the hotlink tap")
    }

    /// The artist hotlink blanked from EVERY entry point, including one where the album
    /// hotlink worked — same routing, same fix.
    func testArtistHotlinkFromSongsListOpensArtistDetail() {
        openNeonFromSongsList()

        let hotlink = app.el("artist-hotlink")
        assertUsable(hotlink, "artist hotlink on the song detail")
        hotlink.tap()

        assertUsable(app.el("artist-play-all"), "artist Play-all button")
        assertNotBlank("artist detail after the hotlink tap")
    }

    /// The SAME two links from inside the album (the one path that always worked) must keep
    /// working — the fix replaced the routing mechanism, so this is the no-regression half.
    func testAlbumHotlinkFromInsideTheAlbumStillReturnsToIt() {
        app.launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        let track = app.el("track-sng_1")
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 10))

        let hotlink = app.el("album-hotlink")
        assertUsable(hotlink, "album hotlink")
        hotlink.tap()
        XCTAssertTrue(app.any("album-detail").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))
        assertNotBlank("album detail pushed from a song opened inside that album")
    }

    // MARK: the SHEET presentation (a different stack — where routing was worst)

    #if !os(macOS)
    /// The Now Playing panel presents the song detail in its OWN sheet stack. That stack used
    /// to register no destinations at all, so the hotlinks had to dismiss the sheet and route
    /// across stacks. It now carries its own path + destinations and pushes in place.
    ///
    /// Drives the same seeded, held-playback path `NowPlayingUITests` uses (fixture songs have
    /// no audio, so `PDJ_HOLD_PLAYBACK` keeps the sequencer running without playing).
    func testAlbumHotlinkInsideTheNowPlayingSheetPushesInPlace() {
        app.launchEnvironment["PDJ_SEED_COLLECTIONS"] = "1"
        app.launchEnvironment["PDJ_HOLD_PLAYBACK"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Playlists"
        app.launch()

        // Start the seeded playlist (sng_1 "Neon" by Aria) so the deck has a record.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'playlist-pls_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "seeded playlist never rendered")
        row.tap()
        XCTAssertTrue(app.el("playlist-play").waitForExistence(timeout: 15))
        app.el("playlist-play").tap()

        // Pop back to the home menu, where the panel lives.
        let panel = app.any("now-playing-panel")
        for _ in 0..<5 where !panel.exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "Now Playing panel never appeared")

        // Long-press the record → its context menu → "Song details" opens the SHEET
        // (whose Back/✕ is sheet-only chrome, distinguishing it from the pushed detail).
        let record = app.any("np-record")
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.press(forDuration: 1.0)
        let details = app.buttons["Song details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10),
                      "the record's context menu should offer Song details")
        details.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 15),
                      "Song details should open the song-detail sheet")
        let back = app.el("np-detail-back")
        let closer = back.waitForExistence(timeout: 2) ? back : app.el("np-detail-close")
        XCTAssertTrue(closer.exists, "this must be the SHEET presentation, not the pushed detail")

        let hotlink = app.el("album-hotlink")
        assertUsable(hotlink, "album hotlink inside the Now Playing sheet")
        hotlink.tap()

        XCTAssertTrue(app.any("album-detail").waitForExistence(timeout: 10),
                      "the sheet's own stack must push the album, not blank")
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))
        assertNotBlank("album detail pushed inside the Now Playing sheet")
    }
    #endif
}
