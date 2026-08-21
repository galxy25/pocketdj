import SwiftUI
import UniformTypeIdentifiers

// MARK: - Studio ▸ Instruments ▸ Score (spec §7)
//
// A take's musical score: `ScoreQuantizer.quantize` (derived at render time — never persisted,
// so quantizer improvements retroactively improve every saved take) laid out by
// `ScoreLayout.paginate` and drawn by `ScoreRenderer` into each page's Canvas. The pages are
// laid at the PDF's OWN A4 metrics and scaled to the screen width — deliberately, so what the
// user sees IS the export, pixel-proportional (one layout, two hosts, zero drift; the ScorePDF
// header's design). Replay plays the take's raw EVENTS back through InstrumentEngine, so the
// score and the sound always agree. Exports ride `.fileExporter` (the SettingsView precedent):
// vector PDF via `ScorePDF.makePDF`, type-0 SMF via `SMFWriter.write` (raw unquantized events).
struct StudioScoreView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentEngine.self) private var instruments
    @Environment(InstrumentPackStore.self) private var packs

    /// Looked up live from the store (not a snapshot) so a rename elsewhere reflects here.
    let takeId: String

    @State private var showPDFExporter = false
    @State private var showMIDIExporter = false
    @State private var showAudioExporter = false
    @State private var pdfDoc = ScorePDFFile(data: Data())
    @State private var midiDoc = ScoreMIDIFile(data: Data())
    @State private var audioDoc = ScoreAudioFile(data: Data())
    /// Rendering the instrumental's events → audio for export (async offline render) — drives the
    /// Audio button's spinner + disables a second tap mid-render.
    @State private var exportingAudio = false
    @State private var errorText: String?

    /// Edit mode (spec §7) — toggled by the action bar, passed to EVERY staff's ScoreEditorView
    /// (one Edit/Done/Cancel bar governs all sections).
    @State private var editing = false
    /// Each staff's `editedEvents` captured when an edit session BEGINS, keyed by staff id
    /// ("" = the primary staff), so Cancel can restore every staff. A nil VALUE = that staff was
    /// deriving-from-raw at session start (Cancel must revert to nil, not pin a snapshot — the
    /// editedEvents==nil derive-from-raw contract).
    @State private var preEditEdited: [String: [StudioNoteEvent]?] = [:]
    /// OVERDUB mode is armed by THIS screen (view-side flag beside the engine's global
    /// `overdubActive`, so the live score's overdub can never be mistaken for ours). While on,
    /// played notes (hand keys, MIDI, or the arp's Play) record a NEW staff from the chosen
    /// position while the existing staffs play back mixed.
    @State private var overdubbing = false

    private var take: StudioTake? { studio.take(takeId) }

    /// TEST SEAM (the `PDJ_USE_FIXTURE` launch-environment convention): pin the score's playhead
    /// to a fixed score-clock ms so the cursor + played/current highlighting can be driven — and
    /// screenshotted — deterministically, without downloading a 32 MB instrument bank to make
    /// Replay audible. Unset in normal use, where the clock is the engine's real replay position.
    private static let pinnedPlayheadMs: Int? =
        ProcessInfo.processInfo.environment["PDJ_SCORE_PLAYHEAD_MS"].flatMap(Int.init)

    var body: some View {
        Group {
            if let take {
                content(take)
            } else {
                // The take was deleted while this screen was on the stack — degrade, never crash.
                ContentUnavailableView("Instrumental not found", systemImage: "questionmark.square.dashed",
                                       description: Text("This instrumental was deleted."))
            }
        }
        .background(Theme.bg)
        .navigationTitle(take.map { $0.name.isEmpty ? "Score" : $0.name } ?? "Score")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Filename: "<take name>.pdf"/".mid". The exporter appends the content type's
        // extension when missing, so the base name is passed bare for PDF; MIDI passes
        // ".mid" explicitly (a registered extension for public.midi-audio) per spec.
        .fileExporter(isPresented: $showPDFExporter, document: pdfDoc, contentType: .pdf,
                      defaultFilename: exportBaseName) { _ in }
        .fileExporter(isPresented: $showMIDIExporter, document: midiDoc,
                      contentType: ScoreMIDIFile.midiType,
                      defaultFilename: exportBaseName + ".mid") { _ in }
        .fileExporter(isPresented: $showAudioExporter, document: audioDoc,
                      contentType: ScoreAudioFile.audioType,
                      defaultFilename: exportBaseName + ".m4a") { _ in }
        .alert("Score", isPresented: Binding(get: { errorText != nil },
                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        // The engine has ONE replay clock, so a PARKED position belongs to whatever was replayed
        // last — possibly another take. Restore THIS take's own remembered cursor (nil ⇒ nothing
        // played, which is what a different take's score shows), so a score resumes where it was
        // left instead of starting over. A replay already RUNNING is left alone (`parkReplayPosition`
        // is a no-op mid-replay) and keeps its own clock — this screen then falls back to its
        // take's stored mark (see `content`) rather than borrowing the other take's cursor.
        .onAppear { cursor.restore() }
        // A replay that ENDS (or is stopped) freezes the cursor where it stopped — remember that,
        // so quitting from a finished replay still resumes there next launch. If the replay that
        // just ended was ANOTHER instrumental's (started from the takes list, then navigated here),
        // there is nothing of ours to remember: take the freed clock and put OUR cursor back on it.
        .onChange(of: instruments.isReplaying) { _, replaying in
            // The overdub pass ends WITH its backing playback (file the staff first, so the
            // cursor bookkeeping below sees the finished state).
            if !replaying, overdubbing, let take { finishOverdub(take) }
            if !replaying, persistsCursor { cursor.replayEnded() }
        }
        .onDisappear {
            // Leaving the screen never abandons an armed overdub (the capture files or drops
            // by the same empty-capture rule as an explicit End).
            if overdubbing, let take { finishOverdub(take) }
            cursor.leave(remembering: persistsCursor)
        }
    }

    // MARK: Cursor persistence + tap-to-seek

    /// This screen's cursor lifecycle (restore / remember / leave) — the take-owner gating lives
    /// there, unit-tested, rather than in the view.
    private var cursor: ScoreCursorSession {
        ScoreCursorSession(takeId: takeId, instruments: instruments, studio: studio)
    }

    /// The pinned test seam drives a FAKE playhead; it must never write itself into the user's
    /// remembered positions. Nor should a take that was DELETED while its score was open leave a
    /// mark behind (`deleteTake` already dropped it).
    private var persistsCursor: Bool { Self.pinnedPlayheadMs == nil && take != nil }

    /// A tap on the score moved the cursor to `ms` (score clock, 0 = beat 1).
    ///
    /// While THIS take is REPLAYING the tap seeks the SOUND too — the Demuxer score's bar-chip
    /// precedent: a tap on the music moves the music, and the cursor follows because it reads the
    /// replay's own clock. Otherwise it parks the cursor, which is also where the next Replay
    /// starts (`StudioTakeReplay.resumeMs`), so tapping and then playing does what it looks like.
    /// (Another take's replay is never hijacked: the park is refused mid-replay, and the stored
    /// mark this screen falls back to still moves under the tap.)
    private func seek(_ take: StudioTake, toMs ms: Int) {
        let target = max(0, min(ms, InstrumentEngine.maxReplayMs))
        if overdubbing {
            // While an overdub is armed and NOTHING is captured yet, a tap RE-ANCHORS the pass
            // (stop the backing, re-arm at the new position). Once notes exist the anchor is
            // fixed — re-basing captured notes would corrupt them — so the tap is ignored.
            guard instruments.overdubCapturedCount == 0 else { return }
            _ = instruments.stopOverdub()
            if instruments.isReplaying { instruments.stopReplay() }
            overdubbing = false
            instruments.parkReplayPosition(atMs: target, forTake: takeId)
            if persistsCursor { studio.setScoreCursorMs(target, forTake: takeId) }
            beginOverdub(take)
            return
        }
        if instruments.isReplaying, instruments.replayClockBelongs(to: takeId) {
            // Re-seek the RUNNING sound: multi-staff replays re-seek polyphonically (all staffs
            // mixed), single-staff exactly as before.
            if let staffs = polyStaffs(take),
               let bank = StudioTakeReplay.polyphonicBankURL(take: take, packs: packs) {
                instruments.replayTakePolyphonic(staffs: staffs, bankURL: bank,
                                                 fromMs: target, forTake: takeId)
            } else {
                instruments.replayTake(events: take.scoreEvents, instrument: take.instrument,
                                       fromMs: target, forTake: takeId)
            }
        } else {
            instruments.parkReplayPosition(atMs: target, forTake: takeId)
        }
        if persistsCursor { studio.setScoreCursorMs(target, forTake: takeId) }
    }

    /// The take's non-empty staffs as the polyphonic replay wants them — nil for a legacy
    /// single-staff take (callers fall back to the sampler path).
    private func polyStaffs(_ take: StudioTake)
        -> [(events: [StudioNoteEvent], instrument: InstrumentKey)]? {
        guard let extras = take.extraStaffs, !extras.isEmpty else { return nil }
        var staffs: [(events: [StudioNoteEvent], instrument: InstrumentKey)] = []
        if !take.scoreEvents.isEmpty { staffs.append((take.scoreEvents, take.instrument)) }
        for st in extras where !st.scoreEvents.isEmpty { staffs.append((st.scoreEvents, st.instrument)) }
        return staffs.isEmpty ? nil : staffs
    }

    // MARK: Content

    private func content(_ take: StudioTake) -> some View {
        // Resolve the environment ONCE and capture the ENGINE + STORE (classes), not this view
        // struct, so the playhead closure below stays a plain object call with no Observation
        // dependency (both properties it touches are `@ObservationIgnored`).
        let engine = instruments, store = studio, id = takeId
        // ONE clock instance shared by every staff section — events are absolute on one score
        // clock, so the playhead paints correctly in each section with zero layout changes.
        let clock = ScorePlaybackClock(
            // THIS take's clock, or — when the engine's one clock is busy with another
            // instrumental's replay — this take's own stored mark. Never the other take's
            // moving position.
            positionMs: {
                Self.pinnedPlayheadMs ?? engine.replayPositionMs(forTake: id)
                    ?? store.scoreCursorMs(id)
            },
            seek: { seek(take, toMs: $0) })
        return ScrollView {
            VStack(spacing: 14) {
                actionBar(take)
                overdubRow(take)
                // The shared editable surface — a take commits edits as `editedEvents`. `playback`
                // adds the score cursor + played-behind + current/last-played highlighting that
                // follow Replay; the closure reads the engine's NON-observable replay clock, so
                // the ~10 Hz playhead tick never re-runs this body (quantize + paginate).
                ScoreEditorView(events: take.scoreEvents, bpm: take.bpm, instrument: take.instrument,
                                title: primaryStaffTitle(take), editing: editing,
                                onEdit: { studio.setTakeEvents(takeId, events: $0) },
                                playback: clock)
                // Overdub staffs 2…4 — the SAME editor surface, one section per staff, all on
                // the one clock (per-staff edits commit through the staff-scoped store APIs).
                ForEach(Array((take.extraStaffs ?? []).enumerated()), id: \.element.id) { i, staff in
                    staffHeader(take, staff: staff, index: i)
                    ScoreEditorView(events: staff.scoreEvents, bpm: take.bpm,
                                    instrument: staff.instrument,
                                    title: "Staff \(i + 2) · \(staff.instrument.displayName)",
                                    editing: editing,
                                    onEdit: { studio.setStaffEvents(takeId, staffId: staff.id, events: $0) },
                                    playback: clock)
                }
                Text("\(take.instrument.displayName) · \(Fmt.bpm(take.bpm)) BPM")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            .padding()
            .frame(maxWidth: 700)     // a readable sheet width on iPad/macOS; full width on iPhone
            .frame(maxWidth: .infinity)
        }
    }

    /// Staff 1's section title: the take name alone for a legacy single-staff take (today's
    /// exact header), numbered once overdub staffs exist.
    private func primaryStaffTitle(_ take: StudioTake) -> String {
        let extras = take.extraStaffs ?? []
        return extras.isEmpty ? displayTitle(take)
                              : "\(displayTitle(take)) · Staff 1 · \(take.instrument.displayName)"
    }

    /// Per-staff header row (staffs 2…4): instrument picker + delete. Staff 1 keeps the take's
    /// existing instrument affordances (Instrumentals list / take menu).
    private func staffHeader(_ take: StudioTake, staff: StudioTakeStaff, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("Staff \(index + 2)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
            Menu {
                ForEach(InstrumentKey.allCases, id: \.rawValue) { key in
                    Button {
                        studio.setStaffInstrument(takeId, staffId: staff.id, key)
                    } label: {
                        if key == staff.instrument {
                            Label(key.displayName, systemImage: "checkmark")
                        } else {
                            Text(key.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(staff.instrument.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .disabled(overdubbing)
            .accessibilityIdentifier("staff-instrument-\(index)")
            Spacer(minLength: 0)
            Button(role: .destructive) {
                studio.deleteStaff(takeId, staffId: staff.id)
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless).tint(Theme.danger)
            .disabled(overdubbing || editing)
            .accessibilityIdentifier("staff-delete-\(index)")
        }
    }

    /// Replay + exports, IN CONTENT (iPhone-portrait toolbar-overflow lesson — an export
    /// hidden behind "•••" is an export nobody finds).
    /// Edit / Done toggle + (while editing) Cancel. Extracted so `actionBar`'s HStack stays
    /// simple enough for SwiftUI's ViewBuilder type-checker.
    @ViewBuilder private func editButtons(_ take: StudioTake) -> some View {
        Button {
            if !editing {
                // Snapshot EVERY staff's edit state for Cancel ("" = the primary staff).
                preEditEdited = ["": take.editedEvents]
                for staff in take.extraStaffs ?? [] { preEditEdited[staff.id] = staff.editedEvents }
            }
            editing.toggle()
        } label: {
            Label(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil")
        }
        .buttonStyle(.bordered)
        .tint(editing ? Theme.accent2 : Theme.accent)
        .disabled(!editing && overdubbing)
        .accessibilityIdentifier("score-edit")
        if editing {
            Button(role: .cancel) {
                // Discard this edit session: restore each staff's pre-edit stream. A staff that
                // was deriving-from-raw (editedEvents == nil) must go back to nil via the revert
                // API, NOT be pinned to a snapshot — otherwise its quantization freezes forever
                // (the editedEvents==nil derive-from-raw contract). A staff overdubbed mid-
                // session has no snapshot entry and reverts to raw the same way.
                switch preEditEdited[""] {
                case .some(.some(let snap)): studio.setTakeEvents(takeId, events: snap)
                default: studio.revertTakeEdits(takeId)
                }
                for staff in take.extraStaffs ?? [] {
                    switch preEditEdited[staff.id] {
                    case .some(.some(let snap)):
                        studio.setStaffEvents(takeId, staffId: staff.id, events: snap)
                    default:
                        studio.revertStaffEdits(takeId, staffId: staff.id)
                    }
                }
                editing = false
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(Theme.fgDim)
            .accessibilityIdentifier("score-cancel")
        }
    }

    private func actionBar(_ take: StudioTake) -> some View {
        // THIS take's transport state — not "something is replaying". With another instrumental's
        // replay running (started from the takes list) this button still reads ▶ Replay and starts
        // ours, instead of reading Stop and silently killing a take that isn't on screen.
        let ours = instruments.isReplaying && instruments.replayClockBelongs(to: takeId)
        return HStack(spacing: 10) {
            Button {
                // Resume from where the cursor sits (a tap-to-seek, or the position this score was
                // left at) — from the top once the take has played through. See `resumeMs`. The
                // stored mark is the fallback for the case above, where the live clock is not ours.
                let parked = instruments.replayPositionMs(forTake: takeId) ?? studio.scoreCursorMs(takeId)
                // Resume against EVERY staff's events — an overdub past the primary's end must
                // still count as "not played through".
                let from = StudioTakeReplay.resumeMs(parkedMs: parked, events: take.allScoreEvents)
                // Free the sampler from a foreign replay first, so `toggle` starts ours rather than
                // just stopping theirs.
                if instruments.isReplaying, !ours { instruments.stopReplay() }
                if !StudioTakeReplay.toggle(take: take, instruments: instruments, packs: packs,
                                            fromMs: from) {
                    errorText = "Download the \(take.instrument.displayName) pack to hear this take."
                }
            } label: {
                Label(ours ? "Stop" : "Replay", systemImage: ours ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(ours ? Theme.danger : Theme.accent)
            .disabled(take.allScoreEvents.isEmpty || overdubbing)
            .accessibilityIdentifier("score-replay")
            editButtons(take)
            Spacer(minLength: 0)
            Button { exportAudio(take) } label: {
                if exportingAudio {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Audio", systemImage: "waveform")
                }
            }
            .disabled(exportingAudio || take.allScoreEvents.isEmpty)
            .accessibilityIdentifier("score-export-audio")
            Button { exportPDF(take) } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            .accessibilityIdentifier("score-export-pdf")
            Button { exportMIDI(take) } label: {
                Label("MIDI", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("score-export-midi")
        }
    }

    // MARK: Overdub (record a NEW staff from a chosen position — hand keys, MIDI, or the arp)

    /// The overdub bar: mode toggle + staff count + status caption. IN CONTENT beneath the
    /// action bar (the iPhone-portrait toolbar-overflow lesson — and the action bar is full).
    @ViewBuilder private func overdubRow(_ take: StudioTake) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if overdubbing { finishOverdub(take) } else { beginOverdub(take) }
                } label: {
                    Label(overdubbing ? "End overdub" : overdubLabel,
                          systemImage: overdubbing ? "stop.circle" : "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                .tint(overdubbing ? Theme.danger : Theme.accent2)
                .disabled(!overdubbing
                          && (editing || instruments.currentInstrument == nil
                              || take.staffCount >= StudioTake.maxStaffs))
                .accessibilityIdentifier("score-overdub")
                Spacer(minLength: 0)
                Text("\(take.staffCount)/\(StudioTake.maxStaffs) staffs")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("score-staff-count")
            }
            Text(overdubCaption(take))
                .font(.caption2)
                .foregroundStyle(overdubbing ? Theme.accent2 : Theme.fgDim)
        }
    }

    /// The idle button names the recording voice — the new staff plays through the CURRENTLY
    /// loaded instrument, which is pickable on the Instrument tab, not here.
    private var overdubLabel: String {
        instruments.currentInstrument.map { "Overdub · \($0.displayName)" } ?? "Overdub"
    }

    private func overdubCaption(_ take: StudioTake) -> String {
        if overdubbing {
            let at = Self.mmss(instruments.overdubBaseMs)
            return "Overdubbing staff \(take.staffCount + 1) from \(at) — play the keys, a MIDI "
                + "keyboard, or the arp's Play; it ends with the backing playback."
        }
        if take.staffCount >= StudioTake.maxStaffs {
            return "4 staffs — the maximum for one instrumental."
        }
        if instruments.currentInstrument == nil {
            return "Load an instrument on the Instrument tab to overdub a new staff."
        }
        return "Tap a position on the score, then Overdub to record a new staff from there."
    }

    private static func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Arm the overdub at the parked cursor (the position the user tapped — nothing tapped ⇒
    /// the top) and start the EXISTING staffs playing back mixed from there, through the
    /// multitimbral synth so the SAMPLER stays free as the user's overdub voice. The overdub
    /// log anchors at the same instant the backing anchors its clock, so played notes land at
    /// the true score position.
    private func beginOverdub(_ take: StudioTake) {
        guard instruments.currentInstrument != nil else {
            errorText = "Load an instrument on the Instrument tab first — the overdub records through it."
            return
        }
        guard take.staffCount < StudioTake.maxStaffs else { return }
        if instruments.isReplaying { instruments.stopReplay() }
        let parked = instruments.replayPositionMs(forTake: takeId) ?? studio.scoreCursorMs(takeId)
        let p = max(0, min(parked ?? 0, InstrumentEngine.maxReplayMs))
        guard instruments.startOverdub(fromMs: p, anchorHostTime: mach_absolute_time()) else { return }
        overdubbing = true
        // Backing: every non-empty staff, mixed. A missing bank degrades to a silent backing
        // (the overdub still records) rather than blocking the pass — same shared font today,
        // so this is a nearly-impossible path, surfaced honestly when it happens.
        var staffs: [(events: [StudioNoteEvent], instrument: InstrumentKey)] = []
        if !take.scoreEvents.isEmpty { staffs.append((take.scoreEvents, take.instrument)) }
        for st in take.extraStaffs ?? [] where !st.scoreEvents.isEmpty {
            staffs.append((st.scoreEvents, st.instrument))
        }
        guard !staffs.isEmpty else { return }
        guard let bank = StudioTakeReplay.polyphonicBankURL(take: take, packs: packs) else {
            errorText = "Download the instrument packs to hear the backing — overdubbing without it."
            return
        }
        instruments.replayTakePolyphonic(staffs: staffs, bankURL: bank, fromMs: p,
                                         forTake: takeId, forceSynth: true)
    }

    /// End the overdub pass: file the capture as a new staff through the store (empty capture ⇒
    /// no staff — no junk), and stop the backing if it is still ours.
    private func finishOverdub(_ take: StudioTake) {
        guard overdubbing else { return }
        overdubbing = false
        let events = instruments.stopOverdub()
        if instruments.isReplaying, instruments.replayClockBelongs(to: takeId) {
            instruments.stopReplay()
        }
        guard !events.isEmpty else { return }
        let inst = instruments.currentInstrument ?? .piano
        if studio.addOverdubStaff(takeId, instrument: inst, events: events) == nil {
            // The cap raced (another screen added a staff mid-pass) — surface it, drop nothing
            // silently is impossible here (the capture is gone either way, so say so).
            errorText = "Couldn't add the overdub — this instrumental already has \(StudioTake.maxStaffs) staffs."
        }
    }

    // MARK: Exports

    private func exportPDF(_ take: StudioTake) {
        let doc = ScoreQuantizer.quantize(events: take.scoreEvents, bpm: take.bpm,
                                          instrument: take.instrument)
        let data = ScorePDF.makePDF(score: doc, title: displayTitle(take),
                                    instrument: take.instrument)
        guard !data.isEmpty else {
            errorText = "Couldn't build the PDF."
            return
        }
        pdfDoc = ScorePDFFile(data: data)
        showPDFExporter = true
    }

    private func exportMIDI(_ take: StudioTake) {
        // Deliberately the RAW/effective events (spec §7): the score's readable simplification is
        // the PDF; MIDI is the faithful stream a DAW ingests.
        midiDoc = ScoreMIDIFile(data: SMFWriter.write(events: take.scoreEvents, bpm: take.bpm,
                                                      instrument: take.instrument))
        showMIDIExporter = true
    }

    /// Render the instrumental's events → a real `.m4a` and hand the bytes to `.fileExporter`. The
    /// render synthesizes the take's notes through its own instrument (the same audio Replay
    /// plays) — so the export is audible even for a live-saved take whose stored file is a silent
    /// placeholder. Needs the instrument pack downloaded (the bank the render loads).
    private func exportAudio(_ take: StudioTake) {
        guard !exportingAudio else { return }
        guard !take.allScoreEvents.isEmpty else {
            errorText = "This instrumental has no notes to render."
            return
        }
        guard let bankURL = packs.localBankURL(forInstrument: take.instrument) else {
            errorText = "Download the \(take.instrument.displayName) pack to export this instrumental's audio."
            return
        }
        // Multi-staff: render EVERY staff and mix (the StudioTakeRenderer routing) — refused
        // when any staff's pack is missing, so a part is never silently dropped.
        var staffs: [(events: [StudioNoteEvent], program: UInt8, bankURL: URL)] =
            [(take.scoreEvents, take.instrument.gmProgram, bankURL)]
        for staff in take.extraStaffs ?? [] where !staff.scoreEvents.isEmpty {
            guard let staffBank = packs.localBankURL(forInstrument: staff.instrument) else {
                errorText = "Download the \(staff.instrument.displayName) pack to export this instrumental's audio."
                return
            }
            staffs.append((staff.scoreEvents, staff.instrument.gmProgram, staffBank))
        }
        let events = take.scoreEvents
        let program = take.instrument.gmProgram
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("instrumental-\(UUID().uuidString).m4a")
        exportingAudio = true
        Task {
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                if staffs.count > 1 {
                    _ = try await StudioRender.shared.renderTakePolyphonic(staffs: staffs, to: tmp)
                } else {
                    _ = try await StudioRender.shared.renderTake(events: events, bankURL: bankURL,
                                                                 program: program, to: tmp)
                }
                let data = try Data(contentsOf: tmp)
                audioDoc = ScoreAudioFile(data: data)
                exportingAudio = false
                showAudioExporter = true
            } catch {
                exportingAudio = false
                errorText = "Couldn't render this instrumental's audio. Try again, or re-download the \(take.instrument.displayName) pack."
            }
        }
    }

    private func displayTitle(_ take: StudioTake) -> String {
        take.name.isEmpty ? "Untitled instrumental" : take.name
    }

    /// Export base name: the instrumental's name with filesystem-hostile separators stripped.
    private var exportBaseName: String {
        let raw = take.map(displayTitle) ?? "Instrumental"
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Instrumental" : cleaned
    }
}


// MARK: - Cursor lifecycle (extracted from the view so the rules are unit-tested)

/// The score screen's half of the cursor contract, extracted from the view so the rules are
/// UNIT-TESTED rather than eyeballed (`ScoreCursorTests`).
///
/// The whole problem it solves: `InstrumentEngine` has exactly ONE replay clock, and a take's
/// score can be open while a DIFFERENT take is replaying (the takes list has a per-row ▶, and the
/// row itself navigates to the score). Every read and every write below is therefore gated on the
/// clock's OWNER. Without that gate the screen would persist another instrumental's position into
/// this take's remembered cursor — which, now that cursors are durable, would follow the user
/// across relaunches instead of evaporating.
@MainActor
struct ScoreCursorSession {
    let takeId: String
    let instruments: InstrumentEngine
    let studio: StudioStore

    /// What this score's cursor should read: this take's live/parked clock, or — while the engine's
    /// clock belongs to another instrumental's replay — this take's own remembered mark. Never the
    /// other take's moving position.
    func positionMs() -> Int? {
        instruments.replayPositionMs(forTake: takeId) ?? studio.scoreCursorMs(takeId)
    }

    /// Opening the score: put this take's remembered cursor back on the engine clock (nil ⇒ nothing
    /// played). Refused mid-replay by the engine, so it can never interrupt a running take.
    func restore() {
        instruments.parkReplayPosition(atMs: studio.scoreCursorMs(takeId), forTake: takeId)
    }

    /// Persist where this take's cursor sits — ONLY if the engine's clock is describing this take.
    /// A foreign position is not ours to store, and a nil never clobbers a good mark.
    func remember() {
        guard let ms = instruments.replayPositionMs(forTake: takeId) else { return }
        studio.setScoreCursorMs(ms, forTake: takeId)
    }

    /// A replay ended (or was stopped). Ours ⇒ remember where it froze. Someone else's ⇒ there is
    /// nothing of ours to remember, so take the freed clock and put OUR cursor back on it.
    func replayEnded() {
        if instruments.replayClockBelongs(to: takeId) { remember() } else { restore() }
    }

    /// Leaving the screen. Only when the clock is ours: another take's replay may be running (its
    /// own row started it and owns its Stop), so its position is not ours to persist, its sound not
    /// ours to cut, its clock not ours to clear.
    ///
    /// `remembering: false` still tears down our replay but writes nothing — the pinned-playhead
    /// test seam and a take deleted out from under the screen.
    func leave(remembering: Bool = true) {
        guard instruments.replayClockBelongs(to: takeId) else { return }
        if remembering { remember() }
        // Leaving the score stops ITS replay (the sampler keeps sounding otherwise, with no visible
        // stop control anywhere — replay is a this-screen affordance).
        if instruments.isReplaying { instruments.stopReplay() }
        instruments.resetReplayPosition(forTake: takeId)
    }
}


// MARK: - FileDocument wrappers (the EditsFile precedent)

/// PDF bytes for `.fileExporter` (score-export-pdf).
struct ScorePDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Standard-MIDI-file bytes for `.fileExporter` (score-export-midi).
struct ScoreMIDIFile: FileDocument {
    /// `public.midi-audio`. `.mid` is one of its registered extensions, so the explicit
    /// "<name>.mid" default filename survives the exporter's type check.
    static let midiType: UTType = .midi
    static var readableContentTypes: [UTType] { [midiType] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Rendered AAC `.m4a` bytes for `.fileExporter` (score-export-audio). `.mpeg4Audio` is
/// `public.mpeg-4-audio`, whose registered extensions include `.m4a`, so the "<name>.m4a"
/// default filename survives the exporter's type check.
struct ScoreAudioFile: FileDocument {
    static let audioType: UTType = .mpeg4Audio
    static var readableContentTypes: [UTType] { [audioType] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
