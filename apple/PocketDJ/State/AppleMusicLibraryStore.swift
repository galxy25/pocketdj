import Foundation
import Observation

/// The user's OWN Apple Music library as a first-class catalog source — the PUBLIC-mode twin of
/// the private catalog's "Apple Music (Local)" source (Levi 2026-07-29: "if you have enabled
/// Apple Music and logged in then we should build and sync with your iCloud profile an index for
/// that source"). Rows are built ON DEVICE by `AppleMusicLibraryIndexer` (MusicKit library reads —
/// no server), persisted here, folded into the catalog as a synthetic source (the
/// DiscoverAddsStore pattern), and synced across the user's devices through CloudSyncService.
///
/// PARITY NOTES:
/// • Every song carries `appleMusicId` (the catalog store id) so streaming/playback works exactly
///   like an indexed song, and `dateAdded` (MusicKit `libraryAddedDate`) so "Recently added" works.
/// • `syntheticIndex` is the FIRST injection source to emit `playlists` — the user's own library
///   playlists appear in `app.indexPlaylists` with this source's badge, so converted-pocket
///   follows + write-back behave exactly as they do for the private catalog's playlist mirrors.
/// • SUPERSEDE: if a real indexed source (the private "Apple Music (Local)" catalog) claims the
///   same `appleMusicId`, the on-device row yields to it with a remap pair — flipping Private
///   syncing on never duplicates the library, it just re-homes it.
@MainActor
@Observable
final class AppleMusicLibraryStore {

    /// The synthetic source's name (song source tags + the Browse source filter). Distinct from
    /// the private catalog's "Apple Music (Local)" on purpose — they can coexist mid-supersede.
    nonisolated static let sourceName = "Apple Music"
    nonisolated static let songIdPrefix = "amlib_"

    struct SongEntry: Codable, Equatable, Identifiable {
        /// `amlib_<libraryId>` — namespaced so it can never collide with catalog `sng_` ids.
        var songId: String
        /// MusicKit library id (`i.…`) — the incremental-index join key on THIS device.
        var libraryId: String
        /// Apple Music catalog store id (from playParameters) — streaming + the supersede key.
        /// nil for library-only items Apple can't match to the catalog (they stay browsable).
        var appleMusicId: String?
        var title: String
        var artist: String
        var album: String?
        var albumId: String?
        var artworkUrl: String?
        var durationMs: Int?
        var trackNumber: Int?
        var year: Int?
        var genre: String?
        /// MusicKit `libraryAddedDate` (epoch ms) — powers "Recently added" parity.
        var addedAtMs: Double
        var id: String { songId }
    }

    struct AlbumEntry: Codable, Equatable, Identifiable {
        var albumId: String
        var title: String
        var artist: String
        var artworkUrl: String?
        var year: Int?
        var genre: String?
        var trackIds: [String]
        var id: String { albumId }
    }

    struct PlaylistEntry: Codable, Equatable, Identifiable {
        /// `amlibpl_<libraryPlaylistId>` — the library playlist, mirrored.
        var id: String
        var name: String
        var songIds: [String]
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var songs: [SongEntry] = []
        /// Optional by design (the DiscoverAddsStore decode lesson): a missing key must never
        /// wipe the document on decode.
        var albums: [AlbumEntry]? = nil
        var playlists: [PlaylistEntry]? = nil
        /// High-water mark: the max `addedAtMs` the indexer has seen — the next incremental run
        /// only walks songs added after this.
        var lastAddedMs: Double? = nil
    }

