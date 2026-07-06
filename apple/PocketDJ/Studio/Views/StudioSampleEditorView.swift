import SwiftUI

/// The non-destructive sample editor (spec §10 "Sample editor") — presented as a sheet from the
/// Samples list. Audition runs through `StudioEngine`'s live sample chain (`loadSample` /
/// `playSample` / `seekSample`; playhead sampled from `samplePlayheadSeconds()` inside a
/// `TimelineView` — never observed state, the PlayerClock doctrine); every control writes the
/// edit BOTH ways in one gesture: `engine.applyEdit` (live AUs / schedule window) and
/// `studio.updateSampleEdit` (persistence + the `renderRevision` bump).
///
/// "Save bakes nothing": there is no save button. The render cache is refreshed IMPLICITLY —
/// whenever `renderRevision` changes, a debounced task calls
/// `StudioRender.shared.renderSample(sample, sourceURL:rawFile, to: folder/renderedSampleFileName)`
/// and files the result with `studio.setRenderedSample(...)`; collection playback prefers the
/// fresh cache, and a stale/missing cache just falls back to the raw file (spec §2).
///
/// The tap-tempo / manual-BPM affordance (a11y `sample-tap-tempo` / `sample-bpm-field`) writes a
/// CONSTANT `StudioGrid(bpm:)` via `studio.setSampleGrid` — grid-less samples (mic) need one
/// before Loops can slice them. A sample that already carries a MEASURED grid (track samples,
/// `beatsMs` non-empty) shows it read-only: overwriting real per-beat timestamps with a constant
/// lattice would destroy inherited data.
struct StudioSampleEditorView: View {
    let sampleId: String

    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Scrub freeze: while the finger is on the slider we show the drag value, not the live
    /// playhead (the StemAuditionPanel scrubber pattern — otherwise the 10 Hz tick fights the drag).
    @State private var scrubbing: Double?
    /// The raw file couldn't be resolved (user folder unreachable / file gone) — explicit state,
    /// never a dead transport.
    @State private var loadFailed = false
    /// Tap-tempo timestamps (`timeIntervalSinceReferenceDate`); a >2.5 s gap starts a new run.
    @State private var tapTimes: [Double] = []
    @State private var bpmText = ""
    @State private var renaming = false
    @State private var renameDraft = ""
    /// True while a background render is writing the edit-baked cache (footnote spinner).
    @State private var renderInFlight = false
    /// True while on-device beat detection is decoding + analysing the raw file.
    @State private var detectInFlight = false
    /// The last auto-detect couldn't lock a tempo (short/quiet/aperiodic) — surfaced in the caption.
    @State private var detectFailed = false

