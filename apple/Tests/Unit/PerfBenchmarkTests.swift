import XCTest
@testable import PocketDJ

/// PERFORMANCE BENCHMARKS — the measuring stick for the three latency complaints:
///
///   1. Collection DETAIL: a 3,650-item collection takes ~9 s to open, and Shuffle
///      another ~4-5 s.
///   2. Collections LIST: every row rebuilds the whole catalog to print "N songs".
///   3. Sequencer: a 75+ bar arrangement freezes the UI for seconds on open.
///
/// These are deliberately NOT `measure {}` blocks with XCTest baselines — a baseline file
/// is machine-specific and would fail CI on a different box. Instead each test prints a
/// wall-clock number and asserts a GENEROUS ceiling: the assertion catches a regression of
/// the "we went back to O(n·m) on the main thread" kind, while the printed number is what
/// you actually read when tuning. Run with:
///
///   xcodebuild test -project apple/PocketDJ.xcodeproj -scheme PocketDJ \
///     -destination 'platform=iOS Simulator,name=iPhone 16' \
///     -only-testing:PocketDJTests/PerfBenchmarkTests
///
/// NOTE: a new test FILE needs `xcodegen generate` (run in apple/) before it is compiled.
@MainActor
final class PerfBenchmarkTests: XCTestCase {

    /// `CollectionsStore.app` is weak — the model must be retained for the store's lifetime.
    private var heldApp: AppModel?

    override func tearDown() { heldApp = nil; super.tearDown() }

    // MARK: - Synthetic catalog

    /// The real-world shape this audit targets: a library big enough that an O(catalog)
    /// scan per row is fatal, and a collection big enough to match the user's 3,650.
    /// Calibrated against the developer's ACTUAL library on 2026-08-02:
    /// `~/.pocketdj/am-sync-clone/public/apple-music-index.json` = 95,962 songs / 12,615 albums,
    /// of which 93,451 carry `dateAdded`. Scale and `dateAdded` COVERAGE both matter — a
    /// fixture without `dateAdded` makes `recentlyAddedSongIds` look free when it is the single
    /// most expensive thing the collections list does.
    private enum Shape {
        static let catalogSongs = 96_000
        static let tracksPerAlbum = 8
        /// Fraction of songs carrying `dateAdded` (93,451 / 95,962 ≈ 0.974).
        static let dateAddedShare = 0.974
        /// `SettingsStore.recentlyAddedDefaultCount` — the user's "collection with 3,650 items".
        static let collectionItems = 3_650
        static let collectionsInList = 30
    }

