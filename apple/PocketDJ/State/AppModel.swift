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
        state = .loading
        do {
            let (index, sourcePlaylists, sources) = try await fetchIndex()
            manifest = index.manifest
            indexPlaylists = sourcePlaylists
            albumSourceById = sources.albums
            songSourceById = sources.songs
            availableSources = sources.names
            rawAlbums = index.albums
            rawSongs = index.songs
            rawAlbumsById = Dictionary(rawAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rawSongsById = Dictionary(rawSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            applyEdits()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
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

    func reload() async {
        state = .idle
        await loadIfNeeded()
    }

    /// Per-source tagging derived alongside the merge: id→source maps + the
    /// distinct source names (first-seen order).
    typealias SourceTags = (albums: [String: String], songs: [String: String], names: [String])

    private func fetchIndex() async throws -> (IndexJSON, [SourcePlaylist], SourceTags) {
        if let loader {
            let index = try await loader.loadIndex()
            return (index, AppModel.sourcePlaylists([index]), AppModel.sourceTags([index]))
        }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        var indexes: [IndexJSON] = []
        for url in urls {
            indexes.append(try await CatalogService(url: url).loadIndex())
        }
        return (AppModel.merge(indexes), AppModel.sourcePlaylists(indexes), AppModel.sourceTags(indexes))
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
