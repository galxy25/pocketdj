import XCTest
@testable import PocketDJ

/// FIRST POPULATION of the New tile, and the honest empty state.
///
/// The bug this file exists to prevent, in the owner's words: *"my new tile is still empty."* The
/// release feed only ever fetched from `noteArtistPlayed`, so a cold cache waited for enough
/// DIFFERENT artists to be played — and since only 15–22% of artists have a release in any 30-day
/// window, that is a very long silence that the tile explained not at all.
///
/// Two things are asserted here and they are separate:
///  • the SEED SET is right — the last 30 days of play EVENTS (not top-by-playcount, not the
///    last-play-per-track that Library.xml would give), one shot, never repeating;
///  • the EMPTY STATE is honest — four genuinely different causes, four different answers.
final class ReleaseFeedSeedSetTests: XCTestCase {

    private let now: Double = 1_800_000_000_000
    private let day: Double = 86_400_000

    private func event(_ artist: String?, at ms: Double, song: String = "s") -> PlayHistoryStore.PlayEvent {
        PlayHistoryStore.PlayEvent(id: UUID(), songId: song, playedAt: ms, source: .browser,
                                   contextId: nil, contextName: nil, title: nil, artist: artist,
                                   originInstallId: nil)
    }

    // ========================================================================
    // MARK: - The window
    // ========================================================================

    func testOnlyTheLastThirtyDaysCount() {
        let names = ReleaseFeedSeed.recentArtistNames([
            event("Inside", at: now - 5 * day),
            event("Edge", at: now - 29.9 * day),
            event("Outside", at: now - 31 * day),
        ], nowMs: now)
        XCTAssertEqual(Set(names), ["Inside", "Edge"])
        XCTAssertFalse(names.contains("Outside"), "the window is 30 days and is not silently widened")
    }

    func testTheWindowIsTheFeedWindow() {
        // If someone re-tunes `windowDays`, the seed follows rather than drifting to its own
        // number — a seed wider than the feed would fetch artists whose releases can never show.
        let inside = ReleaseFeedSeed.recentArtistNames(
            [event("A", at: now - (ReleaseFeedPolicy.windowDays - 1) * day)], nowMs: now)
        let outside = ReleaseFeedSeed.recentArtistNames(
            [event("A", at: now - (ReleaseFeedPolicy.windowDays + 1) * day)], nowMs: now)
        XCTAssertEqual(inside, ["A"])
        XCTAssertTrue(outside.isEmpty)
    }

    // ========================================================================
    // MARK: - It is a set of ARTISTS, from EVENTS
    // ========================================================================

    /// THE Library.xml TRAP. That file keeps only the LAST play per track, so a month of repeat
    /// listening collapses to one row and an artist whose recent activity is all re-listens can
    /// vanish. The event log has every play — this asserts the repeat listening is what carries
    /// the artist in.
    func testRepeatPlaysOfOneTrackStillCarryTheArtist() {
        let names = ReleaseFeedSeed.recentArtistNames((0..<20).map {
            event("Repeater", at: now - Double($0) * 3_600_000, song: "one-track")
        }, nowMs: now)
        XCTAssertEqual(names, ["Repeater"], "twenty plays of one track = one artist, still seeded")
    }

    func testArtistsAreDedupedCaseAndDiacriticInsensitively() {
        let names = ReleaseFeedSeed.recentArtistNames([
            event("Beyoncé", at: now - day),
            event("BEYONCE", at: now - 2 * day),
            event("beyoncé", at: now - 3 * day),
        ], nowMs: now)
        XCTAssertEqual(names.count, 1, "one artist, however it was spelled at record time")
    }

    func testMostRecentlyPlayedFirst() {
        // The batches go out 50 at a time, so ordering decides who gets checked first.
        let names = ReleaseFeedSeed.recentArtistNames([
            event("Oldest", at: now - 20 * day),
            event("Newest", at: now - 1 * day),
            event("Middle", at: now - 10 * day),
        ], nowMs: now)
        XCTAssertEqual(names, ["Newest", "Middle", "Oldest"])
    }

