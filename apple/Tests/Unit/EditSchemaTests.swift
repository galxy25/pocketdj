import XCTest
@testable import PocketDJ

final class EditSchemaTests: XCTestCase {
    func testRoundTrip() throws {
        var doc = EditsDocument()
        doc.albums["alb_1"] = AlbumEdit(name: "New Name", year: 1999)
        doc.songs["sng_1"] = SongEdit(bpm: 128, camelot: "8A")
        let data = try EditsCodec.encode(doc)
        let back = try EditsCodec.decode(data)
        XCTAssertEqual(back.schemaVersion, editsSchemaVersion)
        XCTAssertEqual(back.albums["alb_1"]?.name, "New Name")
        XCTAssertEqual(back.albums["alb_1"]?.year, 1999)
        XCTAssertEqual(back.songs["sng_1"]?.camelot, "8A")
    }

    func testMissingVersionMigratesToCurrent() throws {
        let json = #"{ "albums": {}, "songs": {} }"#          // no schemaVersion ⇒ v0
        let doc = try EditsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.schemaVersion, editsSchemaVersion)  // auto-migrated
    }

    func testUnknownFieldsIgnored() throws {
        // a future top-level key + a future field on an AlbumEdit
        let json = #"{ "schemaVersion": 1, "future": 42, "albums": { "alb_1": { "name": "X", "newField": true } }, "songs": {} }"#
        let doc = try EditsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.albums["alb_1"]?.name, "X")          // known field survives
    }

    func testNewerVersionDegradesNotFails() throws {
        let json = #"{ "schemaVersion": 999, "albums": { "alb_1": { "artist": "Y" } }, "songs": {} }"#
        let doc = try EditsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.schemaVersion, 999)                  // kept; no down-migration
        XCTAssertEqual(doc.albums["alb_1"]?.artist, "Y")        // known fields still load
    }

    func testMissingMapsDegradeToEmpty() throws {
        let doc = try EditsCodec.decode(Data(#"{ "schemaVersion": 1 }"#.utf8))
        XCTAssertTrue(doc.albums.isEmpty)
        XCTAssertTrue(doc.songs.isEmpty)
    }

    func testAlbumOverlayAppliesOnlySetFields() throws {
        let album = try TestData.index().albums[0]              // "Night Drive" / Aria / Electronic / 2020
        let edited = album.applying(AlbumEdit(name: "Renamed", genre: "Jazz"))
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertEqual(edited.genre, "Jazz")
        XCTAssertEqual(edited.artist, "Aria")                  // unset ⇒ unchanged
        XCTAssertEqual(edited.year, 2020)
        XCTAssertEqual(album.applying(nil).name, "Night Drive") // nil edit ⇒ identity
    }

    func testSongOverlay() throws {
        let song = try TestData.index().songs[0]               // sng_1 bpm 128 camelot 8A
        let edited = song.applying(SongEdit(bpm: 100, camelot: "5A"))
        XCTAssertEqual(edited.bpm, 100)
        XCTAssertEqual(edited.camelot, "5A")
        XCTAssertEqual(edited.name, "Neon")                    // unchanged
    }

    func testIsEmpty() {
        XCTAssertTrue(AlbumEdit().isEmpty)
        XCTAssertFalse(AlbumEdit(year: 2000).isEmpty)
        XCTAssertTrue(SongEdit().isEmpty)
        XCTAssertFalse(SongEdit(explicit: true).isEmpty)
    }
}
