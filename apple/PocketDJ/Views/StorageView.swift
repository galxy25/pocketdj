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

    @State private var showBurnFolderPicker = false
    @State private var showSessionFolderPicker = false
    /// Measured on appear + after every delete/prune (nil = not measured yet).
    @State private var burnedBytes: Int?
    @State private var recordingBytes: Int?
    @State private var confirmingDeleteAll = false
    @State private var confirmingDeleteRecordings = false

    var body: some View {
        Form {
            usageSection
            burnFolderSection
            sessionFolderSection
            capSection
            deleteMusicSection
            recordingsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
        .task { refreshUsage() }
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
