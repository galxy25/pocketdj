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
        svc.ownsRelease = { $0.storeId == "1000" }
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
        svc.ownsRelease = { $0.storeId == "1000" }
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

    // ========================================================================
    // MARK: - "Check for new releases" — the manual pull behind New's ⋯
    // ========================================================================

    /// A fresh cache, so every entry is INSIDE its TTL. This is the case that decides whether the
    /// menu item is a real control or a decoy.
    private func freshCache(_ svc: ReleaseFeedService) {
        let now = Date().timeIntervalSince1970 * 1000
        svc.playsForArtist = { _ in 2860 }                    // hot ⇒ the shortest TTL there is
        svc.seedForTesting((1...3).map {
            ArtistReleaseEntry(artistId: $0, artistName: "A\($0)", checkedAtMs: now - 3_600_000)
        })
    }

    /// IT MUST ACTUALLY DO SOMETHING. `noteArtistPlayed` is TTL-gated and correctly enqueues
    /// nothing for a fresh entry — so a "check now" built on the same gate would silently no-op in
    /// the commonest case, which is a dead control wearing a live one's clothes. The recheck
    /// therefore ignores TTL and re-queues every known artist.
    func testRecheckReQueuesEveryKnownArtistEvenWhenNothingIsDue() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        freshCache(svc)
        // The lazy trigger's own answer for this cache, for contrast: nothing due, nothing queued.
        svc.noteArtistPlayed(artistId: 1, name: "A1")
        XCTAssertEqual(svc.pendingCountForTesting, 0, "TTL-fresh ⇒ a play queues nothing")

        svc.recheckKnownArtists()
        XCTAssertEqual(svc.pendingCountForTesting, 3, "…and the manual re-check queues all of them")
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 1, "one batched request, exactly like every other drain")
    }

    /// The ⋯ item disables rather than disappears — a control that comes and goes with the data is
    /// what this whole round is removing. So `canRecheck` has to be honest about all three of its
    /// off-states.
    func testCanRecheckIsOffOnlyWhenARecheckCouldNotDoAnything() {
        let cold = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        XCTAssertFalse(cold.canRecheck, "an empty cache has no known artists to re-ask about")

        let live = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        freshCache(live)
        XCTAssertTrue(live.canRecheck, "a populated cache ⇒ a real re-ask, TTL notwithstanding")

        let noMusic = ReleaseFeedService(transport: nil, fileURL: tempURL())
        freshCache(noMusic)
        XCTAssertFalse(noMusic.canRecheck, "Apple Music off ⇒ there is nothing to ask")
    }

    func testRecheckWithoutAppleMusicQueuesNothing() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        freshCache(svc)
        svc.recheckKnownArtists()
        XCTAssertEqual(svc.pendingCountForTesting, 0, "nothing done, and nothing pretended")
    }
}

// ============================================================================
// MARK: - Ownership under EVERY identity a release carries
// ============================================================================

