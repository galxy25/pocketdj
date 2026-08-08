import XCTest
@testable import PocketDJ

/// The Add-to-collection sheet's name filter (Levi 2026-08: "fuzzy text search against the
/// playlist or pocket name"). Fuzzy here means THREE things, and each has to keep working:
/// dropped characters ("80snght"), initials ("fnm"), and real typos — a transposition or a
/// wrong letter, which a subsequence walk alone can never match.
final class FuzzyMatchTests: XCTestCase {

    private let names = ["80s Night", "Friday Night Mix", "Roadtrip", "Warmup",
                         "Chill Sunday", "Night Owl", "Bangers", "Deep House 2024"]

    private func ranked(_ q: String) -> [String] {
        FuzzyMatch.rank(names, query: q) { $0 }
    }

    // MARK: Literal

    func testExactAndCaseInsensitiveAndPunctuationInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "80s night", candidate: "80s Night"))
        XCTAssertNotNil(FuzzyMatch.score(query: "80S-NIGHT", candidate: "80s Night"))
        XCTAssertNotNil(FuzzyMatch.score(query: "80snight", candidate: "80s Night"))
        // Exact beats every looser hit.
        let exact = FuzzyMatch.score(query: "roadtrip", candidate: "Roadtrip") ?? 0
        let loose = FuzzyMatch.score(query: "roadtrip", candidate: "Roadtrip Reloaded") ?? 0
        XCTAssertGreaterThan(exact, loose)
    }

    func testSubstringStillMatches() {
        XCTAssertEqual(ranked("night").first, "Night Owl")     // prefix outranks substring
        XCTAssertTrue(ranked("night").contains("80s Night"))
        XCTAssertTrue(ranked("night").contains("Friday Night Mix"))
        XCTAssertFalse(ranked("night").contains("Roadtrip"))
    }

    // MARK: Subsequence (Levi's example)

    /// THE case from the request: "80snght" — every vowel and the space dropped — finds
    /// "80s Night", and nothing else in the list.
    func testDroppedCharactersFindTheName() {
        XCTAssertEqual(ranked("80snght"), ["80s Night"])
    }

    func testInitialsFindAMultiWordName() {
        XCTAssertEqual(ranked("fnm").first, "Friday Night Mix")
    }

    // MARK: Typos (the pass a subsequence walk cannot do)

    /// A transposed pair ("Nigth"): NOT a subsequence of "80snight" (the h precedes the t),
    /// so this only passes through the approximate-distance pass.
    func testTransposedLettersStillMatch() {
        XCTAssertFalse(isSubsequence("80snigth", of: "80snight"),
                       "guard: if this became a subsequence the typo pass would be untested")
        XCTAssertEqual(ranked("80s Nigth"), ["80s Night"])
    }

    func testSubstitutedLetterStillMatches() {
        XCTAssertEqual(ranked("roadtrup"), ["Roadtrip"])       // i → u
        XCTAssertEqual(ranked("bangors"), ["Bangers"])         // e → o
    }

    func testExtraLetterStillMatches() {
        XCTAssertEqual(ranked("warmupp"), ["Warmup"])
    }

    /// A typo INSIDE a longer name still matches — the distance pass starts and ends
    /// anywhere in the candidate.
    func testTypoWithinALongerName() {
        XCTAssertTrue(ranked("fridya").contains("Friday Night Mix"))
    }

    /// The error budget scales with query length, so a short query can't fuzz into
    /// everything: "xyz" matches nothing at all.
    func testNonsenseMatchesNothing() {
        XCTAssertEqual(ranked("xyz"), [])
        XCTAssertNil(FuzzyMatch.score(query: "zzzz", candidate: "80s Night"))
    }
    func testShortQueriesGetNoTypoBudget() {
        XCTAssertEqual(FuzzyMatch.errorBudget(3), 0)
        XCTAssertEqual(FuzzyMatch.errorBudget(4), 1)
        XCTAssertEqual(FuzzyMatch.errorBudget(7), 1)
        XCTAssertEqual(FuzzyMatch.errorBudget(12), 3)
    }

    // MARK: Ranking + the empty query

    /// An empty (or whitespace-only) query is "not searching": the list comes back whole and
    /// in the caller's order — the sheet with no query must look exactly as it did before.
    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(ranked(""), names)
        XCTAssertEqual(ranked("   "), names)
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
    }

    func testBestMatchRanksFirst() {
        // "Warmup" is the exact name; "Warm Up Two" is a looser hit on the same query.
        let list = ["Warm Up Two", "Warmup"]
        XCTAssertEqual(FuzzyMatch.rank(list, query: "warmup") { $0 }.first, "Warmup")
    }

    func testTiesKeepTheCallersOrder() {
        // Identical names ⇒ identical scores; the input order must survive (rank is stable).
        let list = ["Set A", "Set B", "Set C"]
        XCTAssertEqual(FuzzyMatch.rank(list, query: "set") { $0 }, list)
    }

    func testDiacriticsFold() {
        XCTAssertNotNil(FuzzyMatch.score(query: "cafe", candidate: "Café Nights"))
        XCTAssertNotNil(FuzzyMatch.score(query: "café", candidate: "Cafe Nights"))
    }

    func testEmptyCandidateNeverMatches() {
        XCTAssertNil(FuzzyMatch.score(query: "mix", candidate: ""))
        XCTAssertNil(FuzzyMatch.score(query: "mix", candidate: "  —  "))
    }

    // MARK: Distance primitive

    func testApproximateDistanceIsSubstringAnchored() {
        let q = Array("night")
        XCTAssertEqual(FuzzyMatch.approximateDistance(q, Array("80snight")), 0)   // free start/end
        XCTAssertEqual(FuzzyMatch.approximateDistance(q, Array("80snigth")), 1)   // one transposition
        XCTAssertEqual(FuzzyMatch.approximateDistance(q, Array("80snigt")), 1)    // one deletion
    }

    // MARK: Helper

    private func isSubsequence(_ q: String, of c: String) -> Bool {
        var it = c.makeIterator()
        var next = it.next()
        for ch in q {
            while let n = next, n != ch { next = it.next() }
            guard next != nil else { return false }
            next = it.next()
        }
        return true
    }
}
