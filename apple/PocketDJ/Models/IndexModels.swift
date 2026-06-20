import Foundation

/// Decodes the catalog `current-index.json` — the contract between the indexer
/// and the app (mirror of `src/types/index-json.ts`). Only the fields the
/// native client renders are modelled; unknown fields are ignored.
struct IndexJSON: Decodable {
    let manifest: Manifest
    let albums: [IndexAlbum]
    let songs: [IndexSong]
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
}
