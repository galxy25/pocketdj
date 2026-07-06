import SwiftUI

/// Slice a sample into up to 8 performance PADS (spec: slicing). Presented as a sheet from the
/// sample editor. Each pad is a start-marker cue point (`StudioSlice`) that plays from its start to
/// the next pad's start (or the sample's end) — a one-shot audition through `StudioEngine.playSlice`
/// on the already-loaded RAW sample, so tapping pads never disturbs the editor's transport.
///
/// Auto-slice partitions the sample into N pads (`BeatMath.sliceStarts`): beat-snapped when the
/// sample has a grid, an even time chop otherwise (Auto-detect gives a grid-less sample a tempo).
/// Manual: drag a marker on the waveform, or nudge/rename/delete a pad. "Make sample" bakes a pad's
/// region into a normal `smp_` sample (which then flows through Loops / the sequencer / use-as-
/// sample under the studio-id fence); "Send pads to sequencer" bakes every pad into a new pattern.
struct StudioSliceEditorView: View {
    let sampleId: String

    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var peaks: [Float] = []
    @State private var sliceCount = 4
    @State private var detectInFlight = false
    @State private var detectFailed = false
    @State private var baking = false
    @State private var notice: String?
    /// Live drag position for a marker (avoids a store write per frame — commit on drag end).
    @State private var draggingSlot: Int?
    @State private var draggingMs = 0
    // Rename alert
    @State private var renameSlot: Int?
    @State private var renameText = ""
    @State private var showRename = false

