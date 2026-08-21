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
    @Environment(DemuxStore.self) private var demux
    @Environment(BurnStore.self) private var burns

    /// Takes whose comping↔melody re-extract is in flight (F8 slice B) — drives the disabled state
    /// so a second tap can't race the switch.
    @State private var switchingIds: Set<String> = []

    @State private var renamingId: String?
    @State private var nameDraft = ""
    @State private var tempoId: String?
    @State private var tempoDraft = ""

    /// Relative tempo presets offered in the take's Tempo submenu (applied to the current bpm).
    private static let tempoMultipliers: [Double] = [0.5, 0.75, 0.9, 1.1, 1.25, 1.5, 2.0]
    private static func multLabel(_ m: Double) -> String {
        m == m.rounded() ? String(Int(m)) : String(format: "%.2g", m)
    }
    /// Takes already sampled THIS visit — flips the button to a checkmark so a double-tap doesn't
    /// mint two identical samples by accident (a re-sample is still allowed after leaving and
    /// returning; samples are cheap and explicitly user-owned).
    @State private var sampledIds: Set<String> = []
    /// Takes whose events are RENDERING into a sample right now (the offline sampler render is
    /// async) — drives the row spinner + disables a second tap mid-render.
    @State private var samplingIds: Set<String> = []
    /// Takes whose multi-staff MIXDOWN is being rendered before playback — the ▶ shows a spinner
    /// instead of doing nothing visible while a cold cache is synthesized (never a silent no-op).
    @State private var preparingIds: Set<String> = []
    @State private var errorText: String?
    /// The instrumental whose "Add to playlist or pocket…" sheet is open (nil ⇒ closed).
    @State private var addRef: StudioAddRef?

    // Folder organization for INSTRUMENTALS (mirrors StudioSamplesView). Device-local; NO audio moves.
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    /// When "New folder…" is chosen from a take's Move submenu, the new folder is created AND this
    /// take is moved into it (nil ⇒ a plain "New folder" from the toolbar, just create).
    @State private var pendingMoveTakeId: String?
    @State private var renamingFolderId: String?
    @State private var folderNameDraft = ""
    @State private var deletingFolderId: String?
    /// Collapsed take-folder ids, persisted across launches (missing ⇒ expanded).
    @State private var collapsed: Set<String> = StudioTakesView.loadCollapsed()

    var body: some View {
        Group {
            // Empty state only when there is nothing at all — a folder with no instrumentals still
            // needs its section shown so the user can move instrumentals in / manage it.
            if studio.takes.isEmpty && studio.takeFolders.isEmpty {
                ContentUnavailableView("No instrumentals yet", systemImage: "pianokeys",
                    description: Text("Record an instrumental on the Instruments tab — it lands here with its score, replay, and export."))
            } else {
                takeList
            }
        }
        .background(Theme.bg)
        .navigationTitle("Instrumentals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // New instrumentals are created on the Instruments tab; this browse list has no in-content
            // creation bar, so the organizational New-folder affordance lives in the toolbar (the
            // StudioSamplesView "folder.badge.plus" button, adapted to this view's nav-pushed shape).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newFolderName = ""; pendingMoveTakeId = nil; showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityIdentifier("take-new-folder")
            }
        }
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
        .alert("Set tempo (BPM)", isPresented: Binding(get: { tempoId != nil },
                                                       set: { if !$0 { tempoId = nil } })) {
            TextField("BPM", text: $tempoDraft)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                .accessibilityIdentifier("take-tempo-field")
            Button("Set") {
                if let id = tempoId, let bpm = Double(tempoDraft.trimmingCharacters(in: .whitespaces)) {
                    studio.setTakeTempo(id, newBpm: bpm)
                }
                tempoId = nil
            }
            .accessibilityIdentifier("take-tempo-confirm")
            Button("Cancel", role: .cancel) { tempoId = nil }
        } message: { Text("Re-times the whole instrumental — the notes play faster or slower.") }
        .alert("Takes", isPresented: Binding(get: { errorText != nil },
                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .studioAddToCollection($addRef)
        // Folder create / rename / delete (the StudioSamplesView precedent) — device-local, additive.
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty {
                    let f = studio.createTakeFolder(n)
                    // Chosen from an instrumental's Move submenu ⇒ file that take into the new folder.
                    if let tid = pendingMoveTakeId { studio.setTakeFolder(tid, folderId: f.id) }
                }
                newFolderName = ""; pendingMoveTakeId = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = ""; pendingMoveTakeId = nil }
        }
        .alert("Rename folder", isPresented: folderRenameBinding) {
            TextField("Name", text: $folderNameDraft)
            Button("Save") {
                if let id = renamingFolderId { studio.renameTakeFolder(id, to: folderNameDraft) }
                renamingFolderId = nil
            }
            Button("Cancel", role: .cancel) { renamingFolderId = nil }
        }
        .confirmationDialog("Delete this folder?", isPresented: folderDeleteBinding,
                            titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let id = deletingFolderId { studio.deleteTakeFolder(id) }
                deletingFolderId = nil
            }
            Button("Cancel", role: .cancel) { deletingFolderId = nil }
        } message: {
            Text("The folder's instrumentals move back to Unfiled. No instrumentals or audio are deleted.")
        }
    }

    // MARK: Folder-grouped list (Unfiled section + one collapsible DisclosureGroup per folder)

    private var takeList: some View {
        List {
            unfiledSection
            ForEach(studio.takeFoldersOrdered()) { folder in
                folderSection(folder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("takes-list")
    }

    /// The Unfiled section — instrumentals with no folder (or a dangling one). Always shown (it's
    /// the default home + the "Move to Unfiled" drop target).
    @ViewBuilder private var unfiledSection: some View {
        let unfiled = studio.takes(inFolder: nil)
        Section {
            if unfiled.isEmpty {
                Text("No unfiled instrumentals.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(unfiled) { take in row(take) }
            }
        } header: {
            Text("Unfiled").foregroundStyle(Theme.fgDim)
        }
    }

    /// One collapsible FOLDER of instrumentals, name-ordered. Collapse state persists (UserDefaults).
    @ViewBuilder private func folderSection(_ folder: StudioTakeFolder) -> some View {
        let members = studio.takes(inFolder: folder.id)
        Section {
            DisclosureGroup(isExpanded: folderExpansion(folder.id)) {
                if members.isEmpty {
                    Text("Empty folder — move an instrumental in with its ⋯ menu.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .listRowBackground(Color.clear)
                }
                ForEach(members) { take in row(take) }
            } label: {
                HStack {
                    Label(folder.name, systemImage: "folder").foregroundStyle(Theme.accent2)
                    Spacer()
                    Text("\(members.count)").font(.caption).foregroundStyle(Theme.fgDim)
                }
                // The id rides the LABEL (a leaf), never the Section/DisclosureGroup container —
                // a container id would clobber descendant ids on macOS (the StemAuditionPanel trap).
                .accessibilityIdentifier("folder-\(folder.id)")
                .contextMenu {
                    Button {
                        folderNameDraft = folder.name; renamingFolderId = folder.id
                    } label: { Label("Rename folder", systemImage: "pencil") }
                        .accessibilityIdentifier("folder-rename-\(folder.id)")
                    Button(role: .destructive) { deletingFolderId = folder.id } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                        .accessibilityIdentifier("folder-delete-\(folder.id)")
                }
            }
        }
    }

    // MARK: Folder bindings + collapse persistence (the StudioSamplesView precedent)

    private var folderRenameBinding: Binding<Bool> {
        Binding(get: { renamingFolderId != nil }, set: { if !$0 { renamingFolderId = nil } })
    }

    private var folderDeleteBinding: Binding<Bool> {
        Binding(get: { deletingFolderId != nil }, set: { if !$0 { deletingFolderId = nil } })
    }

    /// NEW key (device-local, distinct from the sample/loop/pattern-folder keys) per the spec.
    private static let collapsedKey = "pdj.takeFolders.collapsed"
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsed), forKey: StudioTakesView.collapsedKey)
    }
    /// A binding into `collapsed` for a folder's DisclosureGroup, persisting on change (presence in
    /// the set = COLLAPSED, so a never-touched folder reads as expanded).
    private func folderExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                persistCollapsed()
            })
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
                    Text("\(take.instrument.displayName) · \(Fmt.duration(take.durationMs)) · \(Fmt.bpm(take.bpm)) BPM · \(take.scoreEvents.count) note\(take.scoreEvents.count == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                // In-row leaf actions — .borderless so each button is individually tappable
                // inside the NavigationLink row (the standard List-row-buttons discipline).
                Button {
                    if !StudioTakeReplay.toggle(take: take, instruments: instruments, studio: studio,
                                                packs: packs,
                                                preparing: { on in
                                                    if on { preparingIds.insert(take.id) }
                                                    else { preparingIds.remove(take.id) }
                                                },
                                                onError: { errorText = $0 }) {
                        errorText = "Download the \(take.instrument.displayName) pack to hear this take."
                    }
                } label: {
                    if preparingIds.contains(take.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: instruments.isReplaying ? "stop.circle" : "play.circle")
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(take.allScoreEvents.isEmpty || preparingIds.contains(take.id))
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
            // Folder organization — file this instrumental into a folder (or Unfiled / a brand-new
            // folder). Sets a string only; the audio never moves.
            Menu {
                ForEach(studio.takeFoldersOrdered()) { f in
                    Button { studio.setTakeFolder(take.id, folderId: f.id) } label: {
                        if take.folderId == f.id {
                            Label(f.name, systemImage: "checkmark")
                        } else {
                            Text(f.name)
                        }
                    }
                    .accessibilityIdentifier("move-to-\(f.id)-\(take.id)")
                }
                Divider()
                Button { studio.setTakeFolder(take.id, folderId: nil) } label: {
                    if take.folderId == nil {
                        Label("Unfiled", systemImage: "checkmark")
                    } else {
                        Text("Unfiled")
                    }
                }
                .accessibilityIdentifier("move-to-unfiled-\(take.id)")
                Button {
                    pendingMoveTakeId = take.id; newFolderName = ""; showNewFolder = true
                } label: {
                    Label("New folder…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("move-to-new-\(take.id)")
            } label: {
                Label("Move to folder", systemImage: "folder")
            }
            .accessibilityIdentifier("take-move-\(take.id)")
            // Switch the playback instrument — re-synthesizes the same notes through the new SoundFont.
            Menu {
                ForEach(InstrumentKey.allCases, id: \.self) { inst in
                    Button { studio.setTakeInstrument(take.id, inst) } label: {
                        Label(inst.displayName, systemImage: take.instrument == inst ? "checkmark" : "")
                    }
                }
            } label: { Label("Instrument", systemImage: "pianokeys") }
            // Re-time the whole take — scales the notes so it plays faster/slower.
            Menu {
                ForEach(Self.tempoMultipliers, id: \.self) { mult in
                    let newBpm = min(max(take.bpm * mult, 20), 300)
                    Button { studio.setTakeTempo(take.id, newBpm: newBpm) } label: {
                        Text("×\(Self.multLabel(mult)) — \(Int(newBpm.rounded())) BPM")
                    }
                }
                Button { beginTempo(take) } label: { Label("Set exact BPM…", systemImage: "metronome") }
            } label: { Label("Tempo (\(Int(take.bpm.rounded())) BPM)", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            // F8 slice B: flip a Demux instrumental between chord-comping and true melody by
            // re-extracting the OTHER mode from the same demux source (only for demux takes).
            if take.demuxSourceKey != nil {
                Button { switchMode(take) } label: {
                    Label(take.demuxMode == "melody" ? "Switch to comping" : "Switch to melody",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(switchingIds.contains(take.id))
                .accessibilityIdentifier("demux-switch-mode-\(take.id)")
            }
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

    private func beginTempo(_ take: StudioTake) {
        tempoDraft = String(Int(take.bpm.rounded()))
        tempoId = take.id
    }

    // MARK: Switch mode (comping ↔ melody, F8 slice B)

    /// Re-extract the OTHER mode from the take's demux source and REPLACE its events in place
    /// (the score/replay re-render). A clear message when melody is requested but the source's
    /// stems are gone (never a silent no-op).
    private func switchMode(_ take: StudioTake) {
        guard !switchingIds.contains(take.id) else { return }
        switchingIds.insert(take.id)
        Task {
            do {
                try await DemuxTakeSwitch.switchMode(take: take, demux: demux, burns: burns,
                                                     studio: studio, packs: packs)
            } catch {
                errorText = DemuxTakeSwitch.message(for: error)
            }
            switchingIds.remove(take.id)
        }
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

// MARK: - Instrumental render cache (collection + Mix playback + multi-staff replay)

/// Ensures an instrumental has a fresh RENDERED-AUDIO cache — every staff synthesized through its
/// own instrument and mixed into a real `.m4a` — so it's audible in collection playback, in Mix,
/// and (for a multi-staff take) under the score's own ▶ even when its raw file is a silent
/// placeholder (a live-saved take). The one place this render happens for PLAYBACK (the sample
/// path renders into a new `smp_`; this renders into the take's own cache).
@MainActor
enum StudioTakeRenderer {
    /// What `ensureRendered` did. A TYPED outcome, not `Void`: playback now depends on this, and a
    /// silent `return` on the playback path is exactly the failure mode this whole change removes.
    enum RenderOutcome: Equatable {
        case fresh              // a valid cache was already on disk
        case rendered           // freshly synthesized + filed
        case noTake
        case noNotes            // nothing to synthesize — not an error
        case needPack(String)   // a staff's instrument pack isn't downloaded (display name)
        case noFolder
        case renderFailed(String)

        /// Did this leave a usable cache behind?
        var hasRender: Bool { self == .fresh || self == .rendered }
    }

    /// No-op when: no such take / no notes / a fresh cache already exists on disk / the instrument
    /// pack isn't downloaded. On the pack-missing path the raw file still resolves — a RECORDED
    /// take is its real capture (audible); a live placeholder stays silent until a later render.
    @discardableResult
    static func ensureRendered(takeId: String, studio: StudioStore,
                               packs: InstrumentPackStore) async -> RenderOutcome {
        guard let take = studio.take(takeId) else {
            NPLog.trace("studio: render SKIP noTake tk=\(takeId)")
            return .noTake
        }
        guard !take.allScoreEvents.isEmpty else {
            NPLog.trace("studio: render SKIP noNotes tk=\(takeId)")
            return .noNotes
        }
        let bm = studio.bookmark(for: .takes)
        if take.isRenderFresh, let rf = take.renderedFileName,
           let got = StudioFolders.fileURL(family: .takes, fileName: rf,
                                           wasUserFolder: take.renderedWasUserFolder ?? false, bookmark: bm) {
            got.release?()
            return .fresh   // fresh cache already on disk
        }
        guard let bankURL = packs.localBankURL(forInstrument: take.instrument) else {
            NPLog.trace("studio: render REFUSED needPack \(take.instrument.rawValue) tk=\(takeId)")
            return .needPack(take.instrument.displayName)
        }
        guard let dest = StudioFolders.folder(.takes, bookmark: bm, requireWritable: true) else {
            NPLog.trace("studio: render REFUSED noFolder tk=\(takeId)")
            return .noFolder
        }
        defer { dest.release?() }
        // The revision this render is made OF. `setTakeRendered` refuses the stamp if the score
        // moved on meanwhile — a mixdown of the pre-edit score must never be filed as current,
        // because it would play back as "the overdub isn't there" forever.
        let revision = take.renderRevision
        let fileName = StudioFolders.renderedTakeFileName(id: takeId, revision: revision)
        let destURL = dest.url.appendingPathComponent(fileName)
        do {
            if let extras = take.extraStaffs, !extras.isEmpty {
                // Multi-staff: render EVERY staff and mix (sequential single-sampler renders —
                // the one 32 MB font is never held twice). Refused when any staff's pack is
                // missing (a partial mix would silently drop a part — the bank gate holds
                // per-staff).
                var staffs: [(events: [StudioNoteEvent], program: UInt8, bankURL: URL)] =
                    [(take.scoreEvents, take.instrument.gmProgram, bankURL)]
                for staff in extras where !staff.scoreEvents.isEmpty {
                    guard let staffBank = packs.localBankURL(forInstrument: staff.instrument) else {
                        NPLog.trace("studio: render REFUSED needPack(staff) \(staff.instrument.rawValue)"
                                    + " tk=\(takeId)")
                        return .needPack(staff.instrument.displayName)
                    }
                    staffs.append((staff.scoreEvents, staff.instrument.gmProgram, staffBank))
                }
                _ = try await StudioRender.shared.renderTakePolyphonic(staffs: staffs, to: destURL)
            } else {
                _ = try await StudioRender.shared.renderTake(events: take.scoreEvents, bankURL: bankURL,
                                                             program: take.instrument.gmProgram, to: destURL)
            }
            studio.setTakeRendered(takeId, fileName: fileName, wasUserFolder: dest.isUserFolder,
                                   revision: revision)
            return .rendered
        } catch {
            // Leave uncached — the raw file still resolves for playback (see the doc comment).
            NPLog.trace("studio: render FAILED tk=\(takeId) — \(error)")
            return .renderFailed(take.instrument.displayName)
        }
    }
}

// MARK: - Take playback routing (which engine path plays this instrumental)

/// WHICH path plays a saved instrumental. A single staff keeps the shipped sampler replay
/// (`replayTake`) untouched; anything with more than one staff plays its RENDERED MIXDOWN through
/// the engine's backing player — proven code (the same file collections and Mix already play),
/// per-staff timbre included, with the live sampler left free for the user's overdub voice.
@MainActor
enum StudioTakePlayback {
    enum Route: Equatable {
        case sampler         // one staff → the shipped replayTake
        case renderedAudio   // multi-staff → the cached mixdown
        case liveSamplers    // multi-staff with no mixdown available → real-time sampler pool
    }

    /// The routing rule, PURE so it is pinned by a test rather than eyeballed. Single staff is
    /// `.sampler` whether or not a render exists — that path demonstrably works and is not touched.
    /// An overdub BACKING never routes to `.sampler` at any staff count: the sampler is the user's
    /// overdub VOICE, and the backing may not contend with it.
    nonisolated static func route(staffCount: Int, hasRender: Bool, asBacking: Bool = false) -> Route {
        guard staffCount > 1 || asBacking else { return .sampler }
        return hasRender ? .renderedAudio : .liveSamplers
    }

    /// How a play attempt ended — the ▶ sites alert on anything that isn't `.playing`.
    enum StartOutcome: Equatable {
        case playing
        case nothingToPlay
        case needPack(String)
        case failed(String)

        /// User-facing copy for the alert both ▶ sites already show, or nil when there is nothing
        /// to say (it played, or there was nothing to play).
        var message: String? {
            switch self {
            case .playing, .nothingToPlay: return nil
            case .needPack(let name): return "Download the \(name) pack to hear this instrumental."
            case .failed(let why): return why
            }
        }
    }

    /// Start `take` playing from `fromMs`, rendering its mixdown on demand when needed.
    /// `preparing` is called with true around a render that has to happen first (the caller shows a
    /// spinner) — the ENGINE is told separately, so a short overdub region can't auto-finalize
    /// while its backing is still being made.
    static func start(take: StudioTake, fromMs: Int = 0,
                      loopRegion: (startMs: Int, endMs: Int)? = nil, asBacking: Bool = false,
                      instruments: InstrumentEngine, studio: StudioStore,
                      packs: InstrumentPackStore,
                      preparing: @MainActor (Bool) -> Void = { _ in }) async -> StartOutcome {
        guard !take.allScoreEvents.isEmpty else { return .nothingToPlay }
        switch route(staffCount: take.staffCount, hasRender: take.isRenderFresh, asBacking: asBacking) {
        case .sampler:
            return startSingle(take: take, fromMs: fromMs, instruments: instruments, packs: packs)
        case .renderedAudio:
            return playRendered(takeId: take.id, take: take, fromMs: fromMs, loopRegion: loopRegion,
                                instruments: instruments, studio: studio, packs: packs)
        case .liveSamplers:
            // Multi-staff with a cold cache: render on demand, VISIBLY (`preparing`), and tell the
            // engine so a short overdub region can't auto-finalize while its backing is being made.
            preparing(true)
            instruments.setBackingPreparing(true)
            let r = await StudioTakeRenderer.ensureRendered(takeId: take.id, studio: studio, packs: packs)
            instruments.setBackingPreparing(false)
            preparing(false)
            guard r.hasRender else {
                // No mixdown: fall back to REAL-TIME per-staff samplers rather than to silence.
                NPLog.trace("studio: take play — no render (\(r)) tk=\(take.id), live samplers instead")
                return startLiveSamplers(take: take, fromMs: fromMs, loopRegion: loopRegion,
                                         instruments: instruments, packs: packs, renderOutcome: r)
            }
            return playRendered(takeId: take.id, take: take, fromMs: fromMs, loopRegion: loopRegion,
                                instruments: instruments, studio: studio, packs: packs)
        }
    }

    /// Resolve the take's fresh mixdown and hand it to the engine. The security scope goes WITH it
    /// (released here is the shipped "silent 0:00" bug); a cache that vanished off disk degrades to
    /// the real-time sampler pool.
    private static func playRendered(takeId: String, take: StudioTake, fromMs: Int,
                                     loopRegion: (startMs: Int, endMs: Int)?,
                                     instruments: InstrumentEngine, studio: StudioStore,
                                     packs: InstrumentPackStore) -> StartOutcome {
        guard let fresh = studio.take(takeId), fresh.isRenderFresh, let rf = fresh.renderedFileName,
              let got = StudioFolders.fileURL(family: .takes, fileName: rf,
                                              wasUserFolder: fresh.renderedWasUserFolder ?? false,
                                              bookmark: studio.bookmark(for: .takes)) else {
            NPLog.trace("studio: backing REFUSED unresolved tk=\(takeId) — the render is gone from disk")
            return startLiveSamplers(take: take, fromMs: fromMs, loopRegion: loopRegion,
                                     instruments: instruments, packs: packs, renderOutcome: nil)
        }
        let started = instruments.replayRenderedAudio(url: got.url, release: got.release,
                                                      fromMs: fromMs, forTake: takeId,
                                                      loopRegion: loopRegion)
        guard started.isAudible else {
            return .failed("Couldn’t play this instrumental’s audio (\(started.rawValue))."
                           + " Settings ▸ Debug ▸ capture has the reason.")
        }
        return .playing
    }

    /// The SHIPPED single-staff path, byte-for-byte what `StudioTakeReplay.toggle` always did:
    /// the take's own bank when it's downloaded, whatever IS loaded otherwise (wrong timbre beats
    /// a dead button), and `.needPack` only when the sampler holds nothing at all.
    static func startSingle(take: StudioTake, fromMs: Int, instruments: InstrumentEngine,
                            packs: InstrumentPackStore) -> StartOutcome {
        guard !take.scoreEvents.isEmpty else { return .nothingToPlay }
        if instruments.currentInstrument == take.instrument {
            instruments.replayTake(events: take.scoreEvents, instrument: take.instrument,
                                   fromMs: fromMs, forTake: take.id)
            return .playing
        }
        // Wrong (or no) instrument loaded: load the right bank first when it's downloaded.
        if let pack = packs.packs.first(where: { $0.instrument == take.instrument }),
           let url = packs.localBankURL(pack) {
            Task { @MainActor in
                _ = await instruments.loadInstrument(take.instrument, bankURL: url)
                instruments.replayTake(events: take.scoreEvents, instrument: take.instrument,
                                       fromMs: fromMs, forTake: take.id)
            }
            return .playing
        }
        // No bank for this instrument on disk. If SOMETHING is loaded, degrade to it
        // (audible, logged); with nothing loaded the sampler is silent — report that.
        if instruments.currentInstrument != nil {
            instruments.replayTake(events: take.scoreEvents, instrument: take.instrument,
                                   fromMs: fromMs, forTake: take.id)
            return .playing
        }
        return .needPack(take.instrument.displayName)
    }

    /// Real-time per-staff sampler fallback — used only when no mixdown can be produced.
    private static func startLiveSamplers(take: StudioTake, fromMs: Int,
                                          loopRegion: (startMs: Int, endMs: Int)?,
                                          instruments: InstrumentEngine, packs: InstrumentPackStore,
                                          renderOutcome: StudioTakeRenderer.RenderOutcome?)
        -> StartOutcome {
        var staffs: [(events: [StudioNoteEvent], instrument: InstrumentKey)] = []
        if !take.scoreEvents.isEmpty { staffs.append((take.scoreEvents, take.instrument)) }
        for st in take.extraStaffs ?? [] where !st.scoreEvents.isEmpty {
            staffs.append((st.scoreEvents, st.instrument))
        }
        guard !staffs.isEmpty else { return .nothingToPlay }
        guard let bank = StudioTakeReplay.bankURL(forInstruments: staffs.map(\.instrument),
                                                  packs: packs) else {
            if case .needPack(let name)? = renderOutcome { return .needPack(name) }
            return .needPack(take.instrument.displayName)
        }
        instruments.replayStaffsLive(staffs: staffs, bankURL: bank, fromMs: fromMs,
                                     forTake: take.id, loopRegion: loopRegion)
        return .playing
    }
}

// MARK: - Comping ↔ melody switch (F8 slice B)

/// Re-extracts a Demux instrumental take between chord-comping and true melody from its recorded
/// demux source, then REPLACES the take's events + flips its mode + re-renders. The ONE place the
/// take-context-menu switch happens (unit-tested at the store level). Comping reads the demux doc's
/// chords; melody reads the CACHED tracked notes (compute-once), tracking the vocals/other stem
/// on-demand only when the cache is empty — and surfacing a clear error when the stems are gone.
@MainActor
enum DemuxTakeSwitch {
    enum SwitchError: Error {
        case noSource        // the take carries no demuxSourceKey
        case noDoc           // the demux document is gone (source never demuxed / cache cleared)
        case noChords        // comping requested but the doc has no chords
        case noMelody        // melody tracked to nothing
        case needStems       // melody requested, no cached notes AND no local stems to track
    }

    /// The mode the switch would produce for `take` (the opposite of its current mode).
    static func targetMode(for take: StudioTake) -> String {
        (take.demuxMode == "melody") ? "comping" : "melody"
    }

    /// Perform the switch. Throws `SwitchError` (mapped to copy by `message(for:)`).
    static func switchMode(take: StudioTake, demux: DemuxStore, burns: BurnStore,
                           studio: StudioStore, packs: InstrumentPackStore) async throws {
        guard let key = take.demuxSourceKey else { throw SwitchError.noSource }
        guard let doc = demux.document(for: key) else { throw SwitchError.noDoc }
        let target = targetMode(for: take)
        let grid = await resolveGrid(key: key, burns: burns)

        let events: [StudioNoteEvent]
        if target == "comping" {
            guard !doc.chords.isEmpty else { throw SwitchError.noChords }
            events = DemuxInstrumental.events(chords: doc.chords, grid: grid).events
        } else {
            let notes: [DemuxMelodyNote]
            if let cached = doc.melodyNotes, !cached.isEmpty {
                notes = cached
            } else {
                guard let stem = resolveMelodyStem(key: key, burns: burns, demux: demux) else {
                    throw SwitchError.needStems
                }
                defer { stem.release?() }
                let url = stem.url
                let tracked = await Task.detached(priority: .utility) {
                    MelodyTracker.detect(melodyURL: url)
                }.value
                guard !tracked.isEmpty else { throw SwitchError.noMelody }
                // RE-FETCH the current doc after the multi-second YIN await — a concurrent Demuxer
                // analysis (chords / words / drumHits) for the SAME source may have landed while we
                // tracked, and saving the pre-await snapshot would clobber it. Cache just the melody
                // fields onto the fresh copy (the `DemuxStore.analyzeMelody` re-fetch discipline).
                var updated = demux.document(for: key) ?? doc
                updated.melodyNotes = tracked
                updated.melodyStatus = .done
                demux.save(updated)
                notes = tracked
            }
            events = DemuxInstrumental.melodyEvents(notes: notes, grid: grid).events
        }
        guard !events.isEmpty else {
            throw target == "comping" ? SwitchError.noChords : SwitchError.noMelody
        }
        studio.setTakeEvents(take.id, events: events)
        studio.setTakeDemuxMode(take.id, mode: target)
        await StudioTakeRenderer.ensureRendered(takeId: take.id, studio: studio, packs: packs)
    }

    /// The demux source's beat grid — a catalog song's beat-grid sidecar (measured lattice), else
    /// a steady 120-BPM grid at 0 (custom audio). ONLY catalog-song keys reach the network: a
    /// custom source (studio `smp_/lp_/ptn_/tk_` or imported `dmx_`) has no server-side sidecar, so
    /// firing `burnBeatGrid` for it just 404s/times-out before falling back. Short-circuiting on the
    /// song predicate matches `StudioDemuxView.resolveInstrumentalGrid` (which guards on `songId`)
    /// so the SAME take quantizes identically online and offline.
    static func resolveGrid(key: String, burns: BurnStore) async -> DemuxInstrumental.Grid {
        guard DemuxSource.isSongKey(key) else { return (120, 0, []) }
        var sc = burns.localBeatGrid(forSong: key)
        if sc == nil { sc = await burns.burnBeatGrid(forSong: key) }
        if let sc, let bpm = sc.beatGridBpm, bpm > 0 {
            return (bpm, sc.firstDownbeatMs ?? 0, sc.beatsMs)
        }
        return (120, 0, [])
    }

    /// The melodic stem (VOCALS, else `other`): a song's from the burn folder (its scope handed
    /// back via `release`), custom audio from the demux stems cache.
    static func resolveMelodyStem(key: String, burns: BurnStore, demux: DemuxStore)
        -> (url: URL, release: (() -> Void)?)? {
        if let stems = burns.localStemURLs(forSong: key),
           let url = stems.urls["vocals"] ?? stems.urls["other"] {
            return (url, stems.release)
        }
        if let stems = demux.localStemURLs(for: key),
           let url = stems["vocals"] ?? stems["other"] {
            return (url, nil)
        }
        return nil
    }

    static func message(for error: Error) -> String {
        switch error {
        case SwitchError.noSource:
            return "This instrumental wasn’t made in the Demuxer, so it can’t switch modes."
        case SwitchError.noDoc:
            return "The Demuxer data for this instrumental’s source is gone — re-open it in the Demuxer."
        case SwitchError.noChords:
            return "No chords were detected for this source, so there’s no comping to switch to."
        case SwitchError.noMelody:
            return "No clear melody could be tracked from this source’s stems."
        case SwitchError.needStems:
            return "Download this track’s stems first — the melody is tracked from the vocals (or “other”) stem."
        default:
            return "Couldn’t switch this instrumental’s mode."
        }
    }
}

// MARK: - Shared replay helper (takes list + score view)

/// Replay a take: a SINGLE staff through the sampler, loading the take's OWN instrument first
/// when its bank is on disk (score and sound should agree — spec §7), falling back to whatever
/// instrument is loaded (wrong timbre beats a dead button — the engine logs the mismatch); a
/// MULTI-STAFF take through its rendered mixdown (`StudioTakePlayback`), which is async because a
/// cold cache renders first. Returns false only when a single-staff replay is impossible right now
/// (no bank loaded AND none downloaded) so callers can point the user at the pack download —
/// multi-staff failures arrive on `onError` instead, since they can only be known after the render.
@MainActor
enum StudioTakeReplay {
    /// `fromMs` starts the replay part-way in — the score screen passes where its cursor was left
    /// (`resumeMs`) so tapping the sheet and then pressing Replay plays from there. The takes LIST
    /// leaves it 0: the parked cursor there could belong to a different instrumental entirely.
    ///
    /// Every replay is STAMPED with its take (`forTake:`), wherever it was started from — the row
    /// button here included. That stamp is what lets a score screen tell "my cursor" from "the
    /// clock of the instrumental someone started in the list", which it must, because remembering
    /// the wrong one is now durable.
    @discardableResult
    static func toggle(take: StudioTake, instruments: InstrumentEngine, studio: StudioStore,
                       packs: InstrumentPackStore, fromMs: Int = 0,
                       preparing: @escaping @MainActor (Bool) -> Void = { _ in },
                       onError: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        if instruments.isReplaying {
            instruments.stopReplay()
            return true
        }
        // Multi-staff: play the take's RENDERED MIXDOWN (each staff synthesized through its own
        // sampler offline, then mixed) — audio, not a live MIDI synth. Async because a cold cache
        // renders on demand; `preparing` drives the caller's spinner, and the outcome's message
        // feeds the alert this call site already shows.
        if take.staffCount > 1 {
            guard !take.allScoreEvents.isEmpty else { return true }
            Task { @MainActor in
                let outcome = await StudioTakePlayback.start(take: take, fromMs: fromMs,
                                                             instruments: instruments,
                                                             studio: studio, packs: packs,
                                                             preparing: preparing)
                if let msg = outcome.message { onError(msg) }
            }
            return true
        }
        guard !take.scoreEvents.isEmpty else { return true }   // nothing to play — not an error
        switch StudioTakePlayback.startSingle(take: take, fromMs: fromMs,
                                              instruments: instruments, packs: packs) {
        case .needPack: return false
        default: return true
        }
    }

    /// The same every-staff gate for an ARBITRARY staff list (the live score's overdub backing,
    /// where the staffs are in-memory `LiveStaff`s, not a saved take).
    static func bankURL(forInstruments instruments: [InstrumentKey],
                        packs: InstrumentPackStore) -> URL? {
        guard let first = instruments.first,
              let bank = packs.localBankURL(forInstrument: first) else { return nil }
        for inst in instruments.dropFirst() {
            guard packs.localBankURL(forInstrument: inst) != nil else { return nil }
        }
        return bank
    }

    /// Where Replay should START given the cursor currently parked on the score: FROM the cursor,
    /// unless it sits at (or past) the end of the take — in which case the take has been played
    /// through and ▶ means "again, from the top" rather than "play the silence after the last
    /// note". Pure + `nonisolated` so the rule is unit-tested, not eyeballed.
    nonisolated static func resumeMs(parkedMs: Int?, events: [StudioNoteEvent]) -> Int {
        guard let parkedMs, parkedMs > 0 else { return 0 }
        let end = events.map(\.offMs).max() ?? 0
        return parkedMs < end ? parkedMs : 0
    }
}
