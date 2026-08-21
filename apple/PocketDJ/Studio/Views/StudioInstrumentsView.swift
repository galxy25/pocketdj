import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Studio ▸ Instruments (spec §1/§7)
//
// The Instruments sub-tab: pick one of the seven virtual instruments (downloading its sound
// pack on demand), play it from the on-screen keys or a wired/USB MIDI keyboard, and record
// takes against a click + count-in. Everything lives IN CONTENT (never toolbar-only — the
// iPhone-portrait overflow lesson): the record bar, the keys, and the pack rows are all plain
// scrollable content capped at the Mix tab's 900 pt column.
//
// The view is a thin seam between three environment stores (spec §4: "the engine records, the
// store persists — the view is the seam between them"):
//   • InstrumentEngine — sound + take capture (published state drives every control here);
//   • InstrumentPackStore — the S3 pack manifest + downloaded-bank ledger;
//   • StudioStore — where a finished take is FILED (`addTake`) after the name prompt.
struct StudioInstrumentsView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentEngine.self) private var instruments
    @Environment(InstrumentPackStore.self) private var packs
    @Environment(SettingsStore.self) private var settings

    /// The take-tempo field's raw text (validated to 40…300 by the engine on start).
    @State private var bpmText = "120"
    /// A finished `stopTake()` result awaiting its name (drives the name alert; nil ⇒ closed).
    /// Held HERE (not re-fetched) because the engine forgets the take the moment it stops —
    /// losing this state would orphan the audio file with no record.
    @State private var pendingTake: InstrumentEngine.TakeResult?
    @State private var takeNameDraft = ""
    /// Transient inline notice (download hints, start-failure reasons). Inline text, not an
    /// alert — these are advisory, and alerts would fight the record flow.
    @State private var notice: String?
    /// The live staff is in edit mode (tap-to-place/select on the free-play score).
    @State private var liveEditing = false
    /// The LIVE score's overdub pass is armed (view-side flag beside the engine's global
    /// `overdubActive`, so a saved-score overdub can never be mistaken for ours).
    @State private var liveOverdubbing = false
    /// Cross-platform Bluetooth-MIDI (I3): the scanner sheet + its CoreBluetooth manager (works on
    /// iPhone, iPad, Mac, and Vision Pro — CoreBluetooth is universal).
    @State private var showBTMIDIPicker = false
    @State private var bleMIDI = BLEMIDIManager()
    @State private var showMIDIImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                instrumentGrid
                recordBar
                arpSection
                // PLAY area: ~200 pt tall keys, horizontally scrollable — the iPhone-portrait
                // contract (2 octaves don't fit a 390 pt screen at playable key widths).
                PianoKeysView()
                    .frame(height: 200)
                liveStaffSection
                takesLink
                midiImportButton
                packsSection
                midiSection
            }
            .padding()
            .frame(maxWidth: 900)               // Mix-tab content-column precedent
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        // The BACKING's natural end still doesn't end the pass — what ends a non-looping pass is
        // the REGION running out, which the engine publishes separately (`overdubReachedEnd`,
        // below): a backing that merely stopped early (bank missing, a staff shorter than the
        // score) must not truncate the take. Otherwise the pass ends explicitly — End overdub, a
        // re-anchoring tap, Clear, Save — and navigating away never leaves the engine armed with
        // no UI owning it.
        .onDisappear { if liveOverdubbing { finishLiveOverdub() } }
        // Loop OFF: the pass is confined to [anchor → the score's end] and stops accepting notes
        // there. The engine publishes that instant; the pass finalizes cleanly right here (held
        // notes were already closed AT the boundary by the capture).
        .onChange(of: instruments.overdubReachedEnd) { _, ended in
            if ended, liveOverdubbing { finishLiveOverdub() }
        }
        .task {
            // Push the live settings into the store (the MixRecorder "views push settings in"
            // pattern — idempotent, no app-init wiring required for bookmark lookups), then
            // refresh the pack index (offline-first: the cached copy already listed instantly).
            studio.settings = settings
            syncArpSettings()
            await packs.refreshIndex()
        }
        // Name-the-take prompt. EVERY dismissal path files the take (Save with the draft,
        // Cancel/outside with the default name) — a recorded take is data and is never
        // silently dropped (the MixRecorder auto-file doctrine).
        .alert("Name this instrumental", isPresented: Binding(
            get: { pendingTake != nil },
            set: { if !$0 { fileTakeIfPending(named: nil) } })) {
            TextField("Name", text: $takeNameDraft)
                .accessibilityIdentifier("take-name-field")
            Button("Save") { fileTakeIfPending(named: takeNameDraft) }
                .accessibilityIdentifier("take-name-save")
            Button("Cancel", role: .cancel) { fileTakeIfPending(named: nil) }
        } message: {
            Text("The instrumental is kept either way — Cancel just uses the default name.")
        }
    }

    // MARK: Instrument grid (7 chips — spec §1)

    private var instrumentGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Instruments").font(.headline).foregroundStyle(Theme.fg)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(InstrumentKey.allCases, id: \.rawValue) { key in
                    instrumentChip(key)
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(Theme.accent2)
            }
        }
    }

    /// One instrument chip. Tapping routes on pack state (the spec'd selection ladder):
    /// no manifest → hint; not downloaded → START the download (the CTA — the chip shows
    /// live progress); downloaded → load the bank into the sampler (off-main parse, spinner).
    private func instrumentChip(_ key: InstrumentKey) -> some View {
        let pack = packs.packs.first { $0.instrument == key }
        let downloaded = pack.map { packs.isDownloaded($0) } ?? false
        let progress = pack.flatMap { packs.progress(for: $0) }
        let selected = instruments.currentInstrument == key
        return Button { select(key, pack: pack, downloaded: downloaded) } label: {
            VStack(spacing: 4) {
                Image(systemName: Self.icon(for: key))
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.bg : Theme.accent)
                Text(key.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Theme.bg : Theme.fg)
                    .lineLimit(1).minimumScaleFactor(0.7)
                chipStatus(selected: selected, downloaded: downloaded, progress: progress)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(selected ? Theme.accent : Theme.bgRaised))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(instruments.isRecordingTake)   // switching banks mid-take is nonsense (engine guards too)
        .accessibilityIdentifier("instrument-\(key.rawValue)")
    }

    /// The chip's one-line status: Loaded / spinner / download progress / "Get · size".
    @ViewBuilder
    private func chipStatus(selected: Bool, downloaded: Bool, progress: Double?) -> some View {
        if selected {
            if instruments.isLoadingInstrument {
                ProgressView().controlSize(.mini)
            } else {
                Text("Loaded").font(.caption2).foregroundStyle(Theme.bg.opacity(0.8))
            }
        } else if let progress {
            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.accent2)
        } else if downloaded {
            Text("Ready").font(.caption2).foregroundStyle(Theme.fgDim)
        } else {
            // No per-chip size — the download is one shared bank, sized once in the Sound packs
            // row below; advertising 31 MB on every chip implied seven separate downloads.
            Text("Get").font(.caption2).foregroundStyle(Theme.accent2)
        }
    }

    private func select(_ key: InstrumentKey, pack: InstrumentPack?, downloaded: Bool) {
        notice = nil
        guard !instruments.isLoadingInstrument else { return }   // one 32 MB parse at a time
        guard let pack else {
            notice = "Sound packs haven't loaded yet — see the Sound packs section below."
            return
        }
        guard downloaded else {
            // The download CTA: first tap starts the shared sound-bank download (progress shows
            // on the chip AND the bank row — same `progressByBank` entry); tap again once ready.
            // Say "sound bank … all instruments" so it's clear this one download enables every
            // instrument, not just this chip.
            packs.download(pack)
            notice = "Downloading the sound bank (enables all instruments) — tap again when it's ready."
            return
        }
        guard let url = packs.localBankURL(pack) else {
            notice = "Couldn't find the downloaded sound bank — try re-downloading the pack."
            return
        }
        Task { @MainActor in
            let ok = await instruments.loadInstrument(key, bankURL: url)
            if !ok { notice = "Couldn't load \(key.displayName) — try re-downloading its pack." }
        }
    }

    // MARK: Record bar (bpm · click · count-in · record — spec §4)

    private var recordBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record an instrumental").font(.headline).foregroundStyle(Theme.fg)
            HStack(spacing: 10) {
                TextField("BPM", text: $bpmText)
                    .pocketField()
                    .frame(width: 64)
                    .numericKeyboard()
                    .disabled(instruments.isRecordingTake)   // the tempo is locked in at start
                    .accessibilityIdentifier("take-bpm")
                // Click + count-in bind straight to SettingsStore and persist IMMEDIATELY —
                // a toggle is a deliberate preference, and no later persist() is guaranteed
                // to run before quit (the SessionFolders stale-bookmark lesson).
                // The click is flippable LIVE: mid-take it starts/stops on the NEXT BEAT of the
                // take's own grid — the take keeps rolling, the graph isn't reconfigured, and
                // (the click joining downstream of the take tap) nothing is written anywhere.
                Toggle("Click", isOn: Binding(
                    get: { settings.studioClickEnabled },
                    set: { on in
                        settings.studioClickEnabled = on
                        settings.persist()
                        if instruments.isRecordingTake { instruments.setClickEnabled(on) }
                    }))
                    .toggleStyle(.button)
                    .accessibilityIdentifier("take-click-toggle")
                Toggle("Count-in", isOn: settingBinding(\.studioCountInEnabled))
                    .toggleStyle(.button)
                    .accessibilityIdentifier("take-countin-toggle")
                Spacer(minLength: 0)
                recordButton
            }
            recordStatus
            if instruments.currentInstrument == nil && !instruments.isLoadingInstrument {
                Text("Pick an instrument above to enable recording.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
    }

    private var recordButton: some View {
        Button {
            if instruments.isRecordingTake {
                finishTake()
            } else {
                // Comma-decimal locales type "120,5"; the engine clamps range itself.
                let bpm = Double(bpmText.replacingOccurrences(of: ",", with: ".")) ?? 120
                if !instruments.startTake(bpm: bpm,
                                          click: settings.studioClickEnabled,
                                          countIn: settings.studioCountInEnabled) {
                    notice = "Couldn't start recording — load an instrument first."
                }
            }
        } label: {
            Label(instruments.isRecordingTake ? "Stop" : "Record",
                  systemImage: instruments.isRecordingTake ? "stop.fill" : "record.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(instruments.isRecordingTake ? Theme.danger : Theme.accent)
        .disabled(!instruments.isRecordingTake
                  && (instruments.currentInstrument == nil || instruments.isLoadingInstrument))
        .accessibilityIdentifier("take-record")
    }

    /// Count-in indicator + the take's CONTENT clock. The clock is sampled from a TimelineView
    /// — `takeContentSeconds` is deliberately NOT observable (fast clocks must never drive
    /// Observation invalidation; the engine's own dead-play/pause-button lesson).
    @ViewBuilder
    private var recordStatus: some View {
        if instruments.isRecordingTake {
            HStack(spacing: 8) {
                if instruments.isCountingIn {
                    Label("Count-in…", systemImage: "metronome")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent2)
                } else {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(Self.clock(instruments.takeContentSeconds))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                    }
                    Text("recording").font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    private func finishTake() {
        // nil = stopped during the count-in (nothing recorded, no file begun) — no prompt.
        guard let result = instruments.stopTake() else { return }
        takeNameDraft = defaultTakeName()
        pendingTake = result
    }

    /// File the pending take exactly once (the alert's Save tap ALSO flips the isPresented
    /// binding false, which re-enters here — the nil-out guard makes that a no-op).
    private func fileTakeIfPending(named name: String?) {
        guard let r = pendingTake else { return }
        pendingTake = nil
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        // Relocating filer: the take recorded into app storage; move it into the user's
        // instrumentals folder now if one is configured (Settings ▸ Storage).
        studio.addTakeRelocating(StudioTake(id: r.takeId,
                                            name: trimmed.isEmpty ? defaultTakeName() : trimmed,
                                            instrument: r.instrument,
                                            fileName: r.fileName,
                                            bpm: r.bpm,
                                            events: r.events,
                                            durationMs: r.durationMs,
                                            createdAt: Date().timeIntervalSince1970 * 1000))
    }

    private func defaultTakeName() -> String { "Take \(studio.takes.count + 1)" }

    // MARK: Arpeggiator (record a note set on the keys, play it as a pattern — spec addition)

    /// The arp panel: master toggle, RECORD (keys toggle pattern membership — each sounds once,
    /// stays highlighted, writes NOTHING to any score), PLAY (loops the pattern through the
    /// instrument's own voice), and the knobs (order / length / octaves / swing / latch). Knob
    /// state persists in SettingsStore (every write persists — the click/count-in doctrine) and
    /// mirrors into `InstrumentEngine.arpSettings`; edits land at the next cycle boundary.
    private var arpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Arp", isOn: arpEnabledBinding)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("arp-toggle")
                if instruments.arpEnabled {
                    Toggle("Program", isOn: arpProgramBinding)
                        .toggleStyle(.button)
                        .tint(instruments.arpProgramming ? Theme.danger : nil)
                        .accessibilityIdentifier("arp-program")
                    arpTransportButton
                    Spacer(minLength: 0)
                    Button("Clear") { instruments.arpClearSelection() }
                        .buttonStyle(.bordered).tint(Theme.fgDim)
                        .disabled(instruments.arpSelectedNotes.isEmpty)
                        .accessibilityIdentifier("arp-clear")
                } else {
                    Spacer(minLength: 0)
                }
            }
            if instruments.arpEnabled {
                arpKnobRows
                Text(arpCaption)
                    .font(.caption2).foregroundStyle(instruments.arpProgramming ? Theme.accent2 : Theme.fgDim)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("arp-panel")
    }

    /// The arp TRANSPORT: a dedicated play/pause button governing whether the pattern is
    /// AUDIBLE — including while Program is on, so you hear the pattern evolve as you add and
    /// remove notes (edits land at the next cycle boundary). It reflects reality rather than a
    /// user intent: latch OFF plays exactly one cycle and the engine drops `arpPlaying`, so the
    /// button falls back to ▶ on its own.
    private var arpTransportButton: some View {
        Button {
            if instruments.arpPlaying { instruments.stopArpPlayback() } else { startArp() }
        } label: {
            Label(instruments.arpPlaying ? "Pause" : "Play",
                  systemImage: instruments.arpPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .tint(instruments.arpPlaying ? Theme.accent2 : Theme.accent)
        .disabled(!instruments.arpPlaying
                  && (instruments.arpSelectedNotes.isEmpty
                      || instruments.currentInstrument == nil))
        .accessibilityIdentifier("arp-transport")
    }

    /// The knob rows: order chips, length + octave chips, swing slider + latch. Each chip row
    /// scrolls horizontally (iPhone portrait can’t fit six order chips inline — the keys’ own
    /// scroll precedent), and the swing slider is the width-adaptive `StudioEditSlider` (inline
    /// on regular widths, value-chip → fixed-width popover on iPhone portrait).
    @ViewBuilder private var arpKnobRows: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Order").font(.caption).foregroundStyle(Theme.fgDim)
                ForEach(ArpOrder.allCases, id: \.rawValue) { order in
                    arpChip(Self.orderLabel(order), on: currentArpSettings.order == order,
                            id: "arp-order-\(order.rawValue)") {
                        settings.studioArpOrder = order.rawValue
                        persistArpKnobs()
                    }
                }
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Length").font(.caption).foregroundStyle(Theme.fgDim)
                ForEach(ArpStepLength.allCases, id: \.rawValue) { len in
                    arpChip("1/\(len.rawValue)", on: currentArpSettings.length == len,
                            id: "arp-len-\(len.rawValue)") {
                        settings.studioArpLength = len.rawValue
                        persistArpKnobs()
                    }
                }
                Text("Octaves").font(.caption).foregroundStyle(Theme.fgDim).padding(.leading, 8)
                ForEach(1...4, id: \.self) { oct in
                    arpChip("\(oct)", on: currentArpSettings.octaves == oct,
                            id: "arp-oct-\(oct)") {
                        settings.studioArpOctaves = oct
                        persistArpKnobs()
                    }
                }
            }
        }
        HStack(spacing: 10) {
            StudioEditSlider(title: "Swing", systemImage: "metronome",
                             range: 50...75, step: 1,
                             value: currentArpSettings.swingPct,
                             format: { "\(Int($0.rounded()))%" },
                             a11y: "arp-swing",
                             onChange: {
                                 settings.studioArpSwing = $0
                                 persistArpKnobs()
                             })
            Toggle("Latch", isOn: arpLatchBinding)
                .toggleStyle(.button)
                .accessibilityIdentifier("arp-latch")
        }
    }

    /// The order/length/octave capsule chip (the ScoreEditorView chip idiom).
    private func arpChip(_ text: String, on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 34)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background((on ? Theme.accent : Theme.fgDim).opacity(on ? 0.22 : 0.10), in: Capsule())
                .foregroundStyle(on ? Theme.accent : Theme.fg)
                .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private static func orderLabel(_ order: ArpOrder) -> String {
        switch order {
        case .up: return "Up"
        case .down: return "Down"
        case .exclusive: return "Excl"
        case .inclusive: return "Incl"
        case .order: return "Order"
        case .random: return "Rand"
        }
    }

    /// The knobs as the engine reads them (persisted raw values, clamped/coalesced).
    private var currentArpSettings: ArpSettings {
        ArpSettings.fromPersisted(order: settings.studioArpOrder,
                                  length: settings.studioArpLength,
                                  octaves: settings.studioArpOctaves,
                                  swing: settings.studioArpSwing,
                                  latch: settings.studioArpLatch)
    }

    /// Persist the knob write (every write persists — the record bar’s WHY-comment) and mirror
    /// into the engine so the running pattern picks it up at the next cycle boundary.
    private func persistArpKnobs() {
        settings.persist()
        syncArpSettings()
    }

    private func syncArpSettings() {
        instruments.arpSettings = currentArpSettings
    }

    private var arpEnabledBinding: Binding<Bool> {
        Binding(get: { instruments.arpEnabled },
                set: { on in
                    if on { syncArpSettings() }
                    instruments.arpEnabled = on   // turning off stops play + record, KEEPS the set
                })
    }

    private var arpProgramBinding: Binding<Bool> {
        Binding(get: { instruments.arpProgramming },
                set: { instruments.arpProgramming = $0 })
    }

    /// Start the transport. The record bar’s BPM drives the arp clock (comma-decimal tolerant,
    /// engine-side degradation for wild values — the recordButton parse).
    private func startArp() {
        syncArpSettings()
        let bpm = Double(bpmText.replacingOccurrences(of: ",", with: ".")) ?? 120
        if !instruments.startArpPlayback(bpm: bpm) {
            notice = "Load an instrument and program some arp notes first."
        }
    }

    private var arpLatchBinding: Binding<Bool> {
        Binding(get: { currentArpSettings.latch },
                set: { settings.studioArpLatch = $0; persistArpKnobs() })
    }

    private var arpCaption: String {
        let n = instruments.arpSelectedNotes.count
        if instruments.arpProgramming {
            return "Program: keys toggle notes in the pattern — each sounds once and stays "
                + "highlighted; nothing is written to the score. Play stays live, so you hear "
                + "the pattern change at the next cycle. \(n) selected."
        }
        let latch = currentArpSettings.latch
            ? "Latch loops the pattern until you pause."
            : "Latch off: Play runs exactly one cycle, then pauses itself."
        let capture = "While the arp plays, its notes are written to the score like hand-played "
            + "keys (to the overdub staff during a pass)."
        return n == 0 ? "Turn on Program and press keys to pick the pattern’s notes. " + latch
                      : "\(n) note\(n == 1 ? "" : "s") in the pattern. " + latch + " " + capture
    }

    // MARK: Live editable staff (spec §7 "one editable staff")

    /// The engine’s ONE replay clock is claimed under this sentinel while it describes the LIVE
    /// score (overdub backing / parked tap-cursor) — the take-owner gating idiom, with an id no
    /// `StudioFactory.newTakeId()` ("tk_…") can ever collide with.
    static let liveReplayOwner = "live-score"

    /// The live score: staff 1 fills in as you play (the always-on `InstrumentEngine.liveEvents`);
    /// staffs 2…4 are OVERDUB passes (`liveExtraStaffs`, in-memory like the live staff itself).
    /// Every staff is tap-editable in place — the SAME `ScoreEditorView` a saved take uses.
    /// "Save" files it all as one take; "Clear" resets everything. Free-play has no click, so it
    /// renders at 120 BPM. Tap a position, hit Overdub, and played notes (keys or the arp’s Play)
    /// record a NEW staff from there while the existing staffs play back mixed.
    @ViewBuilder
    private var liveStaffSection: some View {
        // Deliberately the cheap `liveHasEvents` FLAG, never the event array: the engine
        // republishes the live capture ~10×/s while you play (and a latched arp plays at machine
        // speed), and reading the array here would re-quantize + re-paginate every staff in this
        // section on each publish. `LiveStaffView` owns that read, so it invalidates alone.
        let hasLive = instruments.liveHasEvents
        let extras = instruments.liveExtraStaffs
        let hasAny = hasLive || !extras.isEmpty || liveOverdubbing
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Live score", systemImage: "music.quarternote.3")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                Spacer(minLength: 0)
                if hasAny {
                    liveOverdubButton
                    Button { liveEditing.toggle() } label: {
                        Label(liveEditing ? "Done" : "Edit", systemImage: liveEditing ? "checkmark" : "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered).tint(liveEditing ? Theme.accent2 : Theme.accent)
                    .disabled(liveOverdubbing)
                    .accessibilityIdentifier("live-edit")
                    Button { saveLiveAsTake() } label: {
                        Label("Save", systemImage: "square.and.arrow.down").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                    .accessibilityIdentifier("live-save")
                    Button(role: .destructive) { clearLiveScore() } label: {
                        Label("Clear", systemImage: "trash").font(.caption.weight(.semibold)).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered).tint(Theme.danger)
                    .accessibilityIdentifier("live-clear")
                }
            }
            if !hasAny && !liveEditing {
                Text("Play the keys (or a connected MIDI keyboard) — your notes appear here as a "
                     + "score you can edit and save as a take.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            } else {
                LiveStaffView(bpm: 120,
                              instrument: instruments.currentInstrument ?? .piano,
                              title: extras.isEmpty ? "Live" : "Live · Staff 1",
                              editing: liveEditing,
                              playback: livePlaybackClock)
                ForEach(Array(extras.enumerated()), id: \.element.id) { i, staff in
                    liveStaffHeader(staff, index: i)
                    ScoreEditorView(events: staff.events, bpm: 120,
                                    instrument: staff.instrument,
                                    title: "Staff \(i + 2) · \(staff.instrument.displayName)",
                                    editing: liveEditing,
                                    onEdit: { instruments.setLiveExtraStaffEvents(id: staff.id, events: $0) },
                                    playback: livePlaybackClock)
                }
                // The pass IN PROGRESS: the staff fills as you play (engine-published, coalesced
                // at ~30 Hz — never per-note), so you watch the notation appear instead of
                // waiting for End overdub. Not editable until the pass is filed.
                if liveOverdubbing {
                    OverdubProgressStaffView(bpm: 120,
                                             instrument: instruments.currentInstrument ?? .piano,
                                             title: "Staff \(2 + extras.count) · recording…",
                                             playback: livePlaybackClock,
                                             a11y: "live-overdub-staff")
                }
            }
            if hasAny { liveStaffFooter(extras: extras) }
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityIdentifier("live-staff")
    }

    /// One shared clock across every live staff section (events are absolute on one clock, so
    /// the cursor paints correctly in each). Captures the ENGINE (a class), not this view struct
    /// — the saved-score screen’s no-Observation-dependency pattern.
    private var livePlaybackClock: ScorePlaybackClock {
        let engine = instruments
        return ScorePlaybackClock(
            positionMs: { engine.replayPositionMs(forTake: Self.liveReplayOwner) },
            seek: { seekLive(toMs: $0) })
    }

    /// Overdub toggle for the live score (the saved score’s `score-overdub` sibling). Label
    /// carries the recording voice — the new staff plays through the CURRENT instrument.
    private var liveOverdubButton: some View {
        Button {
            if liveOverdubbing { finishLiveOverdub() } else { beginLiveOverdub() }
        } label: {
            Label(liveOverdubbing ? "End overdub" : "Overdub",
                  systemImage: liveOverdubbing ? "stop.circle" : "plus.square.on.square")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(liveOverdubbing ? Theme.danger : Theme.accent2)
        .disabled(!liveOverdubbing
                  && (liveEditing || instruments.currentInstrument == nil
                      || 1 + instruments.liveExtraStaffs.count >= StudioTake.maxStaffs))
        .accessibilityIdentifier("live-overdub")
    }

    /// Per-staff header for a live overdub staff: instrument picker + delete (the saved score’s
    /// staff-header idiom, against the engine’s in-memory staffs).
    private func liveStaffHeader(_ staff: InstrumentEngine.LiveStaff, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("Staff \(index + 2)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
            Menu {
                ForEach(InstrumentKey.allCases, id: \.rawValue) { key in
                    Button {
                        instruments.setLiveExtraStaffInstrument(id: staff.id, key)
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
            .accessibilityIdentifier("live-staff-instrument-\(index)")
            Spacer(minLength: 0)
            Button(role: .destructive) {
                instruments.deleteLiveExtraStaff(id: staff.id)
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless).tint(Theme.danger)
            .accessibilityIdentifier("live-staff-delete-\(index)")
        }
    }

    /// Overdub transport options: LOOP the pass over its confined region, and the MONITORING
    /// metronome (flippable live, mid-pass). Both persist like the arp knobs; Loop is fixed for
    /// the duration of a pass because the region + wrap are anchored when the pass arms.
    private var overdubOptionsRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { settings.studioOverdubLoop },
                                 set: { settings.studioOverdubLoop = $0; settings.persist() })) {
                Label("Loop", systemImage: "repeat").font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .tint(settings.studioOverdubLoop ? Theme.accent2 : Theme.fgDim)
            .disabled(liveOverdubbing)
            .accessibilityIdentifier("live-overdub-loop")
            Toggle(isOn: Binding(get: { settings.studioOverdubClickEnabled },
                                 set: { on in
                                     settings.studioOverdubClickEnabled = on
                                     settings.persist()
                                     instruments.setClickEnabled(on, bpm: 120)
                                 })) {
                Label("Click", systemImage: "metronome").font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .tint(instruments.clickEnabled ? Theme.accent2 : Theme.fgDim)
            .accessibilityIdentifier("overdub-click-toggle")
            Spacer(minLength: 0)
        }
    }

    /// How the armed pass will end: looping over its region, auto-finalizing at the score's end,
    /// or (an EMPTY score — no region to confine to) only when the user says so.
    private var liveOverdubEndingCaption: String {
        guard instruments.overdubRegionEndMs < .max else { return "Tap End overdub to finish." }
        let end = Self.clock(Double(instruments.overdubRegionEndMs) / 1000)
        return instruments.overdubLoop
            ? "Looping to \(end) — keep layering; End overdub finishes."
            : "The pass ends by itself at \(end), or tap End overdub."
    }

    /// Status line under the live staffs: overdub-armed notice, or the staff-cap message.
    @ViewBuilder private func liveStaffFooter(extras: [InstrumentEngine.LiveStaff]) -> some View {
        overdubOptionsRow
        if instruments.liveCaptureFull {
            // The capture stopped growing rather than growing without bound (a latched arp is a
            // machine) — said out loud, because the keys still sound.
            Text("Live score is full (\(InstrumentEventLog.maxLiveEvents) notes) — Save or Clear "
                 + "it to keep capturing. The keys still play.")
                .font(.caption2).foregroundStyle(Theme.danger)
                .accessibilityIdentifier("live-capture-full")
        }
        if liveOverdubbing {
            Text("Overdubbing staff \(2 + extras.count) from \(Self.clock(Double(instruments.overdubBaseMs) / 1000))"
                 + " — play the keys (or the arp’s Play). " + liveOverdubEndingCaption)
                .font(.caption2).foregroundStyle(Theme.accent2)
        } else if 1 + extras.count >= StudioTake.maxStaffs {
            Text("4 staffs — the maximum for one instrumental.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        } else {
            Text("Tap a position on the score, then Overdub to record a new staff from there.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    // MARK: Live overdub flow (the saved-score flow’s in-memory twin)

    /// A tap on a live staff parks the cursor (where the next Overdub starts). While an overdub
    /// is armed and NOTHING is captured yet, a tap RE-ANCHORS the pass; once notes exist the
    /// anchor is fixed (re-basing captured notes would corrupt them).
    private func seekLive(toMs ms: Int) {
        let target = max(0, min(ms, InstrumentEngine.maxReplayMs))
        if liveOverdubbing {
            guard instruments.overdubCapturedCount == 0 else { return }
            _ = instruments.stopOverdub()
            if instruments.isReplaying { instruments.stopReplay() }
            liveOverdubbing = false
            instruments.parkReplayPosition(atMs: target, forTake: Self.liveReplayOwner)
            beginLiveOverdub()
            return
        }
        instruments.parkReplayPosition(atMs: target, forTake: Self.liveReplayOwner)
    }

    /// Arm a live overdub pass at the parked cursor and start the existing staffs playing back
    /// MIXED from there — REAL TIME, one `AVAudioUnitSampler` per staff (`replayStaffsLive`),
    /// because a live score has no saved take and therefore no rendered mixdown to play. The live
    /// sampler stays free: it is the user’s overdub voice. The overdub log anchors at the same
    /// instant the backing anchors its clock, so played notes land at the true score position.
    private func beginLiveOverdub() {
        guard instruments.currentInstrument != nil else {
            notice = "Pick an instrument first — the overdub records through it."
            return
        }
        guard 1 + instruments.liveExtraStaffs.count < StudioTake.maxStaffs else { return }
        if instruments.isReplaying { instruments.stopReplay() }
        let p = max(0, instruments.replayPositionMs(forTake: Self.liveReplayOwner) ?? 0)
        // The pass is CONFINED to [anchor → the live score's own end]: an overdub can never make
        // the score longer. An EMPTY score has no end to confine to (`scoreEndMs` = 0), which the
        // engine reads as unbounded — that is "overdub from silence", the first take.
        let end = InstrumentEngine.scoreEndMs(
            staffs: [instruments.liveEvents] + instruments.liveExtraStaffs.map(\.events))
        // At/near the score's END there is no region to record into, and an overdub may never
        // lengthen the score — so say that, instead of arming a pass that finalizes itself on the
        // next tick and looks like a dead button.
        guard InstrumentEngine.hasOverdubRoom(fromMs: p, scoreEndMs: end) else {
            notice = "The cursor is at the end of the live score — an overdub can’t make it "
                + "longer. Tap an earlier position, then Overdub."
            return
        }
        let loop = settings.studioOverdubLoop
        guard instruments.startOverdub(fromMs: p, anchorHostTime: mach_absolute_time(),
                                       scoreEndMs: end > 0 ? end : .max, loop: loop) else { return }
        liveOverdubbing = true
        instruments.setClickEnabled(settings.studioOverdubClickEnabled, bpm: 120)
        var staffs: [(events: [StudioNoteEvent], instrument: InstrumentKey)] = []
        if !instruments.liveEvents.isEmpty {
            staffs.append((instruments.liveEvents, instruments.currentInstrument ?? .piano))
        }
        for st in instruments.liveExtraStaffs where !st.events.isEmpty {
            staffs.append((st.events, st.instrument))
        }
        guard !staffs.isEmpty else { return }   // overdubbing from silence — nothing to back
        guard let bank = StudioTakeReplay.bankURL(forInstruments: staffs.map(\.instrument),
                                                  packs: packs) else {
            notice = "Backing playback needs the sound bank — overdubbing without it."
            return
        }
        // AWAITED and CHECKED — the pool's preset parse takes real time, and a pool that cannot
        // load is a refusal the user must be told about rather than a silent dead Overdub. A
        // refusal also re-anchors the (still empty) capture: it armed at the button press, and
        // measuring a confined region from there would finalize the pass before a note is played.
        let loopRegion: (startMs: Int, endMs: Int)? = instruments.overdubLoop
            ? (startMs: p, endMs: instruments.overdubRegionEndMs) : nil
        Task { @MainActor in
            let started = await instruments.replayStaffsLive(staffs: staffs, bankURL: bank,
                                                             fromMs: p,
                                                             forTake: Self.liveReplayOwner,
                                                             loopRegion: loopRegion)
            guard !started.isAudible else { return }
            instruments.reanchorOverdubIfEmpty()
            guard !started.isCursorPark else { return }
            notice = "Backing playback couldn’t start (\(started.rawValue)) — overdubbing without"
                + " it. Settings ▸ Debug ▸ capture has the reason."
        }
    }

    /// End the live overdub pass: file the capture as a new in-memory staff (empty capture ⇒ no
    /// staff — no junk), and stop the backing if it is still ours.
    private func finishLiveOverdub() {
        guard liveOverdubbing else { return }
        liveOverdubbing = false
        instruments.setClickEnabled(false)
        let events = instruments.stopOverdub()
        if instruments.isReplaying, instruments.replayClockBelongs(to: Self.liveReplayOwner) {
            instruments.stopReplay()
        }
        guard !events.isEmpty else {
            notice = "Overdub ended — nothing was played, so no staff was added."
            return
        }
        if instruments.appendLiveExtraStaff(instrument: instruments.currentInstrument ?? .piano,
                                            events: events) != nil {
            notice = "Overdub added as staff \(1 + instruments.liveExtraStaffs.count)."
        } else {
            notice = "4 staffs is the maximum — the overdub wasn’t added."
        }
    }

    /// Clear EVERYTHING on the live score (staff 1 + overdub staffs), ending an armed overdub
    /// pass without filing it (Clear is the explicit discard).
    private func clearLiveScore() {
        if liveOverdubbing {
            liveOverdubbing = false
            instruments.setClickEnabled(false)
            _ = instruments.stopOverdub()
            if instruments.isReplaying, instruments.replayClockBelongs(to: Self.liveReplayOwner) {
                instruments.stopReplay()
            }
        }
        instruments.clearLiveEvents()
        instruments.clearLiveExtraStaffs()
        liveEditing = false
    }

    /// File the live score as ONE take: staff 1 becomes the take's own events, the overdub
    /// staffs file as `extraStaffs` (each keeping its instrument). Replay plays the EVENTS
    /// (audible via the sampler/synth), so the take is fully playable; the audio file is a
    /// silent placeholder (kept so launch reconcile doesn't prune the record) — the background
    /// render synthesizes the real (polyphonic) audio. Clears every staff.
    private func saveLiveAsTake() {
        if liveOverdubbing { finishLiveOverdub() }   // an armed pass files before the save
        let live = instruments.liveEvents
        let extras = instruments.liveExtraStaffs
        guard !live.isEmpty || !extras.isEmpty, let takesDir = try? StudioFolders.appRoot(.takes) else {
            notice = "Couldn't save — the takes folder isn't reachable."
            return
        }
        let takeId = StudioFactory.newTakeId()
        let fileName = StudioFolders.fileName(.takes, id: takeId)
        let allOffs = live.map(\.offMs) + extras.flatMap { $0.events.map(\.offMs) }
        let dur = max(500, allOffs.max() ?? 500)
        writePlaceholderTakeAudio(to: takesDir.appendingPathComponent(fileName), durationMs: dur)
        let now = Date().timeIntervalSince1970
        let staffs = extras.map { st in
            StudioTakeStaff(id: st.id, instrument: st.instrument, events: st.events, createdAt: now)
        }
        studio.addTakeRelocating(StudioTake(id: takeId, name: defaultTakeName(),
                                            instrument: instruments.currentInstrument ?? .piano,
                                            fileName: fileName, bpm: 120, events: live, durationMs: dur,
                                            createdAt: now * 1000,
                                            extraStaffs: staffs.isEmpty ? nil : staffs))
        // The saved file is a SILENT placeholder — render the real audio in the background so the
        // instrumental is audible wherever it plays (collections / Mix), not just on Replay.
        Task { await StudioTakeRenderer.ensureRendered(takeId: takeId, studio: studio, packs: packs) }
        instruments.clearLiveEvents()
        instruments.clearLiveExtraStaffs()
        liveEditing = false
        notice = "Saved to Takes."
    }

    /// A silent AAC placeholder so the take file exists (reconcile keeps it; replay uses events).
    private func writePlaceholderTakeAudio(to url: URL, durationMs: Int) {
        let sr = 44_100.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                        AVSampleRateKey: sr, AVNumberOfChannelsKey: 1]
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(sr * Double(durationMs) / 1000))
        else { return }
        buf.frameLength = buf.frameCapacity   // fresh buffer = silence
        try? file.write(from: buf)
    }

    // MARK: Takes (pushed list — the layout call: the list + score live one push away)

    private var takesLink: some View {
        NavigationLink {
            StudioTakesView()
        } label: {
            HStack {
                Label("Instrumentals", systemImage: "music.note.list").foregroundStyle(Theme.fg)
                Spacer()
                Text("\(studio.takes.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("takes-open")
    }

    /// Accepted MIDI UTIs (Standard MIDI File — a few spellings across sources).
    private static let midiTypes: [UTType] = [.midi,
                                              UTType(filenameExtension: "mid") ?? .midi,
                                              UTType(filenameExtension: "midi") ?? .midi]

    /// Import a Standard MIDI File as an instrumental take — parsed into notes that play through the
    /// CURRENTLY-SELECTED instrument (switchable afterward from the Instrumentals list). Renders the
    /// real audio in the background like a live-saved take.
    private var midiImportButton: some View {
        Button { showMIDIImporter = true } label: {
            HStack {
                Label("Import MIDI file…", systemImage: "square.and.arrow.down").foregroundStyle(Theme.fg)
                Spacer()
                Text("→ \(instruments.currentInstrument?.displayName ?? InstrumentKey.piano.displayName)")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("midi-import")
        .fileImporter(isPresented: $showMIDIImporter, allowedContentTypes: Self.midiTypes) { result in
            if case .success(let url) = result { handleMIDIImport(url) }
        }
    }

    private func handleMIDIImport(_ url: URL) {
        guard let takesDir = try? StudioFolders.appRoot(.takes) else {
            notice = "Couldn't save — the takes folder isn't reachable."
            return
        }
        do {
            let parsed = try StudioMIDIImport.parse(url: url)
            let takeId = StudioFactory.newTakeId()
            let fileName = StudioFolders.fileName(.takes, id: takeId)
            writePlaceholderTakeAudio(to: takesDir.appendingPathComponent(fileName), durationMs: parsed.durationMs)
            let base = url.deletingPathExtension().lastPathComponent
            let inst = instruments.currentInstrument ?? .piano
            studio.addTakeRelocating(StudioTake(id: takeId, name: base.isEmpty ? defaultTakeName() : base,
                                                instrument: inst, fileName: fileName, bpm: parsed.bpm,
                                                events: parsed.events, durationMs: parsed.durationMs,
                                                createdAt: Date().timeIntervalSince1970 * 1000))
            Task { await StudioTakeRenderer.ensureRendered(takeId: takeId, studio: studio, packs: packs) }
            notice = "Imported “\(base)” — \(parsed.events.count) notes on \(inst.displayName). "
                + "Change its instrument or tempo from Instrumentals."
        } catch {
            notice = (error as? StudioMIDIImport.ImportError)?.errorDescription ?? "Couldn’t read that MIDI file."
        }
    }

    // MARK: Pack management (spec §6)

    private var packsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound packs").font(.headline).foregroundStyle(Theme.fg)
            if packs.packs.isEmpty {
                HStack(spacing: 10) {
                    Text(packs.isRefreshing ? "Loading pack index…"
                                            : "Couldn't load the pack index.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                    if !packs.isRefreshing {
                        Button("Retry") { Task { await packs.refreshIndex() } }
                            .font(.caption)
                            .accessibilityIdentifier("packs-refresh")
                    }
                }
            } else {
                // ONE row per sound BANK, not per instrument. The seven GM instruments are all
                // presets inside a single 32 MB SoundFont, so there is exactly one download —
                // and it enables every instrument at once. Showing seven "Get" buttons made
                // downloading Piano look like it also grabbed everything else; grouping by
                // bankKey makes the single shared download honest (and still degrades correctly
                // if a future manifest gives an instrument its own bank → its own row).
                let groups = bankGroups
                VStack(spacing: 0) {
                    ForEach(groups, id: \.key) { group in
                        bankRow(group)
                        if group.key != groups.last?.key { Divider().overlay(Theme.border) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
            }
            // Attribution from the manifest — the GeneralUser GS license asks for it (spec §6).
            if let attribution = packs.attribution {
                Text(attribution).font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
    }

    /// Packs grouped by the bank they share, preserving manifest order. One entry per distinct
    /// bank file → one download row. In v1 every instrument shares one bank, so this collapses to
    /// a single row covering all seven.
    private var bankGroups: [(key: String, packs: [InstrumentPack])] {
        var order: [String] = []
        var byKey: [String: [InstrumentPack]] = [:]
        for pack in packs.packs where !pack.bankKey.isEmpty {
            if byKey[pack.bankKey] == nil { order.append(pack.bankKey) }
            byKey[pack.bankKey, default: []].append(pack)
        }
        return order.map { (key: $0, packs: byKey[$0]!) }
    }

    /// A single downloadable sound bank. The representative pack (first in the group) drives the
    /// shared per-bank download/progress/delete state and carries the a11y ids.
    private func bankRow(_ group: (key: String, packs: [InstrumentPack])) -> some View {
        let rep = group.packs[0]
        let bytes = packs.bank(forKey: group.key)?.bytes ?? rep.bytes
        // One instrument → its own name; many → "Instrument sound bank" so it never reads as if
        // one download only grabbed Piano.
        let title = group.packs.count == 1 ? rep.name : "Instrument sound bank"
        let subtitle: String = {
            if let err = packs.error(for: rep) { return err }
            let size = bytes > 0 ? Self.sizeString(bytes) : ""
            if group.packs.count == 1 { return size }
            let names = group.packs.map(\.name).joined(separator: ", ")
            // "Piano, Violin, … · 31 MB" — makes the one-download-for-all reality explicit.
            return size.isEmpty ? names : "\(names) · \(size)"
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Theme.fg).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(packs.error(for: rep) != nil ? Theme.danger : Theme.fgDim)
                    .lineLimit(2)
            }
            Spacer()
            if let progress = packs.progress(for: rep) {
                ProgressView(value: progress).frame(width: 90)
                Button { packs.cancelDownload(rep) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("pack-cancel-\(rep.id)")
            } else if packs.isDownloaded(rep) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Button(role: .destructive) {
                    // Deleting the BANK flips every instrument sharing it back to downloadable —
                    // banks are re-downloadable, which is why deletion is allowed at all.
                    packs.deleteBank(bankKey: group.key)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .tint(Theme.danger)
                .accessibilityIdentifier("pack-delete-\(rep.id)")
            } else {
                Button { packs.download(rep) } label: {
                    Label("Get", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("pack-download-\(rep.id)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: MIDI (wired/USB + on-screen keys — v1 scope, spec §4)

    private var midiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIDI input").font(.headline).foregroundStyle(Theme.fg)
            if instruments.midiSourceNames.isEmpty {
                Text("No MIDI devices connected.").font(.caption).foregroundStyle(Theme.fgDim)
            } else {
                ForEach(instruments.midiSourceNames, id: \.self) { name in
                    Label(name, systemImage: "pianokeys.inverse")
                        .font(.subheadline).foregroundStyle(Theme.fg)
                }
            }
            // Bluetooth MIDI (I3) — a CoreBluetooth scanner that works on every platform (the
            // paired keyboard's notes feed InstrumentEngine directly, same as the on-screen keys).
            Button { showBTMIDIPicker = true } label: {
                Label("Connect Bluetooth MIDI…", systemImage: "wave.3.right")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .accessibilityIdentifier("midi-connect-bluetooth")
            Text("Wired USB MIDI, the on-screen keys, and Bluetooth MIDI keyboards (Connect above) all work on every device. Network MIDI isn't supported yet.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
        .sheet(isPresented: $showBTMIDIPicker) {
            BluetoothMIDIView(manager: bleMIDI, instruments: instruments)
        }
    }

    // MARK: Helpers

    /// A Binding onto a SettingsStore Bool that persists on EVERY write (see the record bar's
    /// WHY-comment).
    private func settingBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { settings[keyPath: keyPath] = $0; settings.persist() })
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Decorative SF-symbol per instrument (no dedicated instrument glyphs exist for most —
    /// nearest musical stand-ins, chosen from symbols present on iOS 18/macOS 15).
    private static func icon(for key: InstrumentKey) -> String {
        switch key {
        case .piano: return "pianokeys"
        case .violin: return "music.note"
        case .bassGuitar: return "guitars"
        case .acousticGuitar: return "guitars.fill"
        case .trumpet: return "music.note.list"
        case .clarinet: return "music.quarternote.3"
        case .harp: return "waveform.path"
        }
    }
}

// MARK: - On-screen piano keys (6 octaves C1–C7, octave-scrollable)

/// The PLAY surface: a horizontally scrollable six-octave keyboard (MIDI 24…96) that opens on
/// C3. `<` / `>` buttons flank it and jump the view down / up a whole octave; on macOS the
/// **left / right arrow keys** do the same (the keyboard also free-scrolls by touch/trackpad).
/// Each key drives `InstrumentEngine.noteOn/noteOff` — the SAME pipeline as CoreMIDI input
/// (spec §4), so a take records identically from either. Highlights render from
/// `engine.pressedNotes` (the ~30 Hz coalesced set), so MIDI input and replay light the keys
/// too, not just local touches.
///
/// Sizing: white keys are a FIXED 44 pt wide (comfortable touch targets); height follows the
/// container (the Instruments tab gives it ~200 pt).
struct PianoKeysView: View {
    @Environment(InstrumentEngine.self) private var instruments

    /// C1…C7 inclusive (MIDI 60 = C4 — the same convention ScoreLayout documents).
    var lowNote: Int = 24
    var highNote: Int = 96

    /// The C we scroll to the leading edge; starts at C3 (48) — the natural playing register.
    /// `<` / `>` move it one octave, clamped so a full octave always stays in view.
    @State private var anchorC: Int = 48

    /// Pitch classes that are black keys (C#, D#, F#, G#, A#).
    private static let blackPCs: Set<Int> = [1, 3, 6, 8, 10]
    private static let whiteKeyWidth: CGFloat = 44

    /// The C notes a button/arrow can anchor to — every octave except the very top one (so the
    /// last position still shows a full octave rather than a sliver).
    private var anchorCs: [Int] { Array(stride(from: lowNote, through: highNote - 12, by: 12)) }

    var body: some View {
        HStack(spacing: 6) {
            octaveButton(symbol: "chevron.left", id: "piano-octave-down",
                         disabled: anchorC <= (anchorCs.first ?? lowNote)) { shiftOctave(-12) }
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        keyboard(height: geo.size.height)
                    }
                    // Programmatic octave jumps (buttons + arrow keys) animate to the anchor C;
                    // free touch-scrolling in between is untouched.
                    .onChange(of: anchorC) {
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(anchorC, anchor: .leading) }
                    }
                    .onAppear { proxy.scrollTo(anchorC, anchor: .leading) }
                }
            }
            octaveButton(symbol: "chevron.right", id: "piano-octave-up",
                         disabled: anchorC >= (anchorCs.last ?? lowNote)) { shiftOctave(12) }
        }
        .background { arrowKeyShortcuts }
    }

    /// Move the anchor C by one octave, clamped to the playable range.
    private func shiftOctave(_ delta: Int) {
        let lo = anchorCs.first ?? lowNote
        let hi = anchorCs.last ?? lowNote
        anchorC = min(max(anchorC + delta, lo), hi)
    }

    /// A flanking octave-jump control — a full-height chevron, dimmed at the range ends.
    private func octaveButton(symbol: String, id: String, disabled: Bool,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Theme.fgDim : Theme.accent)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    /// macOS left/right arrow keys jump octaves (spec: "on macOS the arrow keys scroll"). Hidden
    /// 1×1 shadow buttons — the app's established keyboard-shortcut pattern — mounted only while
    /// this keyboard is, so plain arrows aren't hijacked elsewhere. iOS relies on the `<`/`>`
    /// buttons + touch scroll (no hardware keyboard assumed).
    @ViewBuilder private var arrowKeyShortcuts: some View {
        #if os(macOS)
        Group {
            Button("piano-octave-down-key") { shiftOctave(-12) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("piano-octave-up-key") { shiftOctave(12) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 1, height: 1).opacity(0.01)
        #else
        EmptyView()
        #endif
    }

    private func keyboard(height: CGFloat) -> some View {
        let whites = (lowNote...highNote).filter { !Self.blackPCs.contains($0 % 12) }
        let blacks = (lowNote...highNote).filter { Self.blackPCs.contains($0 % 12) }
        let whiteW = Self.whiteKeyWidth
        let blackW = whiteW * 0.62
        let blackH = height * 0.6
        // ZStack: whites first, blacks OVERLAID after so they win hit-testing at the
        // boundaries (each key carries its own gesture — simultaneous touches on different
        // keys work because they're distinct views). Each white key carries `.id(note)` so the
        // ScrollViewReader can jump to a C; C is always white, so anchor Cs resolve here.
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(whites, id: \.self) { note in
                    PianoKey(note: note, isBlack: false,
                             label: note % 12 == 0 ? "C\(note / 12 - 1)" : nil)
                        .frame(width: whiteW, height: height)
                        .id(note)
                }
            }
            ForEach(blacks, id: \.self) { note in
                // A black key sits centered on the boundary between its white neighbours:
                // x = (count of white keys strictly below it) × white width.
                let boundary = CGFloat(whites.filter { $0 < note }.count) * whiteW
                PianoKey(note: note, isBlack: true, label: nil)
                    .frame(width: blackW, height: blackH)
                    .offset(x: boundary - blackW / 2, y: 0)
            }
        }
    }
}

/// One key. Press state is LOCAL (`down`) for instant feedback; the engine's coalesced
/// `pressedNotes` also lights it so MIDI/replay highlights show on the same keys.
private struct PianoKey: View {
    @Environment(InstrumentEngine.self) private var instruments
    let note: Int
    let isBlack: Bool
    let label: String?
    @State private var down = false

    var body: some View {
        let lit = down || instruments.pressedNotes.contains(note)
        // Steady arp-set highlight (record mode's "stays highlighted"): distinct from the
        // momentary press color, and never fighting it — a lit key always wins.
        let arpSel = instruments.arpEnabled && instruments.arpSelectedNotes.contains(note)
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(lit ? Theme.accent : (arpSel ? Theme.accent2 : (isBlack ? Theme.bgOverlay : Theme.fg)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .overlay(alignment: .bottom) {
                if let label {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(lit ? Theme.bg : Theme.bgOverlay)
                        .padding(.bottom, 6)
                }
            }
            .contentShape(Rectangle())
            // DragGesture(minimumDistance: 0) = touch-down/touch-up semantics: noteOn the
            // instant the finger lands (a press, not a tap — latency matters on a keyboard),
            // noteOff on release. `down` guards the repeated .onChanged calls of one press.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        instruments.noteOn(note)
                    }
                    .onEnded { _ in
                        down = false
                        instruments.noteOff(note)
                    }
            )
            .accessibilityIdentifier("piano-key-\(note)")
    }
}

// MARK: - Small cross-platform helper

private extension View {
    /// Numeric keyboard on iOS; no-op on macOS (hardware keyboard).
    @ViewBuilder
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
