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

    @State private var selectedId = ""

    // Rename affordances (cross-platform alert + TextField).
    @State private var pendingRenameTrack: String?
    @State private var pendingRenameArrangement = false
    @State private var nameText = ""

    // Add-clip source picker (which track it targets) + a baking spinner.
    @State private var pickerTrackId: String?
    @State private var baking = false

    // Per-clip waveform peaks (immutable clips → compute once, cache).
    @State private var clipPeaks: [String: [Float]] = [:]

    // Clip drag (horizontal reposition).
    @State private var dragClipId: String?
    @State private var dragDX: CGFloat = 0

    // Layout grid.
    private let laneHeight: CGFloat = 58
    private let headerWidth: CGFloat = 172
    private let pxPerSec: CGFloat = 48
    private let laneGap: CGFloat = 8

    /// Track lane colours — the stem palette first (drums·yellow, bass·red, other·green,
    /// vocals·purple) then cue-extra hues, cycling at `StudioStore.trackPaletteSize` (= 8).
    static let trackColors: [Color] = [.yellow, .red, .green, .purple, .cyan, .orange, .pink, .mint]
    static func color(_ index: Int) -> Color {
        trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count]
    }

    private var current: StudioArrangement? { studio.arrangement(selectedId) }

    /// Signature of every clip id on screen — drives the peak-loading task when a clip is added.
    private var clipSignature: String {
        (current?.tracks.flatMap { $0.clips.map(\.id) } ?? []).joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if let arr = current {
                if arr.tracks.isEmpty {
                    emptyTracks(arr)
                } else {
                    arranger(arr)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay { if baking { bakingOverlay } }
        .task { bootstrap() }
        .task(id: clipSignature) { await loadPeaks() }
        .sheet(item: pickerTrackBinding) { box in
            ClipSourcePicker(studio: studio) { sourceId, kind in
                addClip(sourceId: sourceId, kind: kind, to: box.id)
                pickerTrackId = nil
            }
        }
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
    }

    // MARK: Header (arrangement picker + add track)

    private var header: some View {
        HStack(spacing: 12) {
            TracksIcon().frame(width: 30, height: 22)

            Menu {
                ForEach(studio.arrangementsOrdered()) { a in
                    Button { selectedId = a.id } label: {
                        Label(a.name.isEmpty ? "Untitled" : a.name,
                              systemImage: a.id == selectedId ? "checkmark" : "")
                    }
                }
                Divider()
                Button { newArrangement() } label: { Label("New arrangement", systemImage: "plus") }
                Button { nameText = current?.name ?? ""; pendingRenameArrangement = true } label: {
                    Label("Rename…", systemImage: "pencil")
                }
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
                // Right: horizontally-scrolling clip lanes on the shared grid.
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: laneGap) {
                        ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                            laneStrip(arr: arr, track: track, index: idx)
                                .frame(width: timelineWidth(arr), height: laneHeight)
                        }
                    }
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
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 5, height: 20)
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
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                Text("Adding clip…").font(.caption).foregroundStyle(.white)
            }
            .padding(20)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("tracks-baking")
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

    private func deleteTrack(arr: StudioArrangement, track: StudioTrack) {
        for clip in track.clips { clipPeaks[clip.id] = nil }
        studio.deleteTrack(arrangement: arr.id, track: track.id)
    }

    private func addClip(sourceId: String, kind: StudioClipSource, to trackId: String) {
        guard let a = current else { return }
        let startMs = a.tracks.first { $0.id == trackId }?.lengthMs ?? 0   // append after the last clip
        baking = true
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
