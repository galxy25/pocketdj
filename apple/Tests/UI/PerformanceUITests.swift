import XCTest

/// XCUITests for the Performance ("Studio") tab — samples, loops, sequencer, instruments,
/// cues — and the Settings ▸ Storage studio sections (spec §1/§3/§9/§11).
///
/// Every test launches against the bundled fixture catalog (`PDJ_USE_FIXTURE`) with the studio
/// document seeded (`PDJ_SEED_STUDIO` → smp_fixture / lp_fixture / ptn_fixture + cue slots 0/1
/// on sng_1) and lands straight on the tab (`PDJ_START_SECTION=Performance`).
///
/// Platform split (the NowPlaying/Storage/Collections convention): iOS drives the real flows
/// (the segmented sub-tab picker is only tappable there); macOS UI automation is unavailable
/// headless, so macOS runs an EXISTENCE SMOKE only — the tab + its picker exist, and the ⌘1…⌘5
/// sub-tab shortcuts are documented (they ride hidden shadow buttons `studio-tab-<name>-shadow`
/// that would be driven via `typeKey("1", modifierFlags: .command)`, exactly like the Browse
/// `selectKind` helper in XCUIHelpers). Deep flows are `#if !os(macOS)` (XCTSkip on macOS).
final class PerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }
    // Terminate between tests so each gets a clean, freshly-seeded launch — back-to-back
    // relaunches in one class otherwise race a lingering prior instance (the SetlistUITests
    // first-tap flake).
    override func tearDown() { app?.terminate(); app = nil }

    // MARK: - Launch

    /// Launch onto the Performance tab with the studio fixture seeded.
    @discardableResult
    private func launchPerformance() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_STUDIO"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Performance"
        app.launch()
        self.app = app
        return app
    }

    /// Launch onto Settings (for the Storage sections), studio still seeded so the usage rows
    /// report the seeded 1 sample / 1 loop / 1 sequence.
    @discardableResult
    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_USE_FIXTURE"] = "1"
        app.launchEnvironment["PDJ_SEED_STUDIO"] = "1"
        app.launchEnvironment["PDJ_START_SECTION"] = "Settings"
        app.launch()
        self.app = app
        return app
    }

    // MARK: - Helpers

    /// The one segmented sub-tab picker (`studio-tab-picker`) on the Performance shell.
    private func studioPicker() -> XCUIElement {
        let seg = app.segmentedControls.firstMatch
        if seg.waitForExistence(timeout: 8) { return seg }
        return app.any("studio-tab-picker")
    }

    /// Switch to sub-tab `index` (0 Samples … 4 Cues) by a COORDINATE tap on the segment's
    /// horizontal centre. On iPhone-portrait (compact) the segments are symbol-only and carry no
    /// individual a11y id/label to address, so a positional tap is the robust cross-width driver.
    private func switchTab(_ index: Int, count: Int = 5) {
        let picker = studioPicker()
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "the studio sub-tab picker must exist")
        let dx = (Double(index) + 0.5) / Double(count)
        picker.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
    }

    /// Scroll `element` into the tree (SwiftUI ScrollView/Form/List are lazy → off-screen rows
    /// aren't present until scrolled). Mirrors StorageUITests.reveal.
    @discardableResult
    private func reveal(_ element: XCUIElement, tries: Int = 12) -> Bool {
        var n = 0
        while !element.exists && n < tries {
            scrollDown()
            n += 1
        }
        return element.exists
    }

    private func scrollDown() {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        #else
        app.swipeUp()
        #endif
    }

    /// Attach a proof screenshot to the result bundle.
    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - (1) Tab + picker exist (ALL platforms — the macOS smoke)

    func testPerformanceTabAndPickerExist() {
        launchPerformance()
        // The picker IS the tab's identity: it only mounts inside PerformanceView.
        XCTAssertTrue(app.any("studio-tab-picker").waitForExistence(timeout: 20),
                      "the Performance tab and its sub-tab picker must exist")
        snap("performance-tab")
    }

    // MARK: - (2) Sub-tab switching through all five

    func testSubTabSwitching() throws {
        launchPerformance()
        XCTAssertTrue(app.any("studio-tab-picker").waitForExistence(timeout: 20))

        #if os(macOS)
        // macOS existence smoke ONLY (UI automation is unavailable headless). The switching
        // path on macOS is the ⌘1…⌘5 shortcuts — hidden shadow buttons `studio-tab-<name>-shadow`
        // driven via `app.typeKey("1", modifierFlags: .command)` (the XCUIHelpers.selectKind
        // pattern). We assert the picker exists; the shortcut shadow buttons carry the same
        // guarantee the Browse suite relies on.
        throw XCTSkip("macOS: existence smoke only — sub-tab switching is exercised on iOS")
        #else
        // Distinctive seeded/leaf element per sub-tab (index = declaration order in StudioSubTab).
        // Samples (0)
        switchTab(0)
        XCTAssertTrue(app.el("sample-new-from-track").waitForExistence(timeout: 10),
                      "Samples sub-tab should show the creation bar")
        // Loops (1)
        switchTab(1)
        XCTAssertTrue(app.el("loop-audition-lp_fixture").waitForExistence(timeout: 10)
                      || app.staticTexts["Seeded Loop"].waitForExistence(timeout: 2),
                      "Loops sub-tab should show the seeded loop")
        // Sequencer (2)
        switchTab(2)
        XCTAssertTrue(app.el("seq-pattern-ptn_fixture").waitForExistence(timeout: 10)
                      || app.staticTexts["Seeded Pattern"].waitForExistence(timeout: 2),
                      "Sequencer sub-tab should list the seeded pattern")
        // Instruments (3)
        switchTab(3)
        XCTAssertTrue(app.el("instrument-piano").waitForExistence(timeout: 10),
                      "Instruments sub-tab should show the instrument chips")
        // Cues (4)
        switchTab(4)
        XCTAssertTrue(app.textFields["cue-search"].waitForExistence(timeout: 10)
                      || app.any("cue-search").waitForExistence(timeout: 2),
                      "Cues sub-tab should show the track-search field")
        // Back to Samples — the picker round-trips.
        switchTab(0)
        XCTAssertTrue(app.el("sample-new-from-track").waitForExistence(timeout: 10))
        snap("sub-tab-switching")
        #endif
    }

    // MARK: - (3) Samples

    func testSamplesSeededRowAndCreationControls() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — samples flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(0)
        // Creation entry points (in-content, never toolbar-only).
        XCTAssertTrue(app.el("sample-new-from-track").waitForExistence(timeout: 15))
        XCTAssertTrue(app.el("sample-record-mic").exists)
        // The seeded sample row + its name.
        XCTAssertTrue(app.any("sample-row-smp_fixture").waitForExistence(timeout: 10),
                      "the seeded sample row must be visible")
        XCTAssertTrue(app.staticTexts["Seeded Sample"].exists)
        snap("samples-seeded")
        #endif
    }

    func testSampleRenameFlow() throws {
        #if os(macOS)
        throw XCTSkip("macOS: alert/keyboard rename path isn't reliably drivable headless")
        #else
        launchPerformance()
        switchTab(0)
        let row = app.any("sample-row-smp_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        // Long-press opens the row context menu (a short tap would open the editor sheet).
        row.press(forDuration: 1.2)
        let rename = app.el("sample-rename-smp_fixture")
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "context menu should offer Rename")
        rename.tap()
        // The rename alert pre-fills the current name — append and Save (the PlaylistsView
        // rename precedent: pre-filled field + typed suffix).
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" Edited")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Seeded Sample Edited"].waitForExistence(timeout: 8),
                      "the renamed sample should show its new name")
        snap("sample-renamed")
        #endif
    }

    func testSliceEditorAutoSliceAndPad() throws {
        #if os(macOS)
        throw XCTSkip("macOS: sheet/slice flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(0)
        let row = app.any("sample-row-smp_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()                                   // opens the sample editor sheet
        // The Slice-into-pads entry is near the bottom of the editor — scroll it into view.
        let sliceEntry = app.el("sample-slice")
        XCTAssertTrue(sliceEntry.waitForExistence(timeout: 8))
        if !sliceEntry.isHittable { app.scrollViews.firstMatch.swipeUp() }
        sliceEntry.tap()
        // Auto-slice → pads populate; tapping a pad auditions it (must not crash).
        let auto = app.el("slice-auto")
        XCTAssertTrue(auto.waitForExistence(timeout: 8), "slice editor should show Auto-slice")
        auto.tap()
        let pad0 = app.el("slice-pad-0")
        XCTAssertTrue(pad0.waitForExistence(timeout: 5), "auto-slice should populate pad 0")
        snap("slice-editor")
        pad0.tap()
        XCTAssertTrue(app.el("slice-send-sequencer").waitForExistence(timeout: 3),
                      "the bake-to-sequencer action should be present with pads")
        #endif
    }

    func testScoreEditorPlacesAndDeletesANote() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)                                   // Instruments
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8), "the seeded take should be listed")
        takeRow.tap()
        // Score screen → enter edit mode.
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "score screen with an Edit control")
        edit.tap()
        XCTAssertTrue(app.el("score-length-4").waitForExistence(timeout: 5), "the edit toolbar")
        let del = app.el("score-delete")
        XCTAssertFalse(del.isEnabled, "Delete is disabled until a note is selected")
        // Pick flat + a half note, then tap the staff to place a note (selects it ⇒ Delete enables).
        app.el("score-acc-flat").tap()
        app.el("score-length-2").tap()
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the first score page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: del)],
             timeout: 5)                               // placing selected the new note
        snap("score-editor")
        // Delete removes it → Delete disabled again.
        del.tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: del)],
             timeout: 5)
        #endif
    }

    func testLiveStaffSectionPresent() throws {
        #if os(macOS)
        throw XCTSkip("macOS: Instruments live-staff exercised on iOS")
        #else
        // The live staff renders in the Instruments tab (its fill-from-play + edit path is covered
        // by InstrumentLiveLogTests — XCUITest can't reliably drive the keys' min-distance-0 drag).
        launchPerformance()
        switchTab(3)                                   // Instruments
        let staff = app.any("live-staff")
        XCTAssertTrue(staff.waitForExistence(timeout: 15), "the live score section should be present")
        snap("live-staff")
        #endif
    }

    // MARK: - (4) Loops

    func testLoopsSeededRowAndSliceChips() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — loop flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(1)
        // Seeded loop row (name text + its audition toggle).
        XCTAssertTrue(app.el("loop-audition-lp_fixture").waitForExistence(timeout: 15)
                      || app.staticTexts["Seeded Loop"].waitForExistence(timeout: 3),
                      "the seeded loop must be visible")
        // The beat-window slice chips live in the New-loop builder (the seeded sample is
        // pre-selected, so the grid-backed chips render). Scroll them into the lazy List.
        let oneChip = app.el("loop-slice-1")
        XCTAssertTrue(reveal(oneChip), "slice chips (½ 1 2 4 8 16 32) should be present")
        XCTAssertTrue(app.el("loop-slice-0.5").exists, "the ½-beat chip uses the '0.5' id token")
        XCTAssertTrue(app.el("loop-slice-8").exists)
        XCTAssertTrue(app.el("loop-slice-32").exists)
        snap("loops-slices")
        #endif
    }

    // MARK: - (5) Sequencer

    func testSequencerOpenPatternAndToggleStep() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — sequencer flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(2)
        // Seeded pattern in the list; open it.
        let patternRow = app.el("seq-pattern-ptn_fixture")
        XCTAssertTrue(patternRow.waitForExistence(timeout: 15), "the seeded pattern must be listed")
        XCTAssertTrue(app.staticTexts["Seeded Pattern"].exists)
        patternRow.tap()
        // The editor: Play exists (do NOT tap — no audio assertions), step grid present.
        XCTAssertTrue(app.el("seq-play").waitForExistence(timeout: 10),
                      "the pattern editor should show a Play control")
        let step = app.el("seq-step-0-0")
        XCTAssertTrue(step.waitForExistence(timeout: 8), "the 16-step grid should be present")
        // Seeded pattern lights steps 0/4/8/12, so step 0 starts ON. Toggling flips it off.
        XCTAssertTrue(step.isSelected, "seeded step 0-0 starts on")
        step.tap()
        expectation(for: NSPredicate(format: "isSelected == false"), evaluatedWith: step)
        waitForExpectations(timeout: 5)
        snap("sequencer-editor")
        #endif
    }

    // MARK: - (6) Instruments (offline-safe: no download taps)

    func testInstrumentsChipsAndPacks() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — instrument flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)
        // The seven instrument chips (leaf ids `instrument-<key>`) — deterministic, network-free.
        XCTAssertTrue(app.el("instrument-piano").waitForExistence(timeout: 15))
        XCTAssertTrue(app.el("instrument-violin").exists)
        XCTAssertTrue(app.el("instrument-harp").exists)
        // Sound-packs section: scroll it into the ScrollView (below the keys). The pack ROWS come
        // from the S3 manifest (offline-first) — so accept either the rows OR the offline
        // fallback (loading/retry), and NEVER tap a download.
        let packsHeader = app.staticTexts["Sound packs"]
        XCTAssertTrue(reveal(packsHeader), "the Sound packs section header should be present")
        let aPackRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pack-download-'"
                                  + " OR identifier BEGINSWITH 'pack-delete-'")).firstMatch
        let packsPresent = aPackRow.exists
            || app.el("packs-refresh").exists
            || app.staticTexts["Loading pack index…"].exists
            || app.staticTexts["Couldn't load the pack index."].exists
        XCTAssertTrue(packsPresent, "pack rows (or the offline loading/retry fallback) should show")
        snap("instruments-packs")
        // The on-screen keyboard's octave-jump controls (`<` / `>`) flank the keys at the very
        // bottom of the scroll — reveal + assert both exist.
        XCTAssertTrue(reveal(app.el("piano-octave-up")), "the octave-up (>) keyboard control should exist")
        XCTAssertTrue(app.el("piano-octave-down").exists, "the octave-down (<) keyboard control should exist")
        #endif
    }

    // MARK: - (7) Cues

    func testCuesSeededSlots() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — cue flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(4)
        // Search to reach the seeded track (the empty-query default is the ContentUnavailable
        // empty state; the track list only shows for a non-empty query). sng_1 = "Neon".
        let search = app.textFields["cue-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "the cue track-search field must exist")
        search.tap()
        search.typeText("neon")
        let trackRow = app.el("cue-track-row-sng_1")
        XCTAssertTrue(trackRow.waitForExistence(timeout: 8), "the seeded cued track should match")
        trackRow.tap()
        // Selected pane: seeded slots 0/1 filled (Intro/Drop), the rest empty. All share the
        // `cue-slot-<n>` id shape (filled and empty), so an empty slot exists at slot 2.
        XCTAssertTrue(app.el("cue-slot-0").waitForExistence(timeout: 8), "filled cue slot 0")
        XCTAssertTrue(app.el("cue-slot-1").exists, "filled cue slot 1")
        XCTAssertTrue(app.el("cue-slot-2").exists, "an empty cue slot must exist")
        XCTAssertTrue(app.staticTexts["Intro"].exists, "slot 0's seeded name")
        XCTAssertTrue(app.staticTexts["Drop"].exists, "slot 1's seeded name")
        snap("cues-slots")
        #endif
    }

    // MARK: - (8) Storage ▸ studio sections

    func testStudioStorageSections() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — Storage studio sections exercised on iOS")
        #else
        launchSettings()
        // Settings → Storage (the single manager entry; scroll it into view first).
        XCTAssertTrue(app.buttons["settings-add-source"].waitForExistence(timeout: 15))
        let storage = app.buttons["settings-storage"].firstMatch
        XCTAssertTrue(reveal(storage), "the Storage entry must be on the Settings root")
        storage.tap()
        // Studio usage rows (one per family) — Text leaves, so query as static text.
        // Each row can sit below the fold in the long Storage form; `reveal` scrolls each into
        // the accessibility tree before asserting (bare `.exists` flakes on lazy Form rendering
        // once a row is off-screen — the `storage-usage-instruments` failure).
        XCTAssertTrue(reveal(app.staticTexts["storage-usage-samples"]),
                      "the per-family studio usage rows should be present")
        XCTAssertTrue(reveal(app.staticTexts["storage-usage-loops"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-usage-sequences"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-usage-takes"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-usage-instruments"]))
        snap("storage-studio-usage")
        // The three relocatable-family folder pickers.
        XCTAssertTrue(reveal(app.buttons["storage-samples-folder-choose"]),
                      "the samples folder picker should be present")
        XCTAssertTrue(reveal(app.buttons["storage-loops-folder-choose"]))
        XCTAssertTrue(reveal(app.buttons["storage-sequences-folder-choose"]))
        // The per-family delete buttons (do NOT confirm any delete).
        XCTAssertTrue(reveal(app.buttons["storage-delete-samples"]),
                      "the per-family delete buttons should be present")
        XCTAssertTrue(reveal(app.buttons["storage-delete-loops"]))
        XCTAssertTrue(reveal(app.buttons["storage-delete-sequences"]))
        XCTAssertTrue(reveal(app.buttons["storage-delete-takes"]))
        XCTAssertTrue(reveal(app.buttons["storage-delete-instruments"]))
        snap("storage-studio-delete")
        #endif
    }
}
