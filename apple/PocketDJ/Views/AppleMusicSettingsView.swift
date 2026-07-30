import SwiftUI

/// Settings ▸ Apple Music — ALL Apple-Music-related settings, consolidated into one pane
/// (Levi 2026-07-29) with two sub-tabs (segmented, the Browse discover-scope idiom):
///
///   • SYNCING — ONE set of sync controls, never duplicated (Levi: "the syncing of collections
///     and favorites is not duplicated across a local and remote mode"). PUBLIC is the unlabeled
///     default: syncing talks to Apple Music directly with a token minted on this device.
///     PRIVATE is an opt-in TOGGLE at the bottom that reveals the server-credential fields and
///     reroutes the same verbs through the user's own PocketDJ server + catalog (the iMac):
///       Collections ⇅/↑/↓ — public ↓ = the WS2 pull/import · private ↓ = the import-server
///         Library.xml re-index; public ↑ = the WS2 idempotent push · private ↑ = (nothing extra;
///         the shared send below covers it). SHARED in both: ↓ also reconciles converted
///         collections from their sources, ↑ also re-drives recent adds (the write-back backfill,
///         its look-back stepper always visible — Levi follow-up).
///       Favorites ⇅ — the same on-device owner-gated service either way.
///       The automatic converted-collections toggle and the write-back queue (evidence,
///       auto-hidden) show regardless of the toggle.
///
///   • CREDENTIALS — the MusicKit account link (log in / log out + status), a sync-service
///     health check, and the owner-only favorites bootstrap (iCloud hash + seed). The PRIVATE
///     server credentials live under the Private-syncing toggle in the Syncing tab.
struct AppleMusicSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(CollectionActivityStore.self) private var activity
    @Environment(MusicSyncClient.self) private var musicSync
    @Environment(StreamingStore.self) private var streaming
    @Environment(ProfileStore.self) private var profile
    /// Optional on purpose: injected by the app's own window; a preview / test host that
    /// renders this standalone should degrade gracefully, not trap.
    @Environment(FavoritesSyncService.self) private var favoritesSync: FavoritesSyncService?
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?
    @Environment(PlaylistAppleMusicSync.self) private var playlistSync: PlaylistAppleMusicSync?

    enum Tab: String, CaseIterable, Identifiable {
        case syncing = "Syncing"
        case credentials = "Credentials"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .syncing

    // Private library re-index (the user's own server)
    @State private var syncing = false
    @State private var syncStatus: Status?
    // Private-server connection test (under the Private-syncing toggle)
    @State private var ripTesting = false
    @State private var ripStatus: Status?
    // Sync-service health check (Credentials tab)
    @State private var remoteTesting = false
    @State private var remoteStatus: Status?
    // Collections run state (one runner for both backends + the shared halves)
    @State private var collectionsRunning = false
    @State private var collectionsStatus: [String] = []
    // Owner bootstrap (favorites)
    @State private var ownerHash: String?
    @State private var loadedHash = false
    @State private var copiedHash = false
    @State private var showSeedExporter = false
    @State private var seedDoc = EditsFile(data: Data())

    enum Status { case ok(String), bad(String) }

    var body: some View {
        Form {
            tabSection
            if tab == .syncing {
                // ONE set of sync controls (never duplicated); the Private toggle at the
                // bottom reroutes them through the user's own server instead of Apple's API.
                collectionsSection
                favoritesSyncSection
                convertedAutoSection
                privateSyncSection
                writeBackSection
            } else {
                accountSection
                remoteServiceSection
                ownerBootstrapSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Music")
        .scrollContentBackground(.hidden).background(Theme.bg)
        // The seed rides the same fileExporter idiom as the Edits/Backup exports — save it
        // into iCloud Drive, then upload it to `Config.favoritesSeedURL` on the catalog CDN.
        .fileExporter(isPresented: $showSeedExporter, document: seedDoc, contentType: .json,
                      defaultFilename: "favorites-seed") { _ in }
        .task {
            ownerHash = await OwnerIdentity.currentHash()
            loadedHash = true
        }
        .onDisappear { settings.persist() }
        // Backend-specific status lines must not outlive a Private-toggle flip (review catch:
        // "Get: needs your server…" lingering under the public footer).
        .onChange(of: settings.appleMusicPrivateSync) { _, _ in
            collectionsStatus = []
            syncStatus = nil
            ripStatus = nil
        }
    }

    // MARK: Sub-tabs

    private var tabSection: some View {
        Section {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("am-settings-tab")
        }
    }

    // MARK: Collections — ONE set of sync verbs; the Private toggle only swaps the backend

    /// FUNCTIONAL PARITY (Levi 2026-07-29): with the exception of the actual rip server, public
    /// and private must not differ — same verbs, same shared halves (converted-collections
    /// reconcile on Get, write-back backfill on Send), same knobs (the look-back stepper is
    /// always visible).
    private var collectionsBusy: Bool {
        // All three run states are APP-SCOPED (review catch: the view-local flag alone let a
        // re-entered pane start an overlapping private Get mid-run).
        collectionsRunning || (playlistSync?.isSyncing ?? false) || musicSync.isSyncing
    }
    private var collectionsAvailable: Bool {
        settings.appleMusicPrivateSync || (playlistSync?.isAvailable ?? false)
    }

    @ViewBuilder private var collectionsSection: some View {
        Section {
            if settings.appleMusicPrivateSync, !settings.hasAppleMusic {
                Button {
                    settings.loadAppleMusic()
                    Task { await app.reload() }
                } label: {
                    Label("Load Apple Music (Local) library", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("am-load-local-source")
            }

            // The same three verbs regardless of the Private toggle: two-way, send-only, get-only.
            Button { runCollections(.both) } label: {
                if collectionsBusy {
                    ProgressView()
                } else {
                    Label("Sync collections", systemImage: "arrow.triangle.2.circlepath.circle")
                }
            }
            .disabled(collectionsBusy || !collectionsAvailable)
            .accessibilityIdentifier("am-collections-sync")

            HStack {
                Button { runCollections(.push) } label: {
                    Label("Send to Apple Music", systemImage: "arrow.up.circle")
                }
                .accessibilityIdentifier("am-collections-send")
                Spacer()
                Button { runCollections(.pull) } label: {
                    Label("Get from Apple Music", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("am-collections-get")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .disabled(collectionsBusy || !collectionsAvailable)

            // Shared knob, BOTH modes (Levi follow-up): how far back "Send" re-drives queued
            // adds from the collection history.
            Stepper(value: $settings.writeBackBackfillDays,
                    in: 1...CollectionsStore.writeBackBackfillMaxDays) {
                LabeledContent("Send look-back",
                               value: "\(settings.writeBackBackfillDays) day\(settings.writeBackBackfillDays == 1 ? "" : "s")")
            }
            .accessibilityIdentifier("writeback-backfill-days")

            // Shared status lines (converted reconcile, backfill, private re-index) — both modes.
            ForEach(Array(collectionsStatus.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("am-collections-status")
            }
            // The device-token sync's live steps + audit history — BOTH modes (the push runs in
            // private too, and running work must never be invisible).
            remoteProgressRows
        } header: {
            Text("Collections")
        } footer: {
            Text(settings.appleMusicPrivateSync
                ? "“Send” pushes your playlists into Apple Music with a token minted on this device (created only if missing; then only missing songs are added) and re-drives your recent adds. “Get” re-indexes the Apple Music library on your own PocketDJ server (also nightly at 04:00) and updates converted collections. “Sync collections” does both."
                : "“Sync collections” pushes your playlists into Apple Music and imports Apple Music playlists back — a playlist is created only if it isn't there yet, and after that only its missing songs are added; an interrupted sync picks up where it left off. “Get” also updates converted collections; “Send” also re-drives recent adds. Runs on your device (requires an Apple Music subscription).")
        }
    }

    /// ONE runner for the verbs — the Private toggle swaps only the collections BACKEND
    /// (public = the WS2 device-token sync; private = the user's own server re-index); the
    /// SHARED halves (converted-collections reconcile on Get, write-back backfill on Send) run
    /// identically in both modes.
    private func runCollections(_ direction: PlaylistAppleMusicSync.Direction) {
        Task { await runCollectionsNow(direction) }
    }

    private func runCollectionsNow(_ direction: PlaylistAppleMusicSync.Direction) async {
        guard !collectionsRunning else { return }
        collectionsRunning = true
        collectionsStatus = []
        defer { collectionsRunning = false }

        // Backend halves. Only GET differs by the toggle (which library index refreshes:
        // your server's Library.xml re-index vs the on-device MusicKit walk + WS2 pull).
        // The device-token PUSH + reconcile runs in BOTH modes (parity review catch: it
        // never needed a server, and without it a private user could never create a new
        // Apple Music playlist or propagate removals/reorders).
        if settings.appleMusicPrivateSync {
            if direction != .push {
                if !musicSync.hasServer {
                    collectionsStatus.append("Get: needs your server — set its URL under Private syncing below.")
                } else {
                    await syncAppleMusic()
                    switch syncStatus {
                    case .ok(let msg): collectionsStatus.append("Get: \(msg)")
                    case .bad(let msg): collectionsStatus.append("Get failed: \(msg)")
                    case nil: break
                    }
                }
            }
            if direction != .pull, let playlistSync, playlistSync.isAvailable {
                await playlistSync.syncNow(collections: collections, app: app, direction: .push)
            }
        } else if let playlistSync, playlistSync.isAvailable {
            await playlistSync.syncNow(collections: collections, app: app, direction: direction)
            // PUBLIC Get also refreshes the on-device "Apple Music" library source — the
            // public-mode twin of the private catalog re-index (data-source parity).
            if direction != .push {
                let before = app.appleMusicLibrary?.songs.count ?? 0
                await app.refreshAppleMusicLibrary?()
                let after = app.appleMusicLibrary?.songs.count ?? 0
                collectionsStatus.append(after > before
                    ? "Library: indexed \(after - before) new song\(after - before == 1 ? "" : "s")"
                    : "Library: index up to date")
            }
        }

        // Shared halves — IDENTICAL in both modes.
        if direction != .push {
            let changed = collections.syncConvertedCollections(with: app.indexPlaylists)
            collectionsStatus.append(changed == 0 ? "Converted collections: all in sync"
                : "Converted collections: updated \(changed) item\(changed == 1 ? "" : "s")")
        }
        if direction != .pull {
            if writeBack?.canWriteBack == true {
                let n = collections.backfillSourceWriteBacks(from: activity.events,
                                                             days: settings.writeBackBackfillDays,
                                                             localInstallId: activity.installId)
                collectionsStatus.append(n == 0 ? "Adds: nothing new to send"
                    : "Adds: sending \(n) song\(n == 1 ? "" : "s") to Apple Music")
            } else {
                collectionsStatus.append("Adds: unavailable on this device (Apple Music library writes need iPhone / Vision Pro).")
            }
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
                // Detected, not yet applied in-app: the server queued a change-set for the deploy
                // pipeline; the catalog only changes once it's committed + deployed.
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

    // MARK: REMOTE progress rows (live steps + audit trail — see PlaylistAppleMusicSync)

    /// The remote backend's status rows, rendered inside the unified Collections section: the
    /// live step list while running, the persisted current/last-run recap, and the audit history.
    @ViewBuilder private var remoteProgressRows: some View {
        if let playlistSync {
            if let startedMs = playlistSync.currentRunStartedMs, !playlistSync.steps.isEmpty {
                HStack {
                    Text(playlistSync.isSyncing ? "Syncing now"
                         : playlistSync.currentRunCompleted ? "Last sync" : "Interrupted sync")
                        .font(.caption.bold())
                    Spacer()
                    Text(Date(timeIntervalSince1970: startedMs / 1000)
                        .formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("am-playlist-sync-run-header")
            }
            ForEach(playlistSync.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch step.state {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                    case .interrupted: Image(systemName: "pause.circle.fill").foregroundStyle(Theme.accent2)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.label).font(.callout)
                        if let detail = step.detail {
                            Text(detail).font(.caption).foregroundStyle(Theme.fgDim)
                        }
                    }
                }
                .accessibilityIdentifier("am-playlist-sync-step")
            }
            if !playlistSync.isSyncing, !playlistSync.currentRunCompleted, !playlistSync.steps.isEmpty {
                Text("This sync was interrupted — tap Sync to resume where it left off.")
                    .font(.caption).foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("am-playlist-sync-resume-hint")
            }

            if !playlistSync.isSyncing, let r = playlistSync.lastResult, playlistSync.steps.isEmpty {
                Text(r).font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("settings-am-playlist-sync-status")
            }

            // Audit trail: what each sync actually did, per playlist, newest first.
            if !playlistSync.auditTrail.isEmpty {
                DisclosureGroup {
                    ForEach(playlistSync.auditTrail) { report in
                        auditReportRows(report)
                    }
                } label: {
                    Label("Sync history", systemImage: "list.bullet.rectangle")
                        .font(.callout)
                }
                .accessibilityIdentifier("am-playlist-sync-history")
            }
        }
    }

    /// One audit-trail entry: the run's summary line, then a per-playlist change list.
    @ViewBuilder private func auditReportRows(_ report: PlaylistAppleMusicSync.SyncReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Date(timeIntervalSince1970: report.dateMs / 1000)
                    .formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.bold())
                Spacer()
                Text(report.summary).font(.caption).foregroundStyle(Theme.fgDim)
                    .lineLimit(1).truncationMode(.tail)
            }
            // Positional identity on purpose: one report can hold several changes with the same
            // kind+name and identical error strings — value-derived ids would collide. Reports
            // are immutable once appended, so offsets are stable.
            ForEach(Array(report.changes.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 6) {
                    Text(changeBadge(change.kind))
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.bgOverlay, in: Capsule())
                    Text(change.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(changeDelta(change)).font(.caption2.monospaced()).foregroundStyle(Theme.fgDim)
                }
            }
            ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                Text(error).font(.caption2).foregroundStyle(Theme.danger).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("am-playlist-sync-report")
    }

    private func changeBadge(_ kind: String) -> String {
        switch kind {
        case "created": return "NEW"
        case "updated": return "＋"
        case "reconciled": return "⇅"
        case "imported": return "IN"
        default: return kind.uppercased()
        }
    }

    private func changeDelta(_ change: PlaylistAppleMusicSync.SyncReport.Change) -> String {
        var parts: [String] = []
        if change.added > 0 { parts.append("+\(change.added)") }
        if change.removed > 0 { parts.append("−\(change.removed)") }
        return parts.isEmpty ? (change.detail ?? "") : parts.joined(separator: " ")
    }

    // MARK: Favorites ⇄ Apple Music — one verb, opt-in toggle (owner bootstrap in Credentials)

    private var favoritesSyncSection: some View {
        Section {
            // OWNER installs are always-on (the allowlist grant); everyone else gets a real
            // opt-in TOGGLE (parity review: the old read-only gate line made "Sync favorites
            // now" a permanently-enabled no-op for every non-owner).
            if favoritesSync?.isOwner == true {
                LabeledContent("Two-way favorites sync", value: "On (library owner)")
                    .accessibilityIdentifier("favorites-sync-gate")
            } else {
                Toggle("Two-way favorites sync", isOn: $settings.favoritesTwoWaySync)
                    .accessibilityIdentifier("favorites-sync-gate")
            }
            if let error = favoritesSync?.lastError {
                LabeledContent("Last error", value: error)
                    .font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("favorites-sync-error")
            }
            if let ms = favoritesSync?.lastSyncedAtMs {
                LabeledContent("Last synced", value: Date(timeIntervalSince1970: ms / 1000)
                    .formatted(date: .abbreviated, time: .shortened))
                    .accessibilityIdentifier("favorites-sync-last-synced")
            }
            Button {
                Task { await favoritesSync?.run() }
            } label: {
                if favoritesSync?.isSyncing == true {
                    ProgressView()
                } else {
                    Label("Sync favorites now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            // Never an enabled no-op: off (and non-owner) means there is nothing the button
            // would sync, so it disables until the toggle is on.
            .disabled(favoritesSync == nil || favoritesSync?.isSyncing == true
                      || !(favoritesSync?.isOwner == true || settings.favoritesTwoWaySync))
            .accessibilityIdentifier("favorites-sync-now")
        } header: {
            Text("Favorites")
        } footer: {
            Text("""
                 ♥ lives in your PocketDJ profile, in your own iCloud account. With two-way \
                 favorites sync ON, ♥ on an Apple Music song also loves it in Apple Music — \
                 using a token minted on this device against your own account, whether Private \
                 syncing is on or off. Vinyl, My Digital, and Studio favorites have no Apple \
                 Music identity, so they never leave this device's iCloud account.

                 UN-FAVORITING IS LOSSY ON APPLE MUSIC. Apple ships no delete counterpart to \
                 `POST /v1/me/favorites`, so removing a ♥ here deletes the love RATING (which is \
                 what recommendations and this app read) but cannot retract the ★ — the track \
                 stays in Apple Music's "Favorite Songs" until you remove it there yourself.
                 """)
        }
    }

    // MARK: Automatic — converted collections follow their sources

    /// Moved here from the (now-retired) Settings ▸ Sync panel: Apple Music is the only sync
    /// provider, so its pane owns this. The manual pass rides the Collections "Get" verb.
    private var convertedAutoSection: some View {
        Section {
            Toggle("Converted collections follow their sources", isOn: $settings.syncConvertedPockets)
                .accessibilityIdentifier("collections-source-sync")
        } header: {
            Text("Automatic")
        } footer: {
            Text("\(linkedCount) linked item\(linkedCount == 1 ? "" : "s"). A pocket converted from — or a playlist duplicated from — a source playlist follows that playlist as the catalog updates: songs added there appear here, songs removed there are removed here; your own edits stay. Runs on every catalog refresh while on; “Get from Apple Music” runs a pass immediately. Freeze a single item from its detail-view ▸ menu.")
        }
    }

    /// How many collections carry source provenance (the population the automatic sync watches).
    private var linkedCount: Int {
        collections.pockets.filter(\.hasSource).count +
        collections.playlists.filter(\.hasSource).count
    }

    // MARK: ALWAYS — Apple Music playlist write-back queue

    /// The OUTBOUND leg of source-playlist adds, made visible (Levi 2026-07-20). Hidden entirely
    /// when the queue is empty: on a healthy install adds land in seconds and there is nothing
    /// to say, so a permanently-visible "0 pending" row would be noise.
    @ViewBuilder private var writeBackSection: some View {
        if let writeBack, !writeBack.jobs.isEmpty {
            Section {
                LabeledContent("Waiting to send", value: "\(writeBack.pendingCount)")
                    .accessibilityIdentifier("writeback-pending")
                LabeledContent("Failed", value: "\(writeBack.failed.count)")
                    .foregroundStyle(writeBack.failed.isEmpty ? Theme.fg : Theme.danger)
                    .accessibilityIdentifier("writeback-failed")

                ForEach(writeBack.failed) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(songTitle(job.songId)) → \(job.playlistName)")
                            .font(.callout)
                        if let error = job.lastError {
                            Text(error).font(.caption).foregroundStyle(Theme.danger)
                        }
                    }
                    .accessibilityIdentifier("writeback-failed-job")
                }

                // A GUESSED playlist match is a successful delivery that may have gone to the
                // wrong place — the one outcome no error list would ever show, so it gets its
                // own row rather than riding the failure list.
                if let warning = writeBack.resolutionWarning {
                    Text(warning)
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("writeback-warning")
                }

                if !writeBack.failed.isEmpty {
                    Button {
                        writeBack.retryFailed()
                        writeBack.runSoon()
                    } label: {
                        Label("Retry failed", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("writeback-retry")
                }
            } header: {
                Text("Apple Music playlist updates")
            } footer: {
                Text("""
                     Songs you add to an Apple Music playlist from inside PocketDJ are written to \
                     your real Apple Music library, and normally arrive within seconds. PocketDJ's \
                     OWN view of that playlist catches up later — the “Apple Music (Local)” source \
                     only changes when the 04:00 nightly library sync re-indexes it — so a song can \
                     be in Apple Music and not yet listed here. That is expected, not a failure.
                     """)
            }
        }
    }

    /// A failed job stores a song id; show the user a title when the catalog still knows it.
    private func songTitle(_ songId: String) -> String {
        app.songsById[songId]?.name ?? songId
    }

    // MARK: CREDENTIALS — MusicKit account

    private var accountSection: some View {
        Section {
            ForEach(streaming.providers, id: \(any StreamingProvider).kind) { provider in
                StreamingAccountRow(provider: provider)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Linking authorizes PocketDJ to play from your Apple Music subscription and to sync playlists and favorites with a token minted on this device — nothing is stored on a server.")
        }
    }

    // MARK: Private syncing — the opt-in toggle + the server credentials it reveals

    /// PRIVATE is a switch, not a mode picker (Levi 2026-07-29): toggled on, the same sync verbs
    /// above reroute through the user's own PocketDJ server + catalog, and the credential fields
    /// appear here. The URL/token are the SAME `ripServerURL`/`ripToken` the rip/import features
    /// use (Settings root ▸ Import server) — two views of one setting, deliberately.
    private var privateSyncSection: some View {
        Section {
            Toggle("Private syncing", isOn: $settings.appleMusicPrivateSync)
                .accessibilityIdentifier("am-private-sync")
            if settings.appleMusicPrivateSync {
                TextField("Server URL", text: $settings.ripServerURL)
                    .pocketField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("am-import-server-url")
                // Plain TextField ON PURPOSE, matching the root Import-server section (same
                // binding — masking one view of a value readable one pane over buys nothing, and
                // iOS secure fields clear on edit, making token tweaks destructive).
                TextField("Token (optional)", text: $settings.ripToken)
                    .pocketField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .accessibilityIdentifier("am-import-server-token")
                HStack {
                    Button {
                        Task { await testImportServer() }
                    } label: {
                        if ripTesting { ProgressView() } else { Label("Test connection", systemImage: "bolt.horizontal") }
                    }
                    .disabled(ripTesting || settings.ripServerURL.isEmpty)
                    .accessibilityIdentifier("am-import-server-test")
                    Spacer()
                    statusView(ripStatus, id: "am-import-server-status")
                }
            }
        } header: {
            Text("Private syncing")
        } footer: {
            Text(settings.appleMusicPrivateSync
                ? "The sync controls above run through your own PocketDJ server and catalog (e.g. the iMac) instead of Apple's API. Same values as Settings ▸ Import server — changing them here changes them everywhere."
                : "Off: syncing talks to Apple Music directly with a token minted on this device — no server of your own. Turn on to run syncing through your own PocketDJ server instead.")
        }
    }

    private func testImportServer() async {
        ripTesting = true; ripStatus = nil
        let result = await RipServerService.health(urlString: settings.ripServerURL,
                                                   token: settings.ripToken, profileId: profile.id)
        switch result {
        case .success(let h):
            var parts: [String] = []
            if let c = h.catalog { parts.append("\(c.songs ?? 0) songs") }
            if let v = h.version { parts.append("v\(v)") }
            if let v = h.version, v < RipServerService.expectedVersion { parts.append("⚠︎ outdated") }
            ripStatus = .ok(parts.isEmpty ? "Online" : parts.joined(separator: " · "))
        case .failure(let e):
            ripStatus = .bad((e as? URLError)?.code == .timedOut ? "Timed out" : "Unreachable")
        }
        ripTesting = false
    }

    // MARK: CREDENTIALS — Sync service (the public backend)

    private var remoteServiceSection: some View {
        Section {
            LabeledContent("Endpoint", value: Config.amPlaylistSyncBase.host() ?? "—")
                .accessibilityIdentifier("am-remote-endpoint")
            HStack {
                Button {
                    Task { await testRemoteService() }
                } label: {
                    if remoteTesting { ProgressView() } else { Label("Test sync service", systemImage: "bolt.horizontal.circle") }
                }
                .disabled(remoteTesting)
                .accessibilityIdentifier("am-remote-test")
                Spacer()
                statusView(remoteStatus, id: "am-remote-status")
            }
        } header: {
            Text("Sync service")
        } footer: {
            Text("The first-party PocketDJ service public syncing talks to. Built in — nothing to configure; this just checks it's reachable.")
        }
    }

    private func testRemoteService() async {
        remoteTesting = true; remoteStatus = nil
        defer { remoteTesting = false }
        do {
            var req = URLRequest(url: Config.amPlaylistSyncBase.appendingPathComponent("health"))
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, String(data: data, encoding: .utf8)?.contains("\"ok\"") == true {
                remoteStatus = .ok("Online")
            } else {
                remoteStatus = .bad("HTTP \(code)")
            }
        } catch {
            remoteStatus = .bad((error as? URLError)?.code == .timedOut ? "Timed out" : "Unreachable")
        }
    }

    // MARK: CREDENTIALS — Owner bootstrap (favorites gate)

    /// The iCloud-hash row is the BOOTSTRAP for owner-gated favorites sync.
    /// `Config.ownerICloudHashes` ships empty — deliberately, so every install is
    /// favorites-local-only until proven otherwise — which means the allowlist can only ever be
    /// filled from a row like this one: run the build, copy the hash, paste it into Config, ship.
    /// Capture the value from EACH build that needs it: `CKContainer.userRecordID` is
    /// container-scoped, so a TestFlight build and a local dev build produce different hashes.
    private var ownerBootstrapSection: some View {
        Section {
            LabeledContent("iCloud hash") {
                Text(hashDisplay)
                    .font(.caption2.monospaced())
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("favorites-sync-hash")
            Button {
                if let ownerHash { copyToPasteboard(ownerHash); copiedHash = true }
            } label: {
                Label(copiedHash ? "Copied" : "Copy hash", systemImage: "doc.on.doc")
            }
            .disabled(ownerHash == nil)
            .accessibilityIdentifier("favorites-sync-copy-hash")

            // Owner-only: the seed is the OWNER's Apple Music ♥, and exporting it from a
            // non-owner install would publish a tester's own favorites to every other tester.
            if (favoritesSync?.isOwner ?? nil) == true {
                Button {
                    exportSeed()
                } label: {
                    Label("Export favorites seed…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("favorites-export-seed")
            }
        } header: {
            Text("Favorites owner bootstrap")
        } footer: {
            Text("Identifies the library owner's install for two-way favorites sync. Copy the hash into the app's owner allowlist to enable it for this build.")
        }
    }

    private var hashDisplay: String {
        if let ownerHash { return ownerHash }
        return loadedHash ? "unavailable" : "…"
    }

    /// Encode the owner's Apple-Music-sourced ♥ and hand them to the file exporter.
    /// The version is a UNIX timestamp: `applySeed` only applies a seed NEWER than the one a
    /// tester already has, so each export must outrank the last.
    private func exportSeed() {
        guard let favoritesSync else { return }
        let seed = favoritesSync.exportSeed(version: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(seed) else { return }
        seedDoc = EditsFile(data: data)
        showSeedExporter = true
    }

    private func copyToPasteboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }

    // MARK: Shared status label

    @ViewBuilder private func statusView(_ status: Status?, id: String) -> some View {
        switch status {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityIdentifier(id)
        case .bad(let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
                .accessibilityIdentifier(id)
        case nil:
            EmptyView()
        }
    }
}

/// A single provider's account row: status line + Log in / Log out button. The row reads
/// provider state reactively (providers are `@Observable`). Moved here from
/// SettingsView+Streaming when the Streaming-accounts section folded into this pane.
struct StreamingAccountRow: View {
    let provider: any StreamingProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(provider.kind.displayName, systemImage: provider.kind.symbol)
                Spacer()
                trailing
            }
            if let detail = statusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("streaming-row-\(provider.kind.rawValue)")
    }

    @ViewBuilder private var trailing: some View {
        switch provider.state {
        case .unavailable:
            Text("Not available")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .authorizing:
            ProgressView()
        case .loggedOut, .failed:
            Button("Log in") { provider.login() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("streaming-login-\(provider.kind.rawValue)")
        case .linked, .connected:
            Button("Log out", role: .destructive) { provider.logout() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("streaming-logout-\(provider.kind.rawValue)")
        }
    }

    private var statusDetail: String? {
        switch provider.state {
        case .unavailable(let reason): return reason
        case .loggedOut: return "Not linked."
        case .authorizing: return "Opening \(provider.kind.displayName)…"
        case .linked(let acct): return acct.map { "Linked: \($0)" } ?? "Linked."
        case .connected(let acct): return acct.map { "Connected: \($0)" } ?? "Connected — ready to play."
        case .failed(let message): return message
        }
    }
}
