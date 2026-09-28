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
}
