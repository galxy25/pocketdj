import Foundation

/// The template-agnostic heart of the CarPlay app: it turns the shared stores into the row lists
/// CarPlay browses (Playlists / Pockets / Albums / Artists → songs) and routes
/// the two write actions — play a collection/song, add a song to a pocket/playlist.
///
/// Deliberately free of any `CarPlay` import, so it unit-tests on the plain test host and compiles
/// on every platform; the CarPlay scene (iOS-only) is a THIN adapter that maps these `Row`s to
/// CPListTemplate / CPListItem and fetches thumbnails. All playback routes through the SAME unified
/// sequencer the rest of the app uses (via `IntentServices`), so CarPlay shares one Now-Playing.
@MainActor
final class CarPlayModel {

    /// One browsable/actionable row. `id` is a collection id, album id, or (for song rows) a song
    /// id; add-to target rows encode the kind as a `pkt:`/`pls:` prefix.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        /// Album id to resolve a thumbnail from (nil → generic icon).
        let artworkAlbumId: String?
        /// True for a playable SONG row (vs. a collection/album drill-in row).
        let isSong: Bool
    }

    let services: IntentServices
    private var app: AppModel { services.app }
    private var collections: CollectionsStore { services.collections }

    init(services: IntentServices) { self.services = services }

    /// Make the catalog usable before building lists (the scene can connect before it's warm).
    ///
    /// Restores the durable session FIRST, and deliberately before the catalog await: the restore
    /// is self-contained (title/artist ride the snapshot) so it does not need a warm catalog, and
    /// doing it first means the root template is built with the resumable set already known — no
    /// second template pass, no O(catalog) rebuild on the main actor.
    func ensureReady() async {
        services.restorePlaybackSessionIfIdle()
        await services.ensureReady()
    }

    /// A restored-but-not-yet-playing set the driver can resume, or nil. Drives the one-shot
    /// "Continue" row at the top of the CarPlay root — the affordance that makes the restore
    /// reachable without the phone.
    func resumableSession() -> Row? {
        let p = services.setlistPlayer
        guard p.isRunning, p.isHeldForResume, p.queue.indices.contains(p.index) else { return nil }
        let item = p.queue[p.index]
        let artist = item.artist.trimmingCharacters(in: .whitespaces)
        return Row(id: "resume:\(item.uid)", title: item.title,
                   subtitle: artist.isEmpty ? "Continue" : "\(artist) · Continue",
                   artworkAlbumId: firstAlbumId([item.id]), isSong: true)
    }

    /// Resume the held set (the "Continue" row's action). No-op when nothing is held.
    func resumeHeldSession() {
        let p = services.setlistPlayer
        guard p.isRunning, p.isHeldForResume else { return }
        p.resumeFromHold()
    }

    // MARK: - Browse lists

    /// All browsable playlists: the user's PocketDJ playlists AND the catalog's source playlists
    /// (Apple Music / iTunes mirrors, from `app.indexPlaylists`) — source rows are id-prefixed
    /// "src:" and carry a source badge in the subtitle.
    func playlists() -> [Row] {
        let mine = collections.playlists.map { pl -> Row in
            let ids = collections.playableIds(forPlaylist: pl.id)
            return Row(id: pl.id, title: pl.name, subtitle: songsSubtitle(resolvedCount(ids)),
                       artworkAlbumId: firstAlbumId(ids), isSong: false)
        }
        let source = app.indexPlaylists.map { sp -> Row in
            Row(id: "src:\(sp.id)", title: sp.name,
                subtitle: "\(songsSubtitle(resolvedCount(sp.songIds))) · \(sp.sourceName)",
                artworkAlbumId: firstAlbumId(sp.songIds), isSong: false)
        }
        return mine + source
    }

    private func sourcePlaylist(_ rowId: String) -> SourcePlaylist? {
        guard rowId.hasPrefix("src:") else { return nil }
        let realId = String(rowId.dropFirst(4))
        return app.indexPlaylists.first { $0.id == realId }
    }

    func pockets() -> [Row] {
        collections.pockets.map { pk in
            let ids = collections.playableIds(forPocket: pk.id)
            return Row(id: pk.id, title: pk.name, subtitle: songsSubtitle(resolvedCount(ids)),
                       artworkAlbumId: firstAlbumId(ids), isSong: false)
        }
    }

    func albums() -> [Row] {
        app.albums.map { Row(id: $0.id, title: $0.name, subtitle: $0.artist, artworkAlbumId: $0.id, isSong: false) }
    }

    /// Distinct artists (from the prebuilt artist groupings), for the CarPlay Artists tab.
    func artists() -> [Row] {
        app.artistBrowseItems.compactMap { item in
            guard case .artist(let name, let albumCount, let songCount, let albumId) = item else { return nil }
            return Row(id: "artist:\(name)", title: name,
                       subtitle: "\(albumCount) album\(albumCount == 1 ? "" : "s") · \(songCount) songs",
                       artworkAlbumId: albumId, isSong: false)
        }
    }

    /// One artist's albums (drill-in from the Artists tab). Case-insensitive (see AppModel grouping).
    func albums(byArtist name: String) -> [Row] {
        albumsByArtist(name).map {
            Row(id: $0.id, title: $0.name, subtitle: "\($0.trackList.count) tracks",
                artworkAlbumId: $0.id, isSong: false)
        }
    }

    /// One artist's whole discography as a FLAT list of song rows (their albums' track lists,
    /// concatenated in album order). CarPlay audio apps cap the template stack at depth 2 (root +
    /// one push) on iOS ≤ 26.3, so the Artists tab pushes this flat list directly instead of
    /// artist → albums → songs (which would be depth 3 and throws at runtime). Case-insensitive.
    func songs(byArtist name: String) -> [Row] {
        songRows(albumsByArtist(name).flatMap(\.trackList))
    }

    /// ▶/🔀 an artist's whole discography.
    func playArtist(name: String, shuffle: Bool = false) async {
        let ids = albumsByArtist(name).flatMap(\.trackList)
        try? await services.playSongIds(ids, name: name, shuffle: shuffle, source: .artist)
    }

    private func albumsByArtist(_ name: String) -> [IndexAlbum] {
        app.albums.filter { $0.artist.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func songs(inPlaylist id: String) -> [Row] {
        if let sp = sourcePlaylist(id) { return songRows(sp.songIds) }
        return songRows(collections.playableIds(forPlaylist: id))
    }
    func songs(inPocket id: String) -> [Row] { songRows(collections.playableIds(forPocket: id)) }
    func songs(inAlbum id: String) -> [Row] {
        guard let album = app.albumsById[id] else { return [] }
        return songRows(album.trackList)
    }

    // MARK: - Play (all through the one unified sequencer)

    func playPlaylist(id: String, shuffle: Bool = false) async {
        if let sp = sourcePlaylist(id) {
            try? await services.playSongIds(sp.songIds, name: sp.name, shuffle: shuffle, source: .playlist)
        } else {
            try? await services.playPlaylist(id: id, shuffle: shuffle)
        }
    }
    func playPocket(id: String, shuffle: Bool = false) async { try? await services.playPocket(id: id, shuffle: shuffle) }
    func playAlbum(id: String, shuffle: Bool = false) async { try? await services.playAlbum(id: id, shuffle: shuffle) }
    func playSong(id: String) async { try? await services.playSong(id: id) }

    // MARK: - Add-to (pocket / playlist)

    /// Add-to destinations: pockets then playlists, each with a kind-prefixed target id.
    func addTargets() -> [Row] {
        collections.pockets.map { Row(id: "pkt:\($0.id)", title: $0.name, subtitle: "Pocket", artworkAlbumId: nil, isSong: false) }
        + collections.playlists.map { Row(id: "pls:\($0.id)", title: $0.name, subtitle: "Playlist", artworkAlbumId: nil, isSong: false) }
    }

    /// Add `songId` to the target encoded by `addTargets` (a `pkt:`/`pls:`-prefixed id). Playlists
    /// append to the default chapter. Returns the target's display name (for a confirmation), or
    /// nil for an unknown/deleted target.
    @discardableResult
    func addSong(_ songId: String, toTargetId targetRowId: String) -> String? {
        if let id = strip(targetRowId, "pkt:"), let p = collections.pocket(id) {
            collections.addSong(songId, to: AddTarget(kind: .pocket, id: id))
            return p.name
        }
        if let id = strip(targetRowId, "pls:"), let pl = collections.playlist(id) {
            collections.addSong(songId, to: AddTarget(kind: .playlist, id: id))
            return pl.name
        }
        return nil
    }

    // MARK: - Up Next (the running sequencer's upcoming queue)

    /// One upcoming row. Identified by `uid` (a song can repeat in the queue), matching how
    /// SetlistPlayer's live-queue edits key rows.
    struct UpNextItem: Identifiable, Equatable {
        let uid: UUID
        let title: String
        let artist: String
        let albumId: String?
        var id: UUID { uid }
    }

    /// The tracks after the current one in the running set (empty when nothing/queue-less is playing).
    func upNext() -> [UpNextItem] {
        services.setlistPlayer.upcoming.map {
            UpNextItem(uid: $0.uid, title: $0.title, artist: $0.artist, albumId: app.songsById[$0.id]?.albumId)
        }
    }

    /// The track the sequencer is currently ON (nil when idle). CarPlay's SYSTEM Now Playing
    /// card is fed by whichever engine owns the audio (MusicKit for Apple Music, `PlayerEngine`
    /// for rips/burns) — but PocketDJ's OWN CarPlay UI otherwise has no "now playing" cue: the
    /// Up Next list starts at the NEXT track. So a set started from the phone (e.g. shuffling an
    /// Apple Music playlist) shows a correct upcoming queue with no in-app marker of what's
    /// playing right now. This pins that current track above the queue. Read straight off
    /// `queue[index]` (not `rips.nowPlaying`, which the Apple Music path never sets).
    func nowPlaying() -> UpNextItem? {
        let p = services.setlistPlayer
        guard p.isRunning, p.index < p.queue.count else { return nil }
        let it = p.queue[p.index]
        return UpNextItem(uid: it.uid, title: it.title, artist: it.artist, albumId: app.songsById[it.id]?.albumId)
    }

    /// The current track's song id (nil when idle) — the identity every favorite op keys on.
    /// Read straight off `queue[index]` like `nowPlaying()`, so it's correct for an Apple Music
    /// set too (which never sets `rips.nowPlaying`).
    private func currentSongId() -> String? {
        let p = services.setlistPlayer
        guard p.isRunning, p.index < p.queue.count else { return nil }
        return p.queue[p.index].id
    }

    // MARK: - Favorite (the ♥ on the CarPlay Now Playing template)

    /// Is the currently-playing track favorited? Drives the heart button's filled/outline glyph.
    /// False when nothing is playing.
    func isCurrentFavorite() -> Bool {
        guard let id = currentSongId() else { return false }
        return services.favorites.isFavorite(id)
    }

    /// Flip the current track's favorite — resolves its Apple Music catalog id (nil for vinyl /
    /// My Digital / Studio, still favorited local-only) and calls `FavoritesStore.toggle`, whose
    /// `onChanged` reaches Apple Music only for an owner install carrying a catalog id. A no-op
    /// when nothing is playing.
    func toggleCurrentFavorite() {
        guard let id = currentSongId() else { return }
        services.favorites.toggle(id, appleMusicId: app.songsById[id]?.appleMusicId)
    }

    // MARK: - CarPlay repeat / shuffle (mirror the Now Playing deck + widget)

    /// Whether a set is running — CarPlay shows the repeat + shuffle buttons only then (they're
    /// meaningless for a single-track play, matching the in-app deck + widget gating).
    func isSetRunning() -> Bool { services.setlistPlayer.isRunning }
    /// Live shuffle of the running queue's upcoming tail.
    func isShuffleOn() -> Bool { services.setlistPlayer.shuffleEnabled }
    func toggleShuffle() { services.setlistPlayer.toggleShuffle() }
    /// Whole-session repeat mode (off / all / one).
    func repeatMode() -> RepeatMode { services.setlistPlayer.repeatMode }
    func cycleRepeat() { services.setlistPlayer.cycleRepeatMode() }

    func removeFromQueue(uid: UUID) { services.setlistPlayer.removeUpcoming(uids: [uid]) }
    func playNext(uid: UUID) { services.setlistPlayer.moveUpcomingNext(uid: uid) }
    func moveToEnd(uid: UUID) { services.setlistPlayer.moveUpcomingToEnd(uid: uid) }
    /// "Play now" on an Up Next row — shift playback to exactly that queue row.
    func jump(uid: UUID) { services.setlistPlayer.jumpToUpcoming(uid: uid) }

    // MARK: - Artwork (URLs; the CarPlay adapter fetches → UIImage)

    func artCandidates(albumId: String?) -> [URL] {
        guard let albumId, let album = app.albumsById[albumId] else { return [] }
        return album.artCandidates
    }

    // MARK: - Helpers

    private func strip(_ s: String, _ prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
    private func songRows(_ ids: [String]) -> [Row] { ids.compactMap { app.songsById[$0] }.map { songRow($0) } }
    /// Count of ids that resolve to a CATALOG song — i.e. the rows the drill-in list actually
    /// renders. (playableIds also keeps STUDIO ids, which have no IndexSong and are dropped from
    /// the list, so counting playableIds directly would overstate the row count.)
    private func resolvedCount(_ ids: [String]) -> Int { ids.reduce(0) { app.songsById[$1] != nil ? $0 + 1 : $0 } }
    private func songRow(_ s: IndexSong) -> Row {
        Row(id: s.id, title: s.name, subtitle: s.artist, artworkAlbumId: s.albumId, isSong: true)
    }
    private func firstAlbumId(_ songIds: [String]) -> String? {
        for id in songIds { if let a = app.songsById[id]?.albumId { return a } }
        return nil
    }
    private func songsSubtitle(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
}
