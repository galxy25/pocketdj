import XCTest
@testable import PocketDJ

/// The items.json codec — the PWA `MusicItem[]` wire shape is load-bearing (R8: the PWA
/// importer hands it raw to bulkPutItems), so these tests pin exact field names and
/// null-conventions, the catalog closure, the studio-id fence, and lenient decode of
/// both the PWA's shape and our own output (round-trip).
@MainActor
final class PortableItemsTests: XCTestCase {

    private func song(_ id: String, albumId: String? = nil, bpm: Double? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": "Song \(id)", "artist": "Artist",
                                  "length": 180_000, "appleMusicId": "am-\(id)"]
        if let albumId { obj["albumId"] = albumId }
        if let bpm { obj["bpm"] = bpm }
        return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func album(_ id: String, tracks: [String]) -> IndexAlbum {
        let obj: [String: Any] = ["id": id, "name": "Album \(id)", "artist": "Artist",
                                  "trackList": tracks, "coverArt": "/art/\(id).jpg",
                                  "genre": "Soul", "year": 1998]
        return try! JSONDecoder().decode(IndexAlbum.self, from: try! JSONSerialization.data(withJSONObject: obj))
    }

    func testEncodeWritesExactPWASongShape() throws {
        let data = try PortableItems.encode(songIds: ["sng_1"], albumIds: [],
                                            songsById: ["sng_1": song("sng_1")], albumsById: [:])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["type"] as? String, "song")
        XCTAssertEqual(row["name"] as? String, "Song sng_1", "PWA field is `name`, never `title`")
        XCTAssertNil(row["title"])
        XCTAssertEqual(row["lengthMs"] as? Int, 180_000, "PWA field is `lengthMs`, never `length`")
        XCTAssertNil(row["length"])
        XCTAssertEqual(row["sentimentKeywords"] as? [String], [], "REQUIRED in the PWA model")
        XCTAssertEqual(row["explicit"] as? Bool, false, "REQUIRED in the PWA model")
        XCTAssertTrue(row["bpm"] is NSNull, "unknown analysis is explicit null (PWA convention)")
        XCTAssertTrue(row["key"] is NSNull)
        XCTAssertEqual(row["sourceId"] as? String, "src_imported")
        XCTAssertEqual(row["appleMusicId"] as? String, "am-sng_1")
        XCTAssertNotNil(row["createdAt"]); XCTAssertNotNil(row["updatedAt"])
    }

    func testEncodeClosesOverAlbumTracksAndSongAlbums() throws {
        let songs = ["sng_1": song("sng_1", albumId: "alb_1"),
                     "sng_2": song("sng_2", albumId: "alb_1"),
                     "sng_3": song("sng_3")]
        let albums = ["alb_1": album("alb_1", tracks: ["sng_1", "sng_2"])]
        // Reference ONLY sng_1: its album pulls in, and the album pulls sibling sng_2.
        let data = try PortableItems.encode(songIds: ["sng_1"], albumIds: [],
                                            songsById: songs, albumsById: albums)
        let payload = PortableItems.decode(data)
        XCTAssertEqual(Set(payload.songs.map(\.id)), ["sng_1", "sng_2"])
        XCTAssertEqual(payload.albums.map(\.id), ["alb_1"])
        XCTAssertEqual(payload.albums[0].trackIds, ["sng_1", "sng_2"])
    }

    func testDecodeToleratesPWAShapeAndJunk() {
        let pwaJson = """
        [
          {"id":"alb_9","sourceId":"src_abc","type":"album","createdAt":1,"updatedAt":1,
           "artist":"P","name":"PWA LP","trackIds":["sng_9"],"coverArtKey":"k",
           "coverArtSources":[{"type":"cdn","url":"/art/alb_9.webp","cors":true}]},
          {"id":"sng_9","sourceId":"src_abc","type":"song","createdAt":1,"updatedAt":1,
           "artist":"P","name":"PWA Song","albumId":"alb_9","sentimentKeywords":["warm"],
           "explicit":false,"bpm":null,"key":null,"camelot":"3B","lengthMs":222000,
           "lyrics":"la la","pointer":{"filename":"x.mp3"}},
          {"id":"broken row with no name"},
          "not even a dict — wait, yes it is not"
        ]
        """.data(using: .utf8)!
        let payload = PortableItems.decode(pwaJson)
        XCTAssertEqual(payload.albums.map(\.id), ["alb_9"])
        XCTAssertEqual(payload.albums[0].coverArtUrl, "/art/alb_9.webp")
        XCTAssertEqual(payload.songs.map(\.id), ["sng_9"])
        XCTAssertEqual(payload.songs[0].lengthMs, 222_000)
        XCTAssertEqual(payload.songs[0].camelot, "3B")
        XCTAssertNil(payload.songs[0].bpm, "explicit null decodes to nil")
    }

    func testReferencedIdsWalksNodesAndPocketsButNeverStudioIds() {
        let pocket = Pocket(id: "pkt_1", name: "P", songIds: ["sng_a", "smp_studio1"],
                            albumIds: ["alb_a"])
        let chapter = PlaylistNode(nodeId: "nd_c", kind: .sequence, children: [
            PlaylistNode(nodeId: "nd_1", kind: .song, songId: "sng_b"),
            PlaylistNode(nodeId: "nd_2", kind: .song, songId: "lp_loop1"),
            PlaylistNode(nodeId: "nd_3", kind: .album, albumId: "alb_b"),
            PlaylistNode(nodeId: "nd_4", kind: .pocket, pocketId: "pkt_1"),
        ])
        let playlist = Playlist(id: "pls_1", name: "L", sequences: [chapter])
        let ids = PortableItems.referencedIds(playlist: playlist, pockets: [pocket])
        XCTAssertEqual(ids.songs, ["sng_a", "sng_b"], "studio ids (smp_/lp_) never travel")
        XCTAssertEqual(ids.albums, ["alb_a", "alb_b"])
    }
}
