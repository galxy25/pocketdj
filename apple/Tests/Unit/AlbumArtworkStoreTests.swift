import XCTest
@testable import PocketDJ

/// The lazy streaming-cover-art cache: resolution, per-album memoization (hit + miss),
/// in-flight de-dupe, and the not-ready (retry-later) gate. The MusicKit provider is
/// stubbed by an injected resolver, so these run offline + deterministically.
@MainActor
final class AlbumArtworkStoreTests: XCTestCase {
    private func song(_ id: String) -> IndexSong { IndexSong.minimal(id: id, name: "X", artist: "Y") }

    func testResolvesViaCandidateAndMemoizesHit() async {
        var calls = 0
        let store = AlbumArtworkStore(ready: { true },
                                      resolve: { _ in calls += 1; return URL(string: "https://art/\(calls).jpg") })
        let u1 = await store.artworkURL(forAlbum: "alb_1", candidates: [song("am:1")])
        let u2 = await store.artworkURL(forAlbum: "alb_1", candidates: [song("am:1")])
        XCTAssertEqual(u1, URL(string: "https://art/1.jpg"))
        XCTAssertEqual(u1, u2)            // memoized → same URL both times
        XCTAssertEqual(calls, 1)          // resolved exactly once
    }

    func testTriesCandidatesInOrderUntilOneResolves() async {
        let store = AlbumArtworkStore(ready: { true },
                                      resolve: { s in s.id == "am:2" ? URL(string: "https://art.jpg") : nil })
        let url = await store.artworkURL(forAlbum: "a", candidates: [song("am:1"), song("am:2")])
        XCTAssertEqual(url, URL(string: "https://art.jpg"))   // first candidate missed, second won
    }

    func testMissIsMemoizedNoRefetch() async {
        var calls = 0
        let store = AlbumArtworkStore(ready: { true }, resolve: { _ in calls += 1; return nil })
        _ = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        _ = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        XCTAssertEqual(calls, 1)          // a miss is cached → never retried
    }

    func testNotReadyReturnsNilThenResolvesOnceReady() async {
        var ready = false
        var calls = 0
        let store = AlbumArtworkStore(ready: { ready },
                                      resolve: { _ in calls += 1; return URL(string: "https://a.jpg") })
        let first = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        XCTAssertNil(first)               // provider not ready → no attempt, NOT a permanent miss
        XCTAssertEqual(calls, 0)
        ready = true
        let second = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        XCTAssertEqual(second, URL(string: "https://a.jpg"))   // retried once ready
        XCTAssertEqual(calls, 1)
    }

    func testNoCandidatesReturnsNil() async {
        let store = AlbumArtworkStore(ready: { true }, resolve: { _ in URL(string: "https://a.jpg") })
        let url = await store.artworkURL(forAlbum: "a", candidates: [])
        XCTAssertNil(url)
    }

    func testHasCatalogID() {
        XCTAssertTrue(AlbumArtworkStore.hasCatalogID(song("am:123")))     // namespaced streaming id
        XCTAssertFalse(AlbumArtworkStore.hasCatalogID(song("sng_1")))     // local id, no appleMusicId
    }
}
