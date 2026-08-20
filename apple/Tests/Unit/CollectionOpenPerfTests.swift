import XCTest
@testable import PocketDJ

/// Wall-clock guards for the "Favorite Songs"-scale collection paths (26,821 songs): the
/// MAIN-ACTOR portion of opening a source collection, the main-actor commit of Shuffle's
/// `playNow`, the off-main resolve pipeline's correctness, the edition-stamp skip, and the
/// playlist-stats memo. Budgets are 5–10× the expected post-fix cost so CI noise never
/// flakes — they exist to catch an O(n) regression (hundreds of ms → seconds), not to
/// benchmark.
@MainActor
final class CollectionOpenPerfTests: XCTestCase {

    static let songCount = 26_821
    static let albumCount = 1_000

    /// One shared 26,821-song catalog for the whole class (decoding it per-test would
    /// dominate the run). Built as one JSON document — `IndexSong`/`IndexAlbum` are
    /// Decodable-only, and a single decode is far cheaper than 26k per-song decodes.
    static let fixture: IndexJSON = {
        var albums: [String] = []
        albums.reserveCapacity(albumCount)
        var songs: [String] = []
        songs.reserveCapacity(songCount)
        let perAlbum = (songCount + albumCount - 1) / albumCount
        for a in 0..<albumCount {
            let lo = a * perAlbum
            let hi = min(lo + perAlbum, songCount)
            guard lo < hi else { break }
            let tracks = (lo..<hi).map { "\"sng_\($0)\"" }.joined(separator: ",")
            albums.append("""
            { "id": "alb_\(a)", "artist": "Artist \(a % 137)", "name": "Album \(a)", \
            "genre": "Electronic", "year": \(1970 + a % 55), "trackList": [\(tracks)] }
            """)
            for i in lo..<hi {
                songs.append("""
                { "id": "sng_\(i)", "albumId": "alb_\(a)", "artist": "Artist \(a % 137)", \
                "name": "Song \(i % 977) take \(i)", "trackNumber": \(i - lo + 1), \
                "year": \(1970 + a % 55), "bpm": \(60 + i % 120), "length": \(120_000 + (i % 300) * 1000), \
                "explicit": \(i % 7 == 0 ? "true" : "false") }
                """)
            }
        }
        let json = """
        { "manifest": { "sourceName": "Perf Crate" },
          "albums": [\(albums.joined(separator: ","))],
          "songs": [\(songs.joined(separator: ","))] }
        """
        return try! JSONDecoder().decode(IndexJSON.self, from: Data(json.utf8))
    }()

