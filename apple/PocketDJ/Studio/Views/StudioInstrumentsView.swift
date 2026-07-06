import SwiftUI

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                instrumentGrid
                recordBar
                // PLAY area: ~200 pt tall keys, horizontally scrollable — the iPhone-portrait
                // contract (2 octaves don't fit a 390 pt screen at playable key widths).
                PianoKeysView()
                    .frame(height: 200)
                takesLink
                packsSection
                midiSection
            }
            .padding()
            .frame(maxWidth: 900)               // Mix-tab content-column precedent
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task {
            // Push the live settings into the store (the MixRecorder "views push settings in"
            // pattern — idempotent, no app-init wiring required for bookmark lookups), then
            // refresh the pack index (offline-first: the cached copy already listed instantly).
            studio.settings = settings
            await packs.refreshIndex()
        }
        // Name-the-take prompt. EVERY dismissal path files the take (Save with the draft,
        // Cancel/outside with the default name) — a recorded take is data and is never
        // silently dropped (the MixRecorder auto-file doctrine).
        .alert("Name this take", isPresented: Binding(
            get: { pendingTake != nil },
            set: { if !$0 { fileTakeIfPending(named: nil) } })) {
            TextField("Name", text: $takeNameDraft)
                .accessibilityIdentifier("take-name-field")
            Button("Save") { fileTakeIfPending(named: takeNameDraft) }
                .accessibilityIdentifier("take-name-save")
            Button("Cancel", role: .cancel) { fileTakeIfPending(named: nil) }
        } message: {
            Text("The take is kept either way — Cancel just uses the default name.")
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
            Text("Record a take").font(.headline).foregroundStyle(Theme.fg)
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
                Toggle("Click", isOn: settingBinding(\.studioClickEnabled))
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
        studio.addTake(StudioTake(id: r.takeId,
                                  name: trimmed.isEmpty ? defaultTakeName() : trimmed,
                                  instrument: r.instrument,
                                  fileName: r.fileName,
                                  bpm: r.bpm,
                                  events: r.events,
                                  durationMs: r.durationMs,
                                  createdAt: Date().timeIntervalSince1970 * 1000))
    }

    private func defaultTakeName() -> String { "Take \(studio.takes.count + 1)" }

    // MARK: Takes (pushed list — the layout call: the list + score live one push away)

    private var takesLink: some View {
        NavigationLink {
            StudioTakesView()
        } label: {
            HStack {
                Label("Takes", systemImage: "music.note.list").foregroundStyle(Theme.fg)
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
            // The v1 scope, stated honestly (spec §12): no network/BLE MIDI.
            Text("Wired USB MIDI keyboards and the on-screen keys are supported in v1 — network and Bluetooth MIDI aren't available yet.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
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

// MARK: - On-screen piano keys (2 octaves C3–C5)

/// The PLAY surface: a scrollable two-octave keyboard (MIDI 48…72). Each key drives
/// `InstrumentEngine.noteOn/noteOff` — the SAME pipeline as CoreMIDI input (spec §4), so a
/// take records identically from either. Highlights render from `engine.pressedNotes` (the
/// ~30 Hz coalesced set), so MIDI input and replay light the keys too, not just local touches.
///
/// Sizing: white keys are a FIXED 44 pt wide (comfortable touch targets) inside a horizontal
/// ScrollView — on iPhone portrait the keyboard scrolls, on iPad/macOS it mostly fits. Height
/// follows the container (the Instruments tab gives it ~200 pt).
struct PianoKeysView: View {
    @Environment(InstrumentEngine.self) private var instruments

    /// C3…C5 inclusive (MIDI 60 = C4 — the same convention ScoreLayout documents).
    var lowNote: Int = 48
    var highNote: Int = 72

    /// Pitch classes that are black keys (C#, D#, F#, G#, A#).
    private static let blackPCs: Set<Int> = [1, 3, 6, 8, 10]
    private static let whiteKeyWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                keyboard(height: geo.size.height)
            }
        }
    }

    private func keyboard(height: CGFloat) -> some View {
        let whites = (lowNote...highNote).filter { !Self.blackPCs.contains($0 % 12) }
        let blacks = (lowNote...highNote).filter { Self.blackPCs.contains($0 % 12) }
        let whiteW = Self.whiteKeyWidth
        let blackW = whiteW * 0.62
        let blackH = height * 0.6
        // ZStack: whites first, blacks OVERLAID after so they win hit-testing at the
        // boundaries (each key carries its own gesture — simultaneous touches on different
        // keys work because they're distinct views).
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(whites, id: \.self) { note in
                    PianoKey(note: note, isBlack: false,
                             label: note % 12 == 0 ? "C\(note / 12 - 1)" : nil)
                        .frame(width: whiteW, height: height)
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
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(lit ? Theme.accent : (isBlack ? Theme.bgOverlay : Theme.fg))
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
