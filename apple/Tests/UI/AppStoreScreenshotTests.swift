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

    private var isPad: Bool {
        #if canImport(UIKit) && !os(macOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
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

    /// Shot 2 — REMOTE: a live Backseat session (`PDJ_SEED_REMOTE=showcase` — an in-memory
    /// loopback "Car" speaker), with participants, now playing and Up Next populated. Remote
    /// lives in the Jukebox panel (`JukeboxHubView`); `PDJ_START_SECTION=Remote` lands on it
    /// with the Remote half of the "Jukebox Hero | Remote" switch selected, and the shot keeps
    /// that switch in frame so the listing shows where Remote lives.
    @discardableResult
    private func captureRemote() -> XCUIApplication {
        let app = launch(section: "Remote", extra: [
            "PDJ_SEED_REMOTE": "showcase",
            "PDJ_SEED_BURNS": "showcase",
        ])
        expect(app.descendants(matching: .any)["remote-now-playing"], "Remote now playing row")
        let modeSwitch = app.descendants(matching: .any)["jukebox-panel-mode"].firstMatch
        expect(modeSwitch, "Jukebox Hero | Remote switch")
        sleep(2)
        // The Session/Mix Together rows lead the list; on a phone they push Now Playing to the
        // bottom edge and Up Next off screen. The switch sits ABOVE the list (it doesn't
        // scroll), so scroll the list (slow drag + hold, so no fling) until Participants sits
        // just under the switch: switch, roles, now playing, transport and Up Next in frame.
        let peer = app.descendants(matching: .any)["remote-peer-A-host"]
        let win = app.windows.firstMatch.frame
        // Participants' HEADER lands just under the switch (its first row starts ~27 pt below
        // the header text, the Mix Together footer ends ~48 pt above it), so the footer is fully
        // scrolled out — never half-cut under the switch.
        let floor = modeSwitch.exists ? modeSwitch.frame.maxY + 40 : win.height * 0.16
        // Re-measure after each drag: the first drag can be eaten by the large title collapsing.
        for _ in 0..<6 where !isPad && peer.exists && abs(peer.frame.minY - floor) > 6 {
            var dy = max(min(peer.frame.minY - floor, win.height * 0.4), -win.height * 0.4)
            dy += dy > 0 ? 10 : -10   // the scroll view eats ~10 pt of touch slop per drag
            let from = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: win.width * 0.5, dy: win.height * 0.75))
            let to = from.withOffset(CGVector(dx: 0, dy: -dy))
            from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(1)
        }
        sleep(2)
        shot(app, "screen-02-remote")
        return app
    }

    /// Only the Remote listing shot (re-captures 02-remote without the whole set).
    func testCaptureRemoteScreen() {
        captureRemote().terminate()
    }

    func testCaptureMarketingScreens() {
        // 1.0.5's two new features LEAD the listing (Levi 2026-11-07), then the established set.

        // ── 1 — POCKET WHEEL: History ▸ Pockets ▸ Wheel over the deterministic three-week demo
        // history (`PDJ_SEED_POCKET_WHEEL`), built through the real moment engine. Tuesday is the
        // focused (widened) ring, so the weekday commute + lunch + gym pockets read at a glance.
        var app = launch(section: "History", extra: [
            "PDJ_SEED_POCKET_WHEEL": "1",
            "PDJ_HISTORY_TAB": "Pockets",
            "PDJ_POCKETS_SEGMENT": "Wheel",
            "PDJ_WHEEL_FOCUS_DOW": "2",
            // Pin the centre ▶'s "now" to Tuesday 8:20 AM so the best-match caption is the
            // commute pocket on every run (it otherwise follows the capture's wall clock).
            "PDJ_WHEEL_NOW": "2,8.33",
        ])
        let wheelPlay = app.buttons["pocket-wheel-play"]
        expect(wheelPlay, "Pocket Wheel centre play")
        sleep(4)   // let the engine's paint settle (cells fade in)
        // On the iPad's tall canvas the area under the legend is empty: open the Tuesday 8 AM
        // CarPlay pocket's card (same ring geometry as PocketWheelUITests — WheelLayout: radius =
        // side/2 − 22, hole 0.30 R, the focused ring 1.8×) so the shot shows what a pocket holds.
        if isPad {
            let c = CGPoint(x: wheelPlay.frame.midX, y: wheelPlay.frame.midY)
            let R: CGFloat = 520 / 2 - 22
            let unit = (R - 0.30 * R - 0.025 * R - 6 * 0.006 * R) / 7.8
            let tueMid = 0.30 * R + unit + 0.006 * R + 0.9 * unit
            let a = 8.5 / 24 * 2 * Double.pi
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: c.x + tueMid * CGFloat(sin(a)), dy: c.y - tueMid * CGFloat(cos(a))))
                .tap()
            _ = app.staticTexts["pocket-card-title"].waitForExistence(timeout: 10)
            sleep(2)
        }
        shot(app, "screen-01-pocketwheel")

        // ── 2 — REMOTE (Jukebox panel, Remote half).
        app.terminate()
        app = captureRemote()

        // ── 3 — MIX: two decks mid-transition, Auto-DJ live, real meters.
        app.terminate()
        app = launch(section: "Mix", extra: [
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
        shot(app, "screen-03-mix")

        // ── 4 — NOW PLAYING: full-bleed deck, playing mid-track, played + up-next populated.
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
        // Re-check the glyph: a tap that lands while the deck is still materializing is dropped
        // (the iPad capture once shot a held ▶ deck), so press until it reads Pause.
        // (iPad renders TWO np-playpause buttons — the sidebar deck and the expanded one — so
        // drive whichever is hittable.)
        let playPauses = app.buttons.matching(identifier: "np-playpause")
        if playPauses.firstMatch.waitForExistence(timeout: 5) {
            for _ in 0..<4 {
                guard let pp = playPauses.allElementsBoundByIndex.first(where: { $0.isHittable }),
                      !pp.label.localizedCaseInsensitiveContains("pause") else { break }
                pp.tap()
                sleep(3)
            }
        }
        sleep(2)
        shot(app, "screen-04-nowplaying")

        // ── 5 — PRODUCER: the 16-step grid with a five-lane groove programmed.
        app.terminate()
        app = launch(section: "Performance", extra: [
            "PDJ_SEED_STUDIO": "showcase",
            "PDJ_STUDIO_TAB": "sequencer",
            "PDJ_STUDIO_OPEN_PATTERN": "ptn_showcase",
        ])
        expect(app.staticTexts["Rooftop"], "Producer showcase pattern")
        sleep(3)
        shot(app, "screen-05-studio")

        // ── 6 — BROWSE: the catalog as the SONGS list, not the album grid. The invented fixture
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
        shot(app, "screen-06-browse")

        // ── 7 — COLLECTIONS: playlists and pockets.
        app.terminate()
        app = launch(section: "Playlists", extra: [
            "PDJ_SEED_COLLECTIONS": "showcase",
            "PDJ_SEED_ACTIVITY": "1",
        ])
        expect(app.staticTexts["Friday Night Warmup"], "showcase playlist")
        sleep(3)
        shot(app, "screen-07-playlists")

        app.terminate()
    }

    // MARK: - 1.0.5 listing passes (DJ Mode, Settings ▸ Mixing, Auto-DJ mid-crossfade, Remote top)

    /// Press the app's own ⏯ until it reads Pause (a tap that lands while the deck is still
    /// materializing is dropped). iPad renders TWO np-playpause buttons (sidebar + expanded deck).
    private func pressPlay(_ app: XCUIApplication) {
        let playPauses = app.buttons.matching(identifier: "np-playpause")
        guard playPauses.firstMatch.waitForExistence(timeout: 10) else { return }
        for _ in 0..<5 {
            guard let pp = playPauses.allElementsBoundByIndex.first(where: { $0.isHittable }),
                  !pp.label.localizedCaseInsensitiveContains("pause") else { break }
            pp.tap()
            sleep(3)
        }
    }

    /// The hittable instance of an id (iPad shows the sidebar deck AND the expanded one).
    private func hittable(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let q = app.descendants(matching: .any).matching(identifier: id)
        let deadline = Date().addingTimeInterval(timeout)
        let screen = app.windows.firstMatch.frame
        repeat {
            let all = q.allElementsBoundByIndex.filter { $0.exists }
            if let e = all.first(where: { $0.isHittable }) { return e }
            // Custom tappable views (a plain view + onTapGesture) can report not-hittable even
            // fully on screen: accept one whose frame sits inside the window.
            if let e = all.first(where: { !$0.frame.isEmpty && screen.contains($0.frame) }) { return e }
            usleep(300_000)
        } while Date() < deadline
        return nil
    }

    /// Tap at the element's centre (works for custom tap views XCUITest won't call hittable).
    private func press(_ e: XCUIElement) {
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Scroll the main scroll view until `id` is on screen (lazy lists only materialize rows near
    /// the viewport).
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ id: String, up: Bool = true, tries: Int = 14) -> XCUIElement? {
        for _ in 0..<tries {
            if let e = hittable(app, id, timeout: 1) { return e }
            up ? app.swipeUp() : app.swipeDown()
        }
        return hittable(app, id, timeout: 2)
    }

    private func envDelay(_ key: String, _ fallback: UInt32) -> UInt32 {
        ProcessInfo.processInfo.environment[key].flatMap { UInt32($0) } ?? fallback
    }

    /// NOW PLAYING DJ MODE, captured MID-MIX: the showcase set plays for real, the DJ chip is
    /// switched on through its own capsule (which turns Mix Mode on and opens the Mix panel), and
    /// ⏭ starts a DJ skip mix (Settings ▸ Mixing ▸ Skip fade, 15 s) into Tidal — so the tempo /
    /// pitch sliders and FX ride the automation, the chip's bar shows the crossfade progress and
    /// the leveling readout shows its trim. Nothing is posed: every moving part is the app's own
    /// transition running on the seeded full-length bodies.
    func testCapture105NowPlayingDJ() {
        var env = [
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_PLAYBACK_SESSION": "showcase",
            "PDJ_NP_EXPANDED": "1",
            "PDJ_SEED_COLLECTIONS": "showcase",
        ]
        // `PDJ_SHOT_NP_DOCKED=1`: shoot the iPad's docked sidebar deck instead of the full-bleed one.
        if ProcessInfo.processInfo.environment["PDJ_SHOT_NP_DOCKED"] == "1" { env["PDJ_NP_EXPANDED"] = nil }
        let section = ProcessInfo.processInfo.environment["PDJ_SHOT_NP_SECTION"] ?? "History"
        let app = launch(section: section, extra: env)
        expect(app.staticTexts["Golden Hour"], "Now Playing current track")
        pressPlay(app)
        // The Mix panel's container id (`np-mix-panel`) overrides its children's ids in the
        // accessibility tree, so the header controls are addressed by LABEL.
        func panelButton(_ label: String, prefix: Bool = false) -> XCUIElement? {
            let q = app.buttons.matching(NSPredicate(
                format: prefix ? "identifier == 'np-mix-panel' AND label BEGINSWITH %@ AND NOT (label BEGINSWITH 'Mix Mode')"
                               : "identifier == 'np-mix-panel' AND label == %@", label))
            let deadline = Date().addingTimeInterval(15)
            repeat {
                if let e = q.allElementsBoundByIndex.first(where: { $0.exists && !$0.frame.isEmpty }) { return e }
                usleep(300_000)
            } while Date() < deadline
            return nil
        }
        guard let dj = panelButton("DJ Mode") else {
            let att = XCTAttachment(string: app.debugDescription)
            att.name = "hierarchy.txt"; att.lifetime = .keepAlways; add(att)
            XCTFail("DJ chip missing"); return
        }
        if (dj.value as? String) != "On" { press(dj) }
        sleep(2)
        // Turning DJ on turns Mix Mode on, which opens the Mix panel once — open it if it isn't.
        if !app.staticTexts["Tempo"].exists, let toggle = panelButton("Mix", prefix: true) {
            press(toggle)
        }
        // Let the on-device analysis land its quick hints (leveling + the next row's facts).
        sleep(envDelay("PDJ_SHOT_DJ_SETTLE", 8))
        if ProcessInfo.processInfo.environment["PDJ_SHOT_DEBUG"] != nil { shot(app, "debug-dj-before-skip") }
        func isMixing() -> Bool { ((dj.value as? String) ?? "").localizedCaseInsensitiveContains("mixing") }
        // `PDJ_SHOT_DJ_MODE=natural`: no ⏭ — wait for the song's own end-of-track DJ transition
        // and shoot its PRE-ROLL glide (tempo / pitch / FX already moving, the queue not yet
        // advanced). Used on the phone, whose tall layout's "Previously played" flank header
        // otherwise slides under the floating ＋ once a skip advances the set.
        if ProcessInfo.processInfo.environment["PDJ_SHOT_DJ_MODE"] == "natural" {
            let deadline = Date().addingTimeInterval(200)
            while !isMixing() && Date() < deadline { usleep(500_000) }
            XCTAssertTrue(isMixing(), "the end-of-song DJ transition never started")
            sleep(envDelay("PDJ_SHOT_DJ_DELAY", 6))
            shot(app, "screen-105-01-dj")
            app.terminate()
            return
        }
        guard let next = hittable(app, "np-next") else { XCTFail("np-next missing"); return }
        // With DJ on, ⏭ is a tap view (single = Skip fade, double = fast). Press until the DJ
        // chip's own value reports the mix ("On, mixing n percent") — a dropped tap retries.
        var mixing = false
        for attempt in 0..<4 where !mixing {
            switch attempt {
            case 0: next.tap()
            case 1: next.press(forDuration: 0.15)
            case 2: press(next)
            default: next.doubleTap()   // the fast 5 s sweep — still a real DJ skip mix
            }
            for _ in 0..<12 where !mixing {
                usleep(250_000)
                mixing = ((dj.value as? String) ?? "").localizedCaseInsensitiveContains("mixing")
            }
        }
        if !mixing {
            let att = XCTAttachment(string: "dj value=\(String(describing: dj.value)) next=\(next.frame) hittable=\(next.isHittable)\n" + app.debugDescription)
            att.name = "hierarchy-after-skip.txt"; att.lifetime = .keepAlways; add(att)
        }
        XCTAssertTrue(mixing, "the DJ skip mix never started — the shot would show a plain deck")
        // A few seconds into the 15 s skip mix: crossfade under way, glides visibly off centre.
        sleep(envDelay("PDJ_SHOT_DJ_DELAY", 5))
        shot(app, "screen-105-01-dj")
        app.terminate()
    }

    /// SETTINGS ▸ MIXING: crossfade lengths, the DJ Mode toggles and the Mix tab section.
    func testCapture105SettingsMixing() {
        let app = launch(section: "Settings")
        _ = app.descendants(matching: .any)["settings-pocketdj-name"].waitForExistence(timeout: 20)
        guard let link = scrollTo(app, "settings-mixing") else {
            XCTFail("screenshot precondition missing: Settings ▸ Mixing row"); return
        }
        press(link)
        expect(app.descendants(matching: .any)["settings-automix-lead"].firstMatch, "Crossfades section")
        sleep(2)
        shot(app, "screen-105-02-settings-mixing")
        app.terminate()
    }

    /// MIX: the restored two-deck session, Auto-DJ resumed, Vol Glide switched on through its
    /// pill, then the Auto-DJ's own Skip — a 15 s crossfade — captured a few seconds in, so the
    /// crossfader is mid-travel and both decks show their leveling trim under Vol.
    func testCapture105MixCrossfade() {
        let app = launch(section: "Mix", extra: [
            "PDJ_SEED_BURNS": "showcase",
            "PDJ_SEED_MIX_DECK_SESSION": "showcase",
            "PDJ_MIX_DECK_LAYOUT": deckLayout,
        ])
        expect(app.staticTexts["Elevator to the Moon"], "Mix deck A track")
        // Resume the restored (suspended) Auto-DJ, retrying a dropped tap until its Pause shows.
        let resume = app.buttons["mix-auto-resume"]
        let pauseAuto = app.buttons["mix-auto-pause"]
        _ = resume.waitForExistence(timeout: 8)
        for _ in 0..<4 where !pauseAuto.exists {
            if resume.exists { press(resume) }
            _ = pauseAuto.waitForExistence(timeout: 4)
        }
        sleep(2)
        if let vg = hittable(app, "mix-volume-glide", timeout: 5) {
            let v = (vg.value as? String) ?? ""
            if !(v == "1" || v.localizedCaseInsensitiveContains("on")) { press(vg) }
        }
        sleep(envDelay("PDJ_SHOT_MIX_SETTLE", 5))   // the leveling analysis + its 2 s trim ramp
        guard let skip = scrollTo(app, "mix-auto-skip") else { XCTFail("Skip to next missing"); return }
        press(skip)
        sleep(envDelay("PDJ_SHOT_MIX_DELAY", 6))
        shot(app, "screen-105-03-mix")
        // A phone's stacked board is taller than the screen: also shoot the top (banner + deck A).
        if !isPad {
            for _ in 0..<5 {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            }
            sleep(1)
            shot(app, "screen-105-03b-mix-top")
        }
        app.terminate()
    }

    /// REMOTE, top of the panel: the session picker (Listen Together / Backseat) and Mix Together
    /// rows in frame — the scrolled `captureRemote` shot shows participants + Up Next instead.
    func testCapture105RemoteTop() {
        let app = launch(section: "Remote", extra: [
            "PDJ_SEED_REMOTE": "showcase",
            "PDJ_SEED_BURNS": "showcase",
        ])
        expect(app.descendants(matching: .any)["remote-now-playing"], "Remote now playing row")
        sleep(3)
        shot(app, "screen-105-04-remote-top")
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
