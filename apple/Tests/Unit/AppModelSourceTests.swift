import XCTest
@testable import PocketDJ

/// Source-tagging on AppModel: each album/song id keeps the name of the FIRST
/// source that carried it (same dedup order as `merge`), and `availableSources`
/// lists the distinct source names in first-seen order.
@MainActor
final class AppModelSourceTests: XCTestCase {

    func testSourceTagsFirstSeenWinsAcrossTwoIndexes() throws {
        // "Test Crate" first, then "Apple Music (Local)" which re-uses alb_1/sng_1.
        let a = try TestData.index()       // sourceName: "Test Crate"
        let b = try TestData.index2()      // sourceName: "Apple Music (Local)"
        let tags = AppModel.sourceTags([a, b])

        // Shared ids resolve to the FIRST source.
        XCTAssertEqual(tags.albums["alb_1"], "Test Crate")
        XCTAssertEqual(tags.songs["sng_1"], "Test Crate")
        // Ids unique to the second source resolve to it.
        XCTAssertEqual(tags.albums["alb_9"], "Apple Music (Local)")
        XCTAssertEqual(tags.songs["sng_9"], "Apple Music (Local)")
        // Ids unique to the first source resolve to it.
        XCTAssertEqual(tags.albums["alb_2"], "Test Crate")
        XCTAssertEqual(tags.songs["sng_4"], "Test Crate")
        // Distinct names in first-seen order.
        XCTAssertEqual(tags.names, ["Test Crate", "Apple Music (Local)"])
    }

    func testSourceTagsHonorsMergeOrder() throws {
        // Reverse the order: now Apple Music is first and wins the shared ids.
        let a = try TestData.index()
        let b = try TestData.index2()
        let tags = AppModel.sourceTags([b, a])
        XCTAssertEqual(tags.albums["alb_1"], "Apple Music (Local)")
        XCTAssertEqual(tags.songs["sng_1"], "Apple Music (Local)")
        XCTAssertEqual(tags.names, ["Apple Music (Local)", "Test Crate"])
    }

    func testLoadedAppExposesSourceAccessors() async throws {
        // Single-source load via the stub loader tags everything with the manifest.
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        XCTAssertEqual(app.availableSources, ["Test Crate"])
        XCTAssertEqual(app.source(ofAlbum: "alb_1"), "Test Crate")
        XCTAssertEqual(app.source(ofSong: "sng_1"), "Test Crate")
        XCTAssertNil(app.source(ofAlbum: "nope"))
    }

    // MARK: - Recently added (virtual playlist)

