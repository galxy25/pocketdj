import Foundation
import Observation

/// PROVISIONAL catalog entries for IMPORTED collections — the cross-USER half of the
/// eventual-consistency doctrine (DiscoverAddsStore is the cross-DEVICE half): when a
/// playlist/pocket zip from another profile references songs outside this device's
/// enabled sources, the import materializes them as first-class catalog citizens
/// IMMEDIATELY (browsable, addable, playable/burnable/stemmable — the global rips
/// manifest + stems + analysis artifacts key on the song id, which travels verbatim).
///
/// SUPERSEDE DOCTRINE (R10 — deliberately different from DiscoverAddsStore):
///   • Exact-id: when the user later enables the source that carries an imported id,
///     `AppModel.merge` (first-wins, provisional sources appended LAST) shadows the
///     provisional entry for free — the entry is KEPT, not pruned, so un-ticking that
///     source later restores the durable fallback instead of orphaning the playlist.
///   • appleMusicId remap: ONLY for `amrec_`-shaped ids (Discover ad-hoc captures,
///     whose ids are per-device); a catalog `sng_` id keeps its exact identity — the
///     imported id's manifest entry is the specific recording user A shared (rip +
///     stems + beat grid), and remapping onto a local un-ripped twin would silently
///     swap the audio (the tight-matching doctrine).
///
/// Persists to Application Support `pocketdj-imported-songs.json` (the PlayStatsStore
/// durable-JSON pattern) and syncs through CloudSyncService under its OWN doc key
/// ("imported-songs" — never a schema change to the discover-adds doc: an older app
/// version failing to decode a widened doc would LWW-push an empty one).
@MainActor
@Observable
final class ImportedSongsStore {

    /// The synthetic source's name (song source tags + the Browse source filter).
    nonisolated static let sourceName = "Imported"

    struct SongEntry: Codable, Equatable, Identifiable {
        var songId: String
        var title: String
        var artist: String
        var albumId: String?
        var album: String?
        var artworkUrl: String?
        var durationMs: Int?
        var bpm: Double?
        var key: String?
        var camelot: String?
        var year: Int?
        var appleMusicId: String?
        var addedAtMs: Double
        var id: String { songId }
    }

    struct AlbumEntry: Codable, Equatable, Identifiable {
        var albumId: String
        var name: String
        var artist: String
        var trackIds: [String]
        var artworkUrl: String?
        var genre: String?
        var year: Int?
        var addedAtMs: Double
        var id: String { albumId }
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var songs: [SongEntry] = []
        var albums: [AlbumEntry] = []
    }

    private(set) var songs: [SongEntry] = []
    private(set) var albums: [AlbumEntry] = []
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }
    /// Fired with each batch of NEW entries (local import or cloud pull) — the app wires
    /// this to `AppModel.injectImported` so the live catalog updates without a reload.
    @ObservationIgnored var onAdded: ((_ songs: [IndexSong], _ albums: [IndexAlbum]) -> Void)?

    init(fileURL: URL = ImportedSongsStore.defaultURL()) {
        self.fileURL = fileURL
        let doc = Self.decode(fileURL)
        songs = doc.songs
        albums = doc.albums
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-imported-songs.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ProfileStore.launchURL idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-imported-songs.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decode(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }

    /// Record an import batch (idempotent per id) and hand the NEW rows to the live
    /// catalog in one shot (a playlist import may carry hundreds — one rebuild, not N).
    func add(songs newSongs: [SongEntry], albums newAlbums: [AlbumEntry] = []) {
        let songIds = Set(songs.map(\.songId))
        let albumIds = Set(albums.map(\.albumId))
        let freshSongs = newSongs.filter { !songIds.contains($0.songId) }
        let freshAlbums = newAlbums.filter { !albumIds.contains($0.albumId) }
        guard !freshSongs.isEmpty || !freshAlbums.isEmpty else { return }
        songs.append(contentsOf: freshSongs)
        albums.append(contentsOf: freshAlbums)
        save()
        onAdded?(freshSongs.map(Self.indexSong), freshAlbums.map(Self.indexAlbum))
    }

    /// Drop remapped entries (amrec_ supersede only — see the header doctrine).
    func remove(songIds ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        songs.removeAll { gone.contains($0.songId) }
        save()
    }

    /// Re-decode after CloudSyncService pulled a newer copy, surfacing NEW entries
    /// through `onAdded` so the live catalog follows the pull.
    func reloadFromDisk() {
        let beforeSongs = Set(songs.map(\.songId))
        let beforeAlbums = Set(albums.map(\.albumId))
        let doc = Self.decode(fileURL)
        songs = doc.songs
        albums = doc.albums
        let freshSongs = songs.filter { !beforeSongs.contains($0.songId) }
        let freshAlbums = albums.filter { !beforeAlbums.contains($0.albumId) }
        if !freshSongs.isEmpty || !freshAlbums.isEmpty {
            onAdded?(freshSongs.map(Self.indexSong), freshAlbums.map(Self.indexAlbum))
        }
    }

    // MARK: - Catalog synthesis (pure)

    /// Entry → catalog row (`IndexSong` is Decodable-only — the `IndexSong.minimal` idiom).
    nonisolated static func indexSong(_ e: SongEntry) -> IndexSong {
        var obj: [String: Any] = ["id": e.songId, "name": e.title, "artist": e.artist]
        if let v = e.albumId { obj["albumId"] = v }
        if let v = e.durationMs { obj["length"] = v }
        if let v = e.bpm { obj["bpm"] = v }
        if let v = e.key { obj["key"] = v }
        if let v = e.camelot { obj["camelot"] = v }
        if let v = e.year { obj["year"] = v }
        if let v = e.appleMusicId { obj["appleMusicId"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    /// Album entry → catalog album (same decode idiom; `coverArt` takes the absolute
    /// artwork URL — `IndexAlbum.artCandidates` handles absolute URLs).
    nonisolated static func indexAlbum(_ e: AlbumEntry) -> IndexAlbum {
        var obj: [String: Any] = ["id": e.albumId, "name": e.name, "artist": e.artist,
                                  "trackList": e.trackIds]
        if let v = e.artworkUrl { obj["coverArt"] = v }
        if let v = e.genre { obj["genre"] = v }
        if let v = e.year { obj["year"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }

    /// The synthetic SOURCE the multi-source catalog merge consumes — appended AFTER
    /// every real source (and after Discover), so real entries shadow provisionals by
    /// merge order alone (the exact-id supersede that never deletes).
    nonisolated static func syntheticIndex(songs: [SongEntry], albums: [AlbumEntry]) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: "imported-songs", generatedAt: nil,
                                     sourceName: sourceName, counts: nil),
                  albums: albums.map(indexAlbum), songs: songs.map(indexSong), playlists: nil)
    }

    /// The amrec_-ONLY remap split (pure): an imported ad-hoc capture whose Apple Music
    /// id is claimed by an INDEXED song yields to it (per-device amrec_ ids have no
    /// durable manifest identity worth preserving); everything else keeps its exact id.
    /// Returns the (provisional → indexed) pairs for the collections remap.
    nonisolated static func supersedePairs(_ entries: [SongEntry],
                                           indexedByAppleMusicId: [String: String]) -> [(from: String, to: String)] {
        entries.compactMap { e in
            guard e.songId.hasPrefix("amrec_"),
                  let am = e.appleMusicId,
                  let indexedId = indexedByAppleMusicId[am],
                  indexedId != e.songId else { return nil }
            return (from: e.songId, to: indexedId)
        }
    }

    private func save() {
        let doc = Document(songs: songs, albums: albums)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
