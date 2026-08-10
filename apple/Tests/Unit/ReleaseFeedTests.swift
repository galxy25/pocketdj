import XCTest
@testable import PocketDJ

/// The release feed's PURE half: the per-artist TTL policy, the 30-day window, the artist-name
/// join key, and the catalog response parsing. No MusicKit, no network — the transport is a stub,
/// so these are deterministic and run on every platform.
final class ReleaseFeedPolicyTests: XCTestCase {

    // ── The invariant the whole design rests on ─────────────────────────────────────────────

    /// TTL_max MUST stay strictly under the feed window. If it ever reaches 30, an artist can
    /// release on day 0, go unplayed, be played on day 29 with a still-"fresh" cold entry, and
    /// that release NEVER surfaces — the check does not fire, and by the time it does the release
    /// has aged out of the window. This test is the tripwire for that regression.
    func testReleaseTTLIsAlwaysStrictlyInsideTheFeedWindow() {
        XCTAssertLessThan(ReleaseFeedPolicy.maxReleaseTTLDays, ReleaseFeedPolicy.windowDays,
                          "TTL ceiling must stay strictly below the 30-day window")
        // Sweep the whole plausible play-count range — no input may produce a TTL at or above
        // the window, whatever the popularity curve does.
        for plays in [0, 1, 2, 5, 10, 50, 100, 500, 1000, 2860, 10_000, 1_000_000] {
            let ttl = ReleaseFeedPolicy.releaseTTLDays(plays: plays)
            XCTAssertLessThan(ttl, ReleaseFeedPolicy.windowDays, "plays=\(plays) produced TTL \(ttl)")
            XCTAssertGreaterThanOrEqual(ttl, ReleaseFeedPolicy.minReleaseTTLDays)
            XCTAssertLessThanOrEqual(ttl, ReleaseFeedPolicy.maxReleaseTTLDays)
        }
    }

    /// A never-played artist gets the coldest TTL; the owner's most-played gets the floor.
    func testTTLDecaysFromColdCeilingToHotFloor() {
        XCTAssertEqual(ReleaseFeedPolicy.releaseTTLDays(plays: 0), 14, accuracy: 0.001)
        XCTAssertEqual(ReleaseFeedPolicy.releaseTTLDays(plays: 2860), 2, accuracy: 0.001)
        // Monotonically non-increasing in play count.
        var last = Double.infinity
        for plays in stride(from: 0, through: 3000, by: 50) {
            let ttl = ReleaseFeedPolicy.releaseTTLDays(plays: plays)
            XCTAssertLessThanOrEqual(ttl, last + 0.0001, "TTL rose at plays=\(plays)")
            last = ttl
        }
    }

    func testPopularityIsNormalizedAndSaturates() {
        XCTAssertEqual(ReleaseFeedPolicy.popularity(plays: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ReleaseFeedPolicy.popularity(plays: 2860), 1, accuracy: 0.0001)
        // Above the reference it saturates rather than exceeding 1 (which would push the TTL
        // below the floor).
        XCTAssertEqual(ReleaseFeedPolicy.popularity(plays: 100_000), 1, accuracy: 0.0001)
    }

    /// The similar-artists TTL is a staleness LABEL riding the same request — it must never be
    /// shorter than the release TTL, or it would imply a fetch of its own.
    func testSimilarTTLIsAlwaysLongerThanReleaseTTLAndClamped() {
        for plays in [0, 1, 100, 2860, 50_000] {
            let rel = ReleaseFeedPolicy.releaseTTLDays(plays: plays)
            let sim = ReleaseFeedPolicy.similarTTLDays(plays: plays)
            XCTAssertGreaterThan(sim, rel)
            XCTAssertGreaterThanOrEqual(sim, ReleaseFeedPolicy.minSimilarTTLDays)
            XCTAssertLessThanOrEqual(sim, ReleaseFeedPolicy.maxSimilarTTLDays)
        }
    }

    func testIsDueFiresOnColdEntryAndAfterTTLElapses() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        // Never checked → always due.
        XCTAssertTrue(ReleaseFeedPolicy.isDue(lastCheckedAtMs: nil, plays: 500, nowMs: now))
        // A hot artist (TTL 2d): 1 day old is fresh, 3 days old is due.
        let hotTTL = ReleaseFeedPolicy.releaseTTLDays(plays: 2860)
        XCTAssertEqual(hotTTL, 2, accuracy: 0.001)
        XCTAssertFalse(ReleaseFeedPolicy.isDue(lastCheckedAtMs: now - day, plays: 2860, nowMs: now))
        XCTAssertTrue(ReleaseFeedPolicy.isDue(lastCheckedAtMs: now - 3 * day, plays: 2860, nowMs: now))
        // A cold artist (TTL 14d): 10 days old is still fresh.
        XCTAssertFalse(ReleaseFeedPolicy.isDue(lastCheckedAtMs: now - 10 * day, plays: 0, nowMs: now))
        XCTAssertTrue(ReleaseFeedPolicy.isDue(lastCheckedAtMs: now - 15 * day, plays: 0, nowMs: now))
    }

