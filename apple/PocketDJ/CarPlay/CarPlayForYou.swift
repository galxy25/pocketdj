import Foundation

/// **For You, in the car.** Owner, verbatim: *"in CarPlay replace artists & albums (if both exist,
/// otherwise replace what does so we only have Playlists, Pockets & For You) with For You (new and
/// recommended pinned up top) view."*
///
/// ── WHY THIS IS A MODEL EXTENSION AND NOT SCENE CODE ─────────────────────────────────────────
/// The CarPlay SURFACE cannot be tested headlessly in this repo — there is no simulated head unit,
/// and `CPListTemplate` renders nothing an XCUITest can see. So everything that can be a decision
/// is a decision made HERE, in a file with no `CarPlay` import, and `CarPlayScene` is left with
/// nothing but "make a `CPListItem` out of this row". What the unit suite verifies is therefore
/// nearly all of the feature; what stays unverified is the template plumbing.
///
/// ── THE ORDER IS NOT RE-DERIVED HERE, AND THAT IS THE POINT ──────────────────────────────────
/// "New and recommended pinned up top … matching the phone" is not implemented in this file. It is
/// implemented in `ForYouGrid.tiles` / `ForYouTiles.build`, which the phone grid also calls, so the
/// car cannot drift from the phone by construction rather than by vigilance.
///
/// ── READ-ONLY. THE CAR NEVER REFRESHES ───────────────────────────────────────────────────────
/// A For You refresh is two catalog sweeps (~96k rows for the zone, another per collection) plus,
/// optionally, a network call. Starting that because a car connected would be a hang at exactly the
/// wrong moment, and the feed is deliberately frozen anyway (owner: *"cache the last result and only
/// refresh when you hit a refresh button"*). The car renders the cached snapshot verbatim; the phone
/// owns the refresh, and a never-refreshed cache says so rather than showing a blank list.
extension CarPlayModel {

    /// The two things this tab reads that nothing else in `CarPlayModel` needs.
    private var feedSnapshot: ForYouFeedSnapshot { services.forYouFeed?.snapshot ?? ForYouFeedSnapshot() }
    private var feedback: RecFeedbackStore? { services.recFeedback }

    /// Row-id prefix for a RELEASE (the New tile's rows). Namespaced so a release can never be
    /// mistaken for a catalog song id — the two are routed to completely different players.
    static let releaseRowPrefix = "rel:"

    /// The message a cold For You cache shows instead of an empty list. A car is the worst possible
    /// place to be handed a blank screen with no explanation, and this state is legitimately
    /// reachable: a fresh install that has never opened History has no ranking yet, and the car must
    /// not be the thing that computes one.
    static let coldFeedNote = "Open For You on your phone to build your recommendations"

    // ========================================================================
    // MARK: - The tab's top level: the tiles
    // ========================================================================

