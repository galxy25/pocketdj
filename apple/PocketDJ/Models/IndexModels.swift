import Foundation

/// Decodes the catalog `current-index.json` — the contract between the indexer
/// and the app (mirror of `src/types/index-json.ts`). Only the fields the
/// native client renders are modelled; unknown fields are ignored.
struct IndexJSON: Decodable {
    let manifest: Manifest
    let albums: [IndexAlbum]
    let songs: [IndexSong]
    /// Apple Music user playlists carried in the catalog (optional / back-compat:
    /// the fixture & vinyl sources have none). Read-only "From your sources" lists.
    let playlists: [IndexPlaylist]?

    init(manifest: Manifest, albums: [IndexAlbum], songs: [IndexSong],
         playlists: [IndexPlaylist]? = nil) {
        self.manifest = manifest
        self.albums = albums
        self.songs = songs
        self.playlists = playlists
    }
}

/// A read-only playlist that ships inside a catalog source (e.g. an Apple Music
/// user playlist). Not a `Playlist` template — just an ordered list of song ids.
struct IndexPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let songIds: [String]
}

/// An `IndexPlaylist` tagged with the name of the source it came from (for the
/// "From your sources" section's per-row source badge). Hashable so it's a
/// `navigationDestination` value.
struct SourcePlaylist: Identifiable, Hashable {
    let playlist: IndexPlaylist
    let sourceName: String
    var id: String { playlist.id }
    var name: String { playlist.name }
    var songIds: [String] { playlist.songIds }
}

/// Read-only source playlists carry no membership/playback timestamps, so under
/// `CollectionSortOrder` they order by NAME for every option (the `updatedAt == 0` /
/// `lastPlayedAt == nil` neutral defaults collapse Recently-played + Last-updated to the
/// name tie-break) — the same comparator the editable collections use.
extension SourcePlaylist: CollectionSortable {
    var updatedAt: Double { 0 }
    var lastPlayedAt: Double? { nil }
}

struct Manifest: Decodable {
    let source: String?
    let generatedAt: String?
    let sourceName: String?
    let counts: Counts?
}

struct Counts: Decodable {
    let albums: Int?
    let songs: Int?
}

struct ArtSource: Decodable, Hashable {
    let type: String        // "cdn" | "remote"
    let url: String
    let cors: Bool?
}

/// One detected audio segment for an album (audio-analysis ground truth).
struct AudioTrack: Decodable, Hashable {
    let trackNumber: Int?
    let startMs: Int?
    let endMs: Int?
    let durationMs: Int?
    let bpm: Double?
    let key: String?
    let camelot: String?
    let keyStrength: Double?
}

struct IndexAlbum: Decodable, Identifiable, Hashable {
    let id: String
    let artist: String
    let name: String
    let coverArt: String?
    let coverArtSources: [ArtSource]?
    let genre: String?
    let year: Int?
    let country: String?
    let trackList: [String]
    let fileType: String?
    let audioTracks: [AudioTrack]?
    let audioDurationSec: Double?
    /// Apple Music album store id (the iTunes `collectionId`) — the SUPERSEDE join key
    /// that lets a real indexed album cleanly replace a provisional Discover album with
    /// the same catalog identity (mirrors `IndexSong.appleMusicId`). OPTIONAL: absent on
    /// every existing indexed album, and the album indexers emit it only where an iTunes
    /// collectionId is resolvable. A bare numeric string when present.
    let appleMusicId: String?

    /// Canonical "Sharing" deep-links (F3), backfilled by the streaming-links pipeline.
    /// `appleMusicUrl` is derived directly from `appleMusicId`
    /// (`https://music.apple.com/album/<id>`); `spotifyUrl` / `youtubeUrl` come from the
    /// headless-browser resolver (`scripts/resolve-streaming-links.mjs`). All optional —
    /// absent until stamped. The inline `= nil` defaults keep the synthesized memberwise
    /// init source-compatible for `applying(_:)` + `OnlineSearchModel`, while the `Optional`
    /// type keeps decoding tolerant of the (many) index rows that lack them.
    var appleMusicUrl: String? = nil
    var spotifyUrl: String? = nil
    var youtubeUrl: String? = nil

    var hasAudioAnalysis: Bool { !(audioTracks ?? []).isEmpty }

