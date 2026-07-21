import Foundation
import Observation

/// PROVISIONAL catalog entries for Discover adds — the EVENTUAL-CONSISTENCY half of
/// "＋ Add" (Levi 2026-07-18): the tap must make the song a first-class catalog citizen
/// IMMEDIATELY (browsable, addable to collections, playable/burnable/stemmable off the
/// server's queued `amrec_` capture), while the nightly Apple Music indexer stays the
/// source of truth — once it lands the track as a real library entry, the INDEXED
/// version supersedes the provisional one and collection references are remapped onto
/// it (`AppModel.applySupersede` → `CollectionsStore.remapSongIds`).
///
/// Persists to Application Support `pocketdj-discover-adds.json` (the PlayStatsStore
/// durable-JSON pattern: atomic save, decode-on-init, PDJ_USE_FIXTURE seam) and syncs
/// across the user's devices through CloudSyncService — an add on the iPhone shows up
/// in the iPad's catalog on its next launch pull.
@MainActor
@Observable
final class DiscoverAddsStore {

    /// The synthetic source's name (song source tags + the Browse source filter).
    nonisolated static let sourceName = "Discover"

    struct Entry: Codable, Equatable, Identifiable {
        /// The ad-hoc rip id (`amrec_<storeId>`) — already the id the rips manifest,
        /// stream path, and burn/stem flows key on.
        var songId: String
        /// Apple Music store id — the SUPERSEDE join key against indexed songs.
        var appleMusicId: String
        var title: String
        var artist: String
        var album: String?
        var artworkUrl: String?
        var durationMs: Int?
        var addedAtMs: Double
        var id: String { songId }
    }

    /// A provisional ALBUM add — the album twin of `Entry`. Browsable/collectable NOW
    /// (its per-track `amrec_` rips land as `Entry` songs); superseded by the real
    /// indexed album via `appleMusicId` once the nightly indexer lands it.
    struct AlbumEntry: Codable, Equatable, Identifiable {
        /// Provisional album id (`amrec_album_<collectionId>`).
        var albumId: String
        /// Apple Music album store id (iTunes collectionId) — the SUPERSEDE join key.
        var appleMusicId: String
        var title: String
        var artist: String
        /// The per-track provisional song ids this album expanded into (`amrec_<trackId>`).
        var trackIds: [String]?
        var artworkUrl: String?
        var year: Int?
        var addedAtMs: Double
        var id: String { albumId }
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var entries: [Entry] = []
        /// OPTIONAL by design — Swift's synthesized Decodable ignores default values and
        /// throws on a MISSING non-optional key, which would silently wipe every existing
        /// Discover add saved by an app version that predates album support. An old document
        /// with no `albums` key decodes with `albums == nil` (the session-wipe lesson).
        var albums: [AlbumEntry]? = nil
    }

