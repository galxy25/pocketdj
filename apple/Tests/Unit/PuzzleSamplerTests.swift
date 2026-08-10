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
                        perTarget: [Set<String>] = [],
                        recencies: [String: Double] = [:]) -> PuzzleSampler.Inputs {
        PuzzleSampler.Inputs(songs: songs, genreBySongId: genres, favoriteIds: favorites,
                             playCounts: playCounts, membershipUnion: membershipUnion,
                             perTargetMembership: perTarget,
                             recencies: recencies, hasRecency: !recencies.isEmpty)
    }

    /// Build the DERIVED recency map the way `Inputs(raw:)` does, from raw dates — so these tests
    /// exercise the same decay the app runs rather than hand-picked scores.
    private func recencies(_ lastPlayedMs: [String: Double], nowMs: Double) -> [String: Double] {
        lastPlayedMs.compactMapValues { ms -> Double? in
            let r = PlayRecency.score(lastPlayedMs: ms, nowMs: nowMs)
            return r > 0 ? r : nil
        }
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

    // MARK: - Recency bias (the second play axis)

    private static let now: Double = 1_700_000_000_000
    private static let day: Double = 86_400_000

    /// `.favor` must measurably shift the sampled distribution toward recently-played songs.
    func testRecencyFavorRaisesRecentShare() {
        var settings = PuzzleSettings()
        settings.recencyBias = .favor
        let songs = (0..<200).map { song("s\($0)") }
        // First 100 played in the last month, last 100 not for six years.
        var dates: [String: Double] = [:]
        for i in 0..<100 { dates["s\(i)"] = Self.now - 10 * Self.day }
        for i in 100..<200 { dates["s\(i)"] = Self.now - 2190 * Self.day }
        let picked = PuzzleSampler.sample(
            60, settings: settings,
            inputs: inputs(songs: songs, recencies: recencies(dates, nowMs: Self.now)),
            rng: PRNG.seededRng("recent"))
        let recentShare = Double(picked.filter { Int($0.id.dropFirst()) ?? 0 < 100 }.count) / 60
        XCTAssertGreaterThan(recentShare, 0.7,
                             "fresh ×~9 vs six-year-old ×~1.6 ⇒ recent dominates (got \(recentShare))")
    }

    /// `.avoid` must shift it the other way — and a NEVER-played song (no date at all) is the
    /// most "not played lately" a song can be, so it gets the flat boost.
    func testRecencyAvoidPrefersLongUnplayedAndNeverPlayed() {
        var settings = PuzzleSettings()
        settings.recencyBias = .avoid
        let songs = (0..<200).map { song("s\($0)") }
        var dates: [String: Double] = [:]
        for i in 0..<100 { dates["s\(i)"] = Self.now - 5 * Self.day }   // played this week
        // s100…s199 have NO date at all — never played.
        let picked = PuzzleSampler.sample(
            60, settings: settings,
            inputs: inputs(songs: songs, recencies: recencies(dates, nowMs: Self.now)),
            rng: PRNG.seededRng("avoid-recent"))
        let staleShare = Double(picked.filter { Int($0.id.dropFirst()) ?? 0 >= 100 }.count) / 60
        XCTAssertGreaterThan(staleShare, 0.8,
                             "never-played ×4 vs fresh ×1/9 ⇒ stale dominates (got \(staleShare))")
    }

    /// THE SEPARABILITY CONTRACT. Two songs differing on exactly ONE axis must be ordered by that
    /// axis — and the order must FLIP when the other bias is selected. A design that collapsed
    /// plays and recency into one score cannot satisfy both halves of this test.
    func testPlaysAndRecencyAreSeparableAxes() {
        let heavyOld = song("heavy-old")      // 200 plays, last touched 5 years ago
        let lightNew = song("light-new")      // 1 play, yesterday
        let counts = ["heavy-old": 200, "light-new": 1]
        let dates = ["heavy-old": Self.now - 1825 * Self.day, "light-new": Self.now - 1 * Self.day]
        let recs = recencies(dates, nowMs: Self.now)
        let weightOf = { (settings: PuzzleSettings, id: String) -> Double in
            PuzzleSampler.pool(settings: settings,
                               inputs: self.inputs(songs: [heavyOld, lightNew],
                                                   playCounts: counts, recencies: recs))
                .first { $0.song.id == id }?.weight ?? 0
        }
        var byPlays = PuzzleSettings(); byPlays.playCountBias = .favor
        XCTAssertGreaterThan(weightOf(byPlays, "heavy-old"), weightOf(byPlays, "light-new"),
                             "on the PLAYS axis the heavily-played song wins")

        var byRecency = PuzzleSettings(); byRecency.recencyBias = .favor
        XCTAssertGreaterThan(weightOf(byRecency, "light-new"), weightOf(byRecency, "heavy-old"),
                             "on the RECENCY axis the order flips — the axes are independent")

        // And they COMPOSE: both on at once is neither one alone.
        var both = PuzzleSettings()
        both.playCountBias = .favor
        both.recencyBias = .favor
        XCTAssertNotEqual(weightOf(both, "heavy-old"), weightOf(byPlays, "heavy-old"), accuracy: 0.0001)
    }

    /// The compatibility contract: an EMPTY recency map leaves the sample byte-identical to what
    /// the shipped build produces, whatever the bias is set to. This is what makes the feature
    /// safe on a device with no Apple baseline.
    func testEmptyRecencyMapLeavesTheSampleUnchanged() {
        let songs = (0..<200).map { song("s\($0)") }
        var counts: [String: Int] = [:]
        for i in 0..<100 { counts["s\(i)"] = 20 }
        var base = PuzzleSettings()
        base.playCountBias = .favor
        let shipped = PuzzleSampler.sample(60, settings: base,
                                           inputs: inputs(songs: songs, playCounts: counts),
                                           rng: PRNG.seededRng("compat")).map(\.id)
        for bias in [PuzzleSettings.Bias.favor, .avoid] {
            var withBias = base
            withBias.recencyBias = bias
            let out = PuzzleSampler.sample(60, settings: withBias,
                                           inputs: inputs(songs: songs, playCounts: counts),
                                           rng: PRNG.seededRng("compat")).map(\.id)
            XCTAssertEqual(out, shipped,
                           "recencyBias .\(bias) with no dates must be a uniform scale, not a reordering")
        }
    }

    /// …and the pre-existing play-count bias is untouched by the new one being present but off.
    func testPlayCountBiasIsUnaffectedByTheRecencyAxisBeingOff() {
        var settings = PuzzleSettings()
        settings.playCountBias = .favor
        XCTAssertEqual(settings.recencyBias, .off, "the new axis defaults off")
        let songs = (0..<50).map { song("s\($0)") }
        var counts: [String: Int] = [:]
        for i in 0..<25 { counts["s\(i)"] = 30 }
        let dates = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, Self.now - 400 * Self.day) })
        // Supplying dates must change NOTHING while the recency bias is off.
        let without = PuzzleSampler.pool(settings: settings,
                                         inputs: inputs(songs: songs, playCounts: counts))
        let with = PuzzleSampler.pool(settings: settings,
                                      inputs: inputs(songs: songs, playCounts: counts,
                                                     recencies: recencies(dates, nowMs: Self.now)))
        XCTAssertEqual(without.map(\.song.id), with.map(\.song.id))
        for (a, b) in zip(without, with) { XCTAssertEqual(a.weight, b.weight, accuracy: 1e-12) }
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

    /// The main actor hands over RAW containers only; the ~96k-row genre map + the
    /// membership Sets are built here, off-main.
    func testInputsFromRawBuildsTheDerivedStructures() {
        let s1 = songInAlbum("s1", albumId: "alb_rock")
        let s2 = songInAlbum("s2", albumId: "alb_jazz")
        let s3 = songInAlbum("s3", albumId: nil)     // album-less songs get no genre entry
        let raw = PuzzleSampler.RawInputs(
            songs: [s1, s2, s3],
            albumsById: ["alb_rock": album("alb_rock", genre: "Classic Rock"),
                         "alb_jazz": album("alb_jazz", genre: "Bebop Jazz")],
            favoriteIds: ["s1"], playCounts: ["s2": 3],
            membershipCollections: [["s1", "s2"], ["s2", "s3"]],
            targetCollections: [["s1"], ["s2", "s3"]])
        let built = PuzzleSampler.Inputs(raw: raw)
        XCTAssertEqual(built.songs.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(built.genreBySongId["s1"], Genre.category("Classic Rock"))
        XCTAssertEqual(built.genreBySongId["s2"], Genre.category("Bebop Jazz"))
        XCTAssertNil(built.genreBySongId["s3"])
        XCTAssertEqual(built.membershipUnion, ["s1", "s2", "s3"], "membership collections UNION")
        XCTAssertEqual(built.perTargetMembership, [["s1"], ["s2", "s3"]])
        XCTAssertEqual(built.favoriteIds, ["s1"])
        XCTAssertEqual(built.playCounts, ["s2": 3])
        // …and the pool it feeds matches a hand-built Inputs exactly.
        var settings = PuzzleSettings()
        settings.genreCategories = [Genre.category("Classic Rock")]
        XCTAssertEqual(PuzzleSampler.poolCount(settings: settings, inputs: built), 1)
    }

    private func songInAlbum(_ id: String, albumId: String?) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id, "artist": "A"]
        if let albumId { obj["albumId"] = albumId }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    private func album(_ id: String, genre: String) -> IndexAlbum {
        let obj: [String: Any] = ["id": id, "artist": "A", "name": id, "genre": genre,
                                  "trackList": []]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }
}