/// **THE OWNER'S OWN BUG REPORT, AS FIXTURES.** Verbatim: *"either version dups or no already
/// owned suggestions aren't working because for me it shows in New: Who Coppin by Larry June,
/// Whatchu Bringing? by Dinner Party, other albums in OUT NOW that are already in my collection,
/// and albums that I have PRE-ADDED to my collection in UPCOMING — Pop Star by Victoria Monet,
/// Don't Look Down by Rod Wave etc."*
///
/// ── THE SCOPE CORRECTION THESE TESTS ENCODE ──────────────────────────────────────────────────
/// Neither named suspect was the defect. Feature 3 is scoped to COLLECTION SUGGESTION tiles and
/// never runs on this feed; feature 6 answers *"is this a DIFFERENT VERSION"*, and every one of
/// these rows is the SAME version — same artist, same title, same (empty) version signature — so
/// it correctly and uselessly answers no. `testFeature6AloneCatchesNoneOfThemAndIsRightNotTo`
/// pins that down. The defect was in NEW's own ownership filter, which compared one Apple Music
/// ALBUM store id by string equality and had no other route.
///
/// ── THE IDENTITIES ARE THE REAL ONES, FROM HIS INDEX ─────────────────────────────────────────
/// Every album row below was read out of `public/apple-music-index.json`, ids and all, because
/// the shapes ARE the bug: *Who Coppin* claims a store id that is not the one the feed returns
/// (Apple ships three for that record), and the pre-orders — written into Library.xml with
/// Apple's `Track N` placeholders, which the indexer's iTunes resolver cannot match — carry NO
/// store id at all, on the album or on any song. *Whatchu Bringing?* is in the index on no row
/// whatsoever: on release day it exists only in the live Apple Music library source, whose
/// `AlbumEntry` has no `appleMusicId` field, so it is modelled here exactly that way.
@MainActor
final class ReleaseFeedOwnershipIdentityTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-relown-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func service(_ entries: [ArtistReleaseEntry]) -> ReleaseFeedService {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        svc.seedForTesting(entries)
        return svc
    }

    private func library() async -> AppModel {
        let app = AppModel(loader: OwnerLibraryLoader())
        await app.loadIfNeeded()
        return app
    }

    private static let now: Double = 1_754_800_000_000   // the week he reported it
    private static let day: Double = 86_400_000

    // ── (a) OUT NOW: albums he already has ───────────────────────────────────────────────────

    /// Larry June's *Who Coppin* is in his library under store id `6791849225`. Apple's
    /// `latest-release` view returns `6786105209` for the SAME 16-track record (it also ships
    /// `6788912749`, the clean edition). The old filter was literally
    /// `"6786105209" != "6791849225"` ⇒ "not owned" ⇒ the row he complained about.
    func testAnAlbumHeOwnsUnderADifferentAppleStoreIdIsNotOfferedAsOutNow() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6786105209",
                               releaseName: "Who Coppin", releaseAtMs: Self.now - 3 * Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 16),
        ])
        // The id route on its own — the whole of the old filter — still cannot see it.
        XCTAssertNil(app.albumId(forAppleMusicId: "6786105209"),
                     "the feed's id is not the one his catalog claims; that is the bug")

        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty,
                      "an album he owns must not appear in Out Now under ANY identity")
        withExtendedLifetime(app) {}
    }

    /// Dinner Party's *Whatchu Bringing?* dropped the morning he reported it, so it is in no
    /// catalog snapshot — the only source that knows it is the live Apple Music library, and that
    /// source emits albums with no `appleMusicId` whatsoever. There is no id to compare; the only
    /// identity the two sides share is artist + title.
    func testAnAlbumKnownOnlyToTheAppleMusicLibrarySourceIsNotOfferedAsOutNow() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 1_500_000_001, artistName: "Dinner Party",
                               checkedAtMs: Self.now, releaseId: "6786482410",
                               releaseName: "Whatchu Bringing?", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 9),
        ])
        XCTAssertNil(app.albumId(forAppleMusicId: "6786482410"), "no id exists on the owned side")
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    // ── (b) COMING SOON: pre-orders he has already added ─────────────────────────────────────

    /// The pre-orders he named (he attributed Tinashe's *Popstar* to Victoria Monét — both are in
    /// his library, and both were showing, so both are fixtures). A pre-order is not released, so
    /// its tracks are Apple's `Track N` placeholders, so the indexer resolves no store id for the
    /// album OR for any song on it: the lookup key the old filter needed cannot exist.
    func testPreOrdersHeHasAlreadyAddedAreNotOfferedInComingSoon() async {
        let app = await library()
        let cases: [(Int, String, String, String)] = [
            (1_400_000_001, "Rod Wave", "6781873059", "Don't Look Down"),
            (1_300_000_001, "Victoria Monét", "6791645195", "Frequency Of Love"),
            // Reported as "Pop Star"; Library.xml spells it "Popstar" — one record, two of
            // Apple's own spellings. See `RecVersionIdentity.spacelessKey`.
            (1_200_000_001, "Tinashe", "6790000101", "Pop Star"),
        ]
        for (artistId, artist, releaseId, title) in cases {
            // The OLD filter's only route, proven dead for each one: the pre-order's tracks are
            // placeholders, so nothing on his side ever resolved a store id to compare against.
            XCTAssertNil(app.albumId(forAppleMusicId: releaseId),
                         "\(artist): an id probe cannot see a pre-order — that is the bug")
            let svc = service([
                ArtistReleaseEntry(artistId: artistId, artistName: artist, checkedAtMs: Self.now,
                                   releaseId: releaseId, releaseName: title,
                                   releaseAtMs: Self.now + 21 * Self.day,
                                   releaseArtworkUrl: nil, releaseKind: "album", trackCount: 22),
            ])
            svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
            XCTAssertTrue(svc.comingSoon(nowMs: Self.now).isEmpty,
                          "\(artist) — \(title) is already pre-added and must not be offered")
        }
        withExtendedLifetime(app) {}
    }

    /// Ravyn Lenae's *Blue Island* was pre-added and has since come out, so the SAME cached entry
    /// crosses from Coming Soon into Out Now on its release date. The filter lives in `feed()`,
    /// which both sections derive from, so one fix covers both sides of that line — a filter hung
    /// off `comingSoon()` would have let it reappear the morning it dropped.
    func testAPreAddedRecordStaysFilteredWhenItCrossesIntoOutNow() async {
        let app = await library()
        let releaseAt = Self.now
        let svc = service([
            ArtistReleaseEntry(artistId: 1_100_000_001, artistName: "Ravyn Lenae",
                               checkedAtMs: Self.now, releaseId: "6790000102",
                               releaseName: "Blue Island", releaseAtMs: releaseAt,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 14),
        ])
        XCTAssertNil(app.albumId(forAppleMusicId: "6790000102"), "pre-added ⇒ no store id resolved")
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.feed(nowMs: releaseAt - 2 * Self.day).isEmpty, "before: Coming Soon")
        XCTAssertTrue(svc.feed(nowMs: releaseAt + 2 * Self.day).isEmpty, "after: Out Now")
        withExtendedLifetime(app) {}
    }

    // ── The scope correction: feature 6 was never going to catch these ───────────────────────

    /// **WHY THE REPORT'S OWN DIAGNOSIS WAS WRONG.** The feature-6 join is not broken — it reaches
    /// his rows and returns a non-empty index — it simply answers a different question. Its last
    /// clause requires the two sides to DIFFER by version material, and here they are the same
    /// version with the same empty signature, so it says "not a different version" and every one
    /// of these rows sailed through. That guard is deliberate (see `RecVersionIdentity`'s "never
    /// on artist + title alone" note) and is left exactly as it was.
    func testFeature6AloneCatchesNoneOfThemAndIsRightNotTo() async {
        let app = await library()
        let index = app.ownedVersionIndex(forArtistId: 675_391_681)
        XCTAssertFalse(index.isEmpty, "the artist-id join works — that was never the problem")
        XCTAssertFalse(index.supersedes(title: "Who Coppin", artist: "Larry June"),
                       "same version ⇒ not a DIFFERENT version; feature 6 is answering honestly")

        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6786105209",
                               releaseName: "Who Coppin", releaseAtMs: Self.now - 3 * Self.day),
        ])
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(svc.feed(nowMs: Self.now).count, 1, "reproduces his report exactly")

        // …and it is the OWNERSHIP filter that closes it, with feature 6 still wired beside it.
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.feed(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    /// Feature 6 must keep working with the widened ownership filter in place. A Deluxe reissue of
    /// an owned album is now caught by EITHER route — they overlap by construction, since every
    /// superseding pair shares a bucket — and the two must not fight.
    func testTheDeluxeReissueCaseStillSuppresses() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6799999999",
                               releaseName: "Who Coppin (Deluxe Edition)",
                               releaseAtMs: Self.now - Self.day),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertTrue(svc.feed(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    // ── THE LINE: what must still get through ────────────────────────────────────────────────

    /// **NO OVER-SUPPRESSION.** The whole point of the feed is a new record by an artist he
    /// listens to. He owns two Larry June albums; a third, genuinely new one has a DIFFERENT base
    /// title, lands in no owned bucket, and is offered exactly as it was before this change.
    /// Suppressing on artist alone would delete the feature and leave no trace.
    func testAGenuinelyNewAlbumByAnArtistHeOwnsStillAppears() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6795000000",
                               releaseName: "Doing It for Me", releaseAtMs: Self.now - Self.day),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1,
                       "a new record by an owned artist is the feature, not the bug")
        withExtendedLifetime(app) {}
    }

    /// A `.distinct` performance FAILS OPEN in both directions — a live album of a record he owns
    /// is new music. The ownership route inherits that safety property rather than re-deciding it.
    func testALivePerformanceOfAnOwnedRecordIsStillOffered() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6796000000",
                               releaseName: "Who Coppin (Live)", releaseAtMs: Self.now - Self.day),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1)
        withExtendedLifetime(app) {}
    }

    /// A new album whose title happens to match a SONG he owns by that artist is new music. This
    /// is why the ownership index is built from ALBUM titles only, while feature 6 — a different
    /// question — keeps indexing songs as well.
    func testANewAlbumNamedAfterASongHeOwnsIsStillOffered() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6797000000",
                               releaseName: "Turkish Cotton", releaseAtMs: Self.now - Self.day),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1,
                       "he owns the TRACK 'Turkish Cotton'; an album of that name is not that record")
        withExtendedLifetime(app) {}
    }

    /// The cold-launch default is unchanged: an unset probe owns nothing, and the exclusion is
    /// still applied on READ, so the catalog arriving fixes the feed with no refetch.
    func testAnUnsetProbeStillOwnsNothingAndTheCatalogArrivingFixesIt() async {
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6786105209",
                               releaseName: "Who Coppin", releaseAtMs: Self.now - Self.day),
        ])
        XCTAssertNil(svc.ownsRelease)
        XCTAssertEqual(svc.feed(nowMs: Self.now).count, 1)

        let app = await library()
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertEqual(svc.feed(nowMs: Self.now).count, 0, "read-time filter, no refetch")
        withExtendedLifetime(app) {}
    }

    // ── The resolver itself ──────────────────────────────────────────────────────────────────

    /// The record index is keyed on the artist NAME, not the artist id, precisely because the
    /// synthetic Apple Music library source contributes no `artists` table — the Dinner Party
    /// case. An id-keyed index would be empty for exactly the albums that need it most.
    func testTheRecordIndexReachesAlbumsWithNoArtistTableEntry() async {
        let app = await library()
        XCTAssertNil(app.artistId(forArtistName: "Dinner Party"),
                     "fixture models the library source: no artists-table row")
        XCTAssertTrue(app.ownedAlbumRecordIndex(forArtistName: "Dinner Party")
                        .hasRecord(title: "Whatchu Bringing?", artist: "Dinner Party"))
        withExtendedLifetime(app) {}
    }

    /// "Popstar" and "Pop Star" are one record. Matched in BOTH directions, so it does not matter
    /// which side of the join carries which of Apple's spellings.
    func testSpacingDifferencesInATitleAreOneRecord() async {
        let app = await library()
        let owned = app.ownedAlbumRecordIndex(forArtistName: "Tinashe")
        XCTAssertTrue(owned.hasRecord(title: "Pop Star", artist: "Tinashe"))
        XCTAssertTrue(owned.hasRecord(title: "Popstar", artist: "Tinashe"))
        XCTAssertFalse(owned.hasRecord(title: "Pop Life", artist: "Tinashe"),
                       "letter-for-letter, or it is a different record")
        withExtendedLifetime(app) {}
    }

    /// HIS ACTUAL ROWS — ids and spellings verbatim from `public/apple-music-index.json`, except
    /// Dinner Party, which is in no snapshot and is modelled as the live-library album it is.
    private struct OwnerLibraryLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            try JSONDecoder().decode(IndexJSON.self, from: Data(Self.json.utf8))
        }

        static let json = """
        {
          "manifest": { "sourceName": "Apple Music (Local)" },
          "artists": [
            { "key": "larry june", "name": "Larry June", "id": 675391681 },
            { "key": "rod wave", "name": "Rod Wave", "id": 1400000001 },
            { "key": "victoria monét", "name": "Victoria Monét", "id": 1300000001 },
            { "key": "tinashe", "name": "Tinashe", "id": 1200000001 },
            { "key": "ravyn lenae", "name": "Ravyn Lenae", "id": 1100000001 }
          ],
          "albums": [
            { "id": "alb_1edd29e42371", "artist": "Larry June", "name": "Who Coppin",
              "appleMusicId": "6791849225", "genre": "Hip-Hop/Rap", "year": 2026,
              "country": "US", "trackList": ["sng_lj1"], "fileType": "m4a" },
            { "id": "alb_lj_spaceships", "artist": "Larry June", "name": "Spaceships on the Blade",
              "appleMusicId": "1630000001", "genre": "Hip-Hop/Rap", "year": 2022,
              "country": "US", "trackList": ["sng_lj2"], "fileType": "m4a" },
            { "id": "alb_amlib_dinnerparty", "artist": "Dinner Party", "name": "Whatchu Bringing?",
              "genre": "Jazz", "year": 2026, "country": "US",
              "trackList": ["amlib_dp1"], "fileType": "m4a" },
            { "id": "alb_0fcafba5ee32", "artist": "Rod Wave", "name": "Don't Look Down",
              "genre": "Hip-Hop/Rap", "year": 2026, "country": "US",
              "trackList": ["sng_rw1"], "fileType": "m4a" },
            { "id": "alb_148a87e14677", "artist": "Victoria Monét", "name": "Frequency Of Love",
              "genre": "R&B/Soul", "year": 2026, "country": "US",
              "trackList": ["sng_vm1"], "fileType": "m4a" },
            { "id": "alb_398fd2fac360", "artist": "Tinashe", "name": "Popstar",
              "genre": "R&B/Soul", "year": 2026, "country": "US",
              "trackList": ["sng_tn1"], "fileType": "m4a" },
            { "id": "alb_eb585e8d4829", "artist": "Ravyn Lenae", "name": "Blue Island",
              "genre": "R&B/Soul", "year": 2026, "country": "US",
              "trackList": ["sng_rl1"], "fileType": "m4a" }
          ],
          "songs": [
            { "id": "sng_lj1", "albumId": "alb_1edd29e42371", "artist": "Larry June",
              "name": "Who Coppin", "appleMusicId": "6791849226", "trackNumber": 1,
              "year": 2026, "length": 180000 },
            { "id": "sng_lj2", "albumId": "alb_lj_spaceships", "artist": "Larry June",
              "name": "Turkish Cotton", "trackNumber": 1, "year": 2022, "length": 200000 },
            { "id": "amlib_dp1", "albumId": "alb_amlib_dinnerparty", "artist": "Dinner Party",
              "name": "Whatchu Bringing?", "trackNumber": 1, "year": 2026, "length": 210000 },
            { "id": "sng_rw1", "albumId": "alb_0fcafba5ee32", "artist": "Rod Wave",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 },
            { "id": "sng_vm1", "albumId": "alb_148a87e14677", "artist": "Victoria Monét",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 },
            { "id": "sng_tn1", "albumId": "alb_398fd2fac360", "artist": "Tinashe",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 },
            { "id": "sng_rl1", "albumId": "alb_eb585e8d4829", "artist": "Ravyn Lenae",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 }
          ]
        }
        """
    }
}

