import SwiftUI

/// Settings ▸ Sync — everything that keeps the app in step with the outside world,
/// gathered into one navigable panel (the Storage-panel pattern):
///   • the Apple Music LIBRARY re-index (ask the Mac's rip server to diff Library.xml
///     for newly-added music — the manual twin of the 04:00 nightly), and
///   • the converted-collections SOURCE SYNC (pockets converted from / playlists
///     duplicated from a source playlist following that playlist as the catalog
///     refreshes), with the global toggle and a manual sync-all trigger.
struct SyncSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(MusicSyncClient.self) private var musicSync

    @State private var syncing = false
    @State private var syncStatus: SyncStatus?
    @State private var collectionsSyncResult: String?

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
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
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
