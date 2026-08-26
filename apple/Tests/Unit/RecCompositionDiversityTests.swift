import XCTest
@testable import PocketDJ

/// `RecComposition`'s two new phases — the SOUND QUOTA's reserved slots and the RAW-GENRE
/// DIVERSITY FLOOR — as pure composition, away from the engine that feeds them.
///
/// Both default to OFF, and the first test here is that they do: `newcomer-parity.json` pins this
/// function against the Lambda's `composeIncumbentCap` list-for-list, and the Lambda has neither
/// phase. A default that ran either one would break that fixture — or, worse, quietly diverge the
/// device from the server on a surface where nobody is looking.
///
/// The floor is measured on RAW labels, never the 15 collapsed categories, because that is where
/// the cost was measured: with the timbre term on, a 25-row tile held 6.47 distinct raw genres
/// against 7.33 with it off, and 29.17% new-genre rows against 34.44%. Two of the fixture's
/// genres below ("Neo-Soul" and "Southern Soul") collapse to ONE category on purpose — an
/// implementation that counted categories would score this fixture as less various than it is and
/// stop swapping a row too early.
final class RecCompositionDiversityTests: XCTestCase {

    private func row(_ id: String, _ artist: String, incumbent: Bool = false,
                     genre: String? = nil, newGenre: Bool = false) -> RecComposition.Row {
        RecComposition.Row(id: id, capKey: artist, isIncumbent: incumbent,
                           rawGenre: genre, isNewGenre: newGenre)
    }

    // ========================================================================
    // MARK: - Off by default
    // ========================================================================