    func testWindowAcceptsRecentAndFutureDatedButNotOld() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        XCTAssertTrue(ReleaseFeedPolicy.isWithinWindow(releaseAtMs: now - 29 * day, nowMs: now))
        XCTAssertTrue(ReleaseFeedPolicy.isWithinWindow(releaseAtMs: now, nowMs: now))
        // Apple returns future-dated pre-releases; those are the newest thing there is.
        XCTAssertTrue(ReleaseFeedPolicy.isWithinWindow(releaseAtMs: now + 7 * day, nowMs: now))
        XCTAssertFalse(ReleaseFeedPolicy.isWithinWindow(releaseAtMs: now - 31 * day, nowMs: now))
    }

    /// 50 is a measured hard cap (100 ids returns HTTP 400), not a style choice.
    func testBatchSizeAndConcurrencyStayWithinMeasuredLimits() {
        XCTAssertLessThanOrEqual(ReleaseFeedPolicy.idsPerRequest, 50)
        XCTAssertLessThanOrEqual(ReleaseFeedPolicy.maxConcurrentRequests, 2,
                                 "40-way fan-out produced 24x HTTP 429 — keep this at 2")
    }
}

// ============================================================================
// MARK: - Artist join key
// ============================================================================

final class IndexArtistJoinTests: XCTestCase {

    /// The app's normalization must match the script's byte for byte, or the join silently
    /// misses and the feed just looks empty.
    func testNormalizeMatchesTheScriptsRules() {
        XCTAssertEqual(IndexArtist.normalize("Drake"), "drake")
        XCTAssertEqual(IndexArtist.normalize("  Drake  "), "drake")
        XCTAssertEqual(IndexArtist.normalize("BANKS"), "banks")
        XCTAssertEqual(IndexArtist.normalize("Chaos In The CBD"), "chaos in the cbd")
        // Runs of whitespace collapse to one space (the script's \s+ → " ").
        XCTAssertEqual(IndexArtist.normalize("A   Tribe\tCalled\nQuest"), "a tribe called quest")
    }

    /// The case variants measured in the real index ("BANKS"/"Banks", "USHER"/"Usher") must land
    /// on ONE key — that is the whole reason the key is normalized rather than raw.
    func testCaseVariantsCollapseToOneKey() {
        XCTAssertEqual(IndexArtist.normalize("BANKS"), IndexArtist.normalize("Banks"))
        XCTAssertEqual(IndexArtist.normalize("USHER"), IndexArtist.normalize("Usher"))
    }
}

// ============================================================================
// MARK: - Response parsing
// ============================================================================

final class ReleaseFeedParsingTests: XCTestCase {

    /// A bare-year `releaseDate` must NOT be coerced into a timestamp: "2026" parsed as
    /// 2026-01-01 would make every January release look months stale and every other release
    /// look absent. It decodes to nil and the entry simply carries no date.
    func testBareYearReleaseDateDecodesToNil() {
        XCTAssertNil(ArtistsCatalogResponse.parseReleaseDate("2026"))
        XCTAssertNil(ArtistsCatalogResponse.parseReleaseDate(nil))
        XCTAssertNil(ArtistsCatalogResponse.parseReleaseDate(""))
        XCTAssertNotNil(ArtistsCatalogResponse.parseReleaseDate("2026-08-01"))
    }

