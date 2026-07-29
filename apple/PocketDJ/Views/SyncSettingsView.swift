import SwiftUI

/// Settings ▸ Sync — everything that keeps the app in step with the outside world,
/// gathered into one navigable panel (the Storage-panel pattern):
///   • the Apple Music LIBRARY re-index (ask the PocketDJ server to diff its Library.xml
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
    @Environment(CollectionActivityStore.self) private var activity
    @Environment(MusicSyncClient.self) private var musicSync
    /// Optional on purpose: this panel is reachable from Settings, which is only ever hosted
    /// by the app's own window (where the service IS injected) — but a preview or a future
    /// test host that renders it standalone should degrade to "unavailable", not trap.
    @Environment(FavoritesSyncService.self) private var favoritesSync: FavoritesSyncService?
    /// Optional for the same reason as `favoritesSync` — a preview host may not inject it.
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?

    /// WS2 bidirectional PocketDJ ↔ Apple Music playlist sync (the AWS Lambda, no iMac/Tailscale).
    /// APP-SCOPED and injected (like `favoritesSync`): a per-panel instance would re-enable the
    /// sync button on re-entry mid-sync and fork the audit trail. Optional for preview hosts.
    @Environment(PlaylistAppleMusicSync.self) private var playlistSync: PlaylistAppleMusicSync?

    @State private var syncing = false
    @State private var syncStatus: SyncStatus?
    @State private var collectionsSyncResult: String?
    @State private var backfillResult: String?
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

    /// The subset of linked collections whose source is Apple Music — the only ones the
    /// write-back backfill can push upstream (vinyl / My Digital have no Apple Music playlist).
    private var appleMusicLinkedCount: Int {
        collections.pockets.filter { $0.hasSource && PlaylistWriteBack.isAppleMusicSource($0.sourceName ?? "") }.count +
        collections.playlists.filter { $0.hasSource && PlaylistWriteBack.isAppleMusicSource($0.sourceName ?? "") }.count
    }

    var body: some View {
        Form {
            appleMusicSection
            playlistSyncSection
            collectionsSection
            backfillSection
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
                 ♥ lives in your PocketDJ profile, in your own iCloud account. Where two-way \
                 Apple Music sync is available on this install, ♥ on an Apple Music song also \
                 loves it in Apple Music — the Status line at the top of this section says \
                 which mode you're in. Vinyl, My Digital, and Studio favorites have no Apple \
                 Music identity, so they never leave this device's iCloud account.

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
                // #TOUPDATE: the no-server branch sends the user to "Settings ▸ Import server", but
                // SettingsView.swift:465/:491 still render "Rip server URL" / "Rip server". That
                // rename ships in this same change-set — confirm it landed, then delete this marker.
                // If it did NOT land, revert this breadcrumb to "Settings ▸ Rip server" instead.
                Text(musicSync.hasServer
                    ? "Checks the Apple Music library on the PocketDJ server for newly-added music. It's also checked automatically every day at 04:00. New songs appear in the “Apple Music (Local)” source after the next catalog publish — not instantly; use “Reload catalog” if one is still landing."
                    : "Requires the import server (Settings ▸ Import server). Once set, this checks the Apple Music library on the PocketDJ server for newly-added music; it's also checked automatically every day at 04:00.")
            }
        }
    }

    /// WS2 — bidirectional PocketDJ ↔ Apple Music PLAYLIST sync, run through the first-party AWS
    /// endpoint (no import server / iMac / Tailscale required). Pushes your playlists into your
    /// Apple Music library and imports your Apple Music playlists back. Device-only (mints a
    /// per-user Apple Music token on the device).
    ///
    /// NOT a bare spinner (Levi 2026-07-29): while syncing this renders the live STEP LIST
    /// (server-published progress — "Reading “Roadtrip” (37/126)"), and afterwards the persisted
    /// AUDIT TRAIL: per-playlist created/updated/reconciled/imported with +added/−removed counts.
    @ViewBuilder private var playlistSyncSection: some View {
        if let playlistSync, playlistSync.isAvailable {
            Section {
                Button {
                    Task { await playlistSync.syncNow(collections: collections, app: app) }
                } label: {
                    Label(playlistSync.isSyncing ? "Syncing…" : "Sync playlists with Apple Music",
                          systemImage: "arrow.triangle.2.circlepath.circle")
                }
                .disabled(playlistSync.isSyncing)
                .accessibilityIdentifier("settings-am-playlist-sync")

                // Live step-by-step progress — persisted to app storage on every change, so this
                // recap survives navigating away, backgrounding, and even an app kill mid-sync
                // (an interrupted run hydrates back with ⏸ steps and the resume hint below).
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
            } header: {
                Text("Apple Music playlists")
            } footer: {
                Text("Two-way sync between your PocketDJ playlists and your Apple Music library — no import server needed. Runs on your device (requires an Apple Music subscription). A playlist is created in Apple Music only if it isn't there yet; after that, syncs only add its missing songs — an interrupted sync picks up where it left off.")
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
            // kind+name (two same-named playlists both "updated") and identical error strings —
            // value-derived ids would collide. Reports are immutable once appended, so offsets
            // are stable.
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

    // MARK: Catch up Apple Music (write-back backfill)

    /// The PUSH counterpart to `collectionsSection`'s pull. Adding a song to a converted /
    /// duplicated Apple Music collection now writes it back to the real Apple Music playlist —
    /// but adds made BEFORE that wiring shipped (or while offline / signed out) never queued.
    /// This re-drives them from the collection ADD history, bounded to the last N days.
    ///
    /// Shown only where a write-back can actually happen (iOS/visionOS with an Apple Music
    /// source linked); hidden on macOS — `MusicLibrary` writes don't exist there — exactly like
    /// `writeBackSection`, so the panel never offers an action this device can't perform.
    @ViewBuilder private var backfillSection: some View {
        if writeBack?.canWriteBack == true, appleMusicLinkedCount > 0 {
            Section {
                Stepper(value: $settings.writeBackBackfillDays,
                        in: 1...CollectionsStore.writeBackBackfillMaxDays) {
                    LabeledContent("Look back",
                                   value: "\(settings.writeBackBackfillDays) day\(settings.writeBackBackfillDays == 1 ? "" : "s")")
                }
                .accessibilityIdentifier("writeback-backfill-days")
                HStack {
                    Button { runBackfill() } label: {
                        Label("Send my adds to Apple Music", systemImage: "arrow.up.circle")
                    }
                    .accessibilityIdentifier("writeback-backfill-run")
                    Spacer()
                    if let msg = backfillResult {
                        Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                            .accessibilityIdentifier("writeback-backfill-result")
                    }
                }
            } header: {
                Text("Catch up Apple Music")
            } footer: {
                Text("""
                     Songs you add to a pocket or playlist that came from an Apple Music list are \
                     also added to that Apple Music playlist. This re-sends any adds from the last \
                     \(settings.writeBackBackfillDays) day\(settings.writeBackBackfillDays == 1 ? "" : "s") \
                     that never made it — made before this was turned on, or while you were offline \
                     or signed out. Songs already in Apple Music are skipped. You can look back up \
                     to \(CollectionsStore.writeBackBackfillMaxDays) days.
                     """)
            }
        }
    }

    /// Re-drive the write-back for the chosen look-back window. Idempotent — the queue dedups —
    /// so a repeat tap reports "Nothing new to send" once everything is queued.
    private func runBackfill() {
        let n = collections.backfillSourceWriteBacks(from: activity.events,
                                                     days: settings.writeBackBackfillDays,
                                                     localInstallId: activity.installId)
        backfillResult = n == 0 ? "Nothing new to send"
            : "Sending \(n) song\(n == 1 ? "" : "s") to Apple Music"
    }
}
