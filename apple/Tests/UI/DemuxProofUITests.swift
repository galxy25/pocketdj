import XCTest

/// SIMULATOR-DRIVEN PROOF of the Demuxer timeline (Levi 2026-07-18: "start at step zero
/// and generate proof of verification in the form of simulator-driven playback"): a
/// seeded 3-minute track REALLY PLAYS in the app while the test measures — from the
/// on-screen accessibility frames — that:
///   (1) zoom-in after a SCRUB (track never played) centers the scrubbed position — the
///       exact field bug,
///   (2) the ⌖ button jumps to the playhead and arms follow,
///   (3) during REAL playback the strip auto-scrolls (chord blocks stream left) and the
///       chord under the playhead stays centered,
///   (4) zooming DURING playback re-centers the live position,
///   (5) the full-span lyrics render.
/// Chord blocks carry deterministic ids (`demux-chord-<startMs>`, one per 2 s), so
/// "centered on the playback position" is a NUMERIC assertion, not a vibe. Screenshots
/// attach at every stage.
final class DemuxProofUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemux(lyrics: Bool = false) throws {
        #if os(macOS)
        throw XCTSkip("macOS UI automation is unavailable headless; the sim carries this proof")
        #else
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"   // no real account/CK in tests
        app.launchEnvironment["PDJ_SEED_DEMUX"] = "1"
        if lyrics { app.launchEnvironment["PDJ_DEMUX_LYRICS"] = "1" }
        app.launchEnvironment["PDJ_START_SECTION"] = "Performance"
        app.launch()
        // Sub-tab 5 = Demuxer (coordinate tap — compact segments carry no per-item ids;
        // the PerformanceUITests idiom).
        let seg = app.segmentedControls.firstMatch
        XCTAssertTrue(seg.waitForExistence(timeout: 10), "studio sub-tab picker up")
        seg.coordinate(withNormalizedOffset: CGVector(dx: 5.5 / 6.0, dy: 0.5)).tap()
        let row = app.any("demux-file-row-dmx_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded 'Demux Proof' source listed")
        row.tap()
        XCTAssertTrue(app.any("demux-timeline").waitForExistence(timeout: 20), "timeline ready")
        #endif
    }

    /// Current playback seconds, read from the transport clock ("m:ss / 3:00").
    private func clockSeconds() -> Int {
        let clock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "/ 3:00")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "transport clock visible")
        let head = clock.label.split(separator: "/")[0].trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2, "clock parses: \(clock.label)")
        return parts[0] * 60 + parts[1]
    }

    /// The chord block whose 2 s span contains `second` (deterministic seeded grid).
    private func chordBlock(at second: Int) -> XCUIElement {
        app.any("demux-chord-\((second / 2) * 2_000)")
    }

    /// Assert the chord under playback second `t` sits near the strip's horizontal
    /// center — at 60 px/s across a 10 800 pt strip, ±220 pt can only hold if the
    /// zoom/follow re-center actually happened.
    private func assertCentered(at t: Int, tolerance: CGFloat = 220,
                                _ message: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        let mid = app.any("demux-timeline").frame.midX
        let block = chordBlock(at: t)
        XCTAssertTrue(block.exists, "chord for t=\(t)s is on screen — \(message)",
                      file: file, line: line)
        XCTAssertLessThan(abs(block.frame.midX - mid), tolerance,
                          "\(message) (chord midX \(block.frame.midX), strip mid \(mid))",
                          file: file, line: line)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testScrubZoomPlaybackFollowAndLyrics() throws {
        try launchDemux()
        snap("demux-proof-1-ready")

        // ---- (1) Scrub BEFORE ever playing, then zoom in: must center the scrub point.
        let strip = app.any("demux-timeline")
        // Tap in the waveform lane (upper strip) — below it every 2 s cell is a chord
        // BUTTON whose tap would open the detail sheet instead of scrubbing.
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25)).tap()
        let scrubT = clockSeconds()
        XCTAssertGreaterThan(scrubT, 10, "the tap scrubbed forward (clock \(scrubT)s)")
        app.el("demux-zoom-in").tap()      // 10 → 25 px/s
        app.el("demux-zoom-in").tap()      // 25 → 60 px/s
        sleep(1)                            // deferred (post-layout) re-center lands
        assertCentered(at: clockSeconds(), "zoom-in centers the SCRUBBED position, never played")
        snap("demux-proof-2-zoom-after-scrub")

        // ---- (2) ⌖ re-centers and arms follow (works while paused).
        app.el("demux-follow").tap()
        sleep(1)
        assertCentered(at: clockSeconds(), "⌖ centers the playhead while paused")

        // ---- (3) REAL playback: the clock advances, the strip streams left, and the
        //          chord under the playhead stays centered (follow).
        app.el("demux-play").tap()
        sleep(2)
        let t1 = clockSeconds()
        XCTAssertGreaterThan(t1, scrubT, "the clock advances — audio is actually playing")
        let ref = chordBlock(at: (scrubT / 2) * 2)      // fixed block; its x tracks the scroll
        let x1 = ref.frame.minX
        sleep(4)
        let x2 = ref.frame.minX
        XCTAssertLessThan(x2, x1 - 100,
                          "the strip auto-scrolls with playback (block moved \(x1 - x2) pt left)")
        assertCentered(at: clockSeconds(), tolerance: 260,
                       "follow keeps the LIVE playhead centered during playback")
        snap("demux-proof-3-playing-following")

        // ---- (4) Zoom DURING playback re-centers the live position.
        app.el("demux-zoom-out").tap()     // 60 → 25 px/s
        sleep(1)
        assertCentered(at: clockSeconds(), tolerance: 150,
                       "zoom during playback re-centers the live position")
        snap("demux-proof-4-zoom-while-playing")
        app.el("demux-play").tap()          // pause for the panel sweep

        // ---- (5) Lyrics are HIDDEN in the shipped state (DemuxFeatures.lyricsEnabled off
        //          until the cloud/local-model transcription engine lands).
        var n = 0
        while n < 8 { app.swipeUp(); n += 1 }
        XCTAssertFalse(app.any("demux-lyrics").exists, "no Lyrics panel while the feature is gated")
        XCTAssertFalse(app.any("demux-transcribing").exists, "no transcription ever kicks off")
        snap("demux-proof-5-no-lyrics")
    }

    /// The gated karaoke path stays ALIVE for the engine swap: relaunching with the
    /// PDJ_DEMUX_LYRICS=1 dev seam renders the full-span seeded lyrics.
    func testGatedLyricsPathStillRendersUnderDevSeam() throws {
        try launchDemux(lyrics: true)
        var n = 0
        while !app.any("demux-lyrics").exists && n < 12 { app.swipeUp(); n += 1 }
        XCTAssertTrue(app.any("demux-lyrics").exists, "dev-seam Lyrics panel renders")
        // Lines render as one concatenated Text inside a (tap-to-seek) Button — match any
        // element carrying the joined words.
        let line = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "let me see you go back")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "seeded lyric lines render")
        snap("demux-proof-6-dev-seam-lyrics")
    }
}