    func testFullReleaseDateParsesAsUTC() throws {
        let ms = try XCTUnwrap(ArtistsCatalogResponse.parseReleaseDate("2026-08-01"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day],
                                       from: Date(timeIntervalSince1970: ms / 1000))
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 1)
    }

    /// A sparse artist — no releases, no similar artists — must not throw away the whole batch.
    /// This is why every nested container in the wire model is optional.
    func testSparseArtistDoesNotDiscardTheBatch() throws {
        let json = """
        {"data":[
          {"id":"271256","attributes":{"name":"Drake"},
           "views":{"latest-release":{"data":[{"id":"999","attributes":{
              "name":"New Thing","releaseDate":"2026-08-01","trackCount":12,
              "contentRating":"explicit","artwork":{"url":"https://x/{w}x{h}.jpg"}}}]},
             "similar-artists":{"data":[{"id":"159260351","attributes":{"name":"Taylor Swift"}}]}}},
          {"id":"5183365","attributes":{"name":"Marlene"},"views":{}},
          {"id":"465031","attributes":{"name":"Kylie Minogue"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(ArtistsCatalogResponse.self,
                                               from: Data(json.utf8))
        let entries = decoded.entries(checkedAtMs: 1_700_000_000_000)
        XCTAssertEqual(entries.count, 3, "a sparse artist must not drop its siblings")

        let drake = try XCTUnwrap(entries.first { $0.artistId == 271256 })
        XCTAssertEqual(drake.releaseName, "New Thing")
        XCTAssertEqual(drake.trackCount, 12)
        XCTAssertEqual(drake.explicit, true, "contentRating is returned UNFILTERED on this endpoint")
        XCTAssertEqual(drake.similarArtistIds, [159260351])
        XCTAssertNotNil(drake.releaseAtMs)

        // The sparse ones still produce entries so their TTL clock gets stamped — otherwise an
        // artist with no releases is re-requested on every single play, forever.
        let marlene = try XCTUnwrap(entries.first { $0.artistId == 5183365 })
        XCTAssertNil(marlene.releaseAtMs)
        XCTAssertNil(marlene.similarArtistIds)
    }

    func testSingleAndCompilationKindsAreDistinguished() throws {
        let json = """
        {"data":[
          {"id":"1","attributes":{"name":"A"},"views":{"latest-release":{"data":[
            {"id":"s1","attributes":{"name":"S","releaseDate":"2026-08-01","isSingle":true}}]}}},
          {"id":"2","attributes":{"name":"B"},"views":{"latest-release":{"data":[
            {"id":"c1","attributes":{"name":"C","releaseDate":"2026-08-01","isCompilation":true}}]}}},
          {"id":"3","attributes":{"name":"C"},"views":{"latest-release":{"data":[
            {"id":"a1","attributes":{"name":"A","releaseDate":"2026-08-01"}}]}}}
        ]}
        """
        let entries = try JSONDecoder().decode(ArtistsCatalogResponse.self, from: Data(json.utf8))
            .entries(checkedAtMs: 0)
        XCTAssertEqual(entries.first { $0.artistId == 1 }?.releaseKind, "single")
        XCTAssertEqual(entries.first { $0.artistId == 2 }?.releaseKind, "compilation")
        XCTAssertEqual(entries.first { $0.artistId == 3 }?.releaseKind, "album")
    }
}

// ============================================================================
// MARK: - Service behaviour (stub transport)
// ============================================================================

/// Records every request and replays a canned body. `@unchecked Sendable` because the recorder is
/// a reference the test reads after the awaits have completed.
final class StubReleaseTransport: ReleaseFeedTransport, @unchecked Sendable {
    var canSync: Bool
    var body: Data
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    init(canSync: Bool = true, body: Data = Data("{\"data\":[]}".utf8)) {
        self.canSync = canSync
        self.body = body
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        lock.lock(); requests.append(request); lock.unlock()
        return body
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

@MainActor
final class ReleaseFeedServiceTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("release-feed-\(UUID().uuidString).json")
    }

    /// The whole cost model depends on this: a play must not fetch when the entry is fresh.
    func testFreshEntryDoesNotEnqueueAFetch() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        let now = Date().timeIntervalSince1970 * 1000
        svc.playsForArtist = { _ in 2860 }                       // hot → 2-day TTL
        svc.seedForTesting([ArtistReleaseEntry(artistId: 271256, artistName: "Drake",
                                               checkedAtMs: now - 3_600_000)])  // 1h old
        svc.noteArtistPlayed(artistId: 271256, name: "Drake", nowMs: now)
        XCTAssertEqual(svc.pendingCountForTesting, 0, "a fresh entry must not queue a fetch")
    }

    func testColdEntryEnqueuesAndDrainsInOneBatchedRequest() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        svc.playsForArtist = { _ in 10 }
        // Three different artists, never checked.
        svc.noteArtistPlayed(artistId: 1, name: "A")
        svc.noteArtistPlayed(artistId: 2, name: "B")
        svc.noteArtistPlayed(artistId: 3, name: "C")
        XCTAssertEqual(svc.pendingCountForTesting, 3)
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 1, "three artists must ride ONE batched request")
        let url = try? XCTUnwrap(stub.requests.first?.url?.absoluteString)
        XCTAssertTrue(url?.contains("views=latest-release,similar-artists") == true)
        XCTAssertTrue(url?.contains("/catalog/us/artists") == true)
    }

    /// Repeated plays of the same artist coalesce — a shuffle through one album must not queue
    /// the artist a dozen times.
    func testRepeatedPlaysOfOneArtistCoalesce() {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        svc.playsForArtist = { _ in 0 }
        for _ in 0..<12 { svc.noteArtistPlayed(artistId: 271256, name: "Drake") }
        XCTAssertEqual(svc.pendingCountForTesting, 1)
    }

    /// More than 50 artists must split into 50-id requests — 100 ids returns HTTP 400.
    func testMoreThanFiftyArtistsSplitIntoBatchesOfFifty() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        svc.playsForArtist = { _ in 0 }
        for id in 1...120 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 3, "120 artists → 50 + 50 + 20")
        for req in stub.requests {
            let ids = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ids" }?.value ?? ""
            XCTAssertLessThanOrEqual(ids.split(separator: ",").count, 50)
        }
    }

    /// The degradation seam: with no transport (a platform without MusicKit, or Apple Music off)
    /// the service still works as a cache reader and never queues network.
    func testNoTransportDegradesInsteadOfFailing() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        XCTAssertFalse(svc.canSync)
        svc.noteArtistPlayed(artistId: 1, name: "A")
        XCTAssertEqual(svc.pendingCountForTesting, 0)
        // Cached entries still read back — the tile shows stale data rather than vanishing.
        let now = Date().timeIntervalSince1970 * 1000
        svc.seedForTesting([ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: now,
                                               releaseId: "r", releaseName: "R",
                                               releaseAtMs: now - 86_400_000)])
        XCTAssertEqual(svc.newReleases(nowMs: now).count, 1)
    }

    /// An artist Apple returns nothing for still gets its clock stamped, or it would be
    /// re-requested on every play forever.
    func testArtistWithNoReleaseStillGetsItsClockStamped() async {
        let stub = StubReleaseTransport(body: Data("{\"data\":[]}".utf8))
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 42, name: "Nobody")
        await svc.drain()
        XCTAssertNotNil(svc.entries[42], "a no-release artist must still be cached")
        let now = Date().timeIntervalSince1970 * 1000
        svc.noteArtistPlayed(artistId: 42, name: "Nobody", nowMs: now)
        XCTAssertEqual(svc.pendingCountForTesting, 0, "and must not immediately re-queue")
    }

    /// `newReleases` is the render path — it must filter by the window and sort newest-first
    /// without touching the network.
    func testNewReleasesFiltersWindowAndSortsNewestFirst() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "Old", checkedAtMs: now,
                               releaseAtMs: now - 60 * day),
            ArtistReleaseEntry(artistId: 2, artistName: "Recent", checkedAtMs: now,
                               releaseAtMs: now - 2 * day),
            ArtistReleaseEntry(artistId: 3, artistName: "Newest", checkedAtMs: now,
                               releaseAtMs: now - 1 * day),
            ArtistReleaseEntry(artistId: 4, artistName: "NoDate", checkedAtMs: now),
        ])
        let feed = svc.newReleases(nowMs: now)
        XCTAssertEqual(feed.map(\.artistId), [3, 2], "60-day-old and date-less entries excluded")
    }

    func testSimilarArtistIdsDedupeAndExcludeTheSeeds() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: 0,
                               similarArtistIds: [2, 3, 4]),
            ArtistReleaseEntry(artistId: 2, artistName: "B", checkedAtMs: 0,
                               similarArtistIds: [3, 5]),
        ])
        let similar = svc.similarArtistIds(for: [1, 2])
        XCTAssertEqual(similar, [3, 4, 5], "seeds excluded, duplicates collapsed, order stable")
    }
}
