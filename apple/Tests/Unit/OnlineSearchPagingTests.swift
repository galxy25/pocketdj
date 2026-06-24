import XCTest
@testable import PocketDJ

/// OnlineSearchModel pages OpenSearch results: the first page loads on a new
/// query/filter, `loadMore()` APPENDS the next `from = loadedCount` page as the
/// user scrolls, `hasMore` is derived from `loadedCount < total`, and a new query
/// RESETS the accumulator. These drive a stubbed `Searching` seam (no network).
@MainActor
final class OnlineSearchPagingTests: XCTestCase {

    /// Records the `from`/`size` of every call and serves a slice of a synthetic
    /// album corpus, reporting `total` as the full corpus size each page.
    final class StubSearch: Searching {
        let total: Int
        private(set) var calls: [(from: Int, size: Int)] = []
        /// `sortKeys` recorded per call so sort-reset/loadMore tests can assert the
        /// server received the Browser's sort on each page.
        private(set) var sortCalls: [[SortKey]] = []

        init(total: Int) { self.total = total }

        func search(_ query: String, kind: ItemKind?, clauses: [Clause],
                    sortKeys: [SortKey], creds: SigV4Creds,
                    from: Int, size: Int) async throws -> SearchResults {
            calls.append((from, size))
            sortCalls.append(sortKeys)
            let upper = min(from + size, total)
            let hits = (from..<max(from, upper)).map { i in
                SearchHit(id: "alb_\(i)", type: "album", title: "Album \(i)", artist: "Artist",
                          album: nil, albumId: nil, genre: "Electronic", year: 2020, bpm: nil,
                          key: nil, camelot: nil, explicit: nil, trackNumber: nil, source: "Web")
            }
            return SearchResults(hits: hits, total: total)
        }
    }

    /// A search seam that always throws — used to prove a first-page failure resets.
    struct FailingSearch: Searching {
        func search(_ query: String, kind: ItemKind?, clauses: [Clause],
                    sortKeys: [SortKey], creds: SigV4Creds,
                    from: Int, size: Int) async throws -> SearchResults {
            throw NSError(domain: "test", code: 1)
        }
    }

    private let creds = SigV4Creds(accessKeyId: "A", secretAccessKey: "S")

    private func app() async -> AppModel {
        let m = AppModel(loader: TestData.StubLoader())
        await m.loadIfNeeded()
        return m
    }

