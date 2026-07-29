import SwiftUI

/// Settings ▸ Sync — keeping CONVERTED collections in step with their SOURCE playlists
/// (pockets converted from / playlists duplicated from a source playlist follow that playlist
/// as the catalog refreshes; sources include Apple Music, vinyl, and My Digital alike).
///
/// Everything Apple-Music-SPECIFIC that used to live here (library re-index, playlist sync +
/// audit trail, write-back queue + backfill, favorites) moved to the consolidated
/// Settings ▸ Apple Music pane — see `AppleMusicSettingsView` (Levi 2026-07-29).
struct SyncSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections

    @State private var collectionsSyncResult: String?

    /// How many collections carry source provenance (the population the sync watches).
    private var linkedCount: Int {
        collections.pockets.filter(\.hasSource).count +
        collections.playlists.filter(\.hasSource).count
    }

    var body: some View {
        Form {
            collectionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
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
