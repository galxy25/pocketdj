import SwiftUI

// MARK: - Studio ▸ Loops (spec §1 sub-tab 2)
//
// Two sections:
//   (a) SAVED LOOPS — every rendered `StudioLoop`: name, beats label, BPM, length; a looped
//       audition toggle (StudioEngine.playLoop / stopLoop — the CAF resolves through
//       `studio.localURLForPlayback(id:)`, which hands back the security-scope release the
//       engine drops right after its full decode); rename + delete (with confirmation that
//       spells out the sequencer rows that would go silent — the store never cascades).
//   (b) NEW LOOP builder — pick a SAMPLE (only samples slice; grid-less ones are disabled with
//       the set-BPM CTA), choose a beat window (½ 1 2 4 8 16 32), snap an anchor beat-by-beat,
//       see the exact computed window (BeatMath.sliceBoundaries — the SAME math the renderer
//       uses, so what the label says is byte-for-byte what renders), preview, save.
//
// PREVIEW CHOICE (the spec offered two): we render a TEMP loop through the REAL
// `StudioRender.renderLoop` into the caches dir and audition it with `StudioEngine.playLoop`
// on a synthetic `StudioLoop`. The "simpler" alternative — seeking the sample-audition chain
// to the window — was rejected because it plays the window ONCE (a loop preview that doesn't
// loop can't expose a bad seam, which is the one thing a loop preview exists to check) and it
// clobbers the audition chain's live edit/trim state that the sample editor owns. Rendering
// the real artifact means preview and Save can never drift: same code path, same frames.
// The temp file lives OUTSIDE every family folder (caches dir, non-family name), so the strict
// `StudioFolders.fileId` sweep/usage accounting can never mistake it for a real artifact.
//
// House rules honored here: everything critical is IN-CONTENT (iPhone toolbar-overflow lesson);
// there are no narrow sliders (steppers + chips only), so the fixed-width-popover pattern isn't
// needed; no segmented Picker / toolbar controls, so no macOS keyboard-shadow buttons are
// needed either (chips are plain content buttons XCUI clicks directly); a11y ids sit on LEAF
// controls only. Stores/engines arrive via the app-wide environment.
struct StudioLoopsView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Saved-loops list state.
    @State private var renamingId: String?
    @State private var nameDraft = ""
    /// Delete confirmation target (nil = closed). The alert lists pattern-row referrers.
    @State private var pendingDelete: StudioLoop?
    /// Inline list-level notice (unplayable audio / unreachable folder on delete).
    @State private var listNote: String?

    // Builder state.
    @State private var selectedSampleId: String?
    @State private var beats: LoopBeats = .four
    /// nil = the default anchor ("from start" = the grid's `firstDownbeatMs`); non-nil = the
    /// user stepped the anchor. Always fed through `BeatMath.sliceBoundaries`, which snaps it
    /// to the nearest beat ≥ anchor — the stepper only ever stores beat positions anyway.
    @State private var customAnchorMs: Int?
    @State private var loopName = ""
    /// An offline render (preview or save) is in flight — gates both buttons so two renders
    /// can't race the same preview file / double-mint a loop from one tap.
    @State private var rendering = false
    @State private var builderError: String?

    /// The synthetic id the preview auditions under. Deliberately NOT a minted uuid: stable, so
    /// "is the preview playing?" is a plain equality check against `engine.loadedLoopId`, and
    /// it can never collide with a stored loop (uuids never equal the literal "preview").
    private static let previewLoopId = "lp_preview"

    var body: some View {
        List {
            loopsSection
            builderSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .task {
            // Stores take their config pushed from the view layer (the MixRecorder.settings
            // pattern) — the per-family bookmark lookups need it, and this tab may be the
            // first Studio surface the user ever opens.
            studio.settings = settings
            // Preselect the first sliceable sample so the builder isn't a dead "Choose a
            // sample" on every visit (selection state survives tab switches — @State lives
            // as long as the tab shell keeps us mounted).
            if selectedSampleId == nil {
                selectedSampleId = studio.samples.first { $0.grid != nil }?.id
            }
        }
        // NOTE: no stop on disappear — StudioEngine is app-scoped precisely so audition
        // survives navigation (spec §4); the row/preview toggles are the way to silence it.
        .alert("Rename loop", isPresented: Binding(get: { renamingId != nil },
                                                   set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft)
                .accessibilityIdentifier("loop-rename-field")
            Button("Save") {
                if let id = renamingId { studio.renameLoop(id, to: nameDraft) }
                renamingId = nil
            }
            .accessibilityIdentifier("loop-rename-confirm")
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .alert("Delete loop?", isPresented: Binding(get: { pendingDelete != nil },
                                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { loop in
            Button("Delete", role: .destructive) { performDelete(loop) }
                .accessibilityIdentifier("loop-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { loop in
            Text(deleteMessage(loop))
        }
    }

    // MARK: - Section (a): saved loops

    /// Newest first — matches the sessions/recordings lists (the thing you just made is the
    /// thing you want to hear).
    private var loopsNewestFirst: [StudioLoop] {
        studio.loops.sorted { $0.createdAt > $1.createdAt }
    }

    private var loopsSection: some View {
        Section {
            if loopsNewestFirst.isEmpty {
                Text("No loops yet — pick a sample below and slice a beat-synced window.")
                    .font(.callout).foregroundStyle(Theme.fgDim)
            } else {
                ForEach(loopsNewestFirst) { loop in
                    loopRow(loop)
                        // Rename/delete ride swipe actions (iOS) + context menu (macOS
                        // right-click / iOS long-press) — the MixSessionsView precedent.
                        .swipeActions(edge: .leading) {
                            Button { beginRename(loop) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Theme.accent2)
                            .accessibilityIdentifier("loop-rename-\(loop.id)")
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = loop } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("loop-delete-\(loop.id)")
                        }
                        .contextMenu {
                            Button { beginRename(loop) } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = loop } label: {
                                Label("Delete loop", systemImage: "trash")
                            }
                        }
                }
            }
            if let listNote {
                Text(listNote).font(.caption).foregroundStyle(Theme.danger)
            }
        } header: {
            Text("Loops")
        }
    }

    private func loopRow(_ loop: StudioLoop) -> some View {
        let auditioning = engine.isPlayingLoop && engine.loadedLoopId == loop.id
        let sourceGone = !studio.sampleExists(loop.sampleId)
        return HStack(spacing: 12) {
            Button { toggleAudition(loop) } label: {
                Image(systemName: auditioning ? "stop.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(auditioning ? Theme.accent : Theme.fgDim)
                    .frame(width: 34, height: 34)
                    .background(auditioning ? Theme.accent.opacity(0.2) : Theme.bgOverlay,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(auditioning ? Theme.accent : Theme.border, lineWidth: 1))
            }
            // .plain so the button taps independently of the row (List's automatic style
            // would turn the whole row into one tap target and swallow the toggle).
            .buttonStyle(.plain)
            .help(auditioning ? "Stop the looped audition" : "Audition this loop (loops until stopped)")
            .accessibilityIdentifier("loop-audition-\(loop.id)")

            VStack(alignment: .leading, spacing: 3) {
                Text(loop.name.isEmpty ? "Loop" : loop.name)
                    .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                Text("\(loop.beats.label) \(loop.beats.beatCount == 1 ? "beat" : "beats")"
                     + " · \(String(format: "%.1f", loop.bpm)) BPM"
                     + " · \(Self.lengthLabel(loop.lengthMs))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                if sourceGone {
                    // Spec §2: loops are self-contained after render — flag, never break.
                    Text("Source sample removed — still plays, can't be re-sliced")
                        .font(.caption2).foregroundStyle(Theme.accent2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Sub-10 s lengths in raw ms (a ½-beat loop is 250 ms — "0:00" would read broken);
    /// longer ones as m:ss like everywhere else.
    private static func lengthLabel(_ ms: Int) -> String {
        ms < 10_000 ? "\(ms) ms" : Fmt.duration(ms)
    }

    private func beginRename(_ loop: StudioLoop) {
        nameDraft = loop.name
        renamingId = loop.id
    }

    private func toggleAudition(_ loop: StudioLoop) {
        if engine.isPlayingLoop, engine.loadedLoopId == loop.id {
            engine.stopLoop()
            return
        }
        // Resolves the CAF against the root it was WRITTEN to; the release closure is handed to
        // the engine, which drops it right after the full decode (nothing re-reads the file).
        guard let got = studio.localURLForPlayback(id: loop.id) else {
            listNote = "“\(loop.name)” can’t play right now — its audio file or folder is unreachable."
            return
        }
        listNote = nil
        engine.playLoop(loop, url: got.url, release: got.release)
    }

    private func deleteMessage(_ loop: StudioLoop) -> String {
        let rows = studio.referrers(for: loop.id).patternRowCount
        var msg = "This deletes the loop’s audio file."
        if rows > 0 {
            msg += " \(rows) sequencer row\(rows == 1 ? "" : "s") targeting it will go silent."
        }
        return msg
    }

    private func performDelete(_ loop: StudioLoop) {
        // Silence it first — deleting the file under a looping schedule leaves the decoded
        // buffer ringing with no row to stop it from.
        if engine.loadedLoopId == loop.id { engine.stopLoop() }
        if studio.deleteLoop(loop.id) {
            listNote = nil
        } else {
            // The store's unreachable-user-root rule: record kept, nothing deleted (data safety).
            listNote = "The loops folder is unreachable right now — reconnect it, then delete “\(loop.name)”."
        }
    }

    // MARK: - Section (b): new-loop builder

    private var selectedSample: StudioSample? {
        selectedSampleId.flatMap { studio.sample($0) }
    }

    private var isPreviewing: Bool {
        engine.isPlayingLoop && engine.loadedLoopId == Self.previewLoopId
    }

    @ViewBuilder private var builderSection: some View {
        Section {
            if studio.samples.isEmpty {
                // Empty state: loops are DERIVED — point at the source tab, don't dead-end.
                Text("No samples yet — record or carve one on the Samples tab. Loops are beat-grid slices of samples.")
                    .font(.callout).foregroundStyle(Theme.fgDim)
            } else {
                samplePickerRow
                if studio.samples.contains(where: { $0.grid == nil }) {
                    // The spec's exact CTA for grid-less (disabled) samples: they need a BPM
                    // before slice math exists for them.
                    Text("Set BPM in the sample editor to slice loops")
                        .font(.caption).foregroundStyle(Theme.accent2)
                        .accessibilityIdentifier("loop-gridless-cta")
                }
                if let s = selectedSample, let grid = s.grid {
                    beatChips
                    anchorRow(sample: s, grid: grid)
                    windowRow(sample: s, grid: grid)
                    TextField("Loop name (optional)", text: $loopName)
                        .pocketField()
                        .accessibilityIdentifier("loop-name-field")
                    actionsRow(sample: s, grid: grid)
                }
                if let builderError {
                    Text(builderError).font(.caption).foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text("New loop")
        } footer: {
            Text("Loops render to a seamless audio file with the sample’s edits baked in — they keep playing even if the sample is later deleted.")
        }
    }

    private var samplePickerRow: some View {
        HStack {
            Text("Sample").foregroundStyle(Theme.fgDim)
            Spacer()
            Menu {
                ForEach(studio.samples) { s in
                    if s.grid != nil {
                        Button { selectSample(s) } label: {
                            if s.id == selectedSampleId {
                                Label(Self.sampleDisplayName(s), systemImage: "checkmark")
                            } else {
                                Text(Self.sampleDisplayName(s))
                            }
                        }
                    } else {
                        // Disabled per spec — no grid, no slice math. The CTA caption under
                        // the picker says how to fix it (menu items can't carry captions).
                        Button {} label: { Text("\(Self.sampleDisplayName(s)) — no BPM") }
                            .disabled(true)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedSample.map(Self.sampleDisplayName) ?? "Choose a sample")
                        .foregroundStyle(selectedSample == nil ? Theme.fgDim : Theme.fg)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityIdentifier("loop-sample-picker")
        }
    }

    private static func sampleDisplayName(_ s: StudioSample) -> String {
        s.name.isEmpty ? "Sample" : s.name
    }

    /// ½ 1 2 4 8 16 32 as compact chips — 7 of them fit an iPhone-portrait row (a segmented
    /// Picker would truncate AND need macOS keyboard shadows; plain buttons need neither).
    private var beatChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Beats").font(.caption).foregroundStyle(Theme.fgDim)
            HStack(spacing: 6) {
                ForEach(LoopBeats.allCases, id: \.self) { b in
                    let on = beats == b
                    Button { setBeats(b) } label: {
                        Text(b.label)
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(minWidth: 30)
                            .padding(.vertical, 6)
                            .background(on ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: 1))
                            .foregroundStyle(on ? Theme.accent : Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    // "0.5", "1" … "32" — the spec's literal id shape (loop-slice-0.5 / -8).
                    .accessibilityIdentifier("loop-slice-\(Self.beatsToken(b))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func beatsToken(_ b: LoopBeats) -> String {
        b == .half ? "0.5" : String(Int(b.rawValue))
    }

    /// Anchor control: ±1 beat steppers + "From start" reset, always displaying the SNAPPED
    /// beat position (the stepper stores beat positions; a raw default anchor snaps forward
    /// inside `sliceBoundaries` exactly like the renderer will).
    private func anchorRow(sample: StudioSample, grid: StudioGrid) -> some View {
        let anchor = effectiveAnchorMs(grid: grid)
        // beats:1 gives (snapped current beat, next beat) in one call — the stepper's world.
        let step = BeatMath.sliceBoundaries(anchorMs: anchor, beats: 1, grid: grid.sliceGrid)
        let snapped = step?.startMs ?? anchor
        let canDec = Self.previousBeat(before: snapped, grid: grid) != nil
        // Don't step INTO pure silence: once the next beat starts at/after the sample's end
        // the whole window would render as padding.
        let canInc = step.map { $0.endMs < sample.durationMs } ?? false
        return HStack(spacing: 8) {
            Text("Anchor").font(.caption).foregroundStyle(Theme.fgDim)
            Spacer()
            Button { stepAnchor(-1, grid: grid) } label: {
                Image(systemName: "minus")
                    .frame(width: 30, height: 26)
                    .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canDec || rendering)
            .help("Move the anchor one beat earlier")
            .accessibilityIdentifier("loop-anchor-dec")

            Text(customAnchorMs == nil ? "start · \(snapped) ms" : "\(snapped) ms")
                .font(.callout.monospacedDigit()).foregroundStyle(Theme.fg)
                .frame(minWidth: 96)
                .accessibilityIdentifier("loop-anchor-label")

            Button { stepAnchor(+1, grid: grid) } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 26)
                    .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canInc || rendering)
            .help("Move the anchor one beat later")
            .accessibilityIdentifier("loop-anchor-inc")

            Button("From start") { resetAnchor() }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(customAnchorMs == nil ? Theme.fgDim : Theme.accent)
                .disabled(customAnchorMs == nil || rendering)
                .help("Snap the anchor back to the first downbeat")
                .accessibilityIdentifier("loop-anchor-reset")
        }
    }

    /// The exact window the renderer will slice — same call, same numbers (spec: "show the
    /// computed window ms via BeatMath.sliceBoundaries").
    @ViewBuilder private func windowRow(sample: StudioSample, grid: StudioGrid) -> some View {
        if let w = currentWindow(grid: grid) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Window \(w.startMs)–\(w.endMs) ms · \(w.lengthMs) ms")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                    .accessibilityIdentifier("loop-window-label")
                if w.endMs > sample.durationMs {
                    Text("Extends past the sample’s end — the overhang renders as silence.")
                        .font(.caption2).foregroundStyle(Theme.accent2)
                }
            }
        } else {
            // Only reachable on a degenerate grid (no beats AND no positive BPM) — the
            // gridded picker normally fences this off, but a hand-edited document can't crash us.
            Text("No usable beat grid at this anchor.")
                .font(.caption).foregroundStyle(Theme.danger)
        }
    }

    private func actionsRow(sample: StudioSample, grid: StudioGrid) -> some View {
        let ready = currentWindow(grid: grid) != nil
        return HStack(spacing: 10) {
            Button { togglePreview(sample: sample, grid: grid) } label: {
                HStack(spacing: 5) {
                    if rendering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPreviewing ? "stop.fill" : "play.circle")
                    }
                    Text(isPreviewing ? "Stop preview" : "Preview")
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(isPreviewing ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isPreviewing ? Theme.accent : Theme.border, lineWidth: 1))
                .foregroundStyle(isPreviewing ? Theme.accent : Theme.fg)
            }
            .buttonStyle(.plain)
            .disabled(rendering || !ready)
            .help("Render this window and audition it looped — exactly what Save keeps")
            .accessibilityIdentifier("loop-preview")

            Button { saveLoop(sample: sample, grid: grid) } label: {
                Label("Save loop", systemImage: "square.and.arrow.down")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(rendering || !ready)
            .accessibilityIdentifier("loop-save")

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Builder math

    private func effectiveAnchorMs(grid: StudioGrid) -> Int {
        customAnchorMs ?? grid.firstDownbeatMs
    }

    private func currentWindow(grid: StudioGrid) -> (startMs: Int, endMs: Int, lengthMs: Int)? {
        BeatMath.sliceBoundaries(anchorMs: effectiveAnchorMs(grid: grid),
                                 beats: beats.beatCount, grid: grid.sliceGrid)
    }

    /// Constant beat spacing (ms) for stepping past / before the measured grid — the same
    /// preference order `BeatMath.sliceBoundaries` uses (stated bpm, else the grid's own mean).
    private static func beatStep(_ grid: StudioGrid) -> Double? {
        if grid.bpm > 0 { return 60_000.0 / grid.bpm }
        let b = grid.beatsMs
        guard b.count >= 2, let first = b.first, let last = b.last, last > first else { return nil }
        return Double(last - first) / Double(b.count - 1)
    }

    /// The beat one step BEFORE `startMs` (a snapped beat position), on the same
    /// real-or-extended lattice the slicer walks. nil at the grid's first representable beat —
    /// mirroring `sliceBoundaries`' "beats before the anchor don't exist" rule, so the − stepper
    /// disables exactly where the walk would refuse. Pure + deterministic (view-local because
    /// only the stepper walks BACKWARD; everything forward goes through BeatMath).
    private static func previousBeat(before startMs: Int, grid: StudioGrid) -> Int? {
        let real = grid.beatsMs
        if !real.isEmpty {
            // Past the measured grid: walk the constant extension back toward the last real beat.
            if let last = real.last, startMs > last, let step = beatStep(grid) {
                return Int(max(Double(last), Double(startMs) - step).rounded())
            }
            // Largest measured beat strictly < startMs (binary search).
            var lo = 0, hi = real.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if real[mid] < startMs { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? real[lo - 1] : nil
        }
        // Constant grid: one spacing back, but never before the phase anchor (firstDownbeatMs)
        // — the synthesized lattice has no beats before it.
        guard let step = beatStep(grid) else { return nil }
        let prev = Double(startMs) - step
        return prev >= Double(grid.firstDownbeatMs) - 0.5 ? Int(prev.rounded()) : nil
    }

    // MARK: - Builder mutations (every input change kills a stale preview)

    /// A running preview is a rendered snapshot of the OLD inputs — let it keep looping after a
    /// change and the user is auditioning something the Save button won't produce.
    private func stopPreviewIfPlaying() {
        if isPreviewing { engine.stopLoop() }
    }

    private func selectSample(_ s: StudioSample) {
        guard s.id != selectedSampleId else { return }
        stopPreviewIfPlaying()
        selectedSampleId = s.id
        customAnchorMs = nil          // anchors are per-sample-timeline — never carry one over
        builderError = nil
    }

    private func setBeats(_ b: LoopBeats) {
        guard b != beats else { return }
        stopPreviewIfPlaying()
        beats = b
        builderError = nil
    }

    private func stepAnchor(_ direction: Int, grid: StudioGrid) {
        let anchor = effectiveAnchorMs(grid: grid)
        guard let cur = BeatMath.sliceBoundaries(anchorMs: anchor, beats: 1, grid: grid.sliceGrid) else { return }
        stopPreviewIfPlaying()
        builderError = nil
        if direction > 0 {
            customAnchorMs = cur.endMs                    // the next beat (real or extended)
        } else if let prev = Self.previousBeat(before: cur.startMs, grid: grid) {
            customAnchorMs = prev
        }
    }

    private func resetAnchor() {
        stopPreviewIfPlaying()
        customAnchorMs = nil
        builderError = nil
    }

    // MARK: - Preview / save (both run the REAL renderer — see the header comment)

    /// The reusable preview file, in the caches dir: outside every family folder, non-family
    /// name shape, and honestly re-derivable — exactly what caches are for. Overwriting per
    /// preview is safe because `playLoop` decodes the whole file BEFORE returning.
    private static func previewURL() -> URL {
        let dir = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("studio-loop-preview.caf")
    }

    /// Resolve the RAW sample file for rendering. Deliberately NOT `localURLForPlayback` — that
    /// prefers the render CACHE (edits already baked), and `renderLoop` bakes the edits itself:
    /// feeding it the cache would apply them twice, and the grid/anchor are in the RAW file's
    /// timeline anyway.
    private func rawSampleURL(_ s: StudioSample) -> (url: URL, release: (() -> Void)?)? {
        StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                              wasUserFolder: s.wasUserFolder, bookmark: studio.bookmark(for: .samples))
    }

    private func togglePreview(sample: StudioSample, grid: StudioGrid) {
        if isPreviewing { engine.stopLoop(); return }
        guard !rendering else { return }
        // Capture every input NOW — the user can keep editing while the render runs, and the
        // preview must be a snapshot of what they asked for, not of what they typed since.
        let anchor = effectiveAnchorMs(grid: grid)
        let sliceBeats = beats
        rendering = true
        builderError = nil
        Task {
            defer { rendering = false }
            guard let src = rawSampleURL(sample) else {
                builderError = "The sample’s audio file can’t be reached right now."
                return
            }
            // Hold the security scope across the off-main render; release on every exit.
            defer { src.release?() }
            let dest = Self.previewURL()
            do {
                let r = try await StudioRender.shared.renderLoop(sample: sample, sourceURL: src.url,
                                                                 anchorMs: anchor, beats: sliceBeats,
                                                                 grid: grid, to: dest)
                // A synthetic record drives the audition; only frames (the seam-exact trim/pad
                // target) and the id (the "is preview playing" tag) are load-bearing.
                let synthetic = StudioLoop(id: Self.previewLoopId, name: "Preview",
                                           sampleId: sample.id, anchorMs: anchor, beats: sliceBeats,
                                           bpm: r.bpm, lengthMs: r.lengthMs, frames: r.frames,
                                           fileName: dest.lastPathComponent)
                engine.playLoop(synthetic, url: dest)
            } catch {
                builderError = Self.describe(error)
            }
        }
    }

    private func saveLoop(sample: StudioSample, grid: StudioGrid) {
        guard !rendering else { return }
        let anchor = effectiveAnchorMs(grid: grid)
        let sliceBeats = beats
        let typedName = loopName.trimmingCharacters(in: .whitespaces)
        rendering = true
        builderError = nil
        Task {
            defer { rendering = false }
            guard let src = rawSampleURL(sample) else {
                builderError = "The sample’s audio file can’t be reached right now."
                return
            }
            defer { src.release?() }
            // The loops FAMILY folder (user-picked when configured, else app-managed) — write
            // path, so requireWritable stays true (the folder() default).
            guard let folder = StudioFolders.folder(.loops, bookmark: studio.bookmark(for: .loops)) else {
                builderError = "The loops folder can’t be written right now."
                return
            }
            defer { folder.release?() }
            let id = StudioFactory.newLoopId()
            let fileName = StudioFolders.fileName(.loops, id: id)
            do {
                let r = try await StudioRender.shared.renderLoop(sample: sample, sourceURL: src.url,
                                                                 anchorMs: anchor, beats: sliceBeats,
                                                                 grid: grid,
                                                                 to: folder.url.appendingPathComponent(fileName))
                // File the record with the RENDERER's returned truth (frames is authoritative;
                // bpm is the loop's standalone tempo — a baked rate ≠ 1 is already folded in).
                studio.addLoop(StudioLoop(
                    id: id,
                    name: typedName.isEmpty ? Self.defaultName(sample: sample, beats: sliceBeats) : typedName,
                    sampleId: sample.id,
                    anchorMs: anchor,
                    beats: sliceBeats,
                    bpm: r.bpm,
                    lengthMs: r.lengthMs,
                    frames: r.frames,
                    fileName: fileName,
                    wasUserFolder: folder.isUserFolder,
                    createdAt: Date().timeIntervalSince1970 * 1000))
                loopName = ""     // inputs stay put — saving beat-window variants back-to-back is the flow
            } catch {
                builderError = Self.describe(error)
            }
        }
    }

    private static func defaultName(sample: StudioSample, beats: LoopBeats) -> String {
        "\(sampleDisplayName(sample)) · \(beats.label) \(beats.beatCount == 1 ? "beat" : "beats")"
    }

    private static func describe(_ error: Error) -> String {
        switch error as? StudioRenderError {
        case .noGrid: return "No usable beat grid at this anchor."
        case .emptyWindow: return "The window has no audio — move the anchor earlier."
        case .unreadableSource: return "The sample’s audio file can’t be read."
        default: return "Rendering failed — please try again."
        }
    }
}
