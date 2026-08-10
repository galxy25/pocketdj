import SwiftUI

/// History ▸ For You — a grid of TILES, each one a different way in.
///
/// ── THE ORDER IS PART OF THE SPEC ────────────────────────────────────────────────────────────
/// **New** is always tile 1 and **In Da Zone** is always tile 2; collection tiles follow. That is
/// the owner's rule, and it is enforced in `ForYouTiles.build` (a pure function) rather than by
/// where a `ForEach` happens to put things — so it is unit-tested, and a future tile cannot
/// quietly displace them.
///
/// ── WHAT EACH TILE IS ────────────────────────────────────────────────────────────────────────
///  • **New** — releases from the last 30 days by artists the owner actually plays. The only
///    networked tile (`ReleaseFeedService`); everything it shows was fetched off a PLAY event,
///    never off this render.
///  • **In Da Zone** — what to play right now, ranked from recent play history against the local
///    catalog (`ZoneEngine.inDaZone`). ≤3 songs per artist, 30–90 songs. No network, ever.
///  • **one per collection** — songs worth adding to that playlist/pocket
///    (`ZoneEngine.suggestions`). A collection only gets a tile when it actually yields
///    suggestions, so this list is short and honest rather than one tile per collection.
///
/// ── WHY THE COUNTS ARE COMPUTED IN A TASK, NOT IN `body` ─────────────────────────────────────
/// Ranking runs over the whole catalog (~96k rows). Doing that in a view body would re-rank on
/// every observation change — the exact "derivations in SwiftUI bodies" regression this project
/// has already paid for once. So the grid computes once per (catalog, history, collections)
/// revision into `@State`, and `body` only reads the result.
struct ForYouTilesView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayHistoryStore.self) private var history
    @Environment(CollectionsStore.self) private var collections
    /// Combined (local + Apple) play counts — the familiarity term in the ranking.
    @Environment(PlayCountService.self) private var playCounts
    /// Optional like the other late-added services: always injected by the app, but a preview or
    /// a test host that renders For You standalone degrades to "no New tile content" rather than
    /// trapping.
    @Environment(ReleaseFeedService.self) private var releaseFeed: ReleaseFeedService?
    /// The cloud engine — optional and default-OFF. Its tile appears only when it has answers.
    @Environment(RecommendationService.self) private var recEngine: RecommendationService?
    /// The accept/reject log. Optional for the same reason the two above are: a preview or a test
    /// host that renders For You standalone degrades to "no feedback yet" rather than trapping.
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    @Binding var path: NavigationPath

    @State private var tiles: [ForYouTile] = []
    @State private var isBuilding = false
    /// The inputs the current `tiles` were built from — recomputing only when one of these moves
    /// is what keeps the ranking off the render path.
    @State private var builtSignature: String = ""

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tiles) { tile in
                    Button {
                        path.append(tile.route)
                    } label: {
                        ForYouTileCard(tile: tile)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("foryou-tile-\(tile.id)")
                    // ▶ / 🔀 ON THE CARD, in a context menu rather than as two more glyphs.
                    //
                    // The owner asked for both affordances "on the tile itself, if it does not
                    // crowd the grid" — and it does: the card is 116pt tall in a 150pt-minimum
                    // adaptive grid, already carrying a symbol, a count, a title and a two-line
                    // subtitle. Two more tappable targets there would be finger-sized on nothing.
                    // A context menu (long-press on iOS/visionOS, right-click on macOS) adds zero
                    // pixels, and the same two actions are ALSO in the opened tile's header where
                    // they are discoverable. A tile with nothing playable shows a disabled row
                    // saying so rather than a live control that does nothing.
                    .contextMenu { playMenu(tile) }
                }
            }
            .padding(12)
            // `tiles` is only ever empty BEFORE the first build — the builder always emits the
            // pinned pair — so this is a first-paint spinner, not an empty state. (An "empty
            // state" here would be unreachable code that could still flash on launch.)
            if tiles.isEmpty {
                ProgressView().padding(40)
            }
        }
        .background(Theme.bg)
        .task(id: signature) { await rebuild() }
        // The cloud engine's refresh used to hang off the For You LIST's `.task`; the list now
        // sits one tap away behind its tile, so the trigger moves up here — otherwise the tile
        // could never appear (its count is what decides whether it exists). Gated internally on
        // `isEnabled`, so a default-OFF install does no work and makes no request.
        .task { await recEngine?.refreshForYou() }
    }

    /// Cheap change-detector for the ranking inputs. Reading `playlists`/`pockets` (observed
    /// arrays) is what SUBSCRIBES this view to collection changes; `membershipRevision` is
    /// `@ObservationIgnored`, so it sharpens the comparison but could not wake the view on its
    /// own. `history.revision` moves on every play, which is the frequent trigger in practice.
    private var signature: String {
        "\(app.catalogRevision)|\(history.revision)|\(collections.playlists.count)"
        + "|\(collections.pockets.count)|\(collections.membershipRevision)"
        + "|\(releaseFeed?.revision ?? 0)|\(recEngine?.forYou.count ?? 0)"
        // A thumbs-down given in the car, on the lock screen or on a tile must change what the
        // GRID says the next time it is looked at — the counts are the tile's whole content.
        // `revision` moves on every decision from every surface, which is what makes the two
        // entry points one feature rather than two that can disagree.
        + "|\(feedback?.revision ?? 0)"
    }

    private func rebuild() async {
        guard signature != builtSignature else { return }
        isBuilding = true
        defer { isBuilding = false }

        // Snapshot everything the ranking needs ON the main actor (these are @Observable stores),
        // then do the actual work OFF it.
        //
        // The hop is not premature caution. The zone pass alone is one sweep of the catalog
        // (~96k rows), and the collection pass is ONE SWEEP PER COLLECTION — 40 collections is
        // ~4M scored rows. On the main actor that is a visible hang, which is precisely the
        // failure this app has already had to fix once (Browse search/catalog were moved off the
        // main actor for the same reason). Every captured value is Sendable, so the pure engine
        // moves across cleanly.
        let tracks = app.zoneTracks
        let songs = app.songs
        let genres = app.zoneGenreBySongId
        let plays = history.recentPlaysForZone()
        let counts = playCounts.snapshot()
        // Combined Apple + local last-played. Without it a song he plays daily in Music.app but
        // never through PocketDJ looks dormant, and the rediscovery pool offers it back.
        let lastPlayed = playCounts.lastPlayedSnapshot()
        let members = collections.suggestibleCollections()
        let cloud = recEngine?.forYou.map(\.songId) ?? []
        let now = Date().timeIntervalSince1970 * 1000
        let newCount = releaseFeed?.newReleases(nowMs: now).count ?? 0
        // The feedback projection is built ON the main actor (the store is @MainActor) and handed
        // across as a plain value — the same discipline every other input here follows.
        let signal = feedbackSignal()
        let known = Set(songs.map(\.id))

        let computed = await Task.detached(priority: .userInitiated) {
            let zoneIds = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                              otherCollections: members.map(\.songIds),
                                              plays: plays, playCount: { counts[$0] ?? 0 },
                                              lastPlayedMs: lastPlayed, feedback: signal,
                                              nowMs: now).songIds
            var suggestionsById: [String: [String]] = [:]
            let perCollection = members.map { c -> (id: String, kind: String, name: String, suggestions: [String]) in
                let ids = ZoneEngine.suggestions(memberSongIds: c.songIds, tracks: tracks,
                                                 playCount: { counts[$0] ?? 0 }, feedback: signal)
                suggestionsById[c.id] = ids
                return (id: c.id, kind: c.kind, name: c.name, suggestions: ids)
            }
            return ForYouTiles.build(
                newReleaseCount: newCount,
                zone: zoneIds,
                collections: perCollection,
                cloudSuggestionCount: cloud.count,
                // Every zone/collection id came OUT of the catalog, so they are playable by
                // construction; a CLOUD suggestion can name an id this device cannot resolve, so
                // that one is counted rather than assumed.
                playableZoneIds: zoneIds,
                playableCloudIds: cloud.filter { known.contains($0) },
                playableByCollectionId: suggestionsById)
        }.value

        tiles = computed
        builtSignature = signature
    }

    /// ▶ / 🔀 for one tile. Disabled tiles get an explanatory row instead of a live control, so a
    /// long-press on **New** never presents a Play button that cannot play.
    @ViewBuilder private func playMenu(_ tile: ForYouTile) -> some View {
        if tile.isPlayable {
            Button {
                ForYouPlayback.play(tile.playableSongIds, name: tile.title, shuffle: false,
                                    collections: collections, path: $path)
            } label: { Label("Play in order", systemImage: "play.fill") }
            Button {
                ForYouPlayback.play(tile.playableSongIds, name: tile.title, shuffle: true,
                                    collections: collections, path: $path)
            } label: { Label("Shuffle", systemImage: "shuffle") }
        } else {
            Label(tile.route.kind == .new ? "Nothing to play — add these first"
                                          : "Nothing playable on this device",
                  systemImage: "play.slash")
                .disabled(true)
        }
    }

    /// The accept/reject log projected for the ranking. Catalog lookups are closures so the store
    /// never learns what a song is — it only knows ids.
    private func feedbackSignal() -> ZoneEngine.Feedback {
        guard let feedback else { return ZoneEngine.Feedback() }
        let genres = app.zoneGenreBySongId
        return feedback.signal(
            artistKeyFor: { app.songsById[$0].map { PuzzleSimilarity.artistKey($0.artist) } },
            genreFor: { genres[$0] })
    }

}

// ============================================================================
// MARK: - The tile card
// ============================================================================

private struct ForYouTileCard: View {
    let tile: ForYouTile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: tile.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tile.tint)
                Spacer()
                Text("\(tile.count)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.fg)
            }
            Text(tile.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
            Text(tile.subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(height: 116, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(tile.isPinned ? tile.tint.opacity(0.55) : Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
