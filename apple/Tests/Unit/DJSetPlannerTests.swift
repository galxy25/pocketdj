import XCTest
@testable import PocketDJ

/// np-dj-mode §4 — the PocketDJ selector: tempo waves, pockets, the renormalized score, fixed
/// rows, and determinism. Pure; no app state.
final class DJSetPlannerTests: XCTestCase {
    typealias C = DJSetPlanner.Candidate

    // MARK: helpers

    private func song(_ id: String, bpm: Double? = nil, key: String? = nil, genre: String? = nil,
                      year: Int? = nil, cols: Set<String> = [], fixed: Bool = false) -> C {
        C(songId: id, bpm: bpm, camelot: key, genre: genre, year: year, collections: cols, fixed: fixed)
    }

    /// The first seed whose wave/pocket lengths match.
    private func seed(wave0: Int? = nil, pocket0: Int? = nil, pocket1: Int? = nil) -> UInt64 {
        for s in UInt64(1)...10_000 {
            if let w = wave0, DJSetPlanner.waveLength(seed: s, index: 0) != w { continue }
            if let p = pocket0, DJSetPlanner.pocketLength(seed: s, index: 0) != p { continue }
            if let p = pocket1, DJSetPlanner.pocketLength(seed: s, index: 1) != p { continue }
            return s
        }
        XCTFail("no seed"); return 0
    }

    private func ordered(_ upcoming: [C], _ order: [UUID]) -> [C] {
        let byUid = Dictionary(uniqueKeysWithValues: upcoming.map { ($0.uid, $0) })
        return order.map { byUid[$0]! }
    }

    private func bands(_ songs: [C]) -> [Int] {
        songs.compactMap { DJSetPlanner.Features($0).band }
    }

    private let tempoOnly = DJSetPlanner.Options(tempoWaves: true, pockets: false, key: false)

    // MARK: tempo waves

    func testWavesBuildAndFall() {
        // Bands 100 ×3, 110 ×6, 120 ×3, listed scrambled (first row is a 100 so the set opens there).
        let pool = [song("a", bpm: 101), song("b", bpm: 121), song("c", bpm: 113), song("d", bpm: 104),
                    song("e", bpm: 117), song("f", bpm: 125), song("g", bpm: 111), song("h", bpm: 108),
                    song("i", bpm: 115), song("j", bpm: 119), song("k", bpm: 129), song("l", bpm: 112)]
        let st = DJSetPlanner.State(seed: seed(wave0: 2))
        let r = DJSetPlanner.plan(current: nil, upcoming: pool, state: st, options: tempoOnly)
        XCTAssertEqual(bands(ordered(pool, r.order)),
                       [100, 100, 100, 110, 110, 110, 120, 120, 120, 110, 110, 110],
                       "build up two bands, then come down")
    }

    func testThreeBandWaveClimbsThenFlips() {
        let pool = (0..<3).flatMap { i in [100, 110, 120, 130].map { song("s\($0)-\(i)", bpm: Double($0 + i)) } }
            + (0..<3).map { song("t\($0)", bpm: Double(125 + $0)) }
        let st = DJSetPlanner.State(seed: seed(wave0: 3))
        let r = DJSetPlanner.plan(current: nil, upcoming: pool, state: st, options: tempoOnly)
        XCTAssertEqual(bands(ordered(pool, r.order)),
                       [100, 100, 100, 110, 110, 110, 120, 120, 120, 130, 130, 130, 120, 120, 120])
    }

    func testMinimumThreePerBandCountsAlreadyPlayed() {
        // The playing song is a 105 (band 100, 1 played): two more 100s, then 110 — even though
        // the 110s come first in the queue.
        let pool = [song("x1", bpm: 112), song("x2", bpm: 114), song("x3", bpm: 116),
                    song("a1", bpm: 101), song("a2", bpm: 108)]
        let cur = song("cur", bpm: 105)
        let r = DJSetPlanner.plan(current: cur, upcoming: pool,
                                  state: DJSetPlanner.State(seed: 7), options: tempoOnly)
        XCTAssertEqual(bands(ordered(pool, r.order)), [100, 100, 110, 110, 110])
        XCTAssertEqual(r.state.band, 100)
        XCTAssertEqual(r.state.playedInBand, 1)

        // Three already played in band 100 (across advances) ⇒ step straight up.
        var st = DJSetPlanner.State(seed: 7)
        for b in [101.0, 103, 107] {
            st = DJSetPlanner.plan(current: song("p\(b)", bpm: b), upcoming: [], state: st, options: tempoOnly).state
        }
        XCTAssertEqual(st.playedInBand, 3)
        let pool2 = [song("a", bpm: 104), song("b", bpm: 113), song("c", bpm: 114), song("d", bpm: 115)]
        let r2 = DJSetPlanner.plan(current: nil, upcoming: pool2, state: st, options: tempoOnly)
        XCTAssertEqual(bands(ordered(pool2, r2.order)), [110, 110, 110, 100])
    }

