import SwiftUI
import UniformTypeIdentifiers

/// Settings — mirrors the PWA's: data sources, online-search credentials, the
/// import-server config, an Edits export/import, plus a nuclear reset. No refresh /
/// data-migration controls: the App Store ships those with each new version.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(CollectionsStore.self) private var collections
    // The nuclear reset ends the whole mix (ejects both decks), which also clears the durable
    // mix-deck session — a reset device must launch quiet, not rehydrate yesterday's decks.
    @Environment(MixEngine.self) private var mix
    // Not private: read by the streamingSection in SettingsView+Streaming.swift.
    @Environment(StreamingStore.self) var streaming
    @Environment(ProfileStore.self) private var profile
    @Environment(CloudSyncService.self) private var cloudSync
    // Account-deletion orchestrator (5.1.1(v)) — wired in PocketDJApp with every store it wipes.
    @Environment(AccountDeletionService.self) private var accountDeletion
    @State private var ripTesting = false
    @State private var ripStatus: RipStatus?
    @State private var jukeboxTesting = false
    @State private var jukeboxStatus: RipStatus?
    @State private var confirmingReset = false
    /// Account deletion (5.1.1(v)): the confirm dialog + the in-progress guard (disables the row
    /// and shows a spinner while the orchestrator runs).
    @State private var confirmingAccountDeletion = false
    @State private var deletingAccount = false
    /// Easter egg: the mushroom-cloud overlay playing after a confirmed reset.
    @State private var nuking = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDoc = EditsFile(data: Data())

    // Full backup (.pocketdj.zip)
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupDoc = PlaylistZipFile(data: Data())
    @State private var backupSummary: String?

    /// The host the app will actually search (user override → global search-config.json →
    /// baked default), shown live in the Online-search section.
    @State private var effectiveSearchHost = ""

    enum RipStatus { case ok(String), bad(String) }

    var body: some View {
        Form {
            identitySection
            sourcesSection
            streamingSection
            searchSection
            ripSection
            jukeboxSection
            mixSection
            syncSection
            storageSection
            editsSection
            backupSection
            resetSection
            debugSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden).background(Theme.bg)
        // Easter egg: confirming the nuclear reset detonates a mushroom cloud over
        // the screen (decoration only — it never intercepts touches; ~2.5 s).
        .overlay { if nuking { MushroomCloudView { nuking = false } } }
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
    }

    // MARK: Storage (one entry — the manager screen)

    /// The single door into the storage manager: usage, the burnt-music + session-recording
    /// folder pickers (moved off this root screen), delete-by-artist/-collection/-all, the
    /// session-recordings delete, and the soft cap. See `StorageView`.
    private var syncSection: some View {
        Section {
            NavigationLink {
                SyncSettingsView(settings: settings)
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("settings-sync")
        } header: {
            Text("Sync")
        } footer: {
            Text("Apple Music library re-index + keeping converted playlists & pockets in step with their source playlists.")
        }
    }

    private var storageSection: some View {
        Section {
            NavigationLink {
                StorageView(settings: settings)
            } label: {
                Label("Storage", systemImage: "internaldrive")
            }
            .accessibilityIdentifier("settings-storage")
        } header: {
            Text("Storage")
        } footer: {
            Text("Downloaded music + session recordings: where they live, what they cost, and the tools to clear them.")
        }
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

    // MARK: Profile (identity + iCloud session sync)

    private var identitySection: some View {
        Section {
            // Edits flow through the PROFILE (the synced identity); setName persists +
            // mirrors into settings.pocketDJName / collections.performerName, so every
            // existing consumer (studio artist, jukebox DJ line) sees it unchanged.
            TextField("Your PocketDJ name", text: Binding(
                get: { profile.name },
                set: { profile.setName($0) }))
                .pocketField()
                .accessibilityIdentifier("settings-pocketdj-name")
            Toggle("Sync with iCloud", isOn: Binding(
                get: { settings.cloudSyncEnabled },
                set: { on in
                    settings.cloudSyncEnabled = on
                    settings.persist()
                    if on { Task { await cloudSync.syncNow() } }
                }))
                .accessibilityIdentifier("profile-cloud-sync-toggle")
            if settings.cloudSyncEnabled {
                HStack {
                    Button {
                        Task { await cloudSync.syncNow() }
                    } label: {
                        if cloudSync.syncing {
                            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(cloudSync.syncing)
                    .accessibilityIdentifier("profile-sync-now")
                    Spacer()
                    Text(syncStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile-sync-status")
                }
            }
            // Account deletion (App Store Guideline 5.1.1(v)) lives HERE, in the Profile /
            // identity section — the account-management area a reviewer (and the user) looks in —
            // rather than beside the local-only "Reset all app state" nuke: this removes the
            // ACCOUNT (the synced identity AND its private-CloudKit copies), not just this
            // device's caches. It reuses the same mushroom-cloud send-off as the reset.
            deleteAccountRow
        } header: {
            Text("Profile")
        } footer: {
            Text("Your PocketDJ name shows as the artist on your samples, loops, sequences, and instrumentals (leave blank for “Studio”). iCloud sync keeps your profile, collections, history, and playback sessions in step across your devices — last writer wins per document.")
        }
    }

    /// The destructive "Delete Account" control (5.1.1(v)) — mirrors `resetSection`'s pattern
    /// (a `Button(role:.destructive)` gated by a `.confirmationDialog`), but wipes EVERYTHING
    /// including the iCloud copies + identity, and shows an in-progress spinner while it runs.
    @ViewBuilder private var deleteAccountRow: some View {
        Button(role: .destructive) { confirmingAccountDeletion = true } label: {
            if deletingAccount {
                Label { Text("Deleting…") } icon: { ProgressView() }
            } else {
                Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .tint(Theme.danger)
        .disabled(deletingAccount)
        .accessibilityIdentifier("settings-delete-account")
        .confirmationDialog("Delete your account and all data?",
                            isPresented: $confirmingAccountDeletion, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) {
                deletingAccount = true
                Task {
                    await accountDeletion.deleteAccountAndAllData()
                    // Re-seed the catalog with the reset sources, then send it off with the same
                    // nuclear overlay as Reset. Onboarding re-arms itself for the next launch
                    // (SettingsStore.resetEverything → OnboardingStore.markPendingAfterReset).
                    await app.reload()
                    deletingAccount = false
                    nuking = true
                }
            }
            .accessibilityIdentifier("settings-delete-account-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases your profile, library, collections, favorites, listening history, downloads, and studio content from this device, and removes their iCloud copies from your private database on this Apple ID. It can’t be undone. Even if iCloud can’t be reached, everything on this device is still erased.")
        }
    }

    private var syncStatusLine: String {
        if cloudSync.accountAvailable == false { return "iCloud unavailable" }
        if let err = cloudSync.lastError { return err }
        guard let at = cloudSync.lastSyncAt else { return "Not synced yet" }
        let time = at.formatted(date: .omitted, time: .shortened)
        if let summary = cloudSync.lastSummary { return "\(summary) · \(time)" }
        return time
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
            Text("\(edits.count) local metadata edit\(edits.count == 1 ? "" : "s"). Export to JSON (schema v\(editsSchemaVersion)) to merge into the PocketDJ catalog; Import merges another export in.")
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
            if !settings.hasMyDigital {
                Button {
                    settings.loadMyDigital()
                    // First fetch must be fresh — see the Reload-catalog note re: the URLCache gotcha.
                    URLCache.shared.removeCachedResponse(for: URLRequest(url: Config.digitalIndexURL))
                    Task { await app.reload() }
                } label: { Label("Load My Digital library", systemImage: "externaldrive.badge.icloud") }
                    .accessibilityIdentifier("settings-load-my-digital")
            }
            Button {
                settings.persist()
                // Evict cached responses for the enabled sources so the reload re-fetches them:
                // CatalogService uses `.returnCacheDataElseLoad` against URLCache.shared, which
                // would otherwise pin a pre-deploy copy (e.g. a freshly-added source whose index
                // briefly 404'd to the SPA HTML) — the load-bearing cache gotcha (see CatalogService
                // + the Apple Music sync path). An explicit "Reload catalog" must mean fresh.
                for url in settings.enabledSourceURLs {
                    URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
                }
                Task { await app.reload() }
            } label: { Label("Reload catalog", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("settings-reload")
        } header: {
            Text("Data sources")
        } footer: {
            Text("Choose which sources to show across the app. Each is a PocketDJ index URL served from cloud storage.")
        }
    }

    // MARK: Streaming accounts (Apple Music) — defined in SettingsView+Streaming.swift

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
            TextField("Search host (optional — blank = shared default)", text: $settings.searchEndpoint)
                .pocketField()
                .font(.caption.monospaced())
                .accessibilityIdentifier("settings-search-host")
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            if !effectiveSearchHost.isEmpty {
                Text("Currently searching: \(effectiveSearchHost)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
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
            Text("Online search")
        } footer: {
            Text("Enables full-text search across the whole collection. Leave the host blank to follow the shared default (updates automatically); set it to point at your own search host. The key and secret are the AWS credentials for that host — leave them blank to stay fully offline.")
        }
        // Reflect the live effective host as the override field changes.
        .task(id: settings.searchEndpoint) {
            await SearchConfig.shared.setUserHost(settings.searchEndpoint)
            effectiveSearchHost = await SearchConfig.shared.resolved().host
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

            Stepper(value: $settings.mixGlideSeconds, in: 1...30, step: 1) {
                HStack {
                    Text("Mix Glide length")
                    Spacer()
                    Text("\(Int(settings.mixGlideSeconds)) s")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-mix-glide-length")
            .onChange(of: settings.mixGlideSeconds) { settings.persist() }

            Toggle("Auto-hide played tracks", isOn: $settings.mixAutoHidePlayed)
                .accessibilityIdentifier("settings-mix-autohide")
                .onChange(of: settings.mixAutoHidePlayed) { settings.persist() }

            Picker(selection: $settings.cueOutputChannel) {
                ForEach(CueChannel.allCases) { ch in Text(ch.label).tag(ch) }
            } label: {
                Text("Cue output channel")
            }
            .accessibilityIdentifier("settings-mix-cue-channel")
            .onChange(of: settings.cueOutputChannel) { settings.persist() }

            Toggle("Beat pulse", isOn: $settings.beatPulseEnabled)
                .accessibilityIdentifier("settings-mix-beat-pulse")
                .onChange(of: settings.beatPulseEnabled) { settings.persist() }

            // iOS-only "view mode": how the two decks are arranged in the Mix tab. macOS is always
            // side-by-side (there's room), so the picker is hidden there.
            #if os(iOS)
            Picker(selection: $settings.mixDeckLayout) {
                ForEach(MixDeckLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.systemImage).tag(layout)
                }
            } label: {
                Text("Deck layout")
            }
            .accessibilityIdentifier("settings-mix-deck-layout")
            .onChange(of: settings.mixDeckLayout) { settings.persist() }
            #endif
        } header: {
            Text("Mix")
        } footer: {
            Text(mixSectionFooter)
        }
    }

    /// Copy for the Mix settings footer. The deck-layout paragraph is iOS-only (the picker is too).
    private var mixSectionFooter: String {
        var s = "In the Mix tab's Auto mode, the app plays a pocket or set list end-to-end, beginning each crossfade this many seconds before a track ends and sweeping the volume from one deck to the next over the fade length. Skip fade is how long the crossfade lasts when you tap the Skip button (double-tap always uses a fast 5 s sweep).\n\nA mix session records what you play until you hit Reset. When Auto-hide played tracks is on, the deck loader hides tracks you've already played this session; off, they still show with a ✓.\n\nCue output channel routes a deck's pre-fade-listen (the headphones button on each deck) to one side of the stereo output, leaving the house mix on the other — for a booth where you monitor on a separate feed.\n\nBeat pulse flashes a ring around each deck on every beat (downbeats brighter) so you can feel the groove and eyeball-align the two decks while beat-matching."
        #if os(iOS)
        s += "\n\nDeck layout arranges the two Mix decks in portrait: Side by side (the classic two-up board), Stacked (full-width decks, one above the other), or Single (one deck at a time with ‹ › buttons on either side to flip to the other). Portrait defaults to Stacked so each deck's sliders stay finger-friendly; landscape always shows them side by side."
        #endif
        return s
    }

    // MARK: Import server

    private var ripSection: some View {
        Section {
            TextField("Import server URL", text: $settings.ripServerURL)
                .pocketField()
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-rip-url")
            TextField("Token (optional)", text: $settings.ripToken)
                .pocketField()
                .accessibilityIdentifier("settings-rip-token")
            // #TOUPDATE: delete this toggle. The target state has no Apple Music capture, so there
            // is no "cloud source" to rip from and nothing for this switch to mean. It is left in
            // place ONLY because removing it today would strand the persisted flag — three things
            // must land first, in this order:
            //   1. rip-server.mjs must fail closed on media the requester doesn't own. Removing
            //      the toggle alone does NOT stop capture: :798 ("Digital songs always capture
            //      from Apple Music") routes every DIGITAL song to capture regardless of this
            //      flag, and :549 captures an analog song on an exact library match.
            //   2. SettingsStore.swift:192 must force `ripFromCloud` false on load, or an already-
            //      persisted `true` keeps asking for capture with no UI left to turn it off.
            //   3. SettingsTests.swift:23/32 asserts that `true` round-trips — update it with (2).
            // The footer below deliberately no longer describes this control.
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
            Text("Import server")
        } footer: {
            // #TOUPDATE: the footer below is written to the TARGET state. Three of its claims are
            // not true of today's code:
            //   (a) "music you already own in your cloud library" / "nothing comes back" —
            //       rip-server.mjs:798 ("Digital songs always capture from Apple Music") still
            //       routes every DIGITAL song to capture unconditionally, and :549 captures an
            //       analog song on an exact library match. The server must fail closed on any
            //       media the requester does not own, and return the miss envelope instead.
            //   (b) "your own copy" / "your storage" — rips/* is public-read under a FLAT
            //       rips/<songId>.mp3 key shared across every user. Needs per-user key prefixes
            //       and the public-read grant removed before any possessive is honest.
            //   (c) any per-requester claim at all — the server does not authenticate: authed()
            //       (rip-server.mjs:1904) returns true whenever no token is configured, and
            //       /health reports auth:false. Needs enforced per-user authorization.
            Text("The server that prepares your own copy of music you already own in your cloud library — nothing else. Ask for a song you don't own and nothing comes back; it is never fetched from anywhere else to fill the gap. Only needed the first time: once a song is prepared it plays from your storage anywhere, with the server off. One job at a time, so a whole collection takes a while.")
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

    // MARK: Jukebox Hero

    private var jukeboxSection: some View {
        Section {
            TextField("Jukebox server URL", text: $settings.jukeboxServerURL)
                .pocketField()
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-jukebox-url")
            TextField("Token (optional)", text: $settings.jukeboxToken)
                .pocketField()
                .accessibilityIdentifier("settings-jukebox-token")
            Toggle(isOn: Binding(
                get: { settings.jukeboxTokensRequiredByDefault },
                set: { settings.jukeboxTokensRequiredByDefault = $0; settings.persist() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Require access token")
                    Text("New sessions require a per-session code by default. You can override this per session.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("settings-jukebox-require-token")
            HStack {
                Button {
                    settings.persist()
                    Task { await testJukebox() }
                } label: {
                    if jukeboxTesting { ProgressView() } else { Text("Test connection") }
                }
                .disabled(jukeboxTesting)
                .accessibilityIdentifier("settings-jukebox-test")
                Spacer()
                jukeboxStatusView
            }
        } header: {
            Text("Jukebox Hero")
        } footer: {
            // #TOUPDATE: the footer below is written to the TARGET state. None of the three
            // session bounds it promises exist yet:
            //   (a) "the link carries a token" — the guest page is a public CloudFront object and
            //       jukebox-server.mjs:446 serves guest requests with no guest key at all
            //       ("Public guest request — no host key"). JUKEBOX_TOKEN (:35) gates only the
            //       host/create endpoints and defaults to empty. Needs a per-session guest token,
            //       default ON.
            //   (b) "the listener count is capped" — there is no cap; the server's own header (:9)
            //       advertises "any number of listeners". The only limit is a per-IP request
            //       window on the request form (ipWindowMax = 12, :62). Needs a server-enforced
            //       listener cap.
            //   (c) "the session expires" — ttlMs (24 h) and deleteMs (7 d) are real (:50-51), but
            //       `timeless` is a shipped opt-out that makes expiryOf() return null (:121), and
            //       each streamUrl is a public, non-expiring rips-bucket mp3 that outlives the
            //       session. Needs `timeless` removed and per-session signed, expiring audio URLs.
            Text("The jukebox session broker your guests' phones talk to. Start a jukebox from the Jukebox Hero tab (⌘J); guests scan its QR code to see what's playing and request songs. A session is bounded to your event: the link carries a token, the listener count is capped, and the session expires when the night is over.")
        }
    }

    @ViewBuilder private var jukeboxStatusView: some View {
        switch jukeboxStatus {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityIdentifier("settings-jukebox-status")
        case .bad(let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
                .accessibilityIdentifier("settings-jukebox-status")
        case nil:
            EmptyView()
        }
    }

    private func testJukebox() async {
        jukeboxTesting = true; jukeboxStatus = nil
        let client = JukeboxClient(baseURL: settings.jukeboxServerURL, token: settings.jukeboxToken)
        do {
            let h = try await client.health()
            var parts = ["Online"]
            if let v = h.version { parts.append("v\(v)") }
            jukeboxStatus = .ok(parts.joined(separator: " · "))
        } catch {
            jukeboxStatus = .bad((error as? URLError)?.code == .timedOut ? "Timed out" : "Unreachable")
        }
        jukeboxTesting = false
    }

    // MARK: Apple Music (Local) sync

    /// "Sync Apple Music library" — kicks a library check on the import server (POST `/am-sync`,
    /// polls the job), then evicts the stale AM index from `URLCache.shared` and reloads the
    /// catalog so newly-deployed tracks appear. Only meaningful once the AM source is loaded,
    /// and it leans on the SAME import server as the import features — so it lives right after
    /// that section and is gated on both `hasAppleMusic` (the source is present) and a server.
    // (The Apple Music library sync UI moved to SyncSettingsView — Settings ▸ Sync.)

    private func testRip() async {
        ripTesting = true; ripStatus = nil
        let result = await RipServerService.health(urlString: settings.ripServerURL,
                                                   token: settings.ripToken, profileId: profile.id)
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

    /// Device-local reset only. #TOUPDATE: this is the closest thing the app has to account
    /// deletion, and it deletes nothing server-side — there is no in-app way to remove your
    /// prepared audio or your synced profile from the cloud. Needs a real delete path (per-user
    /// keys to delete, an authenticated request to delete them, and the CloudKit profile/session
    /// records purged) before the copy here can offer it. Until then this message must keep
    /// saying plainly that server-side audio survives.
    private var resetSection: some View {
        Section {
            Button(role: .destructive) { confirmingReset = true } label: {
                Label("Reset all app state", systemImage: "trash")
            }
            .accessibilityIdentifier("settings-reset")
            .confirmationDialog("Reset everything on this device?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) {
                    mix.ejectAll()   // stop any auto-DJ + eject both decks → durable session cleared
                    settings.resetEverything()
                    Task { await app.reload() }
                    nuking = true   // the nuclear option gets a nuclear send-off
                }
                .accessibilityIdentifier("settings-reset-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                // #TOUPDATE: "your cloud library" is per-user framing that is not true today —
                // prepared audio lives at a FLAT, public-read rips/<songId>.mp3 key shared across
                // every user, so there is no "your" copy to leave behind. Honest once per-user key
                // prefixes and an authenticating server land.
                Text("Removes sources, search & import-server config, and cached covers. Your collections are cleared too. This can’t be undone. Music you’ve already prepared stays in your cloud library — this only resets this device.")
            }
        } footer: {
            Text("App updates (new views + data migrations) ship via the App Store.")
        }
    }

    // MARK: Debug (audio capture-session diagnostics — see DebugView)

    /// Last section on purpose: its footer is the app's build identity, so a TestFlight
    /// tester can say exactly which build they're running.
    private var debugSection: some View {
        Section {
            NavigationLink {
                DebugView(settings: settings)
            } label: {
                Label("Debug", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("settings-debug")
        } footer: {
            Text("PocketDJ \(MixDiag.buildIdentity())")
                .accessibilityIdentifier("settings-build-version")
        }
    }
}
