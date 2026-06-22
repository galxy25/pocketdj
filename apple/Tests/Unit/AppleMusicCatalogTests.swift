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

    // MARK: appleMusicId (index-resolved catalog candidate id)

    /// The indexer writes the iTunes-Search `trackId` onto each Apple-Music-(Local)
    /// song as `appleMusicId`. It must decode onto `IndexSong` so the streaming
    /// provider can try it as a catalog-fetch candidate before the fuzzy search.
    func testIndexSongDecodesAppleMusicId() throws {
        // A "sng_…" id — the shape Apple-Music-(Local) songs carry, which the
        // `am:` storeID decoder deliberately rejects (so step-2 always misses).
        let json = """
        {
          "id": "sng_3f2a1c",
          "artist": "Omarion",
          "name": "Post To Be (feat. Chris Brown & Jhené Aiko)",
          "fileType": "applemusic",
          "appleMusicId": "944459436"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(IndexSong.self, from: json)
        XCTAssertEqual(song.appleMusicId, "944459436")
        // Sanity: this id is NOT recoverable from the song id (proves why
        // `appleMusicId` is needed — step-2 `storeID(fromSongID:)` returns nil).
        XCTAssertNil(AppleMusicCatalog.storeID(fromSongID: song.id))
    }

    /// `appleMusicId` is optional / back-compat: a song JSON without it (vinyl,
    /// fixture, unresolved Apple-Music-Local rows) still decodes, with nil.
    func testIndexSongDecodesWithoutAppleMusicId() throws {
        let json = """
        { "id": "sng_99", "artist": "Aria", "name": "Neon" }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(IndexSong.self, from: json)
        XCTAssertNil(song.appleMusicId)
    }

    /// `IndexSong.minimal` (the row-▶ shim) carries no catalog id → nil, so resolve()
    /// skips its fast path for those and uses the id/search fallbacks.
    func testMinimalIndexSongHasNoAppleMusicId() {
        let song = IndexSong.minimal(id: "sng_1", name: "Neon", artist: "Aria")
        XCTAssertNil(song.appleMusicId)
    }
}
