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

    // ── OUT NOW vs COMING SOON ───────────────────────────────────────────────────────────────

    /// Apple returns pre-orders from `latest-release`, so future-dated releases are routine.
    /// They belong in the feed but must be labelled — an age-in-days wording would render a
    /// record that ships in three weeks as "released today".
    func testClassifySplitsOutNowFromComingSoon() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        XCTAssertEqual(ReleaseFeedPolicy.classify(releaseAtMs: now, nowMs: now), .outNow)
        XCTAssertEqual(ReleaseFeedPolicy.classify(releaseAtMs: now - day, nowMs: now), .outNow)
        XCTAssertEqual(ReleaseFeedPolicy.classify(releaseAtMs: now - 30 * day, nowMs: now), .outNow)
        XCTAssertEqual(ReleaseFeedPolicy.classify(releaseAtMs: now + day, nowMs: now), .comingSoon)
        // Past the window on the OUT NOW side, it leaves the feed entirely.
        XCTAssertNil(ReleaseFeedPolicy.classify(releaseAtMs: now - 31 * day, nowMs: now))
    }

    /// The 30-day window is a RECENCY filter and that reasoning does not run forwards: a
    /// pre-order 90 days out is still the artist's next release, and nothing newer can displace
    /// it. Bounding the future side would hide the freshest item in the feed.
    func testComingSoonIsNotBoundedByTheThirtyDayWindow() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        XCTAssertEqual(ReleaseFeedPolicy.classify(releaseAtMs: now + 90 * day, nowMs: now),
                       .comingSoon)
        XCTAssertTrue(ReleaseFeedPolicy.isWithinWindow(releaseAtMs: now + 90 * day, nowMs: now))
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
// MARK: - Ownership predicate (shared with AlbumPreviewView)
// ============================================================================

final class ReleaseOwnershipPredicateTests: XCTestCase {

    /// The release feed asks "does he own this ALBUM" through the SAME predicate the album
    /// screen uses for tracks — only the provisional-id prefix differs. A second predicate would
    /// start identical and drift the first time either was fixed.
    func testAlbumOwnershipUsesTheAlbumAdHocPrefix() {
        // The provisional id an earlier Discover/recognizer add synthesizes.
        XCTAssertTrue(AlbumOwnership.owns(storeID: "1000",
                                          catalogSongIds: ["amrec_album_1000"],
                                          catalogAppleMusicIds: [],
                                          rippedSongIds: [],
                                          adHocPrefix: "amrec_album_"))
        // A real indexed album claiming that Apple Music id (post-supersede).
        XCTAssertTrue(AlbumOwnership.owns(storeID: "1000",
                                          catalogSongIds: [],
                                          catalogAppleMusicIds: ["1000"],
                                          rippedSongIds: [],
                                          adHocPrefix: "amrec_album_"))
        XCTAssertFalse(AlbumOwnership.owns(storeID: "1000",
                                           catalogSongIds: [],
                                           catalogAppleMusicIds: [],
                                           rippedSongIds: [],
                                           adHocPrefix: "amrec_album_"))
        // The TRACK prefix must not match an album's provisional id, or every album would look
        // unowned and the feed would offer records he already has.
        XCTAssertFalse(AlbumOwnership.owns(storeID: "1000",
                                           catalogSongIds: ["amrec_album_1000"],
                                           catalogAppleMusicIds: [],
                                           rippedSongIds: []))
    }

