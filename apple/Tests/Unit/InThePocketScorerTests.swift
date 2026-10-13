import XCTest
@testable import PocketDJ

/// In the Pocket — the pure round builder: context derivation (the cloud's buckets), context
/// MATCHING of cloud pockets/patterns, determinism given a seed, the history / cold fallbacks,
/// exclusions (recently played, unplayable), and round learning (cloud section + the on-device
/// twin of the cloud formula).
final class InThePocketScorerTests: XCTestCase {

    // 2026-10-13 (Tue) 19:30 local at UTC−7 = 2026-10-14T02:30Z.
    static let nowMs = 1_791_945_000_000.0
    static let tz = -420
    static let placeA = "plc_0f1e2d3c4b5a6978"
    static let placeB = "plc_8899aabbccddeeff"

    // MARK: - Fixtures

    /// A small catalog: funk/soul around 118–126, rock fast, jazz slow.
    static let catalog: [String: InThePocketScorer.Song] = {
        var out: [String: InThePocketScorer.Song] = [:]
        func add(_ id: String, _ artist: String, _ genre: String, _ bpm: Double) {
            out[id] = .init(id: id, title: "T-\(id)", artist: artist, lengthMs: 200_000, genre: genre, bpm: bpm)
        }
        add("f1", "Ada", "funk", 118); add("f2", "Bix", "funk", 120); add("f3", "Cleo", "funk", 122)
        add("f4", "Dax", "funk", 124); add("f5", "Eve", "funk", 126); add("f6", "Fin", "funk", 119)
        add("s1", "Gus", "soul", 121); add("s2", "Hal", "soul", 123); add("s3", "Ivy", "soul", 60)
        add("r1", "Jet", "rock", 150); add("r2", "Kai", "rock", 155); add("r3", "Lux", "rock", 148)
        add("j1", "Mo", "jazz", 90); add("j2", "Nia", "jazz", 95)
        return out
    }()

    static let evening = InThePocketContext.make(atMs: nowMs, tzOffsetMin: tz, ctx: .place(placeA))

    static func results(_ json: String) -> ListeningPocketsResults {
        try! JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
    }

    /// One weekday-evening funk pattern at place A, one weekend-morning rock pattern.
    static let cloudJSON = """
    {"v":1,"generatedAtMs":1791940000000,"stale":false,"algo":{"version":1,"params":{}},
     "pockets":[],
     "patterns":[
      {"id":"pt_000000000001","key":"weekday|evening|place:\(placeA)|funk","title":"Weekday evenings · Location A · Funk",
       "pocketIds":["pk_1","pk_2","pk_3"],"occurrences":3,"distinctDays":3,"dayType":"weekday","timeBucket":"evening",
       "ctx":{"kind":"place","placeId":"\(placeA)"},
       "features":[{"dim":"genre","value":"funk","label":"Funk","share":0.8,"lift":3,"score":0.88},
                   {"dim":"place","value":"\(placeA)","label":"Location A","share":1,"lift":2,"score":0.69}],
       "numeric":{"bpm":{"center":121,"lo":118,"hi":126,"coverage":1,"dispersionRatio":0.2,"defining":true}},
       "topSongs":[{"songId":"f1","plays":3},{"songId":"s1","plays":2}]},
      {"id":"pt_000000000002","key":"weekend|morning|*|rock","title":"Weekend mornings · Rock",
       "pocketIds":["pk_4","pk_5"],"occurrences":2,"distinctDays":2,"dayType":"weekend","timeBucket":"morning",
       "features":[{"dim":"genre","value":"rock","label":"Rock","share":0.9,"lift":4,"score":1.2}],
       "numeric":{"bpm":{"center":150,"lo":145,"hi":156,"coverage":1,"dispersionRatio":0.1,"defining":true}},
       "topSongs":[{"songId":"r1","plays":2}]}
     ]}
    """

    static func input(results: ListeningPocketsResults? = InThePocketScorerTests.results(cloudJSON),
                      plays: [InThePocketScorer.Play] = [], seed: UInt64 = 42,
                      playable: Set<String>? = nil, context: InThePocketContext = evening,
                      pastRounds: [InThePocketRound] = []) -> InThePocketScorer.Input {
        InThePocketScorer.Input(context: context, contextLabel: "Location A", results: results,
                                catalog: catalog, playableIds: playable ?? Set(catalog.keys), plays: plays,
                                pastRounds: pastRounds, nowMs: nowMs, seed: seed)
    }

    static func play(_ id: String, hoursAgo: Double, skipped: Bool = false, tz: Int = tz) -> InThePocketScorer.Play {
        .init(songId: id, atMs: nowMs - hoursAgo * 3_600_000, tzOffsetMin: tz,
              outcome: skipped ? "skipped" : "completed", ctx: nil)
    }

    private func picks(_ input: InThePocketScorer.Input) -> InThePocketScorer.Output {
        guard case .success(let out) = InThePocketScorer.build(input) else {
            XCTFail("expected a round"); fatalError()
        }
        return out
    }