    func testFirstPageLoadsAndDerivesHasMore() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(model.loadedCount, 50)
        XCTAssertEqual(model.total, 130)
        XCTAssertTrue(model.hasMore)                 // 50 < 130
        XCTAssertEqual(stub.calls.first?.from, 0)
        XCTAssertEqual(stub.calls.first?.size, 50)
    }

    func testLoadMoreAppendsAndAdvancesOffset() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        await model.loadMore()

        XCTAssertEqual(model.items.count, 100)       // 50 appended onto 50
        XCTAssertEqual(model.loadedCount, 100)
        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(stub.calls[1].from, 50)       // next page offset = loadedCount
        XCTAssertTrue(model.hasMore)                 // 100 < 130
    }

    func testPagingToCompletionClearsHasMore() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        await model.loadMore()                       // 100
        await model.loadMore()                       // 130 (last page is 30)

        XCTAssertEqual(model.items.count, 130)
        XCTAssertEqual(model.loadedCount, 130)
        XCTAssertFalse(model.hasMore)                // loadedCount == total

        // Further calls no-op (no extra request) once everything is loaded.
        await model.loadMore()
        XCTAssertEqual(stub.calls.count, 3)
    }

    func testLoadMoreNoOpsWhenNoMore() async {
        let stub = StubSearch(total: 30)             // single page
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        XCTAssertFalse(model.hasMore)                // 30 < 50 ⇒ already complete
        await model.loadMore()
        XCTAssertEqual(stub.calls.count, 1)          // no second request
    }

    func testNewQueryResetsAccumulator() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 100)

        // A fresh query RESETS: offset back to 0, accumulator cleared, first page only.
        await model.startSearch(query: "y", kind: .album, creds: creds, app: app)
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(model.loadedCount, 50)
        XCTAssertEqual(stub.calls.last?.from, 0)
    }

    func testDeDupesByIdAcrossPagesButOffsetStillAdvances() async {
        // A stub that returns the SAME ids on both pages — items must not double up,
        // yet loadedCount still advances by the raw page count so paging terminates.
        final class DupStub: Searching {
            func search(_ query: String, kind: ItemKind?, clauses: [Clause],
                        sortKeys: [SortKey], creds: SigV4Creds,
                        from: Int, size: Int) async throws -> SearchResults {
                let hits = (0..<size).map { i in
                    SearchHit(id: "dup_\(i)", type: "album", title: "A", artist: "B", album: nil,
                              albumId: nil, genre: nil, year: nil, bpm: nil, key: nil, camelot: nil,
                              explicit: nil, trackNumber: nil, source: "Web")
                }
                return SearchResults(hits: hits, total: 200)
            }
        }
        let model = OnlineSearchModel(service: DupStub(), pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        await model.loadMore()

        XCTAssertEqual(model.items.count, 50)        // de-duped — no duplicates appended
        XCTAssertEqual(model.loadedCount, 100)       // offset still advanced by raw counts
    }

    func testHasMoreCappedAtMaxResultWindow() async {
        // total exceeds the 10k offset window: once loadedCount hits the cap,
        // hasMore is false even though total > loadedCount.
        let stub = StubSearch(total: 50_000)
        let model = OnlineSearchModel(service: stub, pageSize: SearchService.maxResultWindow)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)
        XCTAssertEqual(model.loadedCount, SearchService.maxResultWindow)
        XCTAssertFalse(model.hasMore)                // loadedCount == max window
    }

    func testFirstPageFailureResetsAndReportsError() async {
        let model = OnlineSearchModel(service: FailingSearch(), pageSize: 50)
        let app = await app()

        await model.startSearch(query: "x", kind: .album, creds: creds, app: app)

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.loadedCount, 0)
        XCTAssertEqual(model.total, 0)
        if case .failed = model.state {} else { XCTFail("expected .failed state") }
    }

    // MARK: - Server-side sort threading

    /// Changing the sort RESETS the accumulator and reloads page 1 — the same
    /// reset-on-change contract as a new query/filter — and the server receives the
    /// NEW sort keys on the fresh first page (it must sort the full result set).
    func testSortChangeResetsAndReloadsPageOne() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        let byYear = [SortKey(field: "year", dir: .desc)]
        await model.startSearch(query: "x", kind: .album, sortKeys: byYear, creds: creds, app: app)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 100)
        XCTAssertEqual(stub.sortCalls.first, byYear)

        // A different sort RESETS: offset back to 0, accumulator cleared, page 1 only,
        // and the server is handed the NEW keys.
        let byArtist = [SortKey(field: "artist", dir: .asc)]
        await model.startSearch(query: "x", kind: .album, sortKeys: byArtist, creds: creds, app: app)
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(model.loadedCount, 50)
        XCTAssertEqual(stub.calls.last?.from, 0)
        XCTAssertEqual(stub.sortCalls.last, byArtist)
    }

    /// `loadMore()` re-issues the SAME sort keys at the next offset, so every page is
    /// ordered consistently by the server (stable from/size pagination).
    func testLoadMoreCarriesSameSortKeys() async {
        let stub = StubSearch(total: 130)
        let model = OnlineSearchModel(service: stub, pageSize: 50)
        let app = await app()

        let keys = [SortKey(field: "name", dir: .asc), SortKey(field: "year", dir: .desc)]
        await model.startSearch(query: "x", kind: .album, sortKeys: keys, creds: creds, app: app)
        await model.loadMore()

        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(stub.sortCalls.count, 2)
        XCTAssertEqual(stub.sortCalls[0], keys)
        XCTAssertEqual(stub.sortCalls[1], keys)   // same sort on the next page
        XCTAssertEqual(stub.calls[1].from, 50)
    }
}
