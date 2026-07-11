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
    /// Takes already sampled THIS visit — flips the button to a checkmark so a double-tap doesn't
    /// mint two identical samples by accident (a re-sample is still allowed after leaving and
    /// returning; samples are cheap and explicitly user-owned).
    @State private var sampledIds: Set<String> = []
    /// Takes whose events are RENDERING into a sample right now (the offline sampler render is
    /// async) — drives the row spinner + disables a second tap mid-render.
    @State private var samplingIds: Set<String> = []
    @State private var errorText: String?
    /// The instrumental whose "Add to playlist or pocket…" sheet is open (nil ⇒ closed).
    @State private var addRef: StudioAddRef?

    private var takesNewestFirst: [StudioTake] {
        studio.takes.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if takesNewestFirst.isEmpty {
                ContentUnavailableView("No instrumentals yet", systemImage: "pianokeys",
                    description: Text("Record an instrumental on the Instruments tab — it lands here with its score, replay, and export."))
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
        .navigationTitle("Instrumentals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Rename instrumental", isPresented: Binding(get: { renamingId != nil },
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
        .studioAddToCollection($addRef)
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
                    Text(take.name.isEmpty ? "Untitled instrumental" : take.name)
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
                    if samplingIds.contains(take.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: sampledIds.contains(take.id)
                              ? "checkmark.circle" : "waveform.badge.plus")
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(sampledIds.contains(take.id) || samplingIds.contains(take.id)
                          || take.scoreEvents.isEmpty)
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
            Button { useAsSample(take) } label: { Label("Sample from instrumental", systemImage: "waveform.badge.plus") }
                .disabled(samplingIds.contains(take.id) || take.scoreEvents.isEmpty)
            Button {
                addRef = StudioAddRef(id: take.id, title: take.name)
                // Prepare it for the collection: render the real audio (so it's audible the moment
                // it plays) + detect its key for Mix glide. Idempotent.
                let tid = take.id
                Task { await StudioAnalyzer.prepare(forStudioId: tid, studio: studio, packs: packs) }
            } label: {
                Label("Add to playlist or pocket…", systemImage: "plus.rectangle.on.folder")
            }
            Button(role: .destructive) { _ = studio.deleteTake(take.id) } label: {
                Label("Delete instrumental", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ take: StudioTake) {
        nameDraft = take.name
        renamingId = take.id
    }

    // MARK: Sample from instrumental (spec §2/§7 — the take → sample → loop path)

    /// RENDER the take's note events through its instrument's SoundFont into a real `.m4a` sample
    /// and file a `StudioSample(source: .take)`. The rendered audio — never a copy of the take's
    /// own file, which for a live-saved take is a SILENT placeholder — is what fixes the
    /// flat-waveform bug: the sample now sounds like the instrumental's Replay. The audio is fully
    /// self-contained (spec §2's load-bearing rule): the sample keeps playing after the take is
    /// deleted. The new sample inherits a CONSTANT grid from the take's bpm.
    ///
    /// Requires the take's instrument pack downloaded (the bank the render loads) — a missing pack
    /// points the user at the download, the same gate Replay uses, never a silent sample.
    private func useAsSample(_ take: StudioTake) {
        guard !sampledIds.contains(take.id), !samplingIds.contains(take.id) else { return }
        guard !take.scoreEvents.isEmpty else {
            errorText = "This instrumental has no notes to render into a sample."
            return
        }
        let takeId = take.id
        samplingIds.insert(takeId)
        Task {
            do {
                _ = try await StudioTakeSampler.makeSample(from: take, studio: studio, packs: packs)
                samplingIds.remove(takeId)
                sampledIds.insert(takeId)
            } catch {
                samplingIds.remove(takeId)
                errorText = StudioTakeSampler.message(for: error)
            }
        }
    }
}

// MARK: - Shared take → sample renderer (takes list + samples-view picker)

/// Renders an instrumental take's note events through its instrument's SoundFont into a real
/// `.m4a` sample and files it (`source: .take`). The ONE place the events→audio "burn a take to
/// disc" happens for sampling, shared by `StudioTakesView`'s in-row button and the Samples view's
/// "Sample from instrumental" picker so the two can't drift. The rendered audio is self-contained
/// (never a copy of the take's own file, which for a live-saved take is a silent placeholder).
@MainActor
enum StudioTakeSampler {
    enum SampleError: Error {
        case noNotes
        case noPack(String)      // instrument display name
        case noFolder
        case renderFailed(String)
    }

    /// Render `take` → a new sample in `studio`, returning the new sample id. Throws `SampleError`
    /// (mapped to user copy by `message(for:)`). Requires the take's instrument pack downloaded.
    @discardableResult
    static func makeSample(from take: StudioTake, studio: StudioStore,
                           packs: InstrumentPackStore) async throws -> String {
        guard !take.scoreEvents.isEmpty else { throw SampleError.noNotes }
        guard let bankURL = packs.localBankURL(forInstrument: take.instrument) else {
            throw SampleError.noPack(take.instrument.displayName)
        }
        // The samples family WRITE root: the user-picked folder when configured (its security scope
        // held across the render), else the app-managed dir; `isUserFolder` is stamped onto the
        // record so the file forever resolves against the root it was written to.
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples),
                                              requireWritable: true) else {
            throw SampleError.noFolder
        }
        defer { dest.release?() }
        let sampleId = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: sampleId)
        let destURL = dest.url.appendingPathComponent(fileName)
        do {
            let rendered = try await StudioRender.shared.renderTake(
                events: take.scoreEvents, bankURL: bankURL,
                program: take.instrument.gmProgram, to: destURL)
            studio.addSample(StudioSample(id: sampleId,
                                          name: take.name.isEmpty ? "Instrumental sample" : take.name,
                                          fileName: fileName, wasUserFolder: dest.isUserFolder,
                                          createdAt: Date().timeIntervalSince1970 * 1000,
                                          durationMs: rendered.durationMs,
                                          source: .take(takeId: take.id),
                                          grid: StudioGrid(bpm: take.bpm)))
            return sampleId
        } catch {
            throw SampleError.renderFailed(take.instrument.displayName)
        }
    }

    /// User-facing copy for a `SampleError` (or any thrown error, defensively).
    static func message(for error: Error) -> String {
        switch error {
        case SampleError.noNotes:
            return "This instrumental has no notes to render into a sample."
        case SampleError.noPack(let name):
            return "Download the \(name) pack to make a sample from this instrumental."
        case SampleError.noFolder:
            return "Couldn't open the samples folder."
        case SampleError.renderFailed(let name):
            return "Couldn't render this instrumental into a sample. Try again, or re-download the \(name) pack."
        default:
            return "Couldn't make a sample from this instrumental."
        }
    }
}

// MARK: - Instrumental render cache (collection + Mix playback)

/// Ensures an instrumental has a fresh RENDERED-AUDIO cache — its `scoreEvents` synthesized through
/// its instrument into a real `.m4a` — so it's audible in collection playback + Mix even when its
/// raw file is a silent placeholder (a live-saved take). The one place this render happens for
/// PLAYBACK (the sample path renders into a new `smp_`; this renders into the take's own cache).
@MainActor
enum StudioTakeRenderer {
    /// No-op when: no such take / no notes / a fresh cache already exists on disk / the instrument
    /// pack isn't downloaded. On the pack-missing path the raw file still resolves — a RECORDED
    /// take is its real capture (audible); a live placeholder stays silent until a later render.
    static func ensureRendered(takeId: String, studio: StudioStore, packs: InstrumentPackStore) async {
        guard let take = studio.take(takeId), !take.scoreEvents.isEmpty else { return }
        let bm = studio.bookmark(for: .takes)
        if let rf = take.renderedFileName,
           let got = StudioFolders.fileURL(family: .takes, fileName: rf,
                                           wasUserFolder: take.renderedWasUserFolder ?? false, bookmark: bm) {
            got.release?()
            return   // fresh cache already on disk
        }
        guard let bankURL = packs.localBankURL(forInstrument: take.instrument),
              let dest = StudioFolders.folder(.takes, bookmark: bm, requireWritable: true) else { return }
        defer { dest.release?() }
        let fileName = StudioFolders.renderedTakeFileName(id: takeId)
        let destURL = dest.url.appendingPathComponent(fileName)
        do {
            _ = try await StudioRender.shared.renderTake(events: take.scoreEvents, bankURL: bankURL,
                                                         program: take.instrument.gmProgram, to: destURL)
            studio.setTakeRendered(takeId, fileName: fileName, wasUserFolder: dest.isUserFolder)
        } catch {
            // Leave uncached — the raw file still resolves for playback (see the doc comment).
        }
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
