import SwiftUI

/// Settings ▸ Sync — everything that keeps the app in step with the outside world,
/// gathered into one navigable panel (the Storage-panel pattern):
///   • the Apple Music LIBRARY re-index (ask the Mac's rip server to diff Library.xml
///     for newly-added music — the manual twin of the 04:00 nightly),
///   • the converted-collections SOURCE SYNC (pockets converted from / playlists
///     duplicated from a source playlist following that playlist as the catalog
///     refreshes), with the global toggle and a manual sync-all trigger, and
///   • FAVORITES sync — whether this install's ♥ round-trip with Apple Music, which
///     is owner-gated (see `OwnerIdentity`).
struct SyncSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(MusicSyncClient.self) private var musicSync
    /// Optional on purpose: this panel is reachable from Settings, which is only ever hosted
    /// by the app's own window (where the service IS injected) — but a preview or a future
    /// test host that renders it standalone should degrade to "unavailable", not trap.
    @Environment(FavoritesSyncService.self) private var favoritesSync: FavoritesSyncService?
    /// Optional for the same reason as `favoritesSync` — a preview host may not inject it.
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?

    @State private var syncing = false
    @State private var syncStatus: SyncStatus?
    @State private var collectionsSyncResult: String?
    /// This install's owner hash, resolved once on appear (CloudKit round-trip, then cached
    /// inside OwnerIdentity). `loadedHash` distinguishes "still asking" from "no answer".
    @State private var ownerHash: String?
    @State private var loadedHash = false
    @State private var copiedHash = false
    @State private var showSeedExporter = false
    @State private var seedDoc = EditsFile(data: Data())

    enum SyncStatus { case ok(String), bad(String) }

    /// How many collections carry source provenance (the population the sync watches).
    private var linkedCount: Int {
        collections.pockets.filter(\.hasSource).count +
        collections.playlists.filter(\.hasSource).count
    }

    var body: some View {
        Form {
            appleMusicSection
            collectionsSection
            writeBackSection
            favoritesSection
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
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
    }

    // MARK: Apple Music playlist write-back

    /// The OUTBOUND leg of source-playlist adds, made visible (Levi 2026-07-20). Half of the
    /// "Sweet Thing never reached Apple Music" bug was that the write failed; the other half
    /// was that nothing anywhere said so — the queue settled the job as `.failed` and the only
    /// evidence lived in a JSON file. This section is that evidence, and the retry.
    ///
    /// Hidden entirely when the queue is empty: on a healthy install adds land in seconds and
    /// there is nothing to say, so a permanently-visible "0 pending" row would be noise.
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

    // MARK: Favorites ⇄ Apple Music

    /// Favorites sync lives HERE rather than in Debug (Levi 2026-07-20): whether your ♥
    /// round-trip with Apple Music is a sync question, and this is the sync panel.
    ///
    /// The iCloud-hash row is the BOOTSTRAP for it. `Config.ownerICloudHashes` ships empty —
    /// deliberately, so every install is favorites-local-only until proven otherwise — which
    /// means the allowlist can only ever be filled from a row like this one: run the build,
    /// copy the hash, paste it into Config, ship. Capture the value from EACH build that
    /// needs it: `CKContainer.userRecordID` is container-scoped, so a TestFlight build and a
    /// local dev build produce different hashes and one does not enable the other.
    private var favoritesSection: some View {
        Section {
            LabeledContent("Status", value: gateLine)
                .accessibilityIdentifier("favorites-sync-gate")
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
            .disabled(favoritesSync == nil || favoritesSync?.isSyncing == true)
            .accessibilityIdentifier("favorites-sync-now")

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
            Text("Favorites")
        } footer: {
            Text("""
                 Two-way Apple Music favorites sync is owner-only — every other install keeps \
                 its ♥ to itself, which is the safe default. Your vinyl, My Digital, and Studio \
                 favorites are always local to your profile: they have no Apple Music identity, \
                 so they never leave this device's iCloud account.

                 UN-FAVORITING IS LOSSY ON APPLE MUSIC. Apple ships no delete counterpart to \
                 `POST /v1/me/favorites`, so removing a ♥ here deletes the love RATING (which is \
                 what recommendations and this app read) but cannot retract the ★ — the track \
                 stays in Apple Music's "Favorite Songs" until you remove it there yourself.
                 """)
        }
    }

    private var hashDisplay: String {
        if let ownerHash { return ownerHash }
        return loadedHash ? "unavailable" : "…"
    }

    private var gateLine: String {
        // Flattened deliberately: `favoritesSync?.isOwner` is a DOUBLE optional (no service
        // vs. gate unresolved), and both of those mean the same thing to the reader here.
        guard let isOwner = favoritesSync?.isOwner ?? nil else { return "Checking…" }
        return isOwner ? "Two-way Apple Music sync on"
                       : "Local to this profile"
    }

    /// Encode the owner's Apple-Music-sourced ♥ and hand them to the file exporter.
    /// The version is a UNIX timestamp: `applySeed` only applies a seed NEWER than the one a
    /// tester already has, so each export must outrank the last, and wall-clock does that
    /// without any state to remember between exports.
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

    // MARK: Apple Music library (moved here from the Settings root)

    @ViewBuilder private var appleMusicSection: some View {
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
                Text("Apple Music library")
            } footer: {
                Text(musicSync.hasServer
                    ? "Checks your Mac's Apple Music library (via the rip server) for newly-added music. The library is also checked automatically every day at 04:00. Detected songs appear in the “Apple Music (Local)” source once the change is committed + deployed — not instantly; use “Reload catalog” if a deploy is still in flight."
                    : "Requires the rip server (Settings ▸ Rip server). Once set, this checks your Mac's Apple Music library for newly-added music; it's also checked automatically every day at 04:00.")
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

    // MARK: Converted collections (source sync)

    private var collectionsSection: some View {
        Section {
            Toggle("Sync converted playlists & pockets", isOn: $settings.syncConvertedPockets)
                .accessibilityIdentifier("collections-source-sync")
            HStack {
                Button { syncCollectionsNow() } label: {
                    Label("Sync from sources now", systemImage: "arrow.clockwise")
                }
                .disabled(linkedCount == 0)
                .accessibilityIdentifier("collections-sync-now")
                Spacer()
                if let msg = collectionsSyncResult {
                    Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("collections-sync-result")
                }
            }
        } header: {
            Text("Converted playlists & pockets")
        } footer: {
            Text("\(linkedCount) linked item\(linkedCount == 1 ? "" : "s"). A pocket converted from — or a playlist duplicated from — a source playlist (e.g. Apple Music) follows that playlist as the catalog updates: songs added there appear here, songs removed there are removed here; your own edits stay. Runs automatically on every catalog refresh while the toggle is on; “Sync from sources now” runs one pass immediately. Freeze a single item from its detail-view ▸ menu.")
        }
    }

    /// One manual reconcile pass over every linked item (an explicit user action — runs
    /// even when the automatic toggle is off; per-item opt-outs still apply).
    private func syncCollectionsNow() {
        let changed = collections.syncConvertedCollections(with: app.indexPlaylists)
        collectionsSyncResult = changed == 0 ? "All in sync"
            : "Updated \(changed) item\(changed == 1 ? "" : "s")"
    }
}
