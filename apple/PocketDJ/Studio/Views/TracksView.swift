import SwiftUI

// MARK: - Tracks (multitrack arranger) sub-tab
//
// A lightweight multitrack arranger. Left: a fixed track-header column (name + mix strip: gain /
// mute / solo + row menu). Right: a horizontally-scrolling timeline where each track's clips are
// positioned blocks on a shared ms→px grid — stem-coloured, carrying a waveform, DRAGGABLE, with
// the empty space BETWEEN blocks being the "gaps" (silence). Clips are immutable baked snapshots
// (Stage B: add from any studio source via the picker). Synced playback + a global playhead (C),
// live record (D), and bounce-to-master (E) slot into the same layout. All state is in StudioStore.
struct TracksView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentPackStore.self) private var packs
    @Environment(StudioMicRecorder.self) private var mic
    @Environment(SettingsStore.self) private var settings
    @Environment(BurnStore.self) private var burns
    @Environment(AppModel.self) private var app
    @Environment(StudioNavState.self) private var nav

    /// The open arrangement (nil ⇒ the HOME browser of arrangements + folders — the tab lands here).
    @State private var openArrangementId: String?

    // Home browser: folder collapse (persisted) + a per-row move-to-folder target.
    @State private var collapsed: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "pdj.arrangementFolders.collapsed") ?? [])
    @State private var pendingDeleteArrangementId: String?

    // Timeline zoom + playhead-follow (the Demux timeline pattern).
    @State private var pxPerSec: CGFloat = 48
    @State private var followPlayhead = true
    @State private var centerNonce = 0
    /// Visible width of the timeline viewport — lets zoom-out reach a fit-to-width floor so the whole
    /// arrangement fits on screen.
    @State private var timelineViewportWidth: CGFloat = 0
    /// The playback cursor position (ms) when stopped — set by a ruler tap; Play starts here.
    @State private var cursorMs = 0

    // Rename affordances (cross-platform alert + TextField).
    @State private var pendingRenameArrangementId: String?
    @State private var nameText = ""
    /// The track being edited in the dual name/colour/pan sheet (tap the name OR the colour chip).
    @State private var editTrackId: String?

    // Add-clip source picker (which track it targets) + a busy spinner.
    @State private var pickerTrackId: String?
    @State private var baking = false
    @State private var busyMessage = "Working…"

    // Bounce-selected sheet.
    @State private var bounceSelecting = false
    @State private var bounceSelection: Set<String> = []

    // Tempo entry (drives the beat grid + looper snap).
    @State private var pendingBpm = false
    @State private var bpmText = ""

    // Arrangement-folder organizer (in-content only; never the macOS menu bar).
    @State private var pendingNewFolder = false
    @State private var folderNameText = ""
    /// When set at new-folder time, the created folder immediately adopts this arrangement (the
    /// one-shot "New folder…" from the Move submenu). nil ⇒ just create an empty folder.
    @State private var newFolderMoveArrangementId: String?
    @State private var pendingRenameFolderId: String?
    @State private var pendingDeleteFolderId: String?

    // Per-clip waveform peaks (immutable clips → compute once, cache).
    @State private var clipPeaks: [String: [Float]] = [:]

    // Clip drag (horizontal reposition).
    @State private var dragClipId: String?
    @State private var dragDX: CGFloat = 0

    // Synced playback (view-scoped: stops on tab exit).
    @State private var player = MultitrackPlayer()

    // Live recording target (the track a take is being captured into).
    @State private var recordingTrackId: String?
    /// Master live-record: playback runs while the master output (with live FX) is captured, then
    /// baked into a Master track (#5).
    @State private var recordingMaster = false

    // Master-FX panel expansion (persisted).
    @AppStorage("pdj.tracks.showMasterFX") private var showMasterFX = false
    /// iPhone transport collapse — stacked controls fold away to maximize track space (persisted).
    @AppStorage("pdj.tracks.transportCollapsed") private var transportCollapsed = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif
    private var isCompact: Bool {
        #if os(iOS)
        return hSize == .compact
        #else
        return false
        #endif
    }

    // Layout grid (pxPerSec is @State above — zoomable).
    private let laneHeight: CGFloat = 66
    private let headerWidth: CGFloat = 172
    private let laneGap: CGFloat = 8
    private let rulerHeight: CGFloat = 24

    /// Named coordinate space for the scrolling timeline — loop-handle drags read the finger's
    /// position in it (from 0:00), independent of a handle's moved local origin.
    private static let timelineSpace = "tracksTimeline"
    /// Horizontal zoom stops (px per second); default 48.
    private static let zoomLadder: [CGFloat] = [16, 24, 36, 48, 72, 108, 160, 240]
    /// Fit-to-width px/sec: the whole arrangement fits the timeline viewport. Zoom-OUT keeps going
    /// down to this even below the ladder floor, so it always reaches "the entire track on screen".
    private func fitPx(_ arr: StudioArrangement) -> CGFloat {
        let secs = max(0.5, Double(arr.lengthMs) / 1000)
        guard timelineViewportWidth > 40 else { return Self.zoomLadder.first! }
        return max(1, (timelineViewportWidth - 28) / CGFloat(secs))
    }
    private func stepZoom(_ dir: Int, arr: StudioArrangement) {
        let fit = fitPx(arr)
        if dir < 0 {
            if let lower = Self.zoomLadder.last(where: { $0 < pxPerSec - 0.01 }), lower > fit { pxPerSec = lower }
            else { pxPerSec = fit }                    // keep zooming out until the whole track fits
        } else {
            pxPerSec = Self.zoomLadder.first(where: { $0 > pxPerSec + 0.01 }) ?? Self.zoomLadder.last!
        }
    }

    /// Track lane colours — the stem palette first (drums·yellow, bass·red, other·green,
    /// vocals·purple) then cue-extra hues, cycling at `StudioStore.trackPaletteSize` (= 8).
    static let trackColors: [Color] = [.yellow, .red, .green, .purple, .cyan, .orange, .pink, .mint]
    static let trackColorNames = ["Yellow", "Red", "Green", "Purple", "Cyan", "Orange", "Pink", "Mint"]
    static func color(_ index: Int) -> Color {
        trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count]
    }
    static func colorName(_ index: Int) -> String {
        trackColorNames[((index % trackColorNames.count) + trackColorNames.count) % trackColorNames.count]
    }

    private var current: StudioArrangement? { openArrangementId.flatMap { studio.arrangement($0) } }

    /// Signature of every clip id on screen — drives the peak-loading task when a clip is added.
    private var clipSignature: String {
        (current?.tracks.flatMap { $0.clips.map(\.id) } ?? []).joined(separator: ",")
    }

    /// Signature of the mix strip (mute/solo/gain/pan) — pushes live changes to the player mid-play.
    private var mixSignature: String {
        // 0.1 dB / 0.02 pan resolution so a sub-step live drag still fires applyMix (whole-unit
        // rounding made continuous slider moves audibly stepped mid-play).
        (current?.tracks.map {
            "\($0.muted ? 1 : 0)\($0.soloed ? 1 : 0)\(Int(($0.gainDb * 10).rounded()))p\(Int(($0.pan * 50).rounded()))"
        } ?? []).joined(separator: ",")
    }

    private func isPlayingThis(_ arr: StudioArrangement) -> Bool {
        player.isPlaying && player.playingArrangementId == arr.id
    }

    private var baseContent: some View {
        Group {
            if let arr = current {
                arrangerScreen(arr)
            } else {
                arrangementsHome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay { if baking { bakingOverlay } }
        .overlay { if recordingTrackId != nil { recordingOverlay } }
        .task { mic.settings = settings; mic.store = studio }
        .task(id: clipSignature) { await loadPeaks() }
        .onChange(of: openArrangementId, initial: true) {
            // Ask PerformanceView to hide its sub-tab picker while an arrangement is open (#1).
            nav.arrangerFullscreen = openArrangementId != nil
        }
        .onChange(of: current?.id) {
            // The open arrangement vanished (e.g. deleted from another window on the shared store) or
            // changed — stop a now-orphaned player so a looping mix can't play on with no transport,
            // and reset the seek cursor for the newly-opened arrangement.
            if player.isPlaying, player.playingArrangementId != current?.id { player.stop() }
            cursorMs = 0
        }
        .onChange(of: mixSignature) {
            if let arr = current, isPlayingThis(arr) { player.applyMix(arr.tracks) }
        }
        .onChange(of: current?.masterFX) {
            if let arr = current, isPlayingThis(arr) { player.applyMasterFX(arr.masterFX, bpm: arr.bpm) }
        }
        .onChange(of: current?.bpm) {
            if let arr = current, isPlayingThis(arr) { player.applyMasterFX(arr.masterFX, bpm: arr.bpm) }
        }
        .onChange(of: player.isPlaying) {
            // Playback stopped while master-recording (Stop / auto-stop) → bake the captured master.
            if !player.isPlaying, recordingMaster { bakeMasterRecording() }
        }
        .onDisappear {
            player.stop()
            if recordingTrackId != nil { _ = mic.stop(); recordingTrackId = nil }
            nav.arrangerFullscreen = false   // restore the picker when leaving the tab
        }
    }

    var body: some View {
        baseContent
        .sheet(item: pickerTrackBinding) { box in
            ClipSourcePicker(studio: studio, burns: burns, app: app,
                onPick: { sourceId, kind in
                    addClip(sourceId: sourceId, kind: kind, to: box.id)
                    pickerTrackId = nil
                },
                onPickStems: { songId in
                    importStems(songId: songId)
                    pickerTrackId = nil
                })
        }
        .sheet(isPresented: $bounceSelecting) { bounceSheet }
        .sheet(item: editTrackBinding) { box in
            if let a = current {
                TrackEditSheet(studio: studio, arrangementId: a.id, trackId: box.id)
            }
        }
        .alert("Rename arrangement", isPresented: renameArrangementShown) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { pendingRenameArrangementId = nil }
            Button("Rename") {
                if let id = pendingRenameArrangementId { studio.renameArrangement(id, to: nameText) }
                pendingRenameArrangementId = nil
            }
        }
        .confirmationDialog("Delete this arrangement? Its tracks and clips are removed.",
                            isPresented: deleteArrangementShown, titleVisibility: .visible) {
            Button("Delete arrangement", role: .destructive) {
                if let id = pendingDeleteArrangementId { deleteArrangement(id) }
                pendingDeleteArrangementId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteArrangementId = nil }
        }
        .alert("Tempo (BPM)", isPresented: $pendingBpm) {
            TextField("BPM", text: $bpmText)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
            Button("Cancel", role: .cancel) {}
            Button("Set") { if let a = current, let v = Double(bpmText) { studio.setArrangementBpm(a.id, bpm: v) } }
        } message: {
            Text("Sets the beat grid and looper snap. 20–300.")
        }
        .alert("New folder", isPresented: $pendingNewFolder) {
            TextField("Folder name", text: $folderNameText)
            Button("Cancel", role: .cancel) { newFolderMoveArrangementId = nil }
            Button("Create") { commitNewFolder() }
        }
        .alert("Rename folder", isPresented: renameFolderShown) {
            TextField("Folder name", text: $folderNameText)
            Button("Cancel", role: .cancel) { pendingRenameFolderId = nil }
            Button("Rename") {
                if let fid = pendingRenameFolderId { studio.renameArrangementFolder(fid, to: folderNameText) }
                pendingRenameFolderId = nil
            }
        }
        .confirmationDialog("Delete this folder? Its arrangements move to “No folder” (nothing is deleted).",
                            isPresented: deleteFolderShown, titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let fid = pendingDeleteFolderId { studio.deleteArrangementFolder(fid) }
                pendingDeleteFolderId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteFolderId = nil }
        }
    }

    private func commitNewFolder() {
        let f = studio.createArrangementFolder(folderNameText)
        if let aid = newFolderMoveArrangementId { studio.moveArrangementToFolder(aid, folderId: f.id) }
        newFolderMoveArrangementId = nil
    }

    private var renameArrangementShown: Binding<Bool> {
        Binding(get: { pendingRenameArrangementId != nil }, set: { if !$0 { pendingRenameArrangementId = nil } })
    }
    private var deleteArrangementShown: Binding<Bool> {
        Binding(get: { pendingDeleteArrangementId != nil }, set: { if !$0 { pendingDeleteArrangementId = nil } })
    }
    private var renameFolderShown: Binding<Bool> {
        Binding(get: { pendingRenameFolderId != nil }, set: { if !$0 { pendingRenameFolderId = nil } })
    }
    private var deleteFolderShown: Binding<Bool> {
        Binding(get: { pendingDeleteFolderId != nil }, set: { if !$0 { pendingDeleteFolderId = nil } })
    }

    // MARK: Arrangements home (the tab's landing page — a browser of arrangements + folders)

    private var arrangementsHome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TracksIcon().frame(width: 30, height: 22)
                Text("Multitrack").font(.headline).foregroundStyle(Theme.fg)
                Spacer()
                Button { newFolderMoveArrangementId = nil; folderNameText = ""; pendingNewFolder = true } label: {
                    Image(systemName: "folder.badge.plus").font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("tracks-new-folder")
                Button { newArrangement() } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("tracks-new-arrangement")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.border)

            if studio.arrangements.isEmpty && studio.arrangementFolders.isEmpty {
                homeEmptyState
            } else {
                List {
                    looseSection
                    ForEach(studio.arrangementFoldersOrdered()) { folder in folderSection(folder) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var homeEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            TracksIcon().frame(width: 120, height: 84).opacity(0.9)
            Text("Make a multitrack").font(.title3.weight(.semibold)).foregroundStyle(Theme.fg)
            Text("Arrange samples, sequences, loops, instrumentals — or a song's stems — into layered tracks. Create one to begin; group them into folders as your set grows.")
                .font(.callout).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button { newArrangement() } label: { Label("New arrangement", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tracks-empty-new-arrangement")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    /// Loose (unfiled) arrangements — always present so a loose arrangement is always reachable.
    @ViewBuilder private var looseSection: some View {
        let loose = studio.arrangements(inFolder: nil)
        Section {
            if loose.isEmpty {
                Text("No loose arrangements.").font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(loose) { a in arrangementBrowserRow(a) }
            }
        } header: {
            Text(studio.arrangementFolders.isEmpty ? "Arrangements" : "No folder").foregroundStyle(Theme.fgDim)
        }
    }

    /// One collapsible folder of arrangements (collapse persists). The id rides the LABEL leaf, never
    /// the Section/DisclosureGroup container (the container-id-swallow lesson).
    @ViewBuilder private func folderSection(_ folder: StudioArrangementFolder) -> some View {
        let members = studio.arrangements(inFolder: folder.id)
        Section {
            DisclosureGroup(isExpanded: folderExpansion(folder.id)) {
                if members.isEmpty {
                    Text("Empty folder — move an arrangement in with its ⋯ menu.")
                        .font(.caption).foregroundStyle(Theme.fgDim).listRowBackground(Color.clear)
                }
                ForEach(members) { a in arrangementBrowserRow(a) }
            } label: {
                HStack {
                    Label(folder.name.isEmpty ? "Folder" : folder.name, systemImage: "folder").foregroundStyle(Theme.accent2)
                    Spacer()
                    Text("\(members.count)").font(.caption).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("tracks-folder-\(folder.id)")
                .contextMenu {
                    Button { pendingRenameFolderId = folder.id; folderNameText = folder.name } label: { Label("Rename folder", systemImage: "pencil") }
                    Button(role: .destructive) { pendingDeleteFolderId = folder.id } label: { Label("Delete folder", systemImage: "trash") }
                }
            }
        }
    }

    /// An arrangement row — tap opens it into the arranger; the context menu opens / renames / moves /
    /// deletes it (rename & delete target the row's id, no need to open first).
    private func arrangementBrowserRow(_ a: StudioArrangement) -> some View {
        Button { openArrangementId = a.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Self.color(0)).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name.isEmpty ? "Untitled" : a.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg)
                    Text("\(a.tracks.count) track\(a.tracks.count == 1 ? "" : "s") · \(mmss(Double(a.lengthMs) / 1000))")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("tracks-arr-row-\(a.id)")
        .contextMenu {
            Button { openArrangementId = a.id } label: { Label("Open", systemImage: "arrow.up.forward.square") }
            Button { pendingRenameArrangementId = a.id; nameText = a.name } label: { Label("Rename…", systemImage: "pencil") }
            moveToFolderSubmenu(for: a)
            Button(role: .destructive) { pendingDeleteArrangementId = a.id } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "Move to folder" submenu for a specific arrangement: None + folders + a one-shot "New folder…"
    /// (creates the folder AND files this arrangement into it, so a UI test never predicts the id).
    @ViewBuilder private func moveToFolderSubmenu(for a: StudioArrangement) -> some View {
        Menu {
            Button { studio.moveArrangementToFolder(a.id, folderId: nil) } label: {
                Label("No folder", systemImage: a.folderId == nil ? "checkmark" : "")
            }
            ForEach(studio.arrangementFoldersOrdered()) { f in
                Button { studio.moveArrangementToFolder(a.id, folderId: f.id) } label: {
                    Label(f.name.isEmpty ? "Folder" : f.name, systemImage: a.folderId == f.id ? "checkmark" : "")
                }
            }
            Divider()
            Button { newFolderMoveArrangementId = a.id; folderNameText = ""; pendingNewFolder = true } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("tracks-move-new-folder")
        } label: { Label("Move to folder", systemImage: "folder") }
    }

    private func folderExpansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { expanded in
                    if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                    UserDefaults.standard.set(Array(collapsed), forKey: "pdj.arrangementFolders.collapsed")
                })
    }

    // MARK: Arranger screen (an open arrangement)

    private func arrangerScreen(_ arr: StudioArrangement) -> some View {
        VStack(spacing: 0) {
            arrangerHeader(arr)
            Divider().overlay(Theme.border)
            if arr.tracks.isEmpty {
                emptyTracks(arr)
            } else {
                transportBar(arr)
                Divider().overlay(Theme.border)
                arranger(arr)
                masterFXPanel(arr)
            }
        }
    }

    /// Arranger header: back to the home browser + the arrangement name (tap to rename) + a ⋯ menu
    /// (rename / delete) + ＋ Track. No folder items here — folders live on the home page.
    private func arrangerHeader(_ arr: StudioArrangement) -> some View {
        HStack(spacing: 10) {
            Button { player.stop(); openArrangementId = nil } label: {
                Label("Arrangements", systemImage: "chevron.backward").font(.callout.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("tracks-home-back")

            Spacer(minLength: 8)

            Button { pendingRenameArrangementId = arr.id; nameText = arr.name } label: {
                Text(arr.name.isEmpty ? "Untitled" : arr.name).font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
            }
            .buttonStyle(.plain)
            Menu {
                Button { pendingRenameArrangementId = arr.id; nameText = arr.name } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { pendingDeleteArrangementId = arr.id } label: { Label("Delete arrangement", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.fgDim)
            }
            .accessibilityIdentifier("tracks-arrangement-menu")

            Spacer(minLength: 8)

            Button { addTrack() } label: { Label("Track", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tracks-add-track")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Empty state

    private func emptyTracks(_ arr: StudioArrangement) -> some View {
        VStack(spacing: 16) {
            Spacer()
            TracksIcon().frame(width: 120, height: 84).opacity(0.9)
            Text("Build a multitrack").font(.title3.weight(.semibold)).foregroundStyle(Theme.fg)
            Text("Add tracks, then place samples, sequences, loops, instrumentals — or record live — onto their lanes.")
                .font(.callout).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { addTrack() } label: { Label("Add a track", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tracks-empty-add-track")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Transport
    //
    // Regular width (iPad/Mac): one horizontal row. Compact (iPhone): the primary row (play + time)
    // stays put with a collapse chevron; the rest (tempo/loop/bounce + zoom/follow) STACK below and
    // fold away when collapsed, to maximize track space (Levi).

    private func transportBar(_ arr: StudioArrangement) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                playControl(arr)
                recordControl(arr)
                timeControl(arr)
                if isCompact {
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.15)) { transportCollapsed.toggle() } } label: {
                        Image(systemName: transportCollapsed ? "slider.horizontal.3" : "chevron.up")
                            .font(.callout).foregroundStyle(Theme.fgDim).padding(6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tracks-transport-collapse")
                    .accessibilityValue(transportCollapsed ? "collapsed" : "expanded")
                } else {
                    bpmControl(arr); loopControl(arr)
                    Spacer()
                    zoomControls(arr); bounceControl(arr)
                }
            }
            if isCompact && !transportCollapsed {
                HStack(spacing: 12) { bpmControl(arr); loopControl(arr); Spacer(); bounceControl(arr) }
                HStack(spacing: 12) { Spacer(); zoomControls(arr) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func playControl(_ arr: StudioArrangement) -> some View {
        Button { togglePlay(arr) } label: {
            Image(systemName: isPlayingThis(arr) ? "stop.fill" : "play.fill").font(.title3)
                .foregroundStyle(arr.lengthMs == 0 ? Theme.fgDim : (isPlayingThis(arr) ? Theme.danger : Theme.accent))
        }
        .buttonStyle(.plain).disabled(arr.lengthMs == 0)
        .accessibilityIdentifier("tracks-play")
        .accessibilityValue(isPlayingThis(arr) ? "playing" : "stopped")
    }
    /// Record-to-master: play with the live master (incl. FX moves) captured, then baked to a Master
    /// track on stop — so you can "master live". Red while recording.
    private func recordControl(_ arr: StudioArrangement) -> some View {
        Button { toggleRecordMaster(arr) } label: {
            Image(systemName: recordingMaster ? "stop.circle.fill" : "record.circle")
                .font(.title3).foregroundStyle(arr.lengthMs == 0 ? Theme.fgDim : Theme.danger)
        }
        .buttonStyle(.plain).disabled(arr.lengthMs == 0)
        .accessibilityIdentifier("tracks-record-master")
        .accessibilityValue(recordingMaster ? "recording" : "idle")
    }
    private func timeControl(_ arr: StudioArrangement) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(timeLabel(arr)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
        }
    }
    private func bpmControl(_ arr: StudioArrangement) -> some View {
        Button { bpmText = String(Int(arr.bpm.rounded())); pendingBpm = true } label: {
            Text("♩ \(Int(arr.bpm.rounded()))")
                .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.fg)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.bgOverlay, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("tracks-bpm")
    }
    private func loopControl(_ arr: StudioArrangement) -> some View {
        Button { toggleLoop(arr) } label: {
            Image(systemName: "repeat").font(.callout.weight(.semibold))
                .foregroundStyle(arr.loopEnabled ? Theme.accent : Theme.fgDim)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(arr.loopEnabled ? Theme.accent.opacity(0.16) : Theme.bgOverlay, in: Capsule())
        }
        .buttonStyle(.plain).disabled(arr.lengthMs == 0)
        .accessibilityIdentifier("tracks-loop-toggle").accessibilityValue(arr.loopEnabled ? "on" : "off")
    }
    @ViewBuilder private func zoomControls(_ arr: StudioArrangement) -> some View {
        Button { stepZoom(-1, arr: arr) } label: { Image(systemName: "minus.magnifyingglass").font(.callout) }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(pxPerSec <= fitPx(arr) + 0.01).accessibilityIdentifier("tracks-zoom-out")
        Button { stepZoom(+1, arr: arr) } label: { Image(systemName: "plus.magnifyingglass").font(.callout) }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(pxPerSec >= Self.zoomLadder.last!).accessibilityIdentifier("tracks-zoom-in")
        Button { followPlayhead.toggle(); if followPlayhead { centerNonce &+= 1 } } label: {
            Image(systemName: "scope").font(.callout)
                .foregroundStyle(followPlayhead ? Theme.bg : Theme.fgDim)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(followPlayhead ? Theme.accent : Theme.bgOverlay, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("tracks-follow").accessibilityValue(followPlayhead ? "on" : "off")
    }
    private func bounceControl(_ arr: StudioArrangement) -> some View {
        Menu {
            Button { bounce(tracks: arr.tracks, label: "Master") } label: {
                Label("Bounce all tracks", systemImage: "square.stack.3d.down.forward")
            }
            Button { bounceSelection = []; bounceSelecting = true } label: {
                Label("Bounce selected…", systemImage: "checklist")
            }
        } label: {
            Label("Bounce", systemImage: "square.and.arrow.down.on.square")
                .font(.caption).foregroundStyle(arr.lengthMs == 0 ? Theme.fgDim : Theme.fg)
        }
        .disabled(arr.lengthMs == 0).accessibilityIdentifier("tracks-bounce-menu")
    }

    private func timeLabel(_ arr: StudioArrangement) -> String {
        let cur = isPlayingThis(arr) ? player.clock.currentSeconds : 0
        return "\(mmss(cur)) / \(mmss(Double(arr.lengthMs) / 1000))"
    }

    private func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Arranger (headers + timeline)

    private func timelineWidth(_ arr: StudioArrangement) -> CGFloat {
        max(560, CGFloat(arr.lengthMs) / 1000 * pxPerSec + 160)
    }

    private func arranger(_ arr: StudioArrangement) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Left: fixed track headers, with a top spacer so they line up with the lanes below
                // the ruler.
                VStack(spacing: 0) {
                    Color.clear.frame(width: headerWidth, height: rulerHeight)
                    VStack(spacing: laneGap) {
                        ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                            trackHeader(arr: arr, track: track, index: idx)
                                .frame(width: headerWidth, height: laneHeight)
                        }
                    }
                }
                // Right: ONE horizontally-scrolling column — the beat-number ruler on top of the clip
                // lanes (they share the exact scroll), with a full-height playhead over both. Wrapped
                // in a ScrollViewReader so playback auto-follows the cursor (⌖) and zoom re-centers on
                // it — the Demux timeline pattern.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ruler(arr).frame(width: timelineWidth(arr), height: rulerHeight)
                            VStack(spacing: laneGap) {
                                ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                                    laneStrip(arr: arr, track: track, index: idx)
                                        .frame(width: timelineWidth(arr), height: laneHeight)
                                }
                            }
                            .overlay(alignment: .topLeading) { beatMarkers(arr) }
                            .overlay(alignment: .topLeading) { loopOverlay(arr) }
                            // Loop-handle drags read this space (from 0:00), not a handle's moved local
                            // origin — attached to the LANES so the ruler doesn't shift the x.
                            .coordinateSpace(name: Self.timelineSpace)
                        }
                        // Full-height cursor over ruler + lanes, and the per-second LAYOUT anchors the
                        // follow/zoom scrollTo targets by id (a real HStack flow, NOT .offset — scrollTo
                        // resolves layout frames, so offset anchors all sit at x=0; the Demux lesson).
                        .overlay(alignment: .topLeading) { playhead(arr) }
                        .overlay(alignment: .topLeading) { followAnchors(arr) }
                        .padding(.trailing, 24)
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onChange(of: g.size.width, initial: true) { _, w in timelineViewportWidth = w }
                    })
                    .onChange(of: pxPerSec) {
                        // Re-center the cursor ONLY while following — with ⌖ off, a zoom must leave
                        // the user's manual scroll where it is (not yank it to the stopped-clock 0:00).
                        guard followPlayhead else { return }
                        let sec = cursorAnchorSec(arr)
                        DispatchQueue.main.async { proxy.scrollTo("tracks-sec-\(sec)", anchor: .center) }
                    }
                    .onChange(of: centerNonce) {
                        // ⌖ pressed → always jump to the cursor (its explicit purpose).
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("tracks-sec-\(cursorAnchorSec(arr))", anchor: .center)
                        }
                    }
                    .task(id: followTaskKey(arr)) {
                        // Poll the non-Observable clock; while following + playing, keep the cursor's
                        // second centered. Re-scroll only when the second changes.
                        var lastSec = -1
                        while !Task.isCancelled {
                            if followPlayhead, isPlayingThis(arr) {
                                let sec = cursorAnchorSec(arr)
                                if sec != lastSec {
                                    lastSec = sec
                                    withAnimation(.linear(duration: 0.3)) {
                                        proxy.scrollTo("tracks-sec-\(sec)", anchor: .center)
                                    }
                                }
                            }
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    /// Number of per-second anchors on the timeline (bounded so a runaway length can't spawn unbounded
    /// views). BOTH the anchors and every scrollTo target derive from this, so a target is never past
    /// the last anchor (which would make scrollTo a silent no-op — follow would die past the cap).
    private func anchorSecondsCount(_ arr: StudioArrangement) -> Int {
        min(3600, max(1, Int(ceil(Double(arr.lengthMs) / 1000)) + 2))
    }
    /// The cursor's anchor second (live while playing, else the seek position), clamped into range.
    private func cursorAnchorSec(_ arr: StudioArrangement) -> Int {
        max(0, min(anchorSecondsCount(arr), Int(cursorSeconds(arr))))
    }

    /// Restart the follow task when zoom / follow / play / LOOP state changes (anchor spacing, gating,
    /// or the wrap bounds `playheadSeconds` uses all moved). Loop fields are included so dragging a
    /// loop handle mid-play re-arms the task with the fresh region.
    private func followTaskKey(_ arr: StudioArrangement) -> String {
        "\(pxPerSec)-\(followPlayhead)-\(isPlayingThis(arr))-\(arr.id)-\(arr.loopEnabled)-\(arr.loopStartMs)-\(arr.loopEndMs)"
    }

    /// One 1-second-wide LAYOUT cell per second (real HStack flow) so `scrollTo("tracks-sec-k")`
    /// lands at the right x.
    private func followAnchors(_ arr: StudioArrangement) -> some View {
        HStack(spacing: 0) {
            ForEach(0...anchorSecondsCount(arr), id: \.self) { sec in
                Color.clear.frame(width: pxPerSec, height: 1).id("tracks-sec-\(sec)")
            }
        }
        .allowsHitTesting(false)
    }

    private func trackHeader(arr: StudioArrangement, track: StudioTrack, index: Int) -> some View {
        let color = Self.color(track.colorIndex)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Big, easy-to-hit colour chip → the track edit sheet (name / colour / pan). The old
                // 5-pt chip was a near-impossible mobile target — tapping it hit the name editor 9/10.
                Button { editTrackId = track.id } label: {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-track-color-\(index)")
                Button { editTrackId = track.id } label: {
                    Text(track.name.isEmpty ? "Track" : track.name)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-track-name-\(index)")
                Spacer(minLength: 0)
                Button { pickerTrackId = track.id } label: {
                    Image(systemName: "plus.circle.fill").font(.caption).foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-add-clip-\(index)")
                Menu {
                    Button { editTrackId = track.id } label: { Label("Edit track…", systemImage: "pencil") }
                    Button { pickerTrackId = track.id } label: { Label("Add clip…", systemImage: "waveform.badge.plus") }
                    Button { startRecord(arr: arr, track: track) } label: { Label("Record…", systemImage: "mic") }
                    Button { bounce(tracks: [track], label: "\(track.name) (bounce)") } label: { Label("Bounce this track", systemImage: "square.and.arrow.down") }
                        .disabled(track.clips.isEmpty)
                    Button { studio.duplicateTrack(arrangement: arr.id, track: track.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { deleteTrack(arr: arr, track: track) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.caption).foregroundStyle(Theme.fgDim).frame(width: 18, height: 18)
                }
                .accessibilityIdentifier("tracks-track-menu-\(index)")
            }
            HStack(spacing: 5) {
                Button { studio.setTrackMuted(arrangement: arr.id, track: track.id, !track.muted) } label: {
                    Text("M").font(.caption2.weight(.bold)).frame(width: 20, height: 18)
                        .background(track.muted ? Theme.danger.opacity(0.85) : Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(track.muted ? .white : Theme.fgDim)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tracks-track-mute-\(index)")
                Button { studio.setTrackSoloed(arrangement: arr.id, track: track.id, !track.soloed) } label: {
                    Text("S").font(.caption2.weight(.bold)).frame(width: 20, height: 18)
                        .background(track.soloed ? Theme.accent2.opacity(0.9) : Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(track.soloed ? .black : Theme.fgDim)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tracks-track-solo-\(index)")
                Slider(value: Binding(
                    get: { track.gainDb },
                    set: { studio.setTrackGain(arrangement: arr.id, track: track.id, gainDb: $0) }
                ), in: -24...6)
                .controlSize(.mini)
                .accessibilityIdentifier("tracks-track-gain-\(index)")
                // A small L/R mark shows the current pan without cluttering the strip; edit it in the
                // track sheet (tap the name / colour chip).
                if abs(track.pan) > 0.02 {
                    Text(track.pan < 0 ? "L" : "R").font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.accent2)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func panLabel(_ p: Double) -> String {
        if abs(p) < 0.02 { return "center" }
        return p < 0 ? "left \(Int(abs(p) * 100))%" : "right \(Int(p * 100))%"
    }

    private func laneStrip(arr: StudioArrangement, track: StudioTrack, index: Int) -> some View {
        let color = Self.color(track.colorIndex)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.bgOverlay)
            if track.clips.isEmpty {
                Text("Tap ＋ to add a clip")
                    .font(.caption2).foregroundStyle(Theme.fgDim.opacity(0.6))
                    .padding(.leading, 10).padding(.top, 8)
            }
            ForEach(Array(track.clips.enumerated()), id: \.element.id) { ci, clip in
                clipBlock(arr: arr, track: track, trackIndex: index, clip: clip, clipIndex: ci, color: color)
                    .offset(x: clipX(clip), y: 4)
            }
        }
    }

    /// Pixels per beat on the shared grid (0 when tempo is unusable).
    private func beatPx(_ arr: StudioArrangement) -> CGFloat {
        arr.bpm > 0 ? pxPerSec * 60 / CGFloat(arr.bpm) : 0
    }

    /// The beat/bar grid over the lanes — thin vertical ticks every beat, bolder every 4 (a 4/4 bar
    /// line). Bar NUMBERS live in the ruler above; here it's just the subtle grid. A Canvas (cheap for
    /// many lines) sized to the lane VStack, so it shares the exact scroll offset the clips use; never
    /// intercepts taps.
    @ViewBuilder private func beatMarkers(_ arr: StudioArrangement) -> some View {
        let bp = beatPx(arr)
        if bp >= 4 {
            Canvas { ctx, size in
                var k = 0
                var x: CGFloat = 0
                while x <= size.width {
                    let isBar = k % 4 == 0
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(Theme.fg.opacity(isBar ? 0.20 : 0.08)),
                               lineWidth: isBar ? 1 : 0.5)
                    k += 1
                    x = CGFloat(k) * bp
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The beat-number RULER strip above the lanes: bar numbers + beat ticks on the shared timeline
    /// grid, scrolling with the clips. Tap anywhere on it to move the playback cursor there (seek).
    private func ruler(_ arr: StudioArrangement) -> some View {
        let bp = beatPx(arr)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.bgRaised)
            Rectangle().fill(Theme.border).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            if bp >= 4 {
                Canvas { ctx, size in
                    let barPx = bp * 4
                    let showNumbers = barPx >= 22
                    var k = 0
                    var x: CGFloat = 0
                    while x <= size.width {
                        let isBar = k % 4 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: isBar ? size.height * 0.35 : size.height * 0.62))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(Theme.fgDim.opacity(isBar ? 0.7 : 0.3)),
                                   lineWidth: isBar ? 1 : 0.5)
                        if isBar && showNumbers && x <= size.width - 10 {
                            ctx.draw(Text("\(k / 4 + 1)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.fg),
                                     at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                        }
                        k += 1
                        x = CGFloat(k) * bp
                    }
                }
            }
        }
        .contentShape(Rectangle())
        // A TAP (not a drag — a drag scrolls) seeks the cursor to that timeline position.
        .gesture(SpatialTapGesture().onEnded { v in seek(toMs: Int(v.location.x / pxPerSec * 1000)) })
        .accessibilityIdentifier("tracks-ruler")
    }

    /// The playback cursor — a full-height line (over ruler + lanes) with a time bubble at the top.
    /// PLAYING: driven by a TimelineView sampling the non-Observable clock (never re-runs the arranger
    /// body), wrapping within the loop span. STOPPED: a static line at the seek position (`cursorMs`,
    /// set by a ruler tap). Never intercepts clip taps/drags.
    @ViewBuilder private func playhead(_ arr: StudioArrangement) -> some View {
        if isPlayingThis(arr) {
            TimelineView(.periodic(from: .now, by: 0.03)) { _ in
                cursorLine(playheadSeconds(arr))
            }
            .allowsHitTesting(false)
        } else {
            cursorLine(Double(effectiveCursorMs(arr)) / 1000).allowsHitTesting(false)
        }
    }

    private func cursorLine(_ sec: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.accent2)
                .frame(width: 2).frame(maxHeight: .infinity)
            Text(mmss(sec)).font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Theme.accent2, in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .offset(y: -1)
        }
        .frame(width: 40)
        .offset(x: CGFloat(sec) * pxPerSec - 20)
    }

    /// Seek the playback cursor to a timeline position (ms). Moves the visible cursor; if this
    /// arrangement is currently playing, playback restarts from there. Also re-centers the view on it.
    private func seek(toMs ms: Int) {
        guard let arr = current else { return }
        cursorMs = max(0, min(ms, max(0, arr.lengthMs)))
        centerNonce &+= 1
        if isPlayingThis(arr) {
            Task { await player.play(arrangement: arr, store: studio, fromMs: cursorMs) }
        }
    }

    /// The cursor's timeline position in seconds — the live clock (+ seek offset, loop-wrapped) while
    /// playing, else the static seek position.
    private func cursorSeconds(_ arr: StudioArrangement) -> Double {
        isPlayingThis(arr) ? playheadSeconds(arr) : Double(effectiveCursorMs(arr)) / 1000
    }

    /// `cursorMs` clamped into the CURRENT timeline — it's only clamped at seek time, so trimming the
    /// tail after a seek could otherwise strand it past the end (a silent Play from nowhere).
    private func effectiveCursorMs(_ arr: StudioArrangement) -> Int {
        max(0, min(cursorMs, max(0, arr.lengthMs)))
    }

    /// The loop region — a shaded band with two draggable, beat-snapped handles. Only the handles
    /// intercept touches (the band itself doesn't, so it never eats clip drags). Shown only when the
    /// looper is on. Shares the clip scroll grid so it lines up with clips and beat markers.
    @ViewBuilder private func loopOverlay(_ arr: StudioArrangement) -> some View {
        if arr.loopEnabled {
            let sPx = CGFloat(arr.loopStartMs) / 1000 * pxPerSec
            let ePx = CGFloat(arr.loopEndMs) / 1000 * pxPerSec
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.accent.opacity(0.10))
                    .frame(width: max(2, ePx - sPx)).frame(maxHeight: .infinity)
                    .offset(x: sPx)
                    .allowsHitTesting(false)
                loopHandle(arr: arr, isStart: true, xPx: sPx)
                loopHandle(arr: arr, isStart: false, xPx: ePx)
            }
        }
    }

    private func loopHandle(arr: StudioArrangement, isStart: Bool, xPx: CGFloat) -> some View {
        Rectangle().fill(Theme.accent)
            .frame(width: 3).frame(maxHeight: .infinity)
            .overlay(alignment: isStart ? .topLeading : .topTrailing) {
                Image(systemName: isStart ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                    .font(.system(size: 9)).foregroundStyle(Theme.accent).offset(y: 2)
            }
            .contentShape(Rectangle().inset(by: -9))   // easy grab target without a wide visual
            .offset(x: xPx - 1.5)
            .accessibilityIdentifier(isStart ? "tracks-loop-start" : "tracks-loop-end")
            .gesture(
                // Read the drag in the TIMELINE coordinate space (from 0:00), so the value tracks
                // the finger regardless of the handle's own moved local origin.
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.timelineSpace))
                    .onChanged { v in
                        let ms = snapMs(Int(v.location.x / pxPerSec * 1000), bpm: arr.bpm)
                        if isStart {
                            studio.setArrangementLoop(arr.id, startMs: min(ms, arr.loopEndMs - 1))
                        } else {
                            studio.setArrangementLoop(arr.id, endMs: max(ms, arr.loopStartMs + 1))
                        }
                    }
            )
    }

    /// Snap a timeline position (ms) to the nearest beat on the arrangement grid.
    private func snapMs(_ ms: Int, bpm: Double) -> Int {
        guard bpm > 0 else { return max(0, ms) }
        let beatMs = 60_000.0 / bpm
        return max(0, Int((Double(ms) / beatMs).rounded() * beatMs))
    }

    /// Toggle the looper. Enabling with no region set seeds a sensible default (4 bars from 0:00,
    /// capped to the timeline). If this arrangement is currently playing, playback restarts so the
    /// loop takes effect immediately.
    private func toggleLoop(_ arr: StudioArrangement) {
        if arr.loopEnabled {
            studio.setArrangementLoop(arr.id, enabled: false)
        } else {
            var start = arr.loopStartMs, end = arr.loopEndMs
            if end <= start {
                let bar4 = arr.bpm > 0 ? Int((60_000.0 / arr.bpm) * 4) : 2_000
                start = 0
                end = arr.lengthMs > 0 ? min(bar4, arr.lengthMs) : bar4
                if end <= start { end = start + bar4 }
            }
            studio.setArrangementLoop(arr.id, enabled: true, startMs: start, endMs: end)
        }
        if isPlayingThis(arr), let fresh = studio.arrangement(arr.id) {
            Task { await player.play(arrangement: fresh, store: studio, fromMs: effectiveCursorMs(fresh)) }
        }
    }

    /// The LIVE playhead position in seconds while playing — the clock plus the seek offset it started
    /// from; wraps into the loop span while looping (the region loops from node 0, offset is 0 then).
    private func playheadSeconds(_ arr: StudioArrangement) -> Double {
        let raw = player.clock.currentSeconds
        guard arr.loopEnabled, arr.loopEndMs > arr.loopStartMs else {
            return Double(player.startOffsetMs) / 1000 + raw
        }
        let startS = Double(arr.loopStartMs) / 1000
        let span = Double(arr.loopEndMs - arr.loopStartMs) / 1000
        guard span > 0 else { return startS + raw }
        return startS + raw.truncatingRemainder(dividingBy: span)
    }

    private func clipX(_ clip: StudioClip) -> CGFloat {
        let base = CGFloat(clip.startMs) / 1000 * pxPerSec
        return max(0, base + (dragClipId == clip.id ? dragDX : 0))
    }

    private func clipBlock(arr: StudioArrangement, track: StudioTrack, trackIndex: Int,
                           clip: StudioClip, clipIndex: Int, color: Color) -> some View {
        let w = max(10, CGFloat(clip.durationMs) / 1000 * pxPerSec)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.30))
            RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.9), lineWidth: 1)
            MixWaveformView(peaks: clipPeaks[clip.id] ?? [], color: color, background: .clear)
                .padding(.horizontal, 3).padding(.top, 12).padding(.bottom, 3)
            Text(clip.name).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Theme.fg).padding(.horizontal, 4).padding(.top, 2)
        }
        .frame(width: w, height: laneHeight - 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tracks-clip-\(trackIndex)-\(clipIndex)")
        .accessibilityLabel(clip.name)
        .contextMenu {
            Button(role: .destructive) {
                studio.removeClip(arrangement: arr.id, track: track.id, clip: clip.id)
                clipPeaks[clip.id] = nil
            } label: { Label("Remove clip", systemImage: "trash") }
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { dragClipId = clip.id; dragDX = $0.translation.width }
                .onEnded { v in
                    let deltaMs = Int(v.translation.width / pxPerSec * 1000)
                    studio.moveClip(arrangement: arr.id, track: track.id, clip: clip.id,
                                    toStartMs: max(0, clip.startMs + deltaMs))
                    dragClipId = nil; dragDX = 0
                }
        )
    }

    // MARK: Master FX panel (bottom mix section)

    /// The master mix panel: four effects the Mix tab doesn't have (phaser / ring-mod / freezer /
    /// Brazilian bass) + an overall master gain, applied live to the summed mix and baked WYSIWYG
    /// into a bounce (freeze excepted — a live-only hold). Collapsible so it doesn't crowd the lanes.
    @ViewBuilder private func masterFXPanel(_ arr: StudioArrangement) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            Button { withAnimation(.easeInOut(duration: 0.15)) { showMasterFX.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dial.medium.fill").font(.caption).foregroundStyle(Theme.accent)
                    Text("Master FX").font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
                    if arr.masterFX.anyEffectEnabled {
                        Text("on").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.18), in: Capsule()).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text(gainLabel(arr.masterFX.masterGainDb)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Image(systemName: showMasterFX ? "chevron.down" : "chevron.up").font(.caption2).foregroundStyle(Theme.fgDim)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tracks-master-fx-toggle")

            if showMasterFX {
                VStack(spacing: 8) {
                    fxGainRow(arr)
                    fxEffectRow(arr, name: "Phaser", id: "phaser", enabled: arr.masterFX.phaserEnabled,
                                toggle: { on in setFX(arr) { $0.phaserEnabled = on } },
                                sliderLabel: "Rate", value: arr.masterFX.phaserRate, range: 0.05...8,
                                onSlide: { v in setFX(arr) { $0.phaserRate = v } })
                    fxEffectRow(arr, name: "Ring Mod", id: "ringmod", enabled: arr.masterFX.ringModEnabled,
                                toggle: { on in setFX(arr) { $0.ringModEnabled = on } },
                                sliderLabel: "Freq", value: arr.masterFX.ringModFreqHz, range: 40...1200,
                                onSlide: { v in setFX(arr) { $0.ringModFreqHz = v } })
                    fxEffectRow(arr, name: "Drive", id: "drive", enabled: arr.masterFX.driveEnabled,
                                toggle: { on in setFX(arr) { $0.driveEnabled = on } },
                                sliderLabel: "Amt", value: arr.masterFX.driveAmount, range: 0...1,
                                onSlide: { v in setFX(arr) { $0.driveAmount = v } })
                    fxEffectRow(arr, name: "Bass Lift", id: "bass", enabled: arr.masterFX.brazilianBassEnabled,
                                toggle: { on in setFX(arr) { $0.brazilianBassEnabled = on } },
                                sliderLabel: "Amt", value: arr.masterFX.brazilianBassAmount, range: 0...1,
                                onSlide: { v in setFX(arr) { $0.brazilianBassAmount = v } })
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .background(Theme.bgRaised)
    }

    private func fxGainRow(_ arr: StudioArrangement) -> some View {
        HStack(spacing: 8) {
            Text("Gain").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fg).frame(width: 58, alignment: .leading)
            Slider(value: Binding(get: { arr.masterFX.masterGainDb },
                                  set: { v in setFX(arr) { $0.masterGainDb = v } }), in: -24...12)
                .controlSize(.small)
                .accessibilityIdentifier("tracks-master-gain")
            Text(gainLabel(arr.masterFX.masterGainDb)).font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.fgDim).frame(width: 46, alignment: .trailing)
        }
    }

    private func fxEffectRow(_ arr: StudioArrangement, name: String, id: String, enabled: Bool,
                             toggle: @escaping (Bool) -> Void, sliderLabel: String?, value: Double,
                             range: ClosedRange<Double>, onSlide: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { toggle(!enabled) } label: {
                Text(name).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: 76)
                    .background(enabled ? Theme.accent.opacity(0.85) : Theme.bgOverlay, in: Capsule())
                    .foregroundStyle(enabled ? .white : Theme.fgDim)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tracks-fx-\(id)")
            .accessibilityValue(enabled ? "on" : "off")
            if let sliderLabel {
                Text(sliderLabel).font(.system(size: 9)).foregroundStyle(Theme.fgDim).frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { value }, set: onSlide), in: range)
                    .controlSize(.mini).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            } else {
                Text("hold / release").font(.system(size: 9)).foregroundStyle(Theme.fgDim)
                Spacer()
            }
        }
    }

    private func setFX(_ arr: StudioArrangement, _ mutate: (inout StudioMasterFX) -> Void) {
        var fx = arr.masterFX
        mutate(&fx)
        studio.setArrangementMasterFX(arr.id, fx)
    }

    private func gainLabel(_ db: Double) -> String {
        let v = Int(db.rounded())
        return v > 0 ? "+\(v) dB" : "\(v) dB"
    }

    private var bakingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text(busyMessage).font(.caption).foregroundStyle(.white)
            }
            .padding(20)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("tracks-baking")
    }

    private var recordingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                // A pulsing record dot (TimelineView so it animates without invalidating state).
                TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
                    Circle().fill(Theme.danger)
                        .frame(width: 22, height: 22)
                        .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
                }
                Text("Recording…").font(.headline).foregroundStyle(.white)
                Text("Captured audio lands as a clip on this track.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button { stopRecord() } label: {
                    Label("Stop", systemImage: "stop.fill").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).tint(Theme.danger)
                .accessibilityIdentifier("tracks-record-stop")
            }
            .padding(28)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Actions

    /// Create a new arrangement AND open it into the arranger (from the home page).
    private func newArrangement() {
        openArrangementId = studio.createArrangement(name: "Arrangement \(studio.arrangements.count + 1)").id
    }

    /// Delete an arrangement (from home or the open arranger). If it was open, drop back to home.
    private func deleteArrangement(_ id: String) {
        if openArrangementId == id { player.stop(); openArrangementId = nil }
        studio.deleteArrangement(id)
    }

    private func addTrack() {
        guard let a = current else { return }
        studio.addTrack(arrangement: a.id)
    }

    private func togglePlay(_ arr: StudioArrangement) {
        if isPlayingThis(arr) { player.stop(); return }
        Task { await player.play(arrangement: arr, store: studio, fromMs: effectiveCursorMs(arr)) }
    }

    /// Start playback WITH master recording (from the cursor); or, if already recording, stop + bake.
    /// Any stop while recording (auto-stop / Play button) also bakes — see `onChange(player.isPlaying)`.
    private func toggleRecordMaster(_ arr: StudioArrangement) {
        if recordingMaster {
            player.stop()               // onChange(isPlaying → false) bakes
            return
        }
        recordingMaster = true
        Task {
            let ok = await player.play(arrangement: arr, store: studio, fromMs: effectiveCursorMs(arr), record: true)
            if !ok { recordingMaster = false }
        }
    }

    /// Bake the captured master recording into a new Master track.
    private func bakeMasterRecording() {
        guard let a = current, let url = player.consumeRecording() else { recordingMaster = false; return }
        recordingMaster = false
        busyMessage = "Saving master…"; baking = true
        Task {
            defer { baking = false }
            if let clip = await ArrangerClipBaker.bakeFromFile(sourceURL: url, name: masterName(a), startMs: 0),
               let master = studio.addTrack(arrangement: a.id, name: masterName(a)) {
                studio.addClip(arrangement: a.id, track: master.id, clip)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Start capturing the mic into `track`. Playback is stopped first (record is a distinct mode —
    /// this sidesteps the mic-capture ↔ playback session-coexistence path for v1; overdub monitoring
    /// is a later enhancement). The recorder requests permission on first use (device-only).
    private func startRecord(arr: StudioArrangement, track: StudioTrack) {
        player.stop()
        mic.settings = settings; mic.store = studio
        Task {
            if await mic.start() { recordingTrackId = track.id }
        }
    }

    /// Stop the take and land it as a clip at the end of the target track — resolve the recorder's
    /// samples file, bake an independent snapshot into the arrangements dir, then DELETE the orphan
    /// samples file (the arranger recording isn't a library sample). nil take = nothing captured.
    private func stopRecord() {
        guard let tid = recordingTrackId, let a = current else { recordingTrackId = nil; return }
        recordingTrackId = nil
        busyMessage = "Saving recording…"; baking = true
        Task {
            defer { baking = false }
            // AWAIT the writer's finalize before reading the take file — reading a fragmented-AAC
            // take mid-finalize truncates the tail or fails to open (the stopRecording lesson).
            guard let take = await mic.stopAwaitingFinalize() else { return }
            let startMs = a.tracks.first { $0.id == tid }?.lengthMs ?? 0
            guard let got = StudioFolders.fileURL(family: .samples, fileName: take.fileName,
                                                  wasUserFolder: take.wasUserFolder,
                                                  bookmark: studio.bookmark(for: .samples)) else { return }
            let clip = await ArrangerClipBaker.bakeFromFile(sourceURL: got.url,
                                                            name: mic.defaultRecordingName, startMs: startMs)
            if let clip {
                studio.addClip(arrangement: a.id, track: tid, clip)
                try? FileManager.default.removeItem(at: got.url)   // orphan gone ONLY after a good bake
            }
            // On bake failure the samples file is LEFT on disk (within scope until release) — launch
            // orphan-recovery files it as a sample, so a recording is never silently destroyed.
            got.release?()
        }
    }

    /// Mix the given tracks (their gains applied; mute/solo don't affect a bounce) into one master
    /// clip and append it on a NEW master track. Individual = [track]; all = arr.tracks; selected =
    /// the sheet's chosen subset.
    private func bounce(tracks: [StudioTrack], label: String) {
        guard let a = current else { return }
        let selected = tracks.filter { !$0.clips.isEmpty }
        guard !selected.isEmpty else { return }
        player.stop()
        busyMessage = "Bouncing…"; baking = true
        Task {
            defer { baking = false }
            guard let clip = await ArrangerBouncer.bounce(tracks: selected, store: studio, name: label,
                                                          masterFX: a.masterFX, bpm: a.bpm),
                  let master = studio.addTrack(arrangement: a.id, name: masterName(a)) else { return }
            studio.addClip(arrangement: a.id, track: master.id, clip)
        }
    }

    private func masterName(_ arr: StudioArrangement) -> String {
        let n = arr.tracks.filter { $0.name.hasPrefix("Master") }.count
        return n == 0 ? "Master" : "Master \(n + 1)"
    }

    private var bounceSheet: some View {
        NavigationStack {
            List {
                Section("Choose tracks to mix into one master") {
                    ForEach(Array((current?.tracks ?? []).enumerated()), id: \.element.id) { idx, track in
                        Button {
                            if bounceSelection.contains(track.id) { bounceSelection.remove(track.id) }
                            else { bounceSelection.insert(track.id) }
                        } label: {
                            HStack {
                                Image(systemName: bounceSelection.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(bounceSelection.contains(track.id) ? Theme.accent : Theme.fgDim)
                                Text(track.name.isEmpty ? "Track" : track.name).foregroundStyle(Theme.fg)
                                Spacer()
                                Text("\(track.clips.count) clip\(track.clips.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(Theme.fgDim)
                            }
                        }
                        .disabled(track.clips.isEmpty)
                        .accessibilityIdentifier("bounce-select-\(idx)")
                    }
                }
            }
            .navigationTitle("Bounce selected")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { bounceSelecting = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bounce (\(bounceSelection.count))") {
                        let sel = (current?.tracks ?? []).filter { bounceSelection.contains($0.id) }
                        bounceSelecting = false
                        bounce(tracks: sel, label: "Master")
                    }
                    .disabled(bounceSelection.isEmpty)
                    .accessibilityIdentifier("bounce-confirm")
                }
            }
        }
    }

    private func deleteTrack(arr: StudioArrangement, track: StudioTrack) {
        for clip in track.clips { clipPeaks[clip.id] = nil }
        studio.deleteTrack(arrangement: arr.id, track: track.id)
    }

    private func addClip(sourceId: String, kind: StudioClipSource, to trackId: String) {
        guard let a = current else { return }
        let startMs = a.tracks.first { $0.id == trackId }?.lengthMs ?? 0   // append after the last clip
        busyMessage = "Adding clip…"; baking = true
        Task {
            if let clip = await ArrangerClipBaker.bake(sourceId: sourceId, kind: kind,
                                                       startMs: startMs, studio: studio, packs: packs) {
                studio.addClip(arrangement: a.id, track: trackId, clip)
            }
            baking = false
        }
    }

    /// Import a song's 4 on-device stems as four new colour-matched tracks on the CURRENT
    /// arrangement (all aligned at 0:00) — the source-picker counterpart to the Demuxer export.
    /// Adds tracks in drums/bass/other/vocals order so the palette maps yellow/red/green/purple, and
    /// holds the BurnStore security scope across all four bakes, releasing once at the end.
    private func importStems(songId: String) {
        guard let a = current else { return }
        let name = app.songsById[songId].map { "\($0.artist) — \($0.name)" } ?? "Stems"
        busyMessage = "Importing stems…"; baking = true
        Task {
            defer { baking = false }
            guard let got = burns.localStemURLs(forSong: songId) else { return }
            for stem in ["drums", "bass", "other", "vocals"] {
                guard let url = got.urls[stem],
                      let track = studio.addTrack(arrangement: a.id, name: stem.capitalized) else { continue }
                if let clip = await ArrangerClipBaker.bakeFromFile(
                    sourceURL: url, name: "\(name) — \(stem)", startMs: 0) {
                    studio.addClip(arrangement: a.id, track: track.id, clip)
                }
            }
            got.release?()
        }
    }

    private func loadPeaks() async {
        guard let arr = current else { return }
        for track in arr.tracks {
            for clip in track.clips where clipPeaks[clip.id] == nil {
                guard let url = studio.clipFileURL(clip.fileName) else { continue }
                clipPeaks[clip.id] = await WaveformExtractor.peaks(url: url, targetCount: 120)
            }
        }
    }

    /// `.sheet(item:)` needs an Identifiable — box the target track id.
    private var pickerTrackBinding: Binding<IdBox?> {
        Binding(get: { pickerTrackId.map(IdBox.init) }, set: { pickerTrackId = $0?.id })
    }
    private var editTrackBinding: Binding<IdBox?> {
        Binding(get: { editTrackId.map(IdBox.init) }, set: { editTrackId = $0?.id })
    }
}

// MARK: - Track edit sheet (name / colour / pan) + pan dial

/// One sheet to edit a lane's NAME, COLOUR (big swatches — the header chip's tap target was too
/// small on mobile) and PAN (a rotary dial). Opened by tapping the name or the colour chip. Colour +
/// pan write live; the name commits on Done.
private struct TrackEditSheet: View {
    let studio: StudioStore
    let arrangementId: String
    let trackId: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loaded = false

    private var track: StudioTrack? {
        studio.arrangement(arrangementId)?.tracks.first { $0.id == trackId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Track name", text: $name)
                        .accessibilityIdentifier("track-edit-name")
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Array(TracksView.trackColors.indices), id: \.self) { ci in
                            let selected = track?.colorIndex == ci
                            Button { studio.setTrackColor(arrangement: arrangementId, track: trackId, colorIndex: ci) } label: {
                                RoundedRectangle(cornerRadius: 8).fill(TracksView.color(ci))
                                    .frame(height: 40)
                                    .overlay { if selected { Image(systemName: "checkmark").font(.headline).foregroundStyle(.white) } }
                                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.fg.opacity(selected ? 0.9 : 0), lineWidth: 2) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("track-edit-color-\(ci)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Pan") {
                    HStack {
                        Text("L").font(.caption.weight(.bold)).foregroundStyle(Theme.fgDim)
                        PanDial(value: track?.pan ?? 0) { v in
                            studio.setTrackPan(arrangement: arrangementId, track: trackId, pan: v)
                        }
                        .frame(width: 96, height: 96).frame(maxWidth: .infinity)
                        Text("R").font(.caption.weight(.bold)).foregroundStyle(Theme.fgDim)
                    }
                    HStack {
                        Text(panText(track?.pan ?? 0)).font(.callout.monospacedDigit()).foregroundStyle(Theme.fg)
                        Spacer()
                        Button("Center") { studio.setTrackPan(arrangement: arrangementId, track: trackId, pan: 0) }
                            .accessibilityIdentifier("track-edit-pan-center")
                    }
                }
            }
            .navigationTitle("Edit track")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitName(); dismiss() }.accessibilityIdentifier("track-edit-done")
                }
            }
            .task {
                if !loaded { name = track?.name ?? ""; loaded = true }
            }
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { studio.renameTrack(arrangement: arrangementId, track: trackId, to: n) }
    }
    private func panText(_ p: Double) -> String {
        if abs(p) < 0.02 { return "Center" }
        return p < 0 ? "Left \(Int(abs(p) * 100))%" : "Right \(Int(p * 100))%"
    }
}

/// A rotary pan dial: the indicator sweeps ±135° over pan −1…+1. Drag anywhere on it to set the angle;
/// snaps to dead-center near 0.
private struct PanDial: View {
    let value: Double
    let onChange: (Double) -> Void
    private let maxAngle = 135.0 * .pi / 180

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let a = value * maxAngle
            ZStack {
                Circle().stroke(Theme.fgDim.opacity(0.4), lineWidth: 3).frame(width: d, height: d)
                Circle().fill(Theme.bgRaised).frame(width: d * 0.82, height: d * 0.82)
                // Center detent tick (top) + indicator.
                Rectangle().fill(Theme.fgDim.opacity(0.5)).frame(width: 2, height: d * 0.12)
                    .offset(y: -d * 0.44)
                Capsule().fill(Theme.accent2).frame(width: 4, height: d * 0.34)
                    .offset(y: -d * 0.24)
                    .rotationEffect(.radians(a), anchor: .center)
                Circle().fill(Theme.accent2).frame(width: d * 0.16, height: d * 0.16)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = v.location.x - c.x, dy = v.location.y - c.y
                        guard abs(dx) + abs(dy) > 1 else { return }
                        var ang = atan2(Double(dx), Double(-dy))       // 0 at top, + clockwise
                        ang = max(-maxAngle, min(maxAngle, ang))
                        let p = ang / maxAngle
                        onChange(abs(p) < 0.06 ? 0 : p)
                    }
            )
            .accessibilityIdentifier("track-edit-pan-dial")
        }
    }
}

/// Identifiable wrapper so a plain String id can drive `.sheet(item:)`.
struct IdBox: Identifiable { let id: String }

// MARK: - Clip source picker
//
// Pick any studio source (sample / loop / sequence / instrumental) to bake onto a track. A plain
// sectioned list with search — items shown directly (a picker's job is to reveal sources, and a
// Button-in-List expander doesn't toggle reliably under XCUITest). Non-interactive section headers;
// only the leaf item rows carry a11y ids.
private struct ClipSourcePicker: View {
    let studio: StudioStore
    let burns: BurnStore
    let app: AppModel
    let onPick: (_ sourceId: String, _ kind: StudioClipSource) -> Void
    /// Import ALL 4 of a song's on-device stems as four new tracks (fans out — the one target track
    /// the picker was opened on is ignored). Distinct from onPick because stems aren't studio ids.
    let onPickStems: (_ songId: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// On-device stem songs (id + display name), loaded once — the availability check scans the
    /// burn folder, so it's kept off the per-keystroke render path.
    @State private var stemSongs: [(id: String, name: String)] = []

    var body: some View {
        NavigationStack {
            List {
                section("Samples", key: "samples", kind: .sample,
                        items: studio.samples.map { ($0.id, $0.name) })
                section("Loops", key: "loops", kind: .loop,
                        items: studio.loops.map { ($0.id, $0.name) })
                section("Sequences", key: "sequences", kind: .pattern,
                        items: studio.patterns.map { ($0.id, $0.name) })
                section("Instrumentals", key: "takes", kind: .take,
                        items: studio.takes.map { ($0.id, $0.name) })
                stemsSection
                if allEmpty && stemSongs.isEmpty {
                    ContentUnavailableView("No sources yet",
                                           systemImage: "waveform",
                                           description: Text("Make a sample, loop, sequence, or instrumental first, then add it to a track."))
                }
            }
            .searchable(text: $query, placement: .automatic, prompt: "Search sources")
            .navigationTitle("Add clip")
            .task { loadStemSongs() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("clip-picker-cancel")
                }
            }
        }
    }

    private var allEmpty: Bool {
        studio.samples.isEmpty && studio.loops.isEmpty && studio.patterns.isEmpty && studio.takes.isEmpty
    }

    private func loadStemSongs() {
        stemSongs = burns.localStemSongIds()
            .map { id in (id, app.songsById[id].map { "\($0.artist) — \($0.name)" } ?? "Stems") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Songs with all 4 stems on device — picking one imports drums/bass/other/vocals as four new
    /// tracks (a whole-song stem split, not a single clip). Leaf-only a11y, like the other sections.
    @ViewBuilder private var stemsSection: some View {
        let filtered = query.isEmpty ? stemSongs
            : stemSongs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !filtered.isEmpty {
            Section("Stems (\(filtered.count))") {
                ForEach(filtered, id: \.id) { item in
                    Button {
                        onPickStems(item.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent)
                            Text(item.name).foregroundStyle(Theme.fg)
                            Spacer()
                            Text("4 stems").font(.caption2).foregroundStyle(Theme.fgDim)
                        }
                    }
                    .accessibilityIdentifier("clip-picker-stem-\(item.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, key: String, kind: StudioClipSource,
                         items: [(id: String, name: String)]) -> some View {
        let filtered = query.isEmpty ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !filtered.isEmpty {
            Section("\(title) (\(filtered.count))") {
                ForEach(filtered, id: \.id) { item in
                    Button {
                        onPick(item.id, kind)
                        dismiss()
                    } label: {
                        Text(item.name.isEmpty ? "Untitled" : item.name).foregroundStyle(Theme.fg)
                    }
                    .accessibilityIdentifier("clip-picker-item-\(item.id)")
                }
            }
        }
    }
}
