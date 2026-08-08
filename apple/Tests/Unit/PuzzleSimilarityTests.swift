import XCTest
@testable import PocketDJ

/// Gem Collector's LOCAL-FIRST similarity ranker: the profile built from the target
/// collections, the six-signal score, and the shortlist that actually changes what the player
/// sees.
///
/// These assert on RANKING BEHAVIOUR — that a song sharing an artist / genre / era / crate /
/// listening session with the targets ends up ABOVE an unrelated one — not merely that a
/// function returned something. A ranker that returned its input unchanged would pass "it
/// returned N rows"; it fails every test below.
final class PuzzleSimilarityTests: XCTestCase {

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String = "A", year: Int? = nil,
                      keywords: [String]? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        if let keywords { obj["sentimentKeywords"] = keywords }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    private func candidates(_ songs: [IndexSong]) -> [(song: IndexSong, weight: Double)] {
        songs.map { (song: $0, weight: 1.0) }
    }

    private func profile(members: [IndexSong],
                         genres: [String: String] = [:],
                         otherCollections: [[String]] = [],
                         plays: [(songId: String, atMs: Double)] = [],
                         catalog: [IndexSong] = []) -> PuzzleSimilarity.TargetProfile {
        let all = catalog.isEmpty ? members : catalog
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PuzzleSimilarity.profile(targetMemberIds: [members.map(\.id)],
                                        songsById: byId, genreBySongId: genres,
                                        otherCollections: otherCollections, plays: plays)
    }

    // MARK: - The no-targets guarantee

    /// The change-B contract: with no targets (or targets that resolve to nothing on this
    /// device) similarity is a strict identity — a target-less round samples EXACTLY as the
    /// shipped game does.
    func testEmptyProfileIsIdentity() {
        let rows = candidates([song("a"), song("b"), song("c")])
        let empty = PuzzleSimilarity.TargetProfile()
        XCTAssertTrue(empty.isEmpty)
        let out = PuzzleSimilarity.shortlist(rows, profile: empty, genreBySongId: [:],
                                             mode: .on, wanted: 60)
        XCTAssertEqual(out.map(\.song.id), ["a", "b", "c"], "same rows, same order")
        XCTAssertEqual(out.map(\.weight), [1, 1, 1], "…and untouched weights")
    }

