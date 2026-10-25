import XCTest
@testable import PocketDJ

/// The two dead-air fixes from the 2026-10-24 drive audit:
///  1. AM→AM — the next rows' Apple Music catalog resolve runs AHEAD (`PrefetchCache`,
///     `prefetchKey`, `PlaybackCoordinator.prefetchAppleMusic` / `streamsAppleMusicFirst`).
///  2. AM→downloaded on a locked phone — the session pre-arms / falls back MIXABLE and is
///     promoted at first audio (`PlayerEngine.sessionStep`, `AppleMusicPlaybackProvider.nearEnd`).
/// MusicKit and a backgrounded AVAudioSession can't run headless; these pin the pure verdicts.
@MainActor
final class GaplessHandoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Near-end pre-arm trigger

    func testNearEndFiresInsideTheLastLeadSeconds() {
        let lead = AppleMusicPlaybackProvider.nearEndLeadSeconds
        XCTAssertFalse(AppleMusicPlaybackProvider.nearEnd(playbackTime: 180 - lead - 0.5, expectedDuration: 180))
        XCTAssertTrue(AppleMusicPlaybackProvider.nearEnd(playbackTime: 180 - lead, expectedDuration: 180))
        XCTAssertTrue(AppleMusicPlaybackProvider.nearEnd(playbackTime: 179.9, expectedDuration: 180))
    }

    func testNearEndNeverFiresForUnknownOrTinyLengths() {
        XCTAssertFalse(AppleMusicPlaybackProvider.nearEnd(playbackTime: 500, expectedDuration: 0))
        XCTAssertFalse(AppleMusicPlaybackProvider.nearEnd(playbackTime: 5, expectedDuration: 6),
                       "a track shorter than the lead would fire at its first poll")
    }

    // MARK: Session hand-off policy

    func testMixableSessionStaysMixableWhileLockedAndSilent() {
        XCTAssertEqual(PlayerEngine.sessionStep(mixable: true, appActive: false, rendering: false), .keepMixable)
    }

    func testForegroundOrRenderingGoesExclusive() {
        XCTAssertEqual(PlayerEngine.sessionStep(mixable: true, appActive: true, rendering: false), .exclusive)
        XCTAssertEqual(PlayerEngine.sessionStep(mixable: true, appActive: false, rendering: true), .exclusive)
        XCTAssertEqual(PlayerEngine.sessionStep(mixable: false, appActive: false, rendering: false), .exclusive,
                       "not mixable yet: try exclusive first (the '!int' refusal falls back)")
    }

    func testCannotInterruptOthersCodeIsBangInt() {
        // '!int' as a four-char code.
        let fourCC = "!int".utf8.reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(PlayerEngine.cannotInterruptOthersCode, fourCC)
    }

    func testFreshEngineSessionIsNotMixable() {
        XCTAssertFalse(PlayerEngine().sessionMixable)
    }

    // MARK: Pre-resolve cache

    func testPrefetchCacheHitsInsideTTLAndExpiresAfter() {
        var c = AppleMusicPlaybackProvider.PrefetchCache()
        c.insert("song", for: "k", now: t0)
        XCTAssertEqual(c.value(for: "k", now: t0.addingTimeInterval(60)) as? String, "song")
        let ttl = AppleMusicPlaybackProvider.PrefetchCache.ttlSeconds
        XCTAssertNil(c.value(for: "k", now: t0.addingTimeInterval(ttl + 1)))
        XCTAssertNil(c.value(for: "other", now: t0))
    }

    func testPrefetchCacheEvictsOldestPastCapacity() {
        var c = AppleMusicPlaybackProvider.PrefetchCache()
        let cap = AppleMusicPlaybackProvider.PrefetchCache.capacity
        for i in 0...cap { c.insert(i, for: "k\(i)", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(c.entries.count, cap)
        XCTAssertNil(c.value(for: "k0", now: t0.addingTimeInterval(Double(cap))), "oldest evicted")
        XCTAssertNotNil(c.value(for: "k\(cap)", now: t0.addingTimeInterval(Double(cap))))
    }

    func testPrefetchCacheRemove() {
        var c = AppleMusicPlaybackProvider.PrefetchCache()
        c.insert(1, for: "k", now: t0)
        c.remove("k")
        XCTAssertNil(c.value(for: "k", now: t0))
    }

    func testPrefetchKeySeparatesEditions() {
        let base = IndexSong.minimal(id: "sng_a", name: "A", artist: "X", appleMusicId: "1")
        let explicit = IndexSong.minimal(id: "sng_a", name: "A", artist: "X", appleMusicId: "1",
                                         explicit: true, appleMusicIdExplicit: "2")
        let variant = IndexSong.minimal(id: "sng_a_clean", name: "A", artist: "X", appleMusicId: "3")
        let keys = Set([base, explicit, variant].map(AppleMusicPlaybackProvider.prefetchKey))
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(AppleMusicPlaybackProvider.prefetchKey(base),
                       AppleMusicPlaybackProvider.prefetchKey(IndexSong.minimal(id: "sng_a", name: "A", artist: "X", appleMusicId: "1")))
    }

    // MARK: Coordinator: which rows pre-resolve / pre-arm

    private func makeCoordinator() -> PlaybackCoordinator {
        let player = PlayerEngine()
        return PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: RipsStore(), player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
    }

    func testStreamsAppleMusicFirstFollowsTheProviderOrdering() {
        let c = makeCoordinator()
        c.appleMusicReadyOverrideForTests = true
        c.sourceOfSong = { $0 == "sng_am" ? Config.appleMusicSourceName : "My Vinyl" }
        XCTAssertTrue(c.streamsAppleMusicFirst(id: "sng_am", title: "T", artist: "A", variant: nil))
        XCTAssertFalse(c.streamsAppleMusicFirst(id: "sng_vinyl", title: "T", artist: "A", variant: nil),
                       "a vinyl row with no catalog id plays through the rip path — pre-arm the session")
        c.appleMusicReadyOverrideForTests = false
        XCTAssertFalse(c.streamsAppleMusicFirst(id: "sng_am", title: "T", artist: "A", variant: nil))
    }

    func testPrefetchAppleMusicIsInertWhenAppleMusicIsNotAuthorized() {
        // Headless MusicKit is never authorized, so the provider's own `isReady` gate stands
        // down even when the ordering says AM-first: nothing may enter flight.
        let c = makeCoordinator()
        c.appleMusicReadyOverrideForTests = true
        c.sourceOfSong = { _ in Config.appleMusicSourceName }
        c.prefetchAppleMusic([("sng_am", "T", "A", nil)])
        XCTAssertTrue(c.appleMusic.prefetchInFlight.isEmpty)
    }
}
