import SwiftUI
import AVFoundation

// MARK: - StudioSequencerView (Performance ▸ Sequencer — spec §1.3 / §11)

/// The Performance tab's **Sequencer** sub-tab: a list of saved 16-step patterns and, once one
/// is opened, the step-grid editor (BPM stepper, ≤ 8 sample/loop rows, per-row gain, play/stop,
/// and an overflow Bounce for offline collection playback).
///
/// Navigation is IN-CONTENT selection (list ⇄ editor via local `@State`), NOT a
/// `navigationDestination` push: the shell's central route registry (RootView) is owned by the
/// tab-shell work, and the Performance sub-tabs swap views inside one detail pane — a nested
/// NavigationStack here would fight the shared one.
///
/// Environment-driven and no-argument by contract (the shell mounts `StudioSequencerView()`).
struct StudioSequencerView: View {
    @Environment(StudioStore.self) private var studio

    /// The pattern open in the editor; nil = the pattern list. When the open pattern vanishes
    /// (deleted from another device's doc sync, a reconcile) the guard below falls back to the
    /// list instead of rendering a dead editor.
    @State private var openPatternId: String?

    var body: some View {
        Group {
            if let id = openPatternId, studio.pattern(id) != nil {
                SequencerEditor(patternId: id, onBack: { openPatternId = nil })
            } else {
                SequencerListView(open: { openPatternId = $0 })
            }
        }
        // Claim the whole detail pane so the empty-state ContentUnavailableView centers in a
        // full-size area instead of collapsing to a tiny box (the List-backed non-empty state
        // already fills greedily; this matches every other sub-tab, e.g. StudioSamplesView).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Pattern list

/// All saved patterns, newest first — name / BPM / row count / bounce state per row. Rename and
/// delete ride the MixSessionsView swipe + context-menu conventions; "New pattern" is an
/// in-content button (iPhone-portrait rule: critical controls never live toolbar-only).
private struct SequencerListView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    let open: (String) -> Void

    @State private var renamingId: String?
    @State private var nameDraft = ""
    @State private var deletingId: String?
    /// The pattern whose "Add to playlist or pocket…" sheet is open (nil ⇒ closed).
    @State private var addRef: StudioAddRef?

    // Sequence folders (create / rename / delete + move-into) — the StudioSamplesView idiom applied
    // to saved patterns. Device-local organization; NO bounce audio moves, no pattern record deleted.
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    /// When "New folder…" is chosen from a pattern's Move submenu, the new folder is created AND
    /// this pattern is moved into it (nil ⇒ a plain "New folder" from the header, just create).
    @State private var pendingMovePatternId: String?
    @State private var renamingFolderId: String?
    @State private var folderNameDraft = ""
    @State private var deletingFolderId: String?
    /// Collapsed sequence-folder ids, persisted across launches (missing ⇒ expanded).
    @State private var collapsed: Set<String> = SequencerListView.loadCollapsed()

    var body: some View {
        Group {
            // Empty state only when there is NOTHING at all — a folder with no patterns still needs
            // its section shown so the user can move sequences in / manage it.
            if studio.patterns.isEmpty && studio.patternFolders.isEmpty {
                ContentUnavailableView {
                    Label("No patterns yet", systemImage: "square.grid.4x3.fill")
                } description: {
                    Text("A pattern is one bar of 16 steps over your samples and loops — program hits, play it in a loop, bounce it for offline.")
                } actions: {
                    newPatternButton
                    newFolderButton   // pre-create a folder before any pattern exists (Loops/Takes parity)
                }
            } else {
                VStack(spacing: 0) {
                    // In-content header bar (never toolbar-only — the iPhone ⋯-overflow lesson).
                    HStack {
                        Text("Patterns").font(.headline).foregroundStyle(Theme.fg)
                        Spacer()
                        newFolderButton
                        newPatternButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    patternList
                }
            }
        }
        .background(Theme.bg)
        .studioAddToCollection($addRef)
        .alert("Rename pattern", isPresented: Binding(get: { renamingId != nil },
                                                      set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft).accessibilityIdentifier("seq-rename-field")
            Button("Save") {
                if let id = renamingId { studio.renamePattern(id, to: nameDraft) }
                renamingId = nil
            }
            .accessibilityIdentifier("seq-rename-confirm")
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .confirmationDialog("Delete this pattern?",
                            isPresented: Binding(get: { deletingId != nil },
                                                 set: { if !$0 { deletingId = nil } }),
                            titleVisibility: .visible) {
            Button("Delete pattern", role: .destructive) {
                if let id = deletingId {
                    // A deleted pattern must not keep sounding: the engine plays its own loaded
                    // copy (by design), so stop it explicitly before dropping the record.
                    if engine.loadedPatternId == id, engine.isPlayingPattern { engine.stopPattern() }
                    _ = studio.deletePattern(id)
                }
                deletingId = nil
            }
            .accessibilityIdentifier("seq-delete-confirm")
            Button("Cancel", role: .cancel) { deletingId = nil }
        } message: {
            Text("Removes the pattern and its bounced audio. The samples and loops it uses are kept.")
        }
        // Sequence-folder create / rename / delete (the StudioSamplesView / PlaylistsView precedent).
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty {
                    let f = studio.createPatternFolder(n)
                    // Chosen from a pattern's Move submenu ⇒ file that pattern into the new folder.
                    if let pid = pendingMovePatternId { studio.setPatternFolder(pid, folderId: f.id) }
                }
                newFolderName = ""; pendingMovePatternId = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = ""; pendingMovePatternId = nil }
        }
        .alert("Rename folder", isPresented: folderRenameBinding) {
            TextField("Name", text: $folderNameDraft)
            Button("Save") {
                if let id = renamingFolderId { studio.renamePatternFolder(id, to: folderNameDraft) }
                renamingFolderId = nil
            }
            Button("Cancel", role: .cancel) { renamingFolderId = nil }
        }
        .confirmationDialog("Delete this folder?", isPresented: folderDeleteBinding,
                            titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let id = deletingFolderId { studio.deletePatternFolder(id) }
                deletingFolderId = nil
            }
            Button("Cancel", role: .cancel) { deletingFolderId = nil }
        } message: {
            Text("The folder's sequences move back to Unfiled. No sequences or audio are deleted.")
        }
    }

    // MARK: Folder-grouped list (Unfiled section + one collapsible DisclosureGroup per folder)