    func testEventsWithNoArtistAreSkippedRatherThanSeedingAnEmptyName() {
        let names = ReleaseFeedSeed.recentArtistNames([
            event(nil, at: now - day),
            event("   ", at: now - day),
            event("Real", at: now - day),
        ], nowMs: now)
        XCTAssertEqual(names, ["Real"])
    }

    func testEmptyLogSeedsNothing() {
        XCTAssertTrue(ReleaseFeedSeed.recentArtistNames([], nowMs: now).isEmpty)
    }

    /// The cost claim in the design note, asserted rather than believed: ~500 distinct artists is
    /// ~10 batched requests at 50 ids each — a handful, not a poll.
    func testARealisticMonthIsAboutTenBatches() {
        var events: [PlayHistoryStore.PlayEvent] = []
        for i in 0..<910 {                       // ~910 events, ~493 distinct artists
            events.append(event("Artist \(i % 493)", at: now - Double(i % 29) * day))
        }
        let names = ReleaseFeedSeed.recentArtistNames(events, nowMs: now)
        XCTAssertEqual(names.count, 493)
        let batches = Int(ceil(Double(names.count) / Double(ReleaseFeedPolicy.idsPerRequest)))
        XCTAssertEqual(batches, 10)
    }
}

@MainActor
final class ReleaseFeedSeedServiceTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("release-feed-seed-\(UUID().uuidString).json")
    }

    private func artists(_ n: Int) -> [(id: Int, name: String)] {
        (1...n).map { (id: $0, name: "Artist \($0)") }
    }

    // ========================================================================
    // MARK: - One shot, ever
    // ========================================================================

    func testSeedQueuesEveryArtistAndBatchesThemFifty() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        XCTAssertTrue(svc.needsSeed)
        XCTAssertTrue(svc.seedFromRecentListening(artists: artists(120)))
        XCTAssertEqual(svc.pendingCountForTesting, 120)
        await svc.drain()
        XCTAssertEqual(stub.requestCount, 3, "120 artists → 50 + 50 + 20 — batched, not 120 calls")
    }

    func testSeedDoesNotRepeatOnTheNextLaunch() async {
        let file = tempURL()
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: file)
        XCTAssertTrue(svc.seedFromRecentListening(artists: artists(3)))
        await svc.drain()
        XCTAssertFalse(svc.needsSeed)

        // A whole new process, reading the same document.
        let reborn = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: file)
        XCTAssertFalse(reborn.needsSeed, "the seed stamp is PERSISTED — it is one shot per install")
        XCTAssertFalse(reborn.seedFromRecentListening(artists: artists(3)))
        XCTAssertEqual(reborn.pendingCountForTesting, 0)
    }

    func testSeedIsRefusedWhileAppleMusicIsUnavailableSoItCanStillRunLater() {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(canSync: false),
                                     fileURL: tempURL())
        XCTAssertFalse(svc.seedFromRecentListening(artists: artists(5)))
        XCTAssertEqual(svc.pendingCountForTesting, 0)
        XCTAssertTrue(svc.needsSeed,
                      "un-stamped, so turning Apple Music on later still seeds — refusing must "
                      + "not burn the one shot")
    }

    func testSeedDoesNotRunOverAWarmCache() {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        let now = Date().timeIntervalSince1970 * 1000
        svc.seedForTesting([ArtistReleaseEntry(artistId: 9, artistName: "Known", checkedAtMs: now)])
        XCTAssertFalse(svc.needsSeed, "an install that already has answers is not a cold feed")
        XCTAssertFalse(svc.seedFromRecentListening(artists: artists(5)))
    }

    /// Steady state is UNCHANGED: after the seed, the only trigger is still a play. Nothing here
    /// introduces a schedule.
    func testAfterTheSeedRefreshIsStillLazyAndOnPlay() async {
        let stub = StubReleaseTransport()
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL())
        svc.playsForArtist = { _ in 2860 }                    // hot → 2-day TTL
        svc.seedFromRecentListening(artists: artists(2))
        await svc.drain()
        let afterSeed = stub.requestCount

        // A play of an artist the seed just checked must NOT fetch again.
        svc.noteArtistPlayed(artistId: 1, name: "Artist 1")
        XCTAssertEqual(svc.pendingCountForTesting, 0)
        await svc.drain()
        XCTAssertEqual(stub.requestCount, afterSeed, "no extra request — the TTL is honoured")
    }

    // ========================================================================
    // MARK: - The honest empty state
    // ========================================================================

    func testEmptyReasonNotAuthorizedWhenAppleMusicIsOff() {
        let svc = ReleaseFeedService(transport: nil, fileURL: tempURL())
        XCTAssertEqual(svc.emptyReason(), .notAuthorized)
    }

    func testEmptyReasonNotCheckedYetOnAColdAuthorizedInstall() {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        XCTAssertEqual(svc.emptyReason(), .notCheckedYet,
                       "authorized but nothing has ever been asked — NOT 'nothing came out'")
    }

    func testEmptyReasonCheckingWhileTheSeedIsInFlight() {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        svc.seedFromRecentListening(artists: artists(3))
        XCTAssertEqual(svc.emptyReason(), .checking)
    }

    func testSeedingClearsItselfSoTheTileStopsSayingChecking() async {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        svc.seedFromRecentListening(artists: artists(3))
        await svc.drain()
        XCTAssertNotEqual(svc.emptyReason(), .checking,
                          "a finished seed must stop claiming to be in progress")
    }

    func testEmptyReasonUnreachableAfterAFailedFetch() async {
        let stub = StubReleaseTransport()
        stub.persistentError = ReleaseFeedTransportError.http(status: 500)
        let svc = ReleaseFeedService(transport: stub, fileURL: tempURL(), timeScale: 0.0001)
        svc.seedFromRecentListening(artists: artists(2))
        await svc.drain()
        guard case .unreachable = svc.emptyReason() else {
            return XCTFail("a failed seed must say the network refused, not 'nothing came out'")
        }
    }

    func testEmptyReasonNothingNewOnlyWhenSomethingWasActuallyChecked() async {
        let svc = ReleaseFeedService(transport: StubReleaseTransport(), fileURL: tempURL())
        svc.seedFromRecentListening(artists: artists(2))
        await svc.drain()
        XCTAssertEqual(svc.emptyReason(), .nothingNew,
                       "artists were checked and none had a release — the only honest use of "
                       + "'nothing new in the last 30 days'")
        XCTAssertTrue(svc.newReleases().isEmpty)
    }

    // ========================================================================
    // MARK: - The tile / screen copy
    // ========================================================================

    func testEveryEmptyReasonHasItsOwnWordingOnBothSurfaces() {
        let reasons: [ReleaseFeedService.EmptyReason] =
            [.checking, .notAuthorized, .unreachable("Offline."), .notCheckedYet, .nothingNew]
        let titles = reasons.map(NewReleasesView.emptyTitle)
        XCTAssertEqual(Set(titles).count, reasons.count, "four causes must not share one screen")
        let symbols = reasons.map(NewReleasesView.emptySymbol)
        XCTAssertEqual(Set(symbols).count, reasons.count)
        // Only `nothingNew` may keep the card's original claim; every other cause overrides it.
        for r in reasons where r != .nothingNew {
            XCTAssertNotNil(r.tileNote, "\(r) must explain itself on the CARD too")
        }
        XCTAssertNil(ReleaseFeedService.EmptyReason.nothingNew.tileNote)
    }

    func testTheCardStopsClaimingNothingCameOutWhenNothingWasChecked() {
        // The specific lie being removed: a bare 0 under "No releases in the last 30 days" while
        // the feed had never asked anybody.
        XCTAssertEqual(ForYouTiles.newReleaseSubtitle(outNow: 0, comingSoon: 0),
                       "No releases in the last 30 days")
        XCTAssertEqual(ForYouTiles.newReleaseSubtitle(outNow: 0, comingSoon: 0,
                                                      emptyNote: "Checking for new releases…"),
                       "Checking for new releases…")
        // …and it must NOT override a tile that actually has releases to show.
        XCTAssertEqual(ForYouTiles.newReleaseSubtitle(outNow: 3, comingSoon: 0,
                                                      emptyNote: "Checking for new releases…"),
                       "From artists you play · last 30 days")
    }
}
