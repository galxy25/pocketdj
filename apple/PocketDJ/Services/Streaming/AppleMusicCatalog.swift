import Foundation

// ============================================================================
// MARK: - Provider-neutral row (MusicKit-free, so the mapping is unit-testable)
// ============================================================================

/// A flattened Apple Music catalog row, deliberately free of any MusicKit type so
/// the mapping logic (→ `StreamingTrack` / → `IndexSong`) can be exercised in
/// tests on a machine without the framework linked. The `#if canImport(MusicKit)`
/// extension below knows how to build one of these from a `MusicKit.Song`.
struct AppleMusicSongRow: Hashable {
    /// Apple Music store id (`Song.id.rawValue`), e.g. "1440913170".
    let storeID: String
    let title: String
    let artist: String
    let albumTitle: String?
    let trackNumber: Int?
    /// Release year when known (parsed from the release date).
    let year: Int?
    let durationSeconds: Double?
    let isExplicit: Bool?
    let artworkURL: URL?
}

// ============================================================================
// MARK: - Catalog mapping (pure functions — no MusicKit, no network)
// ============================================================================

/// Maps Apple Music catalog rows into the two shapes the app consumes:
///   • `StreamingTrack` — what the player/search UI shows and what the player loads.
///   • `IndexSong`      — a catalog row appended into `AppModel.songs` so an Apple
///     Music track behaves like any other song in Browse / setlists.
///
/// IMPORTANT CONSTRAINTS baked in here:
///   • `IndexSong` is **Decodable-only** (no memberwise/`Encodable`), so we cannot
///     construct one directly — we build a JSON object and decode it. That keeps
///     this module from having to touch the model file at all.
///   • `IndexSong.length` is **milliseconds**, while Apple Music durations are
///     seconds → we multiply by 1000.
///   • Ids are **source-namespaced** (`am:<storeID>`) so the first-id-wins catalog
///     dedupe never collapses a streaming track onto a vinyl/Local song.
enum AppleMusicCatalog {
    /// Namespace prefix for every Apple Music id we mint (song + album).
    static let idPrefix = "am"

    static func namespacedSongID(_ storeID: String) -> String { "\(idPrefix):\(storeID)" }
    static func namespacedAlbumID(_ storeID: String) -> String { "\(idPrefix):album:\(storeID)" }

    /// Pull the raw Apple Music store id back out of a namespaced song id, or nil
    /// if the id isn't one of ours. Used by the provider's recognizer/playback path.
    static func storeID(fromSongID id: String) -> String? {
        let prefix = "\(idPrefix):"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        // Guard against the album form ("am:album:…") leaking in.
        guard !rest.hasPrefix("album:") else { return nil }
        return rest
    }

    // MARK: → StreamingTrack

    static func track(from row: AppleMusicSongRow) -> StreamingTrack {
        StreamingTrack(
            id: namespacedSongID(row.storeID),
            kind: .appleMusic,
            providerTrackID: row.storeID,        // ApplicationMusicPlayer plays by store id
            title: row.title,
            artist: row.artist,
            artworkURL: row.artworkURL,
            durationSeconds: row.durationSeconds.map { Int($0.rounded()) })
    }

    // MARK: → IndexSong (built in memory by decoding a JSON object)

    /// Build an `IndexSong` for an Apple Music row. Returns nil only if JSON
    /// encoding/decoding round-trips fail (never expected for these scalar fields).
    /// `sourceName` is carried by `AppModel`'s source-tagging map, not the song, so
    /// it isn't part of the JSON object.
    static func indexSong(from row: AppleMusicSongRow) -> IndexSong? {
        var obj: [String: Any] = [
            "id": namespacedSongID(row.storeID),
            "artist": row.artist,
            "name": row.title,
            "fileType": "applemusic",
        ]
        if let albumStoreID = row.albumStoreID {
            obj["albumId"] = namespacedAlbumID(albumStoreID)
        }
        if let n = row.trackNumber { obj["trackNumber"] = n }
        if let y = row.year { obj["year"] = y }
        if let e = row.isExplicit { obj["explicit"] = e }
        // seconds → milliseconds. bpm/key/camelot/sentiment stay absent (nil).
        if let secs = row.durationSeconds { obj["length"] = Int((secs * 1000).rounded()) }

        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let song = try? JSONDecoder().decode(IndexSong.self, from: data)
        else { return nil }
        return song
    }
}

// Album linkage is optional in the v1 contribution (we append songs, not full
// albums). Kept as a computed nil so `indexSong` stays a pure function over the
// row; when the provider later fetches album ids it can populate this.
private extension AppleMusicSongRow {
    var albumStoreID: String? { nil }
}
