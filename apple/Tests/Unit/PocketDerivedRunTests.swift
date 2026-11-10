import XCTest
@testable import PocketDJ

/// A pocket run is DERIVED from its pocket, not a replay: neighbour collections that sound like
/// the pocket's own join the run, the captured songs (seeds) are capped, a cloud List pocket
/// becomes a run profile, and seed features fill the profile's gaps.
final class PocketDerivedRunTests: XCTestCase {

    typealias C = PocketRunPlanner.Candidate

    static func song(_ id: String, artist: String, genre: String, bpm: Double, year: Int,
                     in collections: [String], timbre: SimilarityFamilies.TimbreVector? = nil) -> C {
        C(id: id, title: id, artist: artist, lengthMs: 200_000,
          features: .init(artistKeys: RecVersionIdentity.creditArtistKeys(artist), album: "alb_\(id)",
                          genre: genre, year: year, bpm: bpm, timbre: timbre),
          memberships: Dictionary(uniqueKeysWithValues: collections.map { ($0, 1.0) }))
    }

    /// "Hip-hop 1990–2000" (the pocket's own crate), another 90s boom-bap crate with no shared
    /// songs, a modern trap crate, and a 90s rock crate.
    static func universe() -> [String: C] {
        var out: [String: C] = [:]
        for i in 0..<150 {
            let id = "hh90_\(i)"
            out[id] = song(id, artist: "HH Artist \(i % 30)", genre: "hip-hop", bpm: 88 + Double(i % 8),
                           year: 1990 + i % 11, in: ["pl_hh90"])
        }
        for i in 0..<80 {
            let id = "boom_\(i)"
            out[id] = song(id, artist: "Boom Artist \(i % 20)", genre: "hip-hop", bpm: 89 + Double(i % 6),
                           year: 1992 + i % 8, in: ["pl_boom"])
        }
        for i in 0..<80 {
            let id = "trap_\(i)"
            out[id] = song(id, artist: "Trap Artist \(i % 20)", genre: "hip-hop", bpm: 140 + Double(i % 6),
                           year: 2018 + i % 6, in: ["pl_trap"])
        }
        for i in 0..<80 {
            let id = "rock_\(i)"
            out[id] = song(id, artist: "Rock Artist \(i % 20)", genre: "rock", bpm: 92, year: 1995, in: ["pl_rock"])
        }
        return out
    }

    static func profile(seeds: [String: Double] = [:]) -> PocketProfile {
        PocketProfile(tier: .rich, caption: "Fri 9 PM", detail: "Hip-hop 90s",
                      collections: ["pl_hh90": 1], genres: ["hip-hop": 1],
                      bpmLo: 88, bpmHi: 96, eraLo: 1990, eraHi: 2000, seeds: seeds)
    }

    func testSimilarCollectionsJoinTheRunAndUnlikeOnesDoNot() {
        let u = Self.universe()
        let d = PocketRunPlanner.derived(Self.profile(), candidates: u)
        XCTAssertNotNil(d.collections["pl_boom"], "90s boom-bap crate is a neighbour")
        XCTAssertNil(d.collections["pl_rock"], "a different genre is never a neighbour")
        XCTAssertNil(d.collections["pl_trap"], "same genre, wrong era + tempo")
        let neighbourMass = d.collections.filter { $0.key != "pl_hh90" }.values.reduce(0, +)
        XCTAssertGreaterThan(neighbourMass, 0)
        XCTAssertLessThanOrEqual(neighbourMass, PocketRunPlanner.neighbourShare + 1e-9)
        XCTAssertEqual(d.dominantCollectionId, "pl_hh90")

        let plan = PocketRunPlanner.plan(.init(profile: d, candidates: u, seed: 3))
        let ids = plan.rows.map(\.songId)
        XCTAssertGreaterThan(ids.filter { $0.hasPrefix("boom_") }.count, 5, "the neighbour crate gets slots")
        XCTAssertGreaterThan(ids.filter { $0.hasPrefix("hh90_") }.count, ids.count / 2, "the pocket's own crate leads")
        XCTAssertTrue(ids.allSatisfy { !$0.hasPrefix("rock_") })
    }

    func testNoCollectionsMeansNoExpansion() {
        var p = Self.profile(); p.collections = [:]
        XCTAssertEqual(PocketRunPlanner.withNeighbourCollections(p, candidates: Self.universe()), p)
    }

    func testSeedsAreCappedSoTheRunIsNotAReplay() {
        let u = Self.universe()
        let seeds = Dictionary(uniqueKeysWithValues: (0..<60).map { ("hh90_\($0)", 5.0) })
        let plan = PocketRunPlanner.plan(.init(profile: PocketRunPlanner.derived(Self.profile(seeds: seeds), candidates: u),
                                               candidates: u, seed: 11))
        XCTAssertEqual(plan.rows.count, PocketRunPlanner.slots)
        let seeded = plan.rows.filter { seeds[$0.songId] != nil }.count
        XCTAssertLessThanOrEqual(seeded, Int((Double(PocketRunPlanner.slots) * PocketRunPlanner.seedSlotShare).rounded()))
        XCTAssertGreaterThan(seeded, 0, "the captured songs still appear, lightly")
    }