    func testBothPhasesAreOffByDefaultSoTheLambdaParityHolds() {
        let rows = (0..<30).map { row("s\($0)", "a\($0)", genre: "Soul") }
        let plain = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                           incumbentMaxShare: 0.5)
        let explicitlyOff = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                                   incumbentMaxShare: 0.5,
                                                   soundAdmit: nil, diversity: nil)
        XCTAssertEqual(plain, explicitlyOff)
        XCTAssertEqual(plain, (0..<25).map { "s\($0)" },
                       "with both phases off this is the identical walk it has always been")
    }

    // ========================================================================
    // MARK: - The diversity floor
    // ========================================================================

    /// The greedy top-25 holds four raw genres; six more sit deeper in the ranking. The floor
    /// swaps the lowest-ranked rows whose genre is already represented — which costs the tile no
    /// genre at all — for the deeper rows that carry one it lacks.
    func testDiversityFloorRaisesDistinctRawGenreCount() {
        // Rows 0…24: four genres, and two of them ("Neo-Soul"/"Southern Soul") are one CATEGORY.
        let top = ["Neo-Soul", "Southern Soul", "Disco", "Funk"]
        var rows = (0..<25).map { i in
            row("t\(String(format: "%02d", i))", "a\(i)", genre: top[i % top.count])
        }
        // Rows 25…: six genres the tile does not hold, all of them new to the crate.
        let deep = ["Techno", "Bebop", "Grunge", "Trap", "Highlife", "Ambient"]
        rows += deep.enumerated().map { i, g in
            row("d\(i)", "b\(i)", genre: g, newGenre: true)
        }

        let before = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                            incumbentMaxShare: 0.5)
        let after = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                           incumbentMaxShare: 0.5,
                                           diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        func genres(_ ids: [String]) -> Set<String> {
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return Set(ids.compactMap { byId[$0]?.rawGenre })
        }
        XCTAssertEqual(genres(before).count, 4, "the greedy walk stops at four")
        XCTAssertGreaterThanOrEqual(genres(after).count, 7,
                                    "the floor reaches its target — and note four of the "
                                    + "pre-floor genres fold into two CATEGORIES, so a "
                                    + "category-space floor would have thought it was already done")
        XCTAssertEqual(after.count, 25, "a floor never shortens a list")
        func newGenreShare(_ ids: [String]) -> Int {
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return ids.filter { byId[$0]?.isNewGenre == true }.count
        }
        XCTAssertGreaterThan(newGenreShare(after), newGenreShare(before),
                             "ONE mechanism raises BOTH measured numbers — the replacement order "
                             + "prefers a genre the CRATE does not hold, so distinct-genre count "
                             + "and new-genre share move together instead of failing apart")
        XCTAssertEqual(Set(after).count, after.count, "no row seated twice")
    }

    /// FAIL OPEN, exactly like the newcomer floor. A catalog that cannot supply the variety must
    /// produce the ranking's own list, not a shorter one and not a crash.
    func testDiversityFloorFailsOpenAndPreservesLength() {
        let rows = (0..<40).map { i in
            row("s\(String(format: "%02d", i))", "a\(i)", genre: i % 2 == 0 ? "Soul" : "Funk")
        }
        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 0.5,
                                         diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        XCTAssertEqual(out, RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                                   incumbentMaxShare: 0.5),
                       "only two genres exist anywhere — the walk stops on its first iteration "
                       + "and the list stands exactly as the ranking left it")
    }

    /// A row with no raw genre is never a REPLACEMENT (it adds nothing) but is a legitimate
    /// VICTIM (removing it costs no genre) — and the artist budget still outranks the floor: the
    /// floor may TRADE one of an artist's seats for another of his songs, never buy a fourth.
    func testDiversityFloorNeverExceedsTheArtistBudget() {
        var rows: [RecComposition.Row] = []
        for i in 0..<25 { rows.append(row("t\(String(format: "%02d", i))", "a\(i / 3)", genre: "Soul")) }
        rows.append(row("d-a0", "a0", genre: "Techno", newGenre: true))
        rows.append(row("d-ungenred", "z", genre: nil, newGenre: true))
        rows.append(row("d-ok", "z2", genre: "Bebop", newGenre: true))

        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 1.0,
                                         diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        XCTAssertEqual(out.count, 25)
        XCTAssertTrue(out.contains("d-ok"), "the floor swapped where it could")
        XCTAssertFalse(out.contains("d-ungenred"),
                       "a row with no genre cannot be the answer to 'the tile needs a genre'")
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let perArtist = out.reduce(into: [String: Int]()) { $0[byId[$1]!.capKey, default: 0] += 1 }
        XCTAssertEqual(perArtist.values.max(), 3,
                       "no artist ever exceeds the budget — a0 may swap one of its own three "
                       + "seats for its Techno row, and that is a trade, not a fourth seat")
    }

    /// The floor may not buy variety by breaking the OTHER floor — and when the only rows that
    /// carry a new genre are incumbents on a tile with no incumbent budget left, it stops.
    func testDiversityFloorNeverExceedsTheIncumbentCap() {
        var rows = (0..<25).map { i in
            row("t\(String(format: "%02d", i))", "a\(i)", incumbent: i < 12, genre: "Soul")
        }
        rows.append(row("d-inc", "z", incumbent: true, genre: "Bebop", newGenre: true))
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 0.5,
                                         diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        XCTAssertEqual(out.count, 25)
        XCTAssertLessThanOrEqual(out.filter { byId[$0]!.isIncumbent }.count, 12,
                                 "⌊25 × 0.5⌋ = 12 — the floor may trade one incumbent for "
                                 + "another to gain a genre, it may not seat a thirteenth")

        // …and with NO incumbent budget at all and nothing but incumbents to swap in, the floor
        // has no legal move and stands down.
        let newcomers = (0..<25).map { i in
            row("t\(String(format: "%02d", i))", "a\(i)", genre: "Soul")
        } + [row("d-inc", "z", incumbent: true, genre: "Bebop", newGenre: true)]
        let strict = RecComposition.compose(newcomers, limit: 25, maxPerArtist: 3,
                                            incumbentMaxShare: 0,
                                            diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        XCTAssertFalse(strict.contains("d-inc"))
        XCTAssertEqual(strict.count, 25)
    }

    /// The victim is the LOWEST-ranked redundant row, never a row from the head of the tile. The
    /// candidate's artist is at its budget and its only same-artist rows sit at ranks 0–2: an
    /// implementation that iterated candidates on the outside would walk up and evict rank 2.
    func testTheFloorEvictsTheLowestRankedRedundantRow() {
        var rows = (0..<3).map { row("head\($0)", "a0", genre: "Soul") }
        rows += (3..<25).map { row("t\(String(format: "%02d", $0))", "b\($0)", genre: "Soul") }
        rows.append(row("d-a0", "a0", genre: "Techno", newGenre: true))
        rows.append(row("d-free", "z", genre: "Bebop", newGenre: true))

        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 1.0,
                                         diversity: .init(minDistinctRawGenres: 2, maxSwaps: 1))
        XCTAssertEqual(Array(out.prefix(3)), ["head0", "head1", "head2"],
                       "the head of the ranking is untouched")
        XCTAssertEqual(out.last, "d-free",
                       "the last row — the lowest-ranked redundant one — is what pays, and the "
                       + "candidate whose artist has budget is what takes its place")
    }

    // ========================================================================
    // MARK: - The sound quota's reserved slots
    // ========================================================================

    func testSoundQuotaSeatsAtReservedPositionsAndPreservesLength() {
        let rows = (0..<40).map { row("s\(String(format: "%02d", $0))", "a\($0)", genre: "Soul") }
        let admit = [row("x0", "z0", genre: "Techno", newGenre: true),
                     row("x1", "z1", genre: "Bebop", newGenre: true),
                     row("x2", "z2", genre: "Trap", newGenre: true)]
        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 0.5,
                                         soundAdmit: .init(rows: admit, maxShare: 0.12, hardCap: 3))
        XCTAssertEqual(out.count, 25, "the quota reorders a tile, it never lengthens one")
        XCTAssertEqual([out.firstIndex(of: "x0"), out.firstIndex(of: "x1"), out.firstIndex(of: "x2")],
                       [4, 9, 14])
        XCTAssertEqual(out[0], "s00", "row 0 stays the ranking's own top row")
        XCTAssertEqual(out.suffix(3), ["s19", "s20", "s21"],
                       "the three rows that spilled are the LOWEST-ranked, never the top match")
    }

    /// The share binds on a SHORT list and the hard cap binds on a long one — which is why there
    /// are two constants and not one.
    func testSoundQuotaIsBoundedByBothTheShareAndTheHardCap() {
        let admit = (0..<6).map { row("x\($0)", "z\($0)", genre: "G\($0)", newGenre: true) }
        // A short tile: ⌊9 × 0.12⌋ = 1.
        let short = (0..<9).map { row("s\($0)", "a\($0)", genre: "Soul") }
        let outShort = RecComposition.compose(short, limit: 25, maxPerArtist: 3,
                                              incumbentMaxShare: 0.5,
                                              soundAdmit: .init(rows: admit, maxShare: 0.12,
                                                                hardCap: 3))
        XCTAssertEqual(outShort.filter { $0.hasPrefix("x") }.count, 1,
                       "a 9-row crate must not be a third guesses")
        // A long one: ⌊60 × 0.12⌋ = 7, but the hard cap is 3.
        let long = (0..<80).map { row("s\(String(format: "%02d", $0))", "a\($0)", genre: "Soul") }
        let outLong = RecComposition.compose(long, limit: 60, maxPerArtist: 3,
                                             incumbentMaxShare: 0.5,
                                             soundAdmit: .init(rows: admit, maxShare: 0.12,
                                                               hardCap: 3))
        XCTAssertEqual(outLong.filter { $0.hasPrefix("x") }.count, 3)
        XCTAssertEqual(outLong.count, 60)
    }

    /// The replacement pool is BOUNDED. A row 40,000 deep in the ranking carrying an unseen
    /// genre is not evidence of anything, and promoting it would make the floor a random-song
    /// generator with a rationale.
    func testDiversityFloorWillNotReachBeyondTheNearMissRegion() {
        var rows = (0..<25).map { row("t\(String(format: "%02d", $0))", "a\($0)", genre: "Soul") }
        rows += (25..<60).map { row("mid\($0)", "b\($0)", genre: "Soul") }
        rows.append(row("far", "z", genre: "Bebop", newGenre: true))   // index 60

        let reachable = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                               incumbentMaxShare: 1.0,
                                               diversity: .init(minDistinctRawGenres: 2,
                                                                maxSwaps: 5, searchDepth: 200))
        XCTAssertTrue(reachable.contains("far"), "inside the window it is promoted")
        let unreachable = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                                 incumbentMaxShare: 1.0,
                                                 diversity: .init(minDistinctRawGenres: 2,
                                                                  maxSwaps: 5, searchDepth: 30))
        XCTAssertFalse(unreachable.contains("far"),
                       "past the window the floor fails open rather than reaching for a stranger")
        XCTAssertEqual(unreachable.count, 25)
    }

    /// The floor defends the quota rather than undoing it: an admitted row is exactly the kind of
    /// variety the floor exists to protect, so it can never be chosen as a swap victim.
    func testTheDiversityFloorNeverEvictsASoundAdmittedRow() {
        // Every ranked row is "Soul"; the only other genres on the tile arrive through the door.
        let rows = (0..<40).map { row("s\(String(format: "%02d", $0))", "a\($0)", genre: "Soul") }
        let admit = [row("x0", "z0", genre: "Techno", newGenre: true),
                     row("x1", "z1", genre: "Bebop", newGenre: true),
                     row("x2", "z2", genre: "Trap", newGenre: true)]
        let out = RecComposition.compose(rows, limit: 25, maxPerArtist: 3,
                                         incumbentMaxShare: 0.5,
                                         soundAdmit: .init(rows: admit, maxShare: 0.12, hardCap: 3),
                                         diversity: .init(minDistinctRawGenres: 7, maxSwaps: 5))
        XCTAssertTrue(["x0", "x1", "x2"].allSatisfy(out.contains),
                      "the floor cannot reach its target here, and it must not pay for the "
                      + "attempt with the three rows that gave the tile any variety at all")
        XCTAssertEqual(out.count, 25)
    }
}
