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
    /// The 👍/👎 log — the same one the local tiles and the now-playing surfaces write to.
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    /// How the toolbar's transport starts a set — the same door every other list screen uses.
    @Environment(IntentServices.self) private var intents: IntentServices?
    @Binding var path: NavigationPath

    /// The song an Add-to-collection sheet is up for (`.sheet(item:)` wants Identifiable).
    private struct AddRef: Identifiable {
        let id: String
    }
    @State private var addRef: AddRef?
    /// Ids added on THIS screen — the row states it is now in a collection, so a 👍 that opened a
    /// sheet ends in the same visible state as one that added directly.
    @State private var added: Set<String> = []

    var body: some View {
        Group {
            if let recEngine {
                if recEngine.isLoadingForYou && visible(recEngine).isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible(recEngine).isEmpty {
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
        // The tile's own title (`ForYouTiles.build`) — this screen used to push with a blank nav
        // bar, which now that it floats a toolbar would read as furniture with nothing above it.
        .navigationTitle("Suggested")
        #if os(iOS)
        // Its own line, like every other list screen — five primary-action items leave no room for
        // an inline title on a compact-width iPhone.
        .navigationBarTitleDisplayMode(.large)
        #endif
        // THE SAME FURNITURE AS EVERY OTHER TILE SCREEN — 📱/☁️ · ▶ · ▶▶ · 🔀 · ⋯, from the shared
        // `CollectionToolbar`. ▶ takes the live picks, ▶▶ takes the thumbed-down tail as well
        // (sunk, never filtered), 🔀 shuffles the live picks. A suggestion whose id THIS device's
        // catalog can't resolve is dropped by `playNow` rather than parking the queue — the same
        // degrade-don't-stall rule the rest of the app follows.
        .collectionToolbar(idPrefix: "foryou-cloud", noun: "list",
                           canPlay: !livePicks.isEmpty,
                           play: { start(livePicks, shuffle: $0) },
                           playAll: { start(everything, shuffle: false) },
                           menuItems: { overflowMenu })
        .sheet(item: $addRef) { r in
            AddToCollectionView(item: .song(r.id), onAdded: { _ in added.insert(r.id) })
        }
    }

    /// The ⋯ menu. Refresh USED to be an inline row inside the list ("not a toolbar item —
    /// History's toolbar belongs to the tabs"); this screen now has a toolbar of its own, and the
    /// owner asked for the ⋯ to be where the context actions live, so it moved. Same id, same act.
    @ViewBuilder private var overflowMenu: some View {
        Button {
            Task { await recEngine?.refreshForYou(force: true) }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(recEngine == nil)
        // NOT `foryou-refresh` — that id belongs to History's For You tab menu, which recomputes
        // the LOCAL tiles. This one re-asks the cloud engine, a different act on a different
        // screen, and two live registrations of one id make both unqueryable in XCUITest.
        .accessibilityIdentifier("foryou-cloud-refresh")
    }

    /// The rows still being offered — what ▶ and 🔀 take.
    private var livePicks: [String] {
        guard let recEngine else { return [] }
        let all = recEngine.forYou.map(\.songId)
        return feedback?.partition(all, scope: Self.scope).live ?? all
    }

    /// Everything ▶▶ takes, including the tail thumbed down and sunk to the bottom.
    private var everything: [String] {
        guard let recEngine else { return [] }
        return visible(recEngine).map(\.songId)
    }

    /// Start a queue from this tile and STAMP THE SCOPE, so the now-playing 👍/👎 file against the
    /// cloud tile rather than nothing.
    private func start(_ ids: [String], shuffle: Bool) {
        CollectionPlayback.start(ids, title: "Suggested", shuffle: shuffle, intents: intents,
                                 onStarted: { queue in
                                     feedback?.beginPlayback(scope: Self.scope, songIds: queue)
                                 })
    }

    private func list(_ recEngine: RecommendationService) -> some View {
        List {
            ForEach(visible(recEngine)) { s in
                row(s)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// RECONCILIATION with decisions made elsewhere: applied at RENDER, not at fetch. The verdict
    /// store is `@Observable` and is the only copy, so a 👎 given on the lock screen or in the car
    /// while this screen was closed is already in place when it opens — and one given while it is
    /// open sinks the row immediately. The cached `forYou` payload is never mutated, so an undo
    /// restores the order without a round trip to the server.
    ///
    /// SUNK, not filtered — the same rule every other recommendation surface follows, so the lit
    /// 👎 that undoes a mis-tap stays on screen. A row the SERVER already dropped is not
    /// re-injected here (unlike the local tiles): the server sinks rather than excludes for
    /// exactly this reason, and this client cannot manufacture a suggestion payload it was not
    /// sent.
    private func visible(_ recEngine: RecommendationService) -> [RecommendationService.SongSuggestion] {
        guard let feedback else { return recEngine.forYou }
        let sunk = feedback.activeTombstones(scope: Self.scope)
        guard !sunk.isEmpty else { return recEngine.forYou }
        return recEngine.forYou.filter { sunk[$0.songId] == nil }
            + recEngine.forYou.filter { sunk[$0.songId] != nil }
    }

    /// The reserved scope for the cloud tile — the same string `ForYouTileRoute.feedbackContext`
    /// yields for `.suggested`.
    static let scope = ForYouTileRoute.Kind.suggested.rawValue

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
            // TWO CONTROLS, NOT THREE (owner, 2026-08-07): 👍 records the verdict AND opens the
            // Add sheet — it IS the add — and 👎 records the reject. The separate ＋ that used to
            // sit beside it is gone; a row that offered both made one act look like two. Neither
            // touches the transport.
            RecFeedbackButtons(songId: s.songId, scope: Self.scope, surface: .tile,
                               onAccept: { addRef = AddRef(id: s.songId) })
            if added.contains(s.songId) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("foryou-added-\(s.songId)")
            }
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