    /// The For You tiles as CarPlay rows, in the phone's order — New, In Da Zone, then one row per
    /// collection with something worth adding.
    ///
    /// `id` is the TILE id (`"new"` / `"zone"` / `"col-<id>"`), which is what every function below
    /// takes; the scene never has to parse it.
    func forYouTiles(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [Row] {
        let tiles = forYouTileModels(nowMs: nowMs)
        let releaseCount = newReleaseItems(nowMs: nowMs).count
        return tiles.map { tile in
            // NEW COUNTS RELEASES, AND THE CAR COUNTS THE ONES IT CAN ACTUALLY PLAY. The phone's
            // badge is out-now PLUS pre-orders, because tapping a pre-order there opens a page worth
            // opening. There is no page in a car — every row must be playable — so the drill-in
            // lists out-now only, and the count above it has to be that same number or the row is
            // lying about what is behind it.
            let n = tile.route.kind == .new ? releaseCount : tile.count
            return Row(id: tile.id, title: tile.title,
                       subtitle: tileDetail(count: n, kind: tile.route.kind, note: tile.subtitle),
                       artworkAlbumId: forYouArtworkAlbumId(tile: tile, nowMs: nowMs),
                       isSong: false)
        }
    }

    /// `"12 songs · Top picks from your recent activity"`. At zero the SUBTITLE wins and the count
    /// is dropped: the tile's own wording already explains an empty New ("Apple Music isn't
    /// connected", "Checking for new releases…") or an empty zone ("Play a few songs to build your
    /// zone"), and "0 songs · " in front of it is noise on a screen glanced at from a moving car.
    private func tileDetail(count: Int, kind: ForYouTileRoute.Kind, note: String) -> String {
        guard count > 0 else { return note }
        let unit = kind == .new ? (count == 1 ? "release" : "releases")
                                : (count == 1 ? "song" : "songs")
        return "\(count) \(unit) · \(note)"
    }

    /// Cover art for a tile: the first resolvable album behind its rows. New has none — its rows are
    /// records not in the catalog, so there is no `albumsById` entry to resolve, and the generic
    /// icon is the honest answer rather than borrowing an unrelated cover.
    private func forYouArtworkAlbumId(tile: ForYouTile, nowMs: Double) -> String? {
        guard tile.route.kind != .new else { return nil }
        return firstAlbumIdForForYou(forYouSongIds(tile: tile, nowMs: nowMs))
    }

    /// The tile cards, from the ONE shared derivation the phone grid uses.
    private func forYouTileModels(nowMs: Double) -> [ForYouTile] {
        ForYouGrid.tiles(snapshot: feedSnapshot, collections: services.collections,
                         feedback: feedback, releaseFeed: services.releaseFeed, nowMs: nowMs)
    }

    private func forYouTile(_ tileId: String, nowMs: Double) -> ForYouTile? {
        forYouTileModels(nowMs: nowMs).first { $0.id == tileId }
    }

    // ========================================================================
    // MARK: - One tile's rows
    // ========================================================================

    /// The playable rows behind a tile. Catalog songs for In Da Zone and the collection tiles;
    /// RELEASES (`isSong == false`, id `rel:<storeId>`) for New.
    ///
    /// Every row here can be played from the car — that is the requirement, and it is why New lists
    /// only what is out now. Nothing unplayable is offered.
    func forYouRows(tileId: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [Row] {
        guard let tile = forYouTile(tileId, nowMs: nowMs) else { return [] }
        if tile.route.kind == .new {
            return newReleaseItems(nowMs: nowMs).compactMap { item in
                guard let releaseId = item.entry.releaseId else { return nil }
                return Row(id: Self.releaseRowPrefix + releaseId,
                           title: item.entry.releaseName ?? item.entry.artistName,
                           subtitle: item.entry.artistName,
                           artworkAlbumId: nil, isSong: false)
            }
        }
        return forYouSongIds(tile: tile, nowMs: nowMs).compactMap { id in
            services.app.songsById[id].map {
                Row(id: $0.id, title: $0.name, subtitle: $0.artist,
                    artworkAlbumId: $0.albumId, isSong: true)
            }
        }
    }

    /// Is this tile's drill-in a list of RELEASES rather than catalog songs? True only for New.
    /// The scene asks so it can label the section and its empty line honestly, rather than
    /// inferring it from whatever the first row happens to be (which answers wrongly when there
    /// are no rows at all — precisely the case the label has to explain).
    func isReleaseTile(_ tileId: String) -> Bool { tileId == ForYouTileRoute.Kind.new.rawValue }

    /// Exactly the ids the tile's badge counted — see `ForYouGrid.songIds(forTile:)`. Empty for New.
    private func forYouSongIds(tile: ForYouTile, nowMs: Double) -> [String] {
        ForYouGrid.songIds(forTile: tile, snapshot: feedSnapshot,
                           collections: services.collections, feedback: feedback, nowMs: nowMs)
    }

    /// The New tile's rows: out now, still being offered (the thumbed-down tail removed), newest
    /// first. A pre-order is deliberately absent — there is no audio behind it, and a row that
    /// cannot play has no business on a car screen.
    private func newReleaseItems(nowMs: Double) -> [ReleaseFeedItem] {
        let items = services.releaseFeed?.outNow(nowMs: nowMs) ?? []
        guard let feedback else { return items }
        let sunk = feedback.activeTombstones(scope: ForYouTileRoute.Kind.new.rawValue, nowMs: nowMs)
        guard !sunk.isEmpty else { return items }
        return items.filter { sunk[$0.feedbackId] == nil }
    }

    // ========================================================================
    // MARK: - Play
    // ========================================================================

    /// ▶ / 🔀 a whole tile. `false` ⇒ nothing playable came of it (an empty tile, a New expansion
    /// that came back with no tracks, onboarding not finished) — the scene says so rather than
    /// leaving a tap that silently did nothing.
    @discardableResult
    func playForYouTile(_ tileId: String, shuffle: Bool = false,
                        nowMs: Double = Date().timeIntervalSince1970 * 1000) async -> Bool {
        guard let tile = forYouTile(tileId, nowMs: nowMs) else { return false }
        if tile.route.kind == .new {
            return await playReleases(newReleaseItems(nowMs: nowMs).compactMap(\.entry.releaseId),
                                      shuffle: shuffle)
        }
        return await playSuggestions(forYouSongIds(tile: tile, nowMs: nowMs), tile: tile,
                                     shuffle: shuffle)
    }

    /// ▶ one row — **and everything after it**, the "play from here" any music list does. A
    /// one-track queue would end and leave the car silent, which is not what tapping a row in a list
    /// of twenty means.
    ///
    /// A `rel:` row is a release: it expands and streams on its own (New has no running order to
    /// continue into — each record is its own thing).
    @discardableResult
    func playForYouRow(_ rowId: String, inTile tileId: String,
                       nowMs: Double = Date().timeIntervalSince1970 * 1000) async -> Bool {
        if let releaseId = strippedReleaseId(rowId) {
            return await playReleases([releaseId], shuffle: false)
        }
        guard let tile = forYouTile(tileId, nowMs: nowMs) else { return false }
        let ids = forYouSongIds(tile: tile, nowMs: nowMs)
        guard let i = ids.firstIndex(of: rowId) else { return false }
        return await playSuggestions(Array(ids[i...]), tile: tile, shuffle: false)
    }

    /// Start a suggestion queue **and stamp the recommendation scope**.
    ///
    /// The stamp is the whole reason the 👍/👎 pair on the CarPlay Now Playing card has ever had
    /// anything to act on. `IntentServices.currentRecTarget` returns nil unless the running queue
    /// was begun as a recommendation, and until this feature the car had no way to begin one — the
    /// buttons could only appear for a set started on the phone. Now the driver can start a tile
    /// from the car and judge it from the car, which is the loop the controls were built for.
    ///
    /// ORDER IS LOAD-BEARING: `playSongIds` → `CollectionsStore.playNow` → `onPlaybackReplaced` →
    /// `endPlaybackScope`. Stamping first would have the new scope wiped by the very play that
    /// created it. (Same ordering `CollectionPlayback.start`'s `onStarted` relies on.)
    private func playSuggestions(_ ids: [String], tile: ForYouTile, shuffle: Bool) async -> Bool {
        guard !ids.isEmpty else { return false }
        guard (try? await services.playSongIds(ids, name: tile.title, shuffle: shuffle,
                                               source: .browser)) != nil else { return false }
        feedback?.beginPlayback(scope: tile.route.feedbackContext, songIds: ids)
        return true
    }

    /// Expand releases into tracks and hand them to the sequencer — the SAME door the phone's New
    /// tile uses (`ReleaseStreaming`), not `playSongIds`.
    ///
    /// It cannot be `playSongIds`: that runs through `CollectionsStore.playNow`, which drops every
    /// id the local catalog cannot resolve — i.e. every track of a record he does not own, i.e. all
    /// of them. `ReleaseStreaming.items` queues namespaced `am:<storeID>` ids that
    /// `PlaybackCoordinator` routes to MusicKit.
    ///
    /// NO FEEDBACK SCOPE IS STAMPED, deliberately, exactly as on the phone: a verdict on the New
    /// tile is filed against a RELEASE (`rel:<albumId>`) and what plays here is TRACKS, so a
    /// now-playing 👍 would have no honest release to attribute itself to. The thumbs stay hidden
    /// for a New queue rather than filing against the wrong thing.
    ///
    /// Vetoed during onboarding by hand — this is the one playback path that does not inherit
    /// `playSongIds`' guard, and CarPlay can cold-launch a device that has never finished setup.
    private func playReleases(_ releaseIds: [String], shuffle: Bool) async -> Bool {
        guard !releaseIds.isEmpty, !services.isOnboardingIncomplete else { return false }
        let library = services.streaming?.providers.libraryContributors.first
        let rows = await ReleaseStreaming.tracks(forReleaseIds: releaseIds, rips: services.rips,
                                                 library: library)
        let catalog = services.app
        var queue = ReleaseStreaming.items(rows, catalogSongId: { catalog.songId(forAppleMusicId: $0) })
        guard !queue.isEmpty else { return false }
        if shuffle { queue.shuffle() }
        services.setlistPlayer.play(queue, sourceSetlistId: ReleaseStreaming.runTag)
        return true
    }

    /// `rel:<storeId>` → `<storeId>`, or nil for a catalog song row.
    private func strippedReleaseId(_ rowId: String) -> String? {
        guard rowId.hasPrefix(Self.releaseRowPrefix) else { return nil }
        let id = String(rowId.dropFirst(Self.releaseRowPrefix.count))
        return id.isEmpty ? nil : id
    }

    private func firstAlbumIdForForYou(_ songIds: [String]) -> String? {
        for id in songIds { if let a = services.app.songsById[id]?.albumId { return a } }
        return nil
    }
}