    private struct FixtureLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON { CollectionOpenPerfTests.fixture }
    }

    /// CollectionsStore.app is a WEAK ref — hold the AppModel for the store's lifetime.
    private var heldApp: AppModel?
    override func tearDown() { heldApp = nil; super.tearDown() }

    private func loadedApp() async -> AppModel {
        let app = AppModel(loader: FixtureLoader())
        await app.loadIfNeeded()
        XCTAssertEqual(app.songCount, Self.songCount)
        return app
    }

    private func wiredStore(_ app: AppModel) -> CollectionsStore {
        heldApp = app
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-perf-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let s = CollectionsStore(fileURL: url)
        s.app = app
        return s
    }

    private var allIds: [String] { (0..<Self.songCount).map { "sng_\($0)" } }

    private func measureMs(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let d = clock.measure(body)
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }

    // MARK: 1 — opening the collection (main-actor portion)

    /// What the main actor pays at open on the windowed source-playlist detail: the
    /// stored-order placeholder page (150 rows), the resolve key, and adopting the resolved
    /// 26,821-row answer as state. The O(n) pipeline itself runs off-main and is NOT in here.
    func testOpenMainActorPortionUnderBudget() async {
        let app = await loadedApp()
        let ids = allIds
        let browse = BrowseState(persistenceKey: "pdj.test.open-\(UUID().uuidString)",
                                 defaultKind: .song)
        // The off-main resolve (not part of the budget) produces the array the tail adopts.
        let full = await app.sortedFilteredSongsAsync(ids: ids, browse: browse,
                                                      collections: nil, favorites: nil)
        XCTAssertEqual(full.count, Self.songCount)
        var placeholder: [IndexSong] = []
        var resolved: [IndexSong] = []
        var resolvedIds: [String] = []
        var key = ""
        let ms = measureMs {
            placeholder = ids.prefix(RowWindow.page).compactMap { app.songsById[$0] }
            key = browse.resultsKey(app)
            resolved = full
            resolvedIds = full.map(\.id)
        }
        XCTAssertEqual(placeholder.count, RowWindow.page)
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(resolved.count, resolvedIds.count)
        XCTAssertLessThan(ms, 250, "open-time main-actor portion regressed to O(seconds)")
    }

    // MARK: 2 — Shuffle's main-actor commit

    /// Post-split `playNow`: the 26,821-track build runs detached; the main actor pays only
    /// `playNowPrepared` (upsert + save). Budget covers the save's document hand-off.
    func testPlayNowMainActorPortionUnderBudget() async {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let ids = allIds
        let songsById = app.songsById          // snapshot on main; the build runs detached
        let (tracks, totalMs) = await Task.detached {
            CollectionsStore.buildNowPlayingTracks(
                songIds: ids, songsById: songsById, repeats: [:], variants: [:],
                studioInfo: [:], studioArtist: "Studio", shuffle: true)
        }.value
        XCTAssertEqual(tracks.count, Self.songCount)
        var committed: Setlist?
        let ms = measureMs {
            committed = collections.playNowPrepared(tracks, totalMs: totalMs,
                                                    name: "Favorite Songs", source: .playlist,
                                                    originId: "pl_fav")
        }
        XCTAssertEqual(committed?.tracks.count, Self.songCount)
        XCTAssertLessThan(ms, 750, "playNow main-actor commit regressed")
        // And a SECOND play releases the prior 26k-track setlist without an O(n) stall
        // beyond the same commit budget.
        let ms2 = measureMs {
            _ = collections.playNowPrepared(tracks, totalMs: totalMs, name: "Favorite Songs",
                                            source: .playlist, originId: "pl_fav")
        }
        XCTAssertLessThan(ms2, 750)
    }

    // MARK: 3 — off-main pipeline correctness

    /// The detached resolve must produce EXACTLY the sync pipeline's order (same inputs), or
    /// the windowed views would render a different list than the un-windowed ones did.
    func testResolvePipelineOffMainMatchesSyncOrder() async {
        let app = await loadedApp()
        let ids = allIds
        let browse = BrowseState(persistenceKey: "pdj.test.resolve-\(UUID().uuidString)",
                                 defaultKind: .song)
        browse.sortKeys = [SortKey(field: "bpm", dir: .desc), SortKey(field: "name", dir: .asc)]
        let sync = app.sortedFilteredSongs(ids: ids, browse: browse,
                                           collections: nil, favorites: nil)
        let async = await app.sortedFilteredSongsAsync(ids: ids, browse: browse,
                                                       collections: nil, favorites: nil)
        XCTAssertEqual(sync.map(\.id), async.map(\.id))
    }

    // MARK: 4 — edition stamp skip + off-main stamp

    /// With the tri-state preference UNSET (decider active probe false) and no frozen
    /// variants, `prepareStamped` must return the items untouched, fast — the 26k map is
    /// skipped entirely.
    func testPrepareStampedSkipsWhenPreferenceUnset() async {
        let app = await loadedApp()
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burnsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-perf-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: burnsURL) }
        let burns = BurnStore(rips: rips, fileURL: burnsURL)
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: PlayerEngine()),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let player = SetlistPlayer(player: PlayerEngine(), rips: rips, burns: burns,
                                   coordinator: coordinator)
        let songsById = app.songsById
        player.editionDecider = { id, cleanOnly in
            EditionPolicy.decide(song: songsById[id], collectionCleanOnly: cleanOnly,
                                 preferExplicitRaw: nil)
        }
        player.editionDeciderActive = { false }   // tri-state raw == nil
        player.editionStampInputs = { (songsById, nil) }
        let items: [SetlistPlayer.Item] = allIds.compactMap { id in
            guard let s = songsById[id] else { return nil }
            return SetlistPlayer.Item(id: s.id, title: s.name, artist: s.artist,
                                      lengthMs: s.length)
        }
        let start = ContinuousClock().now
        let stamped = await player.prepareStamped(items, sourceSetlistId: nil)
        let elapsed = start.duration(to: ContinuousClock().now)
        XCTAssertEqual(stamped, items)
        XCTAssertLessThan(elapsed, .milliseconds(250),
                          "unset-preference stamp must be the O(1)-ish skip path")
    }

    // MARK: 5 — playlist stats memo

    /// The schema reindex (and every stats caller) must hit `resolvedStats`' memo: the second
    /// resolve of an unchanged 26,821-song playlist is O(1), not another full catalog fold.
    func testPlaylistStatsMemoSecondResolveFast() async {
        let app = await loadedApp()
        let collections = wiredStore(app)
        let pl = collections.createPlaylist("Favorite Songs", songIds: allIds)
        _ = collections.stats(forPlaylist: pl)          // first resolve fills the memo
        var second = CollectionCatalog.Stats()
        let ms = measureMs {
            for _ in 0..<50 { second = collections.stats(forPlaylist: pl) }
        }
        XCTAssertEqual(second.count, Self.songCount)
        XCTAssertLessThan(ms, 100, "stats memo miss — 50 reads re-walked the catalog")
    }
}