// ============================================================================
// MARK: - Ownership, round 2: the identities the FIRST cut of this filter missed
// ============================================================================

/// The first pass at the New feed's ownership filter keyed the owned side on
/// `RecVersionIdentity.artistKey(album.artist)` alone. Measured against the owner's real
/// 12,642-album index, that reached only **349 of the 510** id-less 2026 albums it exists for
/// once the feed names the artist the way APPLE does — because `ArtistReleaseEntry.artistName` is
/// Apple's canonical name for ONE artist id (`artist.attributes.name`) while the owned side
/// carries whatever Music.app wrote, which for a collaboration is the whole credit. Dinner Party
/// — one of the two Out Now albums he named — was in the missing 161, and passed only under the
/// plain spelling its fixture happened to use.
///
/// With the credit split, the artist-id route and the bracketed-name key, the same measurement
/// reaches **510 of 510**, with 0 of 400 fabricated titles suppressed as a control.
///
/// Every owned row here is copied VERBATIM out of `public/apple-music-index.json`, credits
/// included — that is the whole point of the class.
@MainActor
final class ReleaseFeedOwnershipCreditIdentityTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-relown2-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func service(_ entries: [ArtistReleaseEntry]) -> ReleaseFeedService {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        svc.seedForTesting(entries)
        return svc
    }

    private func library() async -> AppModel {
        let app = AppModel(loader: RealCreditsLoader())
        await app.loadIfNeeded()
        return app
    }

    private static let now: Double = 1_754_800_000_000
    private static let day: Double = 86_400_000

    // ── (a) OUT NOW: the collaboration credit ────────────────────────────────────────────────

    /// **THE ALBUM HE NAMED, UNDER THE CREDIT HIS INDEX ACTUALLY USES.** Both of his Dinner Party
    /// albums are filed as *"Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi
    /// Washington"*, and the artists table has no plain "Dinner Party" row — that long string is
    /// what maps to Apple artist 1539968565, whose canonical name (verified against
    /// `itunes.apple.com/lookup?id=1539968565`) is just "Dinner Party". So the feed says "dinner
    /// party" and the library says the whole credit, and an `artistKey` equality never met.
    func testAnAlbumOwnedUnderACollaborationCreditIsNotOfferedAsOutNow() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 1_539_968_565, artistName: "Dinner Party",
                               checkedAtMs: Self.now, releaseId: "6786482410",
                               releaseName: "Whatchu Bringing?", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 9),
        ])
        XCTAssertNil(app.albumId(forAppleMusicId: "6786482410"), "no id on the owned side either")
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty,
                      "owned under the long credit, offered under Apple's short one")
        withExtendedLifetime(app) {}
    }

    /// The same shape on a different real row: `alb_fb9a8af9d735` is *"BigXthaPlug, MurdaGang PB,
    /// Ro$ama & Yung Hood — 6WA"*, 2026, no `appleMusicId`, with a real on-disk pointer. Apple's
    /// canonical name for the tracked artist 1482508209 is "BigXthaPlug".
    func testACollabCreditedAlbumHeOwnsIsNotOfferedAsOutNow() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 1_482_508_209, artistName: "BigXthaPlug",
                               checkedAtMs: Self.now, releaseId: "6798000001",
                               releaseName: "6WA", releaseAtMs: Self.now - 2 * Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 14),
        ])
        XCTAssertNil(app.albumId(forAppleMusicId: "6798000001"))
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    /// The control that isolates the variable: the SAME record filed under the plain credit was
    /// already suppressed before this change, and still is.
    func testThePlainCreditCaseStillSuppresses() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 1_539_968_565, artistName: "Dinner Party",
                               checkedAtMs: Self.now, releaseId: "6786482411",
                               releaseName: "Dessert Two", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 9),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    /// **THE ARTIST-ID ROUTE, ON A REAL ALIAS.** His artists table has
    /// `{"key":"kanye west","name":"Kanye West","id":2715720,"alt":[1714710847]}`, and Apple's own
    /// name for 1714710847 (verified by lookup) is **"Ye"**. So a release for that id arrives
    /// naming an artist his catalog has never spelled — `artistKey("Ye")` is "ye", nothing in the
    /// credit says "ye", and the credit split cannot help. Only the artists table knows they are
    /// one artist, which is why the id route exists alongside the name route.
    ///
    /// The owned row is `alb_132e23a7ebf5` — *Yeezus [Explicit Version]*, no `appleMusicId`, so
    /// the store-id route is dead here too.
    func testTheArtistIdRouteReachesAnAlbumFiledUnderAnotherNameForTheSameArtist() async {
        let app = await library()
        XCTAssertNil(app.artistId(forArtistName: "Ye"), "his index has no row spelled 'Ye'")
        let svc = service([
            ArtistReleaseEntry(artistId: 1_714_710_847, artistName: "Ye",
                               checkedAtMs: Self.now, releaseId: "6793000001",
                               releaseName: "Yeezus", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 10),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty,
                      "the alt id in the artists table is the only thing that joins these")
        // …and the name route alone genuinely cannot: no artist id, no suppression.
        XCTAssertFalse(app.ownedAlbumRecordIndex(forArtistName: "Ye")
                        .hasRecord(title: "Yeezus", artist: "Ye"),
                       "isolates the route — this is the id route's work, not the name route's")
        withExtendedLifetime(app) {}
    }

    /// A name written ENTIRELY in brackets is not an artist-less row. `artistKey` strips bracketed
    /// groups (right for "Sade (feat. Sweetback)"), which reduced `"[IVY]"` to the empty string —
    /// an unusable key, so the row silently left the comparison. Real row: `alb_0127f123a18b`,
    /// *"[IVY] & XIRA — Car Crash - Single"*. This was the last of the 510 still getting through.
    func testABracketedArtistNameIsNotArtistLess() async {
        let app = await library()
        XCTAssertEqual(RecVersionIdentity.artistKey("[IVY]"), "",
                       "the shared artist key really is empty — that is the mechanism")
        XCTAssertEqual(RecVersionIdentity.ownershipArtistKey("[IVY]"), "ivy")
        let svc = service([
            ArtistReleaseEntry(artistId: 1_600_000_002, artistName: "[IVY]",
                               checkedAtMs: Self.now, releaseId: "6794000001",
                               releaseName: "Car Crash - Single", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "single", trackCount: 1),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty)
        withExtendedLifetime(app) {}
    }

    /// An UNRECOGNISED parenthetical makes a title `.distinct`, which fails open — correctly, for
    /// "(Taylor's Version)". But "fails open" cannot mean "he does not own the record when the two
    /// titles are letter-for-letter identical". Both of these are real 2026 rows in his library
    /// with no store id, and both were still being offered.
    func testAnUnrecognisedParentheticalIsStillTheSameRecord() async {
        let app = await library()
        let cases: [(Int, String, String, String)] = [
            (1_601_000_001, "Sexyy Red", "6795000101",
             "Yo Favorite Trappa Favorite Rappa (Hosted by DJ Holiday)"),
            (1_601_000_002, "Too $hort", "6795000102", "SIR TOO $HORT, VOL. 2 (DRINK & SMOKE)"),
        ]
        for (artistId, artist, releaseId, title) in cases {
            let svc = service([
                ArtistReleaseEntry(artistId: artistId, artistName: artist, checkedAtMs: Self.now,
                                   releaseId: releaseId, releaseName: title,
                                   releaseAtMs: Self.now - Self.day, releaseArtworkUrl: nil,
                                   releaseKind: "album", trackCount: 13),
            ])
            svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
            svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
            XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty, "\(artist) — \(title)")
        }
        withExtendedLifetime(app) {}
    }

    // ── THE LINE: what the widening must NOT delete ──────────────────────────────────────────

    /// **THE COMING SOON SIDE OF "MUST STILL APPEAR"** — which the first cut never tested: every
    /// one of its no-over-suppression tests was an Out Now test. An unadded pre-order by an artist
    /// he owns is the entire point of that section, and over-suppressing it would silently empty
    /// the list he complained about.
    func testAPreOrderHeHasNotAddedIsStillOfferedInComingSoon() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6799000001",
                               releaseName: "Midnight Orange", releaseAtMs: Self.now + 30 * Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 12),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(svc.comingSoon(nowMs: Self.now).count, 1,
                       "an unadded pre-order by an artist he owns is the FEATURE")
        withExtendedLifetime(app) {}
    }

    /// A release by an artist he owns nothing by — the similar-artist seed path.
    func testAReleaseByAnArtistHeOwnsNothingByIsStillOffered() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 999_000_001, artistName: "Some New Artist",
                               checkedAtMs: Self.now, releaseId: "6799000002",
                               releaseName: "Debut", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 10),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1)
        withExtendedLifetime(app) {}
    }

    /// **THE COST OF THE CREDIT SPLIT, BOUNDED.** Being named on a credit he owns is not ownership
    /// of everything that artist releases: 9th Wonder is on the Dinner Party record, and a new
    /// 9th Wonder album under a different title is still new music. Only the identical base title
    /// suppresses.
    func testACollaboratorsOwnNewRecordIsStillOffered() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 1_610_000_001, artistName: "9th Wonder",
                               checkedAtMs: Self.now, releaseId: "6799000005",
                               releaseName: "The Wonder Years II", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 12),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        svc.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1,
                       "credited on an owned record ≠ owning this one")
        // …but the record he IS on, under his own name, is his.
        XCTAssertTrue(app.ownedAlbumRecordIndex(forArtistName: "9th Wonder")
                        .hasRecord(title: "Whatchu Bringing?", artist: "9th Wonder"))
        withExtendedLifetime(app) {}
    }

    /// Owning a LIVE album is still not grounds to hide the studio record, and vice versa. The
    /// exact-title route added for unrecognised parentheticals must not touch this — the two sides
    /// there differ by version material, which is a different question.
    func testTheLiveFailOpenSurvivesInBothDirections() async {
        let app = await library()
        // He owns "Who Coppin"; a live album of it is new music.
        let live = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6796000000",
                               releaseName: "Who Coppin (Live)", releaseAtMs: Self.now - Self.day),
        ])
        live.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        live.ownsReleaseVersion = ReleaseFeedService.versionProbe(app: app)
        XCTAssertEqual(live.outNow(nowMs: Self.now).count, 1)

        // And he owns "Car Crash - Single (Live)"; the studio cut is still new music.
        let owned = RecVersionIndex(owned: [
            RecVersionIdentity.key(title: "Some Record (Live)", artistKey: "an artist")!,
        ])
        XCTAssertFalse(owned.hasRecord(title: "Some Record", artist: "An Artist"),
                       "owning the live take does not mean owning the record")
        XCTAssertTrue(owned.hasRecord(title: "Some Record (Live)", artist: "An Artist"),
                      "…but the live take itself is his")
        withExtendedLifetime(app) {}
    }

    // ── The plumbing, asserted directly ──────────────────────────────────────────────────────

    /// The credit split itself, and the `artistKey` behaviour that makes it necessary.
    func testCreditArtistKeysNamesEveryArtistInACredit() {
        let dp = RecVersionIdentity.creditArtistKeys(
            "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington")
        XCTAssertTrue(dp.contains("dinner party"))
        XCTAssertTrue(dp.contains("terrace martin"))
        XCTAssertTrue(dp.contains("kamasi washington"))
        // The whole credit stays in the set — nothing that matched before stops matching.
        XCTAssertTrue(dp.contains(RecVersionIdentity.artistKey(
            "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington")))
        // A single-name credit is exactly one key.
        XCTAssertEqual(RecVersionIdentity.creditArtistKeys("BigXthaPlug"), ["bigxthaplug"])
        // The shared key that feature 6 uses is UNCHANGED — this is additive, not a loosening.
        XCTAssertNotEqual(RecVersionIdentity.artistKey("BigXthaPlug, MurdaGang PB, Ro$ama & Yung Hood"),
                          RecVersionIdentity.artistKey("BigXthaPlug"))
        XCTAssertFalse(RecVersionIdentity.isDifferentVersion(
            candidateTitle: "6WA (Deluxe)", candidateArtist: "BigXthaPlug",
            ownedTitle: "6WA", ownedArtist: "BigXthaPlug, MurdaGang PB, Ro$ama & Yung Hood"),
            "feature 6's bucketing is not widened by any of this")
    }

    /// `AlbumOwnership.owns` is still the one predicate, and the record route reaches it as its own
    /// argument rather than as a forged store id — so a future change here can still veto it.
    func testOwnsDecidesTheRecordRouteItself() {
        XCTAssertFalse(AlbumOwnership.owns(storeID: "1", catalogSongIds: [],
                                           catalogAppleMusicIds: [], rippedSongIds: [],
                                           adHocPrefix: "amrec_album_"))
        XCTAssertTrue(AlbumOwnership.owns(storeID: "1", catalogSongIds: [],
                                          catalogAppleMusicIds: [], rippedSongIds: [],
                                          adHocPrefix: "amrec_album_", localRecordMatch: true))
        // The track-level callers are untouched: the parameter defaults to false.
        XCTAssertFalse(AlbumOwnership.owns(storeID: "1", catalogSongIds: [],
                                           catalogAppleMusicIds: [], rippedSongIds: []))
    }

    /// A titleless release cannot use the record route and must not crash or over-match.
    func testATitlelessReleaseFallsBackToTheIdRouteOnly() async {
        let app = await library()
        let probe = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertFalse(probe(ReleaseIdentity(storeId: "6799000003", artistId: 675_391_681,
                                             artistName: "Larry June", title: nil)))
        XCTAssertTrue(probe(ReleaseIdentity(storeId: "6799000003", artistId: 675_391_681,
                                            artistName: "Larry June", title: "Who Coppin")))
        withExtendedLifetime(app) {}
    }

    /// **STILL FILTERED ON READ.** The album→artist grouping moved into the catalog build (off the
    /// main actor) to get a 54 ms album-table walk off the render path — which is only safe if an
    /// ADD still rebuilds it. It does: the add seam runs `applyEdits`, which bumps
    /// `catalogRevision` and re-derives the grouping, so the row drops on the very next read with
    /// no refetch and no stale memo.
    func testAnAddTakesEffectOnTheNextReadWithNoRefetch() async {
        let app = await library()
        let svc = service([
            ArtistReleaseEntry(artistId: 675_391_681, artistName: "Larry June",
                               checkedAtMs: Self.now, releaseId: "6799000004",
                               releaseName: "Midnight Orange", releaseAtMs: Self.now - Self.day,
                               releaseArtworkUrl: nil, releaseKind: "album", trackCount: 12),
        ])
        svc.ownsRelease = ReleaseFeedService.ownershipProbe(app: app)
        XCTAssertEqual(svc.outNow(nowMs: Self.now).count, 1, "not owned yet")
        _ = app.ownedAlbumRecordIndex(forArtistName: "Larry June", artistId: 675_391_681)  // warm
        let obj: [String: Any] = ["id": "alb_new_mo", "name": "Midnight Orange",
                                  "artist": "Larry June", "trackList": [String]()]
        let added = try! JSONDecoder().decode(
            IndexAlbum.self, from: try! JSONSerialization.data(withJSONObject: obj))
        app.injectDiscoverAlbumBatch(songs: [], album: added)
        XCTAssertTrue(svc.outNow(nowMs: Self.now).isEmpty,
                      "READ-time: the add drops the row with no refetch and no stale memo")
        withExtendedLifetime(app) {}
    }

    /// HIS ACTUAL ROWS — album ids, credits and titles verbatim from
    /// `public/apple-music-index.json`, plus the artists-table rows that carry the joins
    /// (including Kanye West's real `alt` id, which Apple names "Ye"). Dinner Party's *Whatchu
    /// Bringing?* is in no snapshot and is modelled as the live-library album it is, under the
    /// long credit both of his other Dinner Party albums carry.
    private struct RealCreditsLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            try JSONDecoder().decode(IndexJSON.self, from: Data(Self.json.utf8))
        }
        static let json = """
        {
          "manifest": { "sourceName": "Apple Music (Local)" },
          "artists": [
            { "key": "larry june", "name": "Larry June", "id": 675391681 },
            { "key": "bigxthaplug", "name": "BigXthaPlug", "id": 1482508209 },
            { "key": "kanye west", "name": "Kanye West", "id": 2715720, "alt": [1714710847] },
            { "key": "sexyy red", "name": "Sexyy Red", "id": 1601000001 },
            { "key": "too $hort", "name": "Too $hort", "id": 1601000002 },
            { "key": "dinner party, terrace martin, robert glasper, 9th wonder & kamasi washington",
              "name": "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington",
              "id": 1539968565 }
          ],
          "albums": [
            { "id": "alb_1edd29e42371", "artist": "Larry June", "name": "Who Coppin",
              "appleMusicId": "6791849225", "genre": "Hip-Hop/Rap", "year": 2026,
              "trackList": ["sng_lj1"], "fileType": "m4a" },
            { "id": "alb_fb9a8af9d735", "artist": "BigXthaPlug, MurdaGang PB, Ro$ama & Yung Hood",
              "name": "6WA", "genre": "Hip-Hop/Rap", "year": 2026,
              "trackList": ["sng_bx1"], "fileType": "aac" },
            { "id": "alb_dp_long", "artist": "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington",
              "name": "Whatchu Bringing?", "genre": "Jazz", "year": 2026,
              "trackList": ["sng_dp1"], "fileType": "m4a" },
            { "id": "alb_dp_plain", "artist": "Dinner Party", "name": "Dessert Two",
              "genre": "Jazz", "year": 2026, "trackList": ["sng_dp2"], "fileType": "m4a" },
            { "id": "alb_132e23a7ebf5", "artist": "Kanye West", "name": "Yeezus [Explicit Version]",
              "genre": "Hip-Hop/Rap", "year": 2013, "trackList": ["sng_kw1"], "fileType": "m4a" },
            { "id": "alb_0127f123a18b", "artist": "[IVY] & XIRA", "name": "Car Crash - Single",
              "genre": "Dance", "year": 2026, "trackList": ["sng_iv1"], "fileType": "m4a" },
            { "id": "alb_a2a0b1d730c5", "artist": "Sexyy Red",
              "name": "Yo Favorite Trappa Favorite Rappa (Hosted by DJ Holiday)",
              "genre": "Hip-Hop/Rap", "year": 2026, "trackList": ["sng_sr1"], "fileType": "m4a" },
            { "id": "alb_089ee7b43ab1", "artist": "Too $hort",
              "name": "SIR TOO $HORT, VOL. 2 (DRINK & SMOKE)",
              "genre": "Hip-Hop/Rap", "year": 2026, "trackList": ["sng_ts1"], "fileType": "m4a" }
          ],
          "songs": [
            { "id": "sng_lj1", "albumId": "alb_1edd29e42371", "artist": "Larry June",
              "name": "Who Coppin", "trackNumber": 1, "year": 2026, "length": 180000 },
            { "id": "sng_bx1", "albumId": "alb_fb9a8af9d735",
              "artist": "BigXthaPlug, Yung Hood, Ro$ama & MurdaGang PB",
              "name": "6WA", "trackNumber": 1, "year": 2026, "length": 128493 },
            { "id": "sng_dp1", "albumId": "alb_dp_long",
              "artist": "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington",
              "name": "Whatchu Bringing?", "trackNumber": 1, "year": 2026, "length": 210000 },
            { "id": "sng_dp2", "albumId": "alb_dp_plain", "artist": "Dinner Party",
              "name": "Dessert Two", "trackNumber": 1, "year": 2026, "length": 210000 },
            { "id": "sng_kw1", "albumId": "alb_132e23a7ebf5", "artist": "Kanye West",
              "name": "On Sight", "trackNumber": 1, "year": 2013, "length": 156000 },
            { "id": "sng_iv1", "albumId": "alb_0127f123a18b", "artist": "[IVY] & XIRA",
              "name": "Car Crash", "trackNumber": 1, "year": 2026, "length": 168000 },
            { "id": "sng_sr1", "albumId": "alb_a2a0b1d730c5", "artist": "Sexyy Red",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 },
            { "id": "sng_ts1", "albumId": "alb_089ee7b43ab1", "artist": "Too $hort",
              "name": "Track 1", "trackNumber": 1, "year": 2026, "length": 0 }
          ]
        }
        """
    }
}
