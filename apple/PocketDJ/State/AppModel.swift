import SwiftUI
import Observation

/// Root app state: loads the catalog (one or more configured sources, merged)
/// and indexes it so views resolve albums/songs instantly. Pure of view concerns.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    var state: LoadState = .idle
    /// Effective catalog = raw index with the user's local edits overlaid.
    var albums: [IndexAlbum] = []
    var songs: [IndexSong] = []
    var songsById: [String: IndexSong] = [:]
    var albumsById: [String: IndexAlbum] = [:]

    /// Pre-built browse rows for each kind, with album name / origin source / top-tier
    /// genre already resolved per item — the exact shape BrowseState used to derive on
    /// EVERY render. Building these ~90k `BrowseItem`s is the bulk of on-device browse
    /// cost, so we do it ONCE here (rebuilt only in `applyEdits`, i.e. on catalog load
    /// or an edit save) instead of re-mapping the whole catalog each body evaluation.
    /// Observed, so a view reading them re-renders when the catalog changes.
    private(set) var albumBrowseItems: [BrowseItem] = []
    private(set) var songBrowseItems: [BrowseItem] = []
    /// Per-item case/diacritic-folded search haystack (title + artist + album/genre), parallel to
    /// `albumBrowseItems` / `songBrowseItems` and built ONCE alongside them. Lets the text-query
    /// filter be a cheap pre-folded `contains` (run OFF the main actor) instead of ~90k × 3
    /// locale-aware `localizedCaseInsensitiveContains` calls per keystroke ON the main actor — the
    /// multi-second search hang the runloop hang reports captured.
    private(set) var albumSearchKeys: [String] = []
    private(set) var songSearchKeys: [String] = []
    /// Artist-grouping browse rows (one per distinct album-artist) + their folded name keys —
    /// the Artists browse kind. Built once in `buildEffective` like the album/song rows.
    private(set) var artistBrowseItems: [BrowseItem] = []
    private(set) var artistSearchKeys: [String] = []
    /// Bumped whenever the effective catalog changes (load / edit). Part of the browse
    /// results cache key, so a stale memo can never survive a catalog change.
    private(set) var catalogRevision = 0

    /// The catalog album for a song id (via the song's `albumId`), when both the song and its
    /// album are indexed. Backs the lock-screen / Control Center Now Playing card's cover art —
    /// nil for a track that isn't in the catalog (e.g. an ad-hoc rip), so the card shows title +
    /// artist only.
    func album(forSongId id: String) -> IndexAlbum? {
        songsById[id]?.albumId.flatMap { albumsById[$0] }
    }

    /// Resolve ordered song ids to universal tracklist CSV rows (title/artist/album/year/genre) —
    /// shared by every CSV export (playlist / pocket / setlist / session). Genre + album name live on
    /// the album; year prefers the song's, falling back to the album's. Ids with no catalog song drop.
    func tracklistCSVRows(forSongIds ids: [String]) -> [TracklistCSV.Row] {
        ids.compactMap { id in
            guard let s = songsById[id] else { return nil }
            let album = s.albumId.flatMap { albumsById[$0] }
            return TracklistCSV.Row(title: s.name, artist: s.artist, album: album?.name ?? "",
                                    year: s.year ?? album?.year, genre: album?.genre ?? "")
        }
    }
    /// Read-only playlists carried in the enabled sources (e.g. Apple Music user
    /// playlists), merged + deduped by id, each tagged with its source's name.
    var indexPlaylists: [SourcePlaylist] = []
    var manifest: Manifest?

    /// Origin source name per album/song id (FIRST-seen wins, same dedup order as
    /// `merge`) — the merged catalog otherwise loses which source each item came
    /// from. Mirrors how `sourcePlaylists` tags playlists by source.
    private(set) var albumSourceById: [String: String] = [:]
    private(set) var songSourceById: [String: String] = [:]
    /// Distinct source names present in the loaded catalog, in first-seen order
    /// (e.g. "My Vinyl", "Apple Music (Local)"). Drives the source filter options.
    private(set) var availableSources: [String] = []

    /// The un-edited catalog (so edit forms can show originals / compute deltas).
    private var rawAlbums: [IndexAlbum] = []
    private var rawSongs: [IndexSong] = []
    var rawAlbumsById: [String: IndexAlbum] = [:]
    var rawSongsById: [String: IndexSong] = [:]

    // Small LRU-ish memo of fully-derived browse results (query→filter→sort), keyed by
    // BrowseState.resultsKey. Lives HERE (long-lived @Observable) — not on BrowseState,
    // which SwiftUI recreates every time the Browser tab is re-entered — so returning to
    // the tab with the same filters/sort is instant instead of re-sorting the catalog.
    // @ObservationIgnored: mutating the cache while READING results inside a view's body
    // must NOT invalidate that view (that would loop). Bounded so it can't grow unbounded
    // as the user tweaks filters; fully cleared whenever the catalog changes.
    @ObservationIgnored private var browseResultsCache: [String: [BrowseItem]] = [:]
    @ObservationIgnored private var browseResultsOrder: [String] = []
    private static let browseResultsCacheCap = 6

    /// Single-flight guard for `loadIfNeeded`. The seed/refresh now suspend (off-main build), so
    /// `state` is no longer claimed synchronously before the first `await` — this flag stops two
    /// concurrent callers (a multi-window RootView `.task` + an App-Intent launch) from both passing
    /// the state check and building the catalog twice / firing duplicate network refreshes.
    @ObservationIgnored private var loadInFlight = false

    /// Optional fixed loader (tests / fixtures). When nil, sources come from `settings`.
    private let loader: CatalogLoading?
    /// Settings drive the live multi-source catalog (set by the app at launch).
    var settings: SettingsStore?
    /// Local metadata edits, overlaid onto the catalog (set by the app at launch).
    var edits: EditsStore?
    /// Provisional Discover adds — merged as a synthetic source until the nightly
    /// indexer lands each track for real (set by the app at launch).
    var discoverAdds: DiscoverAddsStore?
    /// Provisional IMPORTED entries (cross-user playlist/pocket transfers) — merged as
    /// a synthetic source appended LAST, so real sources shadow them by merge order
    /// alone and the entries survive as durable fallbacks (set by the app at launch).
    var importedSongs: ImportedSongsStore?
    /// Supersede hook: (provisional id → indexed id) pairs for the collections remap —
    /// Discover amrec_ supersedes AND imported amrec_ remaps ride the same seam
    /// (set by the app at launch).
    var onDiscoverSupersede: (([(from: String, to: String)]) -> Void)?

    init(loader: CatalogLoading? = nil) {
        if let loader {
            self.loader = loader
        } else if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            self.loader = FixtureCatalog()
        } else {
            self.loader = nil
        }
    }

    var sourceName: String { manifest?.sourceName ?? "Collection" }
    var albumCount: Int { albums.count }
    var songCount: Int { songs.count }

    func loadIfNeeded() async {
        switch state {
        case .loaded, .loading: return
        default: break
        }
        // Single-flight: the build below suspends, so claim the load with a flag (not `state`, which
        // we intentionally leave `.idle` on the seed path to avoid a loading flash). Without this a
        // second concurrent caller would slip past the `state` check during the first's `await`.
        if loadInFlight { return }
        loadInFlight = true
        defer { loadInFlight = false }
        // OFFLINE-FIRST: render the last-good catalog from the on-disk cache — no waiting on the
        // network — fixing the cold/iOS-kill relaunch that showed an empty UI while it re-downloaded
        // a catalog it already had. The decode + merge + edit-overlay + browse-row build all run OFF
        // the main actor (see `seedFromCache` → `buildDerived`), so a large (~90k-row) catalog never
        // blocks the first frame — the visionOS blank-first-window on cold relaunch was this same
        // build blocking the compositor's first frame. Only show `.loading` when nothing is cached.
        if await seedFromCache() {
            // Seed applied ⇒ state is already `.loaded`. Run the conditional network refresh
            // OFF the caller's critical path: a caller that awaits here (e.g. a Siri playback
            // intent on a cold background launch) must not hang on ~30s-per-source network
            // timeouts for a catalog — and burned songs — that are already on disk. Re-entry
            // is safe: the `.loaded` early-return above keeps this to one refresh per load.
            Task { await self.performRefresh(hadData: true) }
            return
        }
        state = .loading
        await performRefresh(hadData: false)
    }

    /// Populate the catalog from each enabled source's CatalogService disk cache, WITHOUT touching
    /// the network. The heavy work — JSON-decoding each cached index and building the merged,
    /// edit-overlaid, indexed catalog + browse rows — runs on a detached task OFF the main actor;
    /// only the final `assign` of the finished value touches `@MainActor` state. Returns whether
    /// anything was seeded. No-op for the fixture/test loader (no per-URL cache) and on a true
    /// first launch (no cache yet).
    @discardableResult
    private func seedFromCache() async -> Bool {
        guard loader == nil else { return false }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        let albumEdits = edits?.doc.albums ?? [:]
        let songEdits = edits?.doc.songs ?? [:]
        let provisional = discoverAdds?.entries ?? []
        let provisionalAlbums = discoverAdds?.albums ?? []
        let importedS = importedSongs?.songs ?? []
        let importedA = importedSongs?.albums ?? []
        let built = await Task.detached(priority: .userInitiated) { () -> (Derived, [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)])? in
            let cached = urls.compactMap { CatalogService.loadCachedIndex(for: $0) }
            guard !cached.isEmpty else { return nil }
            let (indexes, discoverPairs, importedPairs, discoverAlbumPairs) = AppModel.withProvisionalSources(
                discover: provisional, discoverAlbums: provisionalAlbums,
                importedSongs: importedS, importedAlbums: importedA, indexes: cached)
            return (AppModel.buildDerived(indexes: indexes, albumEdits: albumEdits, songEdits: songEdits),
                    discoverPairs, importedPairs, discoverAlbumPairs)
        }.value
        guard let (derived, discoverPairs, importedPairs, discoverAlbumPairs) = built else { return false }
        assign(derived)
        applySupersede(discover: discoverPairs, imported: importedPairs, discoverAlbums: discoverAlbumPairs)
        reconcileEditsAfterBuild(albumEdits: albumEdits, songEdits: songEdits)
        state = .loaded
        return true
    }

    /// Fold the provisional Discover adds in as a synthetic SOURCE — after the supersede
    /// split: an add the indexer has since landed for real is excluded (its remap pair is
    /// returned instead). Pure; runs inside the off-main build. (Thin wrapper kept for
    /// the existing tests; the live pipeline calls `withProvisionalSources`.)
    nonisolated static func withDiscoverAdds(_ provisional: [DiscoverAddsStore.Entry],
                                             indexes: [IndexJSON])
        -> (indexes: [IndexJSON], superseded: [(from: String, to: String)]) {
        let r = withProvisionalSources(discover: provisional, importedSongs: [],
                                       importedAlbums: [], indexes: indexes)
        return (r.indexes, r.discoverSuperseded)
    }

    /// Fold BOTH provisional sources in — Discover adds, then imported entries — each as
    /// a synthetic source appended AFTER every real one (merge is first-wins, so a real
    /// source always shadows a provisional twin without deleting it). Discover entries
    /// whose appleMusicId the indexer has landed are excluded with a remap pair; imported
    /// amrec_ entries likewise (catalog sng_ ids are NEVER remapped — the imported id's
    /// manifest identity is the specific recording that was shared). Pure; off-main.
    nonisolated static func withProvisionalSources(discover: [DiscoverAddsStore.Entry],
                                                   discoverAlbums: [DiscoverAddsStore.AlbumEntry] = [],
                                                   importedSongs: [ImportedSongsStore.SongEntry],
                                                   importedAlbums: [ImportedSongsStore.AlbumEntry],
                                                   indexes: [IndexJSON])
        -> (indexes: [IndexJSON],
            discoverSuperseded: [(from: String, to: String)],
            importedSuperseded: [(from: String, to: String)],
            discoverAlbumSuperseded: [(from: String, to: String)]) {
        guard !discover.isEmpty || !discoverAlbums.isEmpty
                || !importedSongs.isEmpty || !importedAlbums.isEmpty else {
            return (indexes, [], [], [])
        }
        var byAppleMusicId: [String: String] = [:]
        var albumByAppleMusicId: [String: String] = [:]
        for index in indexes {
            for s in index.songs where s.appleMusicId != nil {
                if byAppleMusicId[s.appleMusicId!] == nil { byAppleMusicId[s.appleMusicId!] = s.id }
            }
            for a in index.albums where a.appleMusicId != nil {
                if albumByAppleMusicId[a.appleMusicId!] == nil { albumByAppleMusicId[a.appleMusicId!] = a.id }
            }
        }
        let split = DiscoverAddsStore.split(discover, indexedByAppleMusicId: byAppleMusicId)
        let albumSplit = DiscoverAddsStore.splitAlbums(discoverAlbums, indexedByAppleMusicId: albumByAppleMusicId)
        let importedPairs = ImportedSongsStore.supersedePairs(importedSongs,
                                                              indexedByAppleMusicId: byAppleMusicId)
        let remapped = Set(importedPairs.map(\.from))
        let keptImported = importedSongs.filter { !remapped.contains($0.songId) }
        var all = indexes
        if !split.keep.isEmpty || !albumSplit.keep.isEmpty {
            all.append(DiscoverAddsStore.syntheticIndex(split.keep, albums: albumSplit.keep))
        }
        if !keptImported.isEmpty || !importedAlbums.isEmpty {
            all.append(ImportedSongsStore.syntheticIndex(songs: keptImported, albums: importedAlbums))
        }
        return (all, split.superseded, importedPairs, albumSplit.superseded)
    }

    /// Land the supersedes: prune each provisional store (Discover entries whose indexed
    /// twin owns the id now; imported amrec_ entries that remapped) and remap collection
    /// references through the shared hook. Discover ALBUM supersedes only prune the
    /// provisional album row — collections reference SONG ids, never album ids, so there
    /// is nothing to remap for a superseded album.
    private func applySupersede(discover: [(from: String, to: String)],
                                imported: [(from: String, to: String)] = [],
                                discoverAlbums: [(from: String, to: String)] = []) {
        if !discover.isEmpty { discoverAdds?.remove(ids: discover.map(\.from)) }
        if !imported.isEmpty { importedSongs?.remove(songIds: imported.map(\.from)) }
        if !discoverAlbums.isEmpty { discoverAdds?.remove(albumIds: discoverAlbums.map(\.from)) }
        let all = discover + imported
        guard !all.isEmpty else { return }
        onDiscoverSupersede?(all)
    }

    /// A Discover add landing while the catalog is LIVE: append the provisional row as a
    /// raw song of the synthetic source and rebuild the effective catalog (the edit-save
    /// rebuild path — synchronous, adds are user-initiated and rare).
    func injectDiscoverAdd(_ song: IndexSong) {
        guard rawSongsById[song.id] == nil, songsById[song.id] == nil else { return }
        rawSongs.append(song)
        rawSongsById[song.id] = song
        songSourceById[song.id] = DiscoverAddsStore.sourceName
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// A Discover ALBUM add landing while the catalog is LIVE: append the provisional album
    /// as a raw album of the synthetic source and rebuild (the album twin of
    /// `injectDiscoverAdd`; the per-track songs arrive via `injectDiscoverAdd`).
    func injectDiscoverAlbumAdd(_ album: IndexAlbum) {
        guard rawAlbumsById[album.id] == nil, albumsById[album.id] == nil else { return }
        rawAlbums.append(album)
        rawAlbumsById[album.id] = album
        albumSourceById[album.id] = DiscoverAddsStore.sourceName
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// A Discover ALBUM BATCH landing while the catalog is LIVE: append every provisional
    /// track song AND the album as raw rows of the synthetic source, then ONE effective
    /// rebuild — an album add fans out to N tracks, and the ~90k-row rebuild is the per-batch
    /// cost, never per-track (the album twin of `injectImported`, mirroring its one-rebuild
    /// contract). Known ids are skipped. `album` is nil when only new tracks landed.
    func injectDiscoverAlbumBatch(songs newSongs: [IndexSong], album: IndexAlbum?) {
        var changed = false
        for s in newSongs where rawSongsById[s.id] == nil && songsById[s.id] == nil {
            rawSongs.append(s)
            rawSongsById[s.id] = s
            songSourceById[s.id] = DiscoverAddsStore.sourceName
            changed = true
        }
        if let album, rawAlbumsById[album.id] == nil, albumsById[album.id] == nil {
            rawAlbums.append(album)
            rawAlbumsById[album.id] = album
            albumSourceById[album.id] = DiscoverAddsStore.sourceName
            changed = true
        }
        guard changed else { return }
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// An IMPORT landing while the catalog is LIVE: append every unknown row (songs AND
    /// their albums) as the "Imported" synthetic source, then ONE effective rebuild — a
    /// playlist import can carry hundreds of songs, and the edit-save rebuild is the
    /// per-batch cost, never per-song. Known ids are skipped (a real source or an
    /// earlier import already owns them).
    func injectImported(songs newSongs: [IndexSong], albums newAlbums: [IndexAlbum]) {
        var changed = false
        for s in newSongs where rawSongsById[s.id] == nil && songsById[s.id] == nil {
            rawSongs.append(s)
            rawSongsById[s.id] = s
            songSourceById[s.id] = ImportedSongsStore.sourceName
            changed = true
        }
        for a in newAlbums where rawAlbumsById[a.id] == nil && albumsById[a.id] == nil {
            rawAlbums.append(a)
            rawAlbumsById[a.id] = a
            albumSourceById[a.id] = ImportedSongsStore.sourceName
            changed = true
        }
        guard changed else { return }
        if !availableSources.contains(ImportedSongsStore.sourceName) {
            availableSources.append(ImportedSongsStore.sourceName)
        }
        applyEdits()
    }

    /// If the user saved a metadata edit DURING an off-main catalog build, that build's `derived`
    /// captured a STALE edit snapshot — re-overlay the current edits so a mid-load save isn't visually
    /// clobbered (the edit itself is already persisted in `EditsStore`). Common case: no change → no-op.
    private func reconcileEditsAfterBuild(albumEdits: [String: AlbumEdit], songEdits: [String: SongEdit]) {
        if (edits?.doc.albums ?? [:]) != albumEdits || (edits?.doc.songs ?? [:]) != songEdits {
            applyEdits()
        }
    }

    /// Conditionally refresh from the network. A 304/offline/failed refresh is NON-DESTRUCTIVE:
    /// CatalogService returns each source's disk cache on failure, so a previously-loaded source
    /// is never dropped, and we only surface `.failed` when there was nothing to show.
    private func performRefresh(hadData: Bool) async {
        do {
            let indexes = try await fetchIndexes()
            let albumEdits = edits?.doc.albums ?? [:]
            let songEdits = edits?.doc.songs ?? [:]
            let provisional = discoverAdds?.entries ?? []
            let provisionalAlbums = discoverAdds?.albums ?? []
            let importedS = importedSongs?.songs ?? []
            let importedA = importedSongs?.albums ?? []
            // Merge + edit-overlay + sort + browse-row build for the whole (~90k-row) catalog runs
            // OFF the main actor; only the finished value is assigned back on `@MainActor`.
            let built = await Task.detached(priority: .userInitiated) { () -> (Derived, [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)]) in
                let (all, discoverPairs, importedPairs, discoverAlbumPairs) = AppModel.withProvisionalSources(
                    discover: provisional, discoverAlbums: provisionalAlbums,
                    importedSongs: importedS, importedAlbums: importedA, indexes: indexes)
                return (AppModel.buildDerived(indexes: all, albumEdits: albumEdits, songEdits: songEdits),
                        discoverPairs, importedPairs, discoverAlbumPairs)
            }.value
            assign(built.0)
            applySupersede(discover: built.1, imported: built.2, discoverAlbums: built.3)
            reconcileEditsAfterBuild(albumEdits: albumEdits, songEdits: songEdits)
            state = .loaded
        } catch {
            // Refresh failed (e.g. true first launch + offline). Keep whatever is already on
            // screen; only blank to an error when we have nothing seeded/loaded.
            if !hadData && albums.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    /// The fully-derived catalog produced OFF the main actor by `buildDerived`: the merged raw
    /// index + per-source tags + playlists, plus the effective (edit-overlaid, sorted, indexed)
    /// catalog and its pre-built browse rows + search keys. `assign` hands it to `@MainActor`
    /// state in one cheap, atomic step (never a half-applied catalog).
    struct Derived {
        let manifest: Manifest?
        let indexPlaylists: [SourcePlaylist]
        let albumSourceById: [String: String]
        let songSourceById: [String: String]
        let availableSources: [String]
        let rawAlbums: [IndexAlbum]
        let rawSongs: [IndexSong]
        let rawAlbumsById: [String: IndexAlbum]
        let rawSongsById: [String: IndexSong]
        let effective: Effective
    }

    /// The edit-overlaid, sorted, indexed catalog + its pre-built browse rows and search keys.
    /// Shared by the launch build (`buildDerived`, off-main) and the edit-save rebuild
    /// (`applyEdits`, on-main) so both produce identical effective state.
    struct Effective {
        let albums: [IndexAlbum]
        let songs: [IndexSong]
        let songsById: [String: IndexSong]
        let albumsById: [String: IndexAlbum]
        let albumBrowseItems: [BrowseItem]
        let songBrowseItems: [BrowseItem]
        let albumSearchKeys: [String]
        let songSearchKeys: [String]
        let artistBrowseItems: [BrowseItem]
        let artistSearchKeys: [String]
    }

    /// Merge source indexes → tag by source → overlay edits → sort → index → build browse rows.
    /// Pure + `nonisolated` so the whole heavy pipeline runs on a background executor; the
    /// `@MainActor` model only assigns the result (see `assign`).
    nonisolated static func buildDerived(indexes: [IndexJSON],
                                         albumEdits: [String: AlbumEdit],
                                         songEdits: [String: SongEdit]) -> Derived {
        let index = merge(indexes)
        let sources = sourceTags(indexes)
        let rawAlbums = index.albums
        let rawSongs = index.songs
        let effective = buildEffective(rawAlbums: rawAlbums, rawSongs: rawSongs,
                                       albumSourceById: sources.albums, songSourceById: sources.songs,
                                       albumEdits: albumEdits, songEdits: songEdits)
        return Derived(
            manifest: index.manifest,
            indexPlaylists: sourcePlaylists(indexes),
            albumSourceById: sources.albums,
            songSourceById: sources.songs,
            availableSources: sources.names,
            rawAlbums: rawAlbums,
            rawSongs: rawSongs,
            rawAlbumsById: Dictionary(rawAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            rawSongsById: Dictionary(rawSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            effective: effective)
    }

    /// Overlay edits onto the raw catalog, sort albums, index by id, and pre-build the browse rows
    /// + per-item search keys. Pure + `nonisolated` (the album sort over ~90k rows uses
    /// `localizedCaseInsensitiveCompare`, which was a main-actor cost — moved off it here).
    nonisolated static func buildEffective(rawAlbums: [IndexAlbum], rawSongs: [IndexSong],
                                           albumSourceById: [String: String],
                                           songSourceById: [String: String],
                                           albumEdits: [String: AlbumEdit],
                                           songEdits: [String: SongEdit]) -> Effective {
        let albums = rawAlbums.map { $0.applying(albumEdits[$0.id]) }.sorted {
            let a = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return a == .orderedSame
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : a == .orderedAscending
        }
        let songs = rawSongs.map { $0.applying(songEdits[$0.id]) }
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumsById = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let albumItems = albums.map { BrowseItem.album($0, source: albumSourceById[$0.id]) }
        let albumKeys = albums.map { searchKey($0.name, $0.artist, $0.genre ?? "") }
        let songItems = songs.map { song -> BrowseItem in
            let album = song.albumId.flatMap { albumsById[$0] }
            return .song(song, albumName: album?.name ?? "",
                         source: songSourceById[song.id],
                         genre: Genre.category(album?.genre))
        }
        let songKeys = songs.map { song -> String in
            let albumName = song.albumId.flatMap { albumsById[$0]?.name } ?? ""
            return searchKey(song.name, song.artist, albumName)
        }
        // Artist groupings (the Artists browse kind): one row per distinct album-artist, in the
        // catalog's existing artist/name order. `albums` is already sorted by artist then name, so a
        // single pass groups consecutive same-artist albums (dictionary-free, order-preserving).
        var artistItems: [BrowseItem] = []
        var artistKeys: [String] = []
        var i = 0
        while i < albums.count {
            let artist = albums[i].artist
            var j = i, songCount = 0
            // Group case-INSENSITIVELY to match the case-insensitive sort above — otherwise a
            // merged catalog whose sources disagree on casing ("OutKast" vs "Outkast") would sort
            // the albums adjacent but split them into multiple artist rows (with a duplicate
            // `artist:<name>` id). The FIRST album's casing becomes the row's display name.
            while j < albums.count, albums[j].artist.localizedCaseInsensitiveCompare(artist) == .orderedSame {
                songCount += albums[j].trackList.count
                j += 1
            }
            artistItems.append(.artist(name: artist, albumCount: j - i, songCount: songCount,
                                       artworkAlbumId: albums[i].id))
            artistKeys.append(searchKey(artist))
            i = j
        }
        return Effective(albums: albums, songs: songs, songsById: songsById, albumsById: albumsById,
                         albumBrowseItems: albumItems, songBrowseItems: songItems,
                         albumSearchKeys: albumKeys, songSearchKeys: songKeys,
                         artistBrowseItems: artistItems, artistSearchKeys: artistKeys)
    }

    /// One case- AND diacritic-insensitive haystack from an item's searchable fields, matched with a
    /// plain `contains` against a same-folded query. `folding(…, locale: nil)` is DETERMINISTIC across
    /// locales (unlike the old `localizedCaseInsensitiveContains`, which also missed "İ" U+0130 whose
    /// `lowercased()` gains a combining dot) and ~an order of magnitude cheaper than per-field
    /// locale-aware search; diacritic-insensitivity ("café" ≈ "cafe") is a win for accented artist/
    /// album names. The `\n` separators keep a match within one field — a query never spans two joined
    /// values, mirroring the old per-field OR.
    nonisolated static func searchKey(_ fields: String...) -> String {
        fields.joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Fired after every full catalog assign (cache seed + network refresh) — the one
    /// choke point where a fresh `indexPlaylists` goes live. Wired at app init to the
    /// collections' converted-pocket source sync (gated there by the Settings toggle).
    var onCatalogAssigned: (() -> Void)?

    /// Assign a fully-derived catalog to `@MainActor` state in one atomic step.
    private func assign(_ d: Derived) {
        manifest = d.manifest
        indexPlaylists = d.indexPlaylists
        albumSourceById = d.albumSourceById
        songSourceById = d.songSourceById
        availableSources = d.availableSources
        rawAlbums = d.rawAlbums
        rawSongs = d.rawSongs
        rawAlbumsById = d.rawAlbumsById
        rawSongsById = d.rawSongsById
        assign(effective: d.effective)
        onCatalogAssigned?()
    }

    /// Assign the effective (edit-overlaid) catalog + browse rows, bump the revision, and clear the
    /// results memo. Shared by the launch assign and the on-main `applyEdits` rebuild.
    private func assign(effective e: Effective) {
        albums = e.albums
        songs = e.songs
        songsById = e.songsById
        albumsById = e.albumsById
        albumBrowseItems = e.albumBrowseItems
        songBrowseItems = e.songBrowseItems
        albumSearchKeys = e.albumSearchKeys
        songSearchKeys = e.songSearchKeys
        artistBrowseItems = e.artistBrowseItems
        artistSearchKeys = e.artistSearchKeys
        catalogRevision &+= 1
        browseResultsCache.removeAll(keepingCapacity: true)
        browseResultsOrder.removeAll(keepingCapacity: true)
    }

    /// Rebuild the effective catalog by overlaying local edits onto the raw index. Called after an
    /// edit is saved (the launch path builds this OFF the main actor via `buildDerived`). Edit saves
    /// are user-initiated and infrequent, so this stays synchronous.
    func applyEdits() {
        assign(effective: Self.buildEffective(
            rawAlbums: rawAlbums, rawSongs: rawSongs,
            albumSourceById: albumSourceById, songSourceById: songSourceById,
            albumEdits: edits?.doc.albums ?? [:], songEdits: edits?.doc.songs ?? [:]))
    }

    /// The pre-built, unfiltered browse rows for a kind (album name / source / genre
    /// already resolved). O(1) — the array is built once in `buildEffective`.
    func browseItems(_ kind: ItemKind) -> [BrowseItem] {
        switch kind {
        case .album:  return albumBrowseItems
        case .song:   return songBrowseItems
        case .artist: return artistBrowseItems
        }
    }

    /// The pre-built folded search keys parallel to `browseItems(kind)` (same order/count).
    func searchKeys(_ kind: ItemKind) -> [String] {
        switch kind {
        case .album:  return albumSearchKeys
        case .song:   return songSearchKeys
        case .artist: return artistSearchKeys
        }
    }

    /// Return the memoized browse results for `key`, computing + caching on a miss. The
    /// caller (BrowseState) owns the derivation; this only decides whether to reuse it.
    func cachedBrowseResults(_ key: String, compute: () -> [BrowseItem]) -> [BrowseItem] {
        if let hit = browseResultsCache[key] { return hit }
        let value = compute()
        storeBrowseResults(key, value)
        return value
    }

    /// Memo peek (no compute) — the OFF-main browse pipeline computes on a detached task, then
    /// stores the finished set here (see `BrowseState.refreshResults`).
    func peekBrowseResults(_ key: String) -> [BrowseItem]? { browseResultsCache[key] }

    /// Store a browse result set into the bounded LRU memo (idempotent — a concurrent refresh that
    /// already filled this key wins; recompute of the same key is deterministic anyway).
    func storeBrowseResults(_ key: String, _ value: [BrowseItem]) {
        if browseResultsCache[key] != nil { return }
        browseResultsCache[key] = value
        browseResultsOrder.append(key)
        if browseResultsOrder.count > Self.browseResultsCacheCap {
            let evict = browseResultsOrder.removeFirst()
            browseResultsCache.removeValue(forKey: evict)
        }
    }

    func rawAlbum(_ id: String) -> IndexAlbum? { rawAlbumsById[id] }
    func rawSong(_ id: String) -> IndexSong? { rawSongsById[id] }

    /// Manual refresh (Settings "Reload catalog" / Browse "Retry"). Keeps the current catalog on
    /// screen and refreshes in place — never resets to `.idle`/`.loading`, so it can't blank the
    /// catalog. On a cold model with nothing loaded yet it seeds from cache first.
    func reload() async {
        // Share loadIfNeeded's single-flight gate: reload also awaits an off-main build, so a manual
        // reload racing the launch load (or another reload) would otherwise double-build the catalog.
        if loadInFlight { return }
        loadInFlight = true
        defer { loadInFlight = false }
        let hadData = !albums.isEmpty
        if !hadData { _ = await seedFromCache() }
        await performRefresh(hadData: hadData || !albums.isEmpty)
    }

    /// Per-source tagging derived alongside the merge: id→source maps + the
    /// distinct source names (first-seen order).
    typealias SourceTags = (albums: [String: String], songs: [String: String], names: [String])

    private func fetchIndexes() async throws -> [IndexJSON] {
        if let loader { return [try await loader.loadIndex()] }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        var indexes: [IndexJSON] = []
        var firstError: Error?
        for url in urls {
            do {
                // CatalogService does a CONDITIONAL GET and falls back to ITS OWN per-URL disk
                // cache when offline/unchanged — so a previously-loaded source never throws here.
                indexes.append(try await CatalogService(url: url).loadIndex())
            } catch {
                // OFFLINE GRACEFUL DEGRADATION: a source with no cache (never loaded online) +
                // no network is SKIPPED so the OTHER sources' cached catalogs still open. We
                // fail the whole load only when EVERY source failed (indexes empty) — one
                // un-cached source must not hide an already-cached one.
                firstError = firstError ?? error
            }
        }
        guard !indexes.isEmpty else { throw firstError ?? URLError(.cannotLoadFromNetwork) }
        return indexes
    }

    /// Tag each album/song id with the name of the FIRST source that carries it —
    /// same dedup order as `merge` — so the merged catalog keeps its provenance.
    /// Pure + nonisolated so it's unit-testable without the network.
    nonisolated static func sourceTags(_ indexes: [IndexJSON]) -> SourceTags {
        var albums: [String: String] = [:]
        var songs: [String: String] = [:]
        var names: [String] = []
        var seenNames = Set<String>()
        for index in indexes {
            let name = index.manifest.sourceName ?? "Collection"
            if seenNames.insert(name).inserted { names.append(name) }
            for a in index.albums where albums[a.id] == nil { albums[a.id] = name }
            for s in index.songs where songs[s.id] == nil { songs[s.id] = name }
        }
        return (albums, songs, names)
    }

    /// Merge multiple source indexes into one (first occurrence of each id wins).
    /// Pure + synchronous (nonisolated) so it's unit-testable without the network.
    nonisolated static func merge(_ indexes: [IndexJSON]) -> IndexJSON {
        var albums: [IndexAlbum] = []
        var songs: [IndexSong] = []
        var playlists: [IndexPlaylist] = []
        var seenAlbums = Set<String>(), seenSongs = Set<String>(), seenPlaylists = Set<String>()
        for index in indexes {
            for a in index.albums where seenAlbums.insert(a.id).inserted { albums.append(a) }
            for s in index.songs where seenSongs.insert(s.id).inserted { songs.append(s) }
            for p in index.playlists ?? [] where seenPlaylists.insert(p.id).inserted { playlists.append(p) }
        }
        let manifest = indexes.first?.manifest
            ?? Manifest(source: nil, generatedAt: nil, sourceName: "Collection", counts: nil)
        return IndexJSON(manifest: manifest, albums: albums, songs: songs,
                         playlists: playlists.isEmpty ? nil : playlists)
    }

    /// Flatten each source's playlists into source-tagged rows (for the badge),
    /// deduped by playlist id across sources (first occurrence wins).
    nonisolated static func sourcePlaylists(_ indexes: [IndexJSON]) -> [SourcePlaylist] {
        var out: [SourcePlaylist] = []
        var seen = Set<String>()
        for index in indexes {
            let name = index.manifest.sourceName ?? "Collection"
            for p in index.playlists ?? [] where seen.insert(p.id).inserted {
                out.append(SourcePlaylist(playlist: p, sourceName: name))
            }
        }
        return out
    }

    /// Resolve an album's ordered tracklist to song records.
    func tracks(for album: IndexAlbum) -> [IndexSong] {
        album.trackList.compactMap { songsById[$0] }
    }

    func albumName(forSong song: IndexSong) -> String {
        song.albumId.flatMap { albumsById[$0]?.name } ?? ""
    }

    /// Origin source name for an album/song id (nil if untagged/unknown).
    func source(ofAlbum id: String) -> String? { albumSourceById[id] }
    func source(ofSong id: String) -> String? { songSourceById[id] }

    // MARK: - Apple Music identity (favorites two-way sync)

    /// Reverse index (Apple Music catalog id → song id), built lazily on first ask and
    /// invalidated by `catalogRevision`. @ObservationIgnored because filling it is a pure
    /// cache fill — observing it would invalidate whatever asked, for no state change.
    @ObservationIgnored private var appleMusicIdIndex: [String: String] = [:]
    @ObservationIgnored private var appleMusicIdIndexRevision = -1

    /// Every catalog song that HAS an Apple Music identity, as (songId, appleMusicId).
    /// This is the id space `FavoritesSyncService`'s inbound pull asks Apple Music about —
    /// vinyl / My Digital / Studio songs carry no catalog id and are excluded by
    /// construction, so they can never be dragged into an Apple Music round-trip.
    func appleMusicCatalogPairs() -> [(songId: String, appleMusicId: String)] {
        songs.compactMap { s in s.appleMusicId.map { (songId: s.id, appleMusicId: $0) } }
    }

    /// Resolve an Apple Music catalog id back to this catalog's song id (the inbound
    /// direction — Apple Music speaks catalog ids, the app speaks PocketDJ song ids).
    /// FIRST-seen wins, matching `merge`'s dedup order, so a song present in two sources
    /// resolves to the same id the rest of the app uses.
    func songId(forAppleMusicId appleMusicId: String) -> String? {
        if appleMusicIdIndexRevision != catalogRevision {
            appleMusicIdIndex = Dictionary(songs.compactMap { s in s.appleMusicId.map { ($0, s.id) } },
                                           uniquingKeysWith: { first, _ in first })
            appleMusicIdIndexRevision = catalogRevision
        }
        return appleMusicIdIndex[appleMusicId]
    }
}
