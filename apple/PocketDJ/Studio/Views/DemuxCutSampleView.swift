import SwiftUI
import AVFoundation

/// Demuxer ▸ "Cut sample" for NON-catalog sources (imported audio + Studio items). Catalog songs
/// go through the full `StudioNewSampleFromTrackView` (burn ladder, sidecar grid, burned stems);
/// this is the same region-editor kit — waveform + region shade, mark in/out at the playhead,
/// `StudioEditSlider` in/out handles — bound to a demux-resolved local file instead of a song.
///
/// Stem subsets: custom sources separated via `/stemify-custom` cache their four stems in the
/// demux stems cache (`DemuxStore.localStemURLs`) — when present, the same stem-source toggle +
/// chips as the sampler flow carve a mix of the selected stems (drum samples from any import).
///
/// Ownership contracts (the demuxer's own lessons):
///   • the AUDITION scope is the engine's — `loadSample(_:url:release:)` holds it until unload;
///   • the CARVE re-resolves its own handle (`.studio` sources open a second scope; demux-cache
///     files are app-managed, no scope) and releases it on every path;
///   • the presenting Demuxer PAUSES its StemPlayer before this sheet opens (one-audio-owner).
struct DemuxCutSampleView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    @Environment(DemuxStore.self) private var demux
    @Environment(\.dismiss) private var dismiss

    let source: DemuxSource

    private enum Phase: Equatable { case resolving, ready, failed(String) }

    @State private var phase: Phase = .resolving
    @State private var url: URL?
    @State private var durationMs = 1
    @State private var regionStartMs = 0
    @State private var regionEndMs = 0
    @State private var previewId: String?
    @State private var peaks: [Float] = []
    @State private var carving = false
    @State private var carveError: String?
    /// Carve a MIX of the selected demux-cache stems instead of the resolved file.
    @State private var stemMode = false
    @State private var enabledStems: Set<String> = Set(StemPlayer.stems)

    private static let minWindowMs = 50

    /// Same display order/labels as the sampler's stem chips (the two flows must read alike).
    private static let stemDisplay: [(key: String, label: String, icon: String)] = [
        ("drums", "Drums", "metronome"),
        ("bass", "Bass", "waveform"),
        ("other", "Other", "guitars"),
        ("vocals", "Vocals", "music.mic"),
    ]

    private var stems: [String: URL]? { demux.localStemURLs(for: source.key) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .resolving:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading audio…").font(.caption).foregroundStyle(Theme.fgDim)
                                .accessibilityIdentifier("demux-cut-resolving")
                        }
                    case .failed(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("demux-cut-failed")
                    case .ready:
                        waveformStrip
                        transport
                        handleControls
                        stemSection
                        carveBar
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .task { await resolveSource() }
        .onDisappear {
            if let pid = previewId, engine.loadedSampleId == pid { engine.unloadSample() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cut sample").font(.headline).foregroundStyle(Theme.fg)
                Text(source.displayName).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-cut-cancel")
        }
    }

    // MARK: Waveform + region overlay (the sampler strip, minus the analog offset)

    private var waveformStrip: some View {
        let len = CGFloat(max(1, durationMs))
        return ZStack {
            MixWaveformView(peaks: peaks)
            GeometryReader { geo in
                let s = min(1, CGFloat(regionStartMs) / len)
                let e = min(1, CGFloat(regionEndMs) / len)
                let w = geo.size.width
                Rectangle().fill(Theme.accent.opacity(0.18))
                    .frame(width: max(2, (e - s) * w))
                    .offset(x: s * w)
                Rectangle().fill(Theme.accent).frame(width: 2).offset(x: s * w)
                Rectangle().fill(Theme.accent2).frame(width: 2).offset(x: max(0, e * w - 2))
            }
            .allowsHitTesting(false)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                GeometryReader { geo in
                    let f = min(1, max(0, playheadSeconds() / (Double(durationMs) / 1000)))
                    Rectangle().fill(Theme.fg).frame(width: 1.5)
                        .offset(x: CGFloat(f) * max(0, geo.size.width - 1.5))
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Transport (audition through the shared StudioEngine sample chain)

    private var transport: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            HStack(spacing: 14) {
                Button { markIn() } label: {
                    Label("Mark in", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly).font(.title3)
                        .frame(width: 40, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-cut-mark-in")

                Spacer()

                Text(StudioFmt.clock(playheadSeconds()))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)

                Button {
                    guard engine.loadedSampleId == previewId else { return }
                    if engine.isPlayingSample { engine.pauseSample() } else { engine.playSample() }
                } label: {
                    Image(systemName: engine.isPlayingSample ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 46, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-cut-play")

                Button { engine.stopSample() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3).frame(width: 40, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-cut-stop")

                Spacer()

                Button { markOut() } label: {
                    Label("Mark out", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly).font(.title3)
                        .frame(width: 40, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent2)
                .accessibilityIdentifier("demux-cut-mark-out")
            }
        }
    }

    // MARK: In/out handles (the sampler's StudioEditSlider kit — ±10 ms steps)

    private var handleControls: some View {
        let len = Double(max(1, durationMs))
        return VStack(alignment: .leading, spacing: 12) {
            StudioEditSlider(title: "In", systemImage: "arrow.right.to.line",
                             range: 0...len, step: 10, value: Double(regionStartMs),
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "demux-cut-region-start") { v in
                regionStartMs = min(Int(v), regionEndMs - Self.minWindowMs)
                if regionStartMs < 0 { regionStartMs = 0 }
            }
            StudioEditSlider(title: "Out", systemImage: "arrow.left.to.line",
                             range: 0...len, step: 10, value: Double(regionEndMs),
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "demux-cut-region-end") { v in
                regionEndMs = max(min(Int(v), Int(len)), regionStartMs + Self.minWindowMs)
            }
            Text("Length \(StudioFmt.mmssTenths(regionEndMs - regionStartMs)) · no grid — set one in the editor")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    // MARK: Stem source (demux-cache stems from /stemify-custom)

    @ViewBuilder private var stemSection: some View {
        if stems != nil {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $stemMode) {
                    Label("Stem source", systemImage: "square.stack.3d.up")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.fg)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("demux-cut-stem-mode")

                if stemMode {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(Self.stemDisplay, id: \.key) { st in stemChip(st) }
                    }
                    Text("Carves a mix of the selected stems for this region.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .padding(.top, 2)
        }
    }

    private func stemChip(_ st: (key: String, label: String, icon: String)) -> some View {
        let on = enabledStems.contains(st.key)
        return Button {
            if on {
                if enabledStems.count > 1 { enabledStems.remove(st.key) }   // never disable the last
            } else {
                enabledStems.insert(st.key)
            }
        } label: {
            Label(st.label, systemImage: st.icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background((on ? Theme.accent : Theme.fgDim).opacity(on ? 0.20 : 0.10), in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
                .foregroundStyle(on ? Theme.accent : Theme.fgDim)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("demux-cut-stem-\(st.key)")
    }

    // MARK: Carve

    private var carveBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let carveError {
                Label(carveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            Button { Task { await carve() } } label: {
                HStack(spacing: 8) {
                    if carving { ProgressView().controlSize(.small) }
                    Text(carving ? "Carving…" : "Create sample")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(carving || regionEndMs - regionStartMs < Self.minWindowMs)
            .accessibilityIdentifier("demux-cut-carve")
        }
    }

    // MARK: - Resolution (the demuxer's per-kind ladder, audition scope handed to the engine)

    private func resolveSource() async {
        switch source {
        case .file(let id, _):
            guard let got = demux.importedAudioURL(for: id) else {
                phase = .failed("This imported file is gone from the demux cache. Import it again.")
                return
            }
            enterReady(url: got, release: nil, lengthMs: fileLengthMs(got))
        case .studio(let id, _):
            guard let got = studio.localURLForPlayback(id: id) else {
                phase = .failed("This item has no playable audio yet (render or bounce it first).")
                return
            }
            enterReady(url: got.url, release: got.release, lengthMs: got.lengthMs)
        case .song:
            // Catalog songs use StudioNewSampleFromTrackView (the presenting demuxer routes) —
            // reaching here is a wiring bug, not a user state.
            phase = .failed("Catalog tracks cut through the sampler flow.")
            return
        }
        guard case .ready = phase, let url else { return }
        peaks = await WaveformExtractor.peaks(url: url)
    }

    private func enterReady(url: URL, release: (() -> Void)?, lengthMs: Int) {
        self.url = url
        durationMs = max(lengthMs, 1)
        regionStartMs = 0
        regionEndMs = min(durationMs, 8_000)                     // the sampler's ~8 s starter window
        if regionEndMs < Self.minWindowMs { regionEndMs = durationMs }
        let pid = StudioFactory.newSampleId()
        let preview = StudioSample(id: pid, name: source.displayName, fileName: "",
                                   durationMs: durationMs,
                                   source: .file(originalName: source.displayName),
                                   edit: .neutral)
        // The engine HOLDS the file's security scope for the load's lifetime (audition contract).
        engine.loadSample(preview, url: url, release: release)
        previewId = pid
        phase = .ready
    }

    // MARK: - Carve (own handle per source kind — never the audition's)

    private func carve() async {
        carving = true
        carveError = nil
        defer { carving = false }
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples)) else {
            carveError = "Your samples folder isn’t reachable right now (Settings ▸ Storage)."
            return
        }
        defer { dest.release?() }
        let sampleId = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: sampleId)
        let destURL = dest.url.appendingPathComponent(fileName)
        do {
            let carved: (frames: Int64, durationMs: Int)
            if stemMode, let stems {
                // Selected subset in canonical order; the UI guarantees ≥1 enabled. Stems are
                // separated from THIS file, so region ms map 1:1 (no offset).
                let selected = StemPlayer.stems.filter { enabledStems.contains($0) }
                    .compactMap { stems[$0] }
                guard !selected.isEmpty else {
                    carveError = "Pick at least one stem to carve."
                    return
                }
                carved = try await StudioRender.shared.carveStemMix(
                    stemURLs: selected, startMs: regionStartMs, endMs: regionEndMs, to: destURL)
            } else {
                guard let src = carveSourceHandle() else {
                    carveError = "This audio isn’t available anymore. Reload it in the Demuxer."
                    return
                }
                defer { src.release?() }
                carved = try await StudioRender.shared.carveTrackRegion(
                    sourceURL: src.url, startMs: regionStartMs, endMs: regionEndMs, to: destURL)
            }
            studio.addSample(StudioSample(
                id: sampleId, name: sampleName(), fileName: fileName,
                wasUserFolder: dest.isUserFolder,
                createdAt: Date().timeIntervalSince1970 * 1000,
                durationMs: carved.durationMs,
                source: .file(originalName: source.displayName),
                grid: nil, edit: .neutral))
            if let pid = previewId, engine.loadedSampleId == pid { engine.unloadSample() }
            dismiss()   // the samples list opens the editor on the new row's tap
        } catch {
            carveError = "Couldn’t carve this region. Try a slightly different in/out point."
        }
    }

    /// The carve's OWN source handle — the audition scope belongs to the engine (releasing it
    /// here would silence the preview; borrowing it would leak on unload). Demux-cache files are
    /// app-managed (no scope); `.studio` items open a fresh scope per call.
    private func carveSourceHandle() -> (url: URL, release: (() -> Void)?)? {
        switch source {
        case .file(let id, _):
            guard let u = demux.importedAudioURL(for: id) else { return nil }
            return (u, nil)
        case .studio(let id, _):
            guard let got = studio.localURLForPlayback(id: id) else { return nil }
            return (got.url, got.release)
        case .song:
            return nil
        }
    }

    /// "<name>" for the file carve; "<name> · drums+bass" etc. for a stem subset (the sampler's
    /// naming so cut provenance reads the same everywhere).
    private func sampleName() -> String {
        guard stemMode else { return source.displayName }
        let sel = StemPlayer.stems.filter { enabledStems.contains($0) }
        let suffix = sel.count == StemPlayer.stems.count ? "stems" : sel.joined(separator: "+")
        return "\(source.displayName) · \(suffix)"
    }

    // MARK: - Marks / playhead

    private func markIn() {
        let ph = Int((playheadSeconds() * 1000).rounded())
        regionStartMs = max(0, min(ph, regionEndMs - Self.minWindowMs))
    }

    private func markOut() {
        let ph = Int((playheadSeconds() * 1000).rounded())
        regionEndMs = min(durationMs, max(ph, regionStartMs + Self.minWindowMs))
    }

    private func playheadSeconds() -> Double {
        guard engine.loadedSampleId == previewId else { return 0 }
        return max(0, engine.samplePlayheadSeconds())
    }

    private func fileLengthMs(_ url: URL) -> Int {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return 1 }
        return max(Int(Double(f.length) / f.processingFormat.sampleRate * 1_000), 1)
    }
}