    private var patternList: some View {
        List {
            unfiledSection
            ForEach(studio.patternFoldersOrdered()) { folder in
                folderSection(folder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The Unfiled section — patterns with no folder (or a dangling one). Always shown (it's the
    /// default home + the drop target for "Move to Unfiled").
    @ViewBuilder private var unfiledSection: some View {
        let unfiled = studio.patterns(inFolder: nil)
        Section {
            if unfiled.isEmpty {
                Text("No unfiled sequences.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(unfiled) { p in row(p) }
            }
        } header: {
            Text("Unfiled").foregroundStyle(Theme.fgDim)
        }
    }

    /// One collapsible FOLDER of sequences, name-ordered. Collapse state persists (UserDefaults).
    @ViewBuilder private func folderSection(_ folder: StudioPatternFolder) -> some View {
        let members = studio.patterns(inFolder: folder.id)
        Section {
            DisclosureGroup(isExpanded: folderExpansion(folder.id)) {
                if members.isEmpty {
                    Text("Empty folder — move a sequence in with its ⋯ menu.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .listRowBackground(Color.clear)
                }
                ForEach(members) { p in row(p) }
            } label: {
                HStack {
                    Label(folder.name, systemImage: "folder").foregroundStyle(Theme.accent2)
                    Spacer()
                    Text("\(members.count)").font(.caption).foregroundStyle(Theme.fgDim)
                }
                // The id rides the LABEL (a leaf), never the Section/DisclosureGroup container —
                // a container id would clobber descendant ids on macOS (the StemAuditionPanel trap).
                .accessibilityIdentifier("seq-folder-\(folder.id)")
                .contextMenu {
                    Button {
                        folderNameDraft = folder.name; renamingFolderId = folder.id
                    } label: { Label("Rename folder", systemImage: "pencil") }
                        .accessibilityIdentifier("seq-folder-rename-\(folder.id)")
                    Button(role: .destructive) { deletingFolderId = folder.id } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                        .accessibilityIdentifier("seq-folder-delete-\(folder.id)")
                }
            }
        }
    }

    private var newFolderButton: some View {
        Button {
            newFolderName = ""; pendingMovePatternId = nil; showNewFolder = true
        } label: {
            Label("New folder", systemImage: "folder.badge.plus").labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent2)
        .accessibilityIdentifier("seq-new-folder")
        .help("New sequence folder")
    }

    // MARK: Folder bindings + collapse persistence (the StudioSamplesView precedent)

    private var folderRenameBinding: Binding<Bool> {
        Binding(get: { renamingFolderId != nil }, set: { if !$0 { renamingFolderId = nil } })
    }

    private var folderDeleteBinding: Binding<Bool> {
        Binding(get: { deletingFolderId != nil }, set: { if !$0 { deletingFolderId = nil } })
    }

    /// NEW key (device-local, distinct from the sample/playlist-folder keys) per the spec.
    private static let collapsedKey = "pdj.patternFolders.collapsed"
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsed), forKey: SequencerListView.collapsedKey)
    }
    /// A binding into `collapsed` for a folder's DisclosureGroup, persisting on change (presence
    /// in the set = COLLAPSED, so a never-touched folder reads as expanded).
    private func folderExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                persistCollapsed()
            })
    }

    private var newPatternButton: some View {
        Button {
            // "New pattern creates + opens" (task spec) — straight into the editor, because an
            // empty pattern's only next step is adding rows there.
            let p = StudioPattern(id: StudioFactory.newPatternId(),
                                  name: "Pattern \(studio.patterns.count + 1)",
                                  bpm: 120,
                                  createdAt: Date().timeIntervalSince1970 * 1000)
            studio.addPattern(p)
            open(p.id)
        } label: {
            Label("New pattern", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .accessibilityIdentifier("seq-new")
    }

    private func row(_ p: StudioPattern) -> some View {
        Button { open(p.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.4x3.fill")
                    .foregroundStyle(engine.loadedPatternId == p.id && engine.isPlayingPattern
                                     ? Theme.accent : Theme.fgDim)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name.isEmpty ? "Untitled pattern" : p.name)
                        .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                    Text("\(Int(p.bpm.rounded())) BPM · \(p.rows.count) row\(p.rows.count == 1 ? "" : "s")"
                         + (p.fileName != nil && !p.bounceDirty ? " · bounced" : ""))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("seq-pattern-\(p.id)")
        .swipeActions(edge: .leading) {
            Button { beginRename(p) } label: { Label("Rename", systemImage: "pencil") }
                .tint(Theme.accent2)
                .accessibilityIdentifier("seq-rename-\(p.id)")
        }
        .swipeActions {
            Button(role: .destructive) { deletingId = p.id } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("seq-delete-\(p.id)")
            Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(Theme.accent)
                .accessibilityIdentifier("seq-duplicate-\(p.id)")
        }
        .contextMenu {   // right-click (macOS) / long-press (iOS) parity for the swipe actions
            Button { beginRename(p) } label: { Label("Rename…", systemImage: "pencil") }
            Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            // File this sequence into a folder (or Unfiled / a brand-new folder). Sets a string
            // only; the pattern record and its bounce audio never move.
            Menu {
                ForEach(studio.patternFoldersOrdered()) { f in
                    Button { studio.setPatternFolder(p.id, folderId: f.id) } label: {
                        if p.folderId == f.id {
                            Label(f.name, systemImage: "checkmark")
                        } else {
                            Text(f.name)
                        }
                    }
                    .accessibilityIdentifier("seq-move-to-\(f.id)-\(p.id)")
                }
                Divider()
                Button { studio.setPatternFolder(p.id, folderId: nil) } label: {
                    if p.folderId == nil {
                        Label("Unfiled", systemImage: "checkmark")
                    } else {
                        Text("Unfiled")
                    }
                }
                .accessibilityIdentifier("seq-move-to-unfiled-\(p.id)")
                Button {
                    pendingMovePatternId = p.id; newFolderName = ""; showNewFolder = true
                } label: {
                    Label("New folder…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("seq-move-to-new-\(p.id)")
            } label: {
                Label("Move to folder", systemImage: "folder")
            }
            .accessibilityIdentifier("seq-move-\(p.id)")
            Button {
                addRef = StudioAddRef(id: p.id, title: p.name)
                let pid = p.id
                Task { await StudioAnalyzer.prepare(forStudioId: pid, studio: studio, packs: nil) }
            } label: {
                Label("Add to playlist or pocket…", systemImage: "plus.rectangle.on.folder")
            }
            Button(role: .destructive) { deletingId = p.id } label: { Label("Delete pattern", systemImage: "trash") }
        }
    }

    private func beginRename(_ p: StudioPattern) {
        nameDraft = p.name
        renamingId = p.id
    }

    /// Duplicate = same rows/BPM under a fresh id. The copy deliberately does NOT inherit the
    /// bounce (`fileName` nil + dirty): the bounce file's name embeds the ORIGINAL's id, and two
    /// records must never point at one bounce file (deleting either would strand the other).
    private func duplicate(_ p: StudioPattern) {
        var copy = p
        copy.id = StudioFactory.newPatternId()
        copy.name = p.name.isEmpty ? "Pattern copy" : p.name + " copy"
        copy.fileName = nil
        copy.bounceDirty = true
        copy.wasUserFolder = false
        copy.createdAt = Date().timeIntervalSince1970 * 1000
        studio.addPattern(copy)
    }
}

// MARK: - Pattern editor

/// One pattern's editor: BPM stepper, the ≤ 8 target rows with their 16-step grids, add-row,
/// play/stop, and the overflow Bounce. Reads the pattern FROM THE STORE every render (the store
/// document is the single truth; every mutation goes through StudioStore so `bounceDirty`
/// bookkeeping can never be bypassed).
private struct SequencerEditor: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    let patternId: String
    let onBack: () -> Void
    /// SEQ2: live-vs-static playback (session-wide via @AppStorage, no schema). Shared by key
    /// with PatternRowCard's flag, which mirrors edits into the running engine.
    @AppStorage("pdj.sequencerLive") private var sequencerLive = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    /// Compact width (iPhone portrait AND landscape-compact): the 16-step line is too narrow to
    /// hit reliably, so each row renders as TWO lines of 8 (spec §11). iPad/macOS keep 1×16.
    private var compact: Bool { hSize == .compact }
    #else
    private var compact: Bool { false }
    #endif

    /// Row buffers are decoding/rendering ahead of play — Play shows a spinner and is disabled
    /// (a second tap mid-prepare would race the engine load).
    @State private var preparing = false
    @State private var bouncing = false
    /// Inline status/problem line (skipped rows, bounce results). Never an alert — these are
    /// advisory, and the pattern remains editable underneath.
    @State private var notice: String?
    @State private var renaming = false
    @State private var nameDraft = ""
    /// SEQ collapse/zoom/rename: which lanes are collapsed, the bars-per-line zoom, and the lane
    /// being renamed (with its draft).
    @State private var collapsedRows: Set<Int> = []
    @State private var barsPerLine = 1
    @State private var renamingRow: Int?
    @State private var rowNameDraft = ""
    /// SEQ5 playhead + looper. `startStep` is the cursor — where Play begins, jumped to the last
    /// pad you touch, reset to 0 by the refresh button. The ∞ looper cycles a `loopBars`-bar window
    /// anchored at the cursor. All transient (a performance control, per editor session).
    @State private var startStep = 0
    @State private var loopEnabled = false
    @State private var loopBars = 2
    @State private var prepareTask: Task<Void, Never>?
    /// Monotonic token pairing each prepare run with ITS `preparing` flag: a cancelled run's
    /// deferred cleanup must not clobber the state of the run that replaced it (the cancelled
    /// task only resumes at its next await — possibly AFTER the new task set `preparing = true`).
    @State private var prepGeneration = 0

    private var isPlayingThis: Bool {
        engine.isPlayingPattern && engine.loadedPatternId == patternId && engine.soloedRow == nil
    }

    /// SEQ4: pattern length in whole bars (16 steps each), up to maxStepCount bars. Growing pads
    /// with off steps; shrinking drops the tail. Applies on the next Play (like BPM). A whole-song
    /// pattern sent from the Demuxer can be far longer than you'd dial by hand — the stepper still
    /// displays and edits it (its range covers the full cap so an imported length isn't clamped down).
    private func lengthRow(_ pattern: StudioPattern) -> some View {
        let bars = max(1, (pattern.stepCount + 15) / 16)
        let maxBars = StudioPattern.maxStepCount / 16
        return HStack(spacing: 10) {
            Text("Length").font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
            Stepper(value: Binding(
                get: { bars },
                set: { studio.setPatternStepCount(patternId, count: min($0 * 16, StudioPattern.maxStepCount)) }),
                    in: 1...maxBars) {
                Text("\(bars) bar\(bars == 1 ? "" : "s") · \(pattern.stepCount) steps")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
            }
            .accessibilityIdentifier("seq-length-stepper")
            Spacer(minLength: 0)
        }
    }

    /// SEQ2: the Live/Static toggle + the mode-appropriate "when do edits apply" note.
    private var liveModeRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $sequencerLive) {
                Label("Live edits",
                      systemImage: sequencerLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .tint(Theme.accent2)
            .accessibilityIdentifier("seq-live-toggle")
            if isPlayingThis {
                Text(sequencerLive
                     ? "Live — step & loop edits apply at the next bar (BPM and span edits still on next Play)."
                     : "Step and BPM edits apply the next time you press Play.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            Spacer(minLength: 0)
        }
    }

    /// SEQ collapse/zoom: collapse-all/expand-all + a bars-per-line zoom (1 bar = big cells/focus a
    /// bar; 8 = compact so a whole-song pattern fits in far fewer lines).
    private func lanesControlRow(_ pattern: StudioPattern) -> some View {
        let allCollapsed = !pattern.rows.isEmpty && collapsedRows.count >= pattern.rows.count
        return HStack(spacing: 10) {
            Button {
                if allCollapsed { collapsedRows.removeAll() } else { collapsedRows = Set(pattern.rows.indices) }
            } label: {
                Label(allCollapsed ? "Expand all" : "Collapse all",
                      systemImage: allCollapsed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("seq-collapse-all")
            Spacer(minLength: 0)
            Text("Zoom").font(.caption).foregroundStyle(Theme.fgDim)
            Picker("Zoom", selection: $barsPerLine) {
                Text("1 bar").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            .accessibilityIdentifier("seq-zoom")
        }
    }

    private func toggleCollapse(_ i: Int) {
        if collapsedRows.contains(i) { collapsedRows.remove(i) } else { collapsedRows.insert(i) }
    }
    private func beginRowRename(_ i: Int, _ pattern: StudioPattern) {
        rowNameDraft = pattern.rows.indices.contains(i) ? (pattern.rows[i].label ?? "") : ""
        renamingRow = i
    }

    var body: some View {
        ScrollView {
            if let pattern = studio.pattern(patternId) {
                VStack(alignment: .leading, spacing: 14) {
                    headerBar(pattern)
                    bpmRow(pattern)
                    lengthRow(pattern)
                    liveModeRow
                    if pattern.rows.count > 1 || pattern.stepCount > 16 { lanesControlRow(pattern) }
                    if !pattern.hasSoundingSteps { emptyNotice }
                    if let notice { noticeLine(notice) }
                    // Lanes below the fold cost nothing until scrolled to. (Each lane windows its
                    // own bars too — see `PatternRowCard.shownLines`.)
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(pattern.rows.indices, id: \.self) { i in
                            PatternRowCard(patternId: patternId, rowIndex: i, row: pattern.rows[i],
                                           compact: compact, playingThis: isPlayingThis,
                                           collapsed: collapsedRows.contains(i), barsPerLine: barsPerLine,
                                           cursorStep: startStep, loopEnabled: loopEnabled, loopBars: loopBars,
                                           onSolo: { toggleSolo(row: $0) },
                                           onToggleCollapse: { toggleCollapse(i) },
                                           onRename: { beginRowRename(i, pattern) },
                                           onTouchStep: { touchStep($0) })
                        }
                    }
                    addRowControl(pattern)
                    bounceStatus(pattern)
                }
                .padding(16)
                .frame(maxWidth: 900)               // cap + center the column (Mix precedent)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bg)
        .onDisappear {
            // Leaving the editor (back, sub-tab switch, tab switch) stops the pattern — a
            // sequencer bar looping with no grid on screen is noise, not persistent playback
            // (task contract; unlike the Mix decks, which deliberately keep playing). Gate on
            // OWNERSHIP: the engine is app-scoped and plays ONE pattern globally, so with a second
            // window open it may be sounding ANOTHER window's pattern — only stop the one THIS
            // editor loaded (mirrors the delete path's `loadedPatternId == id` guard above).
            prepareTask?.cancel()
            if engine.loadedPatternId == patternId, engine.isPlayingPattern { engine.stopPattern() }
        }
        .alert("Rename pattern", isPresented: $renaming) {
            TextField("Name", text: $nameDraft).accessibilityIdentifier("seq-rename-field")
            Button("Save") { studio.renamePattern(patternId, to: nameDraft); renaming = false }
                .accessibilityIdentifier("seq-rename-confirm")
            Button("Cancel", role: .cancel) { renaming = false }
        }
        .alert("Rename lane", isPresented: Binding(get: { renamingRow != nil },
                                                   set: { if !$0 { renamingRow = nil } })) {
            TextField("Lane name", text: $rowNameDraft).accessibilityIdentifier("seq-row-rename-field")
            Button("Save") {
                if let i = renamingRow { studio.setPatternRowLabel(patternId, row: i, label: rowNameDraft) }
                renamingRow = nil
            }
            .accessibilityIdentifier("seq-row-rename-confirm")
            Button("Cancel", role: .cancel) { renamingRow = nil }
        } message: { Text("A custom lane name — leave blank to restore the sample’s name.") }
    }

    // MARK: Header (back · name · rename · play · overflow)

    private func headerBar(_ pattern: StudioPattern) -> some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to patterns")
            .accessibilityIdentifier("seq-back")

            Text(pattern.name.isEmpty ? "Untitled pattern" : pattern.name)
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)

            Button { nameDraft = pattern.name; renaming = true } label: {
                Image(systemName: "pencil").foregroundStyle(Theme.fgDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename pattern")
            .accessibilityIdentifier("seq-rename-\(patternId)")

            Spacer()

            refreshButton
            loopButton
            playButton(pattern)

            Menu {
                Button { bounce(pattern) } label: {
                    Label("Bounce for offline", systemImage: "square.and.arrow.down")
                }
                .disabled(bouncing || !pattern.hasSoundingSteps)
                .accessibilityIdentifier("seq-bounce")
            } label: {
                if bouncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("seq-overflow")
            .help("More actions")
        }
    }

    private func playButton(_ pattern: StudioPattern) -> some View {
        Button {
            if isPlayingThis {
                // SEQ5: park the cursor at the last PLAYED pad on stop (a resume-from-here feel),
                // rather than snapping back to where Play began. It only moves again when the user
                // taps another pad or hits the refresh (restart) button. Read the live step BEFORE
                // stopping — stopPattern() clears the clock, after which currentStep is nil.
                //
                // NOT while the ∞ looper is on: there `startStep` doubles as the loop-window
                // ANCHOR, so moving it would silently slide the chosen loop region forward on every
                // stop→replay (and jump the highlight band the instant Stop is pressed). Looping
                // also ignores the stop position on replay, so parking would buy nothing there.
                if !loopEnabled, let s = engine.patternClock.currentStep { startStep = s }
                engine.stopPattern()
            } else {
                startPlayback(pattern)
            }
        } label: {
            HStack(spacing: 6) {
                if preparing { ProgressView().controlSize(.small) }
                else { Image(systemName: isPlayingThis ? "stop.fill" : "play.fill") }
                Text(isPlayingThis ? "Stop" : "Play")
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background((isPlayingThis ? Theme.accent2 : Theme.accent).opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(isPlayingThis ? Theme.accent2 : Theme.accent, lineWidth: 1))
            .foregroundStyle(isPlayingThis ? Theme.accent2 : Theme.accent)
        }
        .buttonStyle(.plain)
        // Zero sounding steps ⇒ Play disabled with the inline notice (spec §2: an empty pattern
        // refuses to play — zero-frame schedules crash; the engine ALSO refuses, this is the UX).
        .disabled(preparing || !pattern.hasSoundingSteps)
        .accessibilityIdentifier("seq-play")
    }

    // MARK: Transport — refresh (playhead → start) + ∞ looper (SEQ5)

    /// Reset the playhead to the top. Acts live while playing (re-anchors from step 0) and just
    /// moves the resting cursor while stopped — either way the next Play begins at the start.
    private var refreshButton: some View {
        Button {
            startStep = 0
            if isPlayingThis { engine.setPatternStartStep(0) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset playhead to start")
        .accessibilityIdentifier("seq-refresh")
        .help("Reset the playhead to the beginning")
    }

    /// The ∞ looper: tap to cycle a `loopBars`-bar window anchored at the playhead; right-click /
    /// long-press to set the bar count (default 2). Turquoise + a bar-count badge when on. Acts
    /// live while playing (re-anchors so the loop starts immediately).
    private var loopButton: some View {
        Button {
            loopEnabled.toggle()
            if isPlayingThis { engine.setPatternLoop(enabled: loopEnabled, bars: loopBars) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "infinity")
                if loopEnabled {
                    Text("\(loopBars)").font(.caption2.weight(.bold)).monospacedDigit()
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(loopEnabled ? Theme.accent2 : Theme.fgDim)
            .frame(height: 30).padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loopEnabled ? "Looper on, \(loopBars) bars" : "Looper off")
        .accessibilityIdentifier("seq-loop")
        .help("Loop a section — right-click to set how many bars")
        .contextMenu {
            Picker("Loop length", selection: Binding(
                get: { loopBars },
                set: { loopBars = $0
                       if isPlayingThis { engine.setPatternLoop(enabled: loopEnabled, bars: $0) } })) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { n in
                    Text("\(n) bar\(n == 1 ? "" : "s")").tag(n)
                }
            }
            .accessibilityIdentifier("seq-loop-bars")
        }
    }

    /// A pad was touched (any cell, on or off): jump the resting cursor there. While stopped this
    /// is where the next Play begins; while playing it just re-homes the cursor for the next manual
    /// Play (we deliberately do NOT live-seek per tap — that would stutter the audio and fight
    /// live step editing; the refresh/∞ transport buttons are the live re-anchor controls).
    private func touchStep(_ col: Int) {
        let n = studio.pattern(patternId)?.stepCount ?? StudioPattern.defaultStepCount
        startStep = min(max(0, col), max(0, n - 1))
    }

    // MARK: BPM

    private func bpmRow(_ pattern: StudioPattern) -> some View {
        HStack(spacing: 10) {
            Text("BPM").font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
            Text("\(Int(pattern.bpm.rounded()))")
                .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.fg)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("BPM",
                    value: Binding(get: { Int(pattern.bpm.rounded()) },
                                   set: { studio.setPatternBpm(patternId, Double($0)) }),
                    in: 60...200, step: 1)
                .labelsHidden()
                .accessibilityIdentifier("seq-bpm")
            Spacer()
        }
    }

    // MARK: Notices

    private var emptyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("Toggle steps below to enable Play and Bounce — an empty pattern is never played or bounced.")
        }
        .font(.caption).foregroundStyle(Theme.accent2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent2.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
            Text(text)
        }
        .font(.caption).foregroundStyle(Theme.fgDim)
    }

    // MARK: Add row

    private func addRowControl(_ pattern: StudioPattern) -> some View {
        let full = pattern.rows.count >= StudioEngine.maxPatternRows
        let samples = studio.samplesByName   // shared memo — see StudioStore
        let loops = studio.loopsByName
        let noTargets = samples.isEmpty && loops.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            Menu {
                if !samples.isEmpty {
                    Section("Samples") {
                        ForEach(samples) { s in
                            Button { studio.addPatternRow(patternId, targetId: s.id) } label: {
                                Label(s.name.isEmpty ? "Untitled sample" : s.name, systemImage: "waveform")
                            }
                            .accessibilityIdentifier("seq-add-row-\(s.id)")
                        }
                    }
                }
                if !loops.isEmpty {
                    Section("Loops") {
                        ForEach(loops) { l in
                            Button { studio.addPatternRow(patternId, targetId: l.id) } label: {
                                Label(l.name.isEmpty ? "Untitled loop" : l.name, systemImage: "repeat")
                            }
                            .accessibilityIdentifier("seq-add-row-\(l.id)")
                        }
                    }
                }
            } label: {
                Label("Add row", systemImage: "plus.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(full || noTargets ? Theme.fgDim : Theme.accent)
            }
            .disabled(full || noTargets)
            .accessibilityIdentifier("seq-add-row")

            if full {
                Text("Patterns hold up to \(StudioEngine.maxPatternRows) rows.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            } else if noTargets {
                Text("Record a sample or slice a loop first — rows trigger your samples and loops.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
    }

    // MARK: Bounce status

    @ViewBuilder private func bounceStatus(_ pattern: StudioPattern) -> some View {
        if pattern.fileName != nil, !pattern.bounceDirty {
            Label("Bounced — plays offline in collections", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Theme.fgDim)
        } else if pattern.fileName != nil, pattern.bounceDirty {
            Label("Bounce out of date — the pattern changed since it was bounced", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(Theme.fgDim)
        }
    }

    // MARK: - Playback preparation (resolve targets → PCM buffers keyed by ROW INDEX)

    /// Build every sounding row's buffer, then hand the set to the engine. Missing targets and
    /// unreadable files are SKIPPED (spec §2: never a throw) with an advisory notice; only a
    /// fully-empty result blocks playback.
    /// Solo-preview ONE row from its header tap (SEQ1): play only that row's steps, looping at
    /// the pattern BPM. Re-tapping the row that's soloing (or the main transport) stops. Uses the
    /// same prepare → load → start path as a full play, with just this row's buffer + soloedRow.
    private func toggleSolo(row i: Int) {
        // Re-tap the row that's already soloing ⇒ stop.
        if engine.loadedPatternId == patternId, engine.isPlayingPattern, engine.soloedRow == i {
            engine.stopPattern()
            return
        }
        guard let pattern = studio.pattern(patternId), pattern.rows.indices.contains(i) else { return }
        let row = pattern.rows[i]
        guard !row.isSilent else { notice = "This row has no steps to preview — add a step first."; return }
        guard studio.targetExists(row.targetId) else { notice = "This row's sample or loop was removed."; return }
        prepareTask?.cancel()
        prepGeneration += 1
        let gen = prepGeneration
        notice = nil
        preparing = true
        prepareTask = Task {
            defer { if gen == prepGeneration { preparing = false } }
            guard let natural = await preparedBuffer(for: row.targetId) else {
                if gen == prepGeneration { notice = "Couldn't prepare audio for \(rowTitle(row.targetId))." }
                return
            }
            // Pre-stretch just this row's span variants (deduped by span).
            var spanBuffers: [Int: [Int: AVAudioPCMBuffer]] = [:]
            var cache: [Int: AVAudioPCMBuffer] = [:]
            let stepF = StudioEngine.stepFrames(bpm: pattern.bpm,
                                                sampleRate: StudioAudio.canonicalSampleRate)
            for col in row.steps.indices where row.steps[col] && row.stepSpans[col] > 0 {
                let span = row.stepSpans[col]
                if cache[span] == nil {
                    cache[span] = try? await StudioRender.shared.stretchBuffer(natural, toFrames: stepF * Int64(span))
                }
                if let b = cache[span] { spanBuffers[i, default: [:]][span] = b }
                guard gen == prepGeneration, !Task.isCancelled else { return }
            }
            guard gen == prepGeneration, !Task.isCancelled else { return }
            engine.loadPattern(pattern, buffers: [i: natural], spanBuffers: spanBuffers, soloedRow: i)
            engine.startPattern()
        }
    }

    private func startPlayback(_ pattern: StudioPattern) {
        prepareTask?.cancel()
        prepGeneration += 1
        let gen = prepGeneration
        notice = nil
        preparing = true
        prepareTask = Task {
            defer { if gen == prepGeneration { preparing = false } }
            var buffers: [Int: AVAudioPCMBuffer] = [:]
            var skipped: [String] = []
            for (i, row) in pattern.rows.prefix(StudioEngine.maxPatternRows).enumerated() {
                guard gen == prepGeneration, !Task.isCancelled else { return }
                guard !row.isSilent else { continue }                    // no on-steps — decode is wasted work
                guard studio.targetExists(row.targetId) else { continue } // missing row — muted by design
                if let buf = await preparedBuffer(for: row.targetId) {
                    buffers[i] = buf
                } else {
                    skipped.append(rowTitle(row.targetId))
                }
            }
            guard gen == prepGeneration, !Task.isCancelled else { return }
            guard !buffers.isEmpty else {
                notice = skipped.isEmpty
                    ? "Nothing can sound — every active row's target was removed."
                    : "Couldn't prepare audio for: \(skipped.joined(separator: ", "))."
                return
            }
            if !skipped.isEmpty {
                notice = "Skipped (audio unavailable): \(skipped.joined(separator: ", "))."
            }
            // Pre-stretch every span variant an on-step demands (deduped by target+span — the
            // same sample fit to the same span on two rows stretches once). A failed stretch
            // falls back to the natural buffer at schedule time — a degraded hit, never a block.
            var spanBuffers: [Int: [Int: AVAudioPCMBuffer]] = [:]
            var stretchCache: [StudioStretchKey: AVAudioPCMBuffer] = [:]
            let stepF = StudioEngine.stepFrames(bpm: pattern.bpm,
                                                sampleRate: StudioAudio.canonicalSampleRate)
            for (i, row) in pattern.rows.prefix(StudioEngine.maxPatternRows).enumerated() {
                guard let natural = buffers[i] else { continue }
                for col in row.steps.indices where row.steps[col] && row.stepSpans[col] > 0 {
                    let span = row.stepSpans[col]
                    let key = StudioStretchKey(targetId: row.targetId, span: span)
                    if stretchCache[key] == nil {
                        stretchCache[key] = try? await StudioRender.shared
                            .stretchBuffer(natural, toFrames: stepF * Int64(span))
                    }
                    if let b = stretchCache[key] { spanBuffers[i, default: [:]][span] = b }
                }
                guard gen == prepGeneration, !Task.isCancelled else { return }
            }
            // Reload the pattern FRESH from the store — the user may have toggled steps while
            // buffers were rendering — but ONLY when the prepared audio still fits it: the
            // buffers hold the SNAPSHOT's targets and the span buffers are tempo-fit to the
            // snapshot's bpm, so a mid-prepare bpm/retarget/span edit must play the snapshot
            // (the "edits apply next Play" banner contract) rather than off-grid/wrong audio.
            let current = studio.pattern(patternId) ?? pattern
            let compatible = current.bpm == pattern.bpm
                && current.rows.map(\.targetId) == pattern.rows.map(\.targetId)
                && current.rows.map(\.stepSpans) == pattern.rows.map(\.stepSpans)
            engine.loadPattern(compatible ? current : pattern,
                               buffers: buffers, spanBuffers: spanBuffers,
                               startStep: startStep, loopEnabled: loopEnabled, loopBars: loopBars)
            engine.startPattern()
        }
    }

    /// Resolve ONE target id to the canonical PCM buffer the engine schedules (task contract):
    ///   • loops → decode the rendered CAF, then trim/pad to the loop's AUTHORITATIVE `frames`
    ///     (ms-derived counts round differently per rate; a ±1-frame seam retriggers off-beat);
    ///   • samples → ensure the render cache is FRESH (bake edits via StudioRender when not),
    ///     then decode rendered-or-raw via `localURLForPlayback` (raw = the no-stale-bake
    ///     fallback when rendering failed — edits inaudible rather than wrong audio).
    /// The security-scope `release` is dropped right after decode: the buffer is a full copy,
    /// nothing reads the file again (the engine's `playLoop` precedent).
    private func preparedBuffer(for targetId: String) async -> AVAudioPCMBuffer? {
        if targetId.hasPrefix("lp_"), let loop = studio.loop(targetId) {
            guard let got = studio.localURLForPlayback(id: targetId) else { return nil }
            let decoded = try? await StudioRender.shared.decodeBuffer(url: got.url)
            got.release?()
            guard let decoded else { return nil }
            // frames ≤ 0 only on a degraded document — play the decode as-is rather than nothing.
            return loop.frames > 0 ? StudioAudio.trimmedOrPadded(decoded, to: loop.frames) : decoded
        }
        if targetId.hasPrefix("smp_") {
            if let s = studio.sample(targetId), !s.isRenderFresh {
                await ensureFreshRender(s)
            }
            guard let got = studio.localURLForPlayback(id: targetId) else { return nil }
            let decoded = try? await StudioRender.shared.decodeBuffer(url: got.url)
            got.release?()
            return decoded
        }
        return nil
    }

    /// Bake a sample's edits into its render cache (`sample-<id>-r<rev>.m4a`) and file the
    /// result. Failure is silent-but-logged (StudioRender rlogs): `localURLForPlayback` then
    /// falls back to the raw capture, so the row still sounds — just without the edits.
    private func ensureFreshRender(_ s: StudioSample) async {
        let bm = studio.bookmark(for: .samples)
        guard let src = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                              wasUserFolder: s.wasUserFolder, bookmark: bm) else { return }
        guard let dest = StudioFolders.folder(.samples, bookmark: bm) else {
            src.release?()
            return
        }
        // The revision is captured BEFORE the await: if the user edits mid-render the store bumps
        // `renderRevision`, `setRenderedSample` files the OLD revision, and `isRenderFresh` stays
        // false — the stale bake is never preferred (the store's revision-stamp contract).
        let name = StudioFolders.renderedSampleFileName(id: s.id, revision: s.renderRevision)
        do {
            _ = try await StudioRender.shared.renderSample(s, sourceURL: src.url,
                                                           to: dest.url.appendingPathComponent(name))
            studio.setRenderedSample(s.id, fileName: name, wasUserFolder: dest.isUserFolder,
                                     revision: s.renderRevision)
        } catch {
            // Raw fallback (above). No user-facing error: the render is an optimization pass.
        }
        src.release?()
        dest.release?()
    }

    private func rowTitle(_ targetId: String) -> String {
        studio.displayInfo(forStudioId: targetId)?.title ?? "Untitled"
    }

    // MARK: - Bounce (offline render → pattern-<id>.m4a; collections play it when not dirty)

    /// Overflow "Bounce": pre-render row buffers (keyed by TARGET id — `bouncePattern`'s
    /// contract, unlike the engine's row-index keying) and write the one-bar bounce. Collection
    /// playback ALSO bounces lazily elsewhere; this button exists so the user can bounce ahead
    /// of going offline.
    private func bounce(_ pattern: StudioPattern) {
        guard !bouncing else { return }
        notice = nil
        bouncing = true
        Task {
            defer { bouncing = false }
            var buffers: [String: AVAudioPCMBuffer] = [:]
            for row in pattern.rows.prefix(StudioEngine.maxPatternRows) where !row.isSilent {
                // Dedupe by target: the same sample on two rows decodes once.
                guard studio.targetExists(row.targetId), buffers[row.targetId] == nil else { continue }
                if let buf = await preparedBuffer(for: row.targetId) {
                    buffers[row.targetId] = buf
                }
            }
            guard !buffers.isEmpty else {
                notice = "Nothing to bounce — no active row has playable audio."
                return
            }
            let bm = studio.bookmark(for: .sequences)
            guard let dest = StudioFolders.folder(.sequences, bookmark: bm) else {
                notice = "Bounce failed — the sequences folder is unavailable."
                return
            }
            let name = StudioFolders.fileName(.sequences, id: pattern.id)
            do {
                let spans = await StudioPatternBouncer.stretchSpanBuffers(pattern: pattern,
                                                                          natural: buffers)
                _ = try await StudioRender.shared.bouncePattern(pattern, buffers: buffers,
                                                                spanBuffers: spans,
                                                                to: dest.url.appendingPathComponent(name))
                // Clear the dirty flag ONLY if the pattern still matches what was bounced — an
                // edit that landed mid-render means the file on disk is already stale, and
                // `setPatternBounced` would wrongly bless it.
                if let now = studio.pattern(patternId), now.rows == pattern.rows, now.bpm == pattern.bpm {
                    studio.setPatternBounced(patternId, fileName: name, wasUserFolder: dest.isUserFolder)
                    notice = "Bounced — this pattern now plays offline in collections."
                } else {
                    notice = "Bounced, but the pattern changed while rendering — bounce again to refresh."
                }
            } catch {
                notice = "Bounce failed: \(error.localizedDescription)"
            }
            dest.release?()
        }
    }
}

// MARK: - One pattern row (target header + gain + remove + 16-step grid)

/// One sequencer row: target label (muted "missing" style when the sample/loop was deleted —
/// the row stays, playback/bounce skip it), the gain chip (fixed-width popover slider), remove,
/// and the step grid. Compact width renders the 16 steps as TWO lines of 8; both layouts group
/// steps in fours with wider gaps (the beat-group separators, spec §11).
private struct PatternRowCard: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    /// SEQ2: when on, step + loop-mode edits mirror into a running pattern (heard next bar).
    @AppStorage("pdj.sequencerLive") private var sequencerLive = false
    let patternId: String
    let rowIndex: Int
    let row: StudioPatternRow
    let compact: Bool
    /// This pattern is the one the engine is currently playing — gates the step highlight so a
    /// DIFFERENT loaded pattern's clock never lights up this grid.
    let playingThis: Bool
    /// Collapsed ⇒ show only the header (hide the step grid + mixer deck) so a many-lane pattern
    /// (e.g. a Demuxer kick/snare/bass/perc export) stays scannable.
    let collapsed: Bool
    /// Zoom: bars (16 steps) shown per grid line. 1 = one bar/line (big cells, focus a bar); higher
    /// packs more bars per line (smaller cells → the whole song fits in fewer lines).
    let barsPerLine: Int
    /// SEQ5: the resting playhead cursor (a pattern step) — drawn as a start-locator on the grid;
    /// where Play begins. Jumps to the last pad touched; reset by the refresh button.
    let cursorStep: Int
    /// SEQ5: the ∞ looper — when on, the loop window (a `loopBars`-bar span anchored at the cursor)
    /// is tinted so the repeating section reads at a glance.
    let loopEnabled: Bool
    let loopBars: Int
    /// Tap the row header to solo-preview just this row (SEQ1).
    var onSolo: (Int) -> Void
    var onToggleCollapse: () -> Void
    var onRename: () -> Void
    /// SEQ5: a pad in this row was touched — re-home the playhead cursor to that column.
    var onTouchStep: (Int) -> Void

    /// SEQ3: reveal this row's per-track mixer deck (collapsed by default so a long pattern's
    /// rows stay compact).
    @State private var deckExpanded = false
    /// How many grid LINES (bars) this lane currently renders. A 75-bar pattern is 75 lines on
    /// regular width and 150 on compact iPhone, and every line carries 16 step Buttons, a marker
    /// overlay AND its own `TimelineView` — so building them all in the open transaction is what
    /// froze the editor for seconds. The window opens at roughly a screenful and grows a chunk
    /// per frame, so the pattern is on screen and playable immediately and the remaining bars
    /// fill in behind. Deliberately per-lane `@State`: lanes fill independently and a collapsed
    /// lane never spends anything.
    @State private var shownLines = PatternRowCard.linesPerChunk
    fileprivate static let linesPerChunk = 8

    /// The engine is currently soloing THIS row (its header shows a Stop glyph).
    private var soloingThis: Bool {
        engine.isPlayingPattern && engine.loadedPatternId == patternId && engine.soloedRow == rowIndex
    }

    /// Grid geometry shared by the toggle layer AND the highlight overlay — identical structure
    /// (groups of 4 + these exact spacings) is what keeps the two layers pixel-aligned.
    private static let groupSpacing: CGFloat = 12
    private static let cellSpacing: CGFloat = 4
    private static let cellHeight: CGFloat = 34
    private static let cellRadius: CGFloat = 6

    private var missing: Bool { !studio.targetExists(row.targetId) }
    private var info: (title: String, lengthMs: Int, bpm: Double?, kindLabel: String)? {
        studio.displayInfo(forStudioId: row.targetId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                stepGrid
                rowDeck
            } else {
                Text("\(row.steps.filter { $0 }.count) hit\(row.steps.filter { $0 }.count == 1 ? "" : "s") · collapsed")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        // The row cards are keyed by INDEX, so a delete/reorder/retarget reuses this view instance
        // with a different underlying row. Collapse the deck whenever THIS slot's target changes so
        // an expanded deck can never be misattributed to the wrong row. (Step edits keep the same
        // targetId, so toggling steps never collapses it.)
        .onChange(of: row.targetId) { deckExpanded = false }
    }

    // MARK: Per-track mixer deck (SEQ3)

    /// A collapsed-by-default `StudioMixerDeck` for a SAMPLE row — tempo / pitch / compressor ·
    /// reverb · delay · filter that BAKE into the row's buffer on the next Play (the sequencer
    /// re-renders a row whose target sample edit changed). Gain and the looper are hidden: the
    /// row's LIVE loudness is the header's `RowGainChip`, and looping is the pattern's job. Loops
    /// (`lp_`) carry their edits baked into the CAF, so they have no editable deck.
    @ViewBuilder private var rowDeck: some View {
        if let s = studio.sample(row.targetId) {
            VStack(alignment: .leading, spacing: 8) {
                // A plain expander button (not a DisclosureGroup — its container tap doesn't toggle
                // reliably under XCUITest) so the reveal is directly addressable + drivable.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { deckExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Mixer deck")
                        Spacer(minLength: 0)
                        Image(systemName: deckExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.fgDim)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("seq-row-deck-\(rowIndex)")
                if deckExpanded {
                    StudioMixerDeck(edit: s.edit, showGain: false, showLooper: false,
                                    idPrefix: "seq-deck-\(rowIndex)") { e in
                        let clamped = e.clamped()
                        // Persist to the sample (bumps renderRevision → the row re-bakes next Play)
                        // and mark THIS pattern's bounce stale so its collection playback re-bounces.
                        studio.updateSampleEdit(s.id, clamped)
                        // Mark the bounce dirty ONCE — not on every slider tick (mutatePattern does a
                        // synchronous saveNow; bounceDirty is idempotent, so re-marking is pure jank).
                        if studio.pattern(patternId)?.bounceDirty == false {
                            studio.mutatePattern(patternId) { _ in }
                        }
                        // If that sample is loaded in the audition chain (open in the editor), keep
                        // the live voicing in sync too.
                        if engine.loadedSampleId == s.id { engine.applyEdit(clamped) }
                    }
                    Text("Shapes this sample — heard on the next Play.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    // MARK: Header (label · gain · remove)

    /// The lane's display name: a custom row label if set, else the target's own name.
    private var displayTitle: String {
        if let l = row.label, !l.isEmpty { return l }
        if let t = info?.title, !t.isEmpty { return t }
        return row.targetId.hasPrefix("lp_") ? "Loop" : "Sample"
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Collapse/expand just this lane (hides its step grid + deck).
            Button { onToggleCollapse() } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.bold)).foregroundStyle(Theme.fgDim)
                    .frame(width: 18, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand lane" : "Collapse lane")
            .accessibilityIdentifier("seq-row-collapse-\(rowIndex)")
            // Tap the icon+title to SOLO-preview just this row (SEQ1). Kept separate from the
            // retarget / gain / remove controls so a preview tap can't fire them by accident.
            Button {
                onSolo(rowIndex)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: soloingThis ? "stop.circle.fill"
                          : (row.targetId.hasPrefix("lp_") ? "repeat" : "waveform"))
                        .foregroundStyle(soloingThis ? Theme.accent2 : (missing ? Theme.fgDim : Theme.accent))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(missing ? Theme.fgDim : Theme.fg)
                            .italic(missing)
                            .lineLimit(1)
                        Text(missing ? "missing — playback and bounce skip this row"
                                     : (info?.kindLabel ?? ""))
                            .font(.caption2)
                            .foregroundStyle(missing ? Theme.danger.opacity(0.8) : Theme.fgDim)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(missing)
            .accessibilityIdentifier("seq-row-solo-\(rowIndex)")
            .accessibilityLabel(soloingThis ? "Stop preview" : "Preview this row")
            retargetMenu
            RowGainChip(rowIndex: rowIndex, gainDb: row.gainDb) { db in
                // Persist through the store (marks the bounce dirty, debounced save) AND mirror
                // into the live mixer when THIS pattern is loaded — row gain is the one edit
                // that applies while playing (mixer volume, no schedule impact).
                studio.setPatternRowGain(patternId, row: rowIndex, gainDb: db)
                if engine.loadedPatternId == patternId {
                    engine.setPatternRowGain(row: rowIndex, gainDb: db)
                }
            }
            Button { onRename() } label: {
                Image(systemName: "pencil").foregroundStyle(Theme.fgDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename lane")
            .accessibilityIdentifier("seq-row-rename-\(rowIndex)")
            .help("Rename this lane")
            Button {
                studio.removePatternRow(patternId, row: rowIndex)
            } label: {
                Image(systemName: "xmark.circle").foregroundStyle(Theme.fgDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove row")
            .accessibilityIdentifier("seq-row-remove-\(rowIndex)")
            .help("Remove row")
        }
    }

    /// Re-point this row at a different sample/loop, keeping its steps/modes/gain — the "morph"
    /// move: an extracted drum pattern's kick lane re-triggers a hit cut from another song.
    private var retargetMenu: some View {
        // Shared + memoized on the store: `Menu` content is built eagerly, so sorting here
        // meant one ICU sort of the whole library PER LANE PER body evaluation.
        let samples = studio.samplesByName
        let loops = studio.loopsByName
        return Menu {
            if !samples.isEmpty {
                Section("Samples") {
                    ForEach(samples) { s in
                        Button { studio.setPatternRowTarget(patternId, row: rowIndex, targetId: s.id) } label: {
                            if s.id == row.targetId {
                                Label(s.name.isEmpty ? "Untitled sample" : s.name, systemImage: "checkmark")
                            } else {
                                Text(s.name.isEmpty ? "Untitled sample" : s.name)
                            }
                        }
                        .accessibilityIdentifier("seq-row-retarget-\(rowIndex)-\(s.id)")
                    }
                }
            }
            if !loops.isEmpty {
                Section("Loops") {
                    ForEach(loops) { l in
                        Button { studio.setPatternRowTarget(patternId, row: rowIndex, targetId: l.id) } label: {
                            if l.id == row.targetId {
                                Label(l.name.isEmpty ? "Untitled loop" : l.name, systemImage: "checkmark")
                            } else {
                                Text(l.name.isEmpty ? "Untitled loop" : l.name)
                            }
                        }
                        .accessibilityIdentifier("seq-row-retarget-\(rowIndex)-\(l.id)")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.fgDim)
        }
        .accessibilityLabel("Change row target")
        .accessibilityIdentifier("seq-row-retarget-\(rowIndex)")
        .help("Swap the sample/loop this row triggers (steps and modes stay)")
    }

    // MARK: Step grid

    private var stepGrid: some View {
        // Compact: two lines of 8 (spec §11); regular: one line of 16. Column ids stay 0–15
        // either way so `seq-step-<row>-<col>` is stable across layouts.
        VStack(spacing: 6) {
            // SEQ4: wrap the row's steps into lines of one bar (16), or half-bars (8) on compact
            // iPhone. A 16-step pattern lays out exactly as before; a long one stacks its bars.
            // Zoom: one bar per line (16, or 8 on compact) times barsPerLine — more bars per line
            // shrinks the cells so a long pattern fits in fewer lines.
            let perLine = (compact ? 8 : 16) * max(1, barsPerLine)
            let n = row.steps.count
            let lines = max(1, (n + perLine - 1) / perLine)
            // PROGRESSIVE: only `shownLines` bars are built now, the rest stream in a chunk per
            // frame (see `shownLines`). Hoisted here — NOT read inside `stepCell` — because
            // `spanCoverage` allocates and scans a full step-count array on every read, and
            // reading it per cell made grid construction quadratic in pattern length.
            let coverage = spanCoverage
            ForEach(0..<min(shownLines, lines), id: \.self) { line in
                let lo = line * perLine
                stepLine(lo..<min(lo + perLine, n), coverage: coverage)
            }
            if shownLines < lines {
                pendingBars(lines - shownLines)
                    // Self-driving: each chunk lands, the view re-renders, this task re-fires
                    // and schedules the next. The sleep is one frame, so every batch of bars
                    // paints — and stays tappable — while the remainder is still arriving.
                    // Ends when the window covers `lines` and this branch disappears.
                    .task(id: shownLines) {
                        try? await Task.sleep(for: .milliseconds(16))
                        guard !Task.isCancelled else { return }
                        shownLines = min(shownLines + Self.linesPerChunk, lines)
                    }
            }
        }
    }

    /// Placeholder for the bars that haven't been built yet — the visible half of "slide into
    /// the sequence and watch it fill in" rather than staring at a frozen screen.
    private func pendingBars(_ remaining: Int) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("\(remaining) more bar\(remaining == 1 ? "" : "s")…")
                .font(.caption2).foregroundStyle(Theme.fgDim)
            Spacer()
        }
        .frame(height: Self.cellHeight)
        .accessibilityIdentifier("seq-pending-bars-\(rowIndex)")
    }

    /// One rendered line of the grid: the tappable toggles plus, OVERLAID, the playing-step
    /// highlight. The highlight lives in its own `TimelineView` layer (hit-testing off, same
    /// nested group structure so it aligns) instead of inside the buttons: the clock is sampled
    /// ~30×/s, and redrawing ONLY passive rectangles keeps the fast clock from re-creating the
    /// buttons mid-tap (the StudioPatternClock / dead-play-button doctrine).
    private func stepLine(_ cols: Range<Int>, coverage: [Bool]) -> some View {
        let groups = beatGroups(cols)
        return HStack(spacing: Self.groupSpacing) {
            ForEach(groups, id: \.lowerBound) { group in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(group, id: \.self) { col in stepCell(col, coverage: coverage) }
                }
            }
        }
        // Task #60 fix: the downbeat border + loop/span badges used to live as THREE stacked
        // `.overlay()` modifiers directly on each tappable step cell. On iPad (16 cells sharing
        // one HStack) that broke the tap→cell a11y mapping — tapping the identifier for column N
        // toggled column N+1 instead (confirmed with a from-scratch minimal reproduction: ANY
        // second view composited onto the per-cell shape reproduced it, whether via `.overlay`
        // or `ZStack`, conditional or unconditional content — so it's not about `_ConditionalContent`
        // specifically, it's the extra per-cell view composition itself). Fix: keep each step
        // Button a SINGLE plain shape, and render the border/badges in their own non-interactive
        // overlay pass instead — the same architecture `markerLayer` already uses for the cursor
        // and loop-window band, which never exhibited the skew.
        .overlay { decorationLayer(cols) }
        .overlay { markerLayer(cols) }          // SEQ5: static loop-window band + playhead cursor
        .overlay {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playingThis)) { _ in
                // Sampled, never observed: `patternClock` is deliberately not @Observable.
                // During the ~0.1s start-latency pre-roll `currentStep` is nil (nothing sounds yet);
                // the resting white cursor is already hidden, so light the FIRST step Play will hit
                // (mappedStep at slot 0) to bridge the gap — no marker-less flicker at Play start.
                let preroll = StudioEngine.mappedStep(slot: 0, startStep: cursorStep, loopEnabled: loopEnabled,
                                                      loopBars: loopBars, stepCount: max(1, row.steps.count))
                let current = playingThis ? (engine.patternClock.currentStep ?? preroll) : nil
                HStack(spacing: Self.groupSpacing) {
                    ForEach(groups, id: \.lowerBound) { group in
                        HStack(spacing: Self.cellSpacing) {
                            ForEach(group, id: \.self) { col in
                                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                                    .strokeBorder(Theme.accent2, lineWidth: 2)
                                    .frame(height: Self.cellHeight)
                                    .frame(maxWidth: .infinity)
                                    .opacity(col == current ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// SEQ5 static overlay: the ∞ loop-window band (faint turquoise fill on the bars that repeat)
    /// and the playhead cursor (a start-locator outline + a ▼ tab on the column Play begins at).
    /// Persistent (not in a TimelineView) — it depends only on the cursor/loop props, so it
    /// redraws on a control change, never on the fast clock. Hit-testing off so it never eats a
    /// pad tap. Mirrors `stepLine`'s exact group/cell geometry so it stays pixel-aligned.
    private func markerLayer(_ cols: Range<Int>) -> some View {
        let groups = beatGroups(cols)
        let n = max(1, row.steps.count)
        let cursor = min(max(0, cursorStep), n - 1)
        let window = loopEnabled
            ? StudioEngine.loopWindow(startStep: cursorStep, loopBars: loopBars, stepCount: n)
            : nil
        return HStack(spacing: Self.groupSpacing) {
            ForEach(groups, id: \.lowerBound) { group in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(group, id: \.self) { col in
                        let inLoop = window.map { col >= $0.start && col < $0.start + $0.len } ?? false
                        ZStack {
                            RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                                .fill(Theme.accent2.opacity(inLoop ? 0.14 : 0))
                                .frame(height: Self.cellHeight)
                                .frame(maxWidth: .infinity)
                            // The resting cursor shows only while stopped — during play the moving
                            // turquoise playhead is the live position, and on stop the cursor parks
                            // at the last played pad (playButton writes `startStep` there).
                            if col == cursor, !playingThis {
                                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                                    .strokeBorder(Theme.fg.opacity(0.9), lineWidth: 2)
                                    .frame(height: Self.cellHeight)
                                    .frame(maxWidth: .infinity)
                                    .overlay(alignment: .top) {
                                        Image(systemName: "arrowtriangle.down.fill")
                                            .font(.system(size: 7))
                                            .foregroundStyle(Theme.fg)
                                            .offset(y: -5)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Task #60: the downbeat border + loop/span badges, moved OUT of the per-cell Button (see
    /// `stepCell`) into their own non-interactive layer — mirrors `markerLayer`'s exact
    /// group/cell geometry so it stays pixel-aligned, and never eats a pad tap.
    private func decorationLayer(_ cols: Range<Int>) -> some View {
        let groups = beatGroups(cols)
        return HStack(spacing: Self.groupSpacing) {
            ForEach(groups, id: \.lowerBound) { group in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(group, id: \.self) { col in
                        let on = row.steps.indices.contains(col) && row.steps[col]
                        let loops = on && row.loopSteps.indices.contains(col) && row.loopSteps[col]
                        let span = on && row.stepSpans.indices.contains(col) ? row.stepSpans[col] : 0
                        RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                            // Downbeat columns get a brighter border — the at-a-glance 4/4 anchor.
                            .strokeBorder(col % 4 == 0 ? Theme.fgDim.opacity(0.55) : Theme.border, lineWidth: 1)
                            .frame(height: Self.cellHeight)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "repeat")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.bg)
                                    .padding(2)
                                    .opacity(loops ? 1 : 0)
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text("×\(span)")
                                    .font(.system(size: 8, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(Theme.bg)
                                    .padding(2)
                                    .opacity(span > 0 ? 1 : 0)
                            }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Split a column range into beat groups of 4 — the visual beat-group separators are the
    /// WIDER `groupSpacing` between these groups.
    private func beatGroups(_ cols: Range<Int>) -> [Range<Int>] {
        stride(from: cols.lowerBound, to: cols.upperBound, by: 4).map {
            $0..<min($0 + 4, cols.upperBound)
        }
    }

    /// Columns swept by an EARLIER trigger's stretch span (trigger col excluded) — rendered
    /// with a faint fill so the fit's musical footprint reads at a glance.
    private var spanCoverage: [Bool] {
        var cov = Array(repeating: false, count: row.steps.count)
        for col in row.steps.indices where row.steps[col] {
            let span = row.stepSpans.indices.contains(col) ? row.stepSpans[col] : 0
            guard span > 1 else { continue }
            for c in (col + 1)..<min(col + span, row.steps.count) { cov[c] = true }
        }
        return cov
    }

    /// `coverage` is `spanCoverage` computed ONCE by the caller. It used to be read (twice) as a
    /// computed property right here, which rebuilt and rescanned a full step-count array for
    /// every off-cell in the grid — O(steps²) per lane, the term that made long patterns fall
    /// off a cliff rather than merely get slower.
    private func stepCell(_ col: Int, coverage: [Bool]) -> some View {
        let on = row.steps.indices.contains(col) && row.steps[col]
        let loops = on && row.loopSteps.indices.contains(col) && row.loopSteps[col]
        let span = on && row.stepSpans.indices.contains(col) ? row.stepSpans[col] : 0
        let covered = !on && coverage.indices.contains(col) && coverage[col]
        // Task #60 fix: this Button's label is now a SINGLE plain shape — no per-cell `.overlay`
        // stack. The downbeat border + loop/span badges moved to `decorationLayer`, a shared
        // non-interactive pass over the whole line (see that function's doc for why: compositing
        // a second view onto the tappable shape — via `.overlay` OR `ZStack`, conditional or not —
        // was breaking the tap→cell a11y mapping on iPad).
        return Button {
            studio.setPatternStep(patternId, row: rowIndex, col: col, on: !on)
            if sequencerLive, playingThis { engine.updateLiveStep(row: rowIndex, col: col, on: !on) }
            onTouchStep(col)   // SEQ5: re-home the playhead cursor to the touched pad
        } label: {
            RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                // A missing row's on-steps render dimmed: the data is kept (re-adding the target
                // revives it) but nothing will sound — the fill mirrors that truth. Span-covered
                // off-cells carry a faint wash (the stretch footprint).
                .fill(on ? Theme.accent.opacity(missing ? 0.35 : 1)
                         : (covered ? Theme.accent.opacity(0.16) : Theme.bgOverlay))
                .frame(height: Self.cellHeight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(col + 1)")
        .accessibilityValue(on ? (loops ? "loop" : "one-shot") + (span > 0 ? ", fit \(span) steps" : "") : "")
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("seq-step-\(rowIndex)-\(col)")
        // Long-press (iOS) / right-click (macOS) step modes — only an ON step has any.
        .contextMenu { if on { stepModeMenu(col, loops: loops, span: span) } }
    }

    /// The per-step trigger-mode menu: one-shot vs loop, and the tempo-fit span. Edits ride
    /// `mutatePattern` (bounce re-dirties) and — like step/BPM edits — apply on the next Play.
    @ViewBuilder private func stepModeMenu(_ col: Int, loops: Bool, span: Int) -> some View {
        Button {
            studio.setPatternStepLoop(patternId, row: rowIndex, col: col, loop: !loops)
            if sequencerLive, playingThis { engine.updateLiveStepLoop(row: rowIndex, col: col, loop: !loops) }
        } label: {
            Label(loops ? "One-shot (play once)" : "Loop until retriggered",
                  systemImage: loops ? "1.circle" : "repeat")
        }
        .accessibilityIdentifier("seq-step-loop-\(rowIndex)-\(col)")
        Picker("Fit to steps", selection: Binding(
            get: { span },
            set: { studio.setPatternStepSpan(patternId, row: rowIndex, col: col, span: $0) })) {
            Text("Natural length").tag(0)
            ForEach([1, 2, 3, 4, 6, 8, 12, 16], id: \.self) { n in
                Text(n == 1 ? "1 step" : "\(n) steps").tag(n)
            }
        }
        .accessibilityIdentifier("seq-step-span-\(rowIndex)-\(col)")
    }
}

// MARK: - Row-gain chip (fixed-width popover slider)

/// The row-gain control: a small dB chip that opens a FIXED-WIDTH popover slider — the MixView
/// chip-popover pattern (spec §11 / iPhone-portrait rule: an in-place slider in this narrow row
/// header is undraggable). Used on every platform for one consistent interaction; dismisses on
/// an outside tap (native popover) or after 3 s idle.
private struct RowGainChip: View {
    let rowIndex: Int
    let gainDb: Double
    let onChange: (Double) -> Void

    @State private var showPopover = false
    /// Bumped on every slider change to (re)start the 3 s idle auto-dismiss.
    @State private var interaction = 0

    private var label: String {
        gainDb == 0 ? "0 dB" : String(format: "%+.1f dB", gainDb)
    }

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                Text(label).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .foregroundStyle(Theme.fgDim)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Row gain")
        .accessibilityIdentifier("seq-row-gain-\(rowIndex)-open")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Row gain", systemImage: "speaker.wave.2")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { gainDb },
                                          set: { onChange($0); interaction += 1 }),
                           in: -24...12, step: 0.5)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("seq-row-gain-\(rowIndex)")
                    Text(label)
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .padding(16)
            .frame(width: 290)                              // fixed width — room to actually drag
            .presentationCompactAdaptation(.popover)        // stay a popover on iPhone (not a sheet)
            // 3 s idle auto-dismiss; every slider change restarts the timer.
            .task(id: interaction) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { showPopover = false }
            }
        }
    }
}