    /// …and so is `.off` with a perfectly good profile: the "Anything" picker option must be
    /// able to give the player the old game back.
    func testOffModeIsIdentityEvenWithARealProfile() {
        let target = song("t1", artist: "Chromatics", year: 1994)
        let p = profile(members: [target])
        XCTAssertFalse(p.isEmpty)
        let rows = candidates([song("x", artist: "Nobody", year: 2020),
                               song("y", artist: "Chromatics", year: 1994)])
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             mode: .off, wanted: 60)
        XCTAssertEqual(out.map(\.song.id), ["x", "y"], "OFF must not reorder anything")
    }

    // MARK: - The six signals, each proven to MOVE the ranking

    func testArtistRanksAboveUnrelated() {
        let p = profile(members: [song("t1", artist: "Chromatics")])
        let rows = candidates([song("stranger", artist: "Nobody At All"),
                               song("same-artist", artist: "Chromatics")])
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             mode: .on, wanted: 60)
        XCTAssertEqual(out.first?.song.id, "same-artist",
                       "a song by an artist already in the crate ranks first")
        XCTAssertGreaterThan(PuzzleSimilarity.score(rows[1].song, profile: p, genre: nil), 0.9,
                             "artist is the ONLY available term here ⇒ it saturates the score")
        XCTAssertEqual(PuzzleSimilarity.score(rows[0].song, profile: p, genre: nil), 0,
                       "…and an unrelated artist scores nothing on it")
    }

    /// Artist matching is normalized: "The Chromatics" and "chromatics" are one artist.
    func testArtistKeyIsCaseDiacriticAndLeadingTheInsensitive() {
        XCTAssertEqual(PuzzleSimilarity.artistKey("The Chromatics"),
                       PuzzleSimilarity.artistKey("chromatics"))
        XCTAssertEqual(PuzzleSimilarity.artistKey("Beyoncé"), PuzzleSimilarity.artistKey("BEYONCE"))
        XCTAssertNotEqual(PuzzleSimilarity.artistKey("Portishead"),
                          PuzzleSimilarity.artistKey("Radiohead"))
    }

    func testGenreRanksAboveUnrelated() {
        let members = [song("t1"), song("t2")]
        let genres = ["t1": "hip-hop", "t2": "hip-hop", "hh": "hip-hop", "country": "country"]
        let p = profile(members: members, genres: genres)
        let rows = candidates([song("country", artist: "X"), song("hh", artist: "Y")])
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: genres,
                                             mode: .on, wanted: 60)
        XCTAssertEqual(out.first?.song.id, "hh", "the same-genre song ranks first")
        XCTAssertGreaterThan(PuzzleSimilarity.score(rows[1].song, profile: p, genre: "hip-hop"),
                             PuzzleSimilarity.score(rows[0].song, profile: p, genre: "country"))
    }

    func testYearDecayRanksTheNearerEraHigher() {
        let p = profile(members: [song("t1", year: 1994), song("t2", year: 1994)])
        let near = song("near", artist: "Q", year: 1995)
        let far = song("far", artist: "Q", year: 1975)
        let none = song("undated", artist: "Q")
        let sNear = PuzzleSimilarity.score(near, profile: p, genre: nil)
        let sFar = PuzzleSimilarity.score(far, profile: p, genre: nil)
        let sNone = PuzzleSimilarity.score(none, profile: p, genre: nil)
        XCTAssertGreaterThan(sNear, sFar, "1995 beats 1975 against a 1994-centred crate")
        XCTAssertGreaterThan(sFar, 0, "…and 1975 is still a candidate, not excluded")
        XCTAssertLessThan(sNone, sNear, "a nil year scores 0 on that term")
        // Every one of them shares the members' artist, so nobody is excluded outright.
        let out = PuzzleSimilarity.shortlist(candidates([far, none, near]), profile: p,
                                             genreBySongId: [:], mode: .on, wanted: 60)
        XCTAssertEqual(out.first?.song.id, "near")
    }

    func testCoMembershipAndCoPlayTerms() {
        let members = [song("t1")]
        // "shared" lives in ANOTHER pocket alongside the target member; "loner" doesn't.
        let p = profile(members: members,
                        otherCollections: [["t1", "shared"], ["loner-elsewhere"]],
                        plays: [(songId: "t1", atMs: 1_000_000),
                                (songId: "recent", atMs: 1_000_000 + 10 * 60 * 1000),
                                (songId: "later", atMs: 1_000_000 + 3 * 60 * 60 * 1000)])
        XCTAssertTrue(p.coMemberIds.contains("shared"))
        XCTAssertFalse(p.coMemberIds.contains("loner"))
        XCTAssertEqual(p.coPlayCount["recent"], 1, "played 10 min after a member ⇒ an edge")
        XCTAssertNil(p.coPlayCount["later"], "played 3 h after ⇒ no edge")

        let shared = song("shared", artist: "Z")
        let recent = song("recent", artist: "Z")
        let loner = song("loner", artist: "Z")
        XCTAssertGreaterThan(PuzzleSimilarity.score(shared, profile: p, genre: nil),
                             PuzzleSimilarity.score(loner, profile: p, genre: nil),
                             "sharing a crate with a member beats sharing nothing")
        XCTAssertGreaterThan(PuzzleSimilarity.score(recent, profile: p, genre: nil),
                             PuzzleSimilarity.score(loner, profile: p, genre: nil),
                             "being played alongside a member beats sharing nothing")
        // Co-membership (0.12) outranks co-play (0.08) — the user PUT those two in one crate.
        XCTAssertGreaterThan(PuzzleSimilarity.score(shared, profile: p, genre: nil),
                             PuzzleSimilarity.score(recent, profile: p, genre: nil))
    }

    /// The lyrical signal, on the only catalog that actually carries it (vinyl:
    /// `sentimentKeywords` covers 12,523 of 12,525 there and 0 of 96,020 Apple Music rows).
    func testLyricalKeywordsRankAboveUnrelatedWhenPresent() {
        let members = [song("t1", keywords: ["melancholy", "rain", "night"]),
                       song("t2", keywords: ["melancholy", "night"])]
        let p = profile(members: members)
        XCTAssertFalse(p.keywordShare.isEmpty, "the profile speaks the lyrical term")
        let moody = song("moody", artist: "Q", keywords: ["melancholy", "night"])
        let sunny = song("sunny", artist: "Q", keywords: ["party", "sunshine"])
        XCTAssertGreaterThan(PuzzleSimilarity.score(moody, profile: p, genre: nil),
                             PuzzleSimilarity.score(sunny, profile: p, genre: nil))
    }

    // MARK: - The sparse-feature guard (the classic bug this design avoids)

    /// THE DENOMINATOR IS PROFILE-LEVEL, never per-song. A per-song denominator rewards songs
    /// with MISSING metadata (fewer terms = higher average), which — against an 11.6%-covered
    /// lyrics field — would have systematically promoted the songs we know least about.
    ///
    /// Proven two ways: (a) a profile with NO keywords scores a keyword-bearing and a
    /// keyword-less song identically on the other terms; (b) against a profile that DOES speak
    /// keywords, a song missing them is not silently promoted.
    func testProfileLevelDenominatorDoesNotRewardMissingMetadata() {
        let p = profile(members: [song("t1", artist: "Chromatics", year: 1994)])
        XCTAssertTrue(p.keywordShare.isEmpty, "precondition: the profile has no lyrical term")
        XCTAssertEqual(p.availableWeight, PuzzleSimilarity.wArtist + PuzzleSimilarity.wYear,
                       accuracy: 0.0001,
                       "only the terms the PROFILE can speak are in the denominator")
        let bare = song("bare", artist: "Chromatics", year: 1994)
        let rich = song("rich", artist: "Chromatics", year: 1994,
                        keywords: ["melancholy", "rain"])
        XCTAssertEqual(PuzzleSimilarity.score(bare, profile: p, genre: nil),
                       PuzzleSimilarity.score(rich, profile: p, genre: nil), accuracy: 0.0001,
                       "a signal the profile can't speak must not score EITHER song")

        // And with a keyword-speaking profile, the keyword-less song simply misses that term.
        let kp = profile(members: [song("t1", artist: "Chromatics", year: 1994,
                                        keywords: ["melancholy", "rain"])])
        XCTAssertGreaterThan(PuzzleSimilarity.score(rich, profile: kp, genre: nil),
                             PuzzleSimilarity.score(bare, profile: kp, genre: nil),
                             "missing metadata is never an advantage")
    }

    // MARK: - The shortlist itself

    /// A shortlist must never be able to starve a round — this is the fallback doctrine the
    /// whole sampler is built on.
    func testShortlistNeverStarves() {
        let p = profile(members: [song("t1", artist: "Nobody Else", year: 1900)])
        // 50 candidates that match the profile on nothing at all.
        let rows = candidates((0..<50).map { song("s\($0)", artist: "Other \($0)") })
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             mode: .on, wanted: 60)
        XCTAssertGreaterThanOrEqual(out.count, 30, "topped up to max(20, wanted/2)")
        XCTAssertEqual(Set(out.map(\.song.id)).count, out.count, "…without duplicating a row")
    }

    func testStrictModeDropsWeakMatchesThenTopsUp() {
        let members = [song("t1", artist: "Chromatics", year: 1994)]
        let p = profile(members: members)
        var rows = candidates([song("strong", artist: "Chromatics", year: 1994)])
        rows += candidates((0..<40).map { song("weak\($0)", artist: "Other \($0)") })
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             mode: .strict, wanted: 60)
        XCTAssertEqual(out.first?.song.id, "strong", "the real match still leads")
        XCTAssertGreaterThanOrEqual(out.count, 20, "strict still can't starve the round")
    }

    /// The shortlist is a real RESTRICTION, not a cosmetic weight tweak — that is the whole
    /// reason for the top-K (a `weight × (1 + s·sim)` multiplier over a 96k pool would move
    /// ~2% of picks).
    func testShortlistActuallyRestrictsALargePool() {
        let members = (0..<5).map { song("t\($0)", artist: "Chromatics", year: 1994) }
        let p = profile(members: members)
        var rows = candidates((0..<20).map { song("hit\($0)", artist: "Chromatics", year: 1994) })
        rows += candidates((0..<5000).map { song("miss\($0)", artist: "Other \($0)") })
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             mode: .on, wanted: 60)
        XCTAssertLessThan(out.count, 600, "5,020 candidates shortlist to the top-K, not to all")
        XCTAssertEqual(Set(out.prefix(20).map(\.song.id)), Set((0..<20).map { "hit\($0)" }),
                       "every genuine match is in the top 20")
    }

    /// Existing soft weights (♥ bias, play-count bias) survive as the WITHIN-shortlist
    /// ordering — "favour favourites" must still favour favourites among the similar set.
    func testExistingWeightsSurviveInsideTheShortlist() {
        let p = profile(members: [song("t1", artist: "Chromatics")])
        let plain = (song: song("plain", artist: "Chromatics"), weight: 1.0)
        let hearted = (song: song("hearted", artist: "Chromatics"), weight: 4.0)
        let out = PuzzleSimilarity.shortlist([plain, hearted], profile: p, genreBySongId: [:],
                                             mode: .on, wanted: 60)
        let byId = Dictionary(out.map { ($0.song.id, $0.weight) }, uniquingKeysWith: { a, _ in a })
        XCTAssertGreaterThan(byId["hearted"] ?? 0, byId["plain"] ?? 0,
                             "the ♥ multiplier is preserved multiplicatively")
    }

    // MARK: - The cloud booster

    /// The cloud can only RAISE a score, and only for songs the LOCAL pool already contains —
    /// it can never smuggle an unknown, filtered-out, or unplayable song into a timed round,
    /// because it is applied to the candidate list, not to the catalog.
    func testCloudRanksOnlyReorderSongsAlreadyInThePool() {
        let p = profile(members: [song("t1", artist: "Chromatics")])
        let rows = candidates([song("known-a", artist: "Zed"), song("known-b", artist: "Zed")])
        let cloud = ["ghost-not-in-catalog": 1.0, "known-b": 1.0]
        let out = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                             cloudRanks: cloud, mode: .on, wanted: 60)
        XCTAssertFalse(out.contains { $0.song.id == "ghost-not-in-catalog" },
                       "a cloud id that is not a candidate cannot enter the round")
        XCTAssertEqual(out.first?.song.id, "known-b", "…but it can lift one that IS")
    }

    /// The cloud is a pure BONUS — it can only lift, never lower, and a cloud hit on an
    /// already-similar song can never push it past 1.
    func testCloudRankCanOnlyRaiseAScore() {
        let p = profile(members: [song("t1", artist: "Chromatics", year: 1994)])
        let match = song("m", artist: "Chromatics", year: 1994)
        let stranger = song("s", artist: "Other", year: 1930)
        for (s, name) in [(match, "match"), (stranger, "stranger")] {
            let bare = PuzzleSimilarity.score(s, profile: p, genre: nil, cloudRank: 0)
            let lifted = PuzzleSimilarity.score(s, profile: p, genre: nil, cloudRank: 1)
            XCTAssertGreaterThanOrEqual(lifted, bare, "\(name): the cloud never lowers a score")
            XCTAssertLessThanOrEqual(lifted, 1.0, "\(name): and never exceeds 1")
        }
    }

    /// Turning the cloud OFF changes nothing about the LOCAL score — with `cloudRank == 0` the
    /// result is EXACTLY the local score, not a scaled one. This is the property that makes the
    /// app safe to ship before the `/recs/similar` route is deployed.
    func testCloudOffProducesTheSameOrderAsAnEmptyCloudMap() {
        let p = profile(members: [song("t1", artist: "Chromatics", year: 1994)])
        let rows = candidates([song("a", artist: "Other", year: 1970),
                               song("b", artist: "Chromatics", year: 1994),
                               song("c", artist: "Other", year: 1993)])
        let withoutCloud = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                                      mode: .on, wanted: 60)
        let withEmptyCloud = PuzzleSimilarity.shortlist(rows, profile: p, genreBySongId: [:],
                                                        cloudRanks: [:], mode: .on, wanted: 60)
        XCTAssertEqual(withoutCloud.map(\.song.id), withEmptyCloud.map(\.song.id))
        XCTAssertEqual(withoutCloud.map(\.song.id), ["b", "c", "a"],
                       "local ordering: same artist+era, then near era, then neither")
    }

    // MARK: - Composition with the sampler (playability stays the OUTER gate)

    /// The load-bearing composition claim: similarity ranks only what already passed the
    /// playable-now filter, so a similar-but-silent song can never take a playable one's slot.
    func testSimilarityNeverAdmitsAnUnplayableSong() {
        // The SIMILAR songs are unplayable; the PLAYABLE ones are dissimilar.
        let members = [song("t1", artist: "Chromatics", year: 1994)]
        let similarSilent = (0..<5).map { song("silent\($0)", artist: "Chromatics", year: 1994) }
        let dissimilarLoud = (0..<5).map { song("loud\($0)", artist: "Other \($0)", year: 2020) }
        let all = members + similarSilent + dissimilarLoud
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let p = PuzzleSimilarity.profile(targetMemberIds: [members.map(\.id)], songsById: byId,
                                         genreBySongId: [:], otherCollections: [], plays: [])
        var settings = PuzzleSettings()
        settings.targetCollectionIds = ["pkt_t"]
        let inputs = PuzzleSampler.Inputs(
            songs: similarSilent + dissimilarLoud, genreBySongId: [:], favoriteIds: [],
            playCounts: [:], membershipUnion: [], perTargetMembership: [Set(members.map(\.id))],
            playableNowIds: Set(dissimilarLoud.map(\.id)), canStreamAppleMusic: false,
            similarityProfile: p)
        let pool = PuzzleSampler.pool(settings: settings, inputs: inputs)
        XCTAssertFalse(pool.isEmpty, "the playable pass is non-empty, so no whole-catalog fallback")
        XCTAssertTrue(pool.allSatisfy { $0.song.id.hasPrefix("loud") },
                      "similarity may reorder the playable set — never reintroduce a silent song")
    }

    /// …and the sample stays deterministic under a seeded RNG, similarity and all.
    func testSeededSampleIsDeterministic() {
        let members = [song("t1", artist: "Chromatics", year: 1994)]
        let catalog = (0..<200).map {
            song("s\($0)", artist: $0 % 3 == 0 ? "Chromatics" : "Other \($0)", year: 1990 + $0 % 20)
        }
        let byId = Dictionary((members + catalog).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let p = PuzzleSimilarity.profile(targetMemberIds: [members.map(\.id)], songsById: byId,
                                         genreBySongId: [:], otherCollections: [], plays: [])
        let inputs = PuzzleSampler.Inputs(songs: catalog, genreBySongId: [:], favoriteIds: [],
                                          playCounts: [:], membershipUnion: [],
                                          perTargetMembership: [Set(members.map(\.id))],
                                          similarityProfile: p)
        let settings = PuzzleSettings()
        let a = PuzzleSampler.sample(30, settings: settings, inputs: inputs,
                                     rng: PRNG.seededRng("sim"))
        let b = PuzzleSampler.sample(30, settings: settings, inputs: inputs,
                                     rng: PRNG.seededRng("sim"))
        XCTAssertEqual(a.map(\.id), b.map(\.id), "same seed ⇒ same queue")
        // And the round is visibly biased toward the crate's artist.
        let sameArtist = a.filter { $0.artist == "Chromatics" }.count
        XCTAssertGreaterThan(Double(sameArtist) / Double(a.count), 0.4,
                             "a similar-drawn round is dominated by the crate's artist "
                             + "(got \(sameArtist)/\(a.count)) — an unranked pool gives ~1/3")
    }

    // MARK: - Settings

    /// The new field is ADDITIVE and lenient-decoded: a settings blob written by the shipped
    /// build (no `similarity` key) loads with the default. That IS the migration — no version
    /// bump, no migration step.
    func testSettingsDecodeWithoutTheSimilarityKey() throws {
        let json = """
        { "roundSeconds": 180, "playCountBias": "off", "favoriteBias": "off",
          "genreCategories": [], "membershipMode": "off", "membershipCollectionIds": [],
          "targetCollectionIds": ["pkt_a"] }
        """
        let s = try JSONDecoder().decode(PuzzleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.similarity, .on)
        XCTAssertEqual(s.roundSeconds, 180)
        XCTAssertEqual(s.targetCollectionIds, ["pkt_a"])
    }

    /// `summaryLine` is written into every RunRecord and decision row — with no targets it
    /// must read "free file", never "0 targets".
    func testSummaryLineNamesTheFreeFileMode() {
        var s = PuzzleSettings()
        XCTAssertTrue(s.summaryLine.contains("free file"), s.summaryLine)
        XCTAssertFalse(s.summaryLine.contains("0 targets"), s.summaryLine)
        s.targetCollectionIds = ["pkt_a"]
        XCTAssertTrue(s.summaryLine.contains("1 target"), s.summaryLine)
        XCTAssertFalse(s.summaryLine.contains("similar"), "the default mode stays unsaid")
        s.similarity = .strict
        XCTAssertTrue(s.summaryLine.contains("similar+"), s.summaryLine)
        s.similarity = .off
        XCTAssertTrue(s.summaryLine.contains("any"), s.summaryLine)
    }
}
