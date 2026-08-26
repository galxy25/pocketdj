import XCTest
@testable import PocketDJ

/// **THE SOUND DOOR** — `ZoneEngine`'s narrow, capped, skew-proof quota of candidates admitted on
/// audio alone, past the `guard a > 0 || g > 0` gate that used to be the ceiling on the whole
/// timbre feature.
///
/// Every test here is written so it FAILS on the pre-change engine, and the mechanism (not the
/// fixture) is what it asserts on: each case that expects an admission also runs the identical
/// input with `soundAdmitHardCap = 0` — which is exactly the old engine, since a zero quota
/// short-circuits the door before a single distance is measured — and requires the two answers to
/// DIFFER in precisely the admitted rows. A fixture that happened to produce the right ids for
/// the wrong reason would pass the first assertion and fail the second.
///
/// The failure mode being guarded against is not "admits nothing". It is "admits, plausibly, and
/// quietly hands the whole quota to 1970s vinyl" — coverage on the real corpus runs 1970s 54.7%
/// and 1980s 53.4% against 2010s 6.3% and 2020s 2.6%, so ranking the pool by fit alone would do
/// exactly that and look like discovery while doing it.
final class RecSoundAdmitTests: XCTestCase {

    // ========================================================================
    // MARK: - Fixtures
    // ========================================================================

    /// A vector whose every axis is `base` (plus per-axis overrides), shifted uniformly. A uniform
    /// shift of `s` puts the vector at RMS distance exactly `|s|` from the unshifted one, which is
    /// what lets these tests state distances in the SAME units the admission threshold is written
    /// in (0.12 noise floor, 0.06 margin) instead of asserting on a number nobody can read.
    private func tvec(_ base: Double, _ overrides: [String: Double] = [:],
                      shift: Double = 0) -> SimilarityFamilies.TimbreVector {
        Dictionary(uniqueKeysWithValues: SimilarityFamilies.timbreAxes.map { axis in
            (axis, min(1, max(0, (overrides[axis] ?? base) + shift)))
        })
    }
    private func soundA(_ shift: Double = 0) -> SimilarityFamilies.TimbreVector {
        tvec(0.2, ["punch": 0.9, "busy": 0.8], shift: shift)
    }
    /// The exact midpoint of `soundA` and its opposite — used to sit a candidate ON a wide
    /// crate's centroid, so the only thing that can exclude it is a precondition.
    private func soundMidpoint() -> SimilarityFamilies.TimbreVector { tvec(0.5) }
    private func soundAFlipped() -> SimilarityFamilies.TimbreVector {
        tvec(0.8, ["punch": 0.1, "busy": 0.2])
    }

    private struct Fixture {
        var members: [String]
        var tracks: [ZoneEngine.Track]
        var timbre: [String: SimilarityFamilies.TimbreVector]
    }

