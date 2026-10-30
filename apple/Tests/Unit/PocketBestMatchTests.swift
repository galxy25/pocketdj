import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 4 — the centre ▶'s best match (§3): each kernel, continuity (and its
/// negation on a skip streak), each cold-start tier, and alternatives with distinct collections.
final class PocketBestMatchTests: XCTestCase {

    private func fixtureWheel() throws -> PocketWheelSnapshot {
        PocketMomentEngine.build(PocketMomentEngineTests.input(try PocketMomentEngineTests.loadFixture()))
    }
    private func key(_ d: Int, _ h: Int, _ m: PocketMode) -> PocketMomentKey { .init(hour: h, dow: d, mode: m) }
    private func now(_ h: Double, _ d: Int, _ m: PocketMode? = nil, ctx: String? = nil) -> PocketBestMatch.Now {
        .init(hour: h, dow: d, mode: m, ctx: ctx)
    }

    // MARK: Kernels

    func testTimeKernelIsCircular() {
        XCTAssertEqual(PocketBestMatch.kt(now(8.5, 2), key(2, 8, .carPlay)), 1, accuracy: 1e-12)
        XCTAssertEqual(PocketBestMatch.kt(now(9.5, 2), key(2, 8, .carPlay)), exp(-0.5), accuracy: 1e-12)
        XCTAssertEqual(PocketBestMatch.kt(now(23.5, 2), key(2, 0, .carPlay)), exp(-0.5), accuracy: 1e-12, "wraps midnight")
        XCTAssertEqual(PocketBestMatch.circularHours(1, 23), 2, accuracy: 1e-12)
    }

    func testDayModeAndPlaceKernels() {
        XCTAssertEqual(PocketBestMatch.kd(now(8, 2), key(2, 8, .carPlay)), 1)
        XCTAssertEqual(PocketBestMatch.kd(now(8, 2), key(4, 8, .carPlay)), 0.6)
        XCTAssertEqual(PocketBestMatch.kd(now(8, 2), key(6, 8, .carPlay)), 0.25)
        XCTAssertEqual(PocketBestMatch.km(now(8, 2, .carPlay), key(2, 8, .carPlay)), 1)
        XCTAssertEqual(PocketBestMatch.km(now(8, 2, .carPlay), key(2, 8, .trip)), 0.7)
        XCTAssertEqual(PocketBestMatch.km(now(8, 2, .carPlay), key(2, 8, .mix)), 0.35)
        XCTAssertEqual(PocketBestMatch.km(now(8, 2), key(2, 8, .mix)), 0.6, "unknown mode")
        var m = PocketMoment(key: key(2, 8, .trip))
        m.ctx = ["trip:trp_ab": 0.5, "none": 0.5]
        XCTAssertEqual(PocketBestMatch.kl(now(8, 2, ctx: "trip:trp_ab"), m), 0.65, accuracy: 1e-12)
        XCTAssertEqual(PocketBestMatch.kl(now(8, 2), m), 1, "no place now ⇒ neutral")
    }

    func testModeNow() {
        XCTAssertEqual(PocketBestMatch.modeNow(carPlayConnected: true, motion: "running", contextGuess: nil), .carPlay)
        XCTAssertEqual(PocketBestMatch.modeNow(carPlayConnected: false, motion: "running", contextGuess: nil), .running)
        XCTAssertEqual(PocketBestMatch.modeNow(carPlayConnected: false, motion: "walking", contextGuess: nil), .walking)
        XCTAssertEqual(PocketBestMatch.modeNow(carPlayConnected: false, motion: "automotive", contextGuess: nil), .trip)
        XCTAssertEqual(PocketBestMatch.modeNow(carPlayConnected: false, motion: nil,
                                               contextGuess: .trip("t", origin: "a", destination: nil)), .trip)
        XCTAssertNil(PocketBestMatch.modeNow(carPlayConnected: false, motion: "stationary", contextGuess: .place("p")))
    }

    // MARK: Tiers on the fixture

    func testRichTierPicksTheMomentAndOffersDistinctAlternatives() throws {
        let r = PocketBestMatch.best(snapshot: try fixtureWheel(), now: now(8.5, 2, .carPlay))
        XCTAssertEqual(r.profile.tier, .rich)
        XCTAssertEqual(r.profile.key, key(2, 8, .carPlay))
        XCTAssertEqual(r.profile.dominantCollectionId, "pl_potential")
        XCTAssertEqual(r.profile.caption, "Tue 8 AM · CarPlay")
        XCTAssertTrue(r.profile.detail.hasPrefix("Potential · "), r.profile.detail)
        XCTAssertEqual(r.profile.mode, .carPlay)
        let alts = r.alternatives.compactMap(\.dominantCollectionId)
        XCTAssertEqual(Set(alts).count, alts.count, "alternatives have distinct collections")
        XCTAssertFalse(alts.contains("pl_potential"))
        XCTAssertLessThanOrEqual(alts.count, 3)
    }

    func testSaturdayMorningRunWins() throws {
        let r = PocketBestMatch.best(snapshot: try fixtureWheel(), now: now(9.2, 6, .running))
        XCTAssertEqual(r.profile.key, key(6, 9, .running))
        XCTAssertEqual(r.profile.dominantCollectionId, "fav_songs")
    }

    func testEveningMixAndW7Mode() throws {
        let r = PocketBestMatch.best(snapshot: try fixtureWheel(), now: now(21.3, 3))
        XCTAssertEqual(r.profile.key?.mode, .mix, "unknown mode at 9 PM → the Mix pocket")
        XCTAssertEqual(r.profile.mode, .mix, "W7: the run plays through Mix Auto-DJ")
    }

