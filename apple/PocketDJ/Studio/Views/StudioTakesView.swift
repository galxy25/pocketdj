import SwiftUI

// MARK: - Studio ▸ Instruments ▸ Takes (spec §7)
//
// The recorded-takes list, pushed from StudioInstrumentsView. Row tap opens the take's SCORE
// (the primary read of a take); Replay and "Use as sample" are in-row leaf buttons (the
// iPhone-portrait rule: critical actions live in content, never behind an overflow); rename
// and delete follow the MixSessionsView swipe + context-menu shape.
struct StudioTakesView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(InstrumentEngine.self) private var instruments
    @Environment(InstrumentPackStore.self) private var packs

    @State private var renamingId: String?
    @State private var nameDraft = ""
    /// Takes already copied into Samples THIS visit — flips the button to a checkmark so a
    /// double-tap doesn't mint two identical samples by accident (a re-copy is still allowed
    /// after leaving and returning; samples are cheap and explicitly user-owned).
    @State private var sampledIds: Set<String> = []
    @State private var errorText: String?

    private var takesNewestFirst: [StudioTake] {
        studio.takes.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if takesNewestFirst.isEmpty {
                ContentUnavailableView("No takes yet", systemImage: "pianokeys",
                    description: Text("Record a take on the Instruments tab — it lands here with its score, replay, and export."))
            } else {
                List {
                    ForEach(takesNewestFirst) { take in
                        row(take)
                    }
                }
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("takes-list")
            }
        }
        .background(Theme.bg)
        .navigationTitle("Takes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Rename take", isPresented: Binding(get: { renamingId != nil },
                                                   set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft).accessibilityIdentifier("take-rename-field")
            Button("Save") {
                if let id = renamingId { studio.renameTake(id, to: nameDraft) }
                renamingId = nil
            }
            .accessibilityIdentifier("take-rename-confirm")
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .alert("Takes", isPresented: Binding(get: { errorText != nil },
                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Row

    private func row(_ take: StudioTake) -> some View {
        NavigationLink {
            StudioScoreView(takeId: take.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(take.name.isEmpty ? "Untitled take" : take.name)
                        .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                    Text("\(take.instrument.displayName) · \(Fmt.duration(take.durationMs)) · \(Fmt.bpm(take.bpm)) BPM · \(take.events.count) note\(take.events.count == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                // In-row leaf actions — .borderless so each button is individually tappable
                // inside the NavigationLink row (the standard List-row-buttons discipline).
                Button {
                    if !StudioTakeReplay.toggle(take: take, instruments: instruments, packs: packs) {
                        errorText = "Download the \(take.instrument.displayName) pack to hear this take."
                    }
                } label: {
                    Image(systemName: instruments.isReplaying ? "stop.circle" : "play.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(take.scoreEvents.isEmpty)
                .accessibilityIdentifier("take-replay-\(take.id)")
                Button {
                    useAsSample(take)
                } label: {
                    Image(systemName: sampledIds.contains(take.id)
                          ? "checkmark.circle" : "waveform.badge.plus")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(sampledIds.contains(take.id))
                .accessibilityIdentifier("take-as-sample-\(take.id)")
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("take-row-\(take.id)")
        .swipeActions(edge: .leading) {
            Button { beginRename(take) } label: { Label("Rename", systemImage: "pencil") }
                .tint(Theme.accent2)
                .accessibilityIdentifier("take-rename-\(take.id)")
        }
        .swipeActions {
            Button(role: .destructive) { _ = studio.deleteTake(take.id) } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("take-delete-\(take.id)")
        }
        .contextMenu {   // right-click (macOS) / long-press (iOS) — swipe parity
            Button { beginRename(take) } label: { Label("Rename…", systemImage: "pencil") }
            Button { useAsSample(take) } label: { Label("Use as sample", systemImage: "waveform.badge.plus") }
            Button(role: .destructive) { _ = studio.deleteTake(take.id) } label: {
                Label("Delete take", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ take: StudioTake) {
        nameDraft = take.name
        renamingId = take.id
    }

    // MARK: Use as sample (spec §2/§7 — the take → sample → loop path)

    /// COPY the take's audio into the samples family and file a `StudioSample(source: .take)`.
    /// A copy, never a reference (spec §2's load-bearing rule): the sample must keep playing
    /// after the take is deleted. The new sample inherits a CONSTANT grid from the take's bpm
    /// (`firstDownbeatMs = 0` — recording starts on beat 1 after the count-in).
    private func useAsSample(_ take: StudioTake) {
        guard !sampledIds.contains(take.id) else { return }
        // Resolve the take's audio (always app-managed — no bookmark, no scope; spec §3).
        guard let src = StudioFolders.fileURL(family: .takes, fileName: take.fileName,
                                              wasUserFolder: false, bookmark: nil) else {
            errorText = "The take's audio file is missing — it can't be used as a sample."
            return
        }
        defer { src.release?() }   // nil for app storage — kept for the resolver's contract symmetry
        let sampleId = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: sampleId)
        // The samples family WRITE root: the user-picked folder when configured (its security
        // scope held for the copy), else the app-managed dir; `isUserFolder` is stamped onto
        // the record so the file forever resolves against the root it was written to.
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples),
                                              requireWritable: true) else {
            errorText = "Couldn't open the samples folder."
            return
        }
        defer { dest.release?() }
        do {
            try FileManager.default.copyItem(at: src.url,
                                             to: dest.url.appendingPathComponent(fileName))
        } catch {
            errorText = "Couldn't copy the take's audio into Samples."
            return
        }
        studio.addSample(StudioSample(id: sampleId,
                                      name: take.name.isEmpty ? "Take sample" : take.name,
                                      fileName: fileName,
                                      wasUserFolder: dest.isUserFolder,
                                      createdAt: Date().timeIntervalSince1970 * 1000,
                                      durationMs: take.durationMs,
                                      source: .take(takeId: take.id),
                                      grid: StudioGrid(bpm: take.bpm)))
        sampledIds.insert(take.id)
    }
}

// MARK: - Shared replay helper (takes list + score view)

/// Replay a take through the sampler, loading the take's OWN instrument first when its bank is
/// on disk (score and sound should agree — spec §7). Falls back to whatever instrument is
/// loaded (wrong timbre beats a dead button — the engine logs the mismatch). Returns false
/// only when replay is impossible right now (no bank loaded AND none downloaded) so callers
/// can point the user at the pack download.
@MainActor
enum StudioTakeReplay {
    @discardableResult
    static func toggle(take: StudioTake, instruments: InstrumentEngine,
                       packs: InstrumentPackStore) -> Bool {
        if instruments.isReplaying {
            instruments.stopReplay()
            return true
        }
        guard !take.scoreEvents.isEmpty else { return true }   // nothing to play — not an error
        if instruments.currentInstrument == take.instrument {
            instruments.replayTake(events: take.scoreEvents, instrument: take.instrument)
            return true
        }
        // Wrong (or no) instrument loaded: load the right bank first when it's downloaded.
        if let pack = packs.packs.first(where: { $0.instrument == take.instrument }),
           let url = packs.localBankURL(pack) {
            Task { @MainActor in
                _ = await instruments.loadInstrument(take.instrument, bankURL: url)
                instruments.replayTake(events: take.scoreEvents, instrument: take.instrument)
            }
            return true
        }
        // No bank for this instrument on disk. If SOMETHING is loaded, degrade to it
        // (audible, logged); with nothing loaded the sampler is silent — report that.
        if instruments.currentInstrument != nil {
            instruments.replayTake(events: take.scoreEvents, instrument: take.instrument)
            return true
        }
        return false
    }
}