    func testEarlyFlipAtPoolEdge() {
        // A 3-band wave would climb to 130, but 120 is the top of the pool: flip early.
        let pool = [song("a", bpm: 101), song("b", bpm: 121), song("c", bpm: 113), song("d", bpm: 104),
                    song("e", bpm: 117), song("f", bpm: 125), song("g", bpm: 111), song("h", bpm: 108),
                    song("i", bpm: 115), song("j", bpm: 119), song("k", bpm: 129), song("l", bpm: 112)]
        let st = DJSetPlanner.State(seed: seed(wave0: 3))
        let r = DJSetPlanner.plan(current: nil, upcoming: pool, state: st, options: tempoOnly)
        XCTAssertEqual(bands(ordered(pool, r.order)),
                       [100, 100, 100, 110, 110, 110, 120, 120, 120, 110, 110, 110])
    }

    func testSparseBandIsSkippedTowardPopulatedBand() {
        // Band 110 has one song: the wave skips to 120 (populated) and plays the stray last.
        let pool = [song("a", bpm: 101), song("s", bpm: 112), song("b", bpm: 103), song("c", bpm: 105),
                    song("d", bpm: 121), song("e", bpm: 123), song("f", bpm: 125)]
        let r = DJSetPlanner.plan(current: nil, upcoming: pool,
                                  state: DJSetPlanner.State(seed: seed(wave0: 3)), options: tempoOnly)
        let ids = ordered(pool, r.order).map(\.songId)
        XCTAssertEqual(Array(ids.prefix(3)).sorted(), ["a", "b", "c"])
        XCTAssertEqual(Array(ids[3..<6]).sorted(), ["d", "e", "f"])
        XCTAssertEqual(ids.last, "s")
    }

    // MARK: degrade / fixed rows

    func testNoMetadataKeepsOrder() {
        let pool = (0..<12).map { song("n\($0)") }
        for opts in [DJSetPlanner.Options.allOn, tempoOnly,
                     DJSetPlanner.Options(tempoWaves: false, pockets: false, key: false)] {
            let r = DJSetPlanner.plan(current: song("cur", bpm: 120, key: "8A", genre: "rock", year: 1990),
                                      upcoming: pool, state: DJSetPlanner.State(seed: 42), options: opts)
            XCTAssertEqual(r.order, pool.map(\.uid))
        }
    }

    func testAllOptionsOffKeepsOrderEvenWithMetadata() {
        let pool = [song("a", bpm: 150, key: "1A", genre: "rock", year: 1970),
                    song("b", bpm: 90, key: "8B", genre: "jazz", year: 2010),
                    song("c", bpm: 121, key: "8A", genre: "rock", year: 1990)]
        let r = DJSetPlanner.plan(current: song("cur", bpm: 120, key: "8A", genre: "rock", year: 1990),
                                  upcoming: pool, state: DJSetPlanner.State(seed: 1),
                                  options: .init(tempoWaves: false, pockets: false, key: false))
        XCTAssertEqual(r.order, pool.map(\.uid))
    }

    func testFixedRowsKeepTheirPositions() {
        var pool = [song("a", bpm: 140), song("b", bpm: 101), song("pin", bpm: 150, fixed: true),
                    song("c", bpm: 103), song("d", bpm: 130), song("jbx", fixed: true), song("e", bpm: 105)]
        pool.append(song("f", bpm: 107))
        let r = DJSetPlanner.plan(current: song("cur", bpm: 104), upcoming: pool,
                                  state: DJSetPlanner.State(seed: 3), options: .allOn)
        XCTAssertEqual(r.order[2], pool[2].uid)
        XCTAssertEqual(r.order[5], pool[5].uid)
        XCTAssertEqual(Set(r.order), Set(pool.map(\.uid)))
        XCTAssertEqual(r.order.count, pool.count)
        XCTAssertNotEqual(r.order, pool.map(\.uid), "the free rows were re-ordered")
    }

