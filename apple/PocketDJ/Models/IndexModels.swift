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

    /// A minimal `IndexSong` carrying only the fields the playback engine needs (id +
    /// title + artist). `IndexSong` is Decodable-only (no memberwise init), so — like
    /// `AppleMusicCatalog.indexSong` — we build it by decoding a JSON object. Used when a
    /// caller (the row ▶) has only `(id, title, artist)` and must hand a song to the
    /// coordinator; the coordinator's provider chain + source map key off the id alone.
    static func minimal(id: String, name: String, artist: String) -> IndexSong {
        let obj: [String: Any] = ["id": id, "name": name, "artist": artist]
        // Force-unwrap is safe: these three scalar fields always encode + decode (the rest
        // of IndexSong's fields are all optional). A failure would be a programmer error.
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }
}