    private(set) var entries: [Entry] = []
    private(set) var albums: [AlbumEntry] = []
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }
    /// Fired for each NEW entry (local add or cloud pull) — the app wires this to
    /// `AppModel.injectDiscoverAdd` so the live catalog updates without a full reload.
    @ObservationIgnored var onAdded: ((IndexSong) -> Void)?
    /// Fired for each NEW album (local add or cloud pull) — wired to
    /// `AppModel.injectDiscoverAlbumAdd`. Kept a SEPARATE arm from `onAdded` so the
    /// existing song path is untouched (back-compat).
    @ObservationIgnored var onAlbumAdded: ((IndexAlbum) -> Void)?
    /// Fired ONCE for a batched ALBUM add — every provisional track song PLUS the album,
    /// in a single call — so the app does ONE catalog rebuild instead of one per track
    /// (`AppModel.injectDiscoverAlbumBatch`; the album twin of `ImportedSongsStore.onAdded`).
    /// The per-row `onAdded`/`onAlbumAdded` arms are deliberately NOT fired on this path.
    /// `album` is nil when the album already existed but new tracks landed (idempotent).
    @ObservationIgnored var onAlbumBatchAdded: ((_ songs: [IndexSong], _ album: IndexAlbum?) -> Void)?

    init(fileURL: URL = DiscoverAddsStore.defaultURL()) {
        self.fileURL = fileURL
        let doc = Self.decodeDoc(fileURL)
        entries = doc.entries
        albums = doc.albums ?? []
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-discover-adds.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ProfileStore.launchURL idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-discover-adds.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decode(_ url: URL) -> [Entry] { decodeDoc(url).entries }

    private nonisolated static func decodeDoc(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }

    /// Record an add (idempotent per songId) and hand the injected catalog row to the app.
    func add(songId: String, appleMusicId: String, title: String, artist: String,
             album: String? = nil, artworkUrl: String? = nil, durationMs: Int? = nil) {
        guard !entries.contains(where: { $0.songId == songId }) else { return }
        let entry = Entry(songId: songId, appleMusicId: appleMusicId, title: title, artist: artist,
                          album: album, artworkUrl: artworkUrl, durationMs: durationMs,
                          addedAtMs: Date().timeIntervalSince1970 * 1000)
        entries.append(entry)
        save()
        onAdded?(Self.indexSong(entry))
    }

    /// Record an album add (idempotent per albumId) and hand the injected catalog album to
    /// the app. The per-track songs are recorded separately via `add(songId:…)` so they are
    /// individually browsable/rippable; this row is what makes the ALBUM itself a citizen.
    func addAlbum(albumId: String, appleMusicId: String, title: String, artist: String,
                  trackIds: [String]? = nil, artworkUrl: String? = nil, year: Int? = nil) {
        guard !albums.contains(where: { $0.albumId == albumId }) else { return }
        let entry = AlbumEntry(albumId: albumId, appleMusicId: appleMusicId, title: title,
                               artist: artist, trackIds: trackIds, artworkUrl: artworkUrl,
                               year: year, addedAtMs: Date().timeIntervalSince1970 * 1000)
        albums.append(entry)
        save()
        onAlbumAdded?(Self.indexAlbum(entry))
    }

    /// Batched ALBUM add (the perf path for a fan-out album — mirrors `ImportedSongsStore.add`):
    /// record every provisional track song (idempotent per songId) PLUS the album (idempotent
    /// per albumId), persist ONCE, and fire a SINGLE `onAlbumBatchAdded` carrying the whole set.
    /// The per-row `onAdded`/`onAlbumAdded` arms are NOT fired, so the app rebuilds the effective
    /// catalog exactly once for the album, never once per track. `songs` are gated by the caller
    /// (only tracks whose rip was accepted arrive here — no dead rows).
    func addAlbumBatch(albumId: String, appleMusicId: String, title: String, artist: String,
                       trackIds: [String]? = nil, artworkUrl: String? = nil, year: Int? = nil,
                       songs newSongs: [Entry]) {
        let existing = Set(entries.map(\.songId))
        let freshSongs = newSongs.filter { !existing.contains($0.songId) }
        let albumIsNew = !albums.contains(where: { $0.albumId == albumId })
        guard !freshSongs.isEmpty || albumIsNew else { return }
        entries.append(contentsOf: freshSongs)
        var albumEntry: AlbumEntry?
        if albumIsNew {
            let e = AlbumEntry(albumId: albumId, appleMusicId: appleMusicId, title: title,
                               artist: artist, trackIds: trackIds, artworkUrl: artworkUrl,
                               year: year, addedAtMs: Date().timeIntervalSince1970 * 1000)
            albums.append(e)
            albumEntry = e
        }
        save()
        onAlbumBatchAdded?(freshSongs.map(Self.indexSong), albumEntry.map(Self.indexAlbum))
    }

    /// Drop superseded entries (their indexed replacements own the ids now).
    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        entries.removeAll { gone.contains($0.songId) }
        save()
    }

    /// Drop superseded ALBUM entries (the real indexed album owns the identity now).
    func remove(albumIds ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        albums.removeAll { gone.contains($0.albumId) }
        save()
    }

    /// Empty the provisional catalog: reset in-memory state and remove the persisted
    /// file (swallowing file-not-found like the rest of the store).
    func clear() {
        entries = []
        albums = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Re-decode after CloudSyncService pulled a newer copy, surfacing any NEW entries
    /// (songs AND albums) through `onAdded`/`onAlbumAdded` so the live catalog follows the pull.
    func reloadFromDisk() {
        let beforeSongs = Set(entries.map(\.songId))
        let beforeAlbums = Set(albums.map(\.albumId))
        let doc = Self.decodeDoc(fileURL)
        entries = doc.entries
        albums = doc.albums ?? []
        for e in entries where !beforeSongs.contains(e.songId) {
            onAdded?(Self.indexSong(e))
        }
        for a in albums where !beforeAlbums.contains(a.albumId) {
            onAlbumAdded?(Self.indexAlbum(a))
        }
    }

    // MARK: - Catalog synthesis (pure)

    /// Entry → catalog row. `IndexSong` is Decodable-only, so this builds via JSON
    /// (the `IndexSong.minimal` idiom) with the fields Discover knows.
    nonisolated static func indexSong(_ e: Entry) -> IndexSong {
        var obj: [String: Any] = ["id": e.songId, "name": e.title, "artist": e.artist,
                                  "appleMusicId": e.appleMusicId]
        if let ms = e.durationMs { obj["length"] = ms }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    /// Album entry → catalog album (`IndexAlbum` is Decodable-only — the same decode idiom;
    /// `coverArt` takes the absolute artwork URL, `appleMusicId` carries the supersede join key).
    nonisolated static func indexAlbum(_ e: AlbumEntry) -> IndexAlbum {
        var obj: [String: Any] = ["id": e.albumId, "name": e.title, "artist": e.artist,
                                  "appleMusicId": e.appleMusicId, "trackList": e.trackIds ?? []]
        if let v = e.artworkUrl { obj["coverArt"] = v }
        if let v = e.year { obj["year"] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }

    /// The synthetic SOURCE the multi-source catalog merge consumes — songs plus any
    /// provisional albums added in album mode (default empty preserves every existing caller).
    nonisolated static func syntheticIndex(_ entries: [Entry], albums albumEntries: [AlbumEntry] = []) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: "discover-adds", generatedAt: nil,
                                     sourceName: sourceName, counts: nil),
                  albums: albumEntries.map(indexAlbum), songs: entries.map(indexSong), playlists: nil)
    }

    /// The SUPERSEDE split (pure): entries whose Apple Music id is claimed by an
    /// INDEXED song yield to it — returns the survivors plus the (provisional →
    /// indexed) id pairs the collections remap applies.
    nonisolated static func split(_ entries: [Entry], indexedByAppleMusicId: [String: String])
        -> (keep: [Entry], superseded: [(from: String, to: String)]) {
        var keep: [Entry] = []
        var superseded: [(from: String, to: String)] = []
        for e in entries {
            if let indexedId = indexedByAppleMusicId[e.appleMusicId], indexedId != e.songId {
                superseded.append((from: e.songId, to: indexedId))
            } else {
                keep.append(e)
            }
        }
        return (keep, superseded)
    }

    /// The album twin of `split` (pure): provisional albums whose Apple Music id is claimed
    /// by an INDEXED album yield to it — returns the survivors plus the (provisional →
    /// indexed) id pairs. An album claiming ITSELF (the synthetic source in a later pass)
    /// never self-supersedes.
    nonisolated static func splitAlbums(_ albums: [AlbumEntry], indexedByAppleMusicId: [String: String])
        -> (keep: [AlbumEntry], superseded: [(from: String, to: String)]) {
        var keep: [AlbumEntry] = []
        var superseded: [(from: String, to: String)] = []
        for a in albums {
            if let indexedId = indexedByAppleMusicId[a.appleMusicId], indexedId != a.albumId {
                superseded.append((from: a.albumId, to: indexedId))
            } else {
                keep.append(a)
            }
        }
        return (keep, superseded)
    }

    private func save() {
        // Persist `albums` only when non-empty so a song-only store keeps writing the exact
        // legacy document shape (older app versions decode it unchanged).
        let doc = Document(entries: entries, albums: albums.isEmpty ? nil : albums)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
