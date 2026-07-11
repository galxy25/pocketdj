import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Storage — the storage manager. One screen to (a) see what burned music and
/// session recordings cost on disk, (b) pick WHERE burns + session recordings live (the
/// two folder pickers, moved here from the Settings root), (c) delete downloaded music by
/// artist / by collection / all at once, (d) delete session recordings, and (e) set the
/// SOFT storage cap the once-a-day prune enforces (least-recently-played evicted first;
/// cap UNSET by default ⇒ the app never deletes anything on its own).
///
/// Every delete here removes DOWNLOADED media only — songs stay in the catalog and in
/// every pocket/playlist/set list, and can always be burned again later.
struct StorageView: View {
    @Bindable var settings: SettingsStore
    @Environment(BurnStore.self) private var burns
    @Environment(CollectionsStore.self) private var collections
    @Environment(MixSessionStore.self) private var mixSessions
    @Environment(MixRecorder.self) private var mixRecorder
    @Environment(StorageManager.self) private var storage
    // Performance studio (spec §3): the studio document store owns per-family usage/delete;
    // the mic recorder is consulted so a crash-orphaned capture is FILED before any sweep;
    // the pack store owns instrument-bank usage and re-syncs its disk view after a sweep.
    @Environment(StudioStore.self) private var studio
    @Environment(StudioMicRecorder.self) private var studioMic
    @Environment(InstrumentPackStore.self) private var packStore

    @State private var showBurnFolderPicker = false
    @State private var showSessionFolderPicker = false
    /// One shared importer serves the three studio folder pickers: the button stamps WHICH
    /// family is being picked, then presents. (Separate state from the bool so the importer's
    /// dismiss can never race the callback out of knowing its family.)
    @State private var showStudioFolderPicker = false
    @State private var studioPickerFamily: StudioFamily = .samples
    /// Measured on appear + after every delete/prune (nil = not measured yet).
    @State private var burnedBytes: Int?
    @State private var recordingBytes: Int?
    /// Per-family studio bytes (samples/loops/sequences/takes via StudioStore's strict-shape
    /// scan; instruments via InstrumentPackStore). Missing key = not measured yet.
    @State private var studioBytes: [StudioFamily: Int] = [:]
    @State private var confirmingDeleteAll = false
    @State private var confirmingDeleteRecordings = false
    /// Which studio family a delete-all confirmation is up for (nil = none).
    @State private var confirmingStudioDelete: StudioFamily?

