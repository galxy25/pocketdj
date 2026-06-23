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

/// SearchService.sortBody maps the Browser's multi-key sort into an OpenSearch
/// `sort` array so the SERVER orders the full result set (paging is server-side, so
/// the client can't sort across pages). Text fields sort on their `.kw` keyword
/// subfield, genre on `genreCategory`, numerics on the field itself, and EVERY array
/// ends with a deterministic `{"id": "asc"}` tiebreaker for stable from/size paging.
final class SearchSortTests: XCTestCase {

    /// Flatten one {field: {order: dir}} sort entry to (field, dir).
    private func entry(_ d: [String: Any]) -> (field: String, dir: String)? {
        guard let field = d.keys.first, let inner = d[field] as? [String: Any],
              let dir = inner["order"] as? String else { return nil }
        return (field, dir)
    }

    func testTextFieldsSortOnKeywordSubfieldAndGenreOnCategory() {
        let keys = [SortKey(field: "name", dir: .asc),
                    SortKey(field: "genre", dir: .desc),
                    SortKey(field: "year", dir: .asc)]
        let sort = SearchService.sortBody(keys, hasQuery: false)

        // name → title.kw, genre → genreCategory, year → year, + trailing id asc.
        XCTAssertEqual(sort.count, 4)
        XCTAssertEqual(entry(sort[0])?.field, "title.kw")
        XCTAssertEqual(entry(sort[0])?.dir, "asc")
        XCTAssertEqual(entry(sort[1])?.field, "genreCategory")
        XCTAssertEqual(entry(sort[1])?.dir, "desc")
        XCTAssertEqual(entry(sort[2])?.field, "year")
        XCTAssertEqual(entry(sort[2])?.dir, "asc")
        // ALWAYS a deterministic id tiebreaker last (stable pagination).
        XCTAssertEqual(entry(sort.last!)?.field, "id")
        XCTAssertEqual(entry(sort.last!)?.dir, "asc")
    }

    func testDirectionHonoredAndArtistUsesKeyword() {
        let sort = SearchService.sortBody([SortKey(field: "artist", dir: .desc)], hasQuery: false)
        XCTAssertEqual(entry(sort[0])?.field, "artist.kw")
        XCTAssertEqual(entry(sort[0])?.dir, "desc")
        XCTAssertEqual(entry(sort.last!)?.field, "id")
    }

    func testEmptyKeysFilterOnlySortsByIdOnly() {
        // No query, no sort keys: deterministic id-only order.
        let sort = SearchService.sortBody([], hasQuery: false)
        XCTAssertEqual(sort.count, 1)
        XCTAssertEqual(entry(sort[0])?.field, "id")
        XCTAssertEqual(entry(sort[0])?.dir, "asc")
    }

    func testEmptyKeysWithQueryStillAppendsIdTiebreaker() {
        // With a query and no explicit sort, _score leads implicitly; the id
        // tiebreaker still makes equally-scored hits page in a stable order.
        let sort = SearchService.sortBody([], hasQuery: true)
        XCTAssertEqual(sort.count, 1)
        XCTAssertEqual(entry(sort[0])?.field, "id")
    }

    func testUnknownSortFieldDropped() {
        // An unmapped field id is skipped, but the id tiebreaker still anchors paging.
        let sort = SearchService.sortBody([SortKey(field: "nope", dir: .asc)], hasQuery: false)
        XCTAssertEqual(sort.count, 1)
        XCTAssertEqual(entry(sort[0])?.field, "id")
    }

    func testNumericAndKeywordFieldsMapDirectly() {
        let keys = [SortKey(field: "bpm", dir: .asc), SortKey(field: "camelot", dir: .desc),
                    SortKey(field: "source", dir: .asc)]
        let sort = SearchService.sortBody(keys, hasQuery: false)
        XCTAssertEqual(entry(sort[0])?.field, "bpm")        // numeric → field directly
        XCTAssertEqual(entry(sort[1])?.field, "camelot")    // keyword → field directly
        XCTAssertEqual(entry(sort[2])?.field, "source")
        XCTAssertEqual(entry(sort.last!)?.field, "id")
    }
}