    private var sample: StudioSample? { studio.sample(sampleId) }
    private var pads: [StudioSlice] { studio.slices(forSample: sampleId) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if let s = sample {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        waveform(s)
                        autoSliceControls(s)
                        padGrid(s)
                        bakeControls(s)
                        if let notice {
                            Text(notice).font(.caption2).foregroundStyle(Theme.fgDim)
                        }
                    }
                    .padding(16)
                }
            } else {
                Spacer()
                Text("This sample is no longer available.").font(.callout).foregroundStyle(Theme.fgDim)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .task { await load() }
        .onDisappear { engine.stopSample() }   // stop any pad audition; leave the sample loaded for the editor
        .alert("Rename pad", isPresented: $showRename) {
            TextField("Pad name", text: $renameText).accessibilityIdentifier("slice-rename-field")
            Button("Save") {
                if let slot = renameSlot { studio.renameSlice(sampleId: sampleId, slot: slot, name: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A blank name goes back to the pad number.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slice into pads").font(.headline).foregroundStyle(Theme.fg)
                Text(sample?.name ?? "").font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderless).font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("slice-done")
        }
    }

    // MARK: Waveform + draggable markers

    private func waveform(_ s: StudioSample) -> some View {
        let dur = max(1, s.durationMs)
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                MixWaveformView(peaks: peaks)
                ForEach(pads) { pad in
                    let ms = draggingSlot == pad.slot ? draggingMs : pad.startMs
                    marker(pad, x: w * CGFloat(min(ms, dur)) / CGFloat(dur), height: geo.size.height)
                        .gesture(
                            DragGesture(coordinateSpace: .named("slicewave"))
                                .onChanged { g in
                                    draggingSlot = pad.slot
                                    draggingMs = clampMs(g.location.x / max(1, w), dur)
                                }
                                .onEnded { g in
                                    studio.setSlice(sampleId: sampleId, slot: pad.slot,
                                                    startMs: clampMs(g.location.x / max(1, w), dur))
                                    draggingSlot = nil
                                }
                        )
                }
            }
            .coordinateSpace(name: "slicewave")
        }
        .frame(height: 84)
    }

    private func marker(_ pad: StudioSlice, x: CGFloat, height: CGFloat) -> some View {
        let color = StudioCuesView.slotColor(pad.slot)
        return VStack(spacing: 0) {
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Text("\(pad.slot + 1)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black))
            Rectangle().fill(color).frame(width: 2).frame(maxHeight: .infinity)
        }
        .frame(width: 16, height: height)
        .contentShape(Rectangle())          // wider-than-2pt drag target
        .offset(x: x - 8)
    }

    private func clampMs(_ frac: CGFloat, _ dur: Int) -> Int {
        Int(max(0, min(1, frac)) * CGFloat(dur))
    }

    // MARK: Auto-slice controls

    private func autoSliceControls(_ s: StudioSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Stepper(value: $sliceCount, in: 2...StudioSlice.maxSlots) {
                    Text("\(sliceCount) slices").font(.callout).foregroundStyle(Theme.fg)
                }
                .fixedSize()
                .accessibilityIdentifier("slice-count")
                Spacer()
            }
            HStack(spacing: 10) {
                Button { autoSlice(s) } label: {
                    Label("Auto-slice", systemImage: "square.split.2x2")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.18), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("slice-auto")

                if !pads.isEmpty {
                    Button(role: .destructive) {
                        engine.stopSample()
                        studio.clearSlices(sampleId: sampleId)
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.danger.opacity(0.14), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("slice-clear")
                }
                Spacer()
            }
            gridHint(s)
        }
    }

    @ViewBuilder
    private func gridHint(_ s: StudioSample) -> some View {
        if let g = s.grid {
            Text("Auto-slice snaps to the \(Fmt.trim(g.bpm)) BPM grid.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        } else {
            HStack(spacing: 10) {
                Button { detectBPM(s) } label: {
                    HStack(spacing: 6) {
                        if detectInFlight { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "waveform.badge.magnifyingglass") }
                        Text(detectInFlight ? "Detecting…" : "Detect BPM")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent).disabled(detectInFlight)
                .accessibilityIdentifier("slice-detect-bpm")
                Text(detectFailed ? "No tempo found — even chop it is." : "No grid: auto-slice does an even chop.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
    }

    // MARK: Pad grid

    private func padGrid(_ s: StudioSample) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 160), spacing: 8)], spacing: 8) {
            ForEach(0..<StudioSlice.maxSlots, id: \.self) { slot in
                padCell(slot: slot, s: s, pad: pads.first { $0.slot == slot })
            }
        }
    }

    @ViewBuilder
    private func padCell(slot: Int, s: StudioSample, pad: StudioSlice?) -> some View {
        let color = StudioCuesView.slotColor(slot)
        if let pad {
            Button {
                if let w = studio.sliceWindow(sampleId: sampleId, slot: slot) {
                    engine.playSlice(startMs: w.startMs, endMs: w.endMs)
                }
            } label: {
                VStack(spacing: 3) {
                    Text(pad.name ?? "Pad \(slot + 1)")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(StudioFmt.mmssTenths(pad.startMs))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("slice-pad-\(slot)")
            .contextMenu { padMenu(slot: slot, s: s) }
        } else {
            Button {
                // Add a pad at a proportional position so it lands somewhere useful to nudge/drag.
                studio.setSlice(sampleId: sampleId, slot: slot,
                                startMs: max(0, s.durationMs) * slot / StudioSlice.maxSlots)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                    Text("Add").font(.caption2)
                }
                .foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("slice-pad-\(slot)")
        }
    }

    @ViewBuilder private func padMenu(slot: Int, s: StudioSample) -> some View {
        Button {
            renameSlot = slot
            renameText = studio.slice(sampleId: sampleId, slot: slot)?.name ?? ""
            showRename = true
        } label: { Label("Rename", systemImage: "pencil") }
        Button { studio.nudgeSlice(sampleId: sampleId, slot: slot, deltaMs: -50) } label: {
            Label("Nudge −50 ms", systemImage: "gobackward.minus")
        }
        Button { studio.nudgeSlice(sampleId: sampleId, slot: slot, deltaMs: 50) } label: {
            Label("Nudge +50 ms", systemImage: "goforward.plus")
        }
        Button {
            Task { if let id = await bakeSlice(s, slot: slot) { notice = "Baked pad \(slot + 1) → a new sample." ; _ = id } }
        } label: { Label("Make sample", systemImage: "waveform.badge.plus") }
            .accessibilityIdentifier("slice-make-sample-\(slot)")
        Divider()
        Button(role: .destructive) {
            engine.stopSample()
            studio.removeSlice(sampleId: sampleId, slot: slot)
        } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Bake controls (performance pads)

    private func bakeControls(_ s: StudioSample) -> some View {
        Button { Task { await sendToSequencer(s) } } label: {
            HStack(spacing: 8) {
                if baking { ProgressView().controlSize(.small) }
                Image(systemName: "square.grid.3x3.fill")
                Text(baking ? "Baking pads…" : "Send pads to sequencer")
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.accent)
        .disabled(baking || pads.isEmpty)
        .accessibilityIdentifier("slice-send-sequencer")
    }

    // MARK: Actions

    private func load() async {
        guard let s = sample else { return }
        if engine.loadedSampleId != sampleId, let got = rawURL(s) {
            engine.loadSample(s, url: got.url, release: got.release)   // engine holds this scope
        }
        if let got = rawURL(s) {
            let url = got.url
            peaks = await WaveformExtractor.peaks(url: url, targetCount: 240)
            got.release?()
        }
    }

    private func rawURL(_ s: StudioSample) -> (url: URL, release: (() -> Void)?)? {
        StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                              wasUserFolder: s.wasUserFolder, bookmark: studio.bookmark(for: .samples))
    }

    private func autoSlice(_ s: StudioSample) {
        engine.stopSample()
        let starts = BeatMath.sliceStarts(count: sliceCount, grid: s.grid?.sliceGrid, durationMs: s.durationMs)
        studio.setSlices(sampleId: sampleId, startsMs: starts)
    }

    /// On-device tempo detection so grid-less samples can beat-align (mirrors the sample editor).
    private func detectBPM(_ s: StudioSample) {
        guard !detectInFlight, let resolved = rawURL(s) else { detectFailed = true; return }
        detectInFlight = true; detectFailed = false
        let url = resolved.url, release = resolved.release, id = s.id
        Task {
            let grid = await Task.detached(priority: .userInitiated) { () -> StudioGrid? in
                defer { release?() }
                guard let buf = try? StudioRender.decodeFileSync(url: url) else { return nil }
                return BeatDetect.detectGrid(buf)
            }.value
            detectInFlight = false
            if let grid { studio.setSampleGrid(id, grid) } else { detectFailed = true }
        }
    }

    /// Bake a pad's [start,end) region into a new independent `smp_` sample (neutral carve of the
    /// RAW file). Returns the new sample id, or nil on failure.
    private func bakeSlice(_ s: StudioSample, slot: Int) async -> String? {
        guard let w = studio.sliceWindow(sampleId: sampleId, slot: slot), let src = rawURL(s) else { return nil }
        defer { src.release?() }
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples)) else { return nil }
        defer { dest.release?() }
        let id = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: id)
        let destURL = dest.url.appendingPathComponent(fileName)
        guard let carved = try? await StudioRender.shared.carveTrackRegion(
            sourceURL: src.url, startMs: w.startMs, endMs: w.endMs, to: destURL) else { return nil }
        studio.addSample(StudioSample(
            id: id, name: "\(s.name) · pad \(slot + 1)", fileName: fileName,
            wasUserFolder: dest.isUserFolder, createdAt: Date().timeIntervalSince1970 * 1000,
            durationMs: carved.durationMs, source: .file(originalName: "\(s.name) pad \(slot + 1)"),
            grid: s.grid, edit: .neutral))
        return id
    }

    /// Bake every pad → a new sequencer pattern, one row per pad (targets the baked samples, which
    /// are normal `smp_` sequencer targets). Time-ordered by pad start.
    private func sendToSequencer(_ s: StudioSample) async {
        guard !baking else { return }
        baking = true
        defer { baking = false }
        var targets: [String] = []
        for pad in pads.sorted(by: { $0.startMs < $1.startMs }) {
            if let id = await bakeSlice(s, slot: pad.slot) { targets.append(id) }
        }
        guard !targets.isEmpty else { notice = "Couldn’t bake the pads — check the samples folder."; return }
        let rows = targets.map { StudioPatternRow(targetId: $0) }
        _ = studio.addPattern(StudioPattern(id: StudioFactory.newPatternId(),
                                            name: "\(s.name) slices",
                                            bpm: s.grid?.bpm ?? 120, rows: rows))
        notice = "Baked \(targets.count) pads → a new sequencer pattern."
    }
}