    private func track(_ id: String, artist: String, genre: String?, rawGenre: String?,
                       year: Int?) -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: artist.lowercased(), artistName: artist,
                         genre: genre, year: year, title: id, genreRaw: rawGenre)
    }

    /// A soul crate of `members` songs, `analysed` of them carrying tight sound-A vectors, plus
    /// `fillers` same-genre candidates the metadata gate admits in the ordinary way (so the tile
    /// has a full 25 rows to compose and the quota is competing for real slots, not filling a
    /// vacuum).
    private func fixture(members: Int = 10, analysed: Int? = nil, fillers: Int = 40,
                         wideSpread: Bool = false) -> Fixture {
        var tracks: [ZoneEngine.Track] = []
        var timbre: [String: SimilarityFamilies.TimbreVector] = [:]
        var ids: [String] = []
        let analysedCount = analysed ?? members
        for i in 0..<members {
            let id = "m-\(i)"
            ids.append(id)
            tracks.append(track(id, artist: "Member \(i)", genre: "soul", rawGenre: "Neo-Soul",
                                year: 1990))
            guard i < analysedCount else { continue }
            timbre[id] = wideSpread
                ? (i % 2 == 0 ? soundA() : soundAFlipped())
                : soundA((Double(i) - Double(members - 1) / 2) * 0.002)
        }
        for i in 0..<fillers {
            tracks.append(track("f-\(i)", artist: "Filler \(i)", genre: "soul", rawGenre: "Soul",
                                year: 1990))
        }
        return Fixture(members: ids, tracks: tracks, timbre: timbre)
    }

    /// The engine with the door SHUT — a zero quota is byte-identical to the pre-change engine,
    /// because `admitEligible` is false and the `else` branch of the gate falls straight through
    /// to the same `continue` the old `guard` produced.
    private var doorShut: ZoneEngine.Tuning {
        var t = ZoneEngine.Tuning()
        t.soundAdmitHardCap = 0
        return t
    }

    private func rank(_ f: Fixture, tuning: ZoneEngine.Tuning = ZoneEngine.Tuning(),
                      feedback: ZoneEngine.Feedback = ZoneEngine.Feedback()) -> ZoneEngine.Ranking {
        ZoneEngine.rank(memberSongIds: f.members, tracks: f.tracks, playCount: { _ in 0 },
                        feedback: feedback, tuning: tuning, timbre: f.timbre)
    }

    // ========================================================================
    // MARK: - The door opens
    // ========================================================================

    /// THE HEADLINE. A candidate sharing NEITHER an artist NOR a genre category with the crate —
    /// the exact class `guard a > 0 || g > 0` rejected outright, so the timbre term could never
    /// speak about it — is seated because it sounds like the crate.
    func testSoundAdmitsACandidateSharingNeitherArtistNorGenre() {
        var f = fixture()
        f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-alike"] = soundA(0.03)   // 0.03 < radius 0.06 — well inside the door

        let shut = ZoneEngine.suggestions(memberSongIds: f.members, tracks: f.tracks,
                                          playCount: { _ in 0 }, tuning: doorShut,
                                          timbre: f.timbre)
        XCTAssertFalse(shut.contains("x-alike"),
                       "TODAY'S ENGINE: neither artist nor genre matches, so the gate rejects it "
                       + "no matter how it sounds — this is the ceiling being lifted")

        let open = rank(f)
        XCTAssertTrue(open.ids.contains("x-alike"),
                      "sound alone admitted it")
        XCTAssertEqual(open.soundAdmitted, ["x-alike"],
                       "and the engine says SO — the badge set is the ranking's own answer, "
                       + "never re-derived downstream")
        XCTAssertEqual(Set(shut).subtracting(open.ids).count, 1,
                       "exactly one metadata row spilled off the bottom to make room")
    }

    /// The quota is a BOUND, not a preference: 40 eligible strangers, three seats.
    func testSoundAdmitNeverExceedsTheCap() {
        var f = fixture()
        let decades = [1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
        for i in 0..<40 {
            let id = "x-\(String(format: "%02d", i))"
            f.tracks.append(track(id, artist: "Stranger \(i)", genre: "jazz",
                                  rawGenre: "Genre \(i)", year: decades[i % decades.count] + 3))
            f.timbre[id] = soundA(0.01 + Double(i) * 0.0005)
        }
        let out = rank(f)
        XCTAssertEqual(out.soundAdmitted.count, 3,
                       "⌊25 × 0.12⌋ = 3 and the hard cap is 3 — 40 qualified strangers cannot "
                       + "become 4 rows, whatever the fits look like")
        XCTAssertEqual(out.ids.count, 25, "the quota reorders a tile, it never lengthens one")
        XCTAssertEqual(out.soundAdmitted.count,
                       out.ids.filter { $0.hasPrefix("x-") }.count,
                       "every admitted row is accounted for, and no stranger arrived any other way")
    }

    /// BEING ANALYSED IS NOT A QUALIFICATION. The margin is stated in the instrument's own units:
    /// the measured median distance between two INDEPENDENT captures of the same recording is
    /// 0.119–0.120, so a candidate must sit half that error bar INSIDE the crate's radius before
    /// the engine will claim it belongs there.
    func testSoundAdmitRequiresAFitMarginNotMerelyAVector() {
        var f = fixture()
        // Inside the radius `max(spread, noiseFloor)` = 0.12 — i.e. closer to this crate than two
        // recordings of the SAME SONG measure from each other — but it does not clear the margin.
        f.tracks.append(track("x-near", artist: "Nearly", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-near"] = soundA(0.09)
        f.tracks.append(track("x-inside", artist: "Inside", genre: "jazz", rawGenre: "Nu Jazz",
                              year: 2005))
        f.timbre["x-inside"] = soundA(0.055)

        let out = rank(f)
        XCTAssertEqual(out.soundAdmitted, ["x-inside"],
                       "0.055 clears radius − margin (0.06); 0.09 is inside the noise floor but "
                       + "not inside the claim, and a threshold of 'has a vector' would seat both")
    }

    // ========================================================================
    // MARK: - The skew guard (the failure the coverage audit predicts)
    // ========================================================================

    /// **THE FLOOD TEST.** The admit pool is 25 mid-70s rows holding the SMALLEST distances — the
    /// exact shape real coverage produces (1970s 54.7% analysed against 2020s 2.6%) — plus five
    /// stragglers from other decades that fit measurably worse. Ranked by fit alone the quota
    /// would be three 1970s rows and the tile would become old vinyl wearing a discovery badge.
    func testSoundAdmitCannotFloodTheBestCoveredEraOrGenre() {
        var f = fixture()
        for i in 0..<25 {
            let id = "x-70s-\(String(format: "%02d", i))"
            // Two different raw genres inside ONE decade, so the decade cap has to bite on its
            // own: the genre cap alone would happily seat a Funk row and a Disco row from 1975.
            f.tracks.append(track(id, artist: "Seventies \(i)", genre: "funk",
                                  rawGenre: i < 20 ? "Funk" : "Disco", year: 1975))
            f.timbre[id] = soundA(0.005 + Double(i) * 0.0005)   // the CLOSEST fits in the pool
        }
        let stragglers = [("x-a-jazz", "Free Jazz", 2015, 0.040), ("x-b-grunge", "Grunge", 1995, 0.045),
                          ("x-c-techno", "Techno", 2005, 0.050), ("x-d-synth", "Synthpop", 1985, 0.055),
                          ("x-e-trap", "Trap", 2020, 0.058)]
        for (id, raw, year, d) in stragglers {
            f.tracks.append(track(id, artist: "Straggler \(id)", genre: "jazz", rawGenre: raw,
                                  year: year))
            f.timbre[id] = soundA(d)
        }

        let out = rank(f)
        XCTAssertEqual(out.soundAdmitted.count, 3)
        let byId = Dictionary(f.tracks.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })
        let admitted = out.soundAdmitted.compactMap { byId[$0] }
        let decades = admitted.compactMap { $0.year.map { ($0 / 10) * 10 } }
        XCTAssertEqual(Set(decades).count, 3,
                       "one seat per decade — the best-covered era cannot take the quota")
        XCTAssertEqual(decades.filter { $0 == 1970 }.count, 1,
                       "25 of the 30 candidates are 1970s and they hold every closest fit; "
                       + "exactly ONE of them may be seated")
        XCTAssertEqual(Set(admitted.compactMap(\.genreRaw)).count, 3,
                       "one seat per RAW genre — measured on raw labels, because that is where "
                       + "the variety cost was measured")
        XCTAssertEqual(Set(admitted.map(\.artistKey)).count, 3, "one seat per artist")
    }

    /// The selector itself, as a pure function — the caps stated directly, so a future change to
    /// the engine's plumbing cannot quietly make them vacuous.
    func testSelectorCapsOneSeatPerDecadeGenreAndArtist() {
        var pool: [RecSoundAdmit.Candidate] = []
        for i in 0..<25 {
            pool.append(.init(id: "a\(i)", capKey: "artist \(i)", decade: 1970,
                              rawGenre: "funk", distance: 0.01 + Double(i) * 0.0001))
        }
        pool.append(.init(id: "b", capKey: "artist b", decade: 2010, rawGenre: "techno", distance: 0.05))
        pool.append(.init(id: "c", capKey: "artist c", decade: 1990, rawGenre: "grunge", distance: 0.06))
        pool.append(.init(id: "d", capKey: "artist b", decade: 1950, rawGenre: "doo wop", distance: 0.02))

        let picked = RecSoundAdmit.select(pool, cap: 3)
        XCTAssertEqual(picked.map(\.id), ["a0", "d", "c"],
                       "closest first, then one seat per decade / genre / artist. a0 takes the "
                       + "1970s funk seat and locks out the other 24; d takes 1950s doo wop; and "
                       + "b — a BETTER fit than c — is refused because d already spent its "
                       + "artist's seat, so the artist cap decides the last row")
        XCTAssertEqual(RecSoundAdmit.select(pool, cap: 0), [], "a zero quota admits nothing")
        // …and determinism: the same pool in a different order is the same answer.
        XCTAssertEqual(RecSoundAdmit.select(pool.reversed(), cap: 3).map(\.id), picked.map(\.id))
    }

    /// "Hip-Hop/Rap" and "hip-hop/rap " must not buy two seats.
    func testGenreBucketsAreNormalisedSoOneLabelCannotBuyTwoSeats() {
        XCTAssertEqual(RecSoundAdmit.genreBucket("Hip-Hop/Rap"),
                       RecSoundAdmit.genreBucket("  hip-hop/rap "))
        XCTAssertNil(RecSoundAdmit.genreBucket(nil))
        XCTAssertNil(RecSoundAdmit.genreBucket("   "))
        let pool: [RecSoundAdmit.Candidate] = [
            .init(id: "a", capKey: "x", decade: 1990, rawGenre: RecSoundAdmit.genreBucket("Hip-Hop/Rap"),
                  distance: 0.01),
            .init(id: "b", capKey: "y", decade: 2000, rawGenre: RecSoundAdmit.genreBucket("hip-hop/rap"),
                  distance: 0.02)]
        XCTAssertEqual(RecSoundAdmit.select(pool, cap: 3).map(\.id), ["a"])
    }

    // ========================================================================
    // MARK: - The label
    // ========================================================================

    /// A suggestion made on SOUND has to be legible AS one. Every other caption the explainer can
    /// produce is false of an admitted row (it shares no artist, no genre and no era claim), and
    /// the strongest true one — "New artist for this crate" — hides the actual evidence.
    func testAdmittedRowsAreLabelledAsSoundMatches() {
        var f = fixture()
        f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-alike"] = soundA(0.03)

        let ranked = ZoneEngine.explainedSuggestions(memberSongIds: f.members, tracks: f.tracks,
                                                     playCount: { _ in 0 }, timbre: f.timbre)
        XCTAssertEqual(ranked.soundAdmitted, ["x-alike"])
        let why = ranked.rows.first { $0.songId == "x-alike" }?.why
        XCTAssertEqual(why?.hasPrefix("Sounds like this crate"), true,
                       "the established caption family, not a new idiom — got \(why ?? "nil")")
        XCTAssertNotEqual(why, "New artist for this crate",
                          "true, but it hides the evidence: novelty must not outrank the "
                          + "measured reason this row is here at all")
        for row in ranked.rows where ranked.soundAdmitted.contains(row.songId) == false {
            XCTAssertFalse(row.why.hasPrefix("Sounds like this crate: "),
                           "no metadata row may borrow the door's caption in this fixture")
        }
    }

    // ========================================================================
    // MARK: - The preconditions (and the no-regression promise)
    // ========================================================================

    /// Each precondition, alone, closes the door — and closing it leaves the tile BYTE-IDENTICAL
    /// to the pre-change engine. This is the "do not regress a pocket with no analysed members"
    /// requirement, stated four ways.
    func testAPocketBelowTheProfileBarIsUnchanged() {
        func assertUnchanged(_ f: Fixture, _ what: String,
                             candidate: SimilarityFamilies.TimbreVector) {
            var f = f
            f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz",
                                  rawGenre: "Free Jazz", year: 2015))
            f.timbre["x-alike"] = candidate
            let open = rank(f)
            let shut = ZoneEngine.suggestions(memberSongIds: f.members, tracks: f.tracks,
                                              playCount: { _ in 0 }, tuning: doorShut,
                                              timbre: f.timbre)
            XCTAssertTrue(open.soundAdmitted.isEmpty, "\(what): nothing may be admitted")
            XCTAssertFalse(open.ids.contains("x-alike"), "\(what): the stranger stays out")
            XCTAssertEqual(open.ids, shut, "\(what): the ranking is byte-identical to today's")
        }

        // 1. No analysed members at all — the term is dead and the door was never built.
        assertUnchanged(fixture(analysed: 0), "no vectors", candidate: soundA(0.01))
        // 2. Two analysed members: below `timbreMinVectors`, so there is no profile at all.
        assertUnchanged(fixture(analysed: 2), "two vectors", candidate: soundA(0.01))
        // 3. Seven analysed: a LIVE profile (the re-rank term runs) but below
        //    `soundAdmitMinProfileVectors` — re-ranking a qualified pool is a cheap mistake,
        //    admitting a stranger is an expensive one, and the two bars are different numbers.
        assertUnchanged(fixture(analysed: 7), "seven vectors", candidate: soundA(0.01))
        // 4. Eight analysed of twenty members — 40% of the crate. Whatever those eight sound
        //    like is not "the crate's sound", and projecting it through the gate would let a
        //    sampling accident recruit.
        assertUnchanged(fixture(members: 20, analysed: 8), "40% analysed", candidate: soundA(0.01))
        // 5. A crate whose own radius is as wide as two random songs: the candidate sits EXACTLY
        //    on its centroid (distance 0) and is still refused, so it is the spread and nothing
        //    else doing the work.
        assertUnchanged(fixture(wideSpread: true), "spread ≈ random", candidate: soundMidpoint())
    }

    /// The door does not reopen any of the filters in front of it.
    func testAdmittedRowsStillRespectMembershipAndSuppression() {
        var f = fixture()
        // (a) SUPPRESSED in this tile — a 👎 given here tombstones the row, admitted or not.
        f.tracks.append(track("x-suppressed", artist: "Stranger A", genre: "jazz",
                              rawGenre: "Free Jazz", year: 2015))
        f.timbre["x-suppressed"] = soundA(0.01)
        // (b) The SAME RECORDING as an ad-hoc member (`amrec_<storeId>` ↔ `appleMusicId`) — the
        //     duplicate-identity class `RecMembership` exists for. A perfect vector must not be
        //     a way back in for something already filed here.
        f.tracks.append(ZoneEngine.Track(songId: "x-twin", artistKey: "stranger b",
                                         artistName: "Stranger B", genre: "jazz", year: 2015,
                                         appleMusicId: "9001", title: "x-twin",
                                         genreRaw: "Nu Jazz"))
        f.timbre["x-twin"] = soundA(0.005)
        var members = f.members
        members.append("amrec_9001")

        let out = ZoneEngine.rank(memberSongIds: members, tracks: f.tracks, playCount: { _ in 0 },
                                  feedback: ZoneEngine.Feedback(suppressed: ["x-suppressed"]),
                                  timbre: f.timbre)
        XCTAssertFalse(out.ids.contains("x-suppressed"))
        XCTAssertFalse(out.ids.contains("x-twin"))
        XCTAssertTrue(out.soundAdmitted.isEmpty,
                      "both strangers would have been the two best fits in the pool")
    }

    /// A 👎'd SOUND never admits. The admitted row's positive fit is 1.0 by construction, so the
    /// rejected profile is the only thing left that can disqualify it — and there is no metadata
    /// score here for a penalty to shade, so it is a veto.
    func testASoundTheOwnerRejectedIsNeverAdmitted() {
        var f = fixture()
        f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-alike"] = soundA(0.03)
        f.tracks.append(track("rejected", artist: "Refused", genre: "soul", rawGenre: "Neo-Soul",
                              year: 1990))
        f.timbre["rejected"] = soundA(0.03)

        XCTAssertEqual(rank(f).soundAdmitted, ["x-alike"], "control: with no verdict it is seated")
        let out = rank(f, feedback: ZoneEngine.Feedback(rejected: ["rejected": 1.0]))
        XCTAssertTrue(out.soundAdmitted.isEmpty,
                      "the 👎'd song sounds exactly like the candidate — the door shuts")
    }

    /// The top row belongs to the ranking, and the list length belongs to the catalog.
    func testAdmitNeverTakesTheTopRowAndNeverShortensTheList() {
        var f = fixture()
        for i in 0..<6 {
            let id = "x-\(i)"
            f.tracks.append(track(id, artist: "Stranger \(i)", genre: "jazz",
                                  rawGenre: "Genre \(i)", year: 1950 + i * 10))
            f.timbre[id] = soundA(0.005)   // a PERFECT fit, better than anything metadata found
        }
        let open = rank(f)
        let shut = ZoneEngine.suggestions(memberSongIds: f.members, tracks: f.tracks,
                                          playCount: { _ in 0 }, tuning: doorShut,
                                          timbre: f.timbre)
        XCTAssertEqual(open.ids.count, shut.count, "same length — rows spill, none is added")
        XCTAssertEqual(open.ids.first, shut.first,
                       "row 0 is the strongest metadata match the engine found, and a sound "
                       + "guess — however good the fit — does not displace it")
        XCTAssertFalse(open.soundAdmitted.contains(open.ids[0]))
        XCTAssertEqual(open.soundAdmitted.count, 3)
        // Seated at the reserved positions, never bunched at the head or dumped at the tail.
        let seats = open.ids.enumerated().filter { open.soundAdmitted.contains($0.element) }
            .map(\.offset)
        XCTAssertEqual(seats, [4, 9, 14])
    }

    /// A crate with no timbre corpus at all reaches none of this code and cannot crash in it.
    func testNoCorpusAtAllIsThePreV2Ranking() {
        var f = fixture(analysed: 0)
        f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        let out = ZoneEngine.rank(memberSongIds: f.members, tracks: f.tracks, playCount: { _ in 0 })
        XCTAssertTrue(out.soundAdmitted.isEmpty)
        XCTAssertNil(out.soundWords)
        XCTAssertEqual(out.ids,
                       ZoneEngine.suggestions(memberSongIds: f.members, tracks: f.tracks,
                                              playCount: { _ in 0 }, tuning: doorShut))
    }

    // ========================================================================
    // MARK: - The packed corpus (the perf shape the door forced)
    // ========================================================================

    /// The admit scan reads PACKED vectors because it cannot ride the gate's short-circuit — but
    /// an admission threshold measured on a different arithmetic than the ranking's would be a
    /// silent divergence, so the two implementations are pinned to each other here, including on
    /// the partial and non-finite vectors that are the whole reason `TimbreVector` is a dictionary.
    func testPackedDistanceIsTheSameArithmeticAsTheDictionaryDistance() {
        var cases: [(SimilarityFamilies.TimbreVector, SimilarityFamilies.TimbreVector)] = [
            (soundA(), soundA(0.03)), (soundA(), soundAFlipped()), (soundA(), soundA())]
        // A partial vector (4 axes dropped ⇒ 10 shared, still comparable).
        var partial = soundA(0.02)
        for axis in ["m1", "m2", "m3", "m4"] { partial[axis] = nil }
        cases.append((soundA(), partial))
        // …and one below the shared-axis minimum, which BOTH must refuse.
        var tooThin = soundA()
        for axis in SimilarityFamilies.timbreAxes.prefix(7) { tooThin[axis] = nil }
        cases.append((soundA(), tooThin))
        // …and a non-finite axis, which must be skipped rather than poison the sum.
        var nan = soundA(0.02)
        nan["bright"] = .nan
        cases.append((soundA(), nan))

        for (a, b) in cases {
            let dict = SimilarityFamilies.timbreDistance(a, b)
            let packed = SimilarityFamilies.timbreDistance(SimilarityFamilies.pack(a),
                                                           SimilarityFamilies.pack(b))
            switch (dict, packed) {
            case let (x?, y?): XCTAssertEqual(x, y, accuracy: 1e-12)
            case (nil, nil): break
            default: XCTFail("packed and dictionary distances disagreed about comparability")
            }
        }
    }

    /// A pre-packed corpus (what `ForYouFeedBuilder` hands every crate) must produce the identical
    /// ranking to letting the engine pack for itself — the whole point is that it is a cache, not
    /// a second implementation.
    func testAPrePackedCorpusRanksIdentically() {
        var f = fixture()
        f.tracks.append(track("x-alike", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-alike"] = soundA(0.03)
        let a = rank(f)
        let b = ZoneEngine.rank(memberSongIds: f.members, tracks: f.tracks, playCount: { _ in 0 },
                                timbre: f.timbre,
                                packed: SimilarityFamilies.pack(f.timbre))
        XCTAssertEqual(a.ids, b.ids)
        XCTAssertEqual(a.soundAdmitted, b.soundAdmitted)
    }

    // ========================================================================
    // MARK: - The door must not reopen the duplicate
    // ========================================================================

    /// **ONE RECORDING, ONE ROW — ACROSS BOTH POOLS.**
    ///
    /// The sound door opened a SECOND way into the list, and `RecRecordingIdentity.keepMask` used
    /// to run over the SCORED pool only. That leaves a real gap, narrow but exactly the shape of
    /// the bug the collapse was landed to kill:
    ///
    ///   · `ZoneEngine.Track.artistKey` is `IndexArtist.normalize(credit)` and does NOT strip a
    ///     credit tail, so "Stranger" and "Stranger feat. Guest" are two different artists to the
    ///     crate's artist-overlap test — one row takes the scored path, the other the admit path;
    ///   · `RecVersionIdentity.artistKey` DOES strip it, so the two rows share one recording key
    ///     and are, correctly, one recording.
    ///
    /// The genres differ for the same ordinary reason two catalog rows for one recording differ
    /// at all: `genre` comes from the ALBUM, and the same master sits on a soul compilation and a
    /// jazz one. So without a joint mask the tile shows the same song twice, once because
    /// metadata qualified it and once because it sounds like the crate.
    func testOneRecordingCannotHoldAScoredSeatAndAnAdmittedSeat() {
        var f = fixture()
        let twinSound = soundA(0.03)          // inside the door's radius either way

        // The SCORED instance: shares the crate's genre category, so the metadata gate passes it.
        f.tracks.append(ZoneEngine.Track(songId: "twin-scored", artistKey: "stranger",
                                         artistName: "Stranger", genre: "soul", year: 2015,
                                         title: "Expressway To Your Heart", lengthMs: 191_000,
                                         genreRaw: "Northern Soul"))
        // The ADMITTED instance: same recording, credited with a feature, filed under jazz — so
        // it shares NEITHER artist key NOR genre category and can only arrive through the door.
        f.tracks.append(ZoneEngine.Track(songId: "twin-admitted", artistKey: "strangerfeatguest",
                                         artistName: "Stranger feat. Guest", genre: "jazz",
                                         year: 2015, title: "Expressway To Your Heart",
                                         lengthMs: 191_000, genreRaw: "Jazz Funk"))
        f.timbre["twin-scored"] = twinSound
        f.timbre["twin-admitted"] = twinSound

        // A genuine stranger, so the door is demonstrably OPEN in this fixture and the assertion
        // below cannot be satisfied by the quota simply admitting nothing.
        f.tracks.append(track("x-alike", artist: "Nobody", genre: "jazz", rawGenre: "Free Jazz",
                              year: 1975))
        f.timbre["x-alike"] = soundA(0.03)

        let open = rank(f)
        XCTAssertTrue(open.ids.contains("x-alike"), "the door is open in this fixture")

        let twins = open.ids.filter { $0.hasPrefix("twin-") }
        XCTAssertEqual(twins.count, 1,
                       "one recording, one row — the admit pool is not a second door for a "
                       + "duplicate the scored pool already holds (got \(twins))")
        XCTAssertEqual(twins.first, "twin-scored",
                       "and the SCORED instance survives: `keepMask`'s tier asks the POOL first, "
                       + "because a net score and an RMS distance are not the same number, and a "
                       + "row metadata qualified is better evidence than one admitted on sound")
        XCTAssertFalse(open.soundAdmitted.contains("twin-admitted"),
                       "…so it must not be badged as a sound match either")
    }

    /// The other half of the same rule: the collapse must not become a filter. Two rows that are
    /// NOT one recording — same title and credit, but durations three minutes apart, which is the
    /// corroborator that kept 639 real rows out of a naive title+artist fusion — both keep their
    /// seat, one scored and one admitted.
    func testTwoDifferentRecordingsAreNotFusedAcrossThePools() {
        var f = fixture()
        f.tracks.append(ZoneEngine.Track(songId: "cut-studio", artistKey: "stranger",
                                         artistName: "Stranger", genre: "soul", year: 2015,
                                         title: "Expressway To Your Heart", lengthMs: 191_000,
                                         genreRaw: "Northern Soul"))
        f.tracks.append(ZoneEngine.Track(songId: "cut-live", artistKey: "strangerfeatguest",
                                         artistName: "Stranger feat. Guest", genre: "jazz",
                                         year: 2015, title: "Expressway To Your Heart",
                                         lengthMs: 371_000,          // a nine-minute live take
                                         genreRaw: "Jazz Funk"))
        f.timbre["cut-live"] = soundA(0.03)

        let open = rank(f)
        XCTAssertTrue(open.ids.contains("cut-studio"))
        XCTAssertTrue(open.ids.contains("cut-live"),
                      "the durations contradict the fusion, so these are two recordings and the "
                      + "collapse must err toward SPLITTING — it is a de-duplicator, not a filter")
        XCTAssertTrue(open.soundAdmitted.contains("cut-live"))
    }

    // ========================================================================
    // MARK: - The regime that actually SHIPS (radius, not the noise floor)
    // ========================================================================

    /// A vector at `shift` from the crate's own centre, built on a base with headroom at BOTH ends
    /// so a uniform shift is never clamped by `tvec` — the "uniform shift of s ⇒ RMS distance
    /// exactly s" identity is what lets these tests state distances in the units the thresholds
    /// are written in, and `soundA` (base 0.2, punch 0.9) cannot carry a ±0.17 shift without
    /// clipping two axes and quietly changing the distance.
    private func soundB(_ shift: Double = 0) -> SimilarityFamilies.TimbreVector {
        tvec(0.45, ["punch": 0.55, "busy": 0.5], shift: shift)
    }

    /// A crate at the spread REAL crates measure. `fixture()` builds members 0.002 apart, so its
    /// spread is floored by `timbreNoiseFloor` and every admission test above runs at radius
    /// `0.12 − 0.06 = 0.06`. The owner's 81 live pockets measure spread **0.156…0.180**, i.e.
    /// radius **0.096…0.120** — a band no test touched. It is not a rounding difference: on the
    /// shipped corpus 0.053 % of random pairs clear 0.06 and 2.75 % clear 0.11, so the tested door
    /// was ~52× narrower than the one that ships, and the other regime (`wideSpread: true`) is
    /// rejected outright by `soundAdmitMaxSpread`.
    ///
    /// Members alternate ±`spread` around the base, so the centroid is the base exactly and every
    /// member sits at distance `spread` from it — the profile's spread is the number asked for,
    /// not an emergent one, and `testTheRealisticFixtureReallyIsAtTheShippingRadius` proves it.
    private func realisticFixture(members: Int = 10, fillers: Int = 40,
                                  spread: Double = 0.17) -> Fixture {
        var tracks: [ZoneEngine.Track] = []
        var timbre: [String: SimilarityFamilies.TimbreVector] = [:]
        var ids: [String] = []
        for i in 0..<members {
            let id = "m-\(i)"
            ids.append(id)
            tracks.append(track(id, artist: "Member \(i)", genre: "soul", rawGenre: "Neo-Soul",
                                year: 1990))
            timbre[id] = soundB(i % 2 == 0 ? spread : -spread)
        }
        for i in 0..<fillers {
            tracks.append(track("f-\(i)", artist: "Filler \(i)", genre: "soul", rawGenre: "Soul",
                                year: 1990))
        }
        return Fixture(members: ids, tracks: tracks, timbre: timbre)
    }

    /// THE FIXTURE IS THE CLAIM, so measure it rather than assert on it by construction.
    func testTheRealisticFixtureReallyIsAtTheShippingRadius() throws {
        let f = realisticFixture()
        let profile = try XCTUnwrap(SimilarityFamilies.timbreProfile(
            f.members.compactMap { id in f.timbre[id].map { (vector: $0, weight: 1.0) } }))
        XCTAssertEqual(profile.spread, 0.17, accuracy: 1e-9,
                       "the crate sits inside the 0.156…0.180 band the live pockets measure")
        XCTAssertEqual(SimilarityFamilies.soundAdmitRadius(spread: profile.spread), 0.11,
                       accuracy: 1e-9,
                       "…so the door is at 0.11 — the crate's own spread less the margin, NOT the "
                       + "noise floor, which stops binding above spread 0.12")
        XCTAssertTrue(SimilarityFamilies.timbreProfileAdmits(profile, profileSize: f.members.count),
                      "and the preconditions pass, exactly as they do on 80 of the 81 real pockets")
    }

    /// The door opens at the radius a real crate produces — including on a candidate that the
    /// noise-floor regime every other test runs in would have REFUSED.
    func testSoundAdmitsAtTheRadiusRealCratesProduce() {
        var f = realisticFixture()
        f.tracks.append(track("x-near", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-near"] = soundB(0.10)     // 0.10 ≤ 0.11 — inside the shipping door…
        f.tracks.append(track("x-far", artist: "Outsider", genre: "metal", rawGenre: "Doom",
                              year: 2005))
        f.timbre["x-far"] = soundB(0.115)     // …and 0.115 is not, by five thousandths

        let open = rank(f)
        XCTAssertTrue(open.soundAdmitted.contains("x-near"),
                      "0.10 is nearly TWICE the 0.06 radius every other admission test runs at — "
                      + "this row is admitted only in the regime that actually ships")
        XCTAssertFalse(open.soundAdmitted.contains("x-far"),
                       "the radius still BITES at the shipping width; it is not open season")

        let shut = ZoneEngine.suggestions(memberSongIds: f.members, tracks: f.tracks,
                                          playCount: { _ in 0 }, tuning: doorShut,
                                          timbre: f.timbre)
        XCTAssertFalse(shut.contains("x-near"), "…and the gate is what kept it out before")
    }

    // ========================================================================
    // MARK: - The door is a SECOND WAY IN, so every demotion must reach it
    // ========================================================================

    /// A 👎 on another tile is promised to reach this row "through `negArtists`/`negGenres`". It
    /// did not reach an ADMITTED row: the admit branch checked tombstones and the rejected SOUND
    /// and nothing else, so a thumbs-downed artist walked past the gate on timbre and was seated
    /// at a reserved position.
    func testAThumbsDownedArtistCannotWalkInThroughTheSoundDoor() {
        var f = realisticFixture()
        f.tracks.append(track("x-near", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-near"] = soundB(0.10)
        // The 👎'd row itself: same artist, a DIFFERENT genre from the admitted row, and NO
        // vector — so neither the rejected SOUND profile nor `negGenres` can be what vetoes, and
        // the artist shape is measured alone.
        f.tracks.append(track("r-1", artist: "Stranger", genre: "blues", rawGenre: "Delta Blues",
                              year: 2011))

        XCTAssertTrue(rank(f).soundAdmitted.contains("x-near"),
                      "with no feedback it IS admitted — the veto below is what is being measured")
        let out = rank(f, feedback: ZoneEngine.Feedback(rejected: ["r-1": 1]))
        XCTAssertFalse(out.soundAdmitted.contains("x-near"),
                       "one 👎 saturates to 1/3, which at rejectionWeight 0.5 puts the net fit at "
                       + "0.833 — under the 0.9 bar, so sound alone no longer qualifies it")
    }

    /// …and the same for the rejected GENRE shape. An admitted row shares no genre with the CRATE
    /// by construction, but it can very well share one with a row the owner just rejected.
    func testAThumbsDownedGenreCannotWalkInThroughTheSoundDoor() {
        var f = realisticFixture()
        f.tracks.append(track("x-near", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-near"] = soundB(0.10)
        f.tracks.append(track("r-1", artist: "Someone Else", genre: "jazz", rawGenre: "Bebop",
                              year: 2011))

        XCTAssertTrue(rank(f).soundAdmitted.contains("x-near"))
        let out = rank(f, feedback: ZoneEngine.Feedback(rejected: ["r-1": 1]))
        XCTAssertFalse(out.soundAdmitted.contains("x-near"),
                       "the 👎'd genre reaches the door, not only the scored path")
    }

    /// THE BROADLY-REACHABLE ONE: `skipPenalty` is built from actual playback over the whole
    /// catalog (`Feedback.skipPenalties(plays:skips:)`), not from this tile's offers. A song the
    /// owner skips every time it plays was demoted up to 35 % on the scored path and admitted at
    /// FULL strength through the door.
    ///
    /// It stays a GRADED veto, not a filter: the door has no ordering to demote within, so the
    /// demotion lands on the same net fit — and the dampener that keeps one skip from burying a
    /// song keeps one skip from closing the door too.
    func testASongTheOwnerAlwaysSkipsIsNotSeatedOnSoundAlone() throws {
        var f = realisticFixture()
        f.tracks.append(track("x-near", artist: "Stranger", genre: "jazz", rawGenre: "Free Jazz",
                              year: 2015))
        f.timbre["x-near"] = soundB(0.10)

        let always = ZoneEngine.Feedback.skipPenalties(plays: ["x-near": 10], skips: ["x-near": 10])
        XCTAssertEqual(try XCTUnwrap(always["x-near"]), 10.0 / 13.0, accuracy: 1e-9)
        XCTAssertFalse(rank(f, feedback: ZoneEngine.Feedback(skipPenalty: always))
                           .soundAdmitted.contains("x-near"),
                       "0.77 skip pressure × 0.35 leaves a net fit of 0.73, under the 0.9 bar")

        let once = ZoneEngine.Feedback.skipPenalties(plays: ["x-near": 1], skips: ["x-near": 1])
        XCTAssertEqual(try XCTUnwrap(once["x-near"]), 0.25, accuracy: 1e-9)
        XCTAssertTrue(rank(f, feedback: ZoneEngine.Feedback(skipPenalty: once))
                          .soundAdmitted.contains("x-near"),
                      "…while ONE skip of one play is 0.25 → net fit 0.9125, still admitted: the "
                      + "Laplace dampener means the same thing on both paths into the tile")
    }

}