    // MARK: - Context

    func testContextUsesTheCloudBucketsInLocalTime() {
        let c = Self.evening
        XCTAssertEqual(c.timeBucket, "evening")
        XCTAssertEqual(c.dayType, "weekday")
        XCTAssertEqual(c.dow, 2, "Tuesday")
        XCTAssertEqual(c.ctxKey, "place:\(Self.placeA)")
        XCTAssertEqual(c.learningKeys, ["weekday|evening|place:\(Self.placeA)", "weekday|evening|*"])
        // The same instant in UTC is Wednesday 02:30 — night, still a weekday.
        let utc = InThePocketContext.make(atMs: Self.nowMs, tzOffsetMin: 0, ctx: nil)
        XCTAssertEqual([utc.timeBucket, utc.dayType], ["night", "weekday"])
        XCTAssertEqual(utc.dow, 3)
        XCTAssertNil(utc.ctx)
        XCTAssertEqual(InThePocketContext.timeBucket(hour: 4.99), "night")
        XCTAssertEqual(InThePocketContext.timeBucket(hour: 5), "morning")
        XCTAssertEqual(InThePocketContext.timeBucket(hour: 21.99), "evening")
        XCTAssertEqual(InThePocketContext.timeBucket(hour: 22), "night")
        // 2026-10-18 15:30Z is Sunday afternoon; at UTC−7 Sunday morning.
        let sun = InThePocketContext.make(atMs: 1_792_337_400_000, tzOffsetMin: Self.tz, ctx: nil)
        XCTAssertEqual([sun.dayType, sun.timeBucket, String(sun.dow)], ["weekend", "morning", "0"])
        let sat = InThePocketContext.make(atMs: 1_792_337_400_000 - 86_400_000, tzOffsetMin: Self.tz, ctx: nil)
        XCTAssertEqual([sat.dayType, String(sat.dow)], ["weekend", "6"])
        // A `none` tag is no context.
        XCTAssertNil(InThePocketContext.make(atMs: Self.nowMs, tzOffsetMin: 0, ctx: .none).ctx)
    }

    func testContextMatchRequiresTheTimeBucketAndRewardsDayAndPlace() {
        let now = Self.evening
        XCTAssertEqual(InThePocketScorer.contextMatch(timeBucket: "morning", dayType: "weekday", ctx: nil, to: now), 0)
        XCTAssertEqual(InThePocketScorer.contextMatch(timeBucket: "evening", dayType: "weekend", ctx: nil, to: now), 2)
        XCTAssertEqual(InThePocketScorer.contextMatch(timeBucket: "evening", dayType: "weekday", ctx: nil, to: now), 3)
        XCTAssertEqual(InThePocketScorer.contextMatch(timeBucket: "evening", dayType: "weekday", ctx: .place(Self.placeA), to: now), 5)
        XCTAssertEqual(InThePocketScorer.contextMatch(timeBucket: "evening", dayType: "weekday", ctx: .place(Self.placeB), to: now), 3)
    }

    // MARK: - Cloud mode

    func testCloudModeAimsAtTheMatchingPatternOnly() {
        let out = picks(Self.input())
        XCTAssertEqual(out.mode, .cloud)
        XCTAssertEqual(out.picks.count, 4, "cloud rounds are four songs")
        XCTAssertEqual(out.targets.map(\.value), ["funk"], "only MUSICAL features of the evening pattern; never the weekend rock")
        XCTAssertEqual(out.bpmBand, 118...126)
        for p in out.picks {
            XCTAssertNotEqual(p.song.genre, "rock")
            XCTAssertNotEqual(p.song.genre, "jazz")
        }
        XCTAssertEqual(out.chips, ["Weekday evening", "Location A", "118–126 BPM", "Funk"])
        XCTAssertEqual(Set(out.picks.map { $0.song.artist }).count, out.picks.count, "one song per artist")
    }

    func testSameSeedSameRoundAndSeedsVary() {
        let a = picks(Self.input(seed: 7))
        let b = picks(Self.input(seed: 7))
        XCTAssertEqual(a, b, "deterministic given the seed")
        let distinct = Set((1...12).map { seed in picks(Self.input(seed: UInt64(seed))).picks.map(\.song.id) })
        XCTAssertGreaterThan(distinct.count, 1, "the seed is what varies a round")
    }

    func testRecentlyPlayedAndUnplayableSongsAreNeverPicked() {
        let recent = ["f1", "f2", "s1"].map { Self.play($0, hoursAgo: 3) }
        let out = picks(Self.input(plays: recent, playable: Set(Self.catalog.keys).subtracting(["f3"])))
        let ids = Set(out.picks.map(\.song.id))
        XCTAssertTrue(ids.isDisjoint(with: ["f1", "f2", "s1", "f3"]))
        // The last three rounds' songs are rested too.
        var past = InThePocketStoreTests.round(songs: ["f4", "f5", "f6"], outcome: .pocket)
        past.createdAtMs = Self.nowMs - 3_600_000
        let rested = picks(Self.input(pastRounds: [past]))
        XCTAssertTrue(Set(rested.picks.map(\.song.id)).isDisjoint(with: ["f4", "f5", "f6"]))
    }