    private func songWithDateAdded(_ id: String, dateAdded: Double) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(
            withJSONObject: ["id": id, "name": id, "artist": "A", "dateAdded": dateAdded]))
    }

    /// recentlyAddedSongIds unions add-times, ranks NEWEST FIRST, dedupes to resolvable catalog
    /// songs, and honors the cap; recentlyAddedPlaylist wraps it as the reserved SourcePlaylist.
    func testRecentlyAddedRanksNewestFirstAndCaps() {
        let app = AppModel()
        // Inject catalog songs carrying `dateAdded` (the Apple-Music-library-add ranking signal).
        app.injectDiscoverAdd(songWithDateAdded("s1", dateAdded: 1_000))
        app.injectDiscoverAdd(songWithDateAdded("s2", dateAdded: 3_000))
        app.injectDiscoverAdd(songWithDateAdded("s3", dateAdded: 2_000))

        XCTAssertEqual(app.recentlyAddedSongIds(limit: 10), ["s2", "s3", "s1"], "newest first")
        XCTAssertEqual(app.recentlyAddedSongIds(limit: 2), ["s2", "s3"], "capped at N")
        XCTAssertTrue(app.recentlyAddedSongIds(limit: 0).isEmpty, "zero limit → empty")

        let ra = app.recentlyAddedPlaylist(limit: 10)
        XCTAssertEqual(ra?.playlist.id, AppModel.recentlyAddedPlaylistId)
        XCTAssertEqual(ra?.playlist.songIds, ["s2", "s3", "s1"])
        XCTAssertEqual(ra?.sourceName, AppModel.recentlyAddedName)
    }

    /// Integrity audit: a NON-OWNER's "Recently added" must exclude `dateAdded` rows sourced from a
    /// shared URL catalog — those are the CURATOR's library-add history, not this user's — so the
    /// curator's recently-added songs never bleed into a hybrid user's list. The OWNER keeps them
    /// (the shared catalog IS their own library history). Gated on `resolvedIsOwner`, NOT on
    /// `appleMusicPrivateSync` (which defaults TRUE for a hybrid user and used to leak these rows).
    func testRecentlyAddedFiltersSharedCatalogForNonOwner() {
        let app = AppModel()
        // A non-nil settings host engages the filter (a nil-settings fixture never filters — see
        // the ranks test above). The injected row is Discover-sourced (≠ the own "Apple Music"
        // library source), standing in for a shared-catalog `dateAdded` row.
        app.settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        app.injectDiscoverAdd(songWithDateAdded("shared1", dateAdded: 1_000))

        app.resolvedIsOwner = false
        XCTAssertTrue(app.recentlyAddedSongIds(limit: 10).isEmpty,
                      "non-owner: a shared-catalog dateAdded row is excluded from Recently added")

        app.resolvedIsOwner = true
        XCTAssertEqual(app.recentlyAddedSongIds(limit: 10), ["shared1"],
                       "owner: the shared catalog IS their library history, so it is kept")
    }

    /// Per-collection sort/filter: `sortedFilteredSongs` sorts a collection's songs by a BrowseState
    /// sort key (date added asc/desc) and preserves the stored order at default state.
    func testCollectionSortedFilteredSongsByDateAdded() {
        let app = AppModel()
        app.injectDiscoverAdd(songWithDateAdded("s1", dateAdded: 1_000))
        app.injectDiscoverAdd(songWithDateAdded("s2", dateAdded: 3_000))
        app.injectDiscoverAdd(songWithDateAdded("s3", dateAdded: 2_000))
        let browse = BrowseState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 persistenceKey: "pdj.collection.test")
        browse.kind = .song

        browse.sortKeys = [SortKey(field: "dateAdded", dir: .desc)]
        XCTAssertEqual(app.sortedFilteredSongs(ids: ["s1", "s2", "s3"], browse: browse,
                                               collections: nil, favorites: nil).map(\.id),
                       ["s2", "s3", "s1"], "newest first")

        browse.sortKeys = [SortKey(field: "dateAdded", dir: .asc)]
        XCTAssertEqual(app.sortedFilteredSongs(ids: ["s1", "s2", "s3"], browse: browse,
                                               collections: nil, favorites: nil).map(\.id),
                       ["s1", "s3", "s2"], "oldest first")

        // Default (no sort keys) preserves the collection's stored order.
        browse.sortKeys = []
        XCTAssertEqual(app.sortedFilteredSongs(ids: ["s2", "s1", "s3"], browse: browse,
                                               collections: nil, favorites: nil).map(\.id),
                       ["s2", "s1", "s3"])

        // A song with NO dateAdded sorts to the END regardless of direction ("add at the end").
        app.injectDiscoverAdd(IndexSong.minimal(id: "s4", name: "s4", artist: "A"))
        browse.sortKeys = [SortKey(field: "dateAdded", dir: .desc)]
        XCTAssertEqual(app.sortedFilteredSongs(ids: ["s1", "s2", "s3", "s4"], browse: browse,
                                               collections: nil, favorites: nil).map(\.id).last, "s4")
        browse.sortKeys = [SortKey(field: "dateAdded", dir: .asc)]
        XCTAssertEqual(app.sortedFilteredSongs(ids: ["s1", "s2", "s3", "s4"], browse: browse,
                                               collections: nil, favorites: nil).map(\.id).last, "s4")
    }

    /// An empty library yields no synthetic playlist (the row hides), and an ejected song drops out.
    func testRecentlyAddedEmptyAndAfterEject() {
        let app = AppModel()
        XCTAssertNil(app.recentlyAddedPlaylist(limit: 10), "no adds → no row")

        let discover = DiscoverAddsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-ra-\(UUID().uuidString).json"))
        app.discoverAdds = discover
        discover.onAdded = { song in app.injectDiscoverAdd(song) }
        discover.add(songId: "amrec_r", appleMusicId: "1", title: "R", artist: "A")
        XCTAssertEqual(app.recentlyAddedSongIds(limit: 10), ["amrec_r"])

        app.removeFromLibrary(songId: "amrec_r")
        XCTAssertTrue(app.recentlyAddedSongIds(limit: 10).isEmpty, "ejected song drops out of Recently Added")
    }
}