    /// Build an `IndexJSON` with `songs` songs spread over `songs / tracksPerAlbum` albums.
    /// Field-for-field the same shape as `TestData.json`, just big — so every downstream
    /// derivation (search keys, genre folding, source tagging) does its real work.
    private static func syntheticIndex(songs: Int) throws -> IndexJSON {
        let albumCount = max(1, songs / Shape.tracksPerAlbum)
        let genres = ["Electronic", "Jazz", "Funk / Soul", "Rock", "Hip Hop", "Classical"]
        let artists = (0..<200).map { "Artist \($0)" }

        var albumObjs: [[String: Any]] = []
        var songObjs: [[String: Any]] = []
        albumObjs.reserveCapacity(albumCount)
        songObjs.reserveCapacity(songs)

        for a in 0..<albumCount {
            let trackIds = (0..<Shape.tracksPerAlbum).compactMap { t -> String? in
                let idx = a * Shape.tracksPerAlbum + t
                return idx < songs ? "sng_\(idx)" : nil
            }
            let artist = artists[a % artists.count]
            albumObjs.append([
                "id": "alb_\(a)", "artist": artist, "name": "Album \(a)",
                "genre": genres[a % genres.count], "year": 1970 + (a % 55),
                "country": "US", "trackList": trackIds, "fileType": "mp3",
            ])
            for (t, sid) in trackIds.enumerated() {
                var obj: [String: Any] = [
                    "id": sid, "albumId": "alb_\(a)", "artist": artist,
                    // Diacritics + mixed case on purpose: the folded search key is one of
                    // the per-row costs under test, and ASCII-only strings would flatter it.
                    "name": "Sóng \(sid) — Café Mix", "trackNumber": t + 1,
                    "year": 1970 + (a % 55), "bpm": 60 + (a % 120),
                    "key": "A minor", "camelot": "8A",
                    "length": 180_000 + (t * 1_000), "explicit": t % 3 == 0,
                ]
                // `dateAdded` on ~97% of rows, matching the real library — this is the field
                // `recentlyAddedSongIds` scans and sorts the entire catalog on.
                let idx = a * Shape.tracksPerAlbum + t
                if Double(idx % 1000) < Shape.dateAddedShare * 1000 {
                    // Deterministic pseudo-shuffled timestamps: a large stride mod a prime
                    // spreads add-times so the sort does real comparison work rather than
                    // running along an already-ordered array.
                    obj["dateAdded"] = 1_500_000_000.0 + Double((idx &* 7919) % 300_000_000)
                }
                songObjs.append(obj)
            }
        }

        let root: [String: Any] = [
            "manifest": ["sourceName": "Bench Crate",
                         "counts": ["albums": albumCount, "songs": songs]],
            "albums": albumObjs,
            "songs": songObjs,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(IndexJSON.self, from: data)
    }

    private struct BenchLoader: CatalogLoading {
        let index: IndexJSON
        func loadIndex() async throws -> IndexJSON { index }
    }

    /// The developer's REAL Apple Music index, when this machine has one. The synthetic
    /// catalog above is honest about *shape* but not about *scale* or `dateAdded` coverage,
    /// and both matter enormously: `recentlyAddedSongIds` is O(catalog · log catalog) over
    /// every song that HAS a `dateAdded`, so a fixture without the field measures nothing.
    /// Returns nil off the dev machine, and those tests skip rather than lie.
    private static func realIndex() -> IndexJSON? {
        let path = ("~/.pocketdj/am-sync-clone/public/apple-music-index.json" as NSString)
            .expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(IndexJSON.self, from: data)
    }

    /// AppModel + CollectionsStore at REAL scale: the developer's actual index when it is
    /// readable, otherwise the synthetic catalog calibrated to the same shape. Either way the
    /// numbers are meaningful — the synthetic path just isn't tied to one machine.
    private func wiredReal() async throws -> (AppModel, CollectionsStore) {
        let index: IndexJSON
        if let real = Self.realIndex() {
            print("catalog source: REAL apple-music-index.json")
            index = real
        } else {
            print("catalog source: SYNTHETIC (\(Shape.catalogSongs) songs, calibrated to real shape)")
            index = try Self.syntheticIndex(songs: Shape.catalogSongs)
        }
        let app = AppModel(loader: BenchLoader(index: index))
        await app.loadIfNeeded()
        heldApp = app
        let store = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bench-\(UUID().uuidString).json"))
        store.app = app
        return (app, store)
    }

    /// A fully wired AppModel + CollectionsStore over the synthetic catalog.
    private func wired(songs: Int = Shape.catalogSongs) async throws -> (AppModel, CollectionsStore) {
        let app = AppModel(loader: BenchLoader(index: try Self.syntheticIndex(songs: songs)))
        await app.loadIfNeeded()
        heldApp = app
        let store = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bench-\(UUID().uuidString).json"))
        store.app = app
        return (app, store)
    }

    /// A `BrowseState` with a private UserDefaults suite, so a benchmark never reads or
    /// writes the developer's real persisted browse snapshot.
    private func cleanBrowse(_ key: String = "pdj.bench") -> BrowseState {
        let suite = UserDefaults(suiteName: "pdj.bench.\(UUID().uuidString)")!
        return BrowseState(defaults: suite, persistenceKey: key)
    }

    // MARK: - Timing helper

    @discardableResult
    private func time(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        try body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print(String(format: "⏱  %@: %.1f ms", label, ms))
        return ms
    }

    // MARK: - 1. Collection detail: opening a 3,650-item collection

    /// The ONE cost that dominates the 9-second open: `AppModel.sortedFilteredSongs` over
    /// the collection's ids. `IndexPlaylistDetailView` evaluates its `songs` computed
    /// property FOUR times per body pass (Play `.disabled`, Shuffle `.disabled`, the
    /// footer's `songs.count`, and the `ForEach`), so the user-visible cost is 4× this.
    func testCollectionDetailResolveCost() async throws {
        let (app, store) = try await wired()
        let ids = (0..<Shape.collectionItems).map { "sng_\($0)" }
        let browse = cleanBrowse()

        // Warm once (first call pays one-time lazies), then measure a steady-state pass.
        _ = app.sortedFilteredSongs(ids: ids, browse: browse, collections: store, favorites: nil)

        var single = 0.0
        time("sortedFilteredSongs × 1 (\(ids.count) ids)") {
            single = 0
            let songs = app.sortedFilteredSongs(ids: ids, browse: browse,
                                                collections: store, favorites: nil)
            XCTAssertEqual(songs.count, ids.count)
        }
        single = time("sortedFilteredSongs × 1 (steady)") {
            _ = app.sortedFilteredSongs(ids: ids, browse: browse, collections: store, favorites: nil)
        }

        let bodyPass = time("ONE SwiftUI body pass (4× resolve — the OLD per-body pattern)") {
            for _ in 0..<4 {
                _ = app.sortedFilteredSongs(ids: ids, browse: browse,
                                            collections: store, favorites: nil)
            }
        }

        print(String(format: "→ per-resolve %.1f ms · per-body-pass %.1f ms", single, bodyPass))
        // Ceiling, not a target: a single resolve of 3,650 ids has no business taking
        // more than a quarter second even on a cold simulator.
        XCTAssertLessThan(single, 250, "single resolve of \(ids.count) ids regressed")
    }

    /// Shuffle: `playNow(songIds:…)` builds a 3,650-track setlist and then `save()`s the
    /// ENTIRE collections document synchronously on the main actor.
    func testCollectionShuffleCost() async throws {
        let (_, store) = try await wired()
        let ids = (0..<Shape.collectionItems).map { "sng_\($0)" }

        let ms = time("playNow(shuffle:) — build \(ids.count) tracks + save() whole doc") {
            _ = store.playNow(songIds: ids, name: "Bench", shuffle: true, source: .playlist,
                              originId: "bench")
        }
        XCTAssertNotNil(store.setlist(nowPlayingSetlistId))
        XCTAssertLessThan(ms, 1_000, "shuffle regressed past one second")
    }

    // MARK: - 2. Collections list: the per-row catalog rebuild

    /// `PlaylistsView.playlistRow` calls `collections.catalog()` INSIDE the row body, and
    /// `catalog()` walks every node of every playlist (`studioEntries()`) plus rebuilds the
    /// pockets dictionary. With N rows on screen that is N × (all collections) work — before
    /// `stats(forPlaylist:)` has resolved a single song.
    func testCollectionsListRowStatsCost() async throws {
        let (_, store) = try await wired()

        // One big collection (the user's 3,650) plus a realistic tail of smaller ones.
        var playlistIds: [String] = []
        let big = store.createPlaylist("Big")
        playlistIds.append(big.id)
        for i in 0..<Shape.collectionItems { store.addSong("sng_\(i)", toPlaylist: big.id) }
        for n in 1..<Shape.collectionsInList {
            let pl = store.createPlaylist("List \(n)")
            playlistIds.append(pl.id)
            for i in 0..<50 { store.addSong("sng_\((n * 50 + i) % Shape.catalogSongs)", toPlaylist: pl.id) }
        }

        let buildOnly = time("catalog() built ONCE") {
            _ = store.catalog()
        }

        // The OLD list-body shape: rebuild the catalog for every row. Kept as a comparison
        // point — the view now calls `collections.stats(for…)`, which memoizes.
        let asShipped = time("\(playlistIds.count) rows × catalog() + stats() — the OLD pattern") {
            for id in playlistIds {
                guard let pl = store.playlist(id) else { continue }
                _ = store.catalog().stats(forPlaylist: pl)
            }
        }

        // What it costs when the catalog is hoisted out of the loop (the obvious fix).
        let hoisted = time("\(playlistIds.count) rows × stats() with ONE hoisted catalog()") {
            let cat = store.catalog()
            for id in playlistIds {
                guard let pl = store.playlist(id) else { continue }
                _ = cat.stats(forPlaylist: pl)
            }
        }

        print(String(format: "→ catalog() %.1f ms · as-shipped %.1f ms · hoisted %.1f ms (%.1f×)",
                     buildOnly, asShipped, hoisted, hoisted > 0 ? asShipped / hoisted : 0))
        XCTAssertLessThan(asShipped, 4_000, "collections list row cost regressed")
    }

    // MARK: - 3. The real catalog: "Recently added" recomputed per body pass

    /// THE dominant cost in the collections LIST. `AppModel.recentlyAddedSongIds(limit:)`
    /// walks every song in the catalog, builds a `[String: Double]` of every add-time, then
    /// SORTS all ~93k of them just to take the first 3,650 — and its doc comment says
    /// "Recomputed on read" out loud. `PlaylistsView` calls `recentlyAddedPlaylist(limit:)`
    /// TWICE per body pass (once in `content`'s empty-state test, once in
    /// `recentlyAddedSection`), so a single SwiftUI pass pays for two full catalog sorts.
    func testRecentlyAddedScanCostOnRealCatalog() async throws {
        let (app, _) = try await wiredReal()
        let limit = SettingsStore.recentlyAddedDefaultCount   // 3,650
        print("catalog: \(app.songsById.count) songs, \(app.albumsById.count) albums")

        _ = app.recentlyAddedSongIds(limit: limit)            // warm

        let once = time("recentlyAddedSongIds(limit: \(limit)) × 1") {
            let ids = app.recentlyAddedSongIds(limit: limit)
            XCTAssertLessThanOrEqual(ids.count, limit)
        }
        let bodyPass = time("ONE PlaylistsView body pass (2× recentlyAddedPlaylist — the OLD per-body pattern)") {
            _ = app.recentlyAddedPlaylist(limit: limit)
            _ = app.recentlyAddedPlaylist(limit: limit)
        }
        print(String(format: "→ scan %.1f ms · list body pass %.1f ms", once, bodyPass))
    }

    /// Collection DETAIL over the real catalog: 3,650 ids resolved through the Browse
    /// pipeline, four times per body pass (`IndexPlaylistDetailView.songs` is a computed
    /// property read by Play `.disabled`, Shuffle `.disabled`, the footer count, and the
    /// `ForEach`). Nothing memoizes it — `AppModel.cachedBrowseResults` exists but only the
    /// Browser uses it.
    func testCollectionDetailOnRealCatalog() async throws {
        let (app, store) = try await wiredReal()
        let limit = SettingsStore.recentlyAddedDefaultCount
        guard let ra = app.recentlyAddedPlaylist(limit: limit) else {
            throw XCTSkip("catalog has no dateAdded rows")
        }
        let ids = ra.playlist.songIds
        print("Recently added: \(ids.count) ids")
        let browse = cleanBrowse("pdj.bench.detail")

        _ = app.sortedFilteredSongs(ids: ids, browse: browse, collections: store, favorites: nil)

        let single = time("sortedFilteredSongs × 1 (\(ids.count) ids, real catalog)") {
            _ = app.sortedFilteredSongs(ids: ids, browse: browse, collections: store, favorites: nil)
        }
        let bodyPass = time("ONE detail body pass (4× resolve — the OLD per-body pattern)") {
            for _ in 0..<4 {
                _ = app.sortedFilteredSongs(ids: ids, browse: browse, collections: store, favorites: nil)
            }
        }
        // Navigating in ALSO re-evaluates the list behind it, and `NavigationLink(value: ra)`
        // hashes the whole SourcePlaylist — 3,650 strings — on every pass.
        let hashing = time("hash SourcePlaylist (\(ids.count) ids) × 4") {
            for _ in 0..<4 { _ = ra.hashValue }
        }
        print(String(format: "→ resolve %.1f ms · detail body %.1f ms · hashing %.1f ms",
                     single, bodyPass, hashing))
    }

    /// Shuffle on the real 3,650-item collection: build the setlist, then `save()` the WHOLE
    /// collections document synchronously on the main actor.
    func testShuffleOnRealCatalog() async throws {
        let (app, store) = try await wiredReal()
        guard let ra = app.recentlyAddedPlaylist(limit: SettingsStore.recentlyAddedDefaultCount) else {
            throw XCTSkip("catalog has no dateAdded rows")
        }
        let ids = ra.playlist.songIds
        let ms = time("playNow(shuffle:) on \(ids.count) real ids (build + save whole doc)") {
            _ = store.playNow(songIds: ids, name: ra.name, shuffle: true, source: .playlist,
                              originId: ra.id)
        }
        print(String(format: "→ shuffle %.1f ms", ms))
    }

    // MARK: - 4. After-fix behaviour

    /// The memo is the whole point: the second and subsequent reads of an unchanged input must
    /// cost nothing, because `PlaylistsView` reads this on every body pass.
    func testRecentlyAddedMemoIsFree() async throws {
        let (app, _) = try await wiredReal()
        let limit = SettingsStore.recentlyAddedDefaultCount

        let cold = time("recentlyAddedSongIds — cold (derives)") {
            _ = app.recentlyAddedSongIds(limit: limit)
        }
        let warm = time("recentlyAddedSongIds × 10 — warm (memo)") {
            for _ in 0..<10 { _ = app.recentlyAddedSongIds(limit: limit) }
        }
        print(String(format: "→ cold %.1f ms · 10 warm reads %.1f ms", cold, warm))
        XCTAssertLessThan(warm, max(5, cold / 4), "memo is not serving repeat reads")

        // Identical inputs must give an identical answer — the top-K selection replaced a full
        // sort, so this is also the determinism check the old unstable sort could not pass.
        XCTAssertEqual(app.recentlyAddedSongIds(limit: limit),
                       app.recentlyAddedSongIds(limit: limit))
    }

    /// The empty-state gate needs a boolean, and must not pay for the 3,650-id list to get it.
    func testHasRecentlyAddedIsCheap() async throws {
        let (app, _) = try await wiredReal()
        let limit = SettingsStore.recentlyAddedDefaultCount

        // Fresh model, so neither path is memo-warm.
        let gate = time("hasRecentlyAddedItems (cold)") {
            XCTAssertTrue(app.hasRecentlyAddedItems(limit: limit))
        }
        let full = time("recentlyAddedSongIds (cold)") {
            _ = app.recentlyAddedSongIds(limit: limit)
        }
        print(String(format: "→ gate %.1f ms vs full %.1f ms", gate, full))
        XCTAssertLessThan(gate, max(5, full / 4), "the gate is still doing the full derivation")
    }

    /// `hasRecentlyAddedItems` must agree with `recentlyAddedSongIds` — it is a short-circuit,
    /// not a different question. Checked on an EMPTY catalog too, where both must say no.
    func testRecentlyAddedGateAgreesWithList() async throws {
        let (app, _) = try await wiredReal()
        let limit = SettingsStore.recentlyAddedDefaultCount
        XCTAssertEqual(app.hasRecentlyAddedItems(limit: limit),
                       !app.recentlyAddedSongIds(limit: limit).isEmpty)

        let empty = AppModel(loader: BenchLoader(index: try Self.syntheticIndex(songs: 0)))
        await empty.loadIfNeeded()
        heldApp = empty
        XCTAssertFalse(empty.hasRecentlyAddedItems(limit: limit))
        XCTAssertTrue(empty.recentlyAddedSongIds(limit: limit).isEmpty)
    }

    /// `catalog()` used to walk every node of every collection (to prebuild a studio lookup
    /// table) and is called once per row, so it had to become independent of document size.
    func testCatalogBuildIsIndependentOfDocumentSize() async throws {
        // SYNTHETIC on purpose (same 96k scale): the 26,774 node ids below are the
        // synthetic "sng_<n>" space and must RESOLVE for the stats assertions. Under
        // wiredReal() an unsandboxed host (macOS, with ~/.pocketdj/am-sync-clone
        // present) loaded the REAL index, none of the synthetic ids resolved, and the
        // count asserted 0 — a machine-state failure, not a perf regression.
        let (app, small) = try await wired()
        small.studioLookup = { _ in nil }        // WIRED — the expensive branch, pre-fix
        let emptyDoc = time("catalog() with an empty document") { _ = small.catalog() }

        // Built by writing a document and letting the store decode it, NOT by 26,774 `addSong`
        // calls: every mutation re-encodes and rewrites the WHOLE document (`mutatePlaylist` →
        // `save()`), so looping adds is quadratic and takes hours at this size.
        let nodes = (0..<26_774).map {
            PlaylistNode(nodeId: "n_\($0)", kind: .song, songId: "sng_\($0 % Shape.catalogSongs)")
        }
        let doc = CollectionsDocument(
            schemaVersion: collectionsSchemaVersion, pockets: [], playlists: [
                Playlist(id: "pls_big", name: "Favorite Songs",
                         sequences: [PlaylistNode(nodeId: "seq_1", kind: .sequence, children: nodes)])
            ], setlists: [], folders: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bench-big-\(UUID().uuidString).json")
        try CollectionsCodec.encode(doc).write(to: url)

        let store = CollectionsStore(fileURL: url)
        store.app = app
        store.studioLookup = { _ in nil }
        XCTAssertEqual(store.playlist("pls_big")?.sequences.first?.children?.count, 26_774)

        let bigDoc = time("catalog() with a 26,774-node playlist") { _ = store.catalog() }
        print(String(format: "→ empty %.2f ms · 26,774 nodes %.2f ms", emptyDoc, bigDoc))
        XCTAssertLessThan(bigDoc, max(2, emptyDoc * 5 + 1),
                          "catalog() still scales with document size")

        // And the subtitle itself: first resolve pays, repeat renders must not.
        let first = time("stats(forPlaylist:) on 26,774 nodes — first") {
            XCTAssertEqual(store.stats(forPlaylist: store.playlist("pls_big")!).count, 26_774)
        }
        let repeated = time("stats(forPlaylist:) × 30 — memoized (one list render)") {
            let pl = store.playlist("pls_big")!
            for _ in 0..<30 { _ = store.stats(forPlaylist: pl) }
        }
        print(String(format: "→ first %.2f ms · 30 repeats %.2f ms", first, repeated))
        XCTAssertLessThan(repeated, max(2, first), "stats memo is not serving repeat renders")
    }

    /// The count subtitle alone, for the single 3,650-item collection — this is what has to
    /// become O(1) (cached) rather than O(items) per body pass.
    func testSingleCollectionStatsCost() async throws {
        let (_, store) = try await wired()
        let pl = store.createPlaylist("Big")
        for i in 0..<Shape.collectionItems { store.addSong("sng_\(i)", toPlaylist: pl.id) }
        guard let big = store.playlist(pl.id) else { return XCTFail("playlist vanished") }

        let cat = store.catalog()
        let ms = time("stats(forPlaylist:) on \(Shape.collectionItems) items") {
            let stats = cat.stats(forPlaylist: big)
            XCTAssertEqual(stats.count, Shape.collectionItems)
        }
        XCTAssertLessThan(ms, 250, "single-collection stats regressed")
    }
}
