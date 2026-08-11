import XCTest
@testable import PocketDJ

/// THE THREE-FAMILY REBALANCE — artist · genre+year · genre+bpm+key.
///
/// What these tests are guarding is not "does it compute a number". It is that the rebalance
/// actually rebalances, and that it does so without any of the four ways this kind of change goes
/// quietly wrong:
///
///   • the families collapse into each other (three votes that are really one),
///   • a song with missing bpm/key is BURIED (scored 0) or REWARDED (term dropped per song),
///   • the genre families silently split on punctuation variants of the same label,
///   • Gem Collector's shipped ranking moves under a scoreboard that was recorded on the old one.
///
/// The catalog numbers quoted throughout come from `scripts/measure-similarity-families.mjs` over
/// the real 109,392-song library; `SimilarityFamilies`'s type doc carries the full table.
final class SimilarityFamiliesTests: XCTestCase {

    // ========================================================================
    // MARK: - Fixtures (IndexSong is Decodable-only — the JSON round-trip house pattern)
    // ========================================================================

    private func song(_ id: String, artist: String, year: Int? = nil,
                      bpm: Double? = nil, camelot: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// A tempo/key shape from bare lists — the tests read better than `[(bpm:camelot:weight:)]`.
    private func musical(bpms: [Double] = [], camelots: [String] = [])
        -> SimilarityFamilies.MusicalProfile {
        SimilarityFamilies.musicalProfile(
            bpms.map { (bpm: Optional($0), camelot: nil, weight: 1.0) }
            + camelots.map { (bpm: nil, camelot: Optional($0), weight: 1.0) })
    }

    // ========================================================================
    // MARK: - The balance itself
    // ========================================================================

    /// The decomposition the whole design rests on: three families whose members are MEANS are
    /// exactly four flat term weights, and genre — which appears in TWO families — ends up
    /// carrying as much total weight as artist does.
    func testEvenBalanceDecomposesToTheDocumentedTermWeights() {
        let t = SimilarityFamilies.termWeights(.even, hasGenre: true, hasYear: true,
                                               hasMusical: true, scaledTo: 1.0)
        // .even is 0.25 / 0.375 / 0.375 — "evenly" measured by EFFECT, not asserted by nominal
        // weight (see the table in `SimilarityFamilies`' type doc). genre appears in TWO families
        // so it carries B/2 + C/2.
        XCTAssertEqual(t.artist, 0.25, accuracy: 1e-9)
        XCTAssertEqual(t.genre, 0.375, accuracy: 1e-9, "genre is half of B plus half of C")
        XCTAssertEqual(t.year, 0.1875, accuracy: 1e-9)
        XCTAssertEqual(t.musical, 0.1875, accuracy: 1e-9)
        XCTAssertEqual(t.total, 1.0, accuracy: 1e-9)

        // The nominal-thirds balance is kept as a constant precisely so this comparison exists:
        // it gives artist MORE than the shipped one, which is why it is not what shipped.
        let thirds = SimilarityFamilies.termWeights(.nominalThirds, hasGenre: true, hasYear: true,
                                                    hasMusical: true, scaledTo: 1.0)
        XCTAssertEqual(thirds.artist, 1.0 / 3, accuracy: 1e-9)
        XCTAssertGreaterThan(thirds.artist, t.artist,
                             "equal thirds is MORE artist-weighted than what shipped")
        XCTAssertLessThan(thirds.year, t.year,
                          "…and it takes that weight out of year, family B's only sharp field")
    }

    /// ROUND-LEVEL renormalization: a family the profile cannot speak leaves the denominator and
    /// its weight goes to the families that remain — the total never shrinks.
    ///
    /// The total mattering is the point. If a metadata-poor device scored systematically LOWER,
    /// every absolute threshold in the app (Gem Collector's `.strict` floor, the `sim > 0` gate)
    /// would quietly be stricter for it — the same trap `hasRecency` was added to close.
    func testAFamilyTheProfileCannotSpeakLeavesTheDenominator() {
        // No tempo/key anywhere in the seed set ⇒ family C collapses to genre alone.
        let noMusic = SimilarityFamilies.termWeights(.even, hasGenre: true, hasYear: true,
                                                     hasMusical: false, scaledTo: 1.0)
        XCTAssertEqual(noMusic.musical, 0, "nothing to compare tempo against")
        XCTAssertEqual(noMusic.total, 1.0, accuracy: 1e-9, "the weight redistributes, it does not vanish")
        XCTAssertGreaterThan(noMusic.genre, 1.0 / 3, "C's whole weight lands on the one field it has")

        // No genre at all ⇒ B is year alone and C is tempo alone.
        let noGenre = SimilarityFamilies.termWeights(.even, hasGenre: false, hasYear: true,
                                                     hasMusical: true, scaledTo: 1.0)
        XCTAssertEqual(noGenre.genre, 0)
        XCTAssertEqual(noGenre.year, 0.375, accuracy: 1e-9, "family B collapses onto year alone")
        XCTAssertEqual(noGenre.musical, 0.375, accuracy: 1e-9, "…and C onto tempo/key alone")
        XCTAssertEqual(noGenre.artist, 0.25, accuracy: 1e-9)
        XCTAssertEqual(noGenre.total, 1.0, accuracy: 1e-9)

        // Artist alone (a device with nothing but names) still produces a usable total.
        let bare = SimilarityFamilies.termWeights(.even, hasGenre: false, hasYear: false,
                                                  hasMusical: false, scaledTo: 1.0)
        XCTAssertEqual(bare.artist, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bare.total, 1.0, accuracy: 1e-9)
    }

    /// The families are scaled to exactly what artist+genre+year weigh today, so switching the
    /// balance on redistributes weight AMONG the three families and does not quietly demote the
    /// four auxiliary signals (co-membership, lyrics, co-play, recency).
    func testFamilyTotalMatchesTodaysArtistGenreYearWeight() {
        XCTAssertEqual(SimilarityFamilies.familyTotal,
                       PuzzleSimilarity.wArtist + PuzzleSimilarity.wGenre + PuzzleSimilarity.wYear,
                       accuracy: 1e-9)
        let t = SimilarityFamilies.termWeights(.even, hasGenre: true, hasYear: true, hasMusical: true)
        XCTAssertEqual(t.total, SimilarityFamilies.familyTotal, accuracy: 1e-9)
        // …and artist really does lose its dominance: 0.30 of 0.70 was 43% of the family weight,
        // and it is now a third.
        XCTAssertLessThan(t.artist, PuzzleSimilarity.wArtist,
                          "the whole point: artist stops being the biggest single term")
    }

    // ========================================================================
    // MARK: - Family C's distances are DISTANCES, not equality
    // ========================================================================

    /// Camelot ADJACENCY. Exact-match on a key is nearly a no-op (24 codes ⇒ a random pair agrees
    /// 4% of the time) and it is also musically wrong: 8A→9A is the classic one-step move.
    func testCamelotMatchesNeighboursNotJustTheExactCode() {
        let p = musical(camelots: ["8A"])
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8A", p), 1.0)
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8B", p), 0.75, "relative major/minor")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("9A", p), 0.6, "one step up")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("7A", p), 0.6, "one step down")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("1A", musical(camelots: ["12A"])), 0.6,
                       "the wheel wraps")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("2A", p), 0.0,
                       "a wrong key is wrong, not slightly right")
        // Junk in, zero out — never a crash, never a false neighbour.
        for junk in ["banana", "13A", "0A", "8C", "", "A8"] {
            XCTAssertEqual(SimilarityFamilies.camelotAffinity(junk, p), 0, "junk: \(junk)")
        }
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8A", SimilarityFamilies.MusicalProfile()), 0)
        // Case and stray whitespace must not break the match — camelot codes reach the catalog
        // from several indexers.
        XCTAssertEqual(SimilarityFamilies.camelotAffinity(" 8a ", p), 1.0)
    }

    /// KEY SATURATION — a latent bug inherited from the shipped ZoneEngine, not something the
    /// rebalance introduced, and the reason the term is a DENSITY rather than set membership.
    ///
    /// Set membership can only ever return one of FOUR values (1.0 / 0.75 / 0.6 / 0) however large
    /// the seed is, so as the seed grows the mass just piles onto 1.0: measured mean affinity for a
    /// random candidate rose 0.123 (one code in the profile) → 0.488 (five) → 0.810 (twelve), at
    /// four distinct values throughout. At that point the key half of family C is a constant and
    /// family C has degenerated to genre + bpm.
    ///
    /// A density normalized by its own peak keeps the term honest: a seed that really does span
    /// the wheel scores every key ALIKE (key carries no information there, and saying so is
    /// correct) instead of scoring every key 1.0.
    func testKeyAffinityDoesNotSaturateAsTheSeedGrows() {
        let one = musical(camelots: ["8A"])
        let wide = musical(camelots: SimilarityFamilies.allCamelotCodes)

        // With ONE code the term discriminates hard: a far key scores zero.
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("2A", one), 0)
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8A", one), 1.0)

        // With the WHOLE wheel every key scores the same — the term has no opinion, and it says so
        // by being FLAT rather than by being 1.0 everywhere.
        let all = SimilarityFamilies.allCamelotCodes.map { SimilarityFamilies.camelotAffinity($0, wide) }
        XCTAssertEqual(all.max()! - all.min()!, 0, accuracy: 1e-9,
                       "a seed spanning the wheel cannot prefer one key over another")

        // And the mean over a random candidate does not run away with seed size — the property
        // the measurement above is about.
        func meanAffinity(_ codes: [String]) -> Double {
            let p = musical(camelots: codes)
            let xs = SimilarityFamilies.allCamelotCodes.map { SimilarityFamilies.camelotAffinity($0, p) }
            return xs.reduce(0, +) / Double(xs.count)
        }
        let m1 = meanAffinity(["8A"])
        let m5 = meanAffinity(["8A", "9A", "1B", "4A", "11B"])
        // Set membership would have taken this from ~0.12 to ~0.49. The density keeps it modest.
        XCTAssertLessThan(m5, 0.45, "five keys must not make the term a near-constant (was ~0.49)")
        XCTAssertGreaterThan(m5, m1, "…while still saying that a wider seed accepts more")

        // RESOLUTION is the real difference: set membership has exactly four possible answers no
        // matter how big the seed is, so it runs out of grades. The density keeps grading.
        let five = musical(camelots: ["8A", "9A", "1B", "4A", "11B"])
        let grades = Set(SimilarityFamilies.allCamelotCodes
            .map { (SimilarityFamilies.camelotAffinity($0, five) * 1000).rounded() })
        XCTAssertGreaterThan(grades.count, 4,
                             "more than the four values set membership can express: \(grades.count)")
    }

    /// HALF/DOUBLE TIME. A 140-bpm track and a 70-bpm track are the same tempo counted
    /// differently — the single most common relationship in a hip-hop/R&B library, which is 45%
    /// of this one — and the detector picks between them by heuristic.
    func testBpmMatchesTheMetricalFamilyNotJustTheLiteralNumber() {
        let p = musical(bpms: [140])
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(140, p), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(70, p), 1.0, accuracy: 1e-9,
                       "70 IS 140, counted in half time")
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(280, p), 1.0, accuracy: 1e-9)
        // 110 has no metrical relative anywhere near 140 (110 · 55 · 220 · 73 · 165).
        XCTAssertLessThan(SimilarityFamilies.bpmAffinity(110, p), 0.15,
                          "a genuinely different tempo still scores low")
        // The 2:3 pair (a 90 against a 135 profile) is a real mix too — but it is a different
        // FEEL, so it is discounted rather than treated as the same pulse. At full strength it
        // made almost every tempo a near-neighbour of almost every other.
        let threeTwo = SimilarityFamilies.bpmAffinity(90, musical(bpms: [135]))
        XCTAssertEqual(threeTwo, SimilarityFamilies.tripletStrength, accuracy: 1e-6)
        XCTAssertLessThan(threeTwo, 1.0, "a 3:2 is a weaker relationship than a half-time")
        // Absent / nonsense inputs contribute nothing rather than trapping.
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(nil, p), 0)
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(140, SimilarityFamilies.MusicalProfile()), 0)
        XCTAssertEqual(SimilarityFamilies.bpmAffinity(0, p), 0)
    }

    /// The falloff is a GRADIENT, not a tolerance window: 121 against a 120 profile must not score
    /// full marks while 122 scores nothing.
    func testBpmFalloffIsSmooth() {
        let p = musical(bpms: [120])
        let a = SimilarityFamilies.bpmAffinity(121, p)
        let b = SimilarityFamilies.bpmAffinity(126, p)
        let c = SimilarityFamilies.bpmAffinity(150, p)
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
        XCTAssertGreaterThan(b, 0.4, "six bpm out is still a near miss, not a rejection")
    }

    /// TEMPO SATURATION, the same failure as the key one and previously worse.
    ///
    /// The tempo term used to score against the seed's MEAN with the seed's own sigma. A seed drawn
    /// from a real library is multimodal — 85-bpm soul beside 140-bpm house — so its mean matches
    /// neither and its sigma (measured 22.8 on a real 25-song seed) is wide enough that every tempo
    /// in the catalog scores: the term fired above 0.1 for 100% of bpm-bearing songs.
    ///
    /// Scoring against the weighted DISTRIBUTION, in log-tempo, with a fixed perceptual width, is
    /// what restores the ability to say no — and it handles the bimodal seed correctly, which a
    /// mean cannot do by construction.
    func testTempoScoresTheDistributionNotItsMean() {
        // A genuinely bimodal listener: half the seed at 85, half at 140.
        let bimodal = musical(bpms: [85, 85, 85, 140, 140, 140])
        XCTAssertGreaterThan(SimilarityFamilies.bpmAffinity(85, bimodal), 0.9, "one real mode")
        XCTAssertGreaterThan(SimilarityFamilies.bpmAffinity(140, bimodal), 0.9, "and the other")
        // 112 is the MEAN of that seed and matches no music in it. A mean-based term would have
        // scored it top; the distribution scores it low.
        XCTAssertLessThan(SimilarityFamilies.bpmAffinity(112, bimodal), 0.35,
                          "the arithmetic mean of a bimodal seed is not a tempo the listener plays")

        // A seed with one dominant tempo and one stray outlier must still prefer the dominant one.
        let skewed = musical(bpms: [96, 96, 96, 96, 96, 170])
        XCTAssertGreaterThan(SimilarityFamilies.bpmAffinity(96, skewed),
                             SimilarityFamilies.bpmAffinity(170, skewed),
                             "a lone outlier tempo cannot score like the one being played")
    }

    // ========================================================================
    // MARK: - Genre canonicalization
    // ========================================================================

    /// The real catalog carries 613 distinct raw album-genre strings, 81 of which (34 groups) are
    /// punctuation variants of another — "Hip-Hop/Rap" (21,166 songs) and "Hip Hop/Rap" (1,980)
    /// are the biggest pair. Families keyed on raw labels would silently split them.
    func testPunctuationVariantsOfTheSameGenreMergeToOneKey() {
        let hipHop = ["Hip-Hop/Rap", "Hip Hop/Rap", "Hip-Hop", "Hip Hop", "Hip hop", "HipHop",
                      "Rap/Hip-Hop", "Rap & Hip-Hop"]
        let keys = Set(hipHop.compactMap { SimilarityFamilies.canonicalGenre($0) })
        XCTAssertEqual(keys.count, 1, "all eight raw labels are one family: \(keys)")

        let soul = ["R&B/Soul", "R&B / Soul", "R&Bsoul", "R&B, soul"]
        XCTAssertEqual(Set(soul.compactMap { SimilarityFamilies.canonicalGenre($0) }).count, 1)

        let funk = ["Funk / Soul", "Funk/Soul", "Funk, soul", "Funk, Soul"]
        XCTAssertEqual(Set(funk.compactMap { SimilarityFamilies.canonicalGenre($0) }).count, 1)

        // …and genuinely different genres do NOT merge (a canonicalizer that maps everything to
        // one bucket also passes the test above).
        XCTAssertNotEqual(SimilarityFamilies.canonicalGenre("Hip-Hop/Rap"),
                          SimilarityFamilies.canonicalGenre("Jazz"))
        XCTAssertNil(SimilarityFamilies.canonicalGenre(nil))
        XCTAssertNil(SimilarityFamilies.canonicalGenre("   "))
    }

    // ========================================================================
    // MARK: - Missing metadata is neither buried nor rewarded
    // ========================================================================

    /// THE sparse-feature trap, in both directions.
    ///
    /// bpm/camelot coverage on the real catalog is 10.4% — and 0.0% across the 96,021 Apple Music
    /// rows. Scoring an absent tempo 0 would sink nine tenths of the library for a field the
    /// indexer has not reached; dropping the term for that song (a per-song denominator) would
    /// make missing metadata an ADVANTAGE. Mean-imputation is neither, and this pins both edges.
    func testASongWithNoTempoOrKeyIsImputedNotBuriedAndNotRewarded() {
        let seed = song("s", artist: "A", year: 2000, bpm: 120, camelot: "8A")

        // Three candidates that differ ONLY in tempo/key.
        let perfect = song("perfect", artist: "A", year: 2000, bpm: 120, camelot: "8A")
        let wrong = song("wrong", artist: "A", year: 2000, bpm: 175, camelot: "2A")
        let unknown = song("unknown", artist: "A", year: 2000)          // no bpm, no camelot
        let g = ["perfect": "electronic", "wrong": "electronic", "unknown": "electronic"]

        var profile = PuzzleSimilarity.profile(
            targetMemberIds: [["s"]], songsById: ["s": seed], genreBySongId: ["s": "electronic"],
            otherCollections: [], plays: [], balance: .even, nowMs: 0)
        profile.calibrate(against: [perfect, wrong, unknown])

        let sPerfect = PuzzleSimilarity.score(perfect, profile: profile, genre: g["perfect"])
        let sWrong = PuzzleSimilarity.score(wrong, profile: profile, genre: g["wrong"])
        let sUnknown = PuzzleSimilarity.score(unknown, profile: profile, genre: g["unknown"])

        XCTAssertGreaterThan(sPerfect, sUnknown,
                             "a known-good tempo/key beats an unknown one — the term has to mean something")
        XCTAssertGreaterThan(sUnknown, sWrong,
                             "but an UNKNOWN tempo is not treated as a WRONG one: not buried")
        // And the unimputed alternative — dropping the term for this song — would have put
        // `unknown` at or above `perfect`. It must not.
        XCTAssertLessThan(sUnknown, sPerfect, "missing metadata is never an advantage")
    }

    /// THE IMPUTATION IS MEASURED PER ROUND, and the ablation proves it is unbiased.
    ///
    /// The direct test of "missing metadata is neither rewarded nor punished": take songs that DO
    /// carry bpm+camelot, strip those two fields, and compare. A positive mean delta means the
    /// scorer rewards missing data (the sparse-feature bug); a negative one means it buries the
    /// 90% of the catalog the audio indexer has not reached. Over the real catalog this measures
    /// +0.0000 (the previous design's global constant measured +0.0042).
    ///
    /// It works because the neutral is the round's OWN mean, not a constant guessed once: subtract
    /// the mean of a distribution from itself and the bias is zero by construction, whatever the
    /// seed happens to look like.
    func testTheRoundNeutralMakesTheImputationUnbiased() {
        // A candidate pool with a realistic ~10% analysed share and a spread of fits.
        var pool: [IndexSong] = []
        for i in 0..<300 {
            let analysed = i % 10 == 0
            pool.append(song("s\(i)", artist: "Artist \(i % 40)", year: 1970 + i % 50,
                             bpm: analysed ? Double(70 + (i * 7) % 100) : nil,
                             camelot: analysed ? "\((i % 12) + 1)\(i % 2 == 0 ? "A" : "B")" : nil))
        }
        let seedIds = (0..<30).map { "s\($0 * 10)" }        // all analysed, so family C is live
        var songsById = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let genres = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, "hip-hop") })

        var profile = PuzzleSimilarity.profile(
            targetMemberIds: [seedIds], songsById: songsById, genreBySongId: genres,
            otherCollections: [], plays: [], balance: .even, nowMs: 0)
        profile.calibrate(against: pool)
        XCTAssertTrue(profile.musicalCalibration.usedRoundMean,
                      "with 30 analysed candidates the round measures its own neutral")

        // ABLATION: strip bpm+camelot from every analysed song and diff the score.
        var deltas: [Double] = []
        for s in pool where s.bpm != nil || s.camelot != nil {
            let stripped = song(s.id, artist: s.artist, year: s.year)
            songsById[stripped.id] = stripped
            let before = PuzzleSimilarity.score(s, profile: profile, genre: genres[s.id])
            let after = PuzzleSimilarity.score(stripped, profile: profile, genre: genres[s.id])
            deltas.append(after - before)
        }
        XCTAssertGreaterThan(deltas.count, 20)
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        XCTAssertEqual(mean, 0, accuracy: 0.01,
                       "stripping tempo/key must not systematically help OR hurt (mean Δ \(mean))")
        // …and it is a real two-sided distribution, not "every delta is exactly zero" (which would
        // mean the term was inert — B1's actual defect).
        XCTAssertTrue(deltas.contains { $0 > 1e-9 }, "some songs lose by being unanalysed")
        XCTAssertTrue(deltas.contains { $0 < -1e-9 }, "and some gain — the term is not inert")
    }

    /// SHRINKAGE. A partially-observed feature over-selects at the top of a ranking purely by
    /// variance — the 10% of songs that can reach 1.0 crowd out the 90% pinned at the mean, even
    /// when the imputation is perfectly unbiased. Pulling one or two noisy observations toward the
    /// round's mean is the standard remedy, and it is what took the measured share of the top-90
    /// held by bpm/key-bearing songs from 2.31× the base rate to 1.56×.
    func testMusicalEvidenceIsShrunkTowardTheRoundNeutral() {
        let p = musical(bpms: [120], camelots: ["8A"])
        let cal = SimilarityFamilies.MusicalCalibration(neutral: 0.30, observations: 500)

        let bothPerfect = SimilarityFamilies.musicalFit(bpm: 120, camelot: "8A",
                                                        profile: p, calibration: cal)
        let bothWrong = SimilarityFamilies.musicalFit(bpm: 179, camelot: "3B",
                                                      profile: p, calibration: cal)
        let none = SimilarityFamilies.musicalFit(bpm: nil, camelot: nil, profile: p, calibration: cal)

        XCTAssertEqual(none, 0.30, accuracy: 1e-9, "no evidence ⇒ exactly the round's mean")
        // With `musicalPrior` pseudo-observations of the mean against two real ones, a perfect fit
        // lands at (2·0.30 + 2·1.0)/4 = 0.65, not 1.0.
        XCTAssertEqual(bothPerfect, (SimilarityFamilies.musicalPrior * 0.30 + 2 * 1.0)
                                     / (SimilarityFamilies.musicalPrior + 2), accuracy: 1e-9)
        XCTAssertLessThan(bothPerfect, 1.0, "evidence is shrunk toward the mean, never taken raw")
        XCTAssertGreaterThan(bothPerfect, none, "…but it still moves the score in the right direction")
        XCTAssertLessThan(bothWrong, none, "and a wrong tempo/key still costs")

        // ONE observation is shrunk HARDER than two — the whole point of counting evidence.
        let oneOnly = SimilarityFamilies.musicalFit(bpm: 120, camelot: nil, profile: musical(bpms: [120]),
                                                    calibration: cal)
        XCTAssertLessThan(oneOnly, bothPerfect, "one field of evidence moves the score less than two")
    }

    // ========================================================================
    // MARK: - The families are genuinely different opinions
    // ========================================================================

    /// Each family ALONE must produce a materially different ranking. Measured on the real
    /// catalog the three families' top-500 sets overlap by a Jaccard of 0.006–0.011, i.e. they are
    /// very nearly orthogonal — which is exactly what makes equal weights a real blend rather than
    /// triple-counting one signal. This is that property on a fixture small enough to read.
    func testEachFamilyAloneRanksDifferently() {
        // Seed: one artist, 1995, 90 bpm, 8A, hip-hop.
        let seed = song("seed", artist: "Seed Artist", year: 1995, bpm: 90, camelot: "8A")
        var songsById = ["seed": seed]
        var genres = ["seed": "hip-hop"]

        // Three candidates, each engineered to win exactly ONE family.
        //  · artistWin  — same artist, wrong era, wrong genre, wrong tempo.
        //  · eraWin     — same genre + same year, different artist, wrong tempo/key.
        //  · grooveWin  — same genre + same tempo + neighbouring key, different artist and era.
        let artistWin = song("artistWin", artist: "Seed Artist", year: 1968, bpm: 170, camelot: "2B")
        let eraWin = song("eraWin", artist: "Other One", year: 1995, bpm: 170, camelot: "2B")
        let grooveWin = song("grooveWin", artist: "Other Two", year: 1968, bpm: 90, camelot: "9A")
        for s in [artistWin, eraWin, grooveWin] { songsById[s.id] = s }
        genres["artistWin"] = "jazz"
        genres["eraWin"] = "hip-hop"
        genres["grooveWin"] = "hip-hop"

        let profile = PuzzleSimilarity.profile(
            targetMemberIds: [["seed"]], songsById: songsById, genreBySongId: genres,
            otherCollections: [], plays: [], balance: .even, nowMs: 0)

        func families(_ s: IndexSong) -> SimilarityFamilies.Scores {
            PuzzleSimilarity.familyScores(s, profile: profile, genre: genres[s.id])
        }
        XCTAssertEqual(families(artistWin).leading, "artist")
        XCTAssertEqual(families(eraWin).leading, "era")
        XCTAssertEqual(families(grooveWin).leading, "groove")

        // A ranking driven by ONE family puts a different song on top in each case — which is the
        // operational meaning of "these are three different opinions".
        let byArtist = [artistWin, eraWin, grooveWin]
            .max { (families($0).artist ?? 0) < (families($1).artist ?? 0) }
        let byEra = [artistWin, eraWin, grooveWin]
            .max { (families($0).genreYear ?? 0) < (families($1).genreYear ?? 0) }
        let byGroove = [artistWin, eraWin, grooveWin]
            .max { (families($0).genreMusical ?? 0) < (families($1).genreMusical ?? 0) }
        XCTAssertEqual(byArtist?.id, "artistWin")
        XCTAssertEqual(byEra?.id, "eraWin")
        XCTAssertEqual(byGroove?.id, "grooveWin")
        XCTAssertEqual(Set([byArtist?.id, byEra?.id, byGroove?.id]).count, 3,
                       "three families, three different winners")
    }

    /// ARTIST'S GRIP LOOSENS — the owner's actual ask, stated as a property rather than a weight.
    ///
    /// Note what is NOT claimed. `wArtist` (0.30) is already smaller than `wGenre + wYear` (0.40),
    /// so a bare artist match does not out-score a genre+era match even today; artist dominates by
    /// SELECTIVITY, not by weight (see `SimilarityFamilies`'s type doc). What the balance changes
    /// is the MARGIN — the gap widens, because artist's share of the family weight falls from
    /// 0.30/0.70 = 43% to a third.
    func testTheBalanceWidensTheGapBetweenAGenreEraMatchAndABareArtistMatch() {
        let seed = song("seed", artist: "Seed Artist", year: 1995, bpm: 90, camelot: "8A")
        // Same artist, and nothing else in common.
        let artistOnly = song("artistOnly", artist: "Seed Artist", year: 1962, bpm: 178, camelot: "3B")
        // Everything in common EXCEPT the artist.
        let everythingElse = song("everythingElse", artist: "Someone Else", year: 1995,
                                  bpm: 90, camelot: "8A")
        let songsById = [seed.id: seed, artistOnly.id: artistOnly, everythingElse.id: everythingElse]
        let genres = ["seed": "hip-hop", "artistOnly": "jazz", "everythingElse": "hip-hop"]

        func gap(balance: SimilarityFamilies.Balance?) -> Double {
            let p = PuzzleSimilarity.profile(targetMemberIds: [["seed"]], songsById: songsById,
                                             genreBySongId: genres, otherCollections: [],
                                             plays: [], balance: balance, nowMs: 0)
            return PuzzleSimilarity.score(everythingElse, profile: p, genre: genres["everythingElse"])
                 - PuzzleSimilarity.score(artistOnly, profile: p, genre: genres["artistOnly"])
        }
        XCTAssertGreaterThan(gap(balance: .even), gap(balance: nil),
                             "the balance moves weight off artist and onto the other two families")
    }

    /// The signal the shipped weights CANNOT express at all: two candidates identical on artist,
    /// genre and year, differing only in tempo and key. Today they tie exactly; under the balance
    /// the one that fits the groove wins. This is what family C buys.
    func testTempoAndKeyBreakATieTheShippedWeightsCannotSee() {
        let seed = song("seed", artist: "Seed Artist", year: 1995, bpm: 90, camelot: "8A")
        let onGroove = song("onGroove", artist: "Other", year: 1995, bpm: 90, camelot: "8A")
        let offGroove = song("offGroove", artist: "Other", year: 1995, bpm: 178, camelot: "3B")
        let songsById = [seed.id: seed, onGroove.id: onGroove, offGroove.id: offGroove]
        let genres = ["seed": "hip-hop", "onGroove": "hip-hop", "offGroove": "hip-hop"]

        func scores(_ balance: SimilarityFamilies.Balance?) -> (on: Double, off: Double) {
            let p = PuzzleSimilarity.profile(targetMemberIds: [["seed"]], songsById: songsById,
                                             genreBySongId: genres, otherCollections: [],
                                             plays: [], balance: balance, nowMs: 0)
            return (PuzzleSimilarity.score(onGroove, profile: p, genre: genres["onGroove"]),
                    PuzzleSimilarity.score(offGroove, profile: p, genre: genres["offGroove"]))
        }
        let shipped = scores(nil)
        XCTAssertEqual(shipped.on, shipped.off, accuracy: 1e-12,
                       "TODAY the two are indistinguishable — tempo and key are not in the scorer")
        let balanced = scores(.even)
        XCTAssertGreaterThan(balanced.on, balanced.off,
                             "BALANCED: the one that fits the tempo and key wins")
    }

    // ========================================================================
    // MARK: - Gem Collector's shipped ranking does NOT move
    // ========================================================================

    /// THE GATE. The owner has scoreboard history under the present semantics, so the balance is
    /// opt-in per caller and the puzzle passes nil. `balance: nil` must be BYTE-IDENTICAL — not
    /// "close", not "same order": the same Double out of the same inputs.
    func testDefaultModeIsByteIdenticalSoThePuzzleRankingCannotMove() {
        var songsById: [String: IndexSong] = [:]
        var genres: [String: String] = [:]
        for i in 0..<40 {
            let s = song("s\(i)", artist: "Artist \(i % 7)", year: 1970 + i,
                         bpm: i % 3 == 0 ? nil : Double(80 + i * 2),
                         camelot: i % 4 == 0 ? nil : "\((i % 12) + 1)\(i % 2 == 0 ? "A" : "B")")
            songsById[s.id] = s
            genres[s.id] = ["hip-hop", "jazz", "soul", "electronic"][i % 4]
        }
        let members = (0..<8).map { "s\($0)" }
        // Member plays PLUS a non-member played inside the co-play window, so the co-play term is
        // genuinely live and the pinned denominator really is all seven constants.
        var plays = (0..<8).map { (songId: "s\($0)", atMs: Double($0) * 60_000) }
        plays.append((songId: "s20", atMs: 30_000))

        let shipped = PuzzleSimilarity.profile(
            targetMemberIds: [members], songsById: songsById, genreBySongId: genres,
            otherCollections: [["s10", "s11", "s2"]], plays: plays, hasRecency: true, nowMs: 0)
        // The pinned denominator: exactly the seven shipped constants, with no musical term.
        XCTAssertEqual(shipped.availableWeight,
                       PuzzleSimilarity.wArtist + PuzzleSimilarity.wGenre + PuzzleSimilarity.wYear
                         + PuzzleSimilarity.wCoMember + PuzzleSimilarity.wCoPlay
                         + PuzzleSimilarity.wRecency,
                       accuracy: 1e-12)
        XCTAssertNil(shipped.terms, "default mode never builds family weights")
        XCTAssertTrue(shipped.musical.isEmpty, "…and never even reads tempo or key")
        // `calibrate` is a no-op outside balanced mode, so a caller cannot accidentally move the
        // puzzle's ranking by calling it.
        var shippedCalibrated = shipped
        shippedCalibrated.calibrate(against: Array(songsById.values))
        XCTAssertTrue(shippedCalibrated.musical.isEmpty)
        XCTAssertEqual(shippedCalibrated.musicalCalibration.observations, 0)

        let balanced = PuzzleSimilarity.profile(
            targetMemberIds: [members], songsById: songsById, genreBySongId: genres,
            otherCollections: [["s10", "s11", "s2"]], plays: plays, hasRecency: true,
            balance: .even, nowMs: 0)
        XCTAssertNotNil(balanced.terms)

        var moved = 0
        for (id, s) in songsById.sorted(by: { $0.key < $1.key }) {
            let a = PuzzleSimilarity.score(s, profile: shipped, genre: genres[id], recency: 0.3)
            let b = PuzzleSimilarity.score(s, profile: balanced, genre: genres[id], recency: 0.3)
            // A second call with the SAME (default) profile is bit-for-bit identical.
            XCTAssertEqual(a, PuzzleSimilarity.score(s, profile: shipped, genre: genres[id], recency: 0.3),
                           "default mode is deterministic")
            if a != b { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0,
                             "…and the opt-in mode really does score differently (otherwise this test proves nothing)")
    }

    /// In Da Zone is the surface the owner asked to rebalance, so it is the one that opts IN.
    func testTheZoneOptsInAndTheDefaultTuningCarriesTheBalance() {
        XCTAssertEqual(ZoneEngine.Tuning().balance, .even,
                       "For You ranks with the three families by default")
    }

    // ========================================================================
    // MARK: - Balance on real-SHAPED data, not a toy fixture
    // ========================================================================

    /// The measured library is 26% hip-hop / 19% soul / 15% pop, 99% year coverage and 10% tempo
    /// coverage. On a catalog shaped like that, the balanced ranking must not simply return one
    /// artist — the failure mode of the ranking it replaces.
    func testOnRealShapedDataTheTopOfTheRankingIsNotOneArtist() {
        // 600 songs: genre distribution and tempo coverage matching the measured catalog.
        let genreMix: [(String, Int)] = [("hip-hop", 156), ("soul", 113), ("pop", 88),
                                         ("electronic", 50), ("rock", 28), ("world", 32),
                                         ("jazz", 18), ("country", 17), ("funk", 12),
                                         ("disco", 8), ("blues", 5), ("classical", 4),
                                         ("folk", 3), ("r&b", 6), ("Other", 60)]
        var songsById: [String: IndexSong] = [:]
        var genres: [String: String] = [:]
        var i = 0
        for (genre, n) in genreMix {
            for k in 0..<n {
                // ~10% of rows carry tempo/key — the measured coverage, concentrated (as in the
                // real catalog) rather than sprinkled evenly.
                let analysed = i % 10 == 0
                let s = song("s\(i)", artist: "Artist \(i % 90)", year: 1968 + (i * 7) % 55,
                             bpm: analysed ? Double(70 + (i * 13) % 90) : nil,
                             camelot: analysed ? "\((i % 12) + 1)\(k % 2 == 0 ? "A" : "B")" : nil)
                songsById[s.id] = s
                genres[s.id] = genre
                i += 1
            }
        }
        // Seed: a small binge on one artist plus a spread — the shape a week of listening has.
        let seedIds = ["s0", "s90", "s180", "s5", "s17", "s233", "s401", "s512"]
        var profile = PuzzleSimilarity.profile(
            targetMemberIds: [seedIds], songsById: songsById, genreBySongId: genres,
            otherCollections: [], plays: [], balance: .even, nowMs: 0)
        XCTAssertNotNil(profile.terms)
        XCTAssertFalse(profile.musical.isEmpty, "the seed set carries enough tempo to speak family C")
        profile.calibrate(against: Array(songsById.values))

        var ranked: [(song: IndexSong, s: Double)] = []
        for s in songsById.values where !seedIds.contains(s.id) {
            ranked.append((s, PuzzleSimilarity.score(s, profile: profile, genre: genres[s.id])))
        }
        ranked.sort { a, b in
            if a.s != b.s { return a.s > b.s }
            return a.song.id < b.song.id
        }
        let top30 = Array(ranked.prefix(30))
        let distinctArtists = Set(top30.map { $0.song.artist }).count
        XCTAssertGreaterThanOrEqual(distinctArtists, 5,
                                    "the top of the ranking is not one artist's discography")

        // And songs with NO tempo/key are not swept out of the top by the ones that have it —
        // they are 90% of the library, so a ranking that buried them would be useless here.
        let unanalysedInTop = top30.filter { $0.song.bpm == nil }.count
        XCTAssertGreaterThan(unanalysedInTop, 0,
                             "the 90% of the catalog with no beat grid can still be recommended")
    }

    // ========================================================================
    // MARK: - The era window (owner: "factor in year range … along with genre")
    // ========================================================================
    //
    // The pocket year-histograms below are REAL DATA, not invented: the member years of the
    // owner's actual pockets (source-backup.pocketdj, 2026-08-11) joined against
    // public/rec-features.json — song year with album-year fallback, 106,879 of 107,757 rows
    // dated (99.2%). They mirror the fixtures in the Lambda's test-rec-engine.mjs EXACTLY, which
    // is the point: cloud and device must compute the same window for the same membership.

    private func years(_ hist: [Int: Int]) -> [Double] {
        hist.flatMap { (y, k) in Array(repeating: Double(y), count: k) }
    }

    /// "808 and Swinging" — 87 members, 86 dated. The owner remembers it as ≈1988–1994 new jack
    /// swing; the year data is verified correct song-by-song (Keith Sweat 1987 ✓, SWV 1992 ✓,
    /// Kodak Black 2023 ✓) and the membership genuinely spans 1986–2025 — a ~30-song 1986–1998
    /// founding core, two whole 2001/2003 albums, and a modern R&B tail he added himself. The
    /// window is honestly WIDE: narrowing it to 88–94 would score the very songs he filed as
    /// misfits. The new-jack-swing SOUND is the genre term's job.
    private let p808AndSwinging: [Int: Int] = [
        1986: 1, 1987: 9, 1988: 2, 1989: 1, 1990: 2, 1992: 4, 1993: 1, 1994: 1, 1995: 2, 1996: 3,
        1997: 1, 1998: 1, 2000: 3, 2001: 12, 2003: 15, 2005: 2, 2007: 1, 2008: 2, 2011: 1, 2013: 1,
        2015: 2, 2016: 1, 2018: 2, 2019: 1, 2020: 1, 2021: 1, 2022: 2, 2023: 8, 2025: 3,
    ]
    /// "Bad Bitch Radio" — 35 members, all dated 2015–2026: a tight, modern pocket.
    private let pBadBitchRadio: [Int: Int] = [
        2015: 1, 2018: 3, 2019: 1, 2022: 2, 2023: 15, 2024: 1, 2025: 11, 2026: 1,
    ]
    /// "🏋🏾‍♀️" — 500 members, 486 dated, one member tagged year **1012** (a tagging error, kept on
    /// purpose: the real catalog's own argument for a percentile window over min/max).
    private let pWorkout: [Int: Int] = [
        1012: 1, 1967: 1, 1976: 2, 1977: 1, 1978: 1, 1980: 3, 1981: 3, 1982: 2, 1983: 3, 1984: 2,
        1986: 3, 1987: 1, 1989: 2, 1990: 3, 1991: 1, 1993: 2, 1996: 6, 1997: 1, 1998: 7, 1999: 5,
        2000: 5, 2001: 18, 2002: 7, 2003: 9, 2004: 11, 2005: 8, 2006: 18, 2007: 21, 2008: 27,
        2009: 32, 2010: 38, 2011: 41, 2012: 29, 2013: 28, 2014: 26, 2015: 26, 2016: 29, 2017: 22,
        2018: 12, 2019: 5, 2020: 2, 2021: 5, 2022: 1, 2023: 10, 2024: 2, 2025: 2, 2026: 2,
    ]

    func testEraWindowOfTheRealPocketsMatchesTheLambda() {
        XCTAssertEqual(SimilarityFamilies.eraWindow(years: years(p808AndSwinging)),
                       SimilarityFamilies.EraWindow(lo: 1987, hi: 2024),
                       "808 and Swinging — wide, and honestly so (see the fixture doc)")
        XCTAssertEqual(SimilarityFamilies.eraWindow(years: years(pBadBitchRadio)),
                       SimilarityFamilies.EraWindow(lo: 2020, hi: 2027),
                       "a modern pocket gets a tight modern window")
        XCTAssertEqual(SimilarityFamilies.eraWindow(years: years(pWorkout)),
                       SimilarityFamilies.EraWindow(lo: 1999, hi: 2018),
                       "a 2000s–2010s pocket gets a 2000s–2010s window")
        // Three real pockets, three obviously different eras.
        let windows = [p808AndSwinging, pBadBitchRadio, pWorkout]
            .compactMap { SimilarityFamilies.eraWindow(years: years($0)) }
        XCTAssertEqual(Set(windows.map { "\($0.lo):\($0.hi)" }).count, 3)
    }

    func testEraWindowPercentileShrugsOffTheYear1012TaggingError() {
        let ys = years(pWorkout)
        XCTAssertEqual(ys.min(), 1012, "the outlier really is in the input")
        XCTAssertEqual(SimilarityFamilies.eraWindow(years: ys)?.lo, 1999,
                       "min/max would have started this window at 1010")
    }

    func testEraWindowFailsOpenOnUndatedInput() {
        XCTAssertNil(SimilarityFamilies.eraWindow(years: []))
        XCTAssertNil(SimilarityFamilies.eraWindow(years: [0, -3, .nan]),
                     "no usable year ⇒ no window ⇒ the term drops and `termWeights` renormalizes")
        // The nearest-rank agreement case the Lambda pins too: a small set whose modern outlier
        // sits above p85 and says nothing.
        XCTAssertEqual(SimilarityFamilies.eraWindow(years: [1990, 1991, 1992, 1993, 1994, 1995, 2024]),
                       SimilarityFamilies.EraWindow(lo: 1989, hi: 1997))
    }

    func testEraFitIsFlatInsideTheWindowAndDecaysOutside() {
        let w = SimilarityFamilies.EraWindow(lo: 1988, hi: 1994)
        XCTAssertEqual(SimilarityFamilies.eraFit(year: 1988, window: w), 1)
        XCTAssertEqual(SimilarityFamilies.eraFit(year: 1991, window: w), 1,
                       "an era is a RANGE — 1991 is not 'more 88–94' than 1993")
        XCTAssertEqual(SimilarityFamilies.eraFit(year: 1994, window: w), 1)
        XCTAssertEqual(SimilarityFamilies.eraFit(year: 1996, window: w),
                       exp(-2 / SimilarityFamilies.eraDecayYears), accuracy: 1e-12)
        XCTAssertLessThan(SimilarityFamilies.eraFit(year: 2020, window: w), 0.002,
                          "a 2020 track against an 88–94 window is buried on era — and still free "
                          + "to win on genre or artist, which is what 'a feature, not a filter' means")
    }

    func testAnUndatedSongIsImputedTheRoundNeutralNeverZero() {
        let w = SimilarityFamilies.EraWindow(lo: 1988, hi: 1994)
        // A pool big enough to measure from: 30 in-window (fit 1) + 10 far outside (fit ≈ 0).
        let pool: [Double?] = Array(repeating: 1990.0, count: 30)
            + Array(repeating: 2024.0, count: 10)
        let cal = SimilarityFamilies.eraCalibrate(pool, window: w)
        XCTAssertTrue(cal.usedRoundMean)
        XCTAssertEqual(cal.neutral, 30.0 / 40.0, accuracy: 0.01, "the neutral IS the pool mean")
        XCTAssertEqual(SimilarityFamilies.eraFit(year: nil, window: w, calibration: cal),
                       cal.neutral, "undated ⇒ the neutral — fail open, not a zero")
        XCTAssertEqual(SimilarityFamilies.eraFit(year: 1990, window: w, calibration: cal), 1,
                       "a dated song keeps its own evidence — no shrinkage at 99.2% coverage")
        // Too few observations ⇒ the measured global fallback, not garbage from a tiny mean.
        let tiny = SimilarityFamilies.eraCalibrate([Double?](arrayLiteral: 1990), window: w)
        XCTAssertFalse(tiny.usedRoundMean)
        XCTAssertEqual(tiny.neutral, SimilarityFamilies.fallbackNeutralEraFit)
    }
}