/// The explicit on-disk catalog cache (OFFLINE support): a successful `loadIndex` persists the
/// raw index bytes per source URL; a later FAILED load returns the cached `IndexJSON` so the
/// catalog opens with NO network. The live `loadIndex` uses `URLSession.shared`, so these tests
/// drive the cache round-trip directly with an injected temp dir (the network leg is unchanged).
final class CatalogServiceCacheTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-catcache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testCacheRoundTripsTheIndexPerURL() {
        let dir = tempDir()
        let url = URL(string: "https://cdn.test/current-index.json")!
        // No cache yet → nil (a fresh install offline has nothing to show — expected).
        XCTAssertNil(CatalogService.loadCachedIndex(for: url, in: dir))
        // A successful load persists the raw bytes; a later offline load decodes them back.
        CatalogService.writeCache(Data(TestData.json.utf8), for: url, in: dir)
        let cached = CatalogService.loadCachedIndex(for: url, in: dir)
        XCTAssertNotNil(cached, "the cached index decodes with no network")
        XCTAssertEqual(cached?.albums.count, 3)
        XCTAssertEqual(cached?.songs.count, 7)
        XCTAssertEqual(cached?.manifest.sourceName, "Test Crate")
    }

    func testCacheIsKeyedByURLSoSourcesDontCollide() {
        let dir = tempDir()
        let urlA = URL(string: "https://cdn.test/a.json")!
        let urlB = URL(string: "https://cdn.test/b.json")!
        CatalogService.writeCache(Data(TestData.json.utf8), for: urlA, in: dir)
        XCTAssertNotNil(CatalogService.loadCachedIndex(for: urlA, in: dir))
        // A DIFFERENT source URL has its own (empty) cache — one cached source can't satisfy another.
        XCTAssertNil(CatalogService.loadCachedIndex(for: urlB, in: dir))
    }

    func testCacheFilenameIsDeterministic() {
        let dir = tempDir()
        let url = URL(string: "https://cdn.test/current-index.json")!
        // The per-URL filename must be STABLE across calls/relaunch (SHA-256 of the URL string,
        // not Swift's per-process-seeded Hasher) — else a relaunch wouldn't find the cache.
        XCTAssertEqual(CatalogService.cacheFileURL(for: url, in: dir),
                       CatalogService.cacheFileURL(for: url, in: dir))
        XCTAssertNotNil(CatalogService.cacheFileURL(for: url, in: dir))
    }

    func testWriteCachePersistsAndLoadsValidator() {
        let dir = tempDir()
        let url = URL(string: "https://cdn.test/current-index.json")!
        XCTAssertNil(CatalogService.loadValidator(for: url, in: dir), "no validator before first cache")
        CatalogService.writeCache(Data(TestData.json.utf8), for: url, in: dir,
                                  validator: .init(lastModified: "Wed, 30 Jun 2026 11:00:22 GMT", etag: "\"abc\""))
        let v = CatalogService.loadValidator(for: url, in: dir)
        XCTAssertEqual(v?.lastModified, "Wed, 30 Jun 2026 11:00:22 GMT")
        XCTAssertEqual(v?.etag, "\"abc\"")
        // The validator sidecar is a SEPARATE file beside the cached body (both still load).
        XCTAssertNotEqual(CatalogService.metaFileURL(for: url, in: dir), CatalogService.cacheFileURL(for: url, in: dir))
        XCTAssertNotNil(CatalogService.loadCachedIndex(for: url, in: dir))
    }

    func testWriteCacheWithoutValidatorLeavesNone() {
        let dir = tempDir()
        let url = URL(string: "https://cdn.test/x.json")!
        // No validator ⇒ the first refresh after this is an UNCONDITIONAL GET (then it records one).
        CatalogService.writeCache(Data(TestData.json.utf8), for: url, in: dir)
        XCTAssertNil(CatalogService.loadValidator(for: url, in: dir))
    }
}

/// Offline-first AppModel: a FAILED refresh must never blank an already-loaded catalog (the
/// disappearing-index-playlists fix). Driven via a flaky loader (the multi-source disk-cache
/// seed path is exercised on-device).
@MainActor
final class AppModelOfflineFirstTests: XCTestCase {
    private final class FlakyLoader: CatalogLoading, @unchecked Sendable {
        var fail = false
        func loadIndex() async throws -> IndexJSON {
            if fail { throw URLError(.notConnectedToInternet) }
            return try TestData.index()
        }
    }

    func testReloadKeepsCatalogWhenRefreshFails() async throws {
        let loader = FlakyLoader()
        let app = AppModel(loader: loader)
        await app.loadIfNeeded()
        XCTAssertEqual(app.state, .loaded)
        let before = app.songs.count
        XCTAssertGreaterThan(before, 0)

        // Network drops → an explicit reload must keep the loaded catalog, not blank it.
        loader.fail = true
        await app.reload()
        XCTAssertEqual(app.songs.count, before, "a failed refresh preserves the loaded catalog")
        XCTAssertEqual(app.state, .loaded, "a failed refresh must NOT fall back to .failed when data is on screen")
    }

    func testFirstLoadOfflineWithNoCacheReportsFailure() async {
        // Genuinely-empty first launch (loader throws, nothing seeded) DOES surface the error.
        let loader = FlakyLoader(); loader.fail = true
        let app = AppModel(loader: loader)
        await app.loadIfNeeded()
        if case .failed = app.state {} else { XCTFail("expected .failed on first-load offline with no cache") }
        XCTAssertTrue(app.songs.isEmpty)
    }
}
