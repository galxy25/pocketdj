import SwiftUI

/// Makes a song row multi-selectable + draggable. REPLACES the row's old
/// `.contentShape + .onTapGesture { navigate }` pair — plain taps still navigate via
/// `onOpen`; modifier-clicks (⌘ range / ⌥ toggle / ⇧ range) and Select mode mutate the
/// per-window RowSelection instead. Also the drag source (selection-aware payload).
struct SelectableRowModifier: ViewModifier {
    @Environment(RowSelection.self) private var selection
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif
    let id: String                       // song id (Browse/pocket/source) or nodeId (playlist)
    let scope: String
    /// The row lives in a `ForEach` that owns `.onMove` (pocket songs, playlist chapter
    /// nodes). An unconditional row `.draggable` claims the drag gesture and kills List's
    /// direct-drag reorder (the only macOS reorder affordance), so reorder hosts attach the
    /// drag source ONLY once the row is part of a selection / Select mode — plain drags
    /// reorder, selected drags export.
    var reorderHost = false
    let orderedIds: () -> [String]       // rendered display order (range universe)
    let payload: () -> SongTransfer      // selection-aware drag payload for this row
    let onOpen: () -> Void

    private var isSelected: Bool { selection.isSelected(id, scope: scope) }
    private var dragCount: Int { isSelected ? max(selection.count, 1) : 1 }
    private var dragEnabled: Bool { !reorderHost || isSelected || selection.isSelectMode(in: scope) }

    func body(content: Content) -> some View {
        let row = content
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
        // The if/else changes view identity when dragEnabled flips — acceptable: it flips on
        // selection changes, which restyle the row anyway.
        Group {
            if dragEnabled {
                row.draggable(payload()) { SongDragChip(count: dragCount) }
            } else {
                row
            }
        }
        .overlay(alignment: .topLeading) {
            if selection.isSelectMode(in: scope) { selectBadge }
        }
        // One DRAWN fill for every container. (`.listRowBackground` looked right for List
        // rows but is a row-root trait — applied here, nested inside the row's VStack, it
        // silently did nothing, leaving modifier-click selections invisible.)
        .background(isSelected ? Theme.accent.opacity(0.26) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        // These rows replaced NavigationLink rows (tap-gesture navigation) — restore the
        // activatable trait so VoiceOver announces them and the Buttons rotor finds them.
        .accessibilityAddTraits(.isButton)
    }
    private var selectBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.footnote)
            .foregroundStyle(isSelected ? Theme.accent : Theme.fgDim)
            .padding(2)
            .background(Theme.bg.opacity(0.7), in: Circle())
            .allowsHitTesting(false)
            .padding(.top, 2)
    }
    private func handleTap() {
        #if os(iOS)
        if editMode?.wrappedValue.isEditing == true { return }   // EditMode owns taps (reorder)
        #endif
        switch selection.handleTap(id: id, scope: scope, orderedIds: orderedIds(),
                                   modifiers: ModifierKeys.current()) {
        case .navigate: onOpen()
        case .selection: break
        }
    }
}

extension View {
    func selectableSongRow(id: String, scope: String,
                           reorderHost: Bool = false,
                           orderedIds: @escaping () -> [String],
                           payload: @escaping () -> SongTransfer,
                           onOpen: @escaping () -> Void) -> some View {
        modifier(SelectableRowModifier(id: id, scope: scope, reorderHost: reorderHost,
                                       orderedIds: orderedIds, payload: payload, onOpen: onOpen))
    }
}

/// Drag preview: a small capsule ("3 songs").
struct SongDragChip: View {
    let count: Int
    var body: some View {
        Label("\(count) song\(count == 1 ? "" : "s")", systemImage: "music.note")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.bgRaised, in: Capsule())
            .foregroundStyle(Theme.fg)
    }
}

/// The floating header shown while a selection (or Select mode) is active in `scope`:
/// count · Select all · Add to ▸ · Copy · ✕. Rides `.safeAreaInset(edge: .top)` above
/// each participating list.
struct SelectionBar: View {
    @Environment(RowSelection.self) private var selection
    @Environment(CollectionsStore.self) private var collections
    let scope: String

