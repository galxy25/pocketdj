import XCTest
@testable import PocketDJ

/// On-device browse paging: the catalog is mapped to `BrowseItem`s ONCE (on
/// AppModel), the query→filter→sort pipeline is MEMOIZED so re-entering the tab or an
/// incidental re-render is instant, and the view renders only a growing PREFIX. These
/// cover the pure/model pieces of that (the SwiftUI prefix wiring is exercised by the
/// UI tests). Sibling of OnlineSearchPagingTests, which covers the server-paged path.
@MainActor
final class BrowsePagingTests: XCTestCase {
    private var heldApp: AppModel?
    override func tearDown() { heldApp = nil; super.tearDown() }

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    private func wiredStore(_ app: AppModel) -> CollectionsStore {
        heldApp = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-paging-\(UUID().uuidString).json"))
        s.app = app
        return s
    }

    // MARK: Pre-built base items (moved off the per-render path)

    func testAppModelPrebuildsBrowseItems() async {
        let app = await loadedApp()
        XCTAssertEqual(app.browseItems(.album).count, 3)
        XCTAssertEqual(app.browseItems(.song).count, 7)
        XCTAssertGreaterThan(app.catalogRevision, 0)   // bumped by the load's applyEdits
    }

    /// The pre-built items carry the SAME per-item derivation baseItems used to compute:
    /// origin source on every row, and the song's top-tier genre category resolved from
    /// its owning album (alb_1 = Electronic → sng_1 category "electronic").
    func testPrebuiltItemsCarrySourceAndResolvedGenre() async {
        let app = await loadedApp()
        for item in app.browseItems(.album) { XCTAssertEqual(item.source, "Test Crate") }
        let sng1 = app.browseItems(.song).first { $0.id == "sng_1" }
        guard case .song(_, _, let source, let genre)? = sng1 else { return XCTFail("sng_1 missing") }
        XCTAssertEqual(source, "Test Crate")
        XCTAssertEqual(genre, "electronic")
    }

