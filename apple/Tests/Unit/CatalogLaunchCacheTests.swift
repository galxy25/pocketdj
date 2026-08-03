import XCTest
@testable import PocketDJ

/// The two launch-window caches, and the property that matters for both: they may DELAY bad
/// news, never INVENT good news. A cache that can resurrect a deleted playlist would be worse
/// than the empty state it replaces.
@MainActor
final class CatalogLaunchCacheTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
    }

    private func sp(_ id: String, _ name: String, _ ids: [String] = ["sng_1"]) -> SourcePlaylist {
        SourcePlaylist(playlist: IndexPlaylist(id: id, name: name, songIds: ids),
                       sourceName: "Apple Music (Local)")
    }

    // MARK: SourcePlaylistsCache

    func testRoundTripsRowsAcrossInstances() {
        let url = tempURL("spl")
        let a = SourcePlaylistsCache(fileURL: url)
        a.record([sp("pl_1", "Road Trip", ["sng_1", "sng_2"]), sp("pl_2", "Dinner")])
        a.flushIfNeeded()

        let b = SourcePlaylistsCache(fileURL: url)
        let rows = b.snapshot()
        XCTAssertEqual(rows.map(\.id), ["pl_1", "pl_2"])
        XCTAssertEqual(rows.first?.name, "Road Trip")
        XCTAssertEqual(rows.first?.songIds, ["sng_1", "sng_2"], "member ids survive — the detail view needs them")
        XCTAssertEqual(rows.first?.sourceName, "Apple Music (Local)")
    }

    /// The one that matters. At launch the catalog is empty before it is loaded; if that empty
    /// set were recorded it would erase exactly what the cache exists to show.
    func testAnEmptySetNeverOverwritesAGoodSnapshot() {
        let url = tempURL("spl")
        let cache = SourcePlaylistsCache(fileURL: url)
        cache.record([sp("pl_1", "Road Trip")])
        cache.flushIfNeeded()

        cache.record([])                       // the pre-load state
        cache.flushIfNeeded()

        XCTAssertEqual(SourcePlaylistsCache(fileURL: url).snapshot().map(\.id), ["pl_1"])
    }

    /// …but a genuinely different, non-empty set MUST replace it, or a removed playlist would
    /// linger forever.
    func testARealChangeReplacesTheSnapshot() {
        let url = tempURL("spl")
        let cache = SourcePlaylistsCache(fileURL: url)
        cache.record([sp("pl_1", "Road Trip"), sp("pl_2", "Dinner")])
        cache.flushIfNeeded()
        cache.record([sp("pl_2", "Dinner")])   // pl_1 deleted upstream
        cache.flushIfNeeded()

        XCTAssertEqual(SourcePlaylistsCache(fileURL: url).snapshot().map(\.id), ["pl_2"])
    }

    func testMissingFileIsAnEmptySnapshotNotACrash() {
        XCTAssertTrue(SourcePlaylistsCache(fileURL: tempURL("absent")).snapshot().isEmpty)
    }

    /// AppModel seeds `indexPlaylists` from the cache at init, so the Shared tab has rows before
    /// any decode. A fixture/loader-backed model must NOT, or every test would inherit whatever
    /// the developer's app last cached.
    ///
    /// Both branches are driven explicitly: this whole target runs with PDJ_USE_FIXTURE=1, so
    /// the production branch is only reachable through the `seedFromCache` seam.
    func testAppModelSeedsFromCacheOnlyWhenItShould() async throws {
        let url = tempURL("spl")
        let warm = SourcePlaylistsCache(fileURL: url)
        warm.record([sp("pl_1", "Road Trip")])
        warm.flushIfNeeded()

        let withLoader = AppModel(loader: TestData.StubLoader(),
                                  sourcePlaylistsCache: SourcePlaylistsCache(fileURL: url))
        XCTAssertTrue(withLoader.indexPlaylists.isEmpty, "a fixture-backed model starts clean")

        let seeded = AppModel(sourcePlaylistsCache: SourcePlaylistsCache(fileURL: url),
                              seedFromCache: true)
        XCTAssertEqual(seeded.indexPlaylists.map(\.id), ["pl_1"],
                       "a real model paints the remembered rows before any decode")
        XCTAssertEqual(seeded.indexPlaylists.first?.songIds, ["sng_1"])
    }

    /// The default really is "seed only without a loader" — the parameter exists for the test
    /// scheme's sake, not to change production behaviour.
    func testSeedingDefaultsToLoaderlessOnly() async throws {
        let url = tempURL("spl")
        let warm = SourcePlaylistsCache(fileURL: url)
        warm.record([sp("pl_9", "Cached")])
        warm.flushIfNeeded()
        // No explicit seam ⇒ under PDJ_USE_FIXTURE this resolves a FixtureCatalog loader, so the
        // default must decline to seed.
        let m = AppModel(sourcePlaylistsCache: SourcePlaylistsCache(fileURL: url))
        XCTAssertTrue(m.indexPlaylists.isEmpty)
    }

    // MARK: CollectionStatsCache — same doctrine

    func testStatsCacheIgnoresStatsDerivedWithoutACatalog() {
        let url = tempURL("stats")
        let cache = CollectionStatsCache(fileURL: url)
        cache.record(.init(count: 12, runtimeMs: 2_400_000), for: "pls_1", catalogReady: true)
        // The cold-launch case: resolving against an empty catalog yields 0, and recording that
        // is exactly the "0 songs" bug this cache exists to prevent.
        cache.record(.init(count: 0, runtimeMs: 0), for: "pls_1", catalogReady: false)
        XCTAssertEqual(cache.stats(for: "pls_1")?.count, 12)
    }

    func testStatsCachePrunesDeletedCollections() {
        let url = tempURL("stats")
        let cache = CollectionStatsCache(fileURL: url)
        cache.record(.init(count: 3, runtimeMs: 100), for: "pls_1", catalogReady: true)
        cache.record(.init(count: 4, runtimeMs: 200), for: "pls_2", catalogReady: true)
        cache.prune(keeping: ["pls_2"])
        XCTAssertNil(cache.stats(for: "pls_1"))
        XCTAssertEqual(cache.stats(for: "pls_2")?.count, 4)
    }
}