    func testBufferedNextRowIsHeld() {
        // The next row is a 150 that a tempo planner would never pick next — it's buffered, so
        // the caller marks it fixed and it stays first.
        let pool = [song("next", bpm: 150, fixed: true), song("a", bpm: 101), song("b", bpm: 103)]
        let r = DJSetPlanner.plan(current: song("cur", bpm: 102), upcoming: pool,
                                  state: DJSetPlanner.State(seed: 9), options: .allOn)
        XCTAssertEqual(r.order.first, pool[0].uid)
        // …and unfixed, it moves.
        var free = pool; free[0].fixed = false
        let r2 = DJSetPlanner.plan(current: song("cur", bpm: 102), upcoming: free,
                                   state: DJSetPlanner.State(seed: 9), options: .allOn)
        XCTAssertEqual(r2.order.last, pool[0].uid)
    }

    func testPartialMetadataNoBpmSongsNeverBreakTheCount() {
        // A no-BPM row (fixed between band-100 songs) doesn't reset the band count: current +
        // 2 more 100s, then 110.
        let pool = [song("a", bpm: 101), song("nil", fixed: true), song("x", bpm: 112), song("b", bpm: 108),
                    song("y", bpm: 115), song("z", bpm: 118)]
        let r = DJSetPlanner.plan(current: song("cur", bpm: 105), upcoming: pool,
                                  state: DJSetPlanner.State(seed: 5), options: tempoOnly)
        let ids = ordered(pool, r.order).map(\.songId)
        XCTAssertEqual(ids[1], "nil")
        XCTAssertEqual(bands(ordered(pool, r.order)), [100, 100, 110, 110, 110])
    }

    func testPartialMetadataKeyOnlySongPlacedByKeyFit() {
        // A song with only a key that matches the playing song's scores 1 on the one part it has
        // (renormalized), so missing tempo never counts against it.
        let pool = [song("a", bpm: 101), song("b", bpm: 109), song("keyed", key: "8A")]
        let r = DJSetPlanner.plan(current: song("cur", bpm: 105, key: "8A"), upcoming: pool,
                                  state: DJSetPlanner.State(seed: 5),
                                  options: .init(tempoWaves: true, pockets: false, key: true))
        XCTAssertEqual(ordered(pool, r.order).first?.songId, "keyed")
        // A no-data song is neutral (0.5) — behind good fits, never dropped.
        let pool2 = [song("bare"), song("a", bpm: 104), song("b", bpm: 106)]
        let r2 = DJSetPlanner.plan(current: song("cur", bpm: 105), upcoming: pool2,
                                   state: DJSetPlanner.State(seed: 5), options: tempoOnly)
        XCTAssertEqual(ordered(pool2, r2.order).map(\.songId), ["a", "b", "bare"])
    }

    func testKeyBreaksTempoTies() {
        let pool = [song("far", bpm: 106, key: "3B"), song("near", bpm: 106, key: "9A")]
        let r = DJSetPlanner.plan(current: song("cur", bpm: 106, key: "8A"), upcoming: pool,
                                  state: DJSetPlanner.State(seed: 1), options: .allOn)
        XCTAssertEqual(ordered(pool, r.order).first?.songId, "near")
    }

    // MARK: pockets

    func testPocketLengthsAreThreeToFour() {
        let s = seed(pocket0: 3, pocket1: 4)
        // X = rock 1980, Y = jazz 1982 (similarity ≈ 0.36: near adjacent), alternating in the queue.
        let pool = (0..<8).flatMap { i in [song("X\(i)", genre: "rock", year: 1980),
                                           song("Y\(i)", genre: "jazz", year: 1982)] }
        let opts = DJSetPlanner.Options(tempoWaves: true, pockets: true, key: true)
        let r = DJSetPlanner.plan(current: nil, upcoming: pool, state: DJSetPlanner.State(seed: s), options: opts)
        let letters = ordered(pool, r.order).map { String($0.songId.prefix(1)) }
        var runs: [Int] = []
        for (i, l) in letters.enumerated() {
            if i > 0, letters[i - 1] == l { runs[runs.count - 1] += 1 } else { runs.append(1) }
        }
        XCTAssertEqual(letters.first, "X")
        XCTAssertEqual(Array(runs.prefix(3)),
                       [3, 4, DJSetPlanner.pocketLength(seed: s, index: 2)], "runs: \(letters)")
    }

