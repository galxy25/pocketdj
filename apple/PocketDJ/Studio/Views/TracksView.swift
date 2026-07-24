import SwiftUI

// MARK: - Tracks (multitrack arranger) sub-tab
//
// Stage A: the arrangement workspace — a picker to switch/create/rename/delete arrangements, and a
// list of track lanes with add / delete / duplicate / rename plus a live mix strip (gain / mute /
// solo). Clip timeline + waveform lanes (Stage B), synced playback (C), live record (D), and bounce
// (E) slot into `laneContent` / the transport as they land. All state lives in `StudioStore`
// (arrangements array + CRUD in StudioStore+Arrangements.swift); this view is a pure surface.
struct TracksView: View {
    @Environment(StudioStore.self) private var studio

    /// The selected arrangement id. Bootstrapped to a real id in `.task` (creating "Arrangement 1"
    /// if the document has none), so there is always exactly one selected once the tab has appeared.
    @State private var selectedId = ""

    // Rename affordances (cross-platform alert + TextField).
    @State private var pendingRenameTrack: String?
    @State private var pendingRenameArrangement = false
    @State private var nameText = ""

    /// Track lane colours — the stem palette first (drums·yellow, bass·red, other·green,
    /// vocals·purple) then cue-extra hues, cycling at `StudioStore.trackPaletteSize` (= 8).
    static let trackColors: [Color] = [.yellow, .red, .green, .purple, .cyan, .orange, .pink, .mint]
    static func color(_ index: Int) -> Color { trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count] }

    private var current: StudioArrangement? { studio.arrangement(selectedId) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if let arr = current {
                if arr.tracks.isEmpty {
                    emptyTracks(arr)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(arr.tracks.enumerated()), id: \.element.id) { idx, track in
                                lane(arr: arr, track: track, index: idx)
                            }
                        }
                        .padding(12)
                    }
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .task { bootstrap() }
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
                Button {
                    nameText = current?.name ?? ""
                    pendingRenameArrangement = true
                } label: { Label("Rename…", systemImage: "pencil") }
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

            Button { addTrack() } label: {
                Label("Track", systemImage: "plus")
            }
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

    // MARK: One track lane

    private func lane(arr: StudioArrangement, track: StudioTrack, index: Int) -> some View {
        let color = Self.color(track.colorIndex)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6, height: 26)

                Button {
                    nameText = track.name
                    pendingRenameTrack = track.id
                } label: {
                    Text(track.name.isEmpty ? "Track" : track.name)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-track-name-\(index)")

                Spacer()

                // Mute / Solo
                Button { studio.setTrackMuted(arrangement: arr.id, track: track.id, !track.muted) } label: {
                    Text("M").font(.caption.weight(.bold))
                        .frame(width: 26, height: 24)
                        .background(track.muted ? Theme.danger.opacity(0.85) : Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(track.muted ? .white : Theme.fgDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-track-mute-\(index)")

                Button { studio.setTrackSoloed(arrangement: arr.id, track: track.id, !track.soloed) } label: {
                    Text("S").font(.caption.weight(.bold))
                        .frame(width: 26, height: 24)
                        .background(track.soloed ? Theme.accent2.opacity(0.9) : Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(track.soloed ? .black : Theme.fgDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tracks-track-solo-\(index)")

                Menu {
                    Button { nameText = track.name; pendingRenameTrack = track.id } label: { Label("Rename…", systemImage: "pencil") }
                    Button { studio.duplicateTrack(arrangement: arr.id, track: track.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { studio.deleteTrack(arrangement: arr.id, track: track.id) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("tracks-track-menu-\(index)")
            }

            // Gain
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(Theme.fgDim)
                Slider(value: Binding(
                    get: { track.gainDb },
                    set: { studio.setTrackGain(arrangement: arr.id, track: track.id, gainDb: $0) }
                ), in: -24...6)
                .accessibilityIdentifier("tracks-track-gain-\(index)")
                Text(gainLabel(track.gainDb)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    .frame(width: 44, alignment: .trailing)
            }

            // Lane (clip timeline lands in Stage B).
            laneContent(track: track, color: color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        // NB: no accessibilityIdentifier on this lane container — a container id promotes the whole
        // card to one element and swallows the mute/solo/menu button ids inside (the XCUITest
        // container-id lesson). Address a lane via its leaf ids (tracks-track-name/-mute/-solo-N).
    }

    /// The clip lane. Stage A: an empty strip with a hint; Stage B fills it with positioned,
    /// gapped clip blocks + waveforms on the shared timeline.
    private func laneContent(track: StudioTrack, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.bgOverlay)
            Text("No clips yet — add a source or record live (coming next stage)")
                .font(.caption2).foregroundStyle(Theme.fgDim.opacity(0.7))
        }
        .frame(height: 48)
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
        // Keep the invariant "always ≥ 1 arrangement" without relying on the one-shot bootstrap task.
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

    private func commitTrackRename() {
        guard let a = current, let tid = pendingRenameTrack else { return }
        studio.renameTrack(arrangement: a.id, track: tid, to: nameText)
        pendingRenameTrack = nil
    }

    private var renameTrackShown: Binding<Bool> {
        Binding(get: { pendingRenameTrack != nil }, set: { if !$0 { pendingRenameTrack = nil } })
    }

    private func gainLabel(_ db: Double) -> String {
        db <= -24 ? "−∞" : String(format: "%+.0f dB", db)
    }
}
