import SwiftUI

/// Demuxer ▸ DRUM PATTERN — the extracted, classified drum hits on a bar-by-bar 16-step grid:
/// one colored lane per hit class (kick / snare / perc / other from the drums stem, bass from
/// the bass stem), bar chips for time division, steps lit where hits landed. "Send to
/// Sequencer" exports the selected bar as a real `StudioPattern`: one representative hit per
/// class is carved from the stem into an `smp_` sample and each lane's steps become a row —
/// from there the sequencer's row-retarget menu morphs any lane onto a sample cut from ANOTHER
/// song (the remix loop this feature exists for).
struct DemuxDrumPatternView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(BurnStore.self) private var burns
    @Environment(DemuxStore.self) private var demux

    let source: DemuxSource
    let hits: [DemuxDrumHit]
    let bars: [DrumPatternDetector.Bar]
    let durationMs: Int
    /// The demuxer's shared player — the grid FOLLOWS playback like the lyrics/chord panels:
    /// the displayed bar tracks the playing bar and a highlight column marches the 16 steps.
    let player: StemPlayer
    /// The ONE shared demux Follow (lifted to StudioDemuxView) — the drum-pattern grid, the
    /// instrumental score, and the timeline all track the SAME playhead under it, so enabling
    /// Follow scrolls BOTH the lane-grid's bar and the score's system to the current playhead.
    @Binding var follow: Bool
    /// Tap a step cell → seek there (the lyrics tap-line contract).
    var onSeek: (Int) -> Void = { _ in }

    @State private var selectedBar = 0
    /// Quantized lanes per bar — computed once per (hits, bars) pair, not per render.
    @State private var grid: [[DemuxDrumKind: [Bool]]] = []
    @State private var exporting = false
    @State private var exportNotice: String?

    /// Lanes shown for every bar: the classes that occur ANYWHERE in the song (stable rows
    /// while flipping through bars).
    private var lanes: [DemuxDrumKind] {
        let present = Set(hits.map(\.kind))
        return DemuxDrumKind.laneOrder.filter { present.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if bars.isEmpty {
                Text("No beat grid for this audio — hits were found, but bars can’t be drawn.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            } else {
                barChips
                laneGrid
                exportBar
            }
        }
        .task(id: hits.count &* 31 &+ bars.count) {
            grid = DrumPatternDetector.stepGrid(hits: hits, bars: bars)
            // Land on the first bar that actually has hits (intros are often empty).
            if let first = grid.firstIndex(where: { !$0.isEmpty }) { selectedBar = first }
        }
        // FOLLOW: advance the displayed bar with the playhead. NO isPlaying gate — a PAUSED scrub
        // (a bar/step tap here, or the score's/timeline's, seeks the shared player) must move the
        // lane-grid too, so the grid and the score land on the SAME bar/time (the unified-follow
        // spec). Bar-granularity state writes only (once per ~2 s bar) — the fast intra-bar column
        // highlight lives in a TimelineView overlay so this poll never invalidates the grid
        // mid-tap (the lyrics-scroll pattern).
        .task(id: follow) {
            guard follow else { return }
            while !Task.isCancelled {
                if !bars.isEmpty {
                    let ms = Int(player.currentTime * 1_000)
                    if let bi = DrumPatternDetector.barIndex(forMs: ms, bars: bars), bi != selectedBar {
                        selectedBar = bi
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: Bar chips (time division — tap to inspect/export that bar)

    private var barChips: some View {
        HStack(spacing: 6) {
            // Follow chip (the timeline's demux-follow idiom): on = the grid rides playback;
            // off = the grid freezes on the selected bar while the song plays on.
            Button { follow.toggle() } label: {
                Image(systemName: follow ? "location.fill" : "location")
                    .font(.caption)
                    .frame(width: 28, height: 26)
                    .background(follow ? Theme.accent.opacity(0.22) : Theme.bgOverlay,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(follow ? Theme.accent : Theme.border, lineWidth: 1))
                    .foregroundStyle(follow ? Theme.accent : Theme.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(follow ? "Following playback" : "Follow playback")
            .accessibilityIdentifier("demux-drum-follow")
            .help("Follow playback — the grid tracks the playing bar")
            barChipScroller
        }
        .frame(height: 34)
    }

    private var barChipScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(bars) { bar in
                        let hasHits = grid.indices.contains(bar.index) && !grid[bar.index].isEmpty
                        Button {
                            // Two-way sync: selecting a bar SNAPS playback to it, so the grid
                            // and the audio agree in both directions (see it AND hear it) —
                            // follow stays armed because there's no divergence to protect.
                            selectedBar = bar.index
                            onSeek(bar.startMs)
                        } label: {
                            Text("\(bar.index + 1)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 26)
                                .padding(.vertical, 5)
                                .background(bar.index == selectedBar ? Theme.accent.opacity(0.25)
                                            : Theme.bgOverlay,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(bar.index == selectedBar ? Theme.accent : Theme.border,
                                                  lineWidth: 1))
                                .foregroundStyle(hasHits ? Theme.fg : Theme.fgDim.opacity(0.6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Bar \(bar.index + 1)")
                        .accessibilityIdentifier("demux-drum-bar-\(bar.index)")
                        .id(bar.index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 34)
            .onChange(of: selectedBar) { _, bar in
                withAnimation { proxy.scrollTo(bar, anchor: .center) }
            }
        }
    }

    // MARK: Lane grid (one colored row per hit class × 16 steps, beat-grouped)

    private var laneGrid: some View {
        let barLanes = grid.indices.contains(selectedBar) ? grid[selectedBar] : [:]
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(lanes, id: \.self) { kind in
                let steps = barLanes[kind] ?? Array(repeating: false, count: 16)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(kind.laneColor).frame(width: 7, height: 7)
                        Text(kind.label).font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.fgDim)
                    }
                    .frame(width: 56, alignment: .leading)
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { group in
                            HStack(spacing: 3) {
                                ForEach(0..<4, id: \.self) { i in
                                    let col = group * 4 + i
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(steps[col] ? kind.laneColor : Theme.bgOverlay)
                                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(col % 4 == 0 ? Theme.fgDim.opacity(0.45)
                                                          : Theme.border, lineWidth: 0.5))
                                        .frame(height: 18)
                                        .frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                        // Tap a step → seek there (the lyrics tap-line contract).
                                        .onTapGesture { seekToStep(col) }
                                        .accessibilityLabel("\(kind.label) step \(col + 1)")
                                        .accessibilityValue(steps[col] ? "hit" : "empty")
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("demux-drum-lane-\(kind.rawValue)")
            }
        }
        // Playing-step column, OVERLAID: its own TimelineView layer (hit-testing off, identical
        // nested spacing so it aligns) — the sequencer's highlight doctrine, so the 10 Hz clock
        // never re-creates the tappable cells mid-gesture.
        .overlay {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let ms = Int(player.currentTime * 1_000)
                let current: Int? = {
                    guard bars.indices.contains(selectedBar) else { return nil }
                    let bar = bars[selectedBar]
                    guard ms >= bar.startMs, ms < bar.endMs else { return nil }
                    let len = max(1, bar.endMs - bar.startMs)
                    return min(15, (ms - bar.startMs) * 16 / len)
                }()
                HStack(spacing: 8) {
                    Color.clear.frame(width: 56)
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { group in
                            HStack(spacing: 3) {
                                ForEach(0..<4, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Theme.accent2, lineWidth: 1.5)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .opacity(group * 4 + i == current ? 1 : 0)
                                }
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Seek playback to a step's time in the selected bar (16th-note boundaries).
    private func seekToStep(_ col: Int) {
        guard bars.indices.contains(selectedBar) else { return }
        let bar = bars[selectedBar]
        onSeek(bar.startMs + col * (bar.endMs - bar.startMs) / 16)
    }

    // MARK: Export (bar → StudioPattern + per-class kit samples)

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let exportNotice {
                Text(exportNotice).font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-drum-export-notice")
            }
            Button { Task { await export() } } label: {
                HStack(spacing: 8) {
                    if exporting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.grid.4x3.fill") }
                    Text(exporting ? "Building sequence…" : "Send bar \(selectedBar + 1) to Sequencer")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.accent.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(exporting || bars.isEmpty
                      || !(grid.indices.contains(selectedBar) && !grid[selectedBar].isEmpty))
            .accessibilityIdentifier("demux-drum-export")
        }
    }

    /// Carve one representative hit per class into an `smp_` kit sample, build a row per lane
    /// from the selected bar's steps, and file the pattern. The bar's own length sets the
    /// pattern bpm (240000 / barMs — one 4/4 bar of 16ths).
    private func export() async {
        exporting = true
        exportNotice = nil
        defer { exporting = false }
        guard bars.indices.contains(selectedBar), grid.indices.contains(selectedBar) else { return }
        let barLanes = grid[selectedBar]
        let kinds = DemuxDrumKind.laneOrder.filter { (barLanes[$0] ?? []).contains(true) }
        guard !kinds.isEmpty else { exportNotice = "No hits in this bar."; return }
        guard let stems = resolveStems() else {
            exportNotice = "The stems aren’t on the device anymore — download them again."
            return
        }
        defer { stems.release?() }
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples)) else {
            exportNotice = "Your samples folder isn’t reachable right now (Settings ▸ Storage)."
            return
        }
        defer { dest.release?() }

        var rows: [StudioPatternRow] = []
        for kind in kinds {
            guard let stemURL = kind == .bass ? stems.bass : stems.drums,
                  let region = Self.hitRegion(for: kind, hits: hits, durationMs: durationMs) else { continue }
            let id = StudioFactory.newSampleId()
            let fileName = StudioFolders.fileName(.samples, id: id)
            do {
                let carved = try await StudioRender.shared.carveTrackRegion(
                    sourceURL: stemURL, startMs: region.start, endMs: region.end,
                    to: dest.url.appendingPathComponent(fileName))
                let provenance: StudioSource = source.songId.map {
                    .track(songId: $0, startMs: region.start, endMs: region.end)
                } ?? .file(originalName: source.displayName)
                studio.addSample(StudioSample(
                    id: id, name: "\(source.displayName) · \(kind.label.lowercased())",
                    fileName: fileName, wasUserFolder: dest.isUserFolder,
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    durationMs: carved.durationMs,
                    source: provenance, grid: nil, edit: .neutral))
                rows.append(StudioPatternRow(targetId: id, steps: barLanes[kind] ?? []))
            } catch {
                continue   // one unusable lane never blocks the rest of the kit
            }
        }
        guard !rows.isEmpty else {
            exportNotice = "Couldn’t carve any hits from the stems."
            return
        }
        let bar = bars[selectedBar]
        let barLen = max(1, bar.endMs - bar.startMs)
        let bpm = min(max(240_000.0 / Double(barLen), 40), 300)
        studio.addPattern(StudioPattern(
            id: StudioFactory.newPatternId(),
            name: "\(source.displayName) · bar \(selectedBar + 1)",
            bpm: bpm, rows: rows,
            createdAt: Date().timeIntervalSince1970 * 1000))
        exportNotice = "Sequence created with \(rows.count) lane\(rows.count == 1 ? "" : "s") — "
            + "open the Sequencer and use each row’s swap menu to morph lanes onto other samples."
    }

    /// The freshest local stem files (a NEW scope per call — never the demux player's):
    /// songs from the burn folder, custom audio from the demux stems cache.
    private func resolveStems() -> (drums: URL?, bass: URL?, release: (() -> Void)?)? {
        if let songId = source.songId, let got = burns.localStemURLs(forSong: songId) {
            return (got.urls["drums"], got.urls["bass"], got.release)
        }
        if let got = demux.localStemURLs(for: source.key) {
            return (got["drums"], got["bass"], nil)
        }
        return nil
    }

    /// The kit-sample region for a class: its STRONGEST hit, cut at the stem's next hit (min
    /// 60 ms so a flam doesn't yield a click, max 500 ms so a sparse groove doesn't drag a
    /// whole phrase into a one-shot). Pure — unit-tested.
    static func hitRegion(for kind: DemuxDrumKind, hits: [DemuxDrumHit], durationMs: Int)
        -> (start: Int, end: Int)? {
        let stemHits = hits.filter { ($0.kind == .bass) == (kind == .bass) }.sorted { $0.ms < $1.ms }
        guard let best = stemHits.filter({ $0.kind == kind }).max(by: { $0.strength < $1.strength })
        else { return nil }
        let next = stemHits.first(where: { $0.ms > best.ms + 30 })?.ms ?? durationMs
        let end = min(min(best.ms + 500, durationMs), max(next, best.ms + 60))
        guard end > best.ms + 20 else { return nil }
        return (best.ms, end)
    }
}

// MARK: - Lane colors

extension DemuxDrumKind {
    /// The pattern grid's class colors (kick red, snare gold, perc cyan, other purple, bass
    /// the app accent) — distinct at 18 pt cells in both appearances.
    var laneColor: Color {
        switch self {
        case .kick: return Theme.danger
        case .snare: return Theme.accent2
        case .percussive: return .cyan
        case .other: return .purple
        case .bass: return Theme.accent
        }
    }
}