    func testListPocketBecomesARunProfile() {
        let feats = [
            ListeningPocketFeature(dim: "genre", value: "hip-hop", label: "Hip-Hop", share: 0.8, lift: 3, score: 2),
            ListeningPocketFeature(dim: "artist", value: "hh artist 1", label: "HH Artist 1", share: 0.3, lift: 2, score: 1),
            ListeningPocketFeature(dim: "timeBucket", value: "evening", label: "Evening", share: 1, lift: 1, score: 1),
        ]
        let numeric = ["bpm": ListeningPocketNumeric(center: 92, lo: 89, hi: 95, coverage: 0.9, dispersionRatio: nil,
                                                     baselineCenter: nil, defining: true)]
        let p = PocketProfile.from(listening: "Friday night", features: feats, numeric: numeric,
                                   membership: [.init(collectionId: "pl_hh90", weight: 0.9)],
                                   songIds: ["hh90_1", "hh90_2", "hh90_3"])
        XCTAssertEqual(p.collections, ["pl_hh90": 1])
        XCTAssertEqual(p.genres, ["hip-hop": 1])
        XCTAssertEqual(Set(p.seeds.keys), ["hh90_1", "hh90_2", "hh90_3"])
        XCTAssertNotNil(p.bpmBand)
        XCTAssertNil(p.era, "the cloud sent no year")

        let u = Self.universe()
        let d = PocketRunPlanner.derived(p, candidates: u)
        XCTAssertNotNil(d.era, "era filled from the seeds' years")
        XCTAssertNotNil(d.collections["pl_boom"])
        let plan = PocketRunPlanner.plan(.init(profile: d, candidates: u, seed: 5))
        XCTAssertEqual(plan.rows.count, PocketRunPlanner.slots, "a 3-song pocket still yields a full derived run")
    }

    func testListPocketWithoutMembershipFallsBackToCollectionFeatures() {
        let feats = [ListeningPocketFeature(dim: "collection", value: "pl_boom", label: "pl_boom", share: 0.6, lift: 2, score: 1)]
        let p = PocketProfile.from(listening: "x", features: feats, numeric: [:], membership: [], songIds: [])
        XCTAssertEqual(p.collections, ["pl_boom": 1])
    }

    func testSeedGapsNeverOverwriteKnownDimensions() {
        let u = Self.universe()
        let p = Self.profile(seeds: ["rock_1": 1, "rock_2": 1, "rock_3": 1])
        let f = PocketRunPlanner.fillingGapsFromSeeds(p, candidates: u)
        XCTAssertEqual(f.genres, p.genres)
        XCTAssertEqual(f.bpmBand, p.bpmBand)
        XCTAssertEqual(f.era, p.era)
    }

    // MARK: Freshness

    func testRecencyIsLinearOverFreshDays() {
        let day = 86_400_000.0, now = 100 * day
        let r = PocketRunPlanner.recency(lastPlayedMs: ["a": now, "b": now - 15 * day, "c": now - 31 * day], nowMs: now)
        XCTAssertEqual(r["a"]!, 1, accuracy: 1e-9)
        XCTAssertEqual(r["b"]!, 0.5, accuracy: 1e-9)
        XCTAssertNil(r["c"], "older than freshDays = fresh")
    }

    /// Most of the pocket's crate was heard this week: the run still stays ≥ 60 % fresh in
    /// every prefix, so it explores instead of replaying the week.
    func testRunsStayFreshEvenWhenThePocketWasHeardRecently() {
        let u = Self.universe()
        var recency: [String: Double] = [:]
        for i in 0..<120 { recency["hh90_\(i)"] = 0.9 }   // 120 of 150 heard in the last ~3 days
        for i in 0..<40 { recency["boom_\(i)"] = 0.5 }
        let d = PocketRunPlanner.derived(Self.profile(), candidates: u)
        let plan = PocketRunPlanner.plan(.init(profile: d, candidates: u, recency: recency, seed: 9))
        XCTAssertEqual(plan.rows.count, PocketRunPlanner.slots)
        var fresh = 0
        for (n, row) in plan.rows.enumerated() {
            if recency[row.songId] == nil { fresh += 1 }
            if n >= 4 {
                XCTAssertGreaterThanOrEqual(Double(fresh) / Double(n + 1), PocketRunPlanner.freshFloor - 0.2,
                                            "prefix \(n + 1) is too stale")
            }
        }
        XCTAssertGreaterThanOrEqual(Double(fresh) / Double(plan.rows.count), PocketRunPlanner.freshFloor)
    }

    func testPlayingASongALotNeverLiftsItButSkippingStillSinksIt() {
        let u = Self.universe()
        let scorer = PocketRunPlanner.Scorer(profile: Self.profile(), tuning: .neutral,
                                             familiarity: ["hh90_1": 0.45, "hh90_2": -0.3], pool: Array(u.values))
        let base = scorer.score(u["hh90_3"]!)
        XCTAssertEqual(scorer.score(u["hh90_1"]!), base, accuracy: 0.2, "familiar ≈ unfamiliar peer")
        XCTAssertLessThanOrEqual(scorer.score(u["hh90_1"]!) - base, 0.2)
        XCTAssertLessThan(scorer.score(u["hh90_2"]!), scorer.score(u["hh90_1"]!), "skipped sinks")

        let fresh = PocketRunPlanner.Scorer(profile: Self.profile(), tuning: .neutral, familiarity: [:],
                                            recency: ["hh90_1": 1], pool: Array(u.values))
        XCTAssertLessThan(fresh.score(u["hh90_1"]!), fresh.score(u["hh90_9"]!), "just heard < fresh peer")
    }
}
