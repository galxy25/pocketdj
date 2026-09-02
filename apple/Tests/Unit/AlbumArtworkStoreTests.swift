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
        XCTAssertEqual(calls, 1)          // a miss is cached → not retried inside the TTL
    }

    /// A miss is a TTL, not a verdict: "no art exists" and "the network blipped" are
    /// indistinguishable at this seam, and a drive that starts in a garage with no signal must
    /// not stay artless for the whole session (the CarPlay rows + Now Playing card ride this).
    func testMissRetriesAfterTTL() async {
        var calls = 0
        let store = AlbumArtworkStore(ready: { true },
                                      resolve: { _ in
                                          calls += 1
                                          return calls >= 2 ? URL(string: "https://late.jpg") : nil
                                      })
        store.missTTL = 0                 // expire immediately — the seam exists for this test
        let first = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        XCTAssertNil(first)
        let second = await store.artworkURL(forAlbum: "a", candidates: [song("am:1")])
        XCTAssertEqual(second, URL(string: "https://late.jpg"), "the transient miss healed")
        XCTAssertEqual(calls, 2)
    }

    /// The car-connect stampede guard: N rows resolving at once must trickle (≤3 concurrent),
    /// and the Now Playing card's `priority` resolve jumps the wait queue instead of landing
    /// minutes behind a few hundred browse rows — the head-of-line regression a strict
    /// one-at-a-time chain introduced and this gate replaced.
    func testResolveConcurrencyBoundedAndPriorityJumpsTheQueue() async {
        var concurrent = 0, maxConcurrent = 0
        var startOrder: [String] = []
        let store = AlbumArtworkStore(ready: { true },
                                      resolve: { s in
                                          concurrent += 1
                                          maxConcurrent = max(maxConcurrent, concurrent)
                                          startOrder.append(s.id)
                                          try? await Task.sleep(nanoseconds: 100_000_000)
                                          concurrent -= 1
                                          return URL(string: "https://\(s.id).jpg")
                                      })
        // Six ordinary resolves: three take slots, three queue.
        let lows = (1...6).map { i in
            Task { await store.artworkURL(forAlbum: "low\(i)", candidates: [self.song("am:low\(i)")]) }
        }
        // Wait until the first three actually hold slots, so the priority call genuinely
        // queues. Bounded so a broken gate FAILS loudly instead of hanging the suite.
        var spins = 0
        while startOrder.count < 3, spins < 500_000 { await Task.yield(); spins += 1 }
        guard startOrder.count >= 3 else { return XCTFail("gate never admitted 3 resolves") }
        let pri = Task { await store.artworkURL(forAlbum: "pri", candidates: [self.song("am:pri")],
                                                priority: true) }
        for t in lows { _ = await t.value }
        _ = await pri.value
        XCTAssertLessThanOrEqual(maxConcurrent, 3, "the gate held the stampede to 3")
        guard let priAt = startOrder.firstIndex(of: "am:pri"),
              let lastLowAt = startOrder.lastIndex(where: { $0.hasPrefix("am:low") }) else {
            return XCTFail("expected priority + low resolves to have started: \(startOrder)")
        }
        XCTAssertLessThan(priAt, lastLowAt, "the priority resolve started before the queue drained")
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
