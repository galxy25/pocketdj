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
    /// The 👍/👎 log — the tile COUNTS must already exclude rejected songs, or a tile promises
    /// twelve suggestions and opens on nine.
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
        let now = Date().timeIntervalSince1970 * 1000
        // ONE feedback projection PER TILE, because suppression is SCOPED: a song thumbed down in
        // one crate must not vanish from another tile's count. The taste half of each projection
        // is the same global map; only `suppressed` differs.
        //
        // Every count below goes through `visibleCount`, THE SAME function the opened list's
        // header uses — so a card that promises twelve suggestions opens on twelve. Computing the
        // count one way here and the list another way there is exactly how a card and its screen
        // end up disagreeing about what is behind it.
        let zoneFb = feedback?.zoneFeedback(scope: ForYouTileRoute.Kind.zone.rawValue, nowMs: now)
            ?? ZoneEngine.Feedback()
        let crateFb = Dictionary(uniqueKeysWithValues: members.map {
            ($0.id, feedback?.zoneFeedback(scope: $0.id, nowMs: now) ?? ZoneEngine.Feedback())
        })
        let cloudIds = recEngine?.forYou.map(\.songId) ?? []
        let cloudCount = feedback?.visibleCount(cloudIds,
                                                scope: ForYouTileRoute.Kind.suggested.rawValue,
                                                nowMs: now) ?? cloudIds.count
        let releases = releaseFeed?.feed(nowMs: now) ?? []
        let newCount = feedback?.visibleCount(releases.map(\.feedbackId),
                                              scope: ForYouTileRoute.Kind.new.rawValue,
                                              nowMs: now) ?? releases.count

        let computed = await Task.detached(priority: .userInitiated) {
            ForYouTiles.build(
                newReleaseCount: newCount,
                zone: ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                          otherCollections: members.map(\.songIds),
                                          plays: plays, playCount: { counts[$0] ?? 0 },
                                          lastPlayedMs: lastPlayed, feedback: zoneFb,
                                          nowMs: now).songIds,
                collections: members.map { c in
                    (id: c.id, kind: c.kind, name: c.name,
                     suggestions: ZoneEngine.suggestions(memberSongIds: c.songIds, tracks: tracks,
                                                         playCount: { counts[$0] ?? 0 },
                                                         feedback: crateFb[c.id] ?? ZoneEngine.Feedback()))
                },
                cloudSuggestionCount: cloudCount)
        }.value

        tiles = computed
        builtSignature = signature
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
