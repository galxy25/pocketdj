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
///    networked tile (`ReleaseFeedService`); everything it shows was fetched off a PLAY event or
///    the one-shot listening seed, never off this render. It is the one tile whose rows he does
///    NOT own — which is why acting on a row means opening the release, and why playing the tile
///    STREAMS it (`ReleaseStreaming`) instead of resolving catalog ids.
///  • **In Da Zone** — what to play right now, ranked from recent play history against the local
///    catalog (`ZoneEngine.inDaZone`). ≤3 songs per artist, 30–90 songs. No network, ever.
///  • **one per collection** — songs worth adding to that playlist/pocket
///    (`ZoneEngine.suggestions`). A collection only gets a tile when it actually yields
///    suggestions, so this list is short and honest rather than one tile per collection.
///
/// ── CACHED, NOT RECOMPUTED (the owner's rule) ────────────────────────────────────────────────
/// This view used to re-rank whenever a signature of `(catalogRevision, history.revision,
/// collection counts, membershipRevision, releaseFeed.revision)` moved — i.e. on every play and
/// every add, WHILE HE WAS LOOKING AT IT. Owner, verbatim: *"history for you should cache the last
/// result and only refresh when you hit a refresh button in the menu."*
///
/// So the ranking now lives in `ForYouFeedStore` (durable JSON), the grid renders it verbatim on
/// every open including a cold launch, and the ONLY things that recompute it are the tab menu's
/// Refresh and a first-ever build on an empty cache. `body` derives tile CARDS from those frozen
/// ids — a cheap pass over a few thousand ids, never a catalog sweep.
///
/// THE ONE EXCEPTION IS THE OWNER'S OWN FEEDBACK. A 👍/👎 is him acting on this list, not the
/// engine changing its mind: it re-runs the cheap derivation (counts drop, rejected rows sink)
/// immediately, without touching the frozen ranking. Freezing the list must not freeze his hands.
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
    /// The frozen feed. Optional for the same reason as the others; with no store the grid still
    /// works, it just cannot persist across launches (an in-memory fallback stands in).
    @Environment(ForYouFeedStore.self) private var feed: ForYouFeedStore?
    /// What the New card's ▶ needs — the two expansion tiers plus the queue itself. See
    /// `ReleaseStreaming`.
    @Environment(RipsStore.self) private var rips
    @Environment(StreamingStore.self) private var streaming
    @Environment(SetlistPlayer.self) private var sequencer
    @Binding var path: NavigationPath
    /// Bumped by History's tab menu ▸ Refresh. The ONLY external trigger for a recompute.
    var refreshToken: Int = 0

    @State private var tiles: [ForYouTile] = []
    /// A New-card expansion is in flight (one network round trip per release).
    @State private var startingReleases = false
    /// Stands in for `feed` when no store is injected (previews / standalone test hosts). Not
    /// durable, which is exactly the degradation intended.
    @State private var fallback = ForYouFeedSnapshot()
    @State private var fallbackRefreshing = false
    /// Re-renders the "Updated …" line without a timer thrash — recomputed whenever the tiles are.
    @State private var updatedLabel = ""

    private var snapshot: ForYouFeedSnapshot { feed?.snapshot ?? fallback }
    private var isRefreshing: Bool { feed?.isRefreshing ?? fallbackRefreshing }

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
                    // A TILE IS A SETLIST — so it gets the SAME menu a collection does, from the
                    // same component. Long-press / right-click, the standard iOS place for it.
                    .contextMenu { tileMenu(tile) }
                }
            }
            .padding(12)
            // A cold install has nothing cached and is building its first feed — that is the ONLY
            // state that shows a spinner. Every later open paints the cache on the first frame.
            if tiles.isEmpty && !snapshot.hasResult {
                ProgressView().padding(40)
            }
        }
        .background(Theme.bg)
        // The staleness readout. A frozen feed has to say it is frozen.
        .safeAreaInset(edge: .top, spacing: 0) { freshnessBar }
        // Derive the CARDS (cheap: counts over frozen ids). Never the ranking.
        .task(id: derivationKey) { deriveTiles() }
        // FIRST POPULATION only — and NOT before the catalog has landed.
        //
        // The gate is load-bearing. A refresh against an empty catalog produces an empty ranking,
        // and that empty ranking would then be STAMPED as the cached result — leaving a brand-new
        // install with a permanently blank For You that only a manual Refresh could fix. Keying
        // the task on `app.state` is what re-arms it the moment the catalog arrives.
        .task(id: app.state) {
            guard !snapshot.hasResult, app.state == .loaded else { return }
            await refresh()
        }
        // The owner's Refresh, from History's tab menu.
        .onChange(of: refreshToken) { _, _ in Task { await refresh() } }
        // The cloud engine's refresh used to hang off the For You LIST's `.task`; the list now
        // sits one tap away behind its tile, so the trigger moves up here — otherwise the tile
        // could never appear (its count is what decides whether it exists). Gated internally on
        // `isEnabled`, so a default-OFF install does no work and makes no request.
        .task { await recEngine?.refreshForYou() }
    }

    // ========================================================================
    // MARK: - Freshness
    // ========================================================================

    private var freshnessBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.caption2)
            Text(isRefreshing ? "Refreshing…" : updatedLabel)
                .font(.caption2)
                .accessibilityIdentifier("foryou-updated-at")
            Spacer()
            if isRefreshing { ProgressView().controlSize(.mini) }
        }
        .foregroundStyle(Theme.fgDim)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    // ========================================================================
    // MARK: - Deriving the cards from the frozen ids
    // ========================================================================

    /// What makes the CARDS different — never what makes the RANKING different.
    ///
    ///  • `feed.revision` — a refresh landed.
    ///  • `feedback.revision` — the owner thumbed something: counts drop, rows sink. IMMEDIATE.
    ///  • `releaseFeed.revision` / cloud count — the two tiles that are deliberately NOT frozen
    ///    (their content lives in their own caches and their screens read those directly, so a
    ///    frozen count here would disagree with the screen behind the card).
    ///  • collection count — a collection deleted out from under a cached tile.
    private var derivationKey: String {
        "\(feed?.revision ?? 0)|\(snapshot.refreshedAtMs)|\(feedback?.revision ?? 0)"
        + "|\(releaseFeed?.revision ?? 0)|\(recEngine?.forYou.count ?? 0)"
        + "|\(collections.playlists.count)|\(collections.pockets.count)"
    }

    private func deriveTiles() {
        let now = Date().timeIntervalSince1970 * 1000
        updatedLabel = ForYouFeedStore.updatedLabel(refreshedAtMs: snapshot.refreshedAtMs, nowMs: now)

        // The LIVE half of each list — the rows still being offered, with the thumbed-down tail
        // taken off. `RecFeedbackOrder.sink` is the one implementation of that partition, and the
        // opened list renders from the same call, so a card that promises twelve suggestions
        // cannot open on nine.
        func live(_ ids: [String], _ scope: String) -> [String] {
            feedback?.partition(ids, scope: scope, nowMs: now).live ?? ids
        }

        let releases = releaseFeed?.feed(nowMs: now) ?? []
        let soon = releases.filter { $0.status == .comingSoon }
        let newScope = ForYouTileRoute.Kind.new.rawValue
        let cloudIds = recEngine?.forYou.map(\.songId) ?? []

        // Drop a cached tile whose collection has since been deleted — the ONE way a frozen feed
        // could offer a door to nothing.
        let crates = snapshot.crates.filter {
            collections.playlist($0.id) != nil || collections.pocket($0.id) != nil
        }

        let newCount = live(releases.map(\.feedbackId), newScope).count
        tiles = ForYouTiles.build(
            newReleaseCount: newCount,
            comingSoonCount: live(soon.map(\.feedbackId), newScope).count,
            zone: live(snapshot.zoneIds, ForYouTileRoute.Kind.zone.rawValue),
            collections: crates.map { c in
                (id: c.id, kind: c.kind, name: c.name, suggestions: live(c.songIds, c.id))
            },
            cloudSuggestionCount: live(cloudIds, ForYouTileRoute.Kind.suggested.rawValue).count,
            // A ZERO ON THE NEW TILE HAS FOUR DIFFERENT CAUSES. Say which — a bare 0 with
            // "no releases in the last 30 days" beneath it is the card asserting something it
            // has not checked, and it is why this feature read as broken.
            newEmptyNote: newCount == 0 ? releaseFeed?.emptyReason().tileNote : nil)
    }

    // ========================================================================
    // MARK: - Refresh (the ONLY recompute)
    // ========================================================================

    /// Snapshot everything the ranking needs ON the main actor (these are @Observable stores),
    /// then hand it to the store, which does the work OFF it.
    ///
    /// The hop is not premature caution. The zone pass alone is one sweep of the catalog (~96k
    /// rows), and the collection pass is ONE SWEEP PER COLLECTION — 40 collections is ~4M scored
    /// rows. On the main actor that is a visible hang, which is precisely the failure this app has
    /// already had to fix once (Browse search/catalog were moved off the main actor for the same
    /// reason). Every captured value is Sendable, so the pure engine moves across cleanly.
    private func refresh() async {
        let members = collections.suggestibleCollections()
        let now = Date().timeIntervalSince1970 * 1000
        // ONE feedback projection PER TILE, because suppression is SCOPED: a song thumbed down in
        // one crate must not vanish from another tile's list.
        let inputs = ForYouFeedInputs(
            songs: app.songs,
            tracks: app.zoneTracks,
            genreBySongId: app.zoneGenreBySongId,
            plays: history.recentPlaysForZone(),
            playCount: playCounts.snapshot(),
            // Combined Apple + local last-played. Without it a song he plays daily in Music.app but
            // never through PocketDJ looks dormant, and the rediscovery pool offers it back.
            lastPlayedMs: playCounts.lastPlayedSnapshot(),
            crates: members.map { .init(id: $0.id, kind: $0.kind, name: $0.name, songIds: $0.songIds) },
            zoneFeedback: feedback?.zoneFeedback(scope: ForYouTileRoute.Kind.zone.rawValue, nowMs: now)
                ?? ZoneEngine.Feedback(),
            crateFeedback: Dictionary(uniqueKeysWithValues: members.map {
                ($0.id, feedback?.zoneFeedback(scope: $0.id, nowMs: now) ?? ZoneEngine.Feedback())
            }),
            nowMs: now)

        if let feed {
            await feed.refresh(inputs)
        } else {
            guard !fallbackRefreshing else { return }
            fallbackRefreshing = true
            defer { fallbackRefreshing = false }
            fallback = await Task.detached(priority: .userInitiated) {
                ForYouFeedBuilder.build(inputs)
            }.value
        }
        deriveTiles()
    }

    // ========================================================================
    // MARK: - The tile menu (shared with collections)
    // ========================================================================

    /// A tile IS a setlist, so its menu is `CollectionPlayMenuItems` — the same ▶ / ▶▶ / 🔀 the
    /// tile's own screen floats in its toolbar, in the one place a CARD can carry actions — rather
    /// than a tile-specific copy.
    ///
    /// **New goes through its own door**, not because it can't play (it can — owner, verbatim:
    /// *"we want to be able to play or shuffle New as well"*) but because its rows are RELEASES
    /// that have to be expanded into tracks and streamed by store id. `ReleaseStreaming` is that
    /// path, shared with `NewReleasesView`, so the card and the screen behind it start the same
    /// queue.
    @ViewBuilder private func tileMenu(_ tile: ForYouTile) -> some View {
        if tile.route.kind == .new {
            let releases = releaseFeed?.outNow() ?? []
            let scope = ForYouTileRoute.Kind.new.rawValue
            let sunk = feedback?.activeTombstones(scope: scope) ?? [:]
            let live = releases.filter { sunk[$0.feedbackId] == nil }
            Button { startReleases(live, shuffle: false) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(live.isEmpty || startingReleases)
            .accessibilityIdentifier("foryou-tile-\(tile.id)-play")
            CollectionPlayAllButton(idPrefix: "foryou-tile-\(tile.id)") {
                startReleases(releases, shuffle: false)
            }
            .disabled(releases.isEmpty || startingReleases)
            Button { startReleases(live, shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(live.isEmpty || startingReleases)
            .accessibilityIdentifier("foryou-tile-\(tile.id)-shuffle")
        } else {
            let ids = playableIds(for: tile.route)
            let p = feedback?.partition(ids, scope: tile.route.feedbackContext) ?? (live: ids, sunk: [])
            CollectionPlayMenuItems(title: tile.title, songIds: p.live, sunkIds: p.sunk,
                                    idPrefix: "foryou-tile-\(tile.id)",
                                    onStarted: { queue in
                                        feedback?.beginPlayback(scope: tile.route.feedbackContext,
                                                                songIds: queue)
                                    })
        }
    }

    /// The New card's ▶ — the SAME expansion + `am:<storeID>` queue `NewReleasesView` uses. Only
    /// **out now** releases: a "coming soon" row is a pre-order with no audio behind it.
    private func startReleases(_ items: [ReleaseFeedItem], shuffle: Bool) {
        let ids = items.compactMap(\.entry.releaseId)
        guard !ids.isEmpty, !startingReleases else { return }
        startingReleases = true
        let library = streaming.providers.libraryContributors.first
        Task {
            let rows = await ReleaseStreaming.tracks(forReleaseIds: ids, rips: rips, library: library)
            var queue = ReleaseStreaming.items(rows, catalogSongId: { app.songId(forAppleMusicId: $0) })
            if shuffle { queue.shuffle() }
            startingReleases = false
            guard !queue.isEmpty else { return }
            sequencer.play(queue)
        }
    }

    /// The frozen ids behind a tile. `.suggested` is not frozen (the server owns it), so it is
    /// read live — the same rule its card's count follows.
    private func playableIds(for route: ForYouTileRoute) -> [String] {
        if route.kind == .suggested { return recEngine?.forYou.map(\.songId) ?? [] }
        return snapshot.songIds(forTileId: route.tileId) ?? []
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
