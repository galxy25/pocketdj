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

    /// Optional fixed loader (tests / fixtures). When nil, sources come from `settings`.
    private let loader: CatalogLoading?
    /// Settings drive the live multi-source catalog (set by the app at launch).
    var settings: SettingsStore?
    /// Local metadata edits, overlaid onto the catalog (set by the app at launch).
    var edits: EditsStore?

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
        // OFFLINE-FIRST: render the last-good catalog from the on-disk cache SYNCHRONOUSLY (no
        // `.loading` blank, no waiting on the network) — fixes the cold/iOS-kill relaunch showing
        // an empty UI while it re-downloads a catalog it already had. Only show `.loading` when
        // there is genuinely nothing cached (true first launch).
        let seeded = seedFromCache()
        if !seeded { state = .loading }
        await performRefresh(hadData: seeded)
    }

    /// Populate the catalog from each enabled source's CatalogService disk cache, WITHOUT touching
    /// the network. Returns whether anything was seeded. No-op for the fixture/test loader (no
    /// per-URL cache) and on a true first launch (no cache yet).
    @discardableResult
    private func seedFromCache() -> Bool {
        guard loader == nil else { return false }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        let cached = urls.compactMap { CatalogService.loadCachedIndex(for: $0) }
        guard !cached.isEmpty else { return false }
        apply(cached)
        return true
    }

    /// Conditionally refresh from the network. A 304/offline/failed refresh is NON-DESTRUCTIVE:
    /// CatalogService returns each source's disk cache on failure, so a previously-loaded source
    /// is never dropped, and we only surface `.failed` when there was nothing to show.
    private func performRefresh(hadData: Bool) async {
        do {
            apply(try await fetchIndexes())
        } catch {
            // Refresh failed (e.g. true first launch + offline). Keep whatever is already on
            // screen; only blank to an error when we have nothing seeded/loaded.
            if !hadData && albums.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    /// Assign the merged catalog + per-source tags + index playlists from a set of source indexes,
    /// overlay edits, and mark `.loaded`. Shared by the instant cache seed and the network refresh
    /// so both paths populate state identically (and atomically — never a half-applied catalog).
    private func apply(_ indexes: [IndexJSON]) {
        let index = AppModel.merge(indexes)
        let sources = AppModel.sourceTags(indexes)
        manifest = index.manifest
        indexPlaylists = AppModel.sourcePlaylists(indexes)
        albumSourceById = sources.albums
        songSourceById = sources.songs
        availableSources = sources.names
        rawAlbums = index.albums
        rawSongs = index.songs
        rawAlbumsById = Dictionary(rawAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rawSongsById = Dictionary(rawSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        applyEdits()
        state = .loaded
    }

    /// Rebuild the effective catalog by overlaying local edits onto the raw index.
    /// Call after the catalog loads or whenever an edit is saved.
    func applyEdits() {
        let albumEdits = edits?.doc.albums ?? [:]
        let songEdits = edits?.doc.songs ?? [:]
        albums = rawAlbums.map { $0.applying(albumEdits[$0.id]) }.sorted {
            let a = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return a == .orderedSame
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : a == .orderedAscending
        }
        songs = rawSongs.map { $0.applying(songEdits[$0.id]) }
        songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsById = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func rawAlbum(_ id: String) -> IndexAlbum? { rawAlbumsById[id] }
    func rawSong(_ id: String) -> IndexSong? { rawSongsById[id] }

    /// Manual refresh (Settings "Reload catalog" / Browse "Retry"). Keeps the current catalog on
    /// screen and refreshes in place — never resets to `.idle`/`.loading`, so it can't blank the
    /// catalog. On a cold model with nothing loaded yet it seeds from cache first.
    func reload() async {
        let hadData = !albums.isEmpty
        if !hadData { _ = seedFromCache() }
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
}
