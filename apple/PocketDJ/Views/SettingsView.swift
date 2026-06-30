import SwiftUI
import UniformTypeIdentifiers

/// Settings — mirrors the PWA's: data sources, online-search credentials, the
/// rip-server config, an Edits export/import, plus a nuclear reset. No refresh /
/// data-migration controls: the App Store ships those with each new version.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(CollectionsStore.self) private var collections
    // Not private: read by the streamingSection in SettingsView+Streaming.swift.
    @Environment(StreamingStore.self) var streaming
    @Environment(MusicSyncClient.self) private var musicSync

    @State private var ripTesting = false
    @State private var ripStatus: RipStatus?
    @State private var syncing = false
    @State private var syncStatus: SyncStatus?
    @State private var confirmingReset = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showCollectionsImporter = false
    @State private var showBurnFolderPicker = false
    @State private var exportDoc = EditsFile(data: Data())

    // Full backup (.pocketdj.zip)
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupDoc = PlaylistZipFile(data: Data())
    @State private var backupSummary: String?

    enum RipStatus { case ok(String), bad(String) }
    enum SyncStatus { case ok(String), bad(String) }

    var body: some View {
        Form {
            sourcesSection
            streamingSection
            searchSection
            ripSection
            mixSection
            appleMusicSyncSection
            burnFolderSection
            editsSection
            collectionsSection
            backupSection
            resetSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .json,
                      defaultFilename: "pocketdj-edits") { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                try? edits.importData(data)
                app.applyEdits()
            }
        }
        .fileImporter(isPresented: $showCollectionsImporter, allowedContentTypes: [.json, .zip]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try? collections.importAny(url: url)
        }
        .fileExporter(isPresented: $showBackupExporter, document: backupDoc, contentType: .zip,
                      defaultFilename: "PocketDJ Backup.pocketdj") { _ in }
        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { importBackup(data) }
        }
        .alert("Backup imported", isPresented: Binding(get: { backupSummary != nil }, set: { if !$0 { backupSummary = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(backupSummary ?? "") }
        // Feature 2 — burnt-music folder. [.folder] presents NSOpenPanel(canChooseDirectories)
        // on macOS and the directory document picker on iOS — one cross-platform call.
        .fileImporter(isPresented: $showBurnFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // The picked folder URL is security-scoped: hold access while creating the bookmark.
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = BurnStore.makeBookmark(for: url) {
                settings.burnFolderBookmark = data
                settings.persist()
            }
        }
    }

    // MARK: Burnt-music folder (Feature 2)

    /// A user-pickable folder for burnt audio + sidecars, so the files are browsable in
    /// Finder (macOS) / the Files app (iOS). Stored as a security-scoped bookmark; unset
    /// falls back to the app-managed Application Support `burns/` dir (not user-browsable).
    private var burnFolderSection: some View {
        Section {
            Button { showBurnFolderPicker = true } label: {
                Label("Choose burnt-music folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("settings-burn-folder-pick")
            if let name = burnFolderName {
                HStack {
                    Label(name, systemImage: "folder")
                        .font(.caption).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("settings-burn-folder-path")
                    Spacer()
                    Button("Use app storage", role: .destructive) {
                        settings.burnFolderBookmark = nil
                        settings.persist()
                    }
                    .font(.caption)
                    .accessibilityIdentifier("settings-burn-folder-reset")
                }
            }
        } header: {
            Text("Burnt music")
        } footer: {
            Text("Where burnt audio + their `.txt` sidecars are saved. Pick a folder to browse the files yourself in \(browseAppName). Leave unset to keep them in the app’s private storage.")
        }
    }

    /// The display name of the currently-chosen burnt-music folder (resolved read-only from
    /// the bookmark), or nil when none is set (app-storage fallback).
    private var burnFolderName: String? {
        guard let data = settings.burnFolderBookmark else { return nil }
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

    // MARK: Backup (full .pocketdj.zip — collections + sources + edits)

    private var backupSection: some View {
        Section {
            Button {
                if let data = try? makeBackup() { backupDoc = PlaylistZipFile(data: data); showBackupExporter = true }
            } label: { Label("Export backup…", systemImage: "square.and.arrow.up.on.square") }
                .accessibilityIdentifier("backup-export")
            Button { showBackupImporter = true } label: {
                Label("Import backup…", systemImage: "square.and.arrow.down.on.square")
            }
                .accessibilityIdentifier("backup-import")
        } header: {
            Text("Backup")
        } footer: {
            Text("A full `.pocketdj.zip` — your pockets, playlists, set lists, sources, and metadata edits. The remote catalog (songs/albums + cover art) is NOT bundled (it re-seeds from the same index), so this is portable across your devices and interchangeable with the web app’s export. Import merges everything in under fresh ids (never overwrites).")
        }
    }

    /// Build the full-backup bytes from all three stores.
    private func makeBackup() throws -> Data {
        try BackupZip.export(sources: settings.sources,
                             pockets: collections.pockets,
                             playlists: collections.playlists,
                             setlists: collections.setlists,
                             folders: collections.folders,
                             editsData: try edits.exportData())
    }

    /// Import a full backup: merge collections (fresh ids) + edits, and adopt any new
    /// sources. Catalog (items/art) in the zip is ignored. Surfaces a summary alert.
    private func importBackup(_ data: Data) {
        guard let (payload, skipped) = try? BackupZip.import(data: data) else { return }
        let c = collections.mergeBackupCollections(pockets: payload.pockets,
                                                   playlists: payload.playlists,
                                                   setlists: payload.setlists,
                                                   folders: payload.folders)
        let addedSources = settings.addSources(payload.sources)
        if let ed = payload.editsData { try? edits.importData(ed); app.applyEdits() }
        if addedSources > 0 { Task { await app.reload() } }

        var parts = ["\(c.pockets) pocket\(c.pockets == 1 ? "" : "s")",
                     "\(c.playlists) playlist\(c.playlists == 1 ? "" : "s")",
                     "\(c.setlists) set list\(c.setlists == 1 ? "" : "s")",
                     "\(addedSources) source\(addedSources == 1 ? "" : "s")"]
        if skipped.items > 0 || skipped.art > 0 {
            parts.append("skipped \(skipped.items) catalog item\(skipped.items == 1 ? "" : "s") + \(skipped.art) cover\(skipped.art == 1 ? "" : "s") (resolved remotely)")
        }
        backupSummary = parts.joined(separator: ", ") + "."
    }

    // MARK: Collections (import a pocket / playlist export)

    private var collectionsSection: some View {
        Section {
            Button { showCollectionsImporter = true } label: {
                Label("Import pocket / playlist…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("collections-import")
        } header: {
            Text("Collections")
        } footer: {
            Text("\(collections.pockets.count) pocket\(collections.pockets.count == 1 ? "" : "s"), \(collections.playlists.count) playlist\(collections.playlists.count == 1 ? "" : "s"). Import a single pocket or playlist exported from another device — fresh ids are minted so it never overwrites an existing one. Export from an item’s detail-view ▸ menu.")
        }
    }

    // MARK: Edits (export / import)

    private var editsSection: some View {
        Section {
            Button {
                if let data = try? edits.exportData() { exportDoc = EditsFile(data: data); showExporter = true }
            } label: { Label("Export edits…", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("edits-export")
                .disabled(edits.count == 0)
            Button { showImporter = true } label: { Label("Import edits…", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("edits-import")
        } header: {
            Text("Edits")
        } footer: {
            Text("\(edits.count) local metadata edit\(edits.count == 1 ? "" : "s"). Export to JSON (schema v\(editsSchemaVersion)) to merge into the main index on the iMac; Import merges another export in.")
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            ForEach($settings.sources) { $source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $source.name)
                            .pocketField()
                        Toggle("", isOn: $source.enabled).labelsHidden()
                        Button(role: .destructive) {
                            settings.removeSource(source.id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings-source-remove")
                    }
                    TextField("Index URL", text: $source.urlString)
                        .pocketField()
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                .padding(.vertical, 2)
            }
            Button { settings.addSource() } label: { Label("Add source", systemImage: "plus") }
                .accessibilityIdentifier("settings-add-source")
            if !settings.hasAppleMusic {
                Button {
                    settings.loadAppleMusic()
                    Task { await app.reload() }
                } label: { Label("Load Apple Music (Local) library", systemImage: "music.note.house") }
                    .accessibilityIdentifier("settings-load-apple-music")
            }
            Button {
                settings.persist()
                Task { await app.reload() }
            } label: { Label("Reload catalog", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("settings-reload")
        } header: {
            Text("Data sources")
        } footer: {
            Text("Choose which sources to show across the app. Each is a PocketDJ index URL served from CloudFront/S3.")
        }
    }

    // MARK: Streaming accounts (Spotify, …) — defined in SettingsView+Streaming.swift

    // MARK: Online search

    private var searchSection: some View {
        Section {
            TextField("Access key ID", text: $settings.searchAccessKeyID)
                .pocketField()
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-search-akid")
            SecureField("Secret access key", text: $settings.searchSecretKey)
                .pocketField()
                .accessibilityIdentifier("settings-search-secret")
            TextField("Endpoint (optional)", text: $settings.searchEndpoint)
                .pocketField()
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            HStack {
                Button("Save") { settings.persist() }
                    .accessibilityIdentifier("settings-search-save")
                Spacer()
                Button("Clear", role: .destructive) {
                    settings.searchAccessKeyID = ""; settings.searchSecretKey = ""
                    settings.searchEndpoint = ""; settings.persist()
                }
                if settings.searchConfigured {
                    Label("Configured", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                }
            }
        } header: {
            Text("Online search (OpenSearch)")
        } footer: {
            Text("Enables full-text search across the whole collection. Leave blank to stay fully offline.")
        }
    }

    // MARK: Mix (auto-mix)

    /// Auto-Mix crossfade timing: when to start fading before a track ends, and how long the
    /// fade (volume sweep) lasts. Whole-second steppers — the engine reads these the moment an
    /// auto-mix starts. Persisted on change.
    private var mixSection: some View {
        Section {
            Stepper(value: $settings.autoMixLeadSeconds, in: 3...60, step: 1) {
                HStack {
                    Text("Crossfade lead")
                    Spacer()
                    Text("\(Int(settings.autoMixLeadSeconds)) s")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-automix-lead")
            .onChange(of: settings.autoMixLeadSeconds) { settings.persist() }

            Stepper(value: $settings.autoMixFadeSeconds, in: 1...12, step: 1) {
                HStack {
                    Text("Crossfade length")
                    Spacer()
                    Text("\(Int(settings.autoMixFadeSeconds)) s")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-automix-fade")
            .onChange(of: settings.autoMixFadeSeconds) { settings.persist() }

            Stepper(value: $settings.skipFadeSeconds, in: 1...60, step: 1) {
                HStack {
                    Text("Skip fade")
                    Spacer()
                    Text("\(Int(settings.skipFadeSeconds)) s")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-automix-skip-fade")
            .onChange(of: settings.skipFadeSeconds) { settings.persist() }

            Toggle("Auto-hide played tracks", isOn: $settings.mixAutoHidePlayed)
                .accessibilityIdentifier("settings-mix-autohide")
                .onChange(of: settings.mixAutoHidePlayed) { settings.persist() }
        } header: {
            Text("Mix")
        } footer: {
            Text("In the Mix tab's Auto mode, the app plays a pocket or set list end-to-end, beginning each crossfade this many seconds before a track ends and sweeping the volume from one deck to the next over the fade length. Skip fade is how long the crossfade lasts when you tap the Skip button (double-tap always uses a fast 5 s sweep).\n\nA mix session records what you play until you hit Reset. When Auto-hide played tracks is on, the deck loader hides tracks you've already played this session; off, they still show with a ✓.")
        }
    }

    // MARK: Rip server

    private var ripSection: some View {
        Section {
            TextField("Rip server URL", text: $settings.ripServerURL)
                .pocketField()
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-rip-url")
            TextField("Token (optional)", text: $settings.ripToken)
                .pocketField()
                .accessibilityIdentifier("settings-rip-token")
            Toggle("Rip from cloud source", isOn: $settings.ripFromCloud)
                .accessibilityIdentifier("settings-rip-from-cloud")
                .onChange(of: settings.ripFromCloud) { settings.persist() }
            HStack {
                Button {
                    settings.persist()
                    Task { await testRip() }
                } label: {
                    if ripTesting { ProgressView() } else { Text("Test connection") }
                }
                .disabled(ripTesting)
                .accessibilityIdentifier("settings-rip-test")
                Spacer()
                ripStatusView
            }
        } header: {
            Text("Rip server")
        } footer: {
            Text("The iMac rip-on-demand server (over Tailscale). Streams/downloads any song; only needed to create a rip — once ripped it plays from S3 anywhere. When “Rip from cloud source” is on, songs that match your Apple Music library are captured from Apple Music (real-time, one at a time) and fall back to vinyl otherwise — a large Rip/Burn can take a while.")
        }
    }

    @ViewBuilder private var ripStatusView: some View {
        switch ripStatus {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityIdentifier("settings-rip-status")
        case .bad(let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
                .accessibilityIdentifier("settings-rip-status")
        case nil:
            EmptyView()
        }
    }

    // MARK: Apple Music (Local) sync

    /// "Sync Apple Music library" — kicks a library check on the rip server (POST `/am-sync`,
    /// polls the job), then evicts the stale AM index from `URLCache.shared` and reloads the
    /// catalog so newly-deployed tracks appear. Only meaningful once the AM source is loaded,
    /// and it leans on the SAME rip server as the rip features — so it lives right after the
    /// rip section and is gated on both `hasAppleMusic` (the source is present) and a server.
    @ViewBuilder private var appleMusicSyncSection: some View {
        if settings.hasAppleMusic {
            Section {
                HStack {
                    Button {
                        Task { await syncAppleMusic() }
                    } label: {
                        if syncing {
                            ProgressView()
                        } else {
                            Label("Sync Apple Music library", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(syncing || !musicSync.hasServer)
                    .accessibilityIdentifier("settings-am-sync")
                    Spacer()
                    syncStatusView
                }
            } header: {
                Text("Apple Music sync")
            } footer: {
                Text(musicSync.hasServer
                    ? "Checks your Mac's Apple Music library (via the rip server) for newly-added music. The library is also checked automatically every day at 04:00. Detected songs appear in the “Apple Music (Local)” source once the change is committed + deployed — not instantly; use “Reload catalog” above if a deploy is still in flight."
                    : "Requires the rip server (configured above). Once set, this checks your Mac's Apple Music library for newly-added music; it's also checked automatically every day at 04:00.")
            }
        }
    }

    @ViewBuilder private var syncStatusView: some View {
        switch syncStatus {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityIdentifier("settings-am-sync-status")
        case .bad(let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
                .accessibilityIdentifier("settings-am-sync-status")
        case nil:
            EmptyView()
        }
    }

    private func syncAppleMusic() async {
        syncing = true; syncStatus = nil
        defer { syncing = false }
        do {
            let result = try await musicSync.sync()
            // Evict the stale AM index so the reload re-fetches it: CatalogService uses
            // `.returnCacheDataElseLoad` against URLCache.shared, which would otherwise serve
            // the pre-deploy copy (the load-bearing cache gotcha — see CatalogService).
            URLCache.shared.removeCachedResponse(for: URLRequest(url: Config.appleMusicIndexURL))
            await app.reload()
            let c = result.counts
            if c.added == 0 && c.changed == 0 && c.removed == 0 {
                syncStatus = .ok("Library up to date")
            } else {
                // The detected tracks are DETECTED, not yet applied in-app: the server queued a
                // change-set for the deploy pipeline. Word it so the green check doesn't overstate
                // (the catalog only changes once that change-set is committed + deployed). Show only
                // the non-zero buckets (v1's Library.xml diff only ever detects `added`).
                var parts: [String] = []
                if c.added > 0 { parts.append("\(c.added) new") }
                if c.changed > 0 { parts.append("\(c.changed) changed") }
                if c.removed > 0 { parts.append("\(c.removed) removed") }
                syncStatus = .ok("\(parts.joined(separator: " · ")) — applies after deploy")
            }
        } catch {
            syncStatus = .bad(error.localizedDescription)
        }
    }

    private func testRip() async {
        ripTesting = true; ripStatus = nil
        let result = await RipServerService.health(urlString: settings.ripServerURL, token: settings.ripToken)
        switch result {
        case .success(let h):
            var parts: [String] = []
            if let c = h.catalog { parts.append("\(c.songs ?? 0) songs") }
            if let v = h.version { parts.append("v\(v)") }
            if h.hls == true { parts.append("HLS") }
            if let v = h.version, v < RipServerService.expectedVersion { parts.append("⚠︎ outdated") }
            ripStatus = .ok(parts.isEmpty ? "Online" : parts.joined(separator: " · "))
        case .failure(let e):
            ripStatus = .bad((e as? URLError)?.code == .timedOut ? "Timed out" : "Unreachable")
        }
        ripTesting = false
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) { confirmingReset = true } label: {
                Label("Reset all app state", systemImage: "trash")
            }
            .accessibilityIdentifier("settings-reset")
            .confirmationDialog("Reset everything on this device?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) {
                    settings.resetEverything()
                    Task { await app.reload() }
                }
                .accessibilityIdentifier("settings-reset-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes sources, search & rip-server config, and cached covers. Your collections are cleared too. This can’t be undone.")
            }
        } footer: {
            Text("PocketDJ \(appVersion). App updates (new views + data migrations) ship via the App Store.")
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }
}
