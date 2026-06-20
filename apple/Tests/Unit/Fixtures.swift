import Foundation
@testable import PocketDJ

/// A tiny in-memory catalog shared by the logic tests — no bundle, no network.
enum TestData {
    static let json = """
    {
      "manifest": { "sourceName": "Test Crate", "counts": { "albums": 3, "songs": 7 } },
      "albums": [
        { "id": "alb_1", "artist": "Aria", "name": "Night Drive", "genre": "Electronic", "year": 2020, "country": "US", "trackList": ["sng_1","sng_2","sng_3"], "fileType": "mp3" },
        { "id": "alb_2", "artist": "Bento", "name": "Brass Era", "genre": "Jazz", "year": 1998, "country": "JP", "trackList": ["sng_4","sng_5"], "fileType": "aiff" },
        { "id": "alb_3", "artist": "Cobalt", "name": "Red Clay", "genre": "Funk / Soul", "year": 1975, "country": "GB", "trackList": ["sng_6","sng_7"], "fileType": "mp3" }
      ],
      "songs": [
        { "id": "sng_1", "albumId": "alb_1", "artist": "Aria", "name": "Neon", "trackNumber": 1, "year": 2020, "bpm": 128, "key": "A minor", "camelot": "8A", "length": 222000, "explicit": false, "sentimentKeywords": ["night","drive"] },
        { "id": "sng_2", "albumId": "alb_1", "artist": "Aria", "name": "Pulse", "trackNumber": 2, "year": 2020, "bpm": 124, "key": "C major", "camelot": "8B", "length": 201000, "explicit": true, "sentimentKeywords": ["energetic"] },
        { "id": "sng_3", "albumId": "alb_1", "artist": "Aria", "name": "Drift", "trackNumber": 3, "year": 2020, "bpm": 90, "key": "E minor", "camelot": "9A", "length": 305000, "explicit": false },
        { "id": "sng_4", "albumId": "alb_2", "artist": "Bento", "name": "Swing Low", "trackNumber": 1, "year": 1998, "bpm": 110, "key": "F major", "camelot": "7B", "length": 240000, "explicit": false },
        { "id": "sng_5", "albumId": "alb_2", "artist": "Bento", "name": "Blue Note", "trackNumber": 2, "year": 1998, "bpm": 96, "key": "D minor", "camelot": "7A", "length": 263000, "explicit": false },
        { "id": "sng_6", "albumId": "alb_3", "artist": "Cobalt", "name": "Get Down", "trackNumber": 1, "year": 1975, "bpm": 116, "key": "G major", "camelot": "9B", "length": 198000, "explicit": true },
        { "id": "sng_7", "albumId": "alb_3", "artist": "Cobalt", "name": "Slow Burn", "trackNumber": 2, "year": 1975, "bpm": 72, "key": "B minor", "camelot": "10A", "length": 351000, "explicit": false }
      ]
    }
    """

    static func index() throws -> IndexJSON {
        try JSONDecoder().decode(IndexJSON.self, from: Data(json.utf8))
    }

    static func albumItems() throws -> [BrowseItem] {
        try index().albums.map { .album($0) }
    }

    static func songItems() throws -> [BrowseItem] {
        let idx = try index()
        let byId = Dictionary(uniqueKeysWithValues: idx.albums.map { ($0.id, $0.name) })
        return idx.songs.map { .song($0, albumName: $0.albumId.flatMap { byId[$0] } ?? "") }
    }

    /// Loader stub for AppModel — returns the in-memory index.
    struct StubLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON { try TestData.index() }
    }
}

extension BrowseItem {
    var idString: String { id }
}