    private(set) var songs: [SongEntry] = []
    private(set) var albums: [AlbumEntry] = []
    private(set) var playlists: [PlaylistEntry] = []
    private(set) var lastAddedMs: Double?
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }
    /// Fired whenever the source's CONTENT changed shape (an index run replaced/extended it, or
    /// a cloud pull landed a peer device's copy) — wired to a full `AppModel.reload()`: unlike
    /// the add-stores, playlists and albums here can change wholesale, so a rebuild is the only
    /// correct refresh.
    @ObservationIgnored var onChanged: (() -> Void)?

    init(fileURL: URL = AppleMusicLibraryStore.defaultURL()) {
        self.fileURL = fileURL
        let doc = Self.decodeDoc(fileURL)
        songs = doc.songs
        albums = doc.albums ?? []
        playlists = doc.playlists ?? []
        lastAddedMs = doc.lastAddedMs
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-apple-music-library.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ProfileStore.launchURL idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-am-library.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decodeDoc(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }

    var isEmpty: Bool { songs.isEmpty && playlists.isEmpty }

    /// A FULL index run's result replaces the source wholesale (the library is the truth).
    func replaceAll(songs newSongs: [SongEntry], albums newAlbums: [AlbumEntry],
                    playlists newPlaylists: [PlaylistEntry], lastAddedMs mark: Double?) {
        songs = newSongs
        albums = newAlbums
        playlists = newPlaylists
        lastAddedMs = mark
        save()
        onChanged?()
    }

    /// An INCREMENTAL run's result: append new songs (idempotent by songId), merge albums by id
    /// (union their track lists), replace playlists wholesale (they're cheap and can reorder),
    /// and advance the high-water mark.
    func applyIncremental(songs newSongs: [SongEntry], albums newAlbums: [AlbumEntry],
                          playlists newPlaylists: [PlaylistEntry], lastAddedMs mark: Double?) {
        let existing = Set(songs.map(\.songId))
        let fresh = newSongs.filter { !existing.contains($0.songId) }
        var changed = !fresh.isEmpty
        songs.append(contentsOf: fresh)
        var albumsById = Dictionary(uniqueKeysWithValues: albums.map { ($0.albumId, $0) })
        for a in newAlbums {
            if var current = albumsById[a.albumId] {
                let seen = Set(current.trackIds)
                let extra = a.trackIds.filter { !seen.contains($0) }
                if !extra.isEmpty { current.trackIds.append(contentsOf: extra); albumsById[a.albumId] = current; changed = true }
            } else {
                albumsById[a.albumId] = a
                changed = true
            }
        }
        albums = albums.compactMap { albumsById[$0.albumId] } + newAlbums.filter { a in !albums.contains(where: { $0.albumId == a.albumId }) }
        if playlists != newPlaylists { playlists = newPlaylists; changed = true }
        if let mark, mark != lastAddedMs { lastAddedMs = mark }
        save()
        if changed { onChanged?() }
    }

    /// Drop superseded entries (their indexed replacements own the ids now — the private
    /// catalog landed the same `appleMusicId`).
    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        songs.removeAll { gone.contains($0.songId) }
        for i in albums.indices { albums[i].trackIds.removeAll { gone.contains($0) } }
        albums.removeAll { $0.trackIds.isEmpty }
        save()
    }

    /// Empty the source: reset in-memory state and remove the persisted file.
    func clear() {
        songs = []
        albums = []
        playlists = []
        lastAddedMs = nil
        try? FileManager.default.removeItem(at: fileURL)
        onChanged?()
    }

    /// Re-decode after CloudSyncService pulled a newer copy. Whole-document LWW — the peer's
    /// index replaces ours; one rebuild follows.
    func reloadFromDisk() {
        let before = (songs, albums, playlists)
        let doc = Self.decodeDoc(fileURL)
        songs = doc.songs
        albums = doc.albums ?? []
        playlists = doc.playlists ?? []
        lastAddedMs = doc.lastAddedMs
        if before != (songs, albums, playlists) { onChanged?() }
    }

    // MARK: - Catalog synthesis (pure)

    /// Entry → catalog row (the Decodable-only JSON idiom). Carries `appleMusicId` (streaming),
    /// `dateAdded` (Recently-added), and the album/track fields the Browser sorts on.
    nonisolated static func indexSong(_ e: SongEntry) -> IndexSong {
        var obj: [String: Any] = ["id": e.songId, "name": e.title, "artist": e.artist,
                                  "dateAdded": e.addedAtMs]
        if let v = e.appleMusicId { obj["appleMusicId"] = v }
        if let v = e.albumId { obj["albumId"] = v }
        if let v = e.durationMs { obj["length"] = v }
        if let v = e.trackNumber { obj["trackNumber"] = v }
        if let v = e.year { obj["year"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    nonisolated static func indexAlbum(_ e: AlbumEntry) -> IndexAlbum {
        var obj: [String: Any] = ["id": e.albumId, "name": e.title, "artist": e.artist,
                                  "trackList": e.trackIds]
        if let v = e.artworkUrl { obj["coverArt"] = v }
        if let v = e.year { obj["year"] = v }
        if let v = e.genre { obj["genre"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }

    /// The synthetic SOURCE the multi-source merge consumes — the FIRST injection source to emit
    /// `playlists`, so the user's library playlists land in `app.indexPlaylists` automatically.
    nonisolated static func syntheticIndex(songs: [SongEntry], albums: [AlbumEntry],
                                           playlists: [PlaylistEntry]) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: "apple-music-library", generatedAt: nil,
                                     sourceName: sourceName, counts: nil),
                  albums: albums.map(indexAlbum),
                  songs: songs.map(indexSong),
                  playlists: playlists.map { IndexPlaylist(id: $0.id, name: $0.name, songIds: $0.songIds) })
    }

    /// The SUPERSEDE split (pure — the DiscoverAddsStore doctrine): entries whose catalog id is
    /// claimed by an INDEXED song yield to it, returning the (on-device → indexed) remap pairs.
    nonisolated static func split(_ entries: [SongEntry], indexedByAppleMusicId: [String: String])
        -> (keep: [SongEntry], superseded: [(from: String, to: String)]) {
        var keep: [SongEntry] = []
        var superseded: [(from: String, to: String)] = []
        for e in entries {
            if let am = e.appleMusicId, let indexedId = indexedByAppleMusicId[am], indexedId != e.songId {
                superseded.append((from: e.songId, to: indexedId))
            } else {
                keep.append(e)
            }
        }
        return (keep, superseded)
    }

    private func save() {
        let doc = Document(songs: songs,
                           albums: albums.isEmpty ? nil : albums,
                           playlists: playlists.isEmpty ? nil : playlists,
                           lastAddedMs: lastAddedMs)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
