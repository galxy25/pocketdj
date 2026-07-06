import XCTest
@testable import PocketDJ

/// Schema v5 — LOSSY per-element playlist decoding (spec §8). The pre-v5 trap: ONE
/// unknown-kind node made the whole synthesized `[Playlist]` decode throw, the
/// document's lenient `try?` yielded `playlists = []`, and the next save() destroyed
/// every playlist. v5 must drop THAT ELEMENT ONLY — never a chapter, the list, or the
/// document — at all three depths (chapter slot, chapter child, nested grandchild),
/// and known-kind documents must decode/encode exactly as before.
final class CollectionsLossyDecodeTests: XCTestCase {

    // Decode, then simulate the app's save() → reload cycle (the step that used to
    // AMPLIFY a decode failure into permanent loss) — survivors must survive BOTH.
    private func decodeAndResave(_ json: String) throws -> (decoded: CollectionsDocument, resaved: CollectionsDocument) {
        let decoded = try CollectionsCodec.decode(Data(json.utf8))
        let resaved = try CollectionsCodec.decode(CollectionsCodec.encode(decoded))
        return (decoded, resaved)
    }

    // MARK: unknown kind at the TOP level (a chapter slot in `sequences`)

    func testUnknownKindChapterSlotDropsThatSlotOnly() throws {
        let json = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "sequences": [
              { "nodeId": "seq_1", "kind": "sequence", "name": "One", "children": [
                  { "nodeId": "n_1", "kind": "song", "songId": "sng_1" } ] },
              { "nodeId": "n_future", "kind": "hologram", "songId": "xyz_1" },
              { "nodeId": "seq_2", "kind": "sequence", "name": "Two", "children": [] }
            ], "createdAt": 0, "updatedAt": 0 },
          { "id": "pls_b", "name": "B", "sequences": [
              { "nodeId": "seq_b", "kind": "sequence", "name": "Default", "children": [] }
            ], "createdAt": 0, "updatedAt": 0 }
        ] }
        """
        let (decoded, resaved) = try decodeAndResave(json)
        for doc in [decoded, resaved] {
            XCTAssertEqual(doc.playlists.map(\.id), ["pls_a", "pls_b"])          // other playlists survive
            let a = try XCTUnwrap(doc.playlists.first)
            XCTAssertEqual(a.sequences.map(\.nodeId), ["seq_1", "seq_2"])        // only the unknown slot dropped
            XCTAssertEqual(a.sequences.first?.children?.map(\.songId), ["sng_1"]) // siblings' content intact
        }
    }

    // MARK: unknown kind as a CHAPTER CHILD

    func testUnknownKindChapterChildDropsThatChildOnly() throws {
        let json = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "sequences": [
              { "nodeId": "seq_1", "kind": "sequence", "name": "One", "children": [
                  { "nodeId": "n_1", "kind": "song", "songId": "sng_1" },
                  { "nodeId": "n_x", "kind": "sample", "songId": "smp_1" },
                  { "nodeId": "n_2", "kind": "text", "text": "mic break" },
                  { "nodeId": "n_3", "kind": "song", "songId": "sng_2" }
                ] }
            ], "createdAt": 0, "updatedAt": 0 }
        ] }
        """
        let (decoded, resaved) = try decodeAndResave(json)
        for doc in [decoded, resaved] {
            let children = try XCTUnwrap(doc.playlists.first?.sequences.first?.children)
            XCTAssertEqual(children.map(\.nodeId), ["n_1", "n_2", "n_3"])        // order + siblings kept
            XCTAssertEqual(children[1].text, "mic break")
        }
    }

    // MARK: unknown kind as a NESTED GRANDCHILD (sub-sequence recursion)

    func testUnknownKindNestedGrandchildDropsThatGrandchildOnly() throws {
        let json = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "sequences": [
              { "nodeId": "seq_1", "kind": "sequence", "name": "One", "children": [
                  { "nodeId": "sub_1", "kind": "sequence", "name": "Sub", "children": [
                      { "nodeId": "g_1", "kind": "song", "songId": "sng_1" },
                      { "nodeId": "g_x", "kind": "loop", "songId": "lp_1" }
                    ] },
                  { "nodeId": "n_2", "kind": "song", "songId": "sng_2" }
                ] }
            ], "createdAt": 0, "updatedAt": 0 }
        ] }
        """
        let (decoded, resaved) = try decodeAndResave(json)
        for doc in [decoded, resaved] {
            let chapter = try XCTUnwrap(doc.playlists.first?.sequences.first)
            XCTAssertEqual(chapter.children?.map(\.nodeId), ["sub_1", "n_2"])    // sub-sequence survives
            XCTAssertEqual(chapter.children?.first?.children?.map(\.nodeId), ["g_1"]) // only grandchild dropped
        }
    }

    // MARK: an undecodable PLAYLIST drops that playlist only (never the list)

    func testUndecodablePlaylistDropsThatPlaylistOnly() throws {
        let json = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "sequences": [], "createdAt": 0, "updatedAt": 0 },
          { "id": "pls_bad", "sequences": [], "createdAt": 0, "updatedAt": 0 },
          { "id": "pls_c", "name": "C", "sequences": [], "createdAt": 0, "updatedAt": 0 }
        ] }
        """
        let doc = try CollectionsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.playlists.map(\.id), ["pls_a", "pls_c"])              // missing `name` ⇒ dropped
    }

    // MARK: known-kind documents are unchanged by the hand-written decoders

    // Every field of every known kind survives decode exactly as the synthesized
    // decoder read it (field-for-field verification of the explicit init(from:)).
    func testKnownKindFieldsDecodeExactly() throws {
        let json = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "description": "desc", "targetMs": 3600000,
            "folderId": "fld_1", "createdAt": 12.5, "updatedAt": 13.5, "sequences": [
              { "nodeId": "seq_1", "kind": "sequence", "name": "One", "targetMs": 600000,
                "note": "chapter cue", "children": [
                  { "nodeId": "n_1", "kind": "song", "songId": "sng_1", "note": "opener" },
                  { "nodeId": "n_2", "kind": "album", "albumId": "alb_1" },
                  { "nodeId": "n_3", "kind": "pocket", "pocketId": "pkt_1" },
                  { "nodeId": "n_4", "kind": "text", "text": "say hi" }
                ] }
            ] }
        ] }
        """
        let doc = try CollectionsCodec.decode(Data(json.utf8))
        let pl = try XCTUnwrap(doc.playlists.first)
        XCTAssertEqual(pl.description, "desc")
        XCTAssertEqual(pl.targetMs, 3_600_000)
        XCTAssertEqual(pl.folderId, "fld_1")
        XCTAssertEqual(pl.createdAt, 12.5)
        XCTAssertEqual(pl.updatedAt, 13.5)
        let seq = try XCTUnwrap(pl.sequences.first)
        XCTAssertEqual(seq.kind, .sequence)
        XCTAssertEqual(seq.name, "One")
        XCTAssertEqual(seq.targetMs, 600_000)
        XCTAssertEqual(seq.note, "chapter cue")
        let kids = try XCTUnwrap(seq.children)
        XCTAssertEqual(kids.map(\.kind), [.song, .album, .pocket, .text])
        XCTAssertEqual(kids[0].songId, "sng_1")
        XCTAssertEqual(kids[0].note, "opener")
        XCTAssertEqual(kids[1].albumId, "alb_1")
        XCTAssertEqual(kids[2].pocketId, "pkt_1")
        XCTAssertEqual(kids[3].text, "say hi")
    }

    // encode(to:) stays SYNTHESIZED: a known-kind document must round-trip to byte-
    // identical JSON (sortedKeys encoder ⇒ deterministic), proving the lossy decoders
    // lose nothing and re-encode nothing differently for known kinds.
    func testKnownKindRoundTripBytesStable() throws {
        var doc = CollectionsDocument()
        var pl = CollectionsFactory.makePlaylist("Set", now: 42)
        pl.description = "d"
        pl.targetMs = 60_000
        pl.folderId = "fld_9"
        pl.sequences[0].children = [
            PlaylistNode(nodeId: "n_1", kind: .song, songId: "sng_1", note: "cue"),
            PlaylistNode(nodeId: "n_2", kind: .album, albumId: "alb_1"),
            PlaylistNode(nodeId: "n_3", kind: .pocket, pocketId: "pkt_1"),
            PlaylistNode(nodeId: "n_4", kind: .text, text: "hello"),
            PlaylistNode(nodeId: "n_5", kind: .sequence, name: "Sub", targetMs: 5_000,
                         children: [PlaylistNode(nodeId: "n_6", kind: .song, songId: "sng_2")]),
        ]
        doc.playlists = [pl]
        let first = try CollectionsCodec.encode(doc)
        let second = try CollectionsCodec.encode(CollectionsCodec.decode(first))
        XCTAssertEqual(first, second)                                            // byte-identical round trip
    }

    // MARK: v4 → v5 migration (no-op shape transform, version stamped)

    func testV4DocMigratesToV5() throws {
        let v4 = """
        { "schemaVersion": 4, "pockets": [], "playlists": [
          { "id": "pls_a", "name": "A", "sequences": [], "createdAt": 0, "updatedAt": 0 }
        ] }
        """
        let doc = try CollectionsCodec.decode(Data(v4.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)              // bumped to 5
        XCTAssertEqual(doc.playlists.first?.name, "A")                           // nothing transformed
    }
}
