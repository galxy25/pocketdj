import XCTest

/// F8 — the Collection tab as a ONE TRUE TIMELINE, driven for real on the fixture catalog.
///
/// The fixture carries `dateAdded` on six of its seven songs, spread over six different months of
/// 2024–2025, with `sng_7` ("Slow Burn") deliberately UNDATED — so this suite exercises the whole
/// shape: the default view being unchanged, the two catalog grains, the cutoff, direction, the
/// progress readout, the honest "no add date" footnote, and cue points.
final class CollectionTimelineUITests: XCTestCase {

    private func openCollection() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_ACTIVITY"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "History"
        // The add-date union is OWNER-SCOPED (a hybrid user must not see the curator's library
        // history). A fixture run can't reach CloudKit to resolve that, so it falls to "not the
        // owner" and every fixture `dateAdded` is scoped away — see `AppModel.fixtureOwnerOverride`.
        app.launchEnvironment["PDJ_OWNER"] = "1"
        app.launch()
        XCTAssertTrue(app.el("history-tab-collection").waitForExistence(timeout: 30))
        app.el("history-tab-collection").tap()
        return app
    }

    /// THE REQUIREMENT THAT OUTRANKS THE REST: opening the Collection tab must look exactly like it
    /// always has — the activity feed of adds / hearts / removes. The timeline is opt-in, and the
    /// only thing new on the default screen is the picker that offers it.
    @MainActor
    func testDefaultIsStillTheActivityFeed() {
        let app = openCollection()
        XCTAssertTrue(app.any("activity-row").firstMatch.waitForExistence(timeout: 20),
                      "the Collection tab must still OPEN on its activity feed")
        XCTAssertTrue(app.textContaining("Running It Up").exists,
                      "the seeded activity rows still render")
        // The timeline chrome is NOT on the default screen.
        XCTAssertFalse(app.el("timeline-date-toggle").exists)
        XCTAssertFalse(app.any("timeline-progress").exists)
        // …and the way to it is present.
        XCTAssertTrue(app.segment("Songs").waitForExistence(timeout: 5))
        XCTAssertTrue(app.segment("Albums").exists)
    }

    #if !os(macOS)

    /// Songs grain: the six dated fixture songs land on the axis newest-first by default, the
    /// undated one does not, and the header says so rather than pretending the library is complete.
    @MainActor
    func testSongsGrainPlacesDatedSongsAndNamesTheUndatedOnes() {
        let app = openCollection()
        app.segment("Songs").tap()

        XCTAssertTrue(app.any("timeline-row-sng_6").waitForExistence(timeout: 20),
                      "the newest dated fixture song should be on the timeline")
        XCTAssertTrue(app.any("timeline-row-sng_1").exists, "the oldest dated song too")
        XCTAssertFalse(app.any("timeline-row-sng_7").exists,
                       "a song with no add date has no honest position — it must not be placed")
        XCTAssertTrue(app.textContaining("no add date").exists,
                      "the undated remainder has to be stated, not silently dropped")
        XCTAssertTrue(app.any("timeline-progress").exists, "the progress readout renders")
    }

    /// Direction is reversible, and the control actually reorders the stream: the first row on
    /// screen flips between the newest and the oldest addition.
    @MainActor
    func testDirectionTogglesBetweenNewestAndOldestFirst() {
        let app = openCollection()
        app.segment("Songs").tap()
        let newest = app.any("timeline-row-sng_6")     // 2025-11-02
        let oldest = app.any("timeline-row-sng_1")     // 2024-01-15
        XCTAssertTrue(newest.waitForExistence(timeout: 20))
        XCTAssertLessThan(newest.frame.minY, oldest.frame.minY,
                          "descending (the default) puts the newest addition first")

        app.el("timeline-order").tap()
        XCTAssertTrue(oldest.waitForExistence(timeout: 10))
        XCTAssertLessThan(oldest.frame.minY, newest.frame.minY,
                          "ascending puts the oldest addition first")
    }

    /// "Added after a date". The fixture spans 2024–2025, and the picker defaults to a year ago,
    /// so switching the cutoff on drops the 2024 additions and keeps the 2025 ones.
    @MainActor
    func testDateCutoffNarrowsTheStream() {
        let app = openCollection()
        app.segment("Songs").tap()
        XCTAssertTrue(app.any("timeline-row-sng_1").waitForExistence(timeout: 20),
                      "all time shows the 2024 additions")

        app.el("timeline-date-toggle").tap()
        // `any`, not `el`: a compact `DatePicker` is not a plain Button on either platform.
        XCTAssertTrue(app.any("timeline-date").waitForExistence(timeout: 10),
                      "turning the cutoff on reveals the date picker")
        XCTAssertFalse(app.any("timeline-row-sng_1").waitForExistence(timeout: 3),
                       "a song added before the cutoff should leave the stream")
    }

    /// Albums grain: one row per album, each carrying its own progress bar over its tracks.
    @MainActor
    func testAlbumsGrainShowsAlbumRowsWithProgress() {
        let app = openCollection()
        app.segment("Albums").tap()
        XCTAssertTrue(app.any("timeline-row-alb_1").waitForExistence(timeout: 20),
                      "albums grain places albums, not songs")
        XCTAssertTrue(app.any("timeline-album-progress-alb_1").exists,
                      "an album row carries its heard/total progress")
        XCTAssertFalse(app.any("timeline-row-sng_1").exists,
                       "song rows do not appear in the albums grain")
    }

    /// CUE POINTS, end to end: name one, see it in the jump menu, jump to it, then delete it.
    @MainActor
    func testCuePointCanBeNamedJumpedToAndDeleted() {
        let app = openCollection()
        app.segment("Songs").tap()
        XCTAssertTrue(app.any("timeline-row-sng_6").waitForExistence(timeout: 20))

        app.el("timeline-cues").tap()
        XCTAssertTrue(app.el("timeline-cue-add").waitForExistence(timeout: 10))
        app.el("timeline-cue-add").tap()

        let field = app.textFields["timeline-cue-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the new-cue sheet should be up")
        field.tap()
        field.typeText("The vinyl binge")
        app.el("timeline-cue-save").tap()

        // It is now in the jump menu, named. A menu ITEM is a Button, so its name lives in the
        // button's label — not in a `staticTexts` query (`textContaining`).
        app.el("timeline-cues").tap()
        let jumpItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "The vinyl binge")).firstMatch
        XCTAssertTrue(jumpItem.waitForExistence(timeout: 10),
                      "a saved cue shows in the jump menu by name")

        // Jumping is a real action — the stream stays rendered afterwards.
        jumpItem.tap()
        XCTAssertTrue(app.any("timeline-progress").waitForExistence(timeout: 10))

        // …and it can be removed again.
        app.el("timeline-cues").tap()
        XCTAssertTrue(app.el("timeline-cue-edit").waitForExistence(timeout: 10))
        app.el("timeline-cue-edit").tap()
        let row = app.staticTexts["The vinyl binge"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the editor lists the cue")
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 3), "the cue is gone")
    }

    /// Switching back to Activity restores the default view intact — the timeline is a mode, not a
    /// replacement.
    @MainActor
    func testSwitchingBackToActivityRestoresTheFeed() {
        let app = openCollection()
        app.segment("Songs").tap()
        XCTAssertTrue(app.el("timeline-order").waitForExistence(timeout: 20))
        app.segment("Activity").tap()
        XCTAssertTrue(app.any("activity-row").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.el("timeline-order").exists)
    }

    #endif
}