    func testBaseItemsReadsPrebuiltArray() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        XCTAssertEqual(b.baseItems(app).map(\.id), app.browseItems(.song).map(\.id))
    }

    // MARK: Results memo key

    /// Two logically-identical filter sets (different Clause UUIDs) share a cache key.
    func testResultsKeyIgnoresClauseIdentity() async {
        let app = await loadedApp()
        let a = BrowseState(); a.kind = .song
        a.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]
        let b = BrowseState(); b.kind = .song
        b.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]   // fresh UUID
        XCTAssertEqual(a.resultsKey(app), b.resultsKey(app))
    }

    /// Different filter VALUES → different key; kind is part of the key.
    func testResultsKeyDistinguishesFiltersAndKind() async {
        let app = await loadedApp()
        let a = BrowseState(); a.kind = .song
        a.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]
        let b = BrowseState(); b.kind = .song
        b.clauses = [Clause(field: "bpm", op: .between, min: 90, max: 130)]
        XCTAssertNotEqual(a.resultsKey(app), b.resultsKey(app))

        let album = BrowseState(); album.kind = .album
        let song = BrowseState(); song.kind = .song
        XCTAssertNotEqual(album.resultsKey(app), song.resultsKey(app))
    }

    /// Incomplete clauses are no-ops in FilterEngine, so they must not change the key.
    func testResultsKeyOmitsIncompleteClauses() async {
        let app = await loadedApp()
        let bare = BrowseState(); bare.kind = .song
        let withIncomplete = BrowseState(); withIncomplete.kind = .song
        withIncomplete.clauses = [Clause(field: "bpm", op: .eq, value: "")]   // incomplete
        XCTAssertEqual(bare.resultsKey(app), withIncomplete.resultsKey(app))
    }

    /// Values containing separator-ish characters must NOT collide onto one key. A song
    /// titled "a,b" (name eq "a,b") and a name eq "a" whose stray `values` holds ["b"]
    /// used to hand-encode to the same string; they must now differ. Also a `query`
    /// carrying delimiter chars must stay distinct from a plain query.
    func testResultsKeyIsCollisionProofAcrossDelimiters() async {
        let app = await loadedApp()
        let x = BrowseState(); x.kind = .song
        x.clauses = [Clause(field: "name", op: .eq, value: "a,b")]
        let y = BrowseState(); y.kind = .song
        var cy = Clause(field: "name", op: .eq, value: "a"); cy.values = ["b"]
        y.clauses = [cy]
        XCTAssertNotEqual(x.resultsKey(app), y.resultsKey(app))

        let q1 = BrowseState(); q1.kind = .song; q1.query = "rock|c:x"
        let q2 = BrowseState(); q2.kind = .song; q2.query = "rock"
        XCTAssertNotEqual(q1.resultsKey(app), q2.resultsKey(app))
    }

    /// A catalog change (revision bump) invalidates the key so a stale memo can't survive.
    func testResultsKeyChangesWithCatalogRevision() async {
        let app = await loadedApp()
        let b = BrowseState(); b.kind = .album
        let before = b.resultsKey(app)
        app.applyEdits()                      // rebuilds items + bumps catalogRevision
        XCTAssertNotEqual(before, b.resultsKey(app))
    }

    // MARK: Memoization on AppModel

    /// The same key computes ONCE; a fresh BrowseState with the same config reuses it —
    /// this is what makes re-entering the Browser tab instant (a new BrowseState each time).
    func testCachedResultsComputeOncePerKey() async {
        let app = await loadedApp()
        var calls = 0
        let key = "shared-key"
        _ = app.cachedBrowseResults(key) { calls += 1; return app.browseItems(.song) }
        _ = app.cachedBrowseResults(key) { calls += 1; return app.browseItems(.song) }
        XCTAssertEqual(calls, 1)              // second call served from cache
    }

    func testCachedResultsEvictBeyondCap() async {
        let app = await loadedApp()
        for i in 0..<10 { _ = app.cachedBrowseResults("k\(i)") { [] } }   // cap is 6
        var recomputedEarliest = false
        _ = app.cachedBrowseResults("k0") { recomputedEarliest = true; return [] }
        XCTAssertTrue(recomputedEarliest, "the earliest key should have been evicted")
        var recomputedRecent = false
        _ = app.cachedBrowseResults("k9") { recomputedRecent = true; return [] }
        XCTAssertFalse(recomputedRecent, "a recent key should still be cached")
    }

    /// Memoization must not change the ANSWER: a filtered+sorted query returns the same
    /// order the direct pipeline does (regression guard on the memo path).
    func testMemoizedResultsMatchDirectPipeline() async {
        let app = await loadedApp()
        let b = BrowseState(); b.kind = .song
        b.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]
        b.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        let first = b.results(app).map(\.id)
        let second = b.results(app).map(\.id)   // served from the memo
        XCTAssertEqual(first, ["sng_4", "sng_6", "sng_2", "sng_1"])
        XCTAssertEqual(first, second)
    }

    /// The membership FILTER is applied fresh (not memoized), so mutating a selected
    /// collection is reflected immediately, never served stale from a memo.
    func testMembershipResultsAreNotServedStale() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        let b = BrowseState(); b.kind = .song; b.includeIds = [pl.id]
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.id)), ["sng_1"])
        s.addSong("sng_4", toPlaylist: pl.id)          // mutate the selected collection
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.id)), ["sng_1", "sng_4"])
    }

    /// ...but the EXPENSIVE base→filter→sort behind it MUST be memoized even on the
    /// membership path, so a scroll (which re-evals results()) can't re-sort ~90k rows.
    /// Proven by checking the resultsKey entry is already cached after a membership call.
    func testMembershipPathStillMemoizesTheSort() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set"); s.addSong("sng_1", toPlaylist: pl.id)
        let b = BrowseState(); b.kind = .song; b.includeIds = [pl.id]
        b.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        _ = b.results(app, collections: s)             // membership-active path
        var recomputed = false
        _ = app.cachedBrowseResults(b.resultsKey(app)) { recomputed = true; return [] }
        XCTAssertFalse(recomputed, "membership path must reuse the memoized sort, not skip the cache")
    }

    // MARK: BrowsePaging (pure prefix math)

    private func synthItems(_ n: Int) -> [BrowseItem] {
        (0..<n).map { .song(IndexSong.minimal(id: "s\($0)", name: "n\($0)", artist: "a"),
                            albumName: "", source: nil, genre: nil) }
    }

    func testPageReturnsPrefixUntilItFits() {
        let items = synthItems(300)
        XCTAssertEqual(BrowsePaging.page(items, visible: 120).count, 120)
        XCTAssertEqual(BrowsePaging.page(items, visible: 120).map(\.id), items.prefix(120).map(\.id))
        // Once the budget covers everything, the whole set is returned unsliced.
        XCTAssertEqual(BrowsePaging.page(items, visible: 500).count, 300)
        XCTAssertEqual(BrowsePaging.page(synthItems(50), visible: 120).count, 50)
    }

    func testGrowStepsUpAndClampsToTotal() {
        XCTAssertEqual(BrowsePaging.grow(120, upTo: 300), 240)          // +pageSize
        XCTAssertEqual(BrowsePaging.grow(240, upTo: 300), 300)          // clamped to total
        XCTAssertEqual(BrowsePaging.grow(300, upTo: 300), 300)          // already full → no-op
        XCTAssertEqual(BrowsePaging.grow(120, upTo: 130), 130)          // small tail clamps
    }

    /// Keyboard focus reveal: grows to include a row stepped to near the loaded edge…
    func testFocusRevealGrowsForIncrementalStep() {
        XCTAssertEqual(BrowsePaging.focusReveal(120, toIndex: 120, total: 90_000), 121) // one past edge
        XCTAssertEqual(BrowsePaging.focusReveal(120, toIndex: 200, total: 90_000), 201) // within one page
        XCTAssertEqual(BrowsePaging.focusReveal(120, toIndex: 50, total: 90_000), 120)  // already visible → no-op
    }

    /// …but a FAR jump (↑-from-nothing seeds focus to the last of ~90k rows, then step)
    /// must NOT drag the budget to the whole catalog — the confirmed regression guard.
    func testFocusRevealIgnoresFarJump() {
        XCTAssertEqual(BrowsePaging.focusReveal(120, toIndex: 89_999, total: 90_000), 120)
        XCTAssertEqual(BrowsePaging.focusReveal(120, toIndex: 241, total: 90_000), 120)  // just past the 1-page window
    }

    // MARK: Large-catalog timing (direct app-side numbers, no XCUITest overhead)

    /// Builds an N-song / (N/10)-album synthetic catalog and times the per-switch cost.
    /// Scales N up only when `PDJ_PERF_SMOKE=1` so CI stays fast while a manual run
    /// (`TEST_RUNNER_PDJ_PERF_SMOKE=1 …`) prints realistic ~100k-scale numbers. Proves:
    ///   • the default switch is a precomputed hand-off + tiny page slice (independent of N),
    ///   • the memo makes a repeat (sorted) result effectively free vs the cold sort,
    ///   • the OLD per-render `baseItems` map cost (now paid once at load) is what we removed.
    func testLargeCatalogSwitchIsCheap() async throws {
        let big = ProcessInfo.processInfo.environment["PDJ_PERF_SMOKE"] == "1"
        let n = big ? 100_000 : 400
        let app = AppModel(loader: SyntheticCatalog(songs: n))
        await app.loadIfNeeded()
        XCTAssertEqual(app.browseItems(.song).count, n)

        func ms(_ block: () -> Void) -> Double {
            let t = CFAbsoluteTimeGetCurrent(); block(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
        }

        let b = BrowseState(); b.kind = .song

        // NEW default switch: precomputed base hand-off + first-page slice (what a kind
        // switch / tab re-entry costs now).
        var page: [BrowseItem] = []
        let tSwitch = ms { page = BrowsePaging.page(b.results(app), visible: BrowsePaging.pageSize) }
        XCTAssertEqual(page.count, min(n, BrowsePaging.pageSize))

        // OLD per-render cost we removed: mapping the WHOLE catalog into rows every render.
        let tOldMap = ms { _ = app.songs.map { BrowseItem.song($0, albumName: "", source: nil, genre: nil) } }

        // Memo: cold sort over all N vs a warm repeat (cache hit).
        b.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        let tCold = ms { _ = b.results(app) }
        let tWarm = ms { _ = b.results(app) }

        print(String(format: "PERF-UNIT n=%d  switch(default)=%.2fms  oldFullMap=%.2fms  coldSort=%.2fms  warmMemo=%.3fms",
                     n, tSwitch, tOldMap, tCold, tWarm))

        // The memo must make the repeat dramatically cheaper than the cold sort…
        XCTAssertLessThan(tWarm, max(0.5, tCold / 2))
        // …and the default switch must not scale with N the way the old full map does.
        if big { XCTAssertLessThan(tSwitch, tOldMap) }
    }
}