    func testNextPocketAnchorIsNearAdjacent() {
        let s = seed(pocket0: 3)
        let x = { (i: Int) in self.song("X\(i)", genre: "rock", year: 1980, cols: ["c1"]) }
        // Z: different genre, 35 years away (≈0 similar). Y: different genre, 2 years, same
        // collection — (0 + 0.72 + 1)/3 ≈ 0.57, near adjacent. X: identical (1.0, too close).
        let pool = [x(1), x(2), song("Z", genre: "pop", year: 2015, cols: ["c9"]), x(3),
                    song("Y", genre: "jazz", year: 1982, cols: ["c1"])]
        let opts = DJSetPlanner.Options(tempoWaves: false, pockets: true, key: false)
        let r = DJSetPlanner.plan(current: x(0), upcoming: pool, state: DJSetPlanner.State(seed: s), options: opts)
        let ids = ordered(pool, r.order).map(\.songId)
        XCTAssertEqual(Array(ids.prefix(3)), ["X1", "X2", "Y"], "\(ids)")

        // Failing a near-adjacent candidate, the best overall (here: queue order) anchors.
        let pool2 = [x(1), x(2), song("Z", genre: "pop", year: 2015), x(3)]
        let r2 = DJSetPlanner.plan(current: x(0), upcoming: pool2, state: DJSetPlanner.State(seed: s), options: opts)
        XCTAssertEqual(ordered(pool2, r2.order).map(\.songId)[2], "Z")
    }