    var body: some View {
        if selection.isActive(in: scope) {
            HStack(spacing: 12) {
                Text("\(selection.count) selected")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .accessibilityIdentifier("selection-count")
                    .accessibilityValue("\(selection.count)")
                Spacer()
                Button("Select all") { selection.selectAll() }
                    .font(.caption)
                    .accessibilityIdentifier("selection-select-all")
                addToMenu
                Button { selection.performCopy() } label: { Image(systemName: "doc.on.doc") }
                    .disabled(!selection.canCopy)
                    .help("Copy selected songs (⌘C)")
                    .accessibilityIdentifier("selection-copy")
                Button { selection.clearAndExit() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Clear selection")
                    .accessibilityIdentifier("selection-clear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.bgRaised)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selection-bar")
        }
    }

    private var addToMenu: some View {
        Menu {
            let recents = Array(collections.recentAddTargets.prefix(3))
            ForEach(Array(recents.enumerated()), id: \.offset) { _, t in
                if let label = collections.lastTargetLabel(t) {
                    Button(label) { add(to: t) }
                }
            }
            if !recents.isEmpty { Divider() }
            if !collections.pockets.isEmpty {
                Menu("Pockets") {
                    ForEach(collections.pockets.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { p in
                        Button(p.name) { add(to: AddTarget(kind: .pocket, id: p.id)) }
                    }
                }
            }
            if !collections.playlists.isEmpty {
                Menu("Playlists") {
                    ForEach(collections.playlists.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { pl in
                        Button(pl.name) { add(to: AddTarget(kind: .playlist, id: pl.id)) }
                    }
                }
            }
        } label: { Label("Add to", systemImage: "plus.circle").font(.caption) }
        .disabled(!selection.canCopy)
        .accessibilityIdentifier("selection-add-to")
    }
    private func add(to target: AddTarget) {
        guard let ids = selection.currentPayload()?.songIds, !ids.isEmpty else {
            // A stale selection resolved to nothing (the songs left the list under it) —
            // clear rather than let the bar keep advertising a count that can't act.
            selection.clearAndExit()
            return
        }
        collections.addSongs(ids, to: target)
    }
}

/// Chrome for a collection detail that takes part in multi-select: the SelectionBar riding
/// the top edge, the whole-list drop target (with highlight) when `acceptDrop` is set, and
/// active-list/paste registration on appear/disappear. One modifier instead of a per-view
/// chain so PlaylistDetail/PocketDetail/IndexPlaylistDetail stay inside the type-checker
/// budget (the PlaylistAlerts extraction pattern).
struct CollectionSelectionChrome: ViewModifier {
    @Environment(RowSelection.self) private var selection
    let scope: String
    let allIds: () -> [String]
    let payload: () -> SongTransfer?
    /// nil ⇒ this list is a copy/drag SOURCE only (no drop target, no paste registration).
    var acceptDrop: (([SongTransfer]) -> Bool)?
    @State private var dropTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let acceptDrop {
            registered(content)
                .dropDestination(for: SongTransfer.self) { items, _ in
                    acceptDrop(items)
                } isTargeted: { dropTargeted = $0 }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            registered(content)
        }
    }

    private func registered(_ content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { SelectionBar(scope: scope) }
            // The list's membership changed under an active selection (swipe-remove, source
            // sync, sort/filter): drop ids that left the list so the bar's count and every
            // batch action agree with what's on screen. Gated so the id-set is only built
            // while a selection in THIS scope actually exists.
            .onChange(of: allIds()) { _, ids in
                guard selection.scopeId == scope, selection.hasSelection else { return }
                selection.prune(validIds: Set(ids))
            }
            .onAppear {
                selection.registerActiveList(scope: scope, allIds: allIds, payload: payload)
                if let acceptDrop {
                    selection.registerPasteTarget(scope: scope) { _ = acceptDrop([$0]) }
                }
            }
            .onDisappear {
                selection.unregisterActiveList(scope: scope)
                selection.unregisterPasteTarget(scope: scope)
            }
    }
}
