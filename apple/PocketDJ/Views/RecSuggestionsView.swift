import SwiftUI

/// The CLOUD recommendation engine's song suggestions.
///
/// This used to BE the For You tab. For You is now a tile grid (`ForYouTilesView`), and this
/// screen is what the "Suggested" tile opens — the tile only appears while the Settings toggle
/// (or the UI-test fixture seam) has the engine on AND it has returned something, so a
/// default-OFF install never sees an empty tile for a feature it hasn't enabled.
///
/// It is kept as its own view, unchanged, rather than being folded into `ForYouSongListView`
/// for one specific reason: rows here render STANDALONE from the wire name/artist — a suggestion
/// whose id this device's catalog can't resolve (source toggled off, another source's id space)
/// still shows as text + its Add button. The local tiles rank ids that are by construction IN
/// the catalog, so they read the catalog row; merging the two would have quietly cost this
/// screen its offline/unresolvable-id behavior.
struct RecSuggestionsListView: View {
    @Environment(RecommendationService.self) private var recEngine: RecommendationService?
    @Environment(AppModel.self) private var app
    @Binding var path: NavigationPath

    /// The song an Add-to-collection sheet is up for (`.sheet(item:)` wants Identifiable).
    private struct AddRef: Identifiable {
        let id: String
    }
    @State private var addRef: AddRef?

    var body: some View {
        Group {
            if let recEngine {
                if recEngine.isLoadingForYou && recEngine.forYou.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if recEngine.forYou.isEmpty {
                    emptyState(error: recEngine.syncError)
                } else {
                    list(recEngine)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await recEngine?.refreshForYou() }
        .sheet(item: $addRef) { r in
            AddToCollectionView(item: .song(r.id))
        }
    }

    private func list(_ recEngine: RecommendationService) -> some View {
        List {
            // Inline refresh row (not a toolbar item — History's toolbar belongs to the tabs).
            HStack {
                Spacer()
                Button {
                    Task { await recEngine.refreshForYou(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("foryou-refresh")
            }
            .listRowBackground(Color.clear)
            ForEach(recEngine.forYou) { s in
                row(s)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func row(_ s: RecommendationService.SongSuggestion) -> some View {
        let resolved = app.songsById[s.songId]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                if !s.artist.isEmpty {
                    Text(s.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                if let reason = s.reasons.first {
                    Text(reason).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
            }
            // The row id lives on the TEXT stack, not the row container: a container id would
            // absorb the add/transport buttons' identifiers (the propagation trap).
            .accessibilityIdentifier("foryou-row-\(s.songId)")
            Spacer()
            Button {
                addRef = AddRef(id: s.songId)
            } label: {
                Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("foryou-add-\(s.songId)")
            if let song = resolved {
                RowTransport(song: (id: song.id, title: song.name, artist: song.artist),
                             startMs: nil)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if let song = resolved { path.append(song) } }
    }

    private func emptyState(error: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text("No suggestions yet").font(.headline).foregroundStyle(Theme.fg)
            Text(error ?? "Play more music — suggestions appear here.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("foryou-empty")
    }
}