    func testSimilarityRenormalizesOverKnownParts() {
        typealias F = DJSetPlanner.Features
        XCTAssertNil(DJSetPlanner.similarity(F(genre: "rock"), F(year: 1990)))
        XCTAssertEqual(DJSetPlanner.similarity(F(genre: "rock"), F(genre: "Rock")), 1)
        XCTAssertEqual(DJSetPlanner.similarity(F(genre: "rock", year: 1990), F(genre: "jazz", year: 1990)), 0.5)
        XCTAssertEqual(DJSetPlanner.similarity(F(collections: ["a", "b"]), F(collections: ["b", "c"]))!,
                       1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(DJSetPlanner.similarity(F(year: 1990), F(year: 1996))!, exp(-1), accuracy: 1e-9)
        XCTAssertNil(F(genre: "Other").genre, "Genre.other is unknown")
        XCTAssertEqual(F(bpm: 60).bpm, 120, "tempo is folded")
        XCTAssertEqual(F(bpm: 60).band, 120)
        XCTAssertNil(F(camelot: "H#").camelot)
        XCTAssertEqual(F(camelot: " 8a").camelot, "8A")
        let c = DJSetPlanner.candidate(uid: UUID(), songId: "s", bpm: 100, camelot: "8A",
                                       rawGenre: "Boom Bap", year: 0, collections: [], fixed: false)
        XCTAssertEqual(c.genre, "hip-hop")
        XCTAssertNil(c.year)
    }

    // MARK: state / determinism

    func testAccountingIsIdempotentPerUid() {
        let cur = song("cur", bpm: 105, genre: "rock")
        let a = DJSetPlanner.plan(current: cur, upcoming: [], state: DJSetPlanner.State(seed: 1), options: .allOn).state
        let b = DJSetPlanner.plan(current: cur, upcoming: [song("q", bpm: 140)], state: a, options: .allOn).state
        XCTAssertEqual(a, b)
        XCTAssertEqual(b.playedInBand, 1)
        XCTAssertEqual(b.pocketCount, 1)
        // State survives a JSON round-trip (it persists with the session).
        let data = try! JSONEncoder().encode(b)
        XCTAssertEqual(try! JSONDecoder().decode(DJSetPlanner.State.self, from: data), b)
    }

    func testDeterministicAndAPermutation() {
        var rng = SplitMix64(seed: 99)
        let genres = ["rock", "jazz", "soul", nil]
        for trial in 0..<40 {
            let n = 5 + Int(rng.next() % 30)
            let pool: [C] = (0..<n).map { i in
                let r = rng.next()
                return C(songId: "t\(trial)-\(i)",
                         bpm: r % 5 == 0 ? nil : 70 + Double(r % 100),
                         camelot: r % 3 == 0 ? nil : "\(1 + Int(r % 12))\(r % 2 == 0 ? "A" : "B")",
                         genre: genres[Int((r >> 8) % 4)],
                         year: r % 7 == 0 ? nil : 1960 + Int((r >> 16) % 60),
                         collections: r % 4 == 0 ? [] : ["c\((r >> 24) % 5)"],
                         fixed: (r >> 32) % 9 == 0)
            }
            let st = DJSetPlanner.State(seed: rng.next())
            let a = DJSetPlanner.plan(current: pool.first, upcoming: Array(pool.dropFirst()), state: st, options: .allOn)
            let b = DJSetPlanner.plan(current: pool.first, upcoming: Array(pool.dropFirst()), state: st, options: .allOn)
            XCTAssertEqual(a.order, b.order)
            XCTAssertEqual(a.state, b.state)
            let up = Array(pool.dropFirst())
            XCTAssertEqual(a.order.count, up.count)
            XCTAssertEqual(Set(a.order), Set(up.map(\.uid)))
            for (i, c) in up.enumerated() where c.fixed { XCTAssertEqual(a.order[i], c.uid) }
        }
    }

    func testSeededLengthsCoverTheirRanges() {
        let waves = Set((0..<64).map { DJSetPlanner.waveLength(seed: 12345, index: $0) })
        let pockets = Set((0..<64).map { DJSetPlanner.pocketLength(seed: 12345, index: $0) })
        XCTAssertEqual(waves, [2, 3])
        XCTAssertEqual(pockets, [3, 4])
        XCTAssertEqual(DJSetPlanner.waveLength(seed: 77, index: 4), DJSetPlanner.waveLength(seed: 77, index: 4))
    }

    // MARK: artist spacing (Levi's 2026-11-10 drive: two artists alternating → four skips)

    /// Pocket similarity alone would chain the two near-identical artists back to back; the
    /// spacing rule keeps each out of the next 3 slots while another free row can play.
    func testArtistSpacingBreaksAPocketCollapse() {
        func s(_ id: String, _ artist: String, bpm: Double, cols: Set<String>) -> C {
            C(songId: id, bpm: bpm, genre: "hip-hop", year: 2017, collections: cols, artists: [artist])
        }
        let tight: Set<String> = ["potential", "drive"]
        let cur = s("cur", "goldlink", bpm: 100, cols: tight)
        let up = [
            s("g1", "goldlink", bpm: 100, cols: tight), s("c1", "cousin stizz", bpm: 101, cols: tight),
            s("g2", "goldlink", bpm: 101, cols: tight), s("c2", "cousin stizz", bpm: 100, cols: tight),
            s("x1", "phonte", bpm: 104, cols: ["other"]), s("x2", "sir", bpm: 106, cols: ["other"]),
            s("x3", "lady wray", bpm: 103, cols: ["other"]), s("x4", "kenny muney", bpm: 105, cols: ["other"]),
        ]
        let r = DJSetPlanner.plan(current: cur, upcoming: up, state: .init(seed: 1), options: .allOn)
        let played = [cur] + ordered(up, r.order)
        for (i, c) in played.enumerated() {
            let window = played[max(0, i - DJSetPlanner.artistSpacing + 1)..<i]
            XCTAssertFalse(window.contains { !$0.artists.isDisjoint(with: c.artists) },
                           "\(c.songId) repeats an artist within \(DJSetPlanner.artistSpacing) slots: \(played.map(\.songId))")
        }
    }

    /// One artist only: spacing can't be met, so the planner still places every row.
    func testArtistSpacingYieldsWhenImpossible() {
        let up = (0..<5).map { C(songId: "a\($0)", bpm: 100 + Double($0), artists: ["solo"]) }
        let r = DJSetPlanner.plan(current: C(songId: "cur", bpm: 100, artists: ["solo"]), upcoming: up,
                                  state: .init(seed: 1), options: .allOn)
        XCTAssertEqual(Set(r.order), Set(up.map(\.uid)))
    }

    /// A featured credit counts: "x feat. goldlink" is blocked right after a GoldLink song.
    func testArtistSpacingCountsAnySharedCredit() {
        let cur = C(songId: "cur", bpm: 100, artists: ["goldlink"])
        let up = [C(songId: "feat", bpm: 100, artists: ["kaytranada", "goldlink"]),
                  C(songId: "far", bpm: 140, artists: ["sir"])]
        let r = DJSetPlanner.plan(current: cur, upcoming: up, state: .init(seed: 1), options: tempoOnly)
        XCTAssertEqual(ordered(up, r.order).map(\.songId), ["far", "feat"])
    }
}
