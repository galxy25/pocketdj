import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
#endif

/// PER-WINDOW multi-select state (Levi 2026-08: ⌘-click = range, ⌥-click = toggle,
/// ⇧-click = range too). One instance is @State on RootView — NOT app-scoped on
/// PocketDJApp — so every ⌘N window selects independently: pick songs in one window,
/// drag/paste them into a collection shown in another. Ids live in the ACTIVE list's
/// id space (Browse/pocket/source lists: song ids; playlist chapters: NODE ids) —
/// the registered payload closure translates to song ids when a payload is built.
@MainActor @Observable
final class RowSelection {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let option  = Modifiers(rawValue: 1 << 1)
        static let shift   = Modifiers(rawValue: 1 << 2)
    }
    enum TapOutcome { case navigate, selection }

    // MARK: Selection state
    private(set) var scopeId: String?
    private(set) var ids: Set<String> = []
    private(set) var anchorId: String?
    /// Touch fallback: plain taps toggle instead of navigating — armed PER SCOPE. A single
    /// Bool here once swallowed the first tap in every OTHER list (armed in Browse, invisible
    /// in a pocket, tap toggles instead of navigating), so the mode carries the scope it was
    /// armed in and `handleTap` only intercepts taps in THAT scope.
    private(set) var selectModeScope: String?
    var selectMode: Bool { selectModeScope != nil }
    func isSelectMode(in scope: String) -> Bool { selectModeScope == scope }
    /// A text field (Browse search) currently has focus: suspend the ⌘A select-all shadow so
    /// the field keeps its own select-all. Published by the view owning the FocusState.
    var textEntryFocused = false

    // MARK: Active-list registration (frontmost selectable list of THIS window)
    struct ActiveList {
        let scope: String
        let allIds: () -> [String]              // FULL filtered universe (select-all), display order
        let payload: () -> SongTransfer?        // ordered selection → song-id payload
    }
    private(set) var activeList: ActiveList?

    // MARK: Paste registration (the collection detail currently on screen, if any)
    struct PasteTarget { let scope: String; let handler: (SongTransfer) -> Void }
    private(set) var pasteTarget: PasteTarget?

    var hasSelection: Bool { !ids.isEmpty }
    var count: Int { ids.count }
    /// ⌘C is live only when the selection belongs to the list that can serialize it.
    var canCopy: Bool { hasSelection && activeList?.scope == scopeId }
    var canPaste: Bool { pasteTarget != nil }
    /// ⌘A shadow presence: a registered list AND no focused text field (which owns its own ⌘A).
    var canSelectAll: Bool { activeList != nil && !textEntryFocused }

    func isSelected(_ id: String, scope: String) -> Bool { scopeId == scope && ids.contains(id) }
    /// The bar shows for a scope while selecting there (or select mode is armed there).
    func isActive(in scope: String) -> Bool {
        (selectMode || hasSelection) && (scopeId == nil || scopeId == scope)
    }

    // MARK: Gestures
    func handleTap(id: String, scope: String, orderedIds: [String], modifiers: Modifiers) -> TapOutcome {
        if modifiers.contains(.option) {
            switchScopeIfNeeded(scope)
            toggle(id)
            anchorId = ids.contains(id) ? id : (anchorId == id ? nil : anchorId)
            return .selection
        }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            switchScopeIfNeeded(scope)
            if let a = anchorId, let ai = orderedIds.firstIndex(of: a),
               let ci = orderedIds.firstIndex(of: id) {
                ids.formUnion(orderedIds[min(ai, ci)...max(ai, ci)])
            } else {                      // no (valid) anchor → single select + arm anchor
                ids.insert(id); anchorId = id
            }
            return .selection
        }
        // Select mode intercepts plain taps ONLY in the scope it was armed in — a tap in any
        // other list navigates as normal (the mode is invisible there: no bar, no badges).
        if selectModeScope == scope { switchScopeIfNeeded(scope); toggle(id); return .selection }
        return .navigate
    }
    func enterSelectMode(scope: String, initial: String?) {
        switchScopeIfNeeded(scope)
        selectModeScope = scope
        if let initial { ids.insert(initial); anchorId = initial }
    }
    func selectAll() {
        guard let al = activeList else { return }
        switchScopeIfNeeded(al.scope)
        ids = Set(al.allIds())
    }
    /// Clear the selection and exit Select mode. Also un-latches `scopeId` so post-clear
    /// guards (e.g. BrowseView's prune-after-recompute) stop matching a dead selection.
    func clearAndExit() { ids = []; anchorId = nil; selectModeScope = nil; scopeId = nil }
    /// Empty the selection but STAY in Select mode (History's "Deselect all"): the user is
    /// still picking, they just want to start over — `clearAndExit` would drop them back to
    /// tap-to-navigate and make them re-arm. Keeps `scopeId` so the bar stays put.
    func deselectAll() { ids = []; anchorId = nil }
    func prune(validIds: Set<String>) {
        ids.formIntersection(validIds)
        if let a = anchorId, !validIds.contains(a) { anchorId = nil }
    }
    /// The selection in display order (intersection with `orderedIds`).
    func orderedSelection(in orderedIds: [String]) -> [String] { orderedIds.filter { ids.contains($0) } }

    // MARK: Registration (onAppear/onDisappear of each participating list)
    func registerActiveList(scope: String, allIds: @escaping () -> [String],
                            payload: @escaping () -> SongTransfer?) {
        activeList = ActiveList(scope: scope, allIds: allIds, payload: payload)
    }
    func unregisterActiveList(scope: String) {           // no-op if another list took over
        if activeList?.scope == scope { activeList = nil }
        // The list Select mode was armed in left the screen — disarm (the selection itself
        // survives; only the tap-to-toggle mode ends with its owning list).
        if selectModeScope == scope { selectModeScope = nil }
    }
    func registerPasteTarget(scope: String, handler: @escaping (SongTransfer) -> Void) {
        pasteTarget = PasteTarget(scope: scope, handler: handler)
    }
    func unregisterPasteTarget(scope: String) {
        if pasteTarget?.scope == scope { pasteTarget = nil }
    }

    // MARK: Clipboard / payload
    func currentPayload() -> SongTransfer? {
        guard canCopy else { return nil }
        return activeList?.payload()
    }
    func performCopy() {
        guard let t = currentPayload(), !t.songIds.isEmpty else { return }
        SongPasteboard.write(t)
    }
    func performPaste() {
        guard let pt = pasteTarget, let t = SongPasteboard.read(), !t.songIds.isEmpty else { return }
        pt.handler(t)
    }
    /// Row context-menu Copy: the whole selection when the row is part of it, else just the row.
    func copyRowOrSelection(rowId: String, scope: String, single: SongTransfer) {
        if isSelected(rowId, scope: scope), let t = currentPayload(), !t.songIds.isEmpty {
            SongPasteboard.write(t)
        } else {
            SongPasteboard.write(single)
        }
    }
    /// Drag payload for a row: selection-aware with a single-row fallback.
    func payloadForRow(_ id: String, scope: String, single: SongTransfer) -> SongTransfer {
        guard isSelected(id, scope: scope), let t = currentPayload(), !t.songIds.isEmpty else { return single }
        return t
    }

    private func toggle(_ id: String) { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) } }
    private func switchScopeIfNeeded(_ scope: String) {
        guard scopeId != scope else { return }
        ids = []; anchorId = nil; scopeId = scope
        // A genuine scope change (modifier-click in another list) also ends Select mode —
        // safe for enterSelectMode, which sets selectModeScope AFTER calling this.
        if selectModeScope != scope { selectModeScope = nil }
    }
}