    /// Ordered cover-art candidates: self-hosted CDN thumbnails first (fast,
    /// cacheable), then any absolute remote (iTunes) cover as a backup.
    var artCandidates: [URL] {
        var out: [URL] = []
        for s in coverArtSources ?? [] {
            if let u = Config.artURL(s.url) { out.append(u) }
        }
        if let c = coverArt, let u = Config.artURL(c) { out.append(u) }
        return out
    }
}

struct IndexSong: Decodable, Identifiable, Hashable {
    let id: String
    let albumId: String?
    let artist: String
    let name: String
    let trackNumber: Int?
    let year: Int?
    let sentimentKeywords: [String]?
    let explicit: Bool?
    let bpm: Double?
    let key: String?
    let camelot: String?
    let length: Int?        // milliseconds
    let fileType: String?
    let lyricsStatus: String?   // "found" | "notfound" | "error"
    /// Apple Music catalog store id ("adam id") the indexer resolved via the public
    /// iTunes Search API (`trackId`), written onto "Apple Music (Local)" songs by
    /// `scripts/resolve-apple-music-catalog.mjs`. A bare numeric string (e.g.
    /// "944459436"); absent when unresolved. Treated as a *candidate* catalog id the
    /// streaming provider must verify with a real MusicKit fetch before use — see
    /// `AppleMusicProvider.resolve(_:)`.
    let appleMusicId: String?

    /// Canonical "Sharing" deep-links (F3), backfilled by the streaming-links pipeline.
    /// `appleMusicUrl` is derived directly from `appleMusicId`
    /// (`https://music.apple.com/song/<id>`); `spotifyUrl` / `youtubeUrl` come from the
    /// headless-browser resolver (`scripts/resolve-streaming-links.mjs`). All optional —
    /// absent until stamped. The inline `= nil` defaults keep the synthesized memberwise
    /// init source-compatible for `applying(_:)` + `OnlineSearchModel`, while the `Optional`
    /// type keeps decoding tolerant of the (many) index rows that lack them.
    var appleMusicUrl: String? = nil
    var spotifyUrl: String? = nil
    var youtubeUrl: String? = nil

    /// Variant catalog ids resolved by `scripts/resolve-explicit-variants.mjs`. The primary
    /// `appleMusicId` is the user's cut and is never rewritten; these are the sibling
    /// EDITIONS of the same recording (explicit / clean), ADD-only in the index. Optional +
    /// inline `= nil`: decode-tolerant of the (many) rows that lack them, and keeps the
    /// synthesized memberwise init source-compatible for `applying(_:)`.
    var appleMusicIdExplicit: String? = nil
    var appleMusicIdClean: String? = nil

    /// Epoch milliseconds the track was added to the source library ("Date Added" in
    /// the Apple Music library, emitted by `index-apple-music.mjs`). Powers the
    /// "Recently added" virtual playlist's ranking of catalog (Apple-Music-library)
    /// songs alongside the client-side in-app add stores. Optional with an inline
    /// default so it stays decode-tolerant of the (many) index rows that predate it
    /// and keeps the synthesized memberwise init source-compatible for `applying(_:)`.
    var dateAdded: Double? = nil

    /// A minimal `IndexSong` carrying only the fields the playback engine needs (id +
    /// title + artist). `IndexSong` is Decodable-only (no memberwise init), so — like
    /// `AppleMusicCatalog.indexSong` — we build it by decoding a JSON object. Used when a
    /// caller (the row ▶) has only `(id, title, artist)` and must hand a song to the
    /// coordinator; the coordinator's provider chain + source map key off the id alone.
    static func minimal(id: String, name: String, artist: String, appleMusicId: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": artist]
        if let appleMusicId { obj["appleMusicId"] = appleMusicId }
        // Force-unwrap is safe: these three scalar fields always encode + decode (the rest
        // of IndexSong's fields are all optional). A failure would be a programmer error.
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }
}

extension IndexSong {
    /// The catalog id for a specific EDITION of this song. Falls back to the primary id
    /// when the primary is ALREADY that edition (per the `explicit` flag); nil when the
    /// edition is unknown/unresolved. Never invents an id.
    func appleMusicId(for variant: SongVariant) -> String? {
        switch variant {
        case .clean:    return appleMusicIdClean    ?? (explicit == false ? appleMusicId : nil)
        case .explicit: return appleMusicIdExplicit ?? (explicit == true  ? appleMusicId : nil)
        }
    }
}
