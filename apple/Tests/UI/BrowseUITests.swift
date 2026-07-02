import XCTest

/// XCUITests for the Browser. Runs on iPhone, iPad, and Mac (one multiplatform
/// UI-test target) against the bundled fixture catalog (PDJ_USE_FIXTURE), so it's
/// offline and deterministic.
///
/// The Albums/Songs segmented Picker, the window-toolbar buttons, and in-sheet
/// Pickers aren't drivable via XCUITest on macOS, so the browser actions go
/// through the app's keyboard commands there (see XCUIHelpers) and the deeper
/// in-sheet interactions are exercised on iOS, where every control is tappable.
final class BrowseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
    }

    // Terminate between tests so each gets a clean, focused instance — on macOS a
    // lingering prior instance makes the next launch flaky (and steals keystrokes).
    override func tearDown() {
        app?.terminate()
        app = nil
    }

    private func launch() -> XCUIApplication {
        app.launch()
        return app
    }

    func testBrowserLoadsAlbums() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        XCTAssertTrue(app.el("album-alb_2").exists)
    }

    func testAlbumNavigationShowsTrackTable() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))
    }

    #if !os(macOS)
    /// Album detail has Play + Shuffle (like a playlist); ▶ pushes the reusable Now
    /// Playing setlist so the album's tracks start in order.
    func testAlbumPlayAndShuffleButtons() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.el("album-shuffle").waitForExistence(timeout: 5))
        XCTAssertTrue(app.el("album-play").waitForExistence(timeout: 5))
        app.el("album-play").tap()
        // ▶ pushes the Now Playing setlist (autostarting) — its first track row appears.
        XCTAssertTrue(app.buttons["setlist-track-0"].waitForExistence(timeout: 8)
                      || app.otherElements["setlist-detail"].waitForExistence(timeout: 2)
                      || app.staticTexts["setlist-stats"].waitForExistence(timeout: 2))
    }

    /// Song detail shows the album artwork near the top and the bottom play/download
    /// transport (the same ▶/⤓ used in every row, revealing the slide-out player).
    func testSongDetailHasArtworkAndPlaybackTransport() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let track = app.el("track-sng_1")
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 5))
        XCTAssertTrue(app.any("song-detail-art").waitForExistence(timeout: 5))   // art near the top
        // The play/download transport sits at the BOTTOM — scroll it into view first.
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 5))      // bottom ▶
        XCTAssertTrue(app.el("row-download-sng_1").exists)                        // bottom ⤓
        // The third transport button (Stemify, line.3.horizontal) renders alongside — and
        // adding it must NOT clobber the play/download ids (the macOS container-id-propagation
        // bug). All three resolve independently on the same row.
        XCTAssertTrue(app.el("row-stemify-sng_1").exists)                         // bottom ☰ (Stemify)
    }
    #endif

    func testSongDetailFromTrackTable() {
        let app = launch()
        let card = app.el("album-alb_1")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let track = app.el("track-sng_1")        // in-content NavigationLink (works on macOS)
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        XCTAssertTrue(app.el("album-hotlink").waitForExistence(timeout: 5))  // links back to the album
        #if !os(macOS)
        // The Edit button lives in the toolbar (not drivable via XCUITest on macOS).
        XCTAssertTrue(app.el("edit-song").exists)
        app.el("edit-song").tap()
        XCTAssertTrue(app.el("save-edit").waitForExistence(timeout: 5))
        #endif
    }

    func testSwitchToSongsListsTracks() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.selectKind(songs: true)
        // The browser song row no longer wraps the whole row in a single NavigationLink
        // Button (that collapsed the inner transport ▶/⤓ buttons so their taps died — the
        // inline-player bug). The nav link now rides in the row's background and the row's
        // own transport ▶ carries the stable per-song id; assert on that (present for every
        // rendered song row on iPhone, iPad, and Mac).
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 5))   // Neon
        XCTAssertTrue(app.el("row-play-sng_7").exists)                         // Slow Burn
    }

    /// REGRESSION — the "songs stuck on page 1" bug: the on-device paging trigger must
    /// ride the always-rendered SongRow, NOT the InlinePlayerSlot that follows it. The
    /// slot renders nothing unless its song is now-playing, and SwiftUI never fires
    /// `.onAppear` on a no-content view — so the song list never grew past page 1
    /// (albums paged fine; their trigger sits on the always-rendered NavigationLink).
    /// With `PDJ_PAGE_SIZE=3` the 7-song fixture overflows page 1 while still fitting
    /// on one screen, so a WORKING trigger chain-grows the render budget (3 → 6 → 7)
    /// with no scrolling needed: every fixture song's row must eventually render.
    func testSongListGrowsPastFirstPage() {
        app.launchEnvironment["PDJ_PAGE_SIZE"] = "3"
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))
        app.selectKind(songs: true)
        XCTAssertTrue(app.el("row-play-sng_1").waitForExistence(timeout: 5))
        // At most 3 of the 7 songs sit in page 1 — the rest render only if the last
        // rendered row's appearance grew the budget. Assert every row shows up.
        for id in ["sng_2", "sng_3", "sng_4", "sng_5", "sng_6", "sng_7"] {
            XCTAssertTrue(app.el("row-play-\(id)").waitForExistence(timeout: 10),
                          "row \(id) never rendered — song paging didn't grow past page 1")
        }
    }

    func testTappingSongRowOpensDetail() {
        // Real tap-to-navigate: tapping a song ROW's content (the title, NOT a
        // transport button) must open the SongDetailView. Guards the regression where
        // the row's nav rode in a background NavigationLink that never received taps —
        // SongRowView's own .contentShape swallowed them — so the row tap was dead.
        // The fix is a row-level .onTapGesture { path.append(song) } in songResults.
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))
        app.selectKind(songs: true)

        // Tap the song TITLE static text — a non-button part of the row, the way a user
        // taps a row to open it. (Tapping a transport button would PLAY, not navigate.)
        // The title also confirms the songs list has rendered. On macOS the segmented
        // Picker switch goes via ⌘2; the title is the first row's name.
        let title = app.staticTexts["Neon"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), "songs list / first song title never rendered")
        title.tap()

        // The SongDetailView appears — its ScrollView carries the stable `song-detail` id.
        XCTAssertTrue(app.any("song-detail").waitForExistence(timeout: 5),
                      "tapping the song row did not open the song detail")
        // And it shows the song's own metadata (the album hotlink back to its album).
        XCTAssertTrue(app.el("album-hotlink").waitForExistence(timeout: 5))
    }

    func testSongRowPlayButtonDoesNotNavigate() {
        // The row's transport ▶ must stay independently hit-testable AFTER the
        // .onTapGesture change: tapping it PLAYS (stays on the list) and must NOT
        // navigate into the detail. Guards re-breaking the inline player.
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))
        app.selectKind(songs: true)
        XCTAssertTrue(app.staticTexts["Neon"].firstMatch.waitForExistence(timeout: 8),
                      "songs list never rendered")

        // The row ▶ keeps its own `row-play-<id>` id on iPhone, iPad, and Mac — the row
        // uses .accessibilityElement(children: .contain) so the child transport buttons'
        // ids survive instead of being clobbered by the row's own `song-<id>` id.
        let rowPlay = app.el("row-play-sng_1")
        XCTAssertTrue(rowPlay.waitForExistence(timeout: 5), "row ▶ not found")
        rowPlay.tap()

        // We stayed on the browser list — the detail did NOT open. (Give any errant
        // navigation a moment to materialize before asserting its absence.)
        _ = app.any("song-detail").waitForExistence(timeout: 2)
        XCTAssertFalse(app.any("song-detail").exists,
                       "tapping the row ▶ navigated into the detail instead of playing")
        XCTAssertTrue(app.staticTexts["Neon"].firstMatch.exists,
                      "left the browser list — the row ▶ should stay on the list")
    }

    func testLayoutToggleKeepsAlbumsVisible() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.toggleLayout()       // grid ⇄ list
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 3))
    }

    func testFilterSheetOpens() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.openFilter()
        XCTAssertTrue(app.el("add-filter").waitForExistence(timeout: 5))
        #if !os(macOS)
        // In-sheet Pickers + the sheet's toolbar buttons are tappable on iOS.
        app.el("add-filter").tap()
        XCTAssertTrue(app.el("clause-field").waitForExistence(timeout: 3))
        app.el("filter-clear-all").tap()
        XCTAssertFalse(app.el("clause-field").exists)
        app.el("filter-done").tap()
        #endif
    }

    func testSortSheetOpens() {
        let app = launch()
        XCTAssertTrue(app.el("album-alb_1").waitForExistence(timeout: 15))   // album name is a button label on macOS
        app.openSort()
        XCTAssertTrue(app.el("addsort-year").waitForExistence(timeout: 5))
        #if !os(macOS)
        app.el("addsort-year").tap()
        XCTAssertTrue(app.el("sortdir-year").waitForExistence(timeout: 3))
        app.el("sort-clear-all").tap()
        XCTAssertFalse(app.el("sortdir-year").exists)
        app.el("sort-done").tap()
        #endif
    }
}
