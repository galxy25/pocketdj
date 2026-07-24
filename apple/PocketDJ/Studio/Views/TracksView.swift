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

    @State private var selectedId = ""

    // Rename affordances (cross-platform alert + TextField).
    @State private var pendingRenameTrack: String?
    @State private var pendingRenameArrangement = false
    @State private var nameText = ""

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

    // Layout grid.
    private let laneHeight: CGFloat = 82
    private let headerWidth: CGFloat = 172
    private let pxPerSec: CGFloat = 48
    private let laneGap: CGFloat = 8

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

    private var current: StudioArrangement? { studio.arrangement(selectedId) }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if let arr = current {
                if arr.tracks.isEmpty {
                    emptyTracks(arr)
                } else {
                    transportBar(arr)
                    Divider().overlay(Theme.border)
                    arranger(arr)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay { if baking { bakingOverlay } }
        .overlay { if recordingTrackId != nil { recordingOverlay } }
        .task { bootstrap(); mic.settings = settings; mic.store = studio }
        .task(id: clipSignature) { await loadPeaks() }
        .onChange(of: mixSignature) {
            if let arr = current, isPlayingThis(arr) { player.applyMix(arr.tracks) }
        }
        .onDisappear {
            player.stop()
            if recordingTrackId != nil { _ = mic.stop(); recordingTrackId = nil }
        }
        .sheet(item: pickerTrackBinding) { box in
            ClipSourcePicker(studio: studio) { sourceId, kind in
                addClip(sourceId: sourceId, kind: kind, to: box.id)
                pickerTrackId = nil
            }
        }
        .sheet(isPresented: $bounceSelecting) { bounceSheet }
        .alert("Rename track", isPresented: renameTrackShown) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { pendingRenameTrack = nil }
            Button("Rename") { commitTrackRename() }
        }
        .alert("Rename arrangement", isPresented: $pendingRenameArrangement) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let a = current { studio.renameArrangement(a.id, to: nameText) } }
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

    private var renameFolderShown: Binding<Bool> {
        Binding(get: { pendingRenameFolderId != nil }, set: { if !$0 { pendingRenameFolderId = nil } })
    }
    private var deleteFolderShown: Binding<Bool> {
        Binding(get: { pendingDeleteFolderId != nil }, set: { if !$0 { pendingDeleteFolderId = nil } })
    }

    // MARK: Header (arrangement picker + add track)

    private var header: some View {
        HStack(spacing: 12) {
            TracksIcon().frame(width: 30, height: 22)

            Menu {
                arrangementPickerItems
                Divider()
                Button { newArrangement() } label: { Label("New arrangement", systemImage: "plus") }
                Button { nameText = current?.name ?? ""; pendingRenameArrangement = true } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if current != nil { moveToFolderMenu }
                manageFoldersMenu
                Divider()
                Button(role: .destructive) { deleteCurrentArrangement() } label: {
                    Label("Delete arrangement", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(current?.name.isEmpty == false ? current!.name : "Arrangement")
                        .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("tracks-arrangement-menu")

            Spacer()

            Button { addTrack() } label: { Label("Track", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tracks-add-track")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The arrangement list, grouped into folder sections + a loose ("No folder") section. A folder
    /// with no arrangements is omitted; the loose section is always present so an unfiled arrangement
    /// is always reachable.
    @ViewBuilder private var arrangementPickerItems: some View {
        ForEach(studio.arrangementFoldersOrdered()) { f in
            let items = studio.arrangements(inFolder: f.id)
            if !items.isEmpty {
                Section(f.name.isEmpty ? "Folder" : f.name) {
                    ForEach(items) { a in arrangementRow(a) }
                }
            }
        }
        let loose = studio.arrangements(inFolder: nil)
        Section(studio.arrangementFolders.isEmpty ? "Arrangements" : "No folder") {
            ForEach(loose) { a in arrangementRow(a) }
        }
    }

    private func arrangementRow(_ a: StudioArrangement) -> some View {
        Button { selectedId = a.id } label: {
            Label(a.name.isEmpty ? "Untitled" : a.name,
                  systemImage: a.id == selectedId ? "checkmark" : "")
        }
    }

    /// "Move to folder" submenu for the CURRENT arrangement: None + existing folders + a one-shot
    /// "New folder…" (creates the folder AND files this arrangement into it — so a UI test never has
    /// to predict the minted `arrfld_` id).
    @ViewBuilder private var moveToFolderMenu: some View {
        Menu {
            if let a = current {
                Button { studio.moveArrangementToFolder(a.id, folderId: nil) } label: {
                    Label("No folder", systemImage: a.folderId == nil ? "checkmark" : "")
                }
                ForEach(studio.arrangementFoldersOrdered()) { f in
                    Button { studio.moveArrangementToFolder(a.id, folderId: f.id) } label: {
                        Label(f.name.isEmpty ? "Folder" : f.name,
                              systemImage: a.folderId == f.id ? "checkmark" : "")
                    }
                }
                Divider()
                Button {
                    newFolderMoveArrangementId = a.id; folderNameText = ""; pendingNewFolder = true
                } label: { Label("New folder…", systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("tracks-move-new-folder")
            }
        } label: { Label("Move to folder", systemImage: "folder") }
    }

    /// Folder management: create an empty folder, and per-folder rename / delete (delete re-homes its
    /// arrangements to loose — it never deletes an arrangement).
    @ViewBuilder private var manageFoldersMenu: some View {
        Menu {
            Button {
                newFolderMoveArrangementId = nil; folderNameText = ""; pendingNewFolder = true
            } label: { Label("New folder", systemImage: "folder.badge.plus") }
                .accessibilityIdentifier("tracks-new-folder")
            ForEach(studio.arrangementFoldersOrdered()) { f in
                Menu(f.name.isEmpty ? "Folder" : f.name) {
                    Button {
                        pendingRenameFolderId = f.id; folderNameText = f.name
                    } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) { pendingDeleteFolderId = f.id } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                }
            }
        } label: { Label("Folders", systemImage: "folder.badge.gearshape") }
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

    private func transportBar(_ arr: StudioArrangement) -> some View {
        HStack(spacing: 14) {
            Button { togglePlay(arr) } label: {
                Image(systemName: isPlayingThis(arr) ? "stop.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(arr.lengthMs == 0 ? Theme.fgDim : (isPlayingThis(arr) ? Theme.danger : Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(arr.lengthMs == 0)
            .accessibilityIdentifier("tracks-play")
            .accessibilityValue(isPlayingThis(arr) ? "playing" : "stopped")

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(timeLabel(arr)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }

            // Tempo — seeds the beat grid + looper snap. Tap to type a new BPM.
            Button { bpmText = String(Int(arr.bpm.rounded())); pendingBpm = true } label: {
                Text("♩ \(Int(arr.bpm.rounded()))")
                    .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.fg)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.bgOverlay, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tracks-bpm")

            Spacer()
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
            .disabled(arr.lengthMs == 0)
            .accessibilityIdentifier("tracks-bounce-menu")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
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
                // Left: fixed track headers.
                VStack(spacing: laneGap) {
                    ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                        trackHeader(arr: arr, track: track, index: idx)
                            .frame(width: headerWidth, height: laneHeight)
                    }
                }
                // Right: horizontally-scrolling clip lanes on the shared grid, with the playhead.
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: laneGap) {
                        ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                            laneStrip(arr: arr, track: track, index: idx)
                                .frame(width: timelineWidth(arr), height: laneHeight)
                        }
                    }
                    .overlay(alignment: .topLeading) { beatMarkers(arr) }
                    .overlay(alignment: .topLeading) { playhead(arr) }
                    .padding(.trailing, 24)
                }
            }
            .padding(12)
        }
    }

    private func trackHeader(arr: StudioArrangement, track: StudioTrack, index: Int) -> some View {
        let color = Self.color(track.colorIndex)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                colorMenu(arr: arr, track: track, index: index, color: color)
                Button {
                    nameText = track.name; pendingRenameTrack = track.id
                } label: {
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
                    Button { nameText = track.name; pendingRenameTrack = track.id } label: { Label("Rename…", systemImage: "pencil") }
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
            }
            panRow(arr: arr, track: track, index: index)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Tappable colour chip → a swatch menu (choose the lane's palette colour). The chip is the
    /// track's identity everywhere (header + lane + clips), so recolouring is a one-tap affordance.
    private func colorMenu(arr: StudioArrangement, track: StudioTrack, index: Int, color: Color) -> some View {
        Menu {
            ForEach(Array(Self.trackColors.indices), id: \.self) { ci in
                Button { studio.setTrackColor(arrangement: arr.id, track: track.id, colorIndex: ci) } label: {
                    Label(Self.colorName(ci), systemImage: ci == track.colorIndex ? "checkmark" : "circle.fill")
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 5, height: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 9)
        .accessibilityIdentifier("tracks-track-color-\(index)")
    }

    /// Compact stereo-pan row: L …slider… R, center = 0. Snaps to dead-center near 0 so a track is
    /// easy to re-center. Streams to the store (and live to the player) like gain.
    private func panRow(arr: StudioArrangement, track: StudioTrack, index: Int) -> some View {
        HStack(spacing: 5) {
            Text("L").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.fgDim)
            Slider(value: Binding(
                get: { track.pan },
                set: { studio.setTrackPan(arrangement: arr.id, track: track.id, pan: abs($0) < 0.06 ? 0 : $0) }
            ), in: -1...1)
            .controlSize(.mini)
            .accessibilityIdentifier("tracks-track-pan-\(index)")
            .accessibilityValue(panLabel(track.pan))
            Text("R").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.fgDim)
        }
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

    /// The beat/bar grid — thin vertical ticks every beat, bolder every 4 (a 4/4 bar line) with a
    /// tiny bar number at the top edge. A Canvas (cheap for many lines) sized to the lane VStack, so
    /// it shares the exact scroll offset the clips use. Drawn as a subtle overlay so it reads over
    /// any lane background; never intercepts taps.
    @ViewBuilder private func beatMarkers(_ arr: StudioArrangement) -> some View {
        let bp = beatPx(arr)
        if bp >= 4 {
            Canvas { ctx, size in
                let barPx = bp * 4
                let showNumbers = barPx >= 26
                var k = 0
                var x: CGFloat = 0
                while x <= size.width {
                    let isBar = k % 4 == 0
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(Theme.fg.opacity(isBar ? 0.20 : 0.08)),
                               lineWidth: isBar ? 1 : 0.5)
                    if isBar && showNumbers && x <= size.width - 8 {
                        let bar = k / 4 + 1
                        ctx.draw(Text("\(bar)").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.fgDim.opacity(0.7)),
                                 at: CGPoint(x: x + 6, y: 6), anchor: .leading)
                    }
                    k += 1
                    x = CGFloat(k) * bp
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The moving playhead — a full-height line at `currentSeconds × pxPerSec` with a small cap and a
    /// live time bubble at the top. Driven by a TimelineView sampling the non-Observable clock (never
    /// re-runs the arranger body); never intercepts clip taps/drags. Hidden when this arrangement
    /// isn't playing. While looping, the line wraps within the loop span.
    @ViewBuilder private func playhead(_ arr: StudioArrangement) -> some View {
        if isPlayingThis(arr) {
            TimelineView(.periodic(from: .now, by: 0.03)) { _ in
                let sec = playheadSeconds(arr)
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
            .allowsHitTesting(false)
        }
    }

    /// The playhead's timeline position in seconds — wraps into the loop span while looping so the
    /// cursor visually repeats the region (the audio node loops; the clock grows unbounded).
    private func playheadSeconds(_ arr: StudioArrangement) -> Double {
        let raw = player.clock.currentSeconds
        guard arr.loopEnabled, arr.loopEndMs > arr.loopStartMs else { return raw }
        let startS = Double(arr.loopStartMs) / 1000
        let endS = Double(arr.loopEndMs) / 1000
        guard raw > startS else { return raw }
        let span = endS - startS
        return startS + (raw - startS).truncatingRemainder(dividingBy: span)
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

    private func bootstrap() {
        if studio.arrangements.isEmpty {
            selectedId = studio.createArrangement(name: "Arrangement 1").id
        } else if studio.arrangement(selectedId) == nil {
            selectedId = studio.arrangementsOrdered().first!.id
        }
    }

    private func newArrangement() {
        selectedId = studio.createArrangement(name: "Arrangement \(studio.arrangements.count + 1)").id
    }

    private func deleteCurrentArrangement() {
        guard let a = current else { return }
        studio.deleteArrangement(a.id)
        if studio.arrangements.isEmpty {
            selectedId = studio.createArrangement(name: "Arrangement 1").id
        } else {
            selectedId = studio.arrangementsOrdered().first!.id
        }
    }

    private func addTrack() {
        guard let a = current else { return }
        studio.addTrack(arrangement: a.id)
    }

    private func togglePlay(_ arr: StudioArrangement) {
        if isPlayingThis(arr) { player.stop(); return }
        Task { await player.play(arrangement: arr, store: studio) }
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
            guard let clip = await ArrangerBouncer.bounce(tracks: selected, store: studio, name: label),
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

    private func loadPeaks() async {
        guard let arr = current else { return }
        for track in arr.tracks {
            for clip in track.clips where clipPeaks[clip.id] == nil {
                guard let url = studio.clipFileURL(clip.fileName) else { continue }
                clipPeaks[clip.id] = await WaveformExtractor.peaks(url: url, targetCount: 120)
            }
        }
    }

    private func commitTrackRename() {
        guard let a = current, let tid = pendingRenameTrack else { return }
        studio.renameTrack(arrangement: a.id, track: tid, to: nameText)
        pendingRenameTrack = nil
    }

    private var renameTrackShown: Binding<Bool> {
        Binding(get: { pendingRenameTrack != nil }, set: { if !$0 { pendingRenameTrack = nil } })
    }

    /// `.sheet(item:)` needs an Identifiable — box the target track id.
    private var pickerTrackBinding: Binding<IdBox?> {
        Binding(get: { pickerTrackId.map(IdBox.init) }, set: { pickerTrackId = $0?.id })
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
    let onPick: (_ sourceId: String, _ kind: StudioClipSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
                if allEmpty {
                    ContentUnavailableView("No sources yet",
                                           systemImage: "waveform",
                                           description: Text("Make a sample, loop, sequence, or instrumental first, then add it to a track."))
                }
            }
            .searchable(text: $query, placement: .automatic, prompt: "Search sources")
            .navigationTitle("Add clip")
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
