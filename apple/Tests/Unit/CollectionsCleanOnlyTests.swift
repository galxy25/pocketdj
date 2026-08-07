import XCTest
@testable import PocketDJ

/// CollectionsStore + schema behavior of the clean-versions-only toggle: additive-optional
/// decode (old docs → nil), setter round-trip, SetlistTrack.variant lenient wire behavior,
/// the playNow substitution funnel, and the frozen-variant ripIds(forSetlist:).
@MainActor
final class CollectionsCleanOnlyTests: XCTestCase {
    private func store() -> CollectionsStore {
        CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cleanonly-\(UUID().uuidString).json"))
    }

    /// A 3-song catalog for the substitution cases: sng_1 clean, sng_2 explicit WITH a
    /// clean id, sng_6 explicit WITHOUT one (mirrors the app fixture's trio).
    private struct CleanLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            let json = """
            { "manifest": { "sourceName": "Clean Crate", "counts": { "albums": 1, "songs": 3 } },
              "albums": [ { "id": "alb_1", "artist": "Aria", "name": "Night Drive", "genre": "Electronic",
                            "year": 2020, "country": "US", "trackList": ["sng_1","sng_2","sng_6"], "fileType": "mp3" } ],
              "songs": [
                { "id": "sng_1", "albumId": "alb_1", "artist": "Aria", "name": "Neon", "length": 222000, "explicit": false },
                { "id": "sng_2", "albumId": "alb_1", "artist": "Aria", "name": "Pulse", "length": 201000, "explicit": true,
                  "appleMusicId": "800000002", "appleMusicIdClean": "900000002" },
                { "id": "sng_6", "albumId": "alb_1", "artist": "Cobalt", "name": "Get Down", "length": 198000, "explicit": true }
              ] }
            """
            return try JSONDecoder().decode(IndexJSON.self, from: Data(json.utf8))
        }
    }

    private func appModel() async -> AppModel {
        let app = AppModel(loader: CleanLoader())
        await app.loadIfNeeded()
        return app
    }

    func testSetCleanOnlyRoundTripsAndOldDocDecodesNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cleanonly-rt-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let pl = s1.createPlaylist("Set")
        let pk = s1.createPocket("Crate")
        XCTAssertNil(s1.playlist(pl.id)?.cleanOnly)          // untouched ⇒ nil (bytes unchanged)
        s1.setCleanOnly(true, forPlaylist: pl.id)
        s1.setCleanOnly(true, forPocket: pk.id)
        // Reload from disk — the toggle round-trips.
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.playlist(pl.id)?.cleanOnly, true)
        XCTAssertEqual(s2.pocket(pk.id)?.cleanOnly, true)
        // OFF stores nil (never false), so an off collection's serialization is unchanged.
        s2.setCleanOnly(false, forPlaylist: pl.id)
        XCTAssertNil(s2.playlist(pl.id)?.cleanOnly)

        // An OLD document (no cleanOnly key anywhere) decodes with nil — feature off.
        let old = """
        { "schemaVersion": 7, "pockets": [
            { "id": "pkt_old", "name": "Old", "songIds": [], "albumIds": [], "childPocketIds": [],
              "createdAt": 0, "updatedAt": 0 } ],
          "playlists": [
            { "id": "pls_old", "name": "Old", "sequences": [], "createdAt": 0, "updatedAt": 0 } ] }
        """
        let doc = try CollectionsCodec.decode(Data(old.utf8))
        XCTAssertNil(doc.pockets.first?.cleanOnly)
        XCTAssertNil(doc.playlists.first?.cleanOnly)
    }

    func testSetlistTrackVariantLenientDecodeAndEncode() throws {
        // With the key → typed projection; unknown value → songVariant nil but raw kept.
        let t1 = try JSONDecoder().decode(SetlistTrack.self, from: Data(
            #"{"songId":"sng_1a7f6bc854af","artist":"A","name":"N","variant":"clean"}"#.utf8))
        XCTAssertEqual(t1.variant, "clean")
        XCTAssertEqual(t1.songVariant, .clean)
        let t2 = try JSONDecoder().decode(SetlistTrack.self, from: Data(
            #"{"songId":"sng_1a7f6bc854af","artist":"A","name":"N"}"#.utf8))
        XCTAssertNil(t2.variant)
        XCTAssertNil(t2.songVariant)
        let t3 = try JSONDecoder().decode(SetlistTrack.self, from: Data(
            #"{"songId":"sng_1a7f6bc854af","artist":"A","name":"N","variant":"futuristic"}"#.utf8))
        XCTAssertEqual(t3.variant, "futuristic")   // forward-tolerant raw survives…
        XCTAssertNil(t3.songVariant)               // …but never maps to a known edition
        // Encode round-trip keeps the stamp.
        let rt = try JSONDecoder().decode(SetlistTrack.self, from: JSONEncoder().encode(t1))
        XCTAssertEqual(rt.songVariant, .clean)
    }

    func testPlayNowPlaylistCleanOnlyFiltersQueueAndStampsVariant() async {
        let app = await appModel()
        let s = store(); s.app = app
        let pl = s.createPlaylist("Clean Test")
        for id in ["sng_1", "sng_2", "sng_6"] { s.addSong(id, toPlaylist: pl.id) }

        // OFF: all three, no variant stamps.
        let off = s.playNow(playlistId: pl.id)
        XCTAssertEqual(off?.tracks.map(\.songId), ["sng_1", "sng_2", "sng_6"])
        XCTAssertTrue(off!.tracks.allSatisfy { $0.variant == nil })

        // ON: sng_6 (explicit, no clean id) drops; sng_2 substitutes clean.
        s.setCleanOnly(true, forPlaylist: pl.id)
        let on = s.playNow(playlistId: pl.id)
        XCTAssertEqual(on?.tracks.map(\.songId), ["sng_1", "sng_2"])
        XCTAssertNil(on?.tracks.first?.variant)
        XCTAssertEqual(on?.tracks.last?.variant, "clean")
        XCTAssertEqual(on?.tracks.last?.songVariant, .clean)
    }

    func testRipIdsForSetlistUsesFrozenVariants() async {
        let app = await appModel()
        let s = store(); s.app = app
        // Freeze a substituted queue into the reserved Now Playing setlist.
        _ = s.playNow(songIds: ["sng_1", "sng_2"], variants: ["sng_2": .clean])
        XCTAssertEqual(s.ripIds(forSetlist: nowPlayingSetlistId), ["sng_1", "sng_2_clean"])
        // The CSV/Storage-facing resolver keeps BASE ids (no variant leakage).
        XCTAssertEqual(s.songIds(forSetlist: nowPlayingSetlistId), ["sng_1", "sng_2"])
    }

    func testRipIdsForPlaylistSubstitutesUnderCleanOnly() async {
        let app = await appModel()
        let s = store(); s.app = app
        let pl = s.createPlaylist("Clean Test")
        for id in ["sng_1", "sng_2", "sng_6"] { s.addSong(id, toPlaylist: pl.id) }
        XCTAssertEqual(s.ripIds(forPlaylist: pl.id), ["sng_1", "sng_2", "sng_6"])   // off = passthrough
        s.setCleanOnly(true, forPlaylist: pl.id)
        XCTAssertEqual(s.ripIds(forPlaylist: pl.id), ["sng_1", "sng_2_clean"])
        // songIds (CSV/Storage) is deliberately untouched by the toggle.
        XCTAssertEqual(s.songIds(forPlaylist: pl.id), ["sng_1", "sng_2", "sng_6"])
    }
}