/// A programmatically-generated catalog of `songs` tracks across `songs/10` albums, with
/// varied bpm/camelot/year so sorting has real work. Decoded once from a built JSON blob
/// (fast) — used only by the large-catalog timing test.
private struct SyntheticCatalog: CatalogLoading {
    let songs: Int
    func loadIndex() async throws -> IndexJSON {
        let albumCount = max(1, songs / 10)
        let cams = ["1A","2A","3A","4A","5A","6A","7A","8A","9A","10A","11A","12A",
                    "1B","2B","3B","4B","5B","6B","7B","8B","9B","10B","11B","12B"]
        var a = "["
        for i in 0..<albumCount {
            if i > 0 { a += "," }
            a += "{\"id\":\"alb_\(i)\",\"artist\":\"Artist \(i % 500)\",\"name\":\"Album \(i)\",\"genre\":\"Jazz\",\"year\":\(1960 + i % 60),\"trackList\":[],\"country\":\"US\",\"fileType\":\"m4a\"}"
        }
        a += "]"
        var s = "["
        for i in 0..<songs {
            if i > 0 { s += "," }
            let alb = i % albumCount
            s += "{\"id\":\"sng_\(i)\",\"albumId\":\"alb_\(alb)\",\"artist\":\"Artist \(i % 500)\",\"name\":\"Song \(i)\",\"trackNumber\":\(i % 20 + 1),\"year\":\(1960 + i % 60),\"bpm\":\(60 + i % 140),\"camelot\":\"\(cams[i % cams.count])\",\"length\":\(120000 + i % 180000),\"explicit\":false}"
        }
        s += "]"
        let json = "{\"manifest\":{\"sourceName\":\"Synthetic\",\"counts\":{\"albums\":\(albumCount),\"songs\":\(songs)}},\"albums\":\(a),\"songs\":\(s)}"
        return try JSONDecoder().decode(IndexJSON.self, from: Data(json.utf8))
    }
}
