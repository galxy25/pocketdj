import XCTest

/// SCRIPTED DEMO WALK for the community-class video (target 90–120 s on screen): one continuous,
/// paced tour of the Mix decks (load two REAL tracks, sync, ride the crossfader, stem-mute vocals,
/// an FX pad, then Auto + Shuffle + Skip) and the Producer suite (Sequencer playing, Demuxer,
/// Tracks arranger). Launched WITHOUT the fixture seam on purpose — the video shows Levi's actual
/// burned library, exactly like `MixSapReproUITests`' real-state pattern.
///
/// The house-mix RECORDING is started in-app (mix-record) before the decks load and stopped before
/// the Producer chapters, so the demo's own mixing becomes the final video's soundtrack (ffmpeg
/// muxes the .m4a over the screen capture afterwards).
///
/// RULES OF THE WALK:
///   • Opt-in only: skips unless PDJ_DEMO_VIDEO=1 (the PDJ_SAP_REPRO gating pattern) — a normal
///     suite run must never spend two minutes here, and the walk depends on on-device state.
///   • EVERY interaction is existence-guarded: a missing control logs a SKIP note and the walk
///     moves on. The video must never fail mid-run, so nothing here asserts.
///   • Pacing is explicit `pause(...)` sleeps so each beat reads on video; XCUITest's own taps
///     are instant.
final class DemoVideoUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PDJ_DEMO_VIDEO"] == "1",
                          "scripted demo-video walk against the REAL library — opt in with PDJ_DEMO_VIDEO=1")
        continueAfterFailure = true   // the video must never die mid-run
    }

    func testDemoVideoWalk() {
        app = XCUIApplication()
        app.launchEnvironment["PDJ_DISABLE_CLOUD_SYNC"] = "1"       // no entitlements in this build
        app.launchEnvironment["PDJ_DISABLE_SESSION_RESTORE"] = "1"  // a clean two-deck opening frame
        app.launchEnvironment["PDJ_START_SECTION"] = "Mix"
        // The debug world's burned audio is seeded by hardlink into the app-storage burns dir;
        // this rebuilds ready ledger entries from those files at launch (PocketDJApp seam).
        app.launchEnvironment["PDJ_ADOPT_ORPHANS"] = "1"
        if let preferred = ProcessInfo.processInfo.environment["PDJ_DEMO_COLLECTION"] {
            app.launchEnvironment["PDJ_DEMO_COLLECTION"] = preferred   // (unused by the app; kept for symmetry)
        }
        app.launch()

        // ---- 0. Settle on the Mix tab, in Manual mode ----
        _ = app.any("mix-auto-mode").waitForExistence(timeout: 30)
        ensureManualMode()
        pause(3)
        shot("01-mix-settled")

        // ---- 1. Start the in-app house recording (the video's soundtrack) ----
        // mix-record is a WINDOW-TOOLBAR button — on macOS those resolve but don't fire under
        // XCUITest taps (the XCUIHelpers lesson), so drive MixView's ⇧⌘R Record-shadow there.
        #if os(macOS)
        app.activate()
        app.typeKey("r", modifierFlags: [.command, .shift])
        note("typed ⇧⌘R (Record-shadow — start recording)")
        #else
        tapIfPresent(app.any("mix-record"), "mix-record (start recording)")
        #endif
        // VERIFY the start: the in-content indicator strip renders only while recording. Without
        // it there is no soundtrack — and step 9's stop toggle must know not to fire.
        let recordingStarted = app.any("mix-record-indicator").waitForExistence(timeout: 5)
        if !recordingStarted {
            note("WARNING: mix-record-indicator never appeared — recording did NOT start; "
                 + "the final video will have no in-app soundtrack")
        }
        pause(1.5)

        // ---- 2. Load both decks from the real library ----
        loadDeck("A", preferRow: 0)
        pause(1)
        loadDeck("B", preferRow: 1)
        pause(1)
        shot("02-decks-loaded")

        // ---- 3. Deck A plays first, crossfader hard on A ----
        setCrossfader(0.02)
        tapIfPresent(app.any("deck-A-play"), "deck-A-play")
        pause(8)

        // ---- 4. Sync deck B to A, then play it ----
        // Sync is "Sync to Lead" and no-ops without a lead deck (MixEngine.syncToLead guards on
        // leadDeck) — star deck A first so the sync visibly matches B's tempo to A's.
        tapIfPresent(app.any("deck-A-lead"), "deck-A-lead (beat-match reference)")
        pause(0.8)
        tapIfPresent(app.any("deck-B-sync"), "deck-B-sync")
        pause(0.8)
        tapIfPresent(app.any("deck-B-play"), "deck-B-play")
        pause(2)

        // ---- 5. Ride the crossfader A → B over ~6 s ----
        for pos in [0.15, 0.30, 0.45, 0.60, 0.72, 0.85, 1.0] {
            setCrossfader(pos)
            pause(0.85)
        }
        pause(1)
        shot("03-crossfaded-to-B")

        // ---- 6. Deck B stems: stem mode on, mute vocals ~4 s, unmute, stem mode off ----
        // deck-B-stemmode renders only for a track with stems; the real library carries 4-stem
        // sets for every ready burn, but the guard keeps a stemless pick from stalling the walk.
        if tapIfPresent(app.any("deck-B-stemmode"), "deck-B-stemmode (enter stem mode)", timeout: 4) {
            let vocals = app.any("deck-B-stem-vocals")
            if tapIfPresent(vocals, "deck-B-stem-vocals (mute)", timeout: 8) {
                pause(4)
                tapIfPresent(vocals, "deck-B-stem-vocals (unmute)", timeout: 3)
                pause(1.5)
            }
            tapIfPresent(app.any("deck-B-stemmode"), "deck-B-stemmode (exit stem mode)", timeout: 3)
            pause(1)
        }

        // ---- 7. One FX pad on/off ----
        // Rack slot 3 is the default layout's Filter (ids are slot-indexed now that a rack can hold
        // duplicates, so a name-keyed id would be ambiguous).
        let fx = app.any("deck-B-fx-slot-3")
        if tapIfPresent(fx, "deck-B-fx-slot-3 (on)", timeout: 4) {
            pause(3)
            tapIfPresent(fx, "deck-B-fx-slot-3 (off)", timeout: 3)
            pause(1)
        }

        // ---- 8. Auto mode: pick a collection, Play + Shuffle, ride, Skip ----
        autoChapter()
        shot("04-auto-mix")

        // ---- 9. Stop the house recording (soundtrack ends with the mix) ----
        // GUARDED by recordingStarted: mix-record is a TOGGLE, so a stop after a failed start
        // would START a stray never-stopped recording over the Producer chapters — and that
        // fragment is what newestMixRecording would mux on a later run.
        if recordingStarted {
            #if os(macOS)
            app.activate()
            app.typeKey("r", modifierFlags: [.command, .shift])
            note("typed ⇧⌘R (Record-shadow — stop recording)")
            #else
            tapIfPresent(app.any("mix-record"), "mix-record (stop recording)")
            #endif
            pause(1)
            if app.any("mix-record-indicator").exists {
                // The toggle didn't land — use the in-content Stop on the indicator strip.
                tapIfPresent(app.any("mix-record-stop"), "mix-record-stop (fallback)", timeout: 3)
                pause(1)
            }
        } else {
            note("SKIP: stop-recording — the start never fired, so toggling now would start one")
        }

        // ---- 10–12. Producer suite: Sequencer → Demuxer → Tracks (end on the arranger) ----
        gotoProducer()
        pause(1.5)
        sequencerChapter()
        demuxerChapter()
        tracksChapter()

        note("demo walk complete")
    }

    // MARK: - Chapters

    /// Load a deck via its header (deck-X-load opens the TrackLoaderSheet). If the deck has no
    /// source yet (fresh launch), pick the first collection from the sheet's source menu.
    private func loadDeck(_ deck: String, preferRow: Int) {
        note("=== load deck \(deck) ===")
        guard tapIfPresent(app.any("deck-\(deck)-load"), "deck-\(deck)-load (open loader)", timeout: 8) else { return }
        let sheet = app.any("mix-loader")
        _ = sheet.waitForExistence(timeout: 6)
        pause(1)                                   // let the sheet read on video
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mix-loader-row-"))
        if !rows.firstMatch.waitForExistence(timeout: 3) {
            // No rows ⇒ no source picked yet. Menus are driven BLIND (keyboard only — see
            // chooseFirstMenuItem), so the pick is verified by its OUTCOME: rows appearing.
            // The first collection can be a dud (job c5a3b2e9 landed on an empty "test"
            // collection), so walk down the menu until one actually yields loadable rows.
            for attempt in 0..<4 {
                guard tapIfPresent(app.any("mix-loader-source"),
                                   "mix-loader-source (pick #\(attempt + 1))", timeout: 4) else { break }
                pickMenuItem(index: attempt, what: "deck \(deck) loader source")
                if rows.firstMatch.waitForExistence(timeout: 5) { break }
                note("collection pick #\(attempt + 1) offered no loadable rows — trying the next")
            }
        }
        let count = rows.count
        guard count > 0 else {
            note("SKIP: deck \(deck) loader has no loadable rows")
            tapIfPresent(app.any("mix-loader-done"), "mix-loader-done (close empty loader)", timeout: 3)
            return
        }
        let row = rows.element(boundBy: min(preferRow, count - 1))
        note("deck \(deck) loading row: \(row.label)")
        row.tapCenter()
        _ = sheet.waitForNonExistence(timeout: 6)
        _ = app.any("deck-\(deck)-seek").waitForExistence(timeout: 8)   // seek slider ⇒ loaded
    }

    /// Flip to Auto, pick a collection if Play is still disabled (the auto source starts nil with
    /// session restore off), start the auto mix shuffled, let it ride, then Skip once.
    private func autoChapter() {
        note("=== Auto mode ===")
        setAutoMode(true)
        let play = app.buttons["mix-auto-play"].firstMatch
        _ = play.waitForExistence(timeout: 6)
        pause(1)
        if play.exists && !play.isEnabled {
            // Play is disabled until a collection is chosen. Blind keyboard picks, verified by
            // the OUTCOME (Play enabling) — walk down the menu past empty collections.
            for attempt in 0..<4 {
                guard tapIfPresent(app.any("mix-auto-source"),
                                   "mix-auto-source (pick #\(attempt + 1))", timeout: 4) else { break }
                pickMenuItem(index: attempt, what: "auto-mix collection")
                pause(1)
                if play.isEnabled { break }
                note("auto collection pick #\(attempt + 1) left Play disabled — trying the next")
            }
        }
        tapIfPresent(play, "mix-auto-play", timeout: 4)
        pause(1)
        // Shuffle re-starts the queue shuffled while the setup bar is still up; once the mix is
        // live the bar is replaced by the banner and this is a harmless guarded skip.
        tapIfPresent(app.buttons["mix-auto-shuffle"].firstMatch, "mix-auto-shuffle", timeout: 2)
        pause(10)
        tapIfPresent(app.any("mix-auto-skip"), "mix-auto-skip", timeout: 4)
        pause(8)
    }

    /// ⌘3 — open the first pattern (or create one), paint steps only if the pattern is EMPTY
    /// (seq-play is disabled with zero sounding steps — the empty-pattern refusal), then play ~10 s.
    private func sequencerChapter() {
        note("=== Sequencer ===")
        gotoStudioTab("3", index: 2, name: "Sequencer")
        pause(1.5)
        let patternRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "seq-pattern-"))
        if patternRows.firstMatch.waitForExistence(timeout: 6) {
            note("opening existing pattern: \(patternRows.firstMatch.label)")
            patternRows.firstMatch.tapCenter()
        } else {
            tapIfPresent(app.any("seq-new"), "seq-new (create + open a pattern)", timeout: 4)
        }
        let play = app.any("seq-play")
        _ = play.waitForExistence(timeout: 8)
        pause(1)
        if play.exists && !play.isEnabled {
            // Empty pattern: give it a row if it has none, then paint a simple 4-to-the-floor +
            // offbeats so Play has something to sound.
            if !app.any("seq-step-0-0").exists {
                if tapIfPresent(app.any("seq-add-row"), "seq-add-row", timeout: 3) {
                    chooseFirstMenuItem("sequencer add-row target")
                    pause(1)
                }
            }
            for (r, c) in [(0, 0), (0, 4), (0, 8), (0, 12), (1, 2), (1, 6), (1, 10), (1, 14)] {
                let cell = app.any("seq-step-\(r)-\(c)")
                if cell.waitForExistence(timeout: 1) {
                    cell.tapCenter()
                    pause(0.3)
                } else {
                    note("SKIP: seq-step-\(r)-\(c) not present")
                }
            }
            pause(1)
        }
        if tapIfPresent(play, "seq-play", timeout: 3) {
            pause(10)
            tapIfPresent(play, "seq-play (stop)", timeout: 3)
            pause(1)
        }
    }

    /// ⌘6 — the Demuxer: open the first offered track, play it, try a vocals stem solo. Everything
    /// here is best-effort — analysis may not be ready on this machine, so guards carry the chapter.
    private func demuxerChapter() {
        note("=== Demuxer ===")
        gotoStudioTab("6", index: 5, name: "Demuxer")
        pause(1.5)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "demux-track-row-"))
        if rows.firstMatch.waitForExistence(timeout: 6) {
            note("opening demux track: \(rows.firstMatch.label)")
            rows.firstMatch.tapCenter()
            pause(2)
        } else {
            note("SKIP: no demux track rows offered (staying on the source picker)")
        }
        if tapIfPresent(app.any("demux-play"), "demux-play", timeout: 8) {
            pause(4)
            if tapIfPresent(app.any("demux-stem-mode"), "demux-stem-mode", timeout: 2) { pause(1) }
            if tapIfPresent(app.any("demux-stem-solo-vocals"), "demux-stem-solo-vocals", timeout: 3) {
                pause(3)
                tapIfPresent(app.any("demux-stem-solo-vocals"), "demux-stem-solo-vocals (unsolo)", timeout: 2)
            }
            pause(2)
            tapIfPresent(app.any("demux-play"), "demux-play (stop)", timeout: 3)
        } else {
            pause(6)   // hold the picker on screen so the chapter still reads on video
        }
    }

    /// ⌘7 — the multitrack arranger. Create an arrangement from the home browser and add a lane,
    /// so the walk ENDS on a real arranger frame.
    private func tracksChapter() {
        note("=== Tracks (arranger) ===")
        gotoStudioTab("7", index: 6, name: "Tracks")
        pause(1.5)
        if tapIfPresent(app.any("tracks-new-arrangement"), "tracks-new-arrangement", timeout: 6) {
            _ = app.any("tracks-add-track").waitForExistence(timeout: 8)
            pause(1)
            // Give the empty arranger a lane so the closing frame shows a lane strip.
            if !tapIfPresent(app.any("tracks-empty-add-track"), "tracks-empty-add-track", timeout: 3) {
                tapIfPresent(app.any("tracks-add-track"), "tracks-add-track", timeout: 3)
            }
            pause(4)
        } else {
            note("SKIP: arranger home not offered; holding whatever Tracks shows")
            pause(6)
        }
        shot("99-end-arranger")
    }

    // MARK: - Navigation

    /// The Mix chapters run in MANUAL mode first; mix-auto-mode's label reads the CURRENT mode.
    private func ensureManualMode() {
        setAutoMode(false)
    }

    /// Flip the Manual/Auto toggle into the requested mode. mix-auto-mode is a WINDOW-TOOLBAR
    /// item: on macOS it isn't a `.buttons` element (type-agnostic `any()` finds it and reads its
    /// label) and taps on it resolve-but-don't-fire, so macOS drives MixView's ⇧⌘A
    /// AutoMode-shadow instead; other platforms tap the toggle directly.
    private func setAutoMode(_ auto: Bool) {
        let toggle = app.any("mix-auto-mode")
        guard toggle.waitForExistence(timeout: 10) else {
            note("SKIP: mix-auto-mode not found")
            return
        }
        // The button's label reads the CURRENT mode (the MixSapRepro lesson).
        guard toggle.label.contains(auto ? "Manual" : "Auto") else {
            note("mix-auto-mode label '\(toggle.label)' — already the desired mode, leaving as-is")
            return
        }
        #if os(macOS)
        app.activate()
        app.typeKey("a", modifierFlags: [.command, .shift])
        note("typed ⇧⌘A (AutoMode-shadow) → \(auto ? "Auto" : "Manual")")
        #else
        toggle.tapCenter()
        note("tapped mix-auto-mode → \(auto ? "Auto" : "Manual")")
        #endif
        pause(1)
    }

    /// ⌘P → Producer (the "Performance" token). macOS drives the app's keyboard shortcut (the
    /// house pattern — toolbar/segment controls aren't reliably tappable there); other platforms
    /// tap the hidden shadow button best-effort.
    private func gotoProducer() {
        note("=== Producer ===")
        #if os(macOS)
        app.activate()
        app.typeKey("p", modifierFlags: .command)
        #else
        tapIfPresent(app.buttons["Performance-shadow"].firstMatch, "Performance-shadow", timeout: 4)
        #endif
        _ = app.any("studio-tab-picker").waitForExistence(timeout: 15)
    }

    /// Producer sub-tab switch: ⌘1…⌘7 shadow shortcuts on macOS (PerformanceView.tabShortcuts);
    /// elsewhere a positional coordinate tap on the segmented picker (PerformanceUITests.switchTab).
    private func gotoStudioTab(_ key: String, index: Int, name: String) {
        #if os(macOS)
        app.activate()
        app.typeKey(key, modifierFlags: .command)
        #else
        let seg = app.segmentedControls.firstMatch
        let picker = seg.exists ? seg : app.any("studio-tab-picker")
        if picker.waitForExistence(timeout: 8) {
            let dx = (Double(index) + 0.5) / 7.0
            picker.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
        } else {
            note("SKIP: studio sub-tab picker not found for \(name)")
        }
        #endif
        note("→ Producer ▸ \(name)")
    }

    // MARK: - Guarded interaction helpers

    /// Tap an element's centre IF it exists — otherwise log a SKIP and keep walking. The centre
    /// coordinate tap is deliberate: many Mix controls are `.buttonStyle(.plain)` / tap-gesture
    /// views where a plain `.tap()` can resolve-but-not-fire (the XCUIHelpers.tapCenter lesson).
    @discardableResult
    private func tapIfPresent(_ el: XCUIElement, _ what: String, timeout: TimeInterval = 5) -> Bool {
        guard el.waitForExistence(timeout: timeout) else {
            note("SKIP: \(what) not found")
            return false
        }
        el.tapCenter()
        note("tapped \(what)")
        return true
    }

    /// Move the equal-power crossfader (a SwiftUI Slider) to a normalized 0…1 position — the
    /// `adjust(toNormalizedSliderPosition:)` idiom MixSessionsUITests already uses on it.
    private func setCrossfader(_ pos: Double) {
        let fader = app.any("crossfader")
        guard fader.waitForExistence(timeout: 3) else {
            note("SKIP: crossfader not found")
            return
        }
        fader.adjust(toNormalizedSliderPosition: CGFloat(pos))
        note("crossfader → \(pos)")
    }

    /// Blind keyboard selection in an OPEN NSMenu, verified by the caller via its outcome.
    /// Attempt 0 prefers PDJ_DEMO_COLLECTION (runner arg `collection`): NSMenu type-ahead
    /// jumps to the first item matching the typed name — how the demo lands on the REAL
    /// library ("Welcome to The Town") instead of whatever sorts first (the empty "test"
    /// collection, take c5a3b2e9's fate). Later attempts walk Down item-by-item.
    private func pickMenuItem(index: Int, what: String) {
        pause(0.8)                                    // let the popup finish opening
        if index == 0,
           let name = ProcessInfo.processInfo.environment["PDJ_DEMO_COLLECTION"],
           !name.isEmpty {
            app.typeText(name)                        // type-ahead jump
            pause(0.5)
            app.typeKey(.return, modifierFlags: [])
            note("type-ahead picked '\(name)' for \(what)")
            return
        }
        for _ in 0...index { app.typeKey(.downArrow, modifierFlags: []); pause(0.25) }
        app.typeKey(.return, modifierFlags: [])
        note("keyboard-picked item #\(index + 1) for \(what)")
    }

    /// After a Menu was opened, choose its FIRST item. On macOS this is keyboard-driven —
    /// Down then Return — because element queries are a trap here: `app.menuItems` matches the
    /// entire MENU BAR tree before the popup's own items, so job 515a2054 "chose" an
    /// empty-labeled system item and popped System Information over the walk, three times.
    /// NSMenu is fully keyboard-navigable and Down skips headers/disabled items natively.
    @discardableResult
    private func chooseFirstMenuItem(_ what: String) -> Bool {
        #if os(macOS)
        pause(0.8)                                    // let the popup finish opening
        app.typeKey(.downArrow, modifierFlags: [])    // highlight the first enabled item
        pause(0.4)
        app.typeKey(.return, modifierFlags: [])       // commit it
        note("keyboard-picked (↓ ⏎) first menu item for \(what)")
        return true
        #else
        let items = app.menuItems
        guard items.firstMatch.waitForExistence(timeout: 4) else {
            note("SKIP: no menu items appeared for \(what)")
            return false
        }
        for i in 0..<min(items.count, 10) {
            let item = items.element(boundBy: i)
            if item.isEnabled {
                note("choosing menu item '\(item.label)' for \(what)")
                item.tap()
                return true
            }
        }
        items.firstMatch.tap()
        return true
        #endif
    }

    // MARK: - Pacing + evidence

    /// Explicit on-video pacing. XCUITest actions are instant; these sleeps are the demo's rhythm.
    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// A note in the test log AND as an attachment (survives xcresult extraction) — MixSapRepro's
    /// `record` pattern.
    private func note(_ s: String) {
        NSLog("[demo-video] %@", s)
        let att = XCTAttachment(string: s)
        att.name = "log"
        att.lifetime = .keepAlways
        add(att)
    }
}