    /// The default keeps every existing track call site behaving exactly as before.
    func testTrackOwnershipDefaultsToTheTrackPrefix() {
        XCTAssertTrue(AlbumOwnership.owns(storeID: "55",
                                          catalogSongIds: ["amrec_55"],
                                          catalogAppleMusicIds: [],
                                          rippedSongIds: []))
        XCTAssertTrue(AlbumOwnership.owns(storeID: "55",
                                          catalogSongIds: [],
                                          catalogAppleMusicIds: [],
                                          rippedSongIds: ["amrec_55"]))
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

    /// Thrown on EVERY call once set — "the network is simply down / the limiter is angry".
    var persistentError: Error?
    /// Thrown once each, from the front, before falling through to `persistentError`/`body` —
    /// for "it failed twice then recovered".
    var errorScript: [Error] = []

    init(canSync: Bool = true, body: Data = Data("{\"data\":[]}".utf8)) {
        self.canSync = canSync
        self.body = body
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        lock.lock()
        requests.append(request)
        let scripted = errorScript.isEmpty ? nil : errorScript.removeFirst()
        let persistent = persistentError
        let payload = body
        lock.unlock()
        if let scripted { throw scripted }
        if let persistent { throw persistent }
        return payload
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

/// A transport that OBSERVES how many requests are actually in flight at once, rather than taking
/// the constant's word for it.
///
/// `ReleaseFeedPolicy.maxConcurrentRequests` being 2 says nothing about whether the SERVICE honours
/// it — the cap used to be enforced per-drain, so two overlapping drains each ran their own pair
/// and the real fan-out was 4. Only a probe that counts concurrent `fetch` calls can catch that,
/// which is why this exists beside `StubReleaseTransport`.
final class ConcurrencyProbeTransport: ReleaseFeedTransport, @unchecked Sendable {
    var canSync = true
    /// How long each request occupies a slot. Long enough that overlapping drains genuinely
    /// overlap, short enough that the suite stays fast.
    var holdNanos: UInt64 = 40_000_000
    var error: Error?

    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var count = 0

    func fetch(_ request: URLRequest) async throws -> Data {
        lock.lock(); inFlight += 1; count += 1; peak = max(peak, inFlight); lock.unlock()
        try? await Task.sleep(nanoseconds: holdNanos)
        lock.lock(); inFlight -= 1; lock.unlock()
        if let error { throw error }
        return Data("{\"data\":[]}".utf8)
    }

    var peakInFlight: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
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
                               releaseId: "r1", releaseAtMs: now - 60 * day),
            ArtistReleaseEntry(artistId: 2, artistName: "Recent", checkedAtMs: now,
                               releaseId: "r2", releaseAtMs: now - 2 * day),
            ArtistReleaseEntry(artistId: 3, artistName: "Newest", checkedAtMs: now,
                               releaseId: "r3", releaseAtMs: now - 1 * day),
            ArtistReleaseEntry(artistId: 4, artistName: "NoDate", checkedAtMs: now,
                               releaseId: "r4"),
        ])
        let feed = svc.newReleases(nowMs: now)
        XCTAssertEqual(feed.map(\.artistId), [3, 2], "60-day-old and date-less entries excluded")
    }

    /// A release with no store id cannot be opened (there is nothing to push) and cannot be
    /// matched against the catalog, so it must not be offered — a row that does nothing when
    /// tapped, and might be something he already owns, is worse than no row.
    func testReleaseWithNoStoreIdIsNotOffered() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "NoId", checkedAtMs: now,
                               releaseId: nil, releaseName: "Ghost",
                               releaseAtMs: now - 86_400_000),
        ])
        XCTAssertTrue(svc.feed(nowMs: now).isEmpty)
    }

    /// OUT NOW reads newest-first ("what just landed"), but COMING SOON reads soonest-first —
    /// for something that has not happened yet, "next" is the useful ordering, not "furthest
    /// away". Sorting both the same way would bury the imminent release under the distant one.
    func testOutNowIsNewestFirstAndComingSoonIsSoonestFirst() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: now,
                               releaseId: "1", releaseAtMs: now - 10 * day),
            ArtistReleaseEntry(artistId: 2, artistName: "B", checkedAtMs: now,
                               releaseId: "2", releaseAtMs: now - 2 * day),
            ArtistReleaseEntry(artistId: 3, artistName: "C", checkedAtMs: now,
                               releaseId: "3", releaseAtMs: now + 40 * day),
            ArtistReleaseEntry(artistId: 4, artistName: "D", checkedAtMs: now,
                               releaseId: "4", releaseAtMs: now + 5 * day),
        ])
        XCTAssertEqual(svc.outNow(nowMs: now).map(\.entry.artistId), [2, 1])
        XCTAssertEqual(svc.comingSoon(nowMs: now).map(\.entry.artistId), [4, 3])
    }

    /// A pre-order dated weeks out used to render as "Today", because the wording only handled
    /// the past. The screen stating the opposite of the truth is worse than saying nothing.
    func testRelativeWordingDistinguishesFutureFromPast() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        XCTAssertEqual(NewReleasesView.relative(now, nowMs: now), "Today")
        XCTAssertEqual(NewReleasesView.relative(now - day, nowMs: now), "Yesterday")
        XCTAssertEqual(NewReleasesView.relative(now - 3 * day, nowMs: now), "3 days ago")
        XCTAssertEqual(NewReleasesView.relative(now + day, nowMs: now), "Tomorrow")
        XCTAssertEqual(NewReleasesView.relative(now + 21 * day, nowMs: now), "In 21 days")
    }

    // ── Ownership exclusion ──────────────────────────────────────────────────────────────────

    /// The point of the whole feature is "here is something NEW". An album already in the
    /// library is the one thing that definitionally is not, so it must not appear.
    func testAlreadyOwnedReleaseIsNotOfferedAsNew() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "Owned", checkedAtMs: now,
                               releaseId: "1000", releaseName: "Have It", releaseAtMs: now - day),
            ArtistReleaseEntry(artistId: 2, artistName: "New", checkedAtMs: now,
                               releaseId: "2000", releaseName: "Don't Have It",
                               releaseAtMs: now - 2 * day),
        ])
        svc.ownsRelease = { $0 == "1000" }
        XCTAssertEqual(svc.feed(nowMs: now).map(\.entry.artistId), [2])
    }

    /// An UNSET probe must mean "own nothing", not "own everything". A cold launch has no
    /// catalog yet, and the opposite default would silently empty the feed exactly when the
    /// user first opens it — an empty screen that looks like "no new releases".
    func testUnsetOwnershipProbeShowsEverythingRatherThanNothing() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: now,
                               releaseId: "1000", releaseAtMs: now - 86_400_000),
        ])
        XCTAssertNil(svc.ownsRelease)
        XCTAssertEqual(svc.feed(nowMs: now).count, 1)
    }

    /// The cold-launch window, and why it needs no cache invalidation to close.
    ///
    /// Before the catalog finishes loading the probe answers "not owned" for everything, so the
    /// New tile can briefly offer an album the owner already has. That is the RIGHT default (the
    /// opposite would empty the feed at exactly the moment he first opens it), and it is
    /// self-correcting because ownership is applied on READ, not stored on the entry: the moment
    /// the catalog is there the same cached entry filters out — with NO refetch and no network.
    /// Storing the exclusion at fetch time is what would make this window permanent.
    func testOwnershipIsAppliedOnReadSoTheCatalogLoadingFixesItWithNoRefetch() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        let now: Double = 1_700_000_000_000
        svc.seedForTesting([
            ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: now,
                               releaseId: "1000", releaseAtMs: now - 86_400_000),
        ])
        // Catalog not loaded yet: nothing reads as owned, so the row shows.
        svc.ownsRelease = { _ in false }
        XCTAssertEqual(svc.feed(nowMs: now).count, 1)
        let requestsBefore = stub.requestCount

        // Catalog arrives and now claims that album.
        svc.ownsRelease = { $0 == "1000" }
        XCTAssertEqual(svc.feed(nowMs: now).count, 0, "the cached entry filters out immediately")
        XCTAssertEqual(stub.requestCount, requestsBefore,
                       "and it costs no request — ownership is a read-time filter, not a stored field")
    }

    // ── Rate limiting ────────────────────────────────────────────────────────────────────────

    /// A 429 is retried with backoff rather than abandoned...
    func testRateLimitedRequestRetriesWithBackoff() async {
        let stub = StubReleaseTransport()
        stub.persistentError = ReleaseFeedTransportError.http(status: 429)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 5, "429 must be retried, not abandoned on first failure")
    }

    /// ...and a 429 that eventually clears produces the real answer, not an empty one.
    func testRateLimitedRequestSucceedsOnceTheLimiterClears() async {
        let body = """
        {"data":[{"id":"1","attributes":{"name":"A"},"views":{"latest-release":{"data":[
          {"id":"r1","attributes":{"name":"Rec","releaseDate":"2026-08-01"}}]}}}]}
        """
        let stub = StubReleaseTransport(body: Data(body.utf8))
        stub.errorScript = [ReleaseFeedTransportError.http(status: 429),
                            ReleaseFeedTransportError.http(status: 429)]
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 3, "two failures then success")
        XCTAssertEqual(svc.entries[1]?.releaseName, "Rec")
    }

    /// A 401/403/400 will fail identically however many times it is asked. Retrying it just
    /// spends the limiter's budget — and because a failed batch re-queues, it would do so on
    /// every single play.
    func testNonRetryableStatusFailsFastWithoutBurningRetries() async {
        let stub = StubReleaseTransport()
        stub.persistentError = ReleaseFeedTransportError.http(status: 401)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 1, "a revoked token must not be retried five times")
    }

    func testRetryabilityIsDecidedByStatusClass() {
        XCTAssertTrue(ReleaseFeedTransportError.http(status: 429).isRetryable)
        XCTAssertTrue(ReleaseFeedTransportError.http(status: 500).isRetryable)
        XCTAssertTrue(ReleaseFeedTransportError.http(status: 503).isRetryable)
        XCTAssertFalse(ReleaseFeedTransportError.http(status: 400).isRetryable)
        XCTAssertFalse(ReleaseFeedTransportError.http(status: 401).isRetryable)
        XCTAssertFalse(ReleaseFeedTransportError.http(status: 404).isRetryable)
        XCTAssertFalse(ReleaseFeedTransportError.unavailable.isRetryable)
    }

    // ── Failure must never poison the cache ──────────────────────────────────────────────────

    /// THE regression that matters most. A failed batch must NOT stamp its artists' TTL clocks:
    /// doing so would mark up to fifty artists "checked" off a request that never succeeded, and
    /// blind the feed to their releases for as long as fourteen days — silently, with nothing to
    /// retry against. The ids must go back on the queue instead.
    func testFailedBatchDoesNotStampTheClockAndRequeuesTheArtists() async {
        let stub = StubReleaseTransport()
        stub.persistentError = ReleaseFeedTransportError.http(status: 429)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        XCTAssertNil(svc.entries[1], "a failed check must not create a 'checked' entry")
        XCTAssertEqual(svc.pendingCountForTesting, 1, "the artist must go back on the queue")
        // And the very next play still finds it due, rather than 'fresh' for a fortnight.
        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(ReleaseFeedPolicy.isDue(lastCheckedAtMs: svc.entries[1]?.checkedAtMs,
                                              plays: 0, nowMs: now))
    }

    /// The retry must ride the NEXT play — any play — not only a play of an artist that is
    /// itself due. A queue made entirely of re-queued ids would otherwise stall until one of
    /// them happened to be played again, which for a once-a-year artist is indistinguishable
    /// from having lost it.
    func testRequeuedArtistsAreRetriedOnThePlayOfAnyArtist() async {
        let stub = StubReleaseTransport()
        stub.persistentError = ReleaseFeedTransportError.http(status: 503)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        XCTAssertEqual(svc.pendingCountForTesting, 1, "the failed id went back on the queue")

        // A DIFFERENT artist plays, and its entry is fresh — on its own it queues nothing.
        let now = Date().timeIntervalSince1970 * 1000
        svc.seedForTesting([ArtistReleaseEntry(artistId: 2, artistName: "B", checkedAtMs: now)])
        svc.noteArtistPlayed(artistId: 2, name: "B", nowMs: now)
        XCTAssertEqual(svc.pendingCountForTesting, 1, "the fresh artist must not be queued")

        // The limiter clears, and the retry carries the ORIGINAL artist through.
        stub.persistentError = nil
        await svc.drain()
        XCTAssertNotNil(svc.entries[1], "the re-queued artist must eventually get checked")
        XCTAssertEqual(svc.pendingCountForTesting, 0)
    }

    /// A 200 carrying an error envelope (or any body that isn't this endpoint's) decodes
    /// "successfully" into `data == nil`, because every field of the wire model is optional.
    /// Treating that as a good answer is the same poisoning path by a different route.
    func testResponseWithNoDataKeyIsTreatedAsFailureNotAsAnEmptyAnswer() async {
        let stub = StubReleaseTransport(body: Data("{\"errors\":[{\"status\":\"429\"}]}".utf8))
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 7, name: "A")
        await svc.drain()
        XCTAssertNil(svc.entries[7], "an error envelope must not stamp a TTL clock")
        XCTAssertEqual(svc.pendingCountForTesting, 1)
    }

    /// One batch failing must not let a SIBLING batch stamp its artists. The first batch to
    /// return used to walk the whole due set, so it marked artists belonging to requests that
    /// were still in flight — or that went on to fail.
    func testAFailedBatchIsNotStampedByASucceedingSibling() async {
        let stub = StubReleaseTransport()
        // Every request fails, so all 120 artists across all 3 batches must survive unstamped.
        stub.persistentError = ReleaseFeedTransportError.http(status: 503)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        for id in 1...120 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        await svc.drain()
        XCTAssertTrue(svc.entries.isEmpty, "no artist may be stamped when every batch failed")
        XCTAssertEqual(svc.pendingCountForTesting, 120, "all three batches must re-queue")
    }

    // ── Cold cache ───────────────────────────────────────────────────────────────────────────

    /// A first launch: no file, no entries, no network yet. Every reader must answer emptily
    /// rather than crash, spin, or nil-crash on the missing document.
    func testColdCacheReadsEmptyOnEveryAccessor() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        XCTAssertTrue(svc.entries.isEmpty)
        XCTAssertTrue(svc.feed().isEmpty)
        XCTAssertTrue(svc.outNow().isEmpty)
        XCTAssertTrue(svc.comingSoon().isEmpty)
        XCTAssertTrue(svc.newReleases().isEmpty)
        XCTAssertTrue(svc.similarArtistIds(for: [1, 2, 3]).isEmpty)
        XCTAssertFalse(svc.isFetching, "a cold cache must not look like a request in flight")
        XCTAssertNil(svc.lastError)
    }

    /// A cold cache survives a round trip through disk — the durable half of the same story.
    func testCacheRoundTripsThroughDisk() async {
        let url = tempURL()
        let body = """
        {"data":[{"id":"1","attributes":{"name":"A"},"views":{"latest-release":{"data":[
          {"id":"r1","attributes":{"name":"Saved","releaseDate":"2026-08-01"}}]}}}]}
        """
        let svc = ReleaseFeedService(transport: StubReleaseTransport(body: Data(body.utf8)),
                                     fileURL: url)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        let reopened = ReleaseFeedService(transport: nil, fileURL: url)
        XCTAssertEqual(reopened.entries[1]?.releaseName, "Saved")
    }

    // ── Concurrency: the cap is GLOBAL, not per-drain ────────────────────────────────────────

    /// Waits until the service is quiet — nothing in flight and nothing waiting on a re-armed
    /// drain — so a concurrency assertion can never read a peak that is still climbing.
    private func settle(_ svc: ReleaseFeedService, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !svc.isFetching && svc.pendingCountForTesting == 0 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// THE concurrency regression. `maxConcurrentRequests` is 2 because a 40-way fan-out at this
    /// endpoint produced 24 separate HTTP 429s — but the cap lived INSIDE one `drain()`, and
    /// `drain()` released its task handle on ENTRY. So any play landing while a drain was in
    /// flight armed a SECOND drain beside it, with its own budget of two: a measured peak of 4.
    ///
    /// The path is not exotic, it is the 429 path itself. A failed batch re-queues, the re-queue
    /// rides the next play, and a drain sleeping through five backoff attempts holds the window
    /// open for tens of seconds — so the fan-out doubles precisely when the limiter is already
    /// refusing, and nothing bounded how many drains could stack up.
    func testASecondDrainCannotRunBesideOneAlreadyInFlight() async {
        let probe = ConcurrencyProbeTransport()
        let svc = ReleaseFeedService(transport: probe, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        // 150 cold artists → 3 batches, so the drain is still working when the next play lands.
        for id in 1...150 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        let running = Task { await svc.drain() }
        try? await Task.sleep(nanoseconds: 20_000_000)          // let the first pair get in flight
        // Plays DURING the drain — each one used to arm another drain.
        for id in 500..<560 { svc.noteArtistPlayed(artistId: id, name: "B\(id)") }
        await running.value
        await settle(svc)

        XCTAssertEqual(probe.peakInFlight, ReleaseFeedPolicy.maxConcurrentRequests,
                       "the cap is global: never more than 2 requests in flight, across ALL drains")
    }

    /// The same guarantee against a DIRECT second call, not just the scheduled one — `drain()` is
    /// internal API and a future caller must not be able to double the fan-out by calling it.
    func testDirectlyCallingDrainTwiceDoesNotDoubleTheFanOut() async {
        let probe = ConcurrencyProbeTransport()
        let svc = ReleaseFeedService(transport: probe, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        for id in 1...150 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        let a = Task { await svc.drain() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for id in 500..<560 { svc.noteArtistPlayed(artistId: id, name: "B\(id)") }
        let b = Task { await svc.drain() }
        _ = await (a.value, b.value)
        await settle(svc)
        XCTAssertEqual(probe.peakInFlight, ReleaseFeedPolicy.maxConcurrentRequests)
    }

    /// The 429 storm, end to end: every request fails, every batch re-queues, and plays keep
    /// arriving through the backoff sleeps. This is the exact condition the cap exists for, so the
    /// cap must hold here specifically — not merely in the happy path.
    func testAFourTwoNineStormDoesNotEscalateTheFanOut() async {
        let probe = ConcurrencyProbeTransport()
        probe.error = ReleaseFeedTransportError.http(status: 429)
        let svc = ReleaseFeedService(transport: probe, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        for id in 1...150 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        let running = Task { await svc.drain() }
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            for id in 500..<560 { svc.noteArtistPlayed(artistId: id, name: "B\(id)") }
        }
        await running.value
        XCTAssertEqual(probe.peakInFlight, ReleaseFeedPolicy.maxConcurrentRequests,
                       "a limiter that is already refusing must not be hit by twice as many requests")
        XCTAssertTrue(svc.entries.isEmpty, "nothing succeeded, so nothing may be stamped")
    }

    /// The other half of a global cap: plays that arrive DURING a drain must not be stranded. The
    /// drain re-arms itself when it finishes cleanly, so they ride the very next batch instead of
    /// waiting for another play to happen along.
    func testPlaysArrivingDuringADrainAreStillFetched() async {
        let probe = ConcurrencyProbeTransport()
        let svc = ReleaseFeedService(transport: probe, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        for id in 1...60 { svc.noteArtistPlayed(artistId: id, name: "A\(id)") }
        let running = Task { await svc.drain() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        svc.noteArtistPlayed(artistId: 999, name: "Late")
        await running.value
        await settle(svc)
        XCTAssertEqual(svc.pendingCountForTesting, 0, "a play during a drain must not be stranded")
        XCTAssertNotNil(svc.entries[999], "and it must actually get checked")
    }

    /// …but a FAILING drain must not re-arm itself, or an outage becomes a spin loop against a
    /// limiter that is already unhappy. The queue rides the next play instead — the same lazy
    /// trigger the whole feature runs on.
    func testAFailedDrainDoesNotReArmItself() async {
        let probe = ConcurrencyProbeTransport()
        probe.error = ReleaseFeedTransportError.http(status: 503)
        let svc = ReleaseFeedService(transport: probe, fileURL: tempURL(), timeScale: 0.0001)
        svc.playsForArtist = { _ in 0 }
        svc.noteArtistPlayed(artistId: 1, name: "A")
        await svc.drain()
        let after = probe.requestCount
        XCTAssertEqual(svc.pendingCountForTesting, 1, "the failed id is queued, waiting on a play")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(probe.requestCount, after, "a failed drain must NOT re-arm and spin")
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
