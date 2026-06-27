import XCTest
@testable import PocketDJ

/// MusicKit-free tests for the recognizer → Apple Music library reducer + matchers
/// (`AppleMusicRecognition`). They pin the branch table (connect / checking / open-album /
/// add) and the normalized album/song matching, none of which touch the framework.
final class AppleMusicRecognitionTests: XCTestCase {

    // MARK: builders (Decodable-only models → decode small JSON objects)

    private func album(id: String, name: String, artist: String) -> IndexAlbum {
        let obj: [String: Any] = ["id": id, "artist": artist, "name": name, "trackList": []]
        return try! JSONDecoder().decode(IndexAlbum.self,
            from: try! JSONSerialization.data(withJSONObject: obj))
    }
    private func song(id: String, name: String, artist: String,
                      appleMusicId: String? = nil, albumId: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "artist": artist, "name": name]
        if let appleMusicId { obj["appleMusicId"] = appleMusicId }
        if let albumId { obj["albumId"] = albumId }
        return try! JSONDecoder().decode(IndexSong.self,
            from: try! JSONSerialization.data(withJSONObject: obj))
    }
    private func ref(store: String = "999", title: String, artist: String) -> AppleMusicAlbumRef {
        AppleMusicAlbumRef(storeID: store, title: title, artist: artist,
                           year: 2020, artworkURL: nil, url: nil)
    }
    private func resolution(store: String = "555", title: String = "Neon", artist: String = "Aria",
                            inLibrary: Bool, album: AppleMusicAlbumRef? = nil,
                            songURL: URL? = nil) -> AppleMusicResolution {
        AppleMusicResolution(songStoreID: store, title: title, artist: artist,
                             inLibrary: inLibrary, album: album, songURL: songURL)
    }

    // MARK: action reducer

    func testUnavailableWhenNotAvailable() {
        let a = AppleMusicRecognition.action(available: false, canContribute: true, canAdd: true,
            resolving: false, resolution: resolution(inLibrary: true), indexAlbumID: nil)
        XCTAssertEqual(a, .unavailable)
    }

    func testConnectWhenAvailableButCannotContribute() {
        let a = AppleMusicRecognition.action(available: true, canContribute: false, canAdd: false,
            resolving: false, resolution: nil, indexAlbumID: nil)
        XCTAssertEqual(a, .connect)
    }

    func testCheckingWhileResolving() {
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: true, resolution: nil, indexAlbumID: nil)
        XCTAssertEqual(a, .checking)
    }

    func testNotFoundWhenResolvedNothing() {
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: false, resolution: nil, indexAlbumID: nil)
        XCTAssertEqual(a, .notFound)
    }

    func testInLibraryAlbumInIndexOpensInApp() {
        let r = resolution(inLibrary: true, album: ref(title: "Night Drive", artist: "Aria"))
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: false, resolution: r, indexAlbumID: "alb_1")
        XCTAssertEqual(a, .openIndexAlbum(albumID: "alb_1"))
    }

    func testInLibraryAlbumNotInIndexOpensRecognizedScreen() {
        let albumRef = ref(title: "Night Drive", artist: "Aria")
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: false, resolution: resolution(inLibrary: true, album: albumRef), indexAlbumID: nil)
        XCTAssertEqual(a, .openRecognizedAlbum(albumRef))
    }

    func testInLibraryNoAlbumIsInformational() {
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: false, resolution: resolution(inLibrary: true, album: nil), indexAlbumID: nil)
        XCTAssertEqual(a, .inLibrary)
    }

    func testNotInLibraryOffersAdd() {
        let r = resolution(store: "777", title: "Neon", artist: "Aria", inLibrary: false)
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: true,
            resolving: false, resolution: r, indexAlbumID: nil)
        XCTAssertEqual(a, .addToLibrary(storeID: "777", title: "Neon", artist: "Aria"))
    }

    func testNotInLibraryNoAddCapabilityOpensMusicApp() {
        let url = URL(string: "https://music.apple.com/us/song/777")!
        let r = resolution(store: "777", title: "Neon", artist: "Aria", inLibrary: false, songURL: url)
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: false,
            resolving: false, resolution: r, indexAlbumID: nil)
        XCTAssertEqual(a, .openInMusicApp(url))
    }

    func testNotInLibraryNoAddNoURLFallsToNotFound() {
        let r = resolution(store: "777", inLibrary: false, songURL: nil)
        let a = AppleMusicRecognition.action(available: true, canContribute: true, canAdd: false,
            resolving: false, resolution: r, indexAlbumID: nil)
        XCTAssertEqual(a, .notFound)
    }

    // MARK: index-album matcher

    func testIndexAlbumMatchesThroughEditionNoise() {
        let albums = [album(id: "alb_1", name: "Night Drive (Deluxe Edition)", artist: "Aria")]
        let hit = AppleMusicRecognition.indexAlbum(matching: ref(title: "Night Drive", artist: "Aria"), in: albums)
        XCTAssertEqual(hit?.id, "alb_1")
    }

    func testIndexAlbumWrongArtistMisses() {
        let albums = [album(id: "alb_1", name: "Night Drive", artist: "Someone Else")]
        XCTAssertNil(AppleMusicRecognition.indexAlbum(matching: ref(title: "Night Drive", artist: "Aria"), in: albums))
    }

    func testIndexAlbumArtistContainmentMatches() {
        let albums = [album(id: "alb_1", name: "Night Drive", artist: "Aria feat. Max")]
        let hit = AppleMusicRecognition.indexAlbum(matching: ref(title: "Night Drive", artist: "Aria"), in: albums)
        XCTAssertEqual(hit?.id, "alb_1")
    }

    // MARK: burn id

    func testBurnSongIDPrefersCatalogID() {
        XCTAssertEqual(AppleMusicRecognition.burnSongID(catalogSongID: "sng_42", storeID: "123"), "sng_42")
        XCTAssertEqual(AppleMusicRecognition.burnSongID(catalogSongID: nil, storeID: "123"), "amrec_123")
        XCTAssertEqual(AppleMusicRecognition.burnSongID(catalogSongID: "", storeID: "123"), "amrec_123")
        // Synthetic id is colon-free (a bare am:<id> would poison the S3 key / filename).
        XCTAssertFalse(AppleMusicRecognition.burnSongID(catalogSongID: nil, storeID: "123").contains(":"))
    }

    // MARK: index-song matcher

    func testIndexSongByNamespacedID() {
        let songs = [song(id: "am:123", name: "Neon", artist: "Aria")]
        XCTAssertEqual(AppleMusicRecognition.indexSong(storeID: "123", title: nil, artist: nil, in: songs)?.id, "am:123")
    }

    func testIndexSongByAppleMusicIdField() {
        let songs = [song(id: "sng_9", name: "Neon", artist: "Aria", appleMusicId: "123")]
        XCTAssertEqual(AppleMusicRecognition.indexSong(storeID: "123", title: nil, artist: nil, in: songs)?.id, "sng_9")
    }

    func testIndexSongByTitleArtistFallback() {
        let songs = [song(id: "sng_9", name: "Néon (Remastered)", artist: "Aria")]
        XCTAssertEqual(AppleMusicRecognition.indexSong(storeID: "555", title: "Neon", artist: "Aria", in: songs)?.id, "sng_9")
    }

    func testIndexSongMissesWhenAbsent() {
        let songs = [song(id: "sng_9", name: "Different", artist: "Nobody")]
        XCTAssertNil(AppleMusicRecognition.indexSong(storeID: "555", title: "Neon", artist: "Aria", in: songs))
    }
}
