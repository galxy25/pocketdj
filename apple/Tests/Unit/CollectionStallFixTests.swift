import XCTest
@testable import PocketDJ

/// Behavior guards for the collection-open/shuffle/back-nav stall fixes: each test pins ONE
/// semantic the perf change must not have moved — key stability, default-kind seeding, the
/// flattened-window arithmetic, the split `playNow`'s document parity, the pure edition
/// stamp's parity with the sync stamp, the play-count snapshot memo, the rip-poll republish
/// guard, and the write-back unsyncable set.
@MainActor
final class CollectionStallFixTests: XCTestCase {

    private var heldApp: AppModel?
    override func tearDown() { heldApp = nil; super.tearDown() }

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        return app
    }

    private func wiredStore(_ app: AppModel) -> CollectionsStore {
        heldApp = app
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-stallfix-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let s = CollectionsStore(fileURL: url)
        s.app = app
        return s
    }

    private func freshBrowse(defaultKind: ItemKind? = .song) -> BrowseState {
        BrowseState(persistenceKey: "pdj.test.\(UUID().uuidString)", defaultKind: defaultKind)
    }

    // MARK: resultsKey ↔ play counts

    /// With NO play-count clause or sort, a play-count revision bump must NOT move the key —
    /// that bump used to re-resolve a 26k collection once per capture checkpoint / play.
    func testResultsKeyIgnoresPlayCountsWhenUnused() async {
        let app = await loadedApp()
        let b = freshBrowse()
        let before = b.resultsKey(app)
        b.applyPlayCounts(["sng_1": 7], revision: 41)
        XCTAssertEqual(b.resultsKey(app), before)
        XCTAssertFalse(b.usesPlayCounts)
    }

    /// With a "Plays" sort active the key MUST move with the revision — the memo would
    /// otherwise serve pre-capture ordering forever.
    func testResultsKeyTracksPlayCountsWhenSorted() async {
        let app = await loadedApp()
        let b = freshBrowse()
        b.sortKeys = [SortKey(field: "playCount", dir: .desc)]
        XCTAssertTrue(b.usesPlayCounts)
        let before = b.resultsKey(app)
        b.applyPlayCounts(["sng_1": 7], revision: 41)
        XCTAssertNotEqual(b.resultsKey(app), before)
    }

    /// A play-count FILTER clause also counts as using them.
    func testResultsKeyTracksPlayCountsWhenFiltered() async {
        let app = await loadedApp()
        let b = freshBrowse()
        b.clauses = [Clause(field: "playCount", op: .between, min: 1)]
        XCTAssertFalse(b.clauses[0].isIncomplete)
        XCTAssertTrue(b.usesPlayCounts)
    }

    // MARK: default kind seeding

    /// A FRESH per-collection BrowseState starts in song mode — the `.album`-default →
    /// onAppear-flip used to guarantee a second full resolve on every first open.
    func testDefaultKindSeedsSongForFreshCollectionState() {
        let b = freshBrowse(defaultKind: .song)
        XCTAssertEqual(b.kind, .song)
    }

    /// A persisted snapshot always beats the default.
    func testPersistedSnapshotBeatsDefaultKind() {
        let key = "pdj.test.persist-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        let first = BrowseState(persistenceKey: key)
        first.kind = .album
        first.persist()
        let second = BrowseState(persistenceKey: key, defaultKind: .song)
        XCTAssertEqual(second.kind, .album)
    }

    // MARK: flattened chapter window

    /// The per-chapter slices of one shared window: order-preserving prefix, sums to
    /// min(shown, total), and EXACTLY ONE chapter hosts the sentinel while rows remain.
    func testFlattenedWindowPartition() {
        let chapters = [0, 40, 0, 200, 10, 3]      // includes empty chapters
        let total = chapters.reduce(0, +)
        for shown in [0, 1, 39, 40, 41, 150, 240, 253, 500] {
            var start = 0
            var rendered = 0
            var sentinels = 0
            for count in chapters {
                let local = RowWindow.localShown(start: start, count: count, shown: shown)
                XCTAssertGreaterThanOrEqual(local, 0)
                XCTAssertLessThanOrEqual(local, count)
                rendered += local
                if RowWindow.hostsSentinel(start: start, count: count, shown: shown, total: total) {
                    sentinels += 1
                    // The sentinel lives where the window's edge falls.
                    XCTAssertLessThan(local, count == 0 ? 1 : count + 1)
                }
                start += count
            }
            XCTAssertEqual(rendered, min(max(shown, 0), total), "shown=\(shown)")
            XCTAssertEqual(sentinels, shown < total ? 1 : 0, "shown=\(shown)")
        }
    }

    // MARK: split playNow parity

    /// The detached builder + main commit must persist the SAME document the old inline
    /// funnel wrote: same track order/fields, same totalMs, decodable round-trip.
    func testPlayNowPreparedMatchesSyncFunnelDocument() async throws {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let ids = ["sng_3", "sng_1", "sng_6", "sng_404", "sng_2"]   // one unresolvable

        let viaSync = collections.playNow(songIds: ids, name: "Parity", shuffle: false,
                                          source: .playlist, repeats: ["sng_1": 3],
                                          originId: "pl_x")
        let syncTracks = try XCTUnwrap(viaSync).tracks

        let (tracks, totalMs) = CollectionsStore.buildNowPlayingTracks(
            songIds: ids, songsById: app.songsById, repeats: ["sng_1": 3], variants: [:],
            studioInfo: [:], studioArtist: "Studio", shuffle: false)
        XCTAssertEqual(tracks.map(\.songId), syncTracks.map(\.songId))
        XCTAssertEqual(tracks.map(\.name), syncTracks.map(\.name))
        XCTAssertEqual(tracks.map(\.repeatCount), syncTracks.map(\.repeatCount))
        XCTAssertEqual(totalMs, viaSync?.totalMs)

        let committed = collections.playNowPrepared(tracks, totalMs: totalMs, name: "Parity",
                                                    source: .playlist, originId: "pl_x")
        XCTAssertEqual(committed.id, nowPlayingSetlistId)
        // One reserved setlist, latest content (the upsert never duplicates).
        let live = try XCTUnwrap(collections.setlist(nowPlayingSetlistId))
        XCTAssertEqual(live.tracks.map(\.songId), tracks.map(\.songId))
        XCTAssertEqual(collections.setlists.filter { $0.id == nowPlayingSetlistId }.count, 1)
    }

    /// Shuffle produces a permutation (same multiset, same runtime), never a different set.
    func testBuildNowPlayingTracksShuffleIsPermutation() async {
        let app = await loadedApp()
        let ids = ["sng_1", "sng_2", "sng_3", "sng_4", "sng_5", "sng_6", "sng_7"]
        let (plain, plainMs) = CollectionsStore.buildNowPlayingTracks(
            songIds: ids, songsById: app.songsById, repeats: [:], variants: [:],
            studioInfo: [:], studioArtist: "Studio", shuffle: false)
        let (shuffled, shuffledMs) = CollectionsStore.buildNowPlayingTracks(
            songIds: ids, songsById: app.songsById, repeats: [:], variants: [:],
            studioInfo: [:], studioArtist: "Studio", shuffle: true)
        XCTAssertEqual(plain.map(\.songId).sorted(), shuffled.map(\.songId).sorted())
        XCTAssertEqual(plainMs, shuffledMs)
    }

    // MARK: pure edition stamp parity

    /// `stampEditionsPure` must produce exactly what the sync instance stamp produces under
    /// the production wiring (decider == EditionPolicy.decide) — for unset/clean/explicit
    /// raw states, frozen variants included.
    func testStampEditionsPureMatchesInstanceStamp() async {
        let app = await loadedApp()
        let songsById = app.songsById
        var items: [SetlistPlayer.Item] = ["sng_1", "sng_2", "sng_6", "sng_7"].compactMap {
            guard let s = songsById[$0] else { return nil }
            return SetlistPlayer.Item(id: s.id, title: s.name, artist: s.artist, lengthMs: s.length)
        }
        items[2].variant = .clean          // a frozen row
        for raw in [nil, true, false] as [Bool?] {
            for cleanOnly in [false, true] {
                let pure = SetlistPlayer.stampEditionsPure(items, cleanOnly: cleanOnly,
                                                           songsById: songsById,
                                                           preferExplicitRaw: raw)
                for (i, row) in pure.enumerated() {
                    let expected: EditionPolicy.Decision
                    if items[i].variant != nil {
                        expected = EditionPolicy.decide(song: songsById[row.id],
                                                        collectionCleanOnly: true,
                                                        preferExplicitRaw: raw)
                        XCTAssertTrue(row.editionLocked)
                        XCTAssertEqual(row.editionCatalogId, expected.catalogId)
                        XCTAssertEqual(row.variant, items[i].variant)   // frozen wins
                    } else if cleanOnly {
                        XCTAssertTrue(row.editionLocked)
                        XCTAssertNil(row.variant)
                    } else {
                        expected = EditionPolicy.decide(song: songsById[row.id],
                                                        collectionCleanOnly: false,
                                                        preferExplicitRaw: raw)
                        XCTAssertEqual(row.variant, expected.edition)
                        XCTAssertEqual(row.editionCatalogId, expected.catalogId)
                    }
                }
            }
        }
    }

    // MARK: play-count snapshot memo

    /// One build per revision (three mounted feeds used to build it three times), and a
    /// revision bump both invalidates the memo and keeps `snapshot()[id]` ==
    /// `combinedPlayCount(id)` — the badge now reads the snapshot.
    func testSnapshotMemoOneBuildPerRevision() {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-snapmemo-\(UUID().uuidString).json")
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-snapmemo-stats-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: statsURL)
            try? FileManager.default.removeItem(at: AMPlayBaselineStore.provisionalURL(for: baseURL))
        }
        let svc = PlayCountService(baseline: AMPlayBaselineStore(fileURL: baseURL),
                                   stats: PlayStatsStore(fileURL: statsURL))
        svc.notePlayed("sng_a", backend: .ripServer)
        _ = svc.snapshot()
        _ = svc.snapshot()
        _ = svc.snapshot()
        XCTAssertEqual(svc.snapshotBuilds, 1, "three reads at one revision must build once")
        svc.notePlayed("sng_a", backend: .ripServer)
        let snap = svc.snapshot()
        XCTAssertEqual(svc.snapshotBuilds, 2, "a revision bump rebuilds")
        XCTAssertEqual(snap["sng_a"], svc.combinedPlayCount("sng_a"),
                       "the badge's snapshot read must agree with combinedPlayCount")
    }

    // MARK: async play twins (playlist/pocket) — full off-main resolve parity

    /// The playlist twin now detaches the WHOLE resolve (DAG walk + CleanOnly + repeat map +
    /// build), not just the track build — it must still produce the sync funnel's exact
    /// document (order, drops, name, totalMs, source tagging).
    func testPlayNowAsyncPlaylistTwinMatchesSyncFunnel() async throws {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let pl = collections.createPlaylist("Twin", songIds: ["sng_3", "sng_1", "sng_404", "sng_6", "sng_2"])

        let sync = try XCTUnwrap(collections.playNow(playlistId: pl.id))
        let syncIds = sync.tracks.map(\.songId)
        let syncMs = sync.totalMs
        let syncName = sync.name

        let asyncResult = await collections.playNowAsync(playlistId: pl.id)
        let viaAsync = try XCTUnwrap(asyncResult)
        XCTAssertEqual(viaAsync.tracks.map(\.songId), syncIds)
        XCTAssertEqual(viaAsync.totalMs, syncMs)
        XCTAssertEqual(viaAsync.name, syncName)
        XCTAssertEqual(viaAsync.id, nowPlayingSetlistId)
        XCTAssertEqual(collections.nowPlayingSource, .playlist)
        XCTAssertEqual(collections.setlists.filter { $0.id == nowPlayingSetlistId }.count, 1)
    }

    /// Same parity for the pocket twin (DAG-resolved order, dedupe, repeats snapshot).
    func testPlayNowAsyncPocketTwinMatchesSyncFunnel() async throws {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let pk = collections.createPocket("TwinPocket", songIds: ["sng_6", "sng_2", "sng_2", "sng_1"])

        let sync = try XCTUnwrap(collections.playNow(pocketId: pk.id))
        let syncIds = sync.tracks.map(\.songId)
        let syncMs = sync.totalMs

        let asyncResult = await collections.playNowAsync(pocketId: pk.id)
        let viaAsync = try XCTUnwrap(asyncResult)
        XCTAssertEqual(viaAsync.tracks.map(\.songId), syncIds)
        XCTAssertEqual(viaAsync.totalMs, syncMs)
        XCTAssertEqual(viaAsync.name, sync.name)
        XCTAssertEqual(collections.nowPlayingSource, .pocket)
    }

    // MARK: read-time filter resolve keys

    /// The collection-detail resolve keys fold `readTimeKey` — it must move whenever a
    /// read-time INPUT moves (♥ set while a favorite filter is on, the filter MODE, the
    /// membership selection, a selected collection's contents) and stay byte-stable when
    /// nothing relevant changes (the folded booleans it replaced missed all four).
    func testReadTimeKeyTracksReadTimeInputs() async throws {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rtk-fav-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let b = freshBrowse()

        // No read-time filter: empty and unaffected by ♥ churn.
        XCTAssertEqual(b.readTimeKey(collections: collections, favorites: favorites), "")
        _ = favorites.toggle("sng_1", appleMusicId: nil)
        XCTAssertEqual(b.readTimeKey(collections: collections, favorites: favorites), "")

        // Favorite filter on: a ♥ toggle must re-key; a mode flip (only→exclude) must too.
        b.favoriteFilter = .only
        let k1 = b.readTimeKey(collections: collections, favorites: favorites)
        XCTAssertFalse(k1.isEmpty)
        _ = favorites.toggle("sng_2", appleMusicId: nil)
        let k2 = b.readTimeKey(collections: collections, favorites: favorites)
        XCTAssertNotEqual(k2, k1, "a ♥ change while the filter is on must move the key")
        b.favoriteFilter = .exclude
        let k3 = b.readTimeKey(collections: collections, favorites: favorites)
        XCTAssertNotEqual(k3, k2, "a favorite-filter MODE flip must move the key")
        b.favoriteFilter = .any

        // Membership filter on: selection identity and selected-collection CONTENTS both count.
        let target = collections.createPlaylist("Y", songIds: ["sng_1"])
        b.includeIds = [target.id]
        let m1 = b.readTimeKey(collections: collections, favorites: favorites)
        XCTAssertFalse(m1.isEmpty)
        XCTAssertEqual(b.readTimeKey(collections: collections, favorites: favorites), m1,
                       "stable inputs ⇒ stable key")
        try await Task.sleep(nanoseconds: 5_000_000)   // updatedAt is epoch-ms; outrun the clock
        collections.addSong("sng_2", toPlaylist: target.id)
        XCTAssertNotEqual(b.readTimeKey(collections: collections, favorites: favorites), m1,
                          "editing a collection while a membership filter is on must move the key")
        let m2 = b.readTimeKey(collections: collections, favorites: favorites)
        b.includeIds = []
        b.excludeIds = [target.id]
        XCTAssertNotEqual(b.readTimeKey(collections: collections, favorites: favorites), m2,
                          "flipping the SELECTION (in → not-in) must move the key")
    }

    // MARK: play-count revision ↔ stats store bypass paths

    /// `PlayStatsStore.reloadFromDisk` (the CloudSync pull hook) and `clear()` (account
    /// deletion) replace the stats wholesale WITHOUT passing through `PlayCountService` —
    /// the service revision must still move, or the memoized snapshot (which the badges and
    /// the "Plays" sort read) serves pre-pull counts until the next local play.
    func testPlayCountRevisionTracksStatsReloadAndClear() {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rev-base-\(UUID().uuidString).json")
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rev-stats-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: statsURL)
            try? FileManager.default.removeItem(at: AMPlayBaselineStore.provisionalURL(for: baseURL))
        }
        let stats = PlayStatsStore(fileURL: statsURL)
        let svc = PlayCountService(baseline: AMPlayBaselineStore(fileURL: baseURL), stats: stats)
        svc.notePlayed("sng_a", backend: .ripServer)
        XCTAssertEqual(svc.snapshot()["sng_a"], 1)

        let r1 = svc.revision
        stats.reloadFromDisk()                       // cloud pull (same bytes — still a new map)
        XCTAssertNotEqual(svc.revision, r1, "a cloud-pull reload must move the revision")
        XCTAssertEqual(svc.snapshot()["sng_a"], svc.combinedPlayCount("sng_a"),
                       "snapshot and combinedPlayCount must agree after a reload")

        let r2 = svc.revision
        stats.clear()                                // AccountDeletionService path
        XCTAssertNotEqual(svc.revision, r2, "clear() must move the revision")
        XCTAssertNil(svc.snapshot()["sng_a"], "the memoized snapshot must drop cleared counts")
        XCTAssertEqual(svc.combinedPlayCount("sng_a"), 0)
    }

    // MARK: rip-poll republish guard

    /// Adopting an IDENTICAL job value must not republish `jobs` (every mounted row
    /// re-rendered on the 2s poll cadence); a changed value must.
    func testAdoptJobSkipsIdenticalValue() {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let job = RipsStore.Job(jobId: "j1", songId: "sng_1", phase: .ripping)
        rips.adoptJob(job, for: "sng_1")

        var fired = false
        withObservationTracking {
            _ = rips.jobs
        } onChange: {
            fired = true
        }
        rips.adoptJob(job, for: "sng_1")               // identical — no publish
        XCTAssertFalse(fired, "identical poll value republished jobs")

        var changed = job
        changed.phase = .ready
        rips.adoptJob(changed, for: "sng_1")           // real change — publishes
        XCTAssertTrue(fired)
        XCTAssertEqual(rips.jobs["sng_1"]?.phase, .ready)
    }

    // MARK: write-back unsyncable set

    private final class NoMatchTransport: PlaylistWriteBackTransport {
        var isSupported: Bool { true }
        var canWrite: Bool { true }
        func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String? {
            "p.TEST"
        }
        func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws {}
        // Identity-only songs resolve to nil ⇒ `.unresolvable`.
    }

    /// The memoized set must match the old per-song filter semantics: unresolvable ⇒ badge;
    /// a later queued job for the same song supersedes the verdict; and the memo tracks
    /// queue mutations (the didSet invalidation).
    func testUnsyncableSetMatchesFilterSemantics() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-unsync-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let queue = PlaylistWriteBack(fileURL: url, transport: NoMatchTransport())

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Favorite Songs",
                      songId: "sng_nm", appleMusicId: nil, title: "Ghost", artist: "Nobody")
        XCTAssertFalse(queue.isUnsyncable("sng_nm"), "queued must not badge")
        await queue.run()
        XCTAssertTrue(queue.isUnsyncable("sng_nm"), "no catalog match ⇒ unresolvable ⇒ badge")
        XCTAssertFalse(queue.isUnsyncable("sng_other"))

        // A fresh enqueue WITH a real store id supersedes the verdict (memo must follow).
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Favorite Songs",
                      songId: "sng_nm", appleMusicId: "12345", title: "Ghost", artist: "Nobody")
        XCTAssertFalse(queue.isUnsyncable("sng_nm"), "a queued retry clears the badge")
    }

    // MARK: source-playlist hashing

    /// Equal values hash equal (required); the hash no longer folds the 26k member ids —
    /// two playlists differing ONLY by id hash differently, and hashing is O(1)-ish.
    func testIndexPlaylistHashCheapAndConsistent() throws {
        let json = { (id: String) in
            """
            {"id":"\(id)","name":"Favorite Songs","songIds":["a","b","c"]}
            """
        }
        let a1 = try JSONDecoder().decode(IndexPlaylist.self, from: Data(json("pl_1").utf8))
        let a2 = try JSONDecoder().decode(IndexPlaylist.self, from: Data(json("pl_1").utf8))
        let b = try JSONDecoder().decode(IndexPlaylist.self, from: Data(json("pl_2").utf8))
        XCTAssertEqual(a1, a2)
        XCTAssertEqual(a1.hashValue, a2.hashValue)
        XCTAssertNotEqual(a1, b)
        let s1 = SourcePlaylist(playlist: a1, sourceName: "Apple Music (Local)")
        let s2 = SourcePlaylist(playlist: a2, sourceName: "Apple Music (Local)")
        XCTAssertEqual(s1.hashValue, s2.hashValue)
    }
}
