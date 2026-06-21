import XCTest
@testable import PocketDJ

/// FilterQuery translates the app's Clause model into OpenSearch bool-query
/// clauses so ONLINE search honors the same filters as on-device. Keyword values
/// are lowercased to match the index's `lc` normalizer (case-insensitive parity).
final class SearchQueryTests: XCTestCase {

    private func build(_ clauses: [Clause]) -> (filter: [[String: Any]], mustNot: [[String: Any]]) {
        var filter: [[String: Any]] = []
        var mustNot: [[String: Any]] = []
        for c in clauses { FilterQuery.append(c, into: &filter, mustNot: &mustNot) }
        return (filter, mustNot)
    }

    // Pull the first {op: {field: value}} entry as a flat tuple for assertions.
    private func entry(_ d: [String: Any]) -> (op: String, field: String, value: Any)? {
        guard let op = d.keys.first, let inner = d[op] as? [String: Any],
              let field = inner.keys.first else { return nil }
        return (op, field, inner[field] as Any)
    }

    func testStringEqLowercasesAndUsesKeywordSubfield() {
        let (filter, mustNot) = build([Clause(field: "artist", op: .eq, value: "Aria")])
        XCTAssertTrue(mustNot.isEmpty)
        let e = entry(filter[0])
        XCTAssertEqual(e?.op, "term")
        XCTAssertEqual(e?.field, "artist.kw")
        XCTAssertEqual(e?.value as? String, "aria")
    }

    func testStringNeqGoesToMustNot() {
        let (filter, mustNot) = build([Clause(field: "source", op: .neq, value: "My Vinyl")])
        XCTAssertTrue(filter.isEmpty)
        let e = entry(mustNot[0])
        XCTAssertEqual(e?.op, "term")
        XCTAssertEqual(e?.field, "source")
        XCTAssertEqual(e?.value as? String, "my vinyl")
    }

    func testGenreMapsToGenreCategory() {
        let (filter, _) = build([Clause(field: "genre", op: .eq, value: "electronic")])
        let e = entry(filter[0])
        XCTAssertEqual(e?.field, "genreCategory")
        XCTAssertEqual(e?.value as? String, "electronic")
    }

    func testInListBecomesTermsLowercased() {
        var c = Clause(field: "camelot", op: .inList); c.values = ["8A", "8B"]
        let (filter, _) = build([c])
        let e = entry(filter[0])
        XCTAssertEqual(e?.op, "terms")
        XCTAssertEqual(e?.field, "camelot")
        XCTAssertEqual(Set(e?.value as? [String] ?? []), ["8a", "8b"])
    }

    func testNumberBetweenBecomesRangeWithInts() {
        var c = Clause(field: "bpm", op: .between); c.min = 100; c.max = 130
        let (filter, _) = build([c])
        guard let r = (filter[0]["range"] as? [String: Any])?["bpm"] as? [String: Any] else {
            return XCTFail("expected range bpm")
        }
        XCTAssertEqual(r["gte"] as? Int, 100)
        XCTAssertEqual(r["lte"] as? Int, 130)
    }

    func testNumberEqEmitsIntForWholeValues() {
        let (filter, _) = build([Clause(field: "year", op: .eq, value: "2020")])
        let e = entry(filter[0])
        XCTAssertEqual(e?.field, "year")
        XCTAssertEqual(e?.value as? Int, 2020)
    }

    func testExplicitBoolTerm() {
        let (filter, _) = build([Clause(field: "explicit", op: .eq, value: "true")])
        let e = entry(filter[0])
        XCTAssertEqual(e?.field, "explicit")
        XCTAssertEqual(e?.value as? Bool, true)
    }

    func testSentimentInListUsesKeywordSubfield() {
        var c = Clause(field: "sentiment", op: .inList); c.values = ["Night", "Drive"]
        let (filter, _) = build([c])
        let e = entry(filter[0])
        XCTAssertEqual(e?.op, "terms")
        XCTAssertEqual(e?.field, "sentiment.kw")
        XCTAssertEqual(Set(e?.value as? [String] ?? []), ["night", "drive"])
    }

    func testIncompleteClauseIsSkipped() {
        let (filter, mustNot) = build([Clause(field: "bpm", op: .eq, value: "")])
        XCTAssertTrue(filter.isEmpty && mustNot.isEmpty)
    }

    func testMultipleClausesCompose() {
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        let expl = Clause(field: "explicit", op: .eq, value: "true")
        let src = Clause(field: "source", op: .neq, value: "Web")
        let (filter, mustNot) = build([bpm, expl, src])
        XCTAssertEqual(filter.count, 2)   // range bpm + term explicit
        XCTAssertEqual(mustNot.count, 1)  // must_not term source
    }
}
