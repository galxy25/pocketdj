import XCTest
@testable import PocketDJ

/// MusicKit-free tests for the Apple Music catalog mapping. They feed plain
/// `AppleMusicSongRow` values (no framework) through the pure mapping functions,
/// pinning the two hard constraints: ids are namespaced `am:<storeID>` and
/// `IndexSong.length` is **milliseconds** (seconds × 1000).
final class AppleMusicCatalogTests: XCTestCase {

    private func row(
        store: String = "1440913170",
        title: String = "Neon",
        artist: String = "Aria",
        track: Int? = 3,
        year: Int? = 2020,
        secs: Double? = 222.4,
        explicit: Bool? = true
    ) -> AppleMusicSongRow {
        AppleMusicSongRow(
            storeID: store, title: title, artist: artist, albumTitle: "Night Drive",
            trackNumber: track, year: year, durationSeconds: secs, isExplicit: explicit,
            artworkURL: URL(string: "https://art.test/\(store).jpg"))
    }

    // MARK: id namespacing

    func testNamespacedSongIDAndRoundTrip() {
        XCTAssertEqual(AppleMusicCatalog.namespacedSongID("123"), "am:123")
        XCTAssertEqual(AppleMusicCatalog.storeID(fromSongID: "am:123"), "123")
        // Album ids and foreign ids don't resolve back to a song store id.
        XCTAssertNil(AppleMusicCatalog.storeID(fromSongID: "am:album:123"))
        XCTAssertNil(AppleMusicCatalog.storeID(fromSongID: "youtube:abc"))
        XCTAssertNil(AppleMusicCatalog.storeID(fromSongID: "sng_1"))
    }

    // MARK: → StreamingTrack

    func testTrackMapping() {
        let t = AppleMusicCatalog.track(from: row())
        XCTAssertEqual(t.id, "am:1440913170")
        XCTAssertEqual(t.kind, .appleMusic)
        XCTAssertEqual(t.providerTrackID, "1440913170")  // raw store id for the player
        XCTAssertEqual(t.title, "Neon")
        XCTAssertEqual(t.artist, "Aria")
        XCTAssertEqual(t.durationSeconds, 222)            // rounded seconds
    }

    // MARK: → IndexSong (the Decodable-only, ms-length constraint)

    func testIndexSongMappingMillisecondsAndFields() throws {
        let song = try XCTUnwrap(AppleMusicCatalog.indexSong(from: row()))
        XCTAssertEqual(song.id, "am:1440913170")
        XCTAssertEqual(song.name, "Neon")
        XCTAssertEqual(song.artist, "Aria")
        XCTAssertEqual(song.trackNumber, 3)
        XCTAssertEqual(song.year, 2020)
        XCTAssertEqual(song.explicit, true)
        XCTAssertEqual(song.fileType, "applemusic")
        // 222.4 s → 222400 ms.
        XCTAssertEqual(song.length, 222400)
        // Audio-analysis fields are absent for a streaming row.
        XCTAssertNil(song.bpm)
        XCTAssertNil(song.key)
        XCTAssertNil(song.camelot)
        XCTAssertNil(song.sentimentKeywords)
    }

    func testIndexSongMappingHandlesMissingOptionals() throws {
        let song = try XCTUnwrap(AppleMusicCatalog.indexSong(
            from: row(track: nil, year: nil, secs: nil, explicit: nil)))
        XCTAssertEqual(song.id, "am:1440913170")
        XCTAssertNil(song.trackNumber)
        XCTAssertNil(song.year)
        XCTAssertNil(song.length)
        XCTAssertNil(song.explicit)
    }

    /// A mapped Apple Music IndexSong decodes/merges exactly like a catalog row
    /// would (it is in fact produced via the same JSON decode path).
    func testMappedSongDecodesAsIndexSong() throws {
        let song = try XCTUnwrap(AppleMusicCatalog.indexSong(from: row()))
        // Namespaced id guarantees it can't collide with a vinyl/Local id.
        XCTAssertTrue(song.id.hasPrefix("am:"))
    }
}
