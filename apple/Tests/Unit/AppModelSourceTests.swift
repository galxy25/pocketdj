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

    // MARK: - The add-time union behind Recently added AND the Collection timeline (F8)

    /// `addedAtBySongId` is the WHOLE union "Recently added" takes its top-N from — and the axis the
    /// Collection tab's One True Timeline orders on. One implementation, so the two surfaces can
    /// never disagree about when something entered the library.
    func testAddedAtBySongIdIsTheWholeUnionRecentlyAddedRanks() {
        let app = AppModel()
        app.injectDiscoverAdd(songWithDateAdded("s1", dateAdded: 1_000))
        app.injectDiscoverAdd(songWithDateAdded("s2", dateAdded: 3_000))
        app.injectDiscoverAdd(songWithDateAdded("s3", dateAdded: 2_000))

        let union = app.addedAtBySongId()
        XCTAssertEqual(union, ["s1": 1_000, "s2": 3_000, "s3": 2_000])
        // …and the playlist is exactly its newest-first prefix.
        XCTAssertEqual(app.recentlyAddedSongIds(limit: 10),
                       union.sorted { $0.value > $1.value }.map(\.key))
    }

    /// A song with NO `dateAdded` is simply absent from the union — the timeline reports those as
    /// "no add date" rather than placing them at the epoch.
    func testAddedAtBySongIdOmitsUndatedSongs() {
        let app = AppModel()
        app.injectDiscoverAdd(songWithDateAdded("dated", dateAdded: 1_000))
        app.injectDiscoverAdd(try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization
            .data(withJSONObject: ["id": "undated", "name": "u", "artist": "A"])))
        XCTAssertEqual(Array(app.addedAtBySongId().keys), ["dated"])
    }

    /// The union honours the SAME non-owner scoping as Recently added (it is the same code path),
    /// so a hybrid user's timeline can't be filled with the curator's library history.
    func testAddedAtBySongIdHonoursOwnerScoping() {
        let app = AppModel()
        app.settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        app.injectDiscoverAdd(songWithDateAdded("shared1", dateAdded: 1_000))

        app.resolvedIsOwner = false
        XCTAssertTrue(app.addedAtBySongId().isEmpty)
        app.resolvedIsOwner = true
        XCTAssertEqual(app.addedAtBySongId()["shared1"], 1_000)
    }

    /// The pure `nonisolated static` core is what the timeline runs OFF the main actor. An override
    /// (an in-app ＋Add / import / custom-audio add-time) BEATS the catalog row's own date when it
    /// is newer, and bypasses the own-library source filter — it IS the user's own add.
    func testAddedAtStaticCoreAppliesOverridesAndScoping() {
        let songs = ["s1": songWithDateAdded("s1", dateAdded: 1_000),
                     "s2": songWithDateAdded("s2", dateAdded: 5_000)]
        let sources = ["s1": "Shared Catalog", "s2": "Shared Catalog"]

        let unfiltered = AppModel.addedAtBySongId(songsById: songs, songSourceById: sources,
                                                  filterToOwnLibrary: false,
                                                  overrides: ["s1": 9_000])
        XCTAssertEqual(unfiltered["s1"], 9_000, "a newer own add-time wins")
        XCTAssertEqual(unfiltered["s2"], 5_000)

        let filtered = AppModel.addedAtBySongId(songsById: songs, songSourceById: sources,
                                                filterToOwnLibrary: true,
                                                overrides: ["s1": 9_000])
        XCTAssertEqual(filtered, ["s1": 9_000],
                       "scoped: only the user's own override survives a shared-catalog source")

        // An OLDER override never overwrites a newer catalog date.
        let stale = AppModel.addedAtBySongId(songsById: songs, songSourceById: sources,
                                             filterToOwnLibrary: false, overrides: ["s2": 100])
        XCTAssertEqual(stale["s2"], 5_000)
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

    /// Task #53: on tvOS (`preferCaches`) the offline catalog cache lives under Caches —
    /// App Support is unwritable on TV hardware, and without this cache every TV launch is
    /// a full network catalog load. Everywhere else it stays in Application Support.
    func testCacheDirectoryFollowsThePlatformStorageHome() {
        let caches = CatalogService.cacheDirectory(nil, preferCaches: true)
        XCTAssertEqual(caches?.lastPathComponent, "catalog-cache")
        XCTAssertTrue(caches?.path.contains("/Caches/") == true,
                      "tvOS catalog cache home is Caches: \(caches?.path ?? "nil")")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches!.path, isDirectory: &isDir) && isDir.boolValue,
                      "the directory is actually created")
        let support = CatalogService.cacheDirectory(nil, preferCaches: false)
        XCTAssertTrue(support?.path.contains("/Application Support/") == true)
        XCTAssertEqual(support?.lastPathComponent, "catalog-cache")
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

