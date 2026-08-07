import XCTest
@testable import PocketDJ

/// The pure weighted sampler behind the Collectors Puzzle queue: hard filters
/// (year/genre/membership/all-targets), soft biases (♥ / play count), and
/// deterministic weighted sampling without replacement (seeded PRNG).
final class PuzzleSamplerTests: XCTestCase {

    /// IndexSong is Decodable-only — build via the JSON round-trip (the `minimal` pattern).
    private func song(_ id: String, year: Int? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": "A"]
        if let year { obj["year"] = year }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    private func inputs(songs: [IndexSong],
                        genres: [String: String] = [:],
                        favorites: Set<String> = [],
                        playCounts: [String: Int] = [:],
                        membershipUnion: Set<String> = [],
                        perTarget: [Set<String>] = []) -> PuzzleSampler.Inputs {
        PuzzleSampler.Inputs(songs: songs, genreBySongId: genres, favoriteIds: favorites,
                             playCounts: playCounts, membershipUnion: membershipUnion,
                             perTargetMembership: perTarget)
    }

    func testYearRangeHardFilter() {
        var settings = PuzzleSettings()
        settings.yearMin = 1990
        settings.yearMax = 1999
        let pool = PuzzleSampler.pool(settings: settings, inputs: inputs(songs: [
            song("a", year: 1980), song("b", year: 1995), song("c", year: 2005),
        ]))
        XCTAssertEqual(pool.map(\.song.id), ["b"])
    }

    func testNilYearDropsOnlyWhenBoundSet() {
        let songs = [song("dated", year: 1995), song("undated")]
        var open = PuzzleSettings()
        XCTAssertEqual(PuzzleSampler.poolCount(settings: open, inputs: inputs(songs: songs)), 2,
                       "no bound ⇒ nil-year songs stay")
        open.yearMin = 1990
        let pool = PuzzleSampler.pool(settings: open, inputs: inputs(songs: songs))
        XCTAssertEqual(pool.map(\.song.id), ["dated"], "any bound ⇒ nil-year songs drop")
    }

    func testGenreCategoryFilter() {
        var settings = PuzzleSettings()
        settings.genreCategories = ["hip-hop"]
        let songs = [song("h"), song("j"), song("x")]
        let genres = ["h": "hip-hop", "j": "jazz"]   // "x" unmapped → Other
        let pool = PuzzleSampler.pool(settings: settings, inputs: inputs(songs: songs, genres: genres))
        XCTAssertEqual(pool.map(\.song.id), ["h"])
    }

    func testMembershipInAny() {
        var settings = PuzzleSettings()
        settings.membershipMode = .inAny
        settings.membershipCollectionIds = ["pkt_x"]
        let pool = PuzzleSampler.pool(settings: settings,
                                      inputs: inputs(songs: [song("in"), song("out")],
                                                     membershipUnion: ["in"]))
        XCTAssertEqual(pool.map(\.song.id), ["in"])
    }

    func testMembershipNotInAny() {
        var settings = PuzzleSettings()
        settings.membershipMode = .notInAny
        settings.membershipCollectionIds = ["pkt_x"]
        let pool = PuzzleSampler.pool(settings: settings,
                                      inputs: inputs(songs: [song("in"), song("out")],
                                                     membershipUnion: ["in"]))
        XCTAssertEqual(pool.map(\.song.id), ["out"], "not-in is the intentional none-of")
    }

    func testExcludesSongsInAllTargets() {
        let settings = PuzzleSettings()
        // "both" is in EVERY target (nothing left to assign); "one" is in only one.
        let pool = PuzzleSampler.pool(settings: settings,
                                      inputs: inputs(songs: [song("both"), song("one"), song("none")],
                                                     perTarget: [["both", "one"], ["both"]]))
        XCTAssertEqual(Set(pool.map(\.song.id)), ["one", "none"],
                       "a song already in one of several targets can still be assigned to the others")
    }

    func testFavoriteFavorRaisesSelectionShare() {
        var settings = PuzzleSettings()
        settings.favoriteBias = .favor
        let songs = (0..<1000).map { song("s\($0)") }
        let favorites = Set((0..<500).map { "s\($0)" })
        let rng = PRNG.seededRng("test")
        let picked = PuzzleSampler.sample(500, settings: settings,
                                          inputs: inputs(songs: songs, favorites: favorites),
                                          rng: rng)
        XCTAssertEqual(picked.count, 500)
        let favShare = Double(picked.filter { favorites.contains($0.id) }.count) / 500
        XCTAssertGreaterThan(favShare, 0.65, "♥ ×4 weight dominates a 50/50 pool (got \(favShare))")
    }

    func testPlayCountAvoidPrefersUnplayed() {
        var settings = PuzzleSettings()
        settings.playCountBias = .avoid
        let songs = (0..<200).map { song("s\($0)") }
        // First 100 heavily played, last 100 never played.
        var counts: [String: Int] = [:]
        for i in 0..<100 { counts["s\(i)"] = 50 }
        let rng = PRNG.seededRng("avoid")
        let picked = PuzzleSampler.sample(60, settings: settings,
                                          inputs: inputs(songs: songs, playCounts: counts),
                                          rng: rng)
        let unplayedShare = Double(picked.filter { counts[$0.id] == nil }.count) / 60
        XCTAssertGreaterThan(unplayedShare, 0.8,
                             "never-played ×4 vs played ×1/(1+log2(51)) ⇒ unplayed dominates (got \(unplayedShare))")
    }

    func testSampleWithoutReplacementNoDuplicates() {
        let songs = (0..<60).map { song("s\($0)") }
        let picked = PuzzleSampler.sample(50, settings: PuzzleSettings(),
                                          inputs: inputs(songs: songs),
                                          rng: PRNG.seededRng("dupes"))
        XCTAssertEqual(picked.count, 50)
        XCTAssertEqual(Set(picked.map(\.id)).count, 50, "without replacement — no repeats")
        // Asking for more than the pool yields exactly the pool.
        let all = PuzzleSampler.sample(100, settings: PuzzleSettings(),
                                       inputs: inputs(songs: songs),
                                       rng: PRNG.seededRng("dupes"))
        XCTAssertEqual(Set(all.map(\.id)).count, 60)
        // `excluding` is the top-up dedup.
        let topped = PuzzleSampler.sample(100, settings: PuzzleSettings(),
                                          inputs: inputs(songs: songs),
                                          rng: PRNG.seededRng("dupes"),
                                          excluding: Set((0..<50).map { "s\($0)" }))
        XCTAssertEqual(Set(topped.map(\.id)), Set((50..<60).map { "s\($0)" }))
    }

    func testDeterministicWithSeed() {
        let songs = (0..<100).map { song("s\($0)") }
        var settings = PuzzleSettings()
        settings.favoriteBias = .favor
        let favorites = Set((0..<30).map { "s\($0)" })
        let a = PuzzleSampler.sample(40, settings: settings,
                                     inputs: inputs(songs: songs, favorites: favorites),
                                     rng: PRNG.seededRng("seed-x"))
        let b = PuzzleSampler.sample(40, settings: settings,
                                     inputs: inputs(songs: songs, favorites: favorites),
                                     rng: PRNG.seededRng("seed-x"))
        XCTAssertEqual(a.map(\.id), b.map(\.id), "same seed ⇒ same draw")
    }
}
