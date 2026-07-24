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

    /// Switch to sub-tab `index` (0 Samples … 4 Cues, 5 Demuxer, 6 Tracks) by a COORDINATE tap on
    /// the segment's horizontal centre. On iPhone-portrait (compact) the segments are symbol-only
    /// and carry no individual a11y id/label to address, so a positional tap is the robust
    /// cross-width driver. `count` MUST track `StudioSubTab.allCases.count`.
    private func switchTab(_ index: Int, count: Int = 7) {
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
        XCTAssertTrue(app.el("sample-record-mic").waitForExistence(timeout: 10),
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
        // Demuxer (5)
        switchTab(5)
        XCTAssertTrue(app.any("demux-source-search").waitForExistence(timeout: 10),
                      "Demuxer sub-tab should show the source picker's search field")
        XCTAssertTrue(app.any("demux-import").waitForExistence(timeout: 4),
                      "Demuxer source picker should offer the Import entry point")
        // Tracks (6) — the multitrack arranger. Its header arrangement menu is always present.
        switchTab(6)
        XCTAssertTrue(app.any("tracks-arrangement-menu").waitForExistence(timeout: 10),
                      "Tracks sub-tab should show the arrangement menu")
        // Back to Samples — the picker round-trips.
        switchTab(0)
        XCTAssertTrue(app.el("sample-record-mic").waitForExistence(timeout: 10))
        snap("sub-tab-switching")
        #endif
    }

    // MARK: - (2b) Tracks (multitrack arranger — Stage A)

    /// The arranger bootstraps an empty "Arrangement 1", so the empty state offers "Add a track";
    /// adding one reveals a track lane with its mix strip (mute/solo/gain) + row menu, and the
    /// header "＋ Track" adds more.
    func testTracksArrangerAddDeleteTracks() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — arranger flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(6)
        // Arranger identity: the arrangement menu is always present.
        XCTAssertTrue(app.any("tracks-arrangement-menu").waitForExistence(timeout: 15),
                      "the arranger should show its arrangement menu")
        // Empty state → add the first track. (The empty-state container must NOT carry its own
        // accessibilityIdentifier — a container id promotes the VStack to a single element and
        // swallows this button's id; the XCUITest DisclosureGroup/container-id lesson, again.)
        let emptyAdd = app.any("tracks-empty-add-track")
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 10), "empty arrangement offers Add a track")
        emptyAdd.tap()
        // A lane appears with its mix strip (addressed via leaf ids — the lane card carries no
        // container id, see the view comment).
        XCTAssertTrue(app.any("tracks-track-name-0").waitForExistence(timeout: 10),
                      "adding a track should reveal its lane")
        XCTAssertTrue(app.any("tracks-track-mute-0").exists, "lane should have a mute button")
        XCTAssertTrue(app.any("tracks-track-solo-0").exists, "lane should have a solo button")
        // Header "＋ Track" adds a second lane.
        app.any("tracks-add-track").tap()
        XCTAssertTrue(app.any("tracks-track-name-1").waitForExistence(timeout: 10),
                      "the header add-track should append a second lane")
        // Mute toggles live.
        app.any("tracks-track-mute-0").tap()
        snap("tracks-arranger")
        // Delete the second track via its row menu.
        app.any("tracks-track-menu-1").tap()
        let del = app.buttons["Delete"]
        if del.waitForExistence(timeout: 5) { del.tap() }
        XCTAssertFalse(app.any("tracks-track-name-1").waitForExistence(timeout: 3),
                       "deleting a lane should remove it")
        #endif
    }

    /// Stage B: add a clip from a studio source. Open a track's add-clip picker, expand the Samples
    /// group (collapsed by default), pick the seeded sample → it bakes an immutable snapshot and a
    /// clip block appears on the lane.
    func testTracksAddClipFromSource() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — arranger flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(6)
        // Add a track, then open its add-clip picker.
        let emptyAdd = app.any("tracks-empty-add-track")
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 15))
        emptyAdd.tap()
        XCTAssertTrue(app.any("tracks-add-clip-0").waitForExistence(timeout: 10))
        app.any("tracks-add-clip-0").tap()
        // Picker lists sources directly; pick the seeded sample.
        let item = app.any("clip-picker-item-smp_fixture")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "picker should list the seeded sample")
        item.tap()
        // The bake completes and a clip block lands on the lane.
        XCTAssertTrue(app.any("tracks-clip-0-0").waitForExistence(timeout: 20),
                      "the baked clip block should appear on the lane")
        snap("tracks-clip-added")
        #endif
    }

    /// Stage C: synced playback. After baking a clip, Play starts the multitrack engine (the play
    /// button's a11y value flips to "playing" — which only happens when `play()` decoded a clip and
    /// started the graph), and Stop returns it to "stopped".
    func testTracksPlaybackStartsAndStops() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — arranger flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(6)
        let emptyAdd = app.any("tracks-empty-add-track")
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 15)); emptyAdd.tap()
        app.any("tracks-add-clip-0").tap()
        let item = app.any("clip-picker-item-smp_fixture")
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
        XCTAssertTrue(app.any("tracks-clip-0-0").waitForExistence(timeout: 20))
        // Play → the engine starts (value flips to "playing" only when a clip decoded + started).
        let play = app.any("tracks-play")
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'playing'"), evaluatedWith: play)], timeout: 10)
        snap("tracks-playing")
        // Stop (my tap or the auto-stop at the clip's end) returns it to "stopped".
        play.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'stopped'"), evaluatedWith: play)], timeout: 10)
        #endif
    }

    // MARK: - (3) Samples

    func testSamplesSeededRowAndCreationControls() throws {
        #if os(macOS)
        throw XCTSkip("macOS: existence smoke only — samples flows exercised on iOS")
        #else
        launchPerformance()
        switchTab(0)
        // Creation entry points (in-content, never toolbar-only). "From track" now lives inside
        // the import (⤓) menu rather than as a standalone button.
        XCTAssertTrue(app.el("sample-record-mic").waitForExistence(timeout: 15))
        XCTAssertTrue(app.any("sample-add-menu").exists, "the import menu (now holds From track)")
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

    /// F9 — folder create + move end-to-end through the UI. Uses the sample's Move submenu
    /// "New folder…" path (creates the folder AND files this sample into it in one action,
    /// so no dynamic folder id needs predicting), then asserts the folder renders with the
    /// sample under it. Proves the new folder wiring is live, not just the store logic.
    func testSampleFolderCreateAndMove() throws {
        #if os(macOS)
        throw XCTSkip("macOS: alert/menu folder flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(0)
        let row = app.any("sample-row-smp_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "seeded sample should start in Unfiled")
        snap("f9-samples-unfiled")

        // Long-press → row context menu → Move to folder submenu → New folder…
        row.press(forDuration: 1.2)
        let moveMenu = app.any("sample-move-smp_fixture")
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 5), "row menu should offer Move to folder")
        moveMenu.tap()
        let newInSubmenu = app.any("move-to-new-smp_fixture")
        XCTAssertTrue(newInSubmenu.waitForExistence(timeout: 5), "submenu should offer New folder…")
        newInSubmenu.tap()

        // New-folder alert → name it → Create (also files smp_fixture into the new folder).
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "New folder alert should show a name field")
        field.tap()
        field.typeText("Roadtrip")
        app.alerts.buttons["Create"].tap()

        // The folder appears (default-expanded) with the moved sample under it.
        XCTAssertTrue(app.staticTexts["Roadtrip"].waitForExistence(timeout: 8),
                      "the new folder should render in the samples list")
        XCTAssertTrue(app.any("sample-row-smp_fixture").waitForExistence(timeout: 5),
                      "the moved sample should be visible under the new folder")
        snap("f9-sample-in-folder")
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
        XCTAssertTrue(app.el("score-mode-select").waitForExistence(timeout: 5), "the mode toolbar")
        // Select mode: tap the staff to place/select a note (selection becomes non-empty).
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the first score page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        snap("score-editor")
        // Edit mode: Delete acts on the selection.
        app.el("score-mode-edit").tap()
        let del = app.el("score-delete")
        XCTAssertTrue(del.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: del)],
             timeout: 5)                               // the placed/selected note is deletable
        del.tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: del)],
             timeout: 5)                               // nothing selected ⇒ Delete disabled
        #endif
    }

    /// I1: multi-step Undo. Starts disabled, enables after an edit, and walks the whole
    /// session back to disabled. (Undo lives on the shared ScoreEditorView, so this also
    /// covers the live staff.)
    func testScoreUndoWalksEditsBack() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)                                   // Instruments
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8))
        takeRow.tap()
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        let undo = app.el("score-undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is in the mode toolbar")
        XCTAssertFalse(undo.isEnabled, "Undo is disabled before any edit")
        // Select a spot (places or selects a note), then in Edit mode set a length — a guaranteed
        // commit whichever the tap did.
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        app.el("score-mode-edit").tap()
        app.el("score-length-1").tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: undo)],
             timeout: 5)                               // an edit was committed ⇒ Undo enables
        snap("score-undo-enabled")
        // Undo the whole session ⇒ the stack empties and Undo disables again.
        var taps = 0
        while undo.isEnabled && taps < 10 { undo.tap(); taps += 1 }
        XCTAssertGreaterThan(taps, 0)
        XCTAssertFalse(undo.isEnabled, "Undo walks the session back, then disables")
        #endif
    }

    /// I1: Cancel discards the edit session and exits edit mode (the toolbar + Cancel vanish).
    /// The restore-to-pre-edit correctness is covered at the store level (StudioStoreTests).
    func testScoreCancelExitsEditMode() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8))
        takeRow.tap()
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        let toolbar = app.el("score-mode-select")
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "the mode toolbar")
        let cancel = app.el("score-cancel")
        XCTAssertTrue(cancel.exists, "Cancel appears while editing")
        // Make an edit, then Cancel → editing ends (toolbar + Cancel disappear).
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        cancel.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: toolbar)],
             timeout: 5)
        XCTAssertFalse(cancel.exists, "Cancel is hidden once editing ends")
        XCTAssertTrue(app.el("score-edit").exists, "back to the Edit affordance")
        #endif
    }

    /// I2: the three score-editor modes expose their tools — Select places/selects, Move shows
    /// enabled ±steppers + Duplicate over a selection (and a nudge commits), Edit shows
    /// length/accidental + Delete.
    func testScoreEditorModesExposeTools() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8))
        takeRow.tap()
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        // Select mode: place/select a note so there's a selection to move.
        XCTAssertTrue(app.el("score-mode-select").waitForExistence(timeout: 5))
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
        // Move mode: steppers + Duplicate are enabled with a selection; a nudge commits.
        app.el("score-mode-move").tap()
        let up = app.el("score-move-up")
        XCTAssertTrue(up.waitForExistence(timeout: 5), "the Move ♯ stepper")
        XCTAssertTrue(up.isEnabled, "Move enabled with a selection")
        XCTAssertTrue(app.el("score-duplicate").isEnabled, "Duplicate enabled with a selection")
        up.tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"),
                               evaluatedWith: app.el("score-undo"))], timeout: 5)   // the nudge committed
        // Edit mode: length + delete are present.
        app.el("score-mode-edit").tap()
        XCTAssertTrue(app.el("score-length-4").waitForExistence(timeout: 5), "Edit shows length chips")
        XCTAssertTrue(app.el("score-delete").isEnabled, "Delete enabled with a selection")
        #endif
    }

    /// Enter vs Select split: ENTER (the default) places a note on tap (commits ⇒ Undo enables);
    /// SELECT snaps a tap to the nearest note (selection ⇒ Edit's Delete enables).
    func testScoreEnterAndSelectModes() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8))
        takeRow.tap()
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        XCTAssertTrue(app.el("score-mode-enter").waitForExistence(timeout: 5), "Enter mode (default)")
        XCTAssertTrue(app.el("score-mode-select").exists, "Select mode")
        let undo = app.el("score-undo")
        XCTAssertFalse(undo.isEnabled, "Undo disabled before any edit")
        // Enter (default): a tap places a note ⇒ committed edit ⇒ Undo enables.
        let page = app.any("score-page-0")
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: undo)],
             timeout: 5)
        // Select: clear, then RE-ENTER Select — the cursor defaults to (auto-selects) the last
        // note, so Edit can act on it (deterministic — no reliance on tap-hit geometry).
        app.el("score-mode-select").tap()
        if app.el("score-deselect").exists { app.el("score-deselect").tap() }
        app.el("score-mode-enter").tap()
        app.el("score-mode-select").tap()
        app.el("score-mode-edit").tap()
        let del = app.el("score-delete")
        XCTAssertTrue(del.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: del)],
             timeout: 5)                               // the default-cursor selection is deletable
        #endif
    }

    /// SELECT cursor + bars: entering Select auto-selects the LAST note (default cursor); ◀ / ▶
    /// arrows exist under the switcher; Add-bar enables Remove-bar (an empty trailing bar), and
    /// Remove-bar clears it again.
    func testScoreSelectCursorAndBars() throws {
        #if os(macOS)
        throw XCTSkip("macOS: score edit flow exercised on iOS")
        #else
        launchPerformance()
        switchTab(3)
        let takesOpen = app.el("takes-open")
        XCTAssertTrue(takesOpen.waitForExistence(timeout: 15))
        takesOpen.tap()
        let takeRow = app.any("take-row-tk_fixture")
        XCTAssertTrue(takeRow.waitForExistence(timeout: 8))
        takeRow.tap()
        let edit = app.el("score-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        // Switch to Select: the cursor defaults to the last note (auto-selected) and the ◀ / ▶
        // arrows appear under the switcher.
        app.el("score-mode-select").tap()
        XCTAssertTrue(app.el("score-cursor-prev").waitForExistence(timeout: 5), "◀ cursor arrow")
        XCTAssertTrue(app.el("score-cursor-next").exists, "▶ cursor arrow")
        // Default selection = the last note ⇒ Edit's Delete is enabled.
        app.el("score-mode-edit").tap()
        XCTAssertTrue(app.el("score-delete").isEnabled, "the last note is the default cursor selection")
        // Cursor navigation (toolbar ◀ / ▶) keeps a selection to edit and doesn't crash.
        app.el("score-mode-select").tap()
        app.el("score-cursor-prev").tap()
        app.el("score-cursor-next").tap()
        app.el("score-mode-edit").tap()
        XCTAssertTrue(app.el("score-delete").isEnabled, "cursor navigation keeps a note selected")
        // (The ＋ / − bar controls render on the last bar's corners in Select mode — verified on
        // device; XCUITest can't reliably address canvas-positioned buttons by id.)
        #endif
    }

    /// I3: the Instruments MIDI section shows a Connect-Bluetooth-MIDI button (iOS/iPadOS). The
    /// pairing sheet itself needs a real Bluetooth radio, so this only asserts the affordance.
    func testInstrumentsBluetoothMIDIButton() throws {
        #if os(macOS)
        throw XCTSkip("Bluetooth MIDI picker is iOS-only (macOS pairs in Audio MIDI Setup)")
        #else
        launchPerformance()
        switchTab(3)                                   // Instruments
        XCTAssertTrue(reveal(app.el("midi-connect-bluetooth")),
                      "the Connect Bluetooth MIDI button (scroll to the MIDI section)")
        // Deliberately not tapped — pairing needs a physical Bluetooth radio (device-only).
        #endif
    }

    // MARK: - (B6) Built-in mixer deck — SAMP + SEQ3

    /// SAMP: opening a sample's editor shows the built-in MIXER DECK — the deck-styled tempo/pitch/
    /// gain, the compressor·reverb·delay·filter FX rack, and the live Loop capsule. No audio/DSP is
    /// exercised (device-only); this proves the surface renders and every control is addressable.
    func testSampleMixerDeckRenders() throws {
        #if os(macOS)
        throw XCTSkip("sample editor sheet exercised on iOS")
        #else
        launchPerformance()
        switchTab(0)                                   // Samples
        let row = app.any("sample-row-smp_fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded sample row")
        row.tap()                                      // a short tap opens the editor sheet
        XCTAssertTrue(reveal(app.any("sample-deck-tempo")), "deck tempo control")
        XCTAssertTrue(app.any("sample-deck-comp").exists, "deck compressor (new FX)")
        XCTAssertTrue(app.any("sample-deck-filter").exists, "deck filter (new FX)")
        XCTAssertTrue(app.any("sample-deck-gain").exists, "deck gain (SAMP shows gain)")
        XCTAssertTrue(app.el("sample-deck-loop").exists, "the live Loop capsule")
        snap("sample-mixer-deck")
        #endif
    }

    /// SEQ3: a sequencer SAMPLE row carries a collapsible per-track mixer deck. Expanding it reveals
    /// the same StudioMixerDeck (tempo/pitch/FX that BAKE on the next Play) — but WITHOUT gain or the
    /// looper (the row's live gain is the header chip; looping is the pattern's job).
    func testSequencerRowMixerDeck() throws {
        #if os(macOS)
        throw XCTSkip("sequencer row deck exercised on iOS")
        #else
        launchPerformance()
        switchTab(2)                                   // Sequencer
        let pattern = app.el("seq-pattern-ptn_fixture")
        XCTAssertTrue(pattern.waitForExistence(timeout: 15), "the seeded pattern")
        pattern.tap()
        let disclosure = app.any("seq-row-deck-0")
        XCTAssertTrue(reveal(disclosure), "the row's Mixer-deck disclosure")
        disclosure.tap()                               // expand
        XCTAssertTrue(reveal(app.any("seq-deck-0-tempo")), "per-row deck tempo appears when expanded")
        XCTAssertTrue(app.any("seq-deck-0-comp").exists, "per-row deck compressor")
        XCTAssertFalse(app.any("seq-deck-0-gain").exists, "per-row deck hides gain (row has a live gain chip)")
        XCTAssertFalse(app.el("seq-deck-0-loop").exists, "per-row deck hides the looper")
        snap("seq-row-mixer-deck")
        #endif
    }

    /// SEQ1: tapping a sequencer row header solo-previews just that row — the engine solos it
    /// (`soloedRow`), and the header's a11y label flips Preview → Stop; re-tapping stops.
    func testSequencerRowHeaderSoloPreview() throws {
        #if os(macOS)
        throw XCTSkip("sequencer audio solo exercised on iOS")
        #else
        launchPerformance()
        switchTab(2)                                   // Sequencer
        let pattern = app.el("seq-pattern-ptn_fixture")
        XCTAssertTrue(pattern.waitForExistence(timeout: 15), "the seeded pattern")
        pattern.tap()
        let solo = app.el("seq-row-solo-0")
        XCTAssertTrue(solo.waitForExistence(timeout: 10), "the row header (solo affordance)")
        XCTAssertFalse((solo.label).contains("Stop"), "starts in the Preview state")
        // Solo-preview → engine.soloedRow == 0, header flips to Stop.
        solo.tap()
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Stop'"), evaluatedWith: solo)],
             timeout: 10)
        snap("seq-row-solo")
        // Re-tap the soloing row ⇒ stop (back to Preview).
        solo.tap()
        wait(for: [expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Stop')"), evaluatedWith: solo)],
             timeout: 10)
        #endif
    }

    /// SEQ2: the Live-edits toggle is present on an opened pattern and flips.
    func testSequencerLiveToggleFlips() throws {
        #if os(macOS)
        throw XCTSkip("sequencer live toggle exercised on iOS")
        #else
        launchPerformance()
        switchTab(2)
        let pattern = app.el("seq-pattern-ptn_fixture")
        XCTAssertTrue(pattern.waitForExistence(timeout: 15))
        pattern.tap()
        let toggle = app.any("seq-live-toggle")      // button-style Toggle: reported as a Switch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Live-edits toggle")
        // @AppStorage persists across sim runs, so assert a FLIP from the current value, not a
        // fixed target (the NowPlayingUITests np-history doctrine).
        let before = (toggle.value as? String) ?? "0"
        toggle.tap()
        let want = before == "1" ? "0" : "1"
        wait(for: [expectation(for: NSPredicate(format: "value == %@", want),
                               evaluatedWith: toggle)], timeout: 3)   // flips Live ⇄ Static
        #endif
    }

    /// SEQ4: growing a pattern's length adds a second bar of steps (16 → 32).
    func testSequencerLengthGrowsAddsSteps() throws {
        #if os(macOS)
        throw XCTSkip("sequencer length exercised on iOS")
        #else
        launchPerformance()
        switchTab(2)
        let pattern = app.el("seq-pattern-ptn_fixture")
        XCTAssertTrue(pattern.waitForExistence(timeout: 15))
        pattern.tap()
        XCTAssertTrue(app.el("seq-step-0-15").waitForExistence(timeout: 10), "a 16-step row")
        XCTAssertFalse(app.el("seq-step-0-16").exists, "no 17th step yet")
        let stepper = app.steppers["seq-length-stepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "the length stepper")
        stepper.buttons.element(boundBy: 1).tap()    // [0]=decrement, [1]=increment
        XCTAssertTrue(app.el("seq-step-0-16").waitForExistence(timeout: 5),
                      "growing by a bar added steps 16+")
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