    func testContinuityPullsAndSkipStreakPushes() throws {
        let snap = try fixtureWheel()
        // 12:30 on a weekday with no mode: lunch Browse (Chill Lunch) is the natural winner.
        let base = PocketBestMatch.best(snapshot: snap, now: now(12.5, 3))
        XCTAssertEqual(base.profile.dominantCollectionId, "pkt_chill")
        // 30 min of unskipped Potential pulls Potential-heavy moments up …
        var n = now(10.5, 3)
        n.recentCollections = ["pl_potential": 1]
        n.recentSkipRate = 0
        let potCell = try XCTUnwrap(snap.moments.first { $0.key == key(3, 8, .carPlay) })
        let sPull = PocketBestMatch.score(potCell, now: n, boosted: [])
        var unhappy = n
        unhappy.recentSkipRate = 0.8
        let sPush = PocketBestMatch.score(potCell, now: unhappy, boosted: [])
        XCTAssertGreaterThan(sPull.continuity, 0)
        XCTAssertLessThan(sPush.continuity, 0, "a skip streak negates continuity")
        XCTAssertGreaterThan(sPull.score, sPush.score)
    }

    func testCloudBoost() throws {
        var m = PocketMoment(key: key(2, 8, .carPlay))
        m.plays = 10; m.cloudPatternIds = ["pat_1"]
        let a = PocketBestMatch.score(m, now: now(8.5, 2, .carPlay), boosted: [])
        let b = PocketBestMatch.score(m, now: now(8.5, 2, .carPlay), boosted: ["pat_1"])
        XCTAssertEqual(b.score / a.score, 1.15, accuracy: 1e-9)
    }

    // MARK: Cold-start tiers (trimmed fixtures)

    private func snapshot(_ moments: [PocketMoment], total: Int) -> PocketWheelSnapshot {
        PocketWheelSnapshot(builtAtMs: 0, moments: moments, collectionNames: ["c1": "One", "c2": "Two"],
                            dominanceOrder: ["c1"], totalDirectPlays: total)
    }
    private func cell(_ d: Int, _ h: Int, _ mode: PocketMode, plays: Double, direct: Int, coll: String) -> PocketMoment {
        var m = PocketMoment(key: key(d, h, mode))
        m.plays = plays; m.directPlays = direct; m.distinctDays = 2
        m.collections = [coll: 1]; m.dominantCollectionId = coll
        return m
    }

    func testNeighbourhoodTierBlendsNearbyCells() {
        // Weak winner (2 plays) but ±3 h on weekdays holds 6 direct plays.
        let s = snapshot([cell(2, 6, .collection, plays: 2, direct: 2, coll: "c1"),
                          cell(3, 7, .collection, plays: 2, direct: 2, coll: "c1"),
                          cell(4, 10, .mix, plays: 2, direct: 2, coll: "c2")], total: 6)
        let r = PocketBestMatch.best(snapshot: s, now: now(8.5, 2))
        XCTAssertEqual(r.profile.tier, .neighbourhood)
        XCTAssertEqual(r.profile.caption, "Weekday mornings")
        XCTAssertEqual(Set(r.profile.collections.keys), ["c1", "c2"])
        XCTAssertGreaterThan(r.profile.collections["c1"] ?? 0, r.profile.collections["c2"] ?? 0)
    }

    func testCloudThenHistoryThenEmptyTiers() {
        let far = snapshot([cell(6, 22, .mix, plays: 30, direct: 25, coll: "c2")], total: 25)
        let cloud = PocketProfile(tier: .cloud, caption: "From your listening pockets", detail: "x", collections: ["c9": 1])
        XCTAssertEqual(PocketBestMatch.best(snapshot: far, now: now(8.5, 2), fallbacks: .init(cloud: cloud)).profile.tier, .cloud)
        let hist = PocketBestMatch.best(snapshot: far, now: now(8.5, 2))
        XCTAssertEqual(hist.profile.tier, .history)
        XCTAssertEqual(hist.profile.caption, "Your recent favourites")
        XCTAssertEqual(hist.profile.dominantCollectionId, "c2")
        let thin = snapshot([cell(6, 22, .mix, plays: 3, direct: 3, coll: "c2")], total: 3)
        let empty = PocketBestMatch.best(snapshot: thin, now: now(8.5, 2))
        XCTAssertEqual(empty.profile.tier, .empty)
        XCTAssertEqual(empty.profile.caption, "Getting to know you")
        let fav = PocketProfile(tier: .empty, caption: "Getting to know you", detail: "Favorite songs", collections: ["fav_songs": 1])
        XCTAssertEqual(PocketBestMatch.best(snapshot: thin, now: now(8.5, 2), fallbacks: .init(empty: fav)).profile.dominantCollectionId,
                       "fav_songs")
    }

    func testRecentActivity() {
        let t = 1_793_115_000_000.0
        func ev(_ minsAgo: Double, skipped: Bool = false, game: Bool = false) -> PlayHistoryStore.PlayEvent {
            var e = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s", playedAt: t - minsAgo * 60_000,
                                               source: game ? .game : .playlist, contextId: nil, contextName: nil,
                                               title: nil, artist: nil, originInstallId: nil, originCollectionId: "c1")
            if skipped { e.wasSkipped = true }
            return e
        }
        let r = PocketBestMatch.recentActivity(events: [ev(90), ev(40), ev(30, skipped: true), ev(10), ev(5, game: true)],
                                               nowMs: t, attribute: { [$0.originCollectionId ?? "": 1] })
        XCTAssertEqual(r.collections["c1"], 2, "two unskipped plays inside 45 min")
        XCTAssertEqual(r.skipRate ?? -1, 1.0 / 3, accuracy: 1e-9)
        XCTAssertNil(PocketBestMatch.recentActivity(events: [], nowMs: t, attribute: { _ in [:] }).skipRate)
    }
}
