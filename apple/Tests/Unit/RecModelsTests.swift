import XCTest
@testable import PocketDJ

/// Recommendation-engine wire types: the upload batch encodes exactly the documented keys,
/// the responses decode LENIENTLY (missing/unknown fields never throw — the collections-schema
/// doctrine), and the pure suggestion→AddTarget filter resolves/dedupes/caps.
final class RecModelsTests: XCTestCase {

    func testUploadBatchEncodesExpectedKeys() throws {
        let batch = RecUploadBatch(
            deviceId: "dev-1", sentAtMs: 123,
            plays: [RecPlayEventWire(id: "e1", songId: "sng_a", atMs: 100, source: "browser")],
            favorites: [RecFavoriteWire(songId: "sng_a", favorited: true, atMs: 100)],
            activity: nil, puzzle: nil,
            collectionsSnapshot: RecCollectionsSnapshotWire(
                atMs: 100,
                collections: [.init(id: "pls_1", kind: "playlist", name: "Warmup", songIds: ["sng_a"])]))
        let data = try JSONEncoder().encode(batch)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["deviceId"] as? String, "dev-1")
        XCTAssertEqual(obj["sentAtMs"] as? Double, 123)
        XCTAssertNotNil(obj["plays"])
        XCTAssertNotNil(obj["favorites"])
        XCTAssertNotNil(obj["collectionsSnapshot"])
        // nil arrays are OMITTED, not null (JSONEncoder default for Optionals).
        XCTAssertNil(obj["activity"])
        XCTAssertNil(obj["puzzle"])
        let play = try XCTUnwrap((obj["plays"] as? [[String: Any]])?.first)
        XCTAssertEqual(play["id"] as? String, "e1")
        XCTAssertEqual(play["songId"] as? String, "sng_a")
        XCTAssertEqual(play["source"] as? String, "browser")
    }

    func testSongsResponseDecodesLeniently() throws {
        // Missing score/reasons, unknown keys, and one row with no songId (dropped).
        let json = """
        { "v": 1, "generatedAtMs": 5, "unknownTopLevel": {"x": 1},
          "songs": [
            { "songId": "sng_1", "name": "Neon", "artist": "Aria", "score": 4.2,
              "reasons": ["Same genre"], "surprise": true },
            { "songId": "sng_2" },
            { "name": "No Id" }
          ] }
        """
        let resp = try JSONDecoder().decode(RecSongsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.songs.count, 2)
        XCTAssertEqual(resp.songs[0].songId, "sng_1")
        XCTAssertEqual(resp.songs[0].reasons, ["Same genre"])
        XCTAssertEqual(resp.songs[1].songId, "sng_2")
        XCTAssertNil(resp.songs[1].score)
        XCTAssertNil(resp.songs[1].name)
    }

    func testCollectionsResponseDecodesLeniently() throws {
        let json = """
        { "v": 1, "songId": "sng_1",
          "suggestions": [
            { "id": "pls_1", "kind": "playlist", "name": "Warmup", "score": 3.1, "reasons": ["BPM fits"] },
            { "id": "pkt_2" },
            { "kind": "playlist" }
          ] }
        """
        let resp = try JSONDecoder().decode(RecCollectionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.songId, "sng_1")
        XCTAssertEqual(resp.suggestions.count, 2, "the id-less row is dropped")
        XCTAssertEqual(resp.suggestions[0].id, "pls_1")
        XCTAssertEqual(resp.suggestions[1].id, "pkt_2")
        XCTAssertNil(resp.suggestions[1].kind)

        // A completely empty body still decodes (all-optional).
        let empty = try JSONDecoder().decode(RecCollectionsResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.suggestions, [])
    }

    func testSuggestionFilterResolvesDedupesAndCaps() {
        let pockets = [Pocket(id: "pkt_1", name: "Soul"), Pocket(id: "pkt_2", name: "Funk")]
        let playlists = [Playlist(id: "pls_1", name: "Warmup", sequences: []),
                         Playlist(id: "pls_2", name: "Peak", sequences: []),
                         Playlist(id: "pls_3", name: "Cooldown", sequences: [])]
        let suggestions = [
            RecCollectionSuggestionWire(id: "pls_gone", kind: "playlist", name: "Deleted"),   // unresolvable
            RecCollectionSuggestionWire(id: "pls_1", kind: "playlist", name: "Warmup"),       // in Recent → dropped
            RecCollectionSuggestionWire(id: "pkt_1", kind: "pocket", name: "Soul"),
            RecCollectionSuggestionWire(id: "pls_2", kind: "playlist", name: "Peak"),
            RecCollectionSuggestionWire(id: "pkt_2", kind: "unknown-kind", name: "Funk"),     // bad kind
            RecCollectionSuggestionWire(id: "pls_3", kind: "playlist", name: "Cooldown"),
            RecCollectionSuggestionWire(id: "pkt_2", kind: "pocket", name: "Funk"),           // over the cap
        ]
        let recent = [AddTarget(kind: .playlist, id: "pls_1", sequenceId: "seq_x")]
        let out = RecSuggestionFilter.resolveTargets(suggestions, pockets: pockets,
                                                     playlists: playlists,
                                                     excluding: recent, limit: 3)
        XCTAssertEqual(out.map(\.id), ["pkt_1", "pls_2", "pls_3"])
        XCTAssertEqual(out.map(\.kind), [.pocket, .playlist, .playlist])
        XCTAssertTrue(out.allSatisfy { $0.sequenceId == nil })
    }
}