    var body: some View {
        Form {
            usageSection
            burnFolderSection
            sessionFolderSection
            capSection
            deleteMusicSection
            recordingsSection
            // ViewBuilder tops out at 10 children — the studio area rides in one Group.
            Group {
                studioUsageSection
                studioFolderSection(.samples)
                studioFolderSection(.loops)
                studioFolderSection(.sequences)
                studioFolderSection(.takes)
                studioDeleteSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
        .task {
            // The studio store + mic recorder take their config pushed from the view layer
            // (the MixRecorder.settings pattern — their doc comments): the store needs the
            // per-family bookmarks for usage/delete across BOTH roots, and the recorder's
            // orphan recovery needs settings (samples-folder bookmark) + the store to file into.
            studio.settings = settings
            studioMic.settings = settings
            studioMic.store = studio
            refreshUsage()
        }
        // Burnt-music folder. [.folder] presents NSOpenPanel(canChooseDirectories) on macOS
        // and the directory document picker on iOS — one cross-platform call.
        .fileImporter(isPresented: $showBurnFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // The picked folder URL is security-scoped: hold access while creating the bookmark.
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = BurnStore.makeBookmark(for: url) {
                settings.burnFolderBookmark = data
                settings.persist()
                refreshUsage()
            }
        }
        // Mix SESSION folder — same cross-platform directory picker as the burnt-music folder.
        .fileImporter(isPresented: $showSessionFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = BurnStore.makeBookmark(for: url) {
                settings.sessionFolderBookmark = data
                settings.persist()
                refreshUsage()
            }
        }
        // Studio family folder (samples / loops / sequences — whichever button presented this).
        // Same scope dance: the picked URL is security-scoped, and bookmark creation needs the
        // scope LIVE, so hold it across the mint.
        .fileImporter(isPresented: $showStudioFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = BurnStore.makeBookmark(for: url) {
                setStudioBookmark(studioPickerFamily, data)
                // Persist NOW — nothing guarantees another persist() before quit on macOS, and
                // an un-persisted bookmark orphans every artifact written into the new folder.
                settings.persist()
                refreshUsage()
            }
        }
        // One dialog serves all five studio delete-all buttons; `presenting:` carries the family
        // so the confirm button gets its per-family a11y id (storage-delete-samples-confirm, …).
        .confirmationDialog(confirmingStudioDelete.map { "Delete all \(studioNoun($0))?" } ?? "",
                            isPresented: Binding(get: { confirmingStudioDelete != nil },
                                                 set: { if !$0 { confirmingStudioDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmingStudioDelete) { family in
            Button(studioConfirmTitle(family), role: .destructive) { performStudioDelete(family) }
                .accessibilityIdentifier("storage-delete-\(family.rawValue)-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { family in
            Text(studioDeleteMessage(family))
        }
    }

    // MARK: Usage

    private var readyBurnCount: Int { burns.items.values.filter { $0.state == .ready }.count }
    private var recordingCount: Int {
        mixSessions.sessions.reduce(0) { $0 + ($1.recordings?.count ?? 0) }
    }

    private var usageSection: some View {
        Section {
            HStack {
                Label("Burnt music", systemImage: "opticaldisc")
                Spacer()
                Text("\(readyBurnCount) song\(readyBurnCount == 1 ? "" : "s") · \(formatBytes(burnedBytes))")
                    .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    .accessibilityIdentifier("storage-usage-burns")
            }
            HStack {
                Label("Session recordings", systemImage: "waveform")
                Spacer()
                Text("\(recordingCount) take\(recordingCount == 1 ? "" : "s") · \(formatBytes(recordingBytes))")
                    .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    .accessibilityIdentifier("storage-usage-recordings")
            }
        } header: {
            Text("On this device")
        } footer: {
            Text("Burnt music counts everything a burn downloads: audio, per-song cuts, stems, beat grids, and metadata sidecars — across the app's storage and your chosen folder.")
        }
    }

    private func refreshUsage() {
        burnedBytes = burns.burnedUsageBytes()
        recordingBytes = SessionFolders.recordingsUsageBytes(bookmark: settings.sessionFolderBookmark)
        // Performance studio families — strict-shape scans across both roots (a user's own
        // co-located files never count). Instrument banks are owned by the pack store.
        for family in StudioFamily.allCases {
            studioBytes[family] = family == .instruments
                ? packStore.usageBytes
                : studio.usageBytes(family: family)
        }
    }

    private func formatBytes(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Burnt-music folder (moved from the Settings root)

    /// A user-pickable folder for burnt audio + sidecars, so the files are browsable in
    /// Finder (macOS) / the Files app (iOS). Stored as a security-scoped bookmark; unset
    /// falls back to the app-managed Application Support `burns/` dir (not user-browsable).
    private var burnFolderSection: some View {
        Section {
            Button { showBurnFolderPicker = true } label: {
                Label("Choose burnt-music folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("settings-burn-folder-pick")
            if let name = folderName(for: settings.burnFolderBookmark) {
                HStack {
                    Label(name, systemImage: "folder")
                        .font(.caption).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("settings-burn-folder-path")
                    Spacer()
                    Button("Use app storage", role: .destructive) {
                        settings.burnFolderBookmark = nil
                        settings.persist()
                        refreshUsage()
                    }
                    .font(.caption)
                    .accessibilityIdentifier("settings-burn-folder-reset")
                }
            }
        } header: {
            Text("Burnt music folder")
        } footer: {
            Text("Where burnt audio + their `.txt` sidecars are saved. Pick a folder to browse the files yourself in \(browseAppName). Leave unset to keep them in the app’s private storage.")
        }
    }

    // MARK: Mix session folder (moved from the Settings root)

    /// A user-pickable folder for mix SESSION data — recorded audio (and future per-session
    /// files), one subfolder per session — so recordings are browsable in Finder / the Files
    /// app. Stored as a security-scoped bookmark; unset falls back to the app-managed
    /// `mix-sessions/` dir. See `SessionFolders` / `MixRecorder`.
    private var sessionFolderSection: some View {
        Section {
            Button { showSessionFolderPicker = true } label: {
                Label("Choose session folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("settings-session-folder-pick")
            if let name = folderName(for: settings.sessionFolderBookmark) {
                HStack {
                    Label(name, systemImage: "folder")
                        .font(.caption).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("settings-session-folder-path")
                    Spacer()
                    Button("Use app storage", role: .destructive) {
                        settings.sessionFolderBookmark = nil
                        settings.persist()
                        refreshUsage()
                    }
                    .font(.caption)
                    .accessibilityIdentifier("settings-session-folder-reset")
                }
            }
        } header: {
            Text("Mix sessions folder")
        } footer: {
            Text("Where each mix session's recorded audio is saved (one folder per session). Pick a folder to browse the recordings yourself in \(browseAppName). Leave unset to keep them in the app’s private storage.")
        }
    }

    /// The display name of a chosen folder (resolved read-only from its bookmark), or nil
    /// when none is set (app-storage fallback).
    private func folderName(for bookmark: Data?) -> String? {
        guard let data = bookmark else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: opts,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return "Chosen folder (unavailable)"
        }
        return url.lastPathComponent
    }

    private var browseAppName: String {
        #if os(macOS)
        return "Finder"
        #else
        return "the Files app"
        #endif
    }

    // MARK: Soft cap (unset by default ⇒ no automatic management)

    private var capSection: some View {
        Section {
            if let cap = settings.storageSoftCapGB {
                Stepper(value: capGBBinding, in: 1...2000, step: 1) {
                    HStack {
                        Text("Soft cap")
                        Spacer()
                        Text("\(Int(cap)) GB")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("storage-cap-stepper")
                HStack {
                    Button("Prune now") {
                        storage.pruneNow()
                        refreshUsage()
                    }
                    .accessibilityIdentifier("storage-prune-now")
                    Spacer()
                    Button("Remove cap", role: .destructive) {
                        settings.storageSoftCapGB = nil
                        settings.persist()
                    }
                    .accessibilityIdentifier("storage-cap-remove")
                }
                if let r = storage.lastResult {
                    Text(r.evicted == 0
                         ? "Already under the cap — nothing pruned."
                         : "Pruned \(r.evicted) song\(r.evicted == 1 ? "" : "s") · freed \(formatBytes(r.freedBytes)).")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("storage-prune-result")
                } else if let last = settings.lastStoragePruneAt {
                    Text("Last checked \(Date(timeIntervalSince1970: last / 1000).formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    // Start the cap at the CURRENT footprint rounded up, so setting it
                    // never marks already-downloaded music for immediate eviction.
                    let usedGB = Double(burnedBytes ?? burns.burnedUsageBytes()) / StorageManager.bytesPerGB
                    settings.storageSoftCapGB = max(1, usedGB.rounded(.up))
                    settings.persist()
                } label: {
                    Label("Set a soft cap…", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .accessibilityIdentifier("storage-cap-set")
            }
        } header: {
            Text("Soft storage cap")
        } footer: {
            Text(settings.storageSoftCapGB == nil
                 ? "No cap is set, so the app never deletes music on its own — storage is yours to manage with the tools below. Set a cap to have the app keep burnt music under a size for you."
                 : "Once a day the app prunes burnt music — least-recently-played first — until it fits under the cap. Only downloaded files are removed; every song stays in your library and can be burned again.")
        }
    }

    private var capGBBinding: Binding<Double> {
        Binding(get: { settings.storageSoftCapGB ?? 1 },
                set: {
                    // A stray stepper tick landing after "Remove cap" must not
                    // resurrect the cap (and re-arm auto-pruning).
                    guard settings.storageSoftCapGB != nil else { return }
                    settings.storageSoftCapGB = $0
                    settings.persist()
                })
    }

    // MARK: Delete downloaded music

    private var deleteMusicSection: some View {
        Section {
            NavigationLink {
                StorageArtistsView(onChanged: refreshUsage)
            } label: {
                Label("Delete by artist…", systemImage: "music.microphone")
            }
            .accessibilityIdentifier("storage-delete-by-artist")
            .disabled(readyBurnCount == 0)
            NavigationLink {
                StorageCollectionsView(onChanged: refreshUsage)
            } label: {
                Label("Delete by collection…", systemImage: "square.stack")
            }
            .accessibilityIdentifier("storage-delete-by-collection")
            .disabled(readyBurnCount == 0)
            Button(role: .destructive) { confirmingDeleteAll = true } label: {
                Label("Delete all burnt music", systemImage: "trash")
            }
            .accessibilityIdentifier("storage-delete-all-burns")
            // Enabled while ANYTHING remains clearable — ready burns, stuck ledger
            // entries, or stray on-disk bytes (orphan stems) the sweep can remove.
            .disabled(readyBurnCount == 0 && burns.items.isEmpty && (burnedBytes ?? 0) == 0)
            .confirmationDialog("Delete all burnt music?",
                                isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete downloaded music", role: .destructive) {
                    burns.removeAllBurns()
                    refreshUsage()
                }
                .accessibilityIdentifier("storage-delete-all-burns-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every downloaded file — audio, cuts, stems, beat grids, sidecars — from this device. Your library and collections are untouched; burn anything again anytime.")
            }
        } header: {
            Text("Downloaded music")
        } footer: {
            Text("Deleting removes downloaded files from this device only — never a song from your library, or from any pocket, playlist, or set list.")
        }
    }

    // MARK: Session recordings

    private var recordingsSection: some View {
        Section {
            Button(role: .destructive) { confirmingDeleteRecordings = true } label: {
                Label("Delete session recordings", systemImage: "trash")
            }
            .accessibilityIdentifier("storage-delete-recordings")
            .disabled(recordingCount == 0 && (recordingBytes ?? 0) == 0)
            .confirmationDialog("Delete all session recordings?",
                                isPresented: $confirmingDeleteRecordings, titleVisibility: .visible) {
                Button("Delete recordings", role: .destructive) {
                    // File any still-unrecovered crash orphan FIRST: the sweep also removes stray
                    // `.m4a`s by design, and a take the user has never SEEN (crash before this
                    // launch's recovery reached its root) must not be silently destroyed by a
                    // delete aimed at old takes.
                    mixRecorder.recoverOrphans()
                    let active = mixRecorder.activeTake
                    mixSessions.deleteAllRecordings(bookmark: settings.sessionFolderBookmark,
                                                    skippingSessionId: active?.sessionId,
                                                    skippingFileName: active?.fileName)
                    refreshUsage()
                }
                .accessibilityIdentifier("storage-delete-recordings-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(mixRecorder.isRecording
                     ? "Removes every captured take's audio file (the recording currently in progress is kept). Session logs are kept — only the audio is deleted."
                     : "Removes every captured take's audio file from this device. Session logs are kept — only the audio is deleted.")
            }
        } header: {
            Text("Session recordings")
        } footer: {
            Text("Captured mix audio (one folder per session). Deleting keeps each session's played-tracks log and timeline — only the recordings go.")
        }
    }

    // MARK: Performance studio (spec §3)

    /// What the Performance tab keeps on disk, one row per family. Samples/loops/sequences/
    /// takes are USER-CREATED content — the soft cap above never touches them; instrument
    /// packs are re-downloadable sound banks.
    private var studioUsageSection: some View {
        Section {
            studioUsageRow(.samples, label: "Samples", icon: "waveform",
                           count: studio.samples.count, unit: "sample")
            studioUsageRow(.loops, label: "Loops", icon: "repeat",
                           count: studio.loops.count, unit: "loop")
            studioUsageRow(.sequences, label: "Sequences", icon: "square.grid.4x3.fill",
                           count: studio.patterns.count, unit: "sequence")
            studioUsageRow(.takes, label: "Instrumentals", icon: "recordingtape",
                           count: studio.takes.count, unit: "instrumental")
            studioUsageRow(.instruments, label: "Instrument packs", icon: "pianokeys",
                           count: packStore.downloadedSlugs.count, unit: "bank")
        } header: {
            Text("Performance studio")
        } footer: {
            Text("Samples, loops, sequences, and instrumentals are things you made — the app never deletes them on its own (the soft cap above prunes burnt music only). Instrument packs are sound banks you can download again anytime.")
        }
    }

    private func studioUsageRow(_ family: StudioFamily, label: String, icon: String,
                                count: Int, unit: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text("\(count) \(unit)\(count == 1 ? "" : "s") · \(formatBytes(studioBytes[family]))")
                .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                .accessibilityIdentifier("storage-usage-\(family.rawValue)")
        }
    }

    /// One user-pickable folder per relocatable studio family (samples / loops / sequences /
    /// instrumentals), cloned from `sessionFolderSection`: choose → security-scoped bookmark
    /// persisted NOW; "Use app storage" resets to the app-managed `studio/<family>/` dir. Instrument
    /// packs are always app-managed (spec §3) and get no picker.
    private func studioFolderSection(_ family: StudioFamily) -> some View {
        Section {
            Button {
                studioPickerFamily = family
                showStudioFolderPicker = true
            } label: {
                Label("Choose \(familyNoun(family)) folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("storage-\(family.rawValue)-folder-choose")
            if let name = folderName(for: studioBookmark(family)) {
                HStack {
                    Label(name, systemImage: "folder")
                        .font(.caption).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("storage-\(family.rawValue)-folder-path")
                    Spacer()
                    Button("Use app storage", role: .destructive) {
                        setStudioBookmark(family, nil)
                        settings.persist()
                        refreshUsage()
                    }
                    .font(.caption)
                    .accessibilityIdentifier("storage-\(family.rawValue)-folder-reset")
                }
            }
        } header: {
            Text("\(familyNoun(family).capitalized) folder")
        } footer: {
            Text("Where new \(familyNoun(family)) are saved (\(studioFileShape(family))). Pick a folder to browse the files yourself in \(browseAppName). Leave unset to keep them in the app’s private storage. Files already saved stay in the folder they were written to.")
        }
    }

    /// User-facing plural noun for a relocatable family — takes read as "instrumentals" per the
    /// product naming (the internal `.takes` rawValue stays `take`/`takes`).
    private func familyNoun(_ family: StudioFamily) -> String {
        family == .takes ? "instrumentals" : family.rawValue
    }

    /// The deterministic file shape a family writes — shown in the folder footers so a user
    /// browsing their picked folder knows which files are the app's.
    private func studioFileShape(_ family: StudioFamily) -> String {
        family.filePrefix + "…." + family.fileExtension
    }

    /// The user-picked folder bookmark for a relocatable family. Instrument packs are always
    /// app-managed (spec §3) — nil keeps `StudioFolders`' no-bookmark assert honest.
    private func studioBookmark(_ family: StudioFamily) -> Data? {
        switch family {
        case .samples: return settings.samplesFolderBookmark
        case .loops: return settings.loopsFolderBookmark
        case .sequences: return settings.sequencesFolderBookmark
        case .takes: return settings.takesFolderBookmark
        case .instruments: return nil
        }
    }

    private func setStudioBookmark(_ family: StudioFamily, _ data: Data?) {
        switch family {
        case .samples: settings.samplesFolderBookmark = data
        case .loops: settings.loopsFolderBookmark = data
        case .sequences: settings.sequencesFolderBookmark = data
        case .takes: settings.takesFolderBookmark = data
        case .instruments: assertionFailure("instrument packs are always app-managed")
        }
    }

    /// Delete-all per studio family, each behind its own confirmation (the shared dialog on
    /// the Form). Records whose user folder is unreachable right now are KEPT by the store —
    /// nothing is ever pruned that wasn't provably deleted.
    private var studioDeleteSection: some View {
        Section {
            studioDeleteButton(.samples, title: "Delete all samples")
            studioDeleteButton(.loops, title: "Delete all loops")
            studioDeleteButton(.sequences, title: "Delete all sequences")
            studioDeleteButton(.takes, title: "Delete all instrumentals")
            studioDeleteButton(.instruments, title: "Delete instrument packs")
        } header: {
            Text("Delete studio content")
        } footer: {
            Text("Deletes remove files from this device only. Content saved in a folder that isn’t reachable right now (an unplugged drive or offline location) is kept, never lost.")
        }
    }

    private func studioDeleteButton(_ family: StudioFamily, title: String) -> some View {
        Button(role: .destructive) { confirmingStudioDelete = family } label: {
            Label(title, systemImage: "trash")
        }
        .accessibilityIdentifier("storage-delete-\(family.rawValue)")
        // Enabled while ANYTHING remains clearable — records, or stray on-disk bytes (a
        // crash-orphaned capture, a never-filed file) the strict-shape sweep can remove.
        .disabled(studioCount(family) == 0 && (studioBytes[family] ?? 0) == 0)
    }

    private func studioCount(_ family: StudioFamily) -> Int {
        switch family {
        case .samples: return studio.samples.count
        case .loops: return studio.loops.count
        case .sequences: return studio.patterns.count
        case .takes: return studio.takes.count
        case .instruments: return packStore.downloadedSlugs.count
        }
    }

    /// Plural noun for dialog titles ("Delete all samples?" … "Delete all instrument packs?").
    private func studioNoun(_ family: StudioFamily) -> String {
        switch family {
        case .samples: return "samples"
        case .loops: return "loops"
        case .sequences: return "sequences"
        case .takes: return "instrumentals"
        case .instruments: return "instrument packs"
        }
    }

    private func studioConfirmTitle(_ family: StudioFamily) -> String {
        switch family {
        case .samples: return "Delete samples"
        case .loops: return "Delete loops"
        case .sequences: return "Delete sequences"
        case .takes: return "Delete instrumentals"
        case .instruments: return "Delete packs"
        }
    }

    /// Data-safety copy per family — spells out exactly what survives (rendered loops keep
    /// playing, pattern rows fall silent, take-derived samples are copies, packs re-download).
    private func studioDeleteMessage(_ family: StudioFamily) -> String {
        switch family {
        case .samples:
            let base = "Removes every sample’s audio and record from this device. Loops already rendered from a sample keep playing but can’t be re-sliced; sequencer rows that used one fall silent."
            return studioMic.isRecording ? base + " The capture in progress is kept." : base
        case .loops:
            return "Removes every loop’s rendered audio and record. Sequencer rows that used a loop fall silent; the samples they were sliced from are untouched."
        case .sequences:
            return "Removes every sequencer pattern and its bounced audio. The samples and loops the patterns played are untouched."
        case .takes:
            return "Removes every instrumental — the audio and the score that goes with it. Samples you made from an instrumental are separate copies and are untouched."
        case .instruments:
            return "Removes downloaded sound banks from this device. Packs stay listed and can be downloaded again anytime."
        }
    }

    private func performStudioDelete(_ family: StudioFamily) {
        // Crash-orphaned mic captures live in the SAMPLES roots with no record yet. File them
        // FIRST (the MixRecorder recoverOrphans-before-sweep doctrine) so the wipe below
        // deletes them deliberately, records and all — never a silent sweep of a take the
        // user has never seen. (The store itself skips the recorder's ACTIVE open file.)
        if family == .samples { studioMic.recoverOrphans() }
        studio.deleteAll(family: family)
        if family == .instruments {
            // The store swept the bank FILES (the app-managed instruments root; the file IS
            // the pack ledger) — re-read the disk so pack rows flip back to downloadable.
            packStore.rescanDownloads()
        }
        refreshUsage()
    }
}

// MARK: - Delete by artist

/// Burned music grouped by artist — tap a row to delete that artist's downloaded files.
/// Bytes are approximate: an analog album's shared mp3 is counted once per group and only
/// leaves the disk when its last remaining song (any artist) is deleted.
struct StorageArtistsView: View {
    @Environment(BurnStore.self) private var burns
    /// Parent's usage refresh, called after any delete.
    var onChanged: () -> Void = {}

    @State private var pending: BurnStore.ArtistUsage?

    var body: some View {
        Group {
            let rows = burns.usageByArtist()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No burnt music", systemImage: "opticaldisc")
                } description: {
                    Text("Burn a collection or song and it'll show up here by artist.")
                }
            } else {
                List(rows) { row in
                    Button { pending = row } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.artist).foregroundStyle(Theme.fg)
                                Text("\(row.songIds.count) song\(row.songIds.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "trash").foregroundStyle(Theme.danger).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("storage-artist-row")
                }
                .scrollContentBackground(.hidden).background(Theme.bg)
            }
        }
        .navigationTitle("Delete by artist")
        .confirmationDialog(pending.map { "Delete \($0.artist)?" } ?? "",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { row in
            Button("Delete \(row.songIds.count) downloaded song\(row.songIds.count == 1 ? "" : "s")",
                   role: .destructive) {
                burns.removeBurns(songIds: row.songIds)
                onChanged()
            }
            .accessibilityIdentifier("storage-artist-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Removes \(row.artist)'s downloaded files from this device. The songs stay in your library and can be burned again.")
        }
    }
}

// MARK: - Delete by collection

/// The user's collections (pockets · playlists · set lists) with how much burned music each
/// one accounts for — tap to delete those songs' downloaded files. Only collections with at
/// least one burned song are listed. A song shared by another collection is still deleted
/// (the delete is by song, not by membership); it can always be burned again.
struct StorageCollectionsView: View {
    @Environment(BurnStore.self) private var burns
    @Environment(CollectionsStore.self) private var collections
    var onChanged: () -> Void = {}

    /// One deletable row: a collection's burned songs.
    struct Row: Identifiable, Equatable {
        let id: String        // "<kind>:<collectionId>"
        let kind: String      // "Pocket" | "Playlist" | "Set list"
        let name: String
        let songIds: [String] // the BURNED subset
        let bytes: Int
    }

    @State private var pending: Row?

    var body: some View {
        Group {
            let sections = makeSections()
            if sections.allSatisfy({ $0.rows.isEmpty }) {
                ContentUnavailableView {
                    Label("Nothing to delete", systemImage: "square.stack")
                } description: {
                    Text("No collection has burnt music on this device yet.")
                }
            } else {
                List {
                    ForEach(sections, id: \.title) { section in
                        if !section.rows.isEmpty {
                            Section(section.title) {
                                ForEach(section.rows) { row in rowView(row) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden).background(Theme.bg)
            }
        }
        .navigationTitle("Delete by collection")
        .confirmationDialog(pending.map { "Delete \($0.name)'s downloads?" } ?? "",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { row in
            Button("Delete \(row.songIds.count) downloaded song\(row.songIds.count == 1 ? "" : "s")",
                   role: .destructive) {
                burns.removeBurns(songIds: row.songIds)
                onChanged()
            }
            .accessibilityIdentifier("storage-collection-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Removes the downloaded files for the songs in this \(row.kind.lowercased()) from this device. The \(row.kind.lowercased()) itself — and every song in it — is untouched and can be burned again.")
        }
    }

    private func rowView(_ row: Row) -> some View {
        Button { pending = row } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).foregroundStyle(Theme.fg)
                    Text("\(row.songIds.count) burned song\(row.songIds.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "trash").foregroundStyle(Theme.danger).font(.caption)
            }
        }
        .accessibilityIdentifier("storage-collection-row")
    }

    private func makeSections() -> [(title: String, rows: [Row])] {
        func row(kind: String, id: String, name: String, allIds: [String]) -> Row? {
            let burned = burns.readyBurnedIds(in: Array(Set(allIds)))
            guard !burned.isEmpty else { return nil }
            return Row(id: "\(kind):\(id)", kind: kind, name: name, songIds: burned,
                       bytes: burns.approximateBytes(forSongs: burned))
        }
        let pockets = collections.pockets.compactMap {
            row(kind: "Pocket", id: $0.id, name: $0.name, allIds: collections.songIds(forPocket: $0.id))
        }
        let playlists = collections.playlists.compactMap {
            row(kind: "Playlist", id: $0.id, name: $0.name, allIds: collections.songIds(forPlaylist: $0.id))
        }
        let setlists = collections.setlists.compactMap {
            row(kind: "Set list", id: $0.id, name: $0.name ?? "Set list",
                allIds: collections.songIds(forSetlist: $0.id))
        }
        return [("Pockets", pockets), ("Playlists", playlists), ("Set lists", setlists)]
    }
}