/// ONE recording must never hold TWO live catalog identities.
///
/// REGRESSION (Levi, device, 2026-08-07): "im not sure if its caught in a loop because its played
/// the same song How You Say My Name twice now" — reported minutes after adding a Roy Woods album
/// from the New tile. The tile mixes owned and unowned releases, so "Add remaining (n)" expands to
/// EVERY track on the album, and each one was recorded as a provisional `amrec_<storeId>` row. For
/// a track the user already had, that row landed BESIDE the real indexed song carrying the same
/// `appleMusicId`: `AppModel.merge` dedups by ID only, so both survived, and any queue built off
/// the catalog (an artist's songs, Recently added, a shuffle/rec set) held the same recording twice
/// and played it twice.
///
/// The supersede that prevents this already existed — `withProvisionalSources` runs
/// `DiscoverAddsStore.split` on every catalog BUILD. The LIVE inject path (which is what every ＋
/// Add walks) skipped it, so the twin lived from the tap until the next full rebuild.
@MainActor
final class DiscoverDuplicateIdentityTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func indexSong(_ id: String, am: String?, name: String = "How You Say My Name") -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": "Roy Woods"]
        if let am { obj["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func indexAlbum(_ id: String, am: String?) -> IndexAlbum {
        var obj: [String: Any] = ["id": id, "name": "Say Less", "artist": "Roy Woods", "trackList": []]
        if let am { obj["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexAlbum.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func entry(_ songId: String, am: String, title: String) -> DiscoverAddsStore.Entry {
        DiscoverAddsStore.Entry(songId: songId, appleMusicId: am, title: title, artist: "Roy Woods",
                                addedAtMs: 1_000)
    }

    /// The album path — the one the New tile actually walks.
    func testAlbumAddDoesNotMintASecondIdentityForATrackTheCatalogAlreadyHolds() {
        let app = AppModel()
        // The user already owns this track: a catalog row claiming Apple Music id 999.
        app.injectImported(songs: [indexSong("sng_real", am: "999")], albums: [])
        XCTAssertEqual(app.songId(forAppleMusicId: "999"), "sng_real")
        var supersededPairs: [(from: String, to: String)] = []
        app.onDiscoverSupersede = { supersededPairs.append(contentsOf: $0) }

        let adds = DiscoverAddsStore(fileURL: tempURL("dupe-adds"))
        app.discoverAdds = adds
        adds.onAlbumBatchAdded = { songs, album in
            app.injectDiscoverAlbumBatch(songs: songs, album: album)
        }

        // Adding the album expands to EVERY track — the owned one included.
        adds.addAlbumBatch(albumId: "amrec_album_111", appleMusicId: "111",
                           title: "Say Less", artist: "Roy Woods",
                           trackIds: ["amrec_999", "amrec_1000"], preparedCopies: false,
                           songs: [entry("amrec_999", am: "999", title: "How You Say My Name"),
                                   entry("amrec_1000", am: "1000", title: "Something New")])

        // ONE recording, ONE row. Before the fix `amrec_999` was appended beside `sng_real`.
        XCTAssertEqual(app.songs.filter { $0.appleMusicId == "999" }.map(\.id), ["sng_real"],
                       "a track the catalog already holds must not gain a second identity")
        XCTAssertNil(app.songsById["amrec_999"], "the provisional twin yields — it does not coexist")
        // The genuinely-new track still becomes a citizen (the fix must not eat real adds).
        XCTAssertNotNil(app.songsById["amrec_1000"])
        // …and the provisional entry is pruned + remapped, exactly as the build-time split does.
        XCTAssertEqual(adds.entries.map(\.songId), ["amrec_1000"])
        XCTAssertEqual(supersededPairs.map(\.from), ["amrec_999"])
        XCTAssertEqual(supersededPairs.map(\.to), ["sng_real"])
    }

    /// The provisional ALBUM row has the same failure mode — two album rows for one release,
    /// which is how the same album shows up twice in Browse.
    func testAlbumAddDoesNotMintASecondAlbumIdentity() {
        let app = AppModel()
        app.injectImported(songs: [], albums: [indexAlbum("alb_real", am: "111")])
        XCTAssertEqual(app.albumId(forAppleMusicId: "111"), "alb_real")

        let adds = DiscoverAddsStore(fileURL: tempURL("dupe-alb"))
        app.discoverAdds = adds
        adds.onAlbumBatchAdded = { songs, album in
            app.injectDiscoverAlbumBatch(songs: songs, album: album)
        }
        adds.addAlbumBatch(albumId: "amrec_album_111", appleMusicId: "111",
                           title: "Say Less", artist: "Roy Woods",
                           trackIds: ["amrec_1000"], preparedCopies: false,
                           songs: [entry("amrec_1000", am: "1000", title: "Something New")])

        XCTAssertEqual(app.albums.filter { $0.appleMusicId == "111" }.map(\.id), ["alb_real"])
        XCTAssertNil(app.albumsById["amrec_album_111"])
        XCTAssertTrue(adds.albums.isEmpty, "the provisional album row is pruned, not left dangling")
    }

    /// The SONG path (a single ＋ Add, and every cloud-pulled add, which re-enters through the
    /// same arm) carries the identical defect.
    func testSongAddDoesNotMintASecondIdentity() {
        let app = AppModel()
        app.injectImported(songs: [indexSong("sng_real", am: "999")], albums: [])

        let adds = DiscoverAddsStore(fileURL: tempURL("dupe-song"))
        app.discoverAdds = adds
        adds.onAdded = { song in app.injectDiscoverAdd(song) }
        adds.add(songId: "amrec_999", appleMusicId: "999",
                 title: "How You Say My Name", artist: "Roy Woods")

        XCTAssertEqual(app.songs.filter { $0.appleMusicId == "999" }.map(\.id), ["sng_real"])
        XCTAssertNil(app.songsById["amrec_999"])
        XCTAssertTrue(adds.entries.isEmpty)
    }

    /// The guard is a CLAIM check, not a blanket refusal: an add for a recording nothing else
    /// holds still becomes a first-class citizen, and a row with no Apple Music id at all
    /// (nothing to collide on) is untouched.
    func testUnclaimedAddsStillLand() {
        let app = AppModel()
        let adds = DiscoverAddsStore(fileURL: tempURL("dupe-ok"))
        app.discoverAdds = adds
        adds.onAdded = { song in app.injectDiscoverAdd(song) }
        adds.add(songId: "amrec_7", appleMusicId: "7", title: "Fresh", artist: "Roy Woods")
        XCTAssertNotNil(app.songsById["amrec_7"])
        XCTAssertEqual(app.source(ofSong: "amrec_7"), DiscoverAddsStore.sourceName)
        XCTAssertEqual(adds.entries.map(\.songId), ["amrec_7"])
    }
}
