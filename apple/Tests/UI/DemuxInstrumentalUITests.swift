import XCTest

/// SIMULATOR-DRIVEN PROOF of the Demux "Extract instrumental" hand-off + synced score (F8 slice A),
/// modeled on DemuxProofUITests. Drives the seeded fixture (a chord every 2 s, chordStatus .done),
/// taps `demux-instrumental-extract`, and confirms the instrumental was minted (success notice),
/// the synced score renders, and the shared follow toggle scrolls the score as the fixture plays.
/// Screenshots attach at every stage.
final class DemuxInstrumentalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchInstrumental() throws {
        #if os(macOS)
        throw XCTSkip("macOS UI automation is unavailable headless; the sim carries this proof")
        #else
        app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_DEMUX"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Performance"
        app.launch()
        let seg = app.segmentedControls.firstMatch
        XCTAssertTrue(seg.waitForExistence(timeout: 10), "studio sub-tab picker up")
        seg.coordinate(withNormalizedOffset: CGVector(dx: 5.5 / 6.0, dy: 0.5)).tap()   // Demuxer
        let row = app.any("demux-file-row-dmx_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded 'Demux Proof' source listed")
        row.tap()
        XCTAssertTrue(app.any("demux-timeline").waitForExistence(timeout: 20), "timeline ready")
        #endif
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Reveal a control below the fold by swiping the outer scroll up until it exists.
    private func revealDown(_ id: String, tries: Int = 10) -> XCUIElement {
        var el = app.any(id)
        var n = 0
        while !el.exists && n < tries { app.swipeUp(); el = app.any(id); n += 1 }
        return el
    }

    func testExtractInstrumentalAndSyncedScoreFollow() throws {
        try launchInstrumental()
        snap("instrumental-1-ready")

        // ---- Extract: the chords-only panel mints a StudioTake (routed to the Instruments tab).
        let extract = revealDown("demux-instrumental-extract")
        XCTAssertTrue(extract.waitForExistence(timeout: 10), "Extract-instrumental button present")
        XCTAssertTrue(app.any("demux-instrumental-score").waitForExistence(timeout: 10),
                      "synced score renders (quantized + laid out off the main actor)")
        extract.tap()
        let notice = app.any("demux-instrumental-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "extracting the instrumental confirms it was saved as a take")
        snap("instrumental-2-extracted")

        // ---- Synced follow, PAUSED SCRUB: follow is on by default; tapping a bar chip seeks the
        //      (paused) shared player, and the un-gated follow poll advances the score's current
        //      system so it scroll-follows — the spec's "scrub while paused scrolls both". With the
        //      LazyVStack the far-up rows can recycle, so the robust probe is the SCRUB TARGET
        //      system (2): the follow programmatically centers it, so after the scrub it MUST be
        //      realized + on-screen. If it was already visible beforehand it also rides UP; if it
        //      wasn't (taller iPad rows push it below the fold), its mere appearance is the proof —
        //      nothing but the follow scroll could bring it on-screen from a top-anchored scroll.
        XCTAssertTrue(app.any("demux-sync-follow").exists, "shared follow toggle present")
        let target = app.any("score-system-2")          // 2 s bars ⇒ score measure 8 ⇒ system 2
        let existedBefore = target.exists
        let beforeY: CGFloat = existedBefore ? target.frame.minY : .greatestFiniteMagnitude
        let bar = app.el("demux-instrumental-bar-8")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "an on-screen bar chip to scrub to")
        bar.tap()
        sleep(2)                                        // the ~200 ms follow poll + scroll settle
        XCTAssertTrue(target.exists,
                      "a paused scrub follow-scrolled the score to the scrubbed-to system (2)")
        if existedBefore {
            XCTAssertLessThan(target.frame.minY, beforeY - 20,
                              "the scrubbed-to system rode up as the score follow-scrolled "
                              + "(moved \(beforeY - target.frame.minY) pt)")
        }
        snap("instrumental-3-following")
    }
}
