import XCTest
@testable import PocketDJ

/// Pure-model tests for the per-window multi-select state machine (⌘-click = range,
/// ⌥-click = toggle, ⇧-click = range alias, plain tap = navigate). Modifiers are
/// injected as parameters — `ModifierKeys.current()` itself stays untested glue.
@MainActor
final class RowSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]
    private let scope = "test-scope"

    private func tap(_ s: RowSelection, _ id: String,
                     _ mods: RowSelection.Modifiers = []) -> RowSelection.TapOutcome {
        s.handleTap(id: id, scope: scope, orderedIds: order, modifiers: mods)
    }

    func testOptionClickTogglesInAndOut() {
        let s = RowSelection()
        XCTAssertEqual(tap(s, "b", .option), .selection)
        XCTAssertEqual(s.ids, ["b"])
        XCTAssertEqual(tap(s, "b", .option), .selection)
        XCTAssertTrue(s.ids.isEmpty)
    }

    func testOptionClickSetsAnchorOnAdd() {
        let s = RowSelection()
        _ = tap(s, "c", .option)
        XCTAssertEqual(s.anchorId, "c")
        // Toggling it OFF clears the anchor (it was the anchor).
        _ = tap(s, "c", .option)
        XCTAssertNil(s.anchorId)
    }

    func testCommandClickWithoutAnchorSelectsSingleAndSetsAnchor() {
        let s = RowSelection()
        _ = tap(s, "d", .command)
        XCTAssertEqual(s.ids, ["d"])
        XCTAssertEqual(s.anchorId, "d")
    }

    func testCommandClickSelectsRangeFromAnchor() {
        let s = RowSelection()
        _ = tap(s, "b", .option)          // anchor b
        _ = tap(s, "e", .command)
        XCTAssertEqual(s.ids, ["b", "c", "d", "e"])
    }

    func testShiftClickSelectsRangeToo() {
        let s = RowSelection()
        _ = tap(s, "b", .option)
        _ = tap(s, "d", .shift)
        XCTAssertEqual(s.ids, ["b", "c", "d"])
    }

    func testRangeIsAdditiveToExistingSelection() {
        let s = RowSelection()
        _ = tap(s, "a", .option)          // {a}, anchor a
        _ = tap(s, "c", .option)          // {a,c}, anchor c
        _ = tap(s, "e", .command)         // + c…e
        XCTAssertEqual(s.ids, ["a", "c", "d", "e"])
    }

    func testReversedRangeWorks() {
        let s = RowSelection()
        _ = tap(s, "e", .option)          // anchor e
        _ = tap(s, "b", .command)
        XCTAssertEqual(s.ids, ["b", "c", "d", "e"])
    }

    func testAnchorMissingFromOrderFallsBackToSingle() {
        let s = RowSelection()
        _ = tap(s, "b", .option)          // anchor b
        // Range gesture against an order that no longer contains the anchor.
        _ = s.handleTap(id: "d", scope: scope, orderedIds: ["c", "d", "e"], modifiers: .command)
        XCTAssertEqual(s.ids, ["b", "d"])   // single-select fallback (b survives — additive)
        XCTAssertEqual(s.anchorId, "d")     // re-anchored
    }

    func testPlainTapNavigatesAndPreservesSelection() {
        let s = RowSelection()
        _ = tap(s, "a", .option)
        XCTAssertEqual(tap(s, "c"), .navigate)
        XCTAssertEqual(s.ids, ["a"])        // plain click preserves the selection (ruling 1)
    }

    func testSelectModePlainTapToggles() {
        let s = RowSelection()
        s.enterSelectMode(scope: scope, initial: "a")
        XCTAssertEqual(tap(s, "b"), .selection)
        XCTAssertEqual(s.ids, ["a", "b"])
        XCTAssertEqual(tap(s, "a"), .selection)
        XCTAssertEqual(s.ids, ["b"])
    }

    func testScopeSwitchClearsPreviousSelection() {
        let s = RowSelection()
        _ = tap(s, "a", .option)
        _ = s.handleTap(id: "x", scope: "other-scope", orderedIds: ["x", "y"], modifiers: .option)
        XCTAssertEqual(s.scopeId, "other-scope")
        XCTAssertEqual(s.ids, ["x"])        // old scope's ids gone
    }

    func testSelectAllUsesRegisteredProvider() {
        let s = RowSelection()
        s.registerActiveList(scope: scope, allIds: { ["a", "b", "c"] }, payload: { nil })
        s.selectAll()
        XCTAssertEqual(s.scopeId, scope)
        XCTAssertEqual(s.ids, ["a", "b", "c"])
    }

    func testCanCopyRequiresScopeMatchWithActiveList() {
        let s = RowSelection()
        _ = tap(s, "a", .option)            // selection in `scope`
        s.registerActiveList(scope: "other", allIds: { [] }, payload: { nil })
        XCTAssertFalse(s.canCopy)           // active list ≠ selection scope
        s.registerActiveList(scope: scope, allIds: { self.order }, payload: { nil })
        XCTAssertTrue(s.canCopy)
    }

    func testUnregisterOtherScopeKeepsActiveList() {
        let s = RowSelection()
        s.registerActiveList(scope: scope, allIds: { self.order }, payload: { nil })
        s.unregisterActiveList(scope: "someone-else")
        XCTAssertNotNil(s.activeList)
        s.unregisterActiveList(scope: scope)
        XCTAssertNil(s.activeList)
    }

    func testPayloadForRowFallsBackToSingleWhenRowUnselected() {
        let s = RowSelection()
        _ = tap(s, "a", .option)
        s.registerActiveList(scope: scope, allIds: { self.order },
                             payload: { SongTransfer(songIds: ["a"], text: nil) })
        let single = SongTransfer(songIds: ["z"], text: nil)
        // Unselected row drags itself…
        XCTAssertEqual(s.payloadForRow("z", scope: scope, single: single).songIds, ["z"])
        // …a selected row drags the whole selection.
        XCTAssertEqual(s.payloadForRow("a", scope: scope, single: single).songIds, ["a"])
    }

    func testPruneDropsMissingIdsAndAnchor() {
        let s = RowSelection()
        _ = tap(s, "a", .option)
        _ = tap(s, "b", .option)            // anchor b
        s.prune(validIds: ["a"])
        XCTAssertEqual(s.ids, ["a"])
        XCTAssertNil(s.anchorId)
    }

    func testClearAndExitResetsMode() {
        let s = RowSelection()
        s.enterSelectMode(scope: scope, initial: "a")
        s.clearAndExit()
        XCTAssertTrue(s.ids.isEmpty)
        XCTAssertNil(s.anchorId)
        XCTAssertFalse(s.selectMode)
        XCTAssertFalse(s.hasSelection)
    }

    // MARK: Select-mode scoping (the mode belongs to the list it was armed in)

    /// Select mode armed in one list must never swallow the navigation tap in ANOTHER list —
    /// the mode is invisible there (no bar, no badges), so a hijacked tap reads as "tapping
    /// does nothing". The armed list keeps its mode and its selection.
    func testSelectModeDoesNotHijackTapsInAnotherScope() {
        let s = RowSelection()
        s.enterSelectMode(scope: scope, initial: "a")
        XCTAssertEqual(s.handleTap(id: "x", scope: "pocket-1", orderedIds: ["x", "y"], modifiers: []),
                       .navigate)
        XCTAssertEqual(s.ids, ["a"])                 // the armed scope's selection survives
        XCTAssertEqual(s.scopeId, scope)
        XCTAssertEqual(tap(s, "b"), .selection)      // …and select mode still works there
        XCTAssertEqual(s.ids, ["a", "b"])
    }

    /// A deliberate modifier gesture in a DIFFERENT scope is a real scope switch — it takes
    /// the selection over and disarms the stale Select mode.
    func testModifierGestureInAnotherScopeExitsSelectMode() {
        let s = RowSelection()
        s.enterSelectMode(scope: scope, initial: "a")
        _ = s.handleTap(id: "x", scope: "other", orderedIds: ["x", "y"], modifiers: .option)
        XCTAssertFalse(s.selectMode)
        XCTAssertEqual(s.scopeId, "other")
        XCTAssertEqual(s.ids, ["x"])
    }

    /// The armed list leaving the screen disarms the mode (its bar/badges left with it);
    /// the selection ids themselves survive. Another list's unregister never disarms.
    func testUnregisterActiveListDisarmsSelectModeForThatScope() {
        let s = RowSelection()
        s.registerActiveList(scope: scope, allIds: { self.order }, payload: { nil })
        s.enterSelectMode(scope: scope, initial: "a")
        s.unregisterActiveList(scope: "someone-else")
        XCTAssertTrue(s.selectMode)
        s.unregisterActiveList(scope: scope)
        XCTAssertFalse(s.selectMode)
        XCTAssertEqual(s.ids, ["a"])
    }

    /// clearAndExit un-latches the scope too, so post-clear guards (BrowseView's
    /// prune-after-recompute) stop matching a dead selection forever.
    func testClearAndExitUnlatchesScope() {
        let s = RowSelection()
        _ = tap(s, "a", .option)
        XCTAssertEqual(s.scopeId, scope)
        s.clearAndExit()
        XCTAssertNil(s.scopeId)
    }

    /// While a text field has focus, ⌘A belongs to the field — the shadow's presence gate
    /// (`canSelectAll`) must read false even with a registered list.
    func testTextEntryFocusSuspendsSelectAll() {
        let s = RowSelection()
        s.registerActiveList(scope: scope, allIds: { self.order }, payload: { nil })
        XCTAssertTrue(s.canSelectAll)
        s.textEntryFocused = true
        XCTAssertFalse(s.canSelectAll)
        s.textEntryFocused = false
        XCTAssertTrue(s.canSelectAll)
    }
}
