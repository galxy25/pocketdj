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

    // MARK: - v2: audio-analysis edits

    func testSchemaVersionIsTwo() {
        XCTAssertEqual(editsSchemaVersion, 2)
    }

    func testAudioEditIsEmpty() {
        XCTAssertTrue(AudioTrackEdit().isEmpty)
        XCTAssertTrue(AudioTrackEdit(trackNumber: 2).isEmpty)     // a match key alone overrides nothing
        XCTAssertFalse(AudioTrackEdit(bpm: 120).isEmpty)
        // An AlbumEdit whose only audioTracks are all-empty deltas is itself empty.
        XCTAssertTrue(AlbumEdit(audioTracks: [AudioTrackEdit(), AudioTrackEdit(trackNumber: 1)]).isEmpty)
        XCTAssertFalse(AlbumEdit(audioTracks: [AudioTrackEdit(bpm: 99)]).isEmpty)
    }

    /// A v1 document (no audioTracks field) migrates cleanly to v2.
    func testV1ToV2Migration() throws {
        let json = #"{ "schemaVersion": 1, "albums": { "alb_1": { "name": "Keep" } }, "songs": {} }"#
        let doc = try EditsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.schemaVersion, 2)                       // upgraded
        XCTAssertEqual(doc.albums["alb_1"]?.name, "Keep")          // data preserved
        XCTAssertNil(doc.albums["alb_1"]?.audioTracks)             // absent ⇒ nil
    }

    /// A v2 document carrying an audioTracks edit decodes (and on a v1 app the
    /// extra field would simply be ignored — lenient decode, same code path).
    func testLenientDecodeOfAudioTracksEdit() throws {
        let json = #"""
        { "schemaVersion": 2, "songs": {},
          "albums": { "alb_1": { "name": "X",
            "audioTracks": [ { "trackNumber": 1, "bpm": 130, "camelot": "5A", "future": true } ] } } }
        """#
        let doc = try EditsCodec.decode(Data(json.utf8))
        let at = try XCTUnwrap(doc.albums["alb_1"]?.audioTracks)
        XCTAssertEqual(at.count, 1)
        XCTAssertEqual(at[0].bpm, 130)
        XCTAssertEqual(at[0].camelot, "5A")                        // unknown "future" ignored
    }

    /// Overlay applies bpm/key/camelot onto the matching segment (by trackNumber)
    /// and leaves the other segments intact.
    func testAudioOverlayMatchesByTrackNumber() throws {
        let album = try TestData.index().albums[0]                 // alb_1, 3 segments
        XCTAssertTrue(album.hasAudioAnalysis)
        let edit = AlbumEdit(audioTracks: [
            AudioTrackEdit(trackNumber: 2, bpm: 200, key: "G minor", camelot: "6A")
        ])
        let segs = try XCTUnwrap(album.applying(edit).audioTracks)
        // Segment 2 overridden…
        XCTAssertEqual(segs[1].bpm, 200)
        XCTAssertEqual(segs[1].key, "G minor")
        XCTAssertEqual(segs[1].camelot, "6A")
        XCTAssertEqual(segs[1].startMs, 222000)                    // untouched field kept
        // …others intact.
        XCTAssertEqual(segs[0].bpm, 128)
        XCTAssertEqual(segs[0].camelot, "8A")
        XCTAssertEqual(segs[2].bpm, 90)
    }

    /// With no trackNumber on the edit, overlay falls back to array index.
    func testAudioOverlayFallsBackToIndex() throws {
        let album = try TestData.index().albums[0]
        let edit = AlbumEdit(audioTracks: [
            AudioTrackEdit(bpm: 111),   // index 0
            AudioTrackEdit(),           // index 1 — empty, no-op
            AudioTrackEdit(camelot: "1B") // index 2
        ])
        let segs = try XCTUnwrap(album.applying(edit).audioTracks)
        XCTAssertEqual(segs[0].bpm, 111)
        XCTAssertEqual(segs[1].bpm, 124)                           // unchanged
        XCTAssertEqual(segs[2].camelot, "1B")
        XCTAssertEqual(segs[2].bpm, 90)                            // unchanged field kept
    }

    /// An album with no audio edits is unchanged.
    func testAudioOverlayNoEditIsIdentity() throws {
        let album = try TestData.index().albums[0]
        let same = album.applying(AlbumEdit(name: "Renamed"))      // album edit, no audio
        XCTAssertEqual(same.audioTracks, album.audioTracks)
        // An album with no detected segments + an audio edit just yields nil.
        let noAudio = try TestData.index().albums[1]               // alb_2, no audioTracks
        XCTAssertNil(noAudio.applying(AlbumEdit(audioTracks: [AudioTrackEdit(bpm: 99)])).audioTracks)
    }

    /// Audio edits round-trip through encode/decode (export/import parity).
    func testAudioEditRoundTrip() throws {
        var doc = EditsDocument()
        doc.albums["alb_1"] = AlbumEdit(name: "N", audioTracks: [
            AudioTrackEdit(trackNumber: 1, startMs: 10, endMs: 20, bpm: 140, key: "D major", camelot: "10B", keyStrength: 0.5)
        ])
        let back = try EditsCodec.decode(try EditsCodec.encode(doc))
        XCTAssertEqual(back.schemaVersion, 2)
        let at = try XCTUnwrap(back.albums["alb_1"]?.audioTracks)
        XCTAssertEqual(at[0].bpm, 140)
        XCTAssertEqual(at[0].camelot, "10B")
        XCTAssertEqual(at[0].keyStrength, 0.5)
        XCTAssertEqual(at[0].startMs, 10)
    }
}