/// Current hardware modifier keys at tap time. macOS: NSEvent. iPadOS/visionOS/iOS:
/// GCKeyboard (hardware keyboards surface through GameController). No keyboard ⇒ [] —
/// plain taps everywhere, Select mode is the touch path.
enum ModifierKeys {
    @MainActor static func current() -> RowSelection.Modifiers {
        var m: RowSelection.Modifiers = []
        #if os(macOS)
        let f = NSEvent.modifierFlags
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.shift)   { m.insert(.shift) }
        #else
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func down(_ c: GCKeyCode) -> Bool { kb.button(forKeyCode: c)?.isPressed == true }
            if down(.leftGUI)   || down(.rightGUI)   { m.insert(.command) }
            if down(.leftAlt)   || down(.rightAlt)   { m.insert(.option) }
            if down(.leftShift) || down(.rightShift) { m.insert(.shift) }
        }
        #endif
        return m
    }
}

// MARK: - macOS Edit-menu bridge (Commands can't read window environment; FocusedValues can)

struct SongSelectionActions {
    var canCopy: Bool
    var canPaste: Bool
    var copy: @MainActor () -> Void
    var paste: @MainActor () -> Void
}
struct SongSelectionActionsKey: FocusedValueKey { typealias Value = SongSelectionActions }
extension FocusedValues {
    var songSelectionActions: SongSelectionActions? {
        get { self[SongSelectionActionsKey.self] }
        set { self[SongSelectionActionsKey.self] = newValue }
    }
}