    /// Always read the LIVE store row — edits stream through the store, and rename/delete can
    /// happen underneath (deleted ⇒ the "gone" state below).
    private var sample: StudioSample? { studio.sample(sampleId) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
            if let s = sample {
                if loadFailed {
                    unavailableState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            transport(s)
                            trimSection(s)
                            editSection(s)
                            gridSection(s)
                            renderFootnote(s)
                        }
                        .padding(16)
                    }
                }
            } else {
                goneState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
        .task { load() }
        // Debounced implicit render: fires whenever the edit revision moves (updateSampleEdit
        // bumps it exactly when the edit VALUE changed). Revision 0 = never edited — the raw
        // file IS the truth, no cache needed.
        .task(id: sample?.renderRevision ?? -1) {
            guard let s = sample, s.renderRevision > 0, !s.isRenderFresh else { return }
            // Edits stream continuously from sliders — wait for quiescence before burning CPU
            // on a bake that the next slider tick would immediately invalidate.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await renderNow()
        }
        .onDisappear {
            // The editor owns the audition: closing it stops playback and releases the raw
            // file's security scope (held by the engine since load).
            if engine.loadedSampleId == sampleId { engine.unloadSample() }
            // Final render kick for an edit whose debounce window was cut short by the close —
            // renderNow() no-ops when the cache is already fresh or nothing was ever edited.
            Task { await renderNow() }
        }
        .alert("Rename sample", isPresented: $renaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") { studio.renameSample(sampleId, to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Load / degraded states

    private func load() {
        guard let s = sample else { return }
        if bpmText.isEmpty, let bpm = s.grid?.bpm { bpmText = Fmt.trim(bpm) }
        guard engine.loadedSampleId != s.id else { return }   // sheet re-presented — already loaded
        // Resolve the RAW file against the root it was written to; the engine HOLDS the returned
        // scope release for the load's lifetime (releasing early = silent 0:00, the BurnStore lesson).
        if let got = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                           wasUserFolder: s.wasUserFolder,
                                           bookmark: studio.bookmark(for: .samples)) {
            engine.loadSample(s, url: got.url, release: got.release)
            loadFailed = false
        } else {
            loadFailed = true
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36)).foregroundStyle(Theme.fgDim)
            Text("Audio unavailable").font(.headline).foregroundStyle(Theme.fg)
            Text("This sample's file lives in your samples folder, which isn't reachable right "
                 + "now. Reconnect it (Settings ▸ Storage), then reopen the editor.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("Retry") { load() }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-edit-retry")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var goneState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("This sample no longer exists.")
                .font(.callout).foregroundStyle(Theme.fgDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample?.name.isEmpty == false ? sample!.name : "Untitled sample")
                    .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                Text(sourceLine)
                    .font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            Button {
                renameDraft = sample?.name ?? ""
                renaming = true
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sample-edit-rename")
            Button("Done") { dismiss() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-edit-done")
        }
    }

    private var sourceLine: String {
        switch sample?.source {
        case .track(let songId, let startMs, let endMs):
            let name = app.songsById[songId]?.name ?? "track"
            return "From \(name) · \(StudioFmt.mmssTenths(startMs))–\(StudioFmt.mmssTenths(endMs))"
        case .mic:
            return "Microphone recording"
        case .take:
            return "From an instrument take"
        case .file(let originalName):
            return originalName.isEmpty ? "Imported audio file" : "Imported from \(originalName)"
        case nil:
            return ""
        }
    }

    // MARK: Transport (playhead sampled, never observed)

    private func transport(_ s: StudioSample) -> some View {
        let durSec = max(0.1, Double(s.durationMs) / 1000)
        return TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            // Playhead is only meaningful while THIS sample is the loaded one.
            let live = engine.loadedSampleId == s.id ? engine.samplePlayheadSeconds() : 0
            let pos = min(scrubbing ?? live, durSec)
            VStack(spacing: 6) {
                Slider(value: Binding(get: { pos }, set: { scrubbing = $0 }), in: 0...durSec) { editing in
                    if !editing, let t = scrubbing {
                        engine.seekSample(toSeconds: t)
                        scrubbing = nil
                    }
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("sample-edit-scrub")
                HStack {
                    Text(StudioFmt.clock(pos))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Text(StudioFmt.clock(durSec))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                HStack(spacing: 18) {
                    Spacer()
                    Button {
                        if engine.isPlayingSample { engine.pauseSample() } else { engine.playSample() }
                    } label: {
                        Image(systemName: engine.isPlayingSample ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 38).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("sample-edit-play")
                    Button { engine.stopSample() } label: {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .frame(width: 44, height: 38).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("sample-edit-stop")
                    Spacer()
                }
            }
        }
    }

    // MARK: Trim (schedule-window edit — spec: sliders + fine nudge)

    private func trimSection(_ s: StudioSample) -> some View {
        let dur = Double(max(1, s.durationMs))
        // `trimEndMs == 0` means "to the end of the file" (the model's neutral) — display maps
        // it onto the actual duration so the slider sits at the right edge.
        let endDisplay = Double(s.edit.trimEndMs == 0 ? s.durationMs : s.edit.trimEndMs)
        return section("TRIM") {
            StudioEditSlider(title: "Start", systemImage: "arrow.right.to.line",
                             range: 0...dur, step: 10,
                             value: Double(s.edit.trimStartMs),
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "sample-trim-start") { v in
                apply { e in
                    let end = e.trimEndMs == 0 ? s.durationMs : e.trimEndMs
                    // Keep ≥50 ms of window — a zero-frame window is refused by the engine and
                    // renderer anyway; the floor keeps the handles from crossing.
                    e.trimStartMs = min(Int(v), max(0, end - 50))
                }
            }
            StudioEditSlider(title: "End", systemImage: "arrow.left.to.line",
                             range: 0...dur, step: 10,
                             value: endDisplay,
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "sample-trim-end") { v in
                apply { e in
                    let ms = Int(v)
                    // At (or past) the file's end store the neutral 0 — "to the end" without
                    // freezing the file length into the edit.
                    e.trimEndMs = ms >= s.durationMs ? 0 : max(ms, e.trimStartMs + 50)
                }
            }
        }
    }

    // MARK: Sonic edits (live-applied; baked only by the implicit render)

    private func editSection(_ s: StudioSample) -> some View {
        section("EDIT") {
            StudioEditSlider(title: "Gain", systemImage: "speaker.wave.2",
                             range: -60...12, step: 1,
                             value: s.edit.gainDb,
                             format: { String(format: "%+.0f dB", $0) },
                             a11y: "sample-edit-gain") { v in
                apply { $0.gainDb = v }
            }
            StudioEditSlider(title: "Rate", systemImage: "hare",
                             range: 0.5...2.0, step: 0.05,
                             value: s.edit.rate,
                             format: { String(format: "×%.2f", $0) },
                             a11y: "sample-edit-rate") { v in
                apply { $0.rate = v }
            }
            StudioEditSlider(title: "Pitch", systemImage: "tuningfork",
                             range: -12...12, step: 1,
                             value: s.edit.pitchSemitones,
                             format: { String(format: "%+.0f st", $0) },
                             a11y: "sample-edit-pitch") { v in
                apply { $0.pitchSemitones = v }
            }
            StudioEditSlider(title: "Reverb", systemImage: "water.waves",
                             range: 0...1, step: 0.05,
                             value: s.edit.reverbWet,
                             format: { "\(Int(($0 * 100).rounded()))%" },
                             a11y: "sample-edit-reverb") { v in
                apply { $0.reverbWet = v }
            }
            StudioEditSlider(title: "Delay", systemImage: "wave.3.right",
                             range: 0...1, step: 0.05,
                             value: s.edit.delayWet,
                             format: { "\(Int(($0 * 100).rounded()))%" },
                             a11y: "sample-edit-delay") { v in
                apply { $0.delayWet = v }
            }
        }
    }

    /// One edit mutation, applied BOTH ways in one gesture: live to the audition chain and to
    /// the store (which clamps, persists debounced, and bumps `renderRevision` iff changed).
    private func apply(_ mutate: (inout StudioSampleEdit) -> Void) {
        guard let s = sample else { return }
        var e = s.edit
        mutate(&e)
        let clamped = e.clamped()
        engine.applyEdit(clamped)
        studio.updateSampleEdit(s.id, clamped)
    }

    // MARK: Beat grid (tap tempo / manual BPM — spec §2)

    @ViewBuilder
    private func gridSection(_ s: StudioSample) -> some View {
        if let g = s.grid, !g.beatsMs.isEmpty {
            // A MEASURED grid (inherited from the parent track's analysis sidecar): read-only.
            // Overwriting real per-beat timestamps with a constant lattice destroys data the
            // user can't get back without re-carving.
            section("BEAT GRID") {
                Label("\(Fmt.trim(g.bpm)) BPM · measured grid", systemImage: "metronome")
                    .font(.callout).foregroundStyle(Theme.fg)
            }
        } else {
            section("BEAT GRID") {
                Button { detectBPM(s) } label: {
                    HStack(spacing: 7) {
                        if detectInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                        }
                        Text(detectInFlight ? "Detecting tempo…" : "Auto-detect tempo")
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .disabled(detectInFlight)
                .accessibilityIdentifier("sample-detect-bpm")

                HStack(spacing: 10) {
                    Button { tapTempo() } label: {
                        Label(tapTimes.isEmpty || tapTimes.count >= 4
                              ? "Tap tempo" : "Tap (\(tapTimes.count))",
                              systemImage: "hand.tap")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("sample-tap-tempo")

                    TextField("BPM", text: $bpmText)
                        .pocketField()
                        .frame(width: 84)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onSubmit { commitBpm() }
                        .accessibilityIdentifier("sample-bpm-field")

                    Button("Set") { commitBpm() }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("sample-bpm-set")
                    Spacer()
                }
                Text(gridCaption(s))
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
    }

    private func gridCaption(_ s: StudioSample) -> String {
        if detectFailed { return "Couldn't detect a tempo — tap at least 4 beats or type a BPM." }
        if s.grid != nil { return "Constant grid: \(Fmt.trim(s.grid!.bpm)) BPM — loops slice on this tempo." }
        return "No grid yet — auto-detect, tap at least 4 beats, or type a BPM to enable slicing."
    }

    /// Analyse the sample's raw file ON-DEVICE and write back a constant grid. Decode + DSP run OFF
    /// the main actor (blocking file read + FFTs); the security scope stays held until the read
    /// completes. Failure leaves the sample grid-less — tap-tempo/manual entry stay available.
    private func detectBPM(_ s: StudioSample) {
        guard !detectInFlight else { return }
        let bm = studio.bookmark(for: .samples)
        guard let resolved = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                                   wasUserFolder: s.wasUserFolder, bookmark: bm) else {
            detectFailed = true
            return
        }
        detectInFlight = true
        detectFailed = false
        let url = resolved.url
        let release = resolved.release
        let id = s.id
        Task {
            let grid = await Task.detached(priority: .userInitiated) { () -> StudioGrid? in
                defer { release?() }
                guard let buf = try? StudioRender.decodeFileSync(url: url) else { return nil }
                return BeatDetect.detectGrid(buf)
            }.value
            detectInFlight = false
            if let grid {
                studio.setSampleGrid(id, grid)
                bpmText = Fmt.trim(grid.bpm)
            } else {
                detectFailed = true
            }
        }
    }

    /// ≥4 taps → median inter-tap interval → BPM (median, not mean: one flubbed tap must not
    /// skew the tempo). A >2.5 s gap (24 BPM — below any musical tempo) starts a fresh run.
    private func tapTempo() {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = tapTimes.last, now - last > 2.5 { tapTimes = [] }
        tapTimes.append(now)
        guard tapTimes.count >= 4 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 0.2, median < 2.5 else { return }   // 24–300 BPM sanity window
        let bpm = ((60.0 / median) * 10).rounded() / 10
        bpmText = Fmt.trim(bpm)
        studio.setSampleGrid(sampleId, StudioGrid(bpm: bpm))
    }

    private func commitBpm() {
        let normalized = bpmText.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalized), v >= 20, v <= 300 else { return }
        studio.setSampleGrid(sampleId, StudioGrid(bpm: v))
    }

    // MARK: Implicit render (the "Save bakes nothing" cache refresh)

    @ViewBuilder
    private func renderFootnote(_ s: StudioSample) -> some View {
        HStack(spacing: 6) {
            if renderInFlight {
                ProgressView().controlSize(.mini)
                Text("Updating the rendered copy…")
            } else {
                Image(systemName: "checkmark.circle")
                Text("Edits are non-destructive and apply automatically — nothing to save.")
            }
        }
        .font(.caption2).foregroundStyle(Theme.fgDim)
    }

    /// Bake the current edit into the revision-stamped render cache. Exact chain (spec §10):
    /// raw file resolved via `StudioFolders.fileURL` → `StudioRender.shared.renderSample` writes
    /// `StudioFolders.renderedSampleFileName(id:revision:)` into the samples family folder
    /// (`StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples))`) →
    /// `studio.setRenderedSample` files it at the revision it was rendered AT (an edit landing
    /// mid-render just leaves the new cache stale — playback keeps using the raw file).
    private func renderNow() async {
        guard let s = studio.sample(sampleId), s.renderRevision > 0, !s.isRenderFresh,
              !renderInFlight else { return }
        renderInFlight = true
        defer { renderInFlight = false }
        let bm = studio.bookmark(for: .samples)
        guard let src = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                              wasUserFolder: s.wasUserFolder, bookmark: bm) else { return }
        guard let dest = StudioFolders.folder(.samples, bookmark: bm) else {
            src.release?()
            return
        }
        let revision = s.renderRevision
        let fileName = StudioFolders.renderedSampleFileName(id: s.id, revision: revision)
        let oldCache = (s.renderedFileName, s.renderedWasUserFolder ?? false)
        do {
            _ = try await StudioRender.shared.renderSample(s, sourceURL: src.url,
                                                           to: dest.url.appendingPathComponent(fileName))
            studio.setRenderedSample(s.id, fileName: fileName,
                                     wasUserFolder: dest.isUserFolder, revision: revision)
            // Reap the superseded revision's cache file (best-effort — derived data): the
            // revision stamp makes every render a NEW file, so without this each edit session
            // would strand one `-rN` file per revision.
            if let old = oldCache.0, old != fileName,
               let got = StudioFolders.fileURL(family: .samples, fileName: old,
                                               wasUserFolder: oldCache.1, bookmark: bm) {
                try? FileManager.default.removeItem(at: got.url)
                got.release?()
            }
        } catch {
            // Throwing renders leave no partial file (StudioRender's atomic-write discipline);
            // the record keeps pointing at the previous cache or none — playback falls back to
            // the raw file, which is always truthful.
        }
        src.release?()
        dest.release?()
    }

    // MARK: Section chrome

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - Width-adaptive edit slider (shared by the editor + the region carve view)

/// A labeled parameter control: label + slider + fine −/＋ steps + value readout.
/// REGULAR width (iPad / macOS / iPhone landscape): everything inline.
/// COMPACT width (iPhone portrait): the slider collapses to a value CHIP that opens a
/// fixed-width popover with the real slider — an inline slider squeezed beside its label is too
/// narrow to drag precisely on a phone (MixView's ChipStrengthPopover precedent, spec §10).
struct StudioEditSlider: View {
    let title: String
    let systemImage: String
    let range: ClosedRange<Double>
    /// The fine-step increment (−/＋ buttons; also the popover's steppers).
    let step: Double
    let value: Double
    let format: (Double) -> String
    let a11y: String
    let onChange: (Double) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var usePopover: Bool { hSize == .compact }
    #else
    private var usePopover: Bool { false }
    #endif
    @State private var showPopover = false

    var body: some View {
        if usePopover {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption).foregroundStyle(Theme.fgDim)
                Spacer()
                Button { showPopover = true } label: {
                    Text(format(value))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.bgOverlay, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(a11y)
                .popover(isPresented: $showPopover, arrowEdge: .top) {
                    StudioSliderPopover(title: title, systemImage: systemImage, range: range,
                                        step: step, value: value, format: format,
                                        a11y: a11y + "-slider", presented: $showPopover,
                                        onChange: onChange)
                }
            }
        } else {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .frame(width: 108, alignment: .leading)
                StudioStepButton(dir: -1, range: range, step: step, value: value,
                                 a11y: a11y, onChange: onChange)
                Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
                    .tint(Theme.accent)
                    .accessibilityIdentifier(a11y)
                StudioStepButton(dir: 1, range: range, step: step, value: value,
                                 a11y: a11y, onChange: onChange)
                Text(format(value))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

/// The fixed-width popover face of `StudioEditSlider` — wide enough to actually drag; dismisses
/// on an outside tap (native popover) OR after 3 s with no interaction (the MixView
/// ChipStrengthPopover contract: each drag/step restarts the idle timer).
struct StudioSliderPopover: View {
    let title: String
    let systemImage: String
    let range: ClosedRange<Double>
    let step: Double
    let value: Double
    let format: (Double) -> String
    let a11y: String
    @Binding var presented: Bool
    let onChange: (Double) -> Void
    @State private var interaction = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                StudioStepButton(dir: -1, range: range, step: step, value: value,
                                 a11y: a11y, onChange: onChange, onInteract: { interaction += 1 })
                Slider(value: Binding(get: { value }, set: { onChange($0); interaction += 1 }), in: range)
                    .tint(Theme.accent)
                    .accessibilityIdentifier(a11y)
                StudioStepButton(dir: 1, range: range, step: step, value: value,
                                 a11y: a11y, onChange: onChange, onInteract: { interaction += 1 })
                Text(format(value))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)   // stay a popover on iPhone (not a sheet)
        .task(id: interaction) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { presented = false }
        }
    }
}

/// A fine −/＋ step button (clamped to the control's range). `dir` is ±1.
struct StudioStepButton: View {
    let dir: Double
    let range: ClosedRange<Double>
    let step: Double
    let value: Double
    let a11y: String
    let onChange: (Double) -> Void
    var onInteract: () -> Void = {}

    var body: some View {
        Button {
            let next = min(range.upperBound, max(range.lowerBound, value + dir * step))
            onChange(next)
            onInteract()
        } label: {
            Image(systemName: dir < 0 ? "minus" : "plus")
                .font(.caption2.weight(.bold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.fgDim)
        .accessibilityIdentifier(a11y + (dir < 0 ? "-minus" : "-plus"))
    }
}
