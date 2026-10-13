import XCTest
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// App Store screenshot driver — NOT a test of behavior. Launches against the bundled
/// `screenshot-index` fixture (a clearly-invented sample catalog: made-up artists and albums,
/// so nothing personal and no third-party artwork appears in the listing) and walks the
/// screens worth marketing, attaching a full-resolution screenshot of each. Run it on the
/// exact simulators whose sizes App Store Connect requires (iPhone 6.9", iPad 13") and pull
/// the PNGs out of the .xcresult.
///
/// EVERY SHOT IS POPULATED ON PURPOSE. The first version of this driver only set
/// `PDJ_START_SECTION` and shot whatever was there, which meant the three screens the listing
/// most needs to sell — Mix, Producer, Now Playing — shipped as an idle deck, an empty sample
/// list and a dead platter. Each capture now composes the app's own `showcase` seeding seams:
///
/// * `PDJ_SEED_BURNS=showcase`          — full-length, song-shaped audio bodies for the catalog
///                                        ids the decks load (a deck's duration and waveform come
///                                        from the FILE, so a 2 s tone reads "0:00 / 0:02").
/// * `PDJ_SEED_MIX_DECK_SESSION=showcase` — a real two-deck transition, restored through the
///                                        durable-session path the app ships.
/// * `PDJ_SEED_PLAYBACK_SESSION=showcase` — a real set parked mid-track with played + up-next rows.
/// * `PDJ_SEED_STUDIO=showcase`         — a five-lane 16-step groove, plus `PDJ_STUDIO_TAB` /
///                                        `PDJ_STUDIO_OPEN_PATTERN` to land on the step grid.
/// * `PDJ_SEED_COLLECTIONS=showcase`    — four real crates (the `=1` seam makes ONE one-song
///                                        playlist, which is the empty listing this replaces).
/// * `PDJ_NP_EXPANDED=1`                — raises the full-bleed Now Playing deck (on iPhone the
///                                        selected section otherwise covers the sidebar deck).
///
/// The Mix and Now Playing passes then press the app's OWN transport, so the meters, spinning
/// record and progress sweep in those two shots are genuine playback of the seeded bodies rather
/// than faked view state.
final class AppStoreScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Deck arrangement per device. `sideBySide` shows both decks AND the crossfader — the board
    /// shot — but only an iPad's 13" canvas actually fits it: forced onto a phone it clips both
    /// decks horizontally ("Deck A" renders as "k A" and the Stop button falls off the edge).
    /// A phone therefore shoots the stacked board, which fills the frame with one complete deck.
    private var deckLayout: String {
        #if canImport(UIKit) && !os(macOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "sideBySide" : "stacked"
        #else
        return "sideBySide"
        #endif
    }

    private func launch(section: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_FIXTURE_RESOURCE"] = "screenshot-index"
        app.launchEnvironment["PDJ_START_SECTION"] = section
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Wait for a specific piece of SEEDED CONTENT, not for chrome. The old driver waited on
    /// `mix-auto-mode`, a toolbar toggle that exists in every state including a blank board — so a
    /// regression to an empty deck would still have captured and uploaded silently.
    @discardableResult
    private func expect(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 30) -> Bool {
        let ok = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(ok, "screenshot precondition missing: \(what) — the shot would be empty")
        return ok
    }

    func testCaptureMarketingScreens() {
        // ── 1 — MIX: two decks mid-transition, Auto-DJ live, real meters.
        var app = launch(section: "Mix", extra: [
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_MIX_DECK_SESSION": "showcase",
            "PDJ_MIX_DECK_LAYOUT": deckLayout,
        ])
        // Deck A's restored title proves the snapshot materialized (metadata renders from the
        // snapshot, the audio body from the seeded burn).
        expect(app.staticTexts["Elevator to the Moon"], "Mix deck A track")
        // The restore deliberately comes up SUSPENDED (autoPaused) — that is the app's real
        // kill-and-relaunch behavior. Resume so the banner reads "Auto-mixing" and the VU meters
        // and waveform playhead are live for the capture.
        let resume = app.buttons["mix-auto-resume"]
        if resume.waitForExistence(timeout: 5), resume.isHittable { resume.tap() }
        sleep(4)   // let audio start, meters settle, waveform playhead advance off 0
        shot(app, "screen-01-mix")

        // ── 2 — NOW PLAYING: full-bleed deck, playing mid-track, played + up-next populated.
        app.terminate()
        app = launch(section: "History", extra: [
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_PLAYBACK_SESSION": "showcase",
            "PDJ_NP_EXPANDED": "1",
            "PDJ_SEED_COLLECTIONS": "showcase",
        ])
        expect(app.staticTexts["Golden Hour"], "Now Playing current track")
        // The restored set is HELD at its stored position; pressing the app's own ⏯ resumes into
        // genuine playback of the seeded body, which is what spins the record and sweeps the
        // tonearm (a held deck renders a frozen platter at 0:00).
        let playPause = app.buttons["np-playpause"]
        if playPause.waitForExistence(timeout: 5), playPause.isHittable { playPause.tap() }
        sleep(4)
        shot(app, "screen-02-nowplaying")

        // ── 3 — PRODUCER: the 16-step grid with a five-lane groove programmed.
        app.terminate()
        app = launch(section: "Performance", extra: [
            "PDJ_SEED_STUDIO": "showcase",
            "PDJ_STUDIO_TAB": "sequencer",
            "PDJ_STUDIO_OPEN_PATTERN": "ptn_showcase",
        ])
        expect(app.staticTexts["Rooftop"], "Producer showcase pattern")
        sleep(3)
        shot(app, "screen-03-studio")

        // ── 4 — BROWSE: the catalog as the SONGS list, not the album grid. The invented fixture
        // albums deliberately carry no artwork (nothing third-party may appear in the listing), so
        // the grid shoots as four grey placeholder discs — which misrepresents the app as artless.
        // The songs list is denser and puts the per-track BPM and Camelot key on screen, which is
        // the metadata the mixing features actually run on.
        app.terminate()
        app = launch(section: "Browser", extra: [
            "PDJ_SEED_COLLECTIONS": "showcase",
            "PDJ_SEED_HISTORY": "fixture",
        ])
        expect(app.staticTexts["Night Drive"], "Browse first album")
        let songsTab = app.buttons["Songs"].firstMatch
        if songsTab.waitForExistence(timeout: 5), songsTab.isHittable { songsTab.tap() }
        sleep(4)   // let the fixture catalog build + rows settle
        shot(app, "screen-04-browse")

        // ── 5 — COLLECTIONS: playlists and pockets.
        app.terminate()
        app = launch(section: "Playlists", extra: [
            "PDJ_SEED_COLLECTIONS": "showcase",
            "PDJ_SEED_ACTIVITY": "1",
        ])
        expect(app.staticTexts["Friday Night Warmup"], "showcase playlist")
        sleep(3)
        shot(app, "screen-05-playlists")

        app.terminate()
    }

    // MARK: - pocket-dj.com tour (www/) — NOT part of the App Store upload

    /// The Producer carousel on pocket-dj.com: one populated shot per Studio sub-tab the
    /// website's Producer bullets name. Same seeds as the listing's Producer shot, landed on
    /// each tab via `PDJ_STUDIO_TAB`.
    func testCaptureWebsiteProducerTour() {
        let base: [String: String] = [
            "PDJ_SEED_STUDIO": "showcase",
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_DEMUX": "showcase",
        ]
        for tab in ["samples", "instruments", "demuxer", "tracks"] {
            var env = base
            env["PDJ_STUDIO_TAB"] = tab
            let app = launch(section: "Performance", extra: env)
            sleep(5)
            if tab == "demuxer" {
                if !app.any("demux-file-row-dmx_fixture").waitForExistence(timeout: 3) {
                    let group = app.any("demux-group-imported")
                    if group.waitForExistence(timeout: 5) { group.tap() }
                }
                let row = app.any("demux-file-row-dmx_fixture")
                if row.waitForExistence(timeout: 10) {
                    row.tap()
                    _ = app.any("demux-timeline").waitForExistence(timeout: 20)
                    sleep(3)
                }
            }
            if tab == "tracks" {
                let row = app.any("tracks-arr-row-arr_showcase")
                expect(row, "showcase arrangement listed")
                row.tap()
                _ = app.any("tracks-play").waitForExistence(timeout: 10)
                sleep(2)
                // Zoom out to fit so the whole 32-second build (every lane's clips) is on screen.
                let zoomOut = app.buttons["tracks-zoom-out"]
                for _ in 0..<8 where zoomOut.exists && zoomOut.isEnabled { zoomOut.tap(); usleep(400_000) }
                sleep(2)
            }
            shot(app, "www-producer-\(tab)")
            app.terminate()
        }
    }

    /// The Games carousel on pocket-dj.com: the Games home (cards + scoreboard), a live
    /// Collectors Puzzle round, and an In the Pocket round.
    func testCaptureWebsiteGamesTour() {
        let env: [String: String] = [
            "PDJ_SEED_GAMES": "1",
            "PDJ_SEED_COLLECTIONS": "showcase",
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_HISTORY": "fixture",
        ]
        var app = launch(section: "Games", extra: env)
        expect(app.any("games-card-puzzle"), "Games home")
        sleep(3)
        shot(app, "www-games-home")

        app.any("games-card-puzzle").tap()
        _ = app.any("puzzle-round-length").waitForExistence(timeout: 10)
        sleep(2)
        shot(app, "www-games-puzzle-setup")
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "puzzle-target-")).firstMatch
        if app.swipeTo(target) {
            for _ in 0..<6 where target.frame.maxY > app.el("puzzle-start").frame.minY { app.swipeUp() }
            target.tap()
        }
        let start = app.el("puzzle-start")
        let deadline = Date().addingTimeInterval(15)
        while !start.isEnabled && Date() < deadline { usleep(300_000) }
        if start.isEnabled { start.tap() }
        if app.el("puzzle-assign-0").waitForExistence(timeout: 15) {
            sleep(4)
            app.el("puzzle-assign-0").tap()
            sleep(3)
        }
        shot(app, "www-games-puzzle-round")
        app.terminate()

        // Listening pockets via the canned-results fixture seam (zero network) so the game is
        // enabled; the round builds on-device from the seeded history.
        var itpEnv = env
        itpEnv["PDJ_POCKETS_FIXTURE"] = "1"
        app = launch(section: "Games", extra: itpEnv)
        expect(app.any("games-card-inthepocket"), "In the Pocket card")
        app.any("games-card-inthepocket").tap()
        _ = app.any("itp-screen").waitForExistence(timeout: 10)
        sleep(2)
        shot(app, "www-games-itp-1")
        let build = app.any("itp-build")
        if build.waitForExistence(timeout: 5), build.isHittable { build.tap() }
        _ = app.any("itp-song-0").waitForExistence(timeout: 20)
        sleep(2)
        shot(app, "www-games-itp-2")
        let startItp = app.any("itp-start")
        if startItp.waitForExistence(timeout: 5), startItp.isHittable { startItp.tap(); sleep(4) }
        shot(app, "www-games-itp-3")
        app.terminate()
    }

    /// The Mix hero on pocket-dj.com: an iPad in LANDSCAPE so both decks, every control and the
    /// crossfader read as one board. iPad only (a phone can't fit `sideBySide`).
    func testCaptureWebsiteIPadMixLandscape() throws {
        #if canImport(UIKit) && !os(macOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(section: "Mix", extra: [
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_MIX_DECK_SESSION": "showcase",
            "PDJ_MIX_DECK_LAYOUT": "sideBySide",
        ])
        XCUIDevice.shared.orientation = .landscapeLeft
        expect(app.staticTexts["Elevator to the Moon"], "Mix deck A track")
        sleep(3)   // let the rotation settle before any tap (coordinates follow the new frame)
        let resume = app.buttons["mix-auto-resume"]
        if resume.waitForExistence(timeout: 5), resume.isHittable { resume.tap() }
        sleep(2)
        // Landscape is short: nudge the board up so the crossfader clears the bottom edge.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.965, dy: 0.80))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.965, dy: 0.66)))
        sleep(4)
        // `app.screenshot()` composites in PORTRAIT space after a rotation (the board comes out
        // clipped under a black band); the screen capture is orientation-correct.
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = "www-ipad-mix-landscape"
        att.lifetime = .keepAlways
        add(att)
        app.terminate()
        #else
        throw XCTSkip("iPad only")
        #endif
    }
}
