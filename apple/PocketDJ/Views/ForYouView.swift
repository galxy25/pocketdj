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
///  • **In Da Zone** — what to play right now. TWO POSSIBLE RANKERS: the cloud recommendation
///    engine when it is enabled AND answers (`RecommendationService.cloudZoneRanking`), the local
///    `ZoneEngine.inDaZone` otherwise. Either way the ids come out through
///    `ZoneEngine.shapeCloudRanking` / `inDaZone` and obey the same rules — ≤3 songs per artist,
///    ≥50% rediscovery, thumbed-down rows removed. The engine is opt-in and ships OFF, so the
///    local path is the common case and must not regress; the cloud path never blocks a render.
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
    /// The cloud engine — optional and default-OFF. It no longer has a tile of its own; it is one
    /// of the two possible RANKERS behind In Da Zone (see `refresh`).
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
    /// The refresh CADENCE (Settings ▸ For You). Read here, not observed by a timer — see
    /// `refreshIfScheduleDue`.
    @Environment(SettingsStore.self) private var settings
    /// The other half of "evaluate at read time": returning to the app is a read.
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: NavigationPath
    /// Bumped by History's tab menu ▸ Refresh. The ONLY external trigger for a recompute.
    var refreshToken: Int = 0

    @State private var tiles: [ForYouTile] = []
    /// A New-card expansion is in flight (one network round trip per release).
    @State private var startingReleases = false
    /// The expansion came back with nothing playable — stated here exactly as the New screen
    /// states it, rather than the card's earlier silent `return`.
    @State private var startError: String?
    /// Stands in for `feed` when no store is injected (previews / standalone test hosts). Not
    /// durable, which is exactly the degradation intended.
    @State private var fallback = ForYouFeedSnapshot()
    @State private var fallbackRefreshing = false
    /// Re-renders the "Updated …" line without a timer thrash — recomputed whenever the tiles are.
    @State private var updatedLabel = ""
    /// "…and here is where you turn it back on." Set when a tile's ⋯ switches recommendations OFF,
    /// because the act REMOVES THE VERY CONTROL THAT DID IT — the tile is gone on the next frame,
    /// and with it the only ⋯ the owner has seen this switch in. Saying nothing would make an
    /// undoable action look permanent. See `recsToggleMenuItem`.
    @State private var recsOffNotice: String?

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
            guard app.state == .loaded else { return }
            guard snapshot.hasResult else { await refresh(); return }
            // Already have a cache — it is ALREADY on screen (this `.task` runs after the first
            // frame). Only the schedule can replace it, and only if it has fallen due.
            await refreshIfScheduleDue()
        }
        // The SCHEDULE'S SECOND READ POINT. Opening the tab is covered above; this covers the app
        // being brought back after 16:20 on a Friday went by while it was in the background —
        // without a timer, and without a sweep that could fail to fire.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshIfScheduleDue()
        }
        // The owner's Refresh, from History's tab menu. Works under EVERY cadence, `.manual`
        // included — a schedule adds a trigger, it never replaces his hands.
        .onChange(of: refreshToken) { _, _ in Task { await refresh() } }
        // THERE IS NO `.task { refreshForYou() }` HERE ANY MORE, and its absence is the point.
        // The cloud fetch used to fire on every appearance because a tile's very existence
        // depended on it. It now feeds In Da Zone, which is part of the FROZEN feed — so the
        // fetch belongs to the refresh (see `refresh`), under the owner's cache-don't-recompute
        // rule, rather than to the render. A tab open costs zero requests.
        .alert("Couldn’t start these releases",
               isPresented: Binding(get: { startError != nil },
                                    set: { if !$0 { startError = nil } })) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "")
        }
        // WHERE IT COMES BACK. Not a toast: the tile vanishing is the confirmation, so this alert
        // exists solely to carry the two places the switch still lives once it has.
        .alert("Recommendations off",
               isPresented: Binding(get: { recsOffNotice != nil },
                                    set: { if !$0 { recsOffNotice = nil } })) {
            Button("OK") { recsOffNotice = nil }
        } message: {
            Text(recsOffNotice ?? "")
        }
        // A tile card can start a New queue without ever opening the New screen, so the grid wears
        // the device-mode banner for it too — otherwise device mode dead-ends here in silence.
        // Only while the grid is what's in front: `NewReleasesView`, pushed onto this same stack,
        // wears the identical condition and must own it once it is.
        .deviceQueueUnplayableAlert(sourceId: ReleaseStreaming.runTag, isActive: path.isEmpty)
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
    ///  • `feed.revision` — a refresh landed (INCLUDING the cloud engine's second commit).
    ///  • `feedback.revision` — the owner thumbed something: counts drop, rows sink. IMMEDIATE.
    ///  • `releaseFeed.revision` — New is deliberately NOT frozen (its content lives in its own
    ///    cache and its screen reads that directly, so a frozen count here would disagree with the
    ///    screen behind the card).
    ///  • collection count — a collection deleted out from under a cached tile.
    ///
    /// The cloud engine is NOT a key any more: its answer reaches the grid through the frozen
    /// snapshot's `zoneIds`/`zoneSource`, so `feed.revision` already covers it. Keying on live
    /// `recEngine` state as well would re-derive the cards off a fetch that has not been committed
    /// — the tile would count one list while its screen showed another.
    ///  • `collections.membershipRevision` — an ADD landed. This is a CARD change, not a ranking
    ///    change, and the distinction is the whole reason it is safe to key on here: the frozen ids
    ///    are untouched, the membership filter over them just has one more song to drop. Leaving it
    ///    out was the gap — a 👍 filed the song and the tile went on counting it.
    ///  • the RECOMMENDATIONS OPT-OUT set — switching a collection off must take its tile away NOW,
    ///    not at the next refresh, and the frozen snapshot still holds that crate until then. The
    ///    ids themselves (sorted) rather than their count: off-A-then-on-A-then-off-B leaves the
    ///    count at 1 while the answer changed completely, and a key that cannot see that would
    ///    leave one dead tile up and one live tile missing.
    private var derivationKey: String {
        "\(feed?.revision ?? 0)|\(snapshot.refreshedAtMs)|\(feedback?.revision ?? 0)"
        + "|\(releaseFeed?.revision ?? 0)"
        + "|\(collections.playlists.count)|\(collections.pockets.count)"
        + "|\(collections.membershipRevision)"
        + "|\(collections.recommendationsOffIds().sorted().joined(separator: ","))"
    }

    /// Derive the cards. The whole computation lives in `ForYouGrid.tiles` — moved out of this view
    /// when CarPlay grew a For You tab, because the owner's requirement there is that the car's
    /// tiles match the phone's ORDER, and two implementations of "which tiles, in what order" is
    /// exactly how that stops being true. One function, two surfaces, and the one that cannot be
    /// headless-tested (CarPlay) inherits this one's tests.
    private func deriveTiles() {
        let now = Date().timeIntervalSince1970 * 1000
        updatedLabel = ForYouFeedStore.updatedLabel(refreshedAtMs: snapshot.refreshedAtMs, nowMs: now)
        tiles = ForYouGrid.tiles(snapshot: snapshot, collections: collections,
                                 feedback: feedback, releaseFeed: releaseFeed, nowMs: now)
    }

    // ========================================================================
    // MARK: - Refresh (the ONLY recompute)
    // ========================================================================

    /// THE SCHEDULED REFRESH (Settings ▸ For You ▸ Refresh — default Weekly, Friday 16:20).
    ///
    /// Called when For You is READ: the tab opening, and the app coming back to the foreground.
    /// Deliberately NOT a timer or a scheduled sweep — the app is usually not running at 16:20 on
    /// a Friday, and a sweep that never fires would freeze the feed permanently. `isDue` asks
    /// whether the most recent scheduled instant has passed and the cache predates it, so a slot
    /// missed while the phone was off fires on the next open instead of being skipped.
    ///
    /// It cannot block the first paint: `.task` runs after the first frame, the cached grid is
    /// already on screen, and the freshness bar flips to "Refreshing…" while the pass runs.
    private func refreshIfScheduleDue() async {
        guard app.state == .loaded, !isRefreshing else { return }
        guard ForYouRefreshSchedule.isDue(nowMs: Date().timeIntervalSince1970 * 1000,
                                          lastRefreshedAtMs: snapshot.refreshedAtMs,
                                          cadence: settings.forYouRefreshCadence,
                                          minutesOfDay: settings.forYouRefreshMinutes,
                                          weekday: settings.forYouRefreshWeekday) else { return }
        await refresh()
    }

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
        // The switched-off crates. They stay in `members` — that list is also In Da Zone's
        // co-membership signal — and are named separately so the builder skips their (expensive)
        // suggestion sweep. See `ForYouFeedInputs.recsOffCrateIds`.
        let recsOff = collections.recommendationsOffIds()
        let now = Date().timeIntervalSince1970 * 1000
        // THE TIMBRE CORPUS (audio-similarity v2) — awaited BEFORE the inputs are frozen, off the
        // paint path (the cached grid is already on screen; this is the refresh, not the render).
        // First call decodes the 2.9 MB corpus once on the actor; after that it is a memo hit.
        // Unavailable — offline cold install, corpus not deployed — arrives as [:], which is the
        // term-dead, byte-identical-to-pre-v2 ranking. Fail open, never a spinner.
        let timbre = await TimbreCatalog.shared.vectors(nowMs: now)
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
            crateFeedback: Dictionary(uniqueKeysWithValues: members
                .filter { !recsOff.contains($0.id) }
                .map {
                    ($0.id, feedback?.zoneFeedback(scope: $0.id, nowMs: now) ?? ZoneEngine.Feedback())
                }),
            recsOffCrateIds: recsOff,
            timbre: timbre,
            nowMs: now)

        // THE CLOUD RANKER FOR In Da Zone, or nil. nil is not a degraded mode — it is the DEFAULT
        // configuration (the engine ships off), and it means the store never awaits a network call
        // at all. `cloudZoneRanking` re-checks the same gate, so this is belt-and-braces rather
        // than the only guard.
        let cloudZone: (() async -> [ForYouCloudZoneRow])?
        if let recEngine, recEngine.isEnabled {
            cloudZone = { await recEngine.cloudZoneRanking() }
        } else {
            cloudZone = nil
        }

        if let feed {
            await feed.refresh(inputs, cloudZone: cloudZone)
        } else {
            guard !fallbackRefreshing else { return }
            fallbackRefreshing = true
            defer { fallbackRefreshing = false }
            var built = await Task.detached(priority: .userInitiated) {
                ForYouFeedBuilder.build(inputs)
            }.value
            fallback = built
            deriveTiles()   // the local answer lands before the network is even asked
            if let cloudZone {
                let rows = await cloudZone()
                if !rows.isEmpty {
                    built = ForYouFeedBuilder.applyingCloudZone(built, cloudZone: rows,
                                                                inputs: inputs)
                    fallback = built
                }
            }
        }
        deriveTiles()
        await scheduleAudioAnalysis(inputs)
    }

    /// TARGETED AUDIO ANALYSIS, scheduled off the ranking that just landed.
    ///
    /// Ordered LAST on purpose, after `deriveTiles()`: it is a background errand for the *next*
    /// ranking, not part of producing this one, and nothing the owner is looking at may wait on
    /// it. It is also the only place the two refresh paths (`feed` and the `fallback`) can be
    /// joined, since both have committed a snapshot by the time it runs.
    ///
    /// The whole selection happens on device (`ForYouFeedBuilder.audioShortlist`) and only the
    /// resulting ids are handed to the service, which rides them onto the next `/events` flush.
    /// With the engine off — the default — `enqueueAudioAnalysis` returns immediately and this
    /// costs one dictionary build over ids the refresh already had in hand.
    private func scheduleAudioAnalysis(_ inputs: ForYouFeedInputs) async {
        guard let recEngine, recEngine.isEnabled else { return }
        let snapshot = feed?.snapshot ?? fallback
        guard snapshot.hasResult else { return }
        let pending = recEngine.audioPendingIds
        let ids = await Task.detached(priority: .background) {
            ForYouFeedBuilder.audioShortlist(snapshot, inputs: inputs, pending: pending)
        }.value
        recEngine.enqueueAudioAnalysis(ids)
    }

    // ========================================================================
    // MARK: - The tile menu (shared with collections)
    // ========================================================================

    /// A tile IS a setlist, so its menu is `CollectionPlayMenuItems` — the same ▶ / 🔀 the tile's
    /// own screen floats in its toolbar, in the one place a CARD can carry actions — rather than a
    /// tile-specific copy.
    ///
    /// Both take the LIVE rows only. The card used to carry a third item, ▶▶ Play All, which added
    /// the thumbed-down tail; the owner removed it (*"we don't need play all, if we thumbs down we
    /// don't need to play those tracks."*) and it had to go from the card and the screen together,
    /// or the two would offer different sets of controls for the same tile.
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
            Button { startReleases(live, shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(live.isEmpty || startingReleases)
            .accessibilityIdentifier("foryou-tile-\(tile.id)-shuffle")
        } else {
            let ids = playableIds(for: tile.route)
            // The LIVE half only. The sunk tail still renders on the tile's own screen, where its
            // lit 👎 can be undone — it is a record of a verdict, never a queue.
            let live = feedback?.partition(ids, scope: tile.route.feedbackContext).live ?? ids
            CollectionPlayMenuItems(title: tile.title, songIds: live,
                                    idPrefix: "foryou-tile-\(tile.id)",
                                    onStarted: { queue in
                                        feedback?.beginPlayback(scope: tile.route.feedbackContext,
                                                                songIds: queue)
                                    })
            if let collectionId = tile.route.collectionId {
                Divider()
                recsToggleMenuItem(collectionId: collectionId, name: tile.title)
            }
        }
    }

    /// **Turn recommendations off for this collection.** Owner, verbatim: *"support ability to turn
    /// off recommendations for a collection (eg comfort zone, favorite songs, OTG) as an option in
    /// the … menu of the tile."*
    ///
    /// ── ONLY ON COLLECTION TILES, AND THAT IS NOT AN OVERSIGHT ───────────────────────────────
    /// New and In Da Zone are the two PINNED tiles — they are not collections, they have no
    /// `collectionId` to store a flag against, and the owner's examples are all crates. Their
    /// equivalent switches already exist elsewhere (Settings ▸ For You for the cadence, Settings ▸
    /// Recommendations for the engine itself).
    ///
    /// ── IT IS A ONE-WAY DOOR *FROM HERE*, WHICH IS WHY IT ANNOUNCES THE WAY BACK ─────────────
    /// Switching off removes the tile, and this menu with it. Two other surfaces carry the same
    /// switch and both survive that — the collection's OWN ⋯ menu (`PlaylistDetailView` /
    /// `PocketDetailView`, which is also the only reachable one for a collection whose tile is
    /// empty or was never earned), and Settings ▸ For You, which lists every switched-off
    /// collection precisely so none of them can get lost. `recsOffNotice` names both, once, at the
    /// moment the tile disappears.
    @ViewBuilder private func recsToggleMenuItem(collectionId: String, name: String) -> some View {
        CollectionRecsToggle(collectionId: collectionId,
                             idPrefix: "foryou-tile-col-\(collectionId)") {
            recsOffNotice = "PocketDJ won’t suggest songs for “\(name)” any more, and its tile is "
                + "gone from For You.\n\nTurn it back on from that collection’s ⋯ menu, or in "
                + "Settings ▸ For You."
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
            // SAY SO. The New SCREEN already explained this failure and the card did not — same
            // act, same network outcome, one surface silent. Same message, from one constant.
            guard !queue.isEmpty else {
                startError = ReleaseStreaming.emptyExpansionMessage
                return
            }
            sequencer.play(queue, sourceSetlistId: ReleaseStreaming.runTag)
        }
    }

    /// The frozen ids behind a tile — including In Da Zone's, whichever ranker produced them. A
    /// cloud answer is committed to the SAME snapshot, so there is exactly one source of truth
    /// here and the card, its menu and its screen can never disagree.
    private func playableIds(for route: ForYouTileRoute) -> [String] {
        snapshot.songIds(forTileId: route.tileId) ?? []
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
