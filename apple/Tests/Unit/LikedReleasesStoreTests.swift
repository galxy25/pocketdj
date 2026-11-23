import XCTest
@testable import PocketDJ

/// The unsynced metadata cache, and the album-lookup decoder that rebuilds it.
@MainActor
final class LikedReleasesStoreTests: XCTestCase {

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-liked-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testRoundTrip() {
        let url = tmp()
        let a = LikedReleasesStore(fileURL: url)
        a.upsert(LikedRelease(
            storeId: "10", artistId: 3, artistName: "A", title: "T", artworkUrl: "https://x/{w}x{h}.jpg",
            releaseAtMs: 5, kind: "album", trackCount: 9, explicit: true, likedAtMs: 7,
            attempt: LikeAddAttempt(atMs: 8, state: .failed, message: "m", writeToken: "w", recorded: true)))
        a.flush()
        let b = LikedReleasesStore(fileURL: url)
        XCTAssertEqual(b.releases["10"], a.releases["10"])
    }

    func testMalformedRowIsSkippedAndUnknownKeysIgnored() throws {
        let url = tmp()
        let json = """
        {"schemaVersion":1,"surprise":true,"releases":[
          {"storeId":"1","title":"Good","futureField":42},
          {"title":"no id"},
          {"storeId":"2","attempt":{"atMs":1,"state":"somethingNew"}}
        ]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let s = LikedReleasesStore(fileURL: url)
        XCTAssertEqual(s.releases["1"]?.title, "Good")
        XCTAssertNil(s.releases["no id"])
        // An unknown state drops the ATTEMPT only; the release survives.
        XCTAssertNotNil(s.releases["2"])
        XCTAssertNil(s.releases["2"]?.attempt)
    }

    func testAddingBecomesOfflineAfterReload() {
        let url = tmp()
        let a = LikedReleasesStore(fileURL: url)
        a.upsert(LikedRelease(storeId: "1", attempt: LikeAddAttempt(atMs: 1, state: .adding, message: nil,
                                                                     writeToken: nil, recorded: nil)))
        a.flush()
        let b = LikedReleasesStore(fileURL: url)
        XCTAssertEqual(b.releases["1"]?.attempt?.state, .offline)
    }

    func testUpsertKeepsAttemptAndLikeTimeWhenIncomingHasNone() {
        let s = LikedReleasesStore(fileURL: tmp())
        s.upsert(LikedRelease(storeId: "1", likedAtMs: 5,
                              attempt: LikeAddAttempt(atMs: 1, state: .failed, message: "x", writeToken: nil, recorded: false)))
        s.upsert(LikedRelease(storeId: "1", artistName: "Fresh"))
        XCTAssertEqual(s.releases["1"]?.artistName, "Fresh")
        XCTAssertEqual(s.releases["1"]?.likedAtMs, 5)
        XCTAssertEqual(s.releases["1"]?.attempt?.state, .failed)
    }

    func testPruneDropsRowsNoLongerAccepted() {
        let s = LikedReleasesStore(fileURL: tmp())
        s.upsert([LikedRelease(storeId: "1"), LikedRelease(storeId: "2")])
        s.prune(keepingAccepted: ["2"])
        XCTAssertEqual(Set(s.releases.keys), ["2"])
    }

    // MARK: album lookup decoder

    func testAlbumsCatalogDecodeCoversDatesKindsMissingRelationshipsAndTombstones() throws {
        let json = """
        {"data":[
          {"id":"100","attributes":{"name":"Full","artistName":"Ann","releaseDate":"2026-08-01",
             "artwork":{"url":"https://a/{w}x{h}bb.jpg"},"trackCount":12,"contentRating":"explicit"},
           "relationships":{"artists":{"data":[{"id":"555"}]}}},
          {"id":"101","attributes":{"name":"Year Only","artistName":"Bob","releaseDate":"2026","isSingle":true}},
          {"id":"102","attributes":{"name":"Comp","artistName":"Cy","isCompilation":true}}
        ]}
        """
        let resp = try JSONDecoder().decode(AlbumsCatalogResponse.self, from: Data(json.utf8))
        let out = resp.releases(requested: ["100", "101", "102", "999"], likedAtMs: { _ in 42 })
        let by = Dictionary(uniqueKeysWithValues: out.map { ($0.storeId, $0) })
        XCTAssertEqual(by["100"]?.artistId, 555)
        XCTAssertEqual(by["100"]?.title, "Full")
        XCTAssertEqual(by["100"]?.explicit, true)
        XCTAssertEqual(by["100"]?.trackCount, 12)
        XCTAssertEqual(by["100"]?.kind, "album")
        XCTAssertEqual(by["100"]?.releaseAtMs, ArtistsCatalogResponse.parseReleaseDate("2026-08-01"))
        XCTAssertNotNil(by["100"]?.releaseAtMs)
        XCTAssertNil(by["101"]?.releaseAtMs, "a bare year is not a release date")
        XCTAssertEqual(by["101"]?.kind, "single")
        XCTAssertNil(by["101"]?.artistId, "missing relationships decode to no artist id")
        XCTAssertEqual(by["102"]?.kind, "compilation")
        XCTAssertEqual(by["999"]?.tombstoned, true, "an id Apple didn't return is tombstoned")
        XCTAssertEqual(by["999"]?.likedAtMs, 42)
    }

    func testRequestShape() {
        let r = LikedReleaseHydration.request(ids: ["1", "2"])
        XCTAssertEqual(r?.url?.absoluteString, "https://api.music.apple.com/v1/catalog/us/albums?ids=1,2")
    }

    func testEntryInitRequiresReleaseId() {
        let e = ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: 0)
        XCTAssertNil(LikedRelease(entry: e, likedAtMs: 1))
    }
}