    func testNothingPlayableAndTooFewCandidatesFail() {
        guard case .failure(.nothingPlayable) = InThePocketScorer.build(Self.input(playable: [])) else {
            return XCTFail("no playable songs")
        }
        guard case .failure(.notEnoughCandidates) = InThePocketScorer.build(Self.input(playable: ["f1", "j1"])) else {
            return XCTFail("two candidates can't make a round")
        }
    }

    // MARK: - Fallbacks

    func testWithoutCloudResultsTheRoundComesFromThisContextsHistory() {
        // Evening weekday plays (local 19:30 on prior weekdays): soul played through; jazz skipped.
        var plays: [InThePocketScorer.Play] = []
        for day in 1...4 {
            let h = Double(day * 24)
            plays.append(Self.play("s1", hoursAgo: h))
            plays.append(Self.play("s2", hoursAgo: h - 0.1))
            plays.append(Self.play("j1", hoursAgo: h - 0.2, skipped: true))
        }
        // Mornings are rock — a different context, ignored.
        for day in 1...4 { plays.append(Self.play("r1", hoursAgo: Double(day * 24) + 11)) }
        let out = picks(Self.input(results: nil, plays: plays))
        XCTAssertEqual(out.mode, .history)
        XCTAssertEqual(out.picks.count, 3, "history rounds are three songs")
        XCTAssertEqual(out.targets.first(where: { $0.dim == "genre" })?.value, "soul")
        XCTAssertFalse(out.targets.contains { $0.value == "rock" })
        XCTAssertFalse(out.picks.contains { $0.song.genre == "jazz" && $0.song.id == "j1" }, "a song this context keeps skipping is not a bet")
    }

    func testColdModeWhenThisContextHasNoHistory() {
        let plays = (1...6).map { Self.play($0 % 2 == 0 ? "f1" : "f2", hoursAgo: Double($0 * 24) + 11) }   // mornings only
        let out = picks(Self.input(results: nil, plays: plays))
        XCTAssertEqual(out.mode, .cold)
        XCTAssertEqual(out.targets.first?.value, "funk")
    }

    // MARK: - Round learning

    func testCloudRoundLearningMultipliesTargetsForThisContext() {
        var r = Self.results(Self.cloudJSON)
        r.roundLearning = .init(contexts: [
            .init(key: "weekday|evening|place:\(Self.placeA)", rounds: 5, weights: [
                .init(dim: "genre", value: "funk", pos: 0, neg: 3, multiplier: 0.4),
                .init(dim: "genre", value: "soul", pos: 3, neg: 0, multiplier: 1.6),
            ]),
        ])
        let out = picks(Self.input(results: r))
        XCTAssertEqual(out.targets.first { $0.value == "funk" }?.weight, 0.4, "funk's weight × 0.4")
        XCTAssertEqual(out.targets.first { $0.value == "soul" }?.weight ?? 0, 0.48, accuracy: 1e-9,
                       "a target that keeps predicting well is added (0.3 × 1.6)")
        XCTAssertEqual(out.targets.first?.value, "soul", "re-sorted by weight")
    }

    func testLocalLearningMatchesTheCloudFormula() {
        XCTAssertEqual(InThePocketLearning.multiplier(pos: 0, neg: 0), 1)
        XCTAssertEqual(InThePocketLearning.multiplier(pos: 3, neg: 0), 1.6)    // 2·4/5 — analyze.mjs
        XCTAssertEqual(InThePocketLearning.multiplier(pos: 0, neg: 3), 0.4)
        XCTAssertEqual(InThePocketLearning.multiplier(pos: 0, neg: 1000), 0.25)
        let pocket = InThePocketStoreTests.round(songs: ["a", "b", "c"], outcome: .pocket)
        let early = InThePocketStoreTests.round(songs: ["a", "b", "c"], outcome: .broke(at: 2))
        let late = InThePocketStoreTests.round(songs: ["a", "b", "c", "d"], outcome: .broke(at: 4))
        XCTAssertEqual([pocket, early, late].map(InThePocketLearning.label), [1, -1, 0])
        let ctx = InThePocketLearning.contexts([pocket, pocket, early, late])
        let w = ctx["weekday|evening|*"]?["genre\u{0}funk"]
        XCTAssertEqual(w?.pos, 2); XCTAssertEqual(w?.neg, 1)
        XCTAssertEqual(w?.multiplier, InThePocketLearning.multiplier(pos: 2, neg: 1))
    }

    func testSplitMixIsStable() {
        var g = SplitMix64(seed: 1)
        XCTAssertEqual(g.next(), 0x910A_2DEC_8902_5CC1, "SplitMix64 reference value for seed 1")
        let u = g.nextUnit()
        XCTAssertTrue((0..<1).contains(u))
    }
}
