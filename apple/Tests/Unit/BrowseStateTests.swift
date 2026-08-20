import XCTest
@testable import PocketDJ

@MainActor
final class BrowseStateTests: XCTestCase {
    /// CollectionsStore.app is a WEAK ref — hold the AppModel for the store's lifetime.
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
            .appendingPathComponent("pdj-browse-\(UUID().uuidString).json"))
        s.app = app
        return s
    }

    func testAppLoadsFromLoader() async {
        let app = await loadedApp()
        XCTAssertEqual(app.state, .loaded)
        XCTAssertEqual(app.albumCount, 3)
        XCTAssertEqual(app.songCount, 7)
        XCTAssertEqual(app.sourceName, "Test Crate")
    }

    /// Stage 6 gate: a "Pocket DJ" profile song is HIDDEN in Browse when its asset isn't local, shown
    /// when it is, and a normal catalog song is unaffected either way.
    func testProfileSongHiddenWhenAssetAbsent() async {
        let app = await loadedApp()
        let ps = ProfileSourceStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-browse-src-\(UUID().uuidString).json"))
        ps.profileName = "Levi"
        app.profileSource = ps
        let entry = ProfileSourceStore.SongEntry(songId: "pdj_test", title: "My Kick", kind: .sample,
                                                 fileName: "pdj_test.m4a", durationMs: 1000,
                                                 bpm: nil, key: nil, camelot: nil, addedAtMs: 0)
        app.injectProfileItem(songs: [ProfileSourceStore.indexSong(entry, profileName: "Levi")], albums: [])
        let b = BrowseState(); b.kind = .song

        let hidden = b.results(app, profileLocal: { _ in false }).map(\.idString)
        XCTAssertFalse(hidden.contains("pdj_test"))     // no local asset ⇒ hidden
        XCTAssertTrue(hidden.contains("sng_1"))         // catalog song unaffected

        let shown = b.results(app, profileLocal: { _ in true }).map(\.idString)
        XCTAssertTrue(shown.contains("pdj_test"))        // asset present ⇒ shown
    }

    func testBaseItemsByKind() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .album
        XCTAssertEqual(b.baseItems(app).count, 3)
        b.kind = .song
        XCTAssertEqual(b.baseItems(app).count, 7)
    }

    func testQueryFiltersSongs() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        b.query = "neon"
        XCTAssertEqual(b.results(app).map(\.idString), ["sng_1"])
    }

    func testResultsPipelineFilterThenSort() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        b.clauses = [bpm]
        b.sortKeys = [SortKey(field: "bpm", dir: .asc)]
        // 110,116,124,128 → sng_4, sng_6, sng_2, sng_1
        XCTAssertEqual(b.results(app).map(\.idString), ["sng_4", "sng_6", "sng_2", "sng_1"])
    }

    func testGenreOptionsAreCategoriesInPriorityOrder() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .album
        // Raw genres Electronic/Jazz/"Funk / Soul" collapse to categories and sort
        // in the PWA's priority order: jazz, funk, electronic.
        XCTAssertEqual(b.options(for: "genre", in: app), ["jazz", "funk", "electronic"])
    }

    func testCamelotOptionsAreWheelOrdered() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        // present camelots: 7A,7B,8A,8B,9A,9B,10A in wheel order
        XCTAssertEqual(b.options(for: "camelot", in: app),
                       ["7A", "7B", "8A", "8B", "9A", "9B", "10A"])
    }

    func testPersistsAndRestoresPrefs() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let b = BrowseState(defaults: defaults)
        b.kind = .song
        b.layout = .list
        b.clauses = [Clause(field: "bpm", op: .between, min: 100, max: 130)]
        b.sortKeys = [SortKey(field: "camelot", dir: .desc)]
        b.persist()

        let restored = BrowseState(defaults: defaults)
        XCTAssertEqual(restored.kind, .song)
        XCTAssertEqual(restored.layout, .list)
        XCTAssertEqual(restored.clauses.first?.field, "bpm")
        XCTAssertEqual(restored.clauses.first?.min, 100)
        XCTAssertEqual(restored.sortKeys.first?.dir, .desc)
    }

    func testRemoveClauseLeavesTheOthers() {
        let b = BrowseState()
        let bpm = Clause(field: "bpm", op: .between, min: 100, max: 130)
        let genre = Clause(field: "genre", op: .inList, values: ["funk"])
        let explicit = Clause(field: "explicit", op: .eq, value: "true")
        b.clauses = [bpm, genre, explicit]

        b.removeClause(id: genre.id)

        XCTAssertEqual(b.clauses.map(\.id), [bpm.id, explicit.id])
        XCTAssertFalse(b.clauses.contains { $0.id == genre.id })
    }

    func testActiveFilterCountIgnoresIncomplete() async {
        let b = BrowseState()
        b.clauses = [Clause(field: "bpm", op: .eq, value: ""),          // incomplete
                     Clause(field: "explicit", op: .eq, value: "true")]  // complete
        XCTAssertEqual(b.activeFilterCount, 1)
    }

    // MARK: Genre on songs (resolved from the owning album, like the PWA SongItem.genre)

    func testGenreFilterOnSongsResolvesViaAlbum() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        // alb_3 ("Funk / Soul") → category "funk" owns sng_6, sng_7.
        b.clauses = [Clause(field: "genre", op: .inList, values: ["funk"])]
        XCTAssertEqual(Set(b.results(app).map(\.idString)), ["sng_6", "sng_7"])
    }

    func testGenreOptionsOnSongsAreCategories() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        // Same three categories the albums map to, in priority order.
        XCTAssertEqual(b.options(for: "genre", in: app), ["jazz", "funk", "electronic"])
    }

    // MARK: Genre predicate semantics (mirror PWA filterEngine matchClause)

    /// in-list is ANY-of (multi-value): PWA `case 'in': vals.map(norm).includes(s)`.
    /// Native FilterEngine.string `.inList`: `c.values.map(norm).contains(ns)`.
    func testGenreInListIsAnyOf() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        // funk (alb_3: sng_6, sng_7) OR electronic (alb_1: sng_1, sng_2, sng_3).
        b.clauses = [Clause(field: "genre", op: .inList, values: ["funk", "electronic"])]
        XCTAssertEqual(Set(b.results(app).map(\.idString)),
                       ["sng_1", "sng_2", "sng_3", "sng_6", "sng_7"])
    }

    /// not-in-list for genre maps to op `.neq` (single value) — the PWA genre field's
    /// op set is eq/neq/in only. PWA `case 'neq': s !== norm(value)` => keeps songs
    /// whose genre is OTHER than the value (here: everything not "electronic"). It also
    /// keeps songs with NO/empty genre (norm('') !== 'electronic' is true).
    func testGenreNotInListKeepsOtherAndUngenredSongs() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        b.clauses = [Clause(field: "genre", op: .neq, value: "electronic")]
        // alb_1 = electronic (sng_1..3) dropped; jazz + funk songs kept.
        XCTAssertEqual(Set(b.results(app).map(\.idString)),
                       ["sng_4", "sng_5", "sng_6", "sng_7"])
    }

    /// not-in-list as a TRUE MULTI-SELECT none-of (`.notInList`): a song is kept only
    /// when its genre is NONE of the selected. Dropping BOTH electronic (sng_1..3) and
    /// funk (sng_6, sng_7) leaves only the jazz songs. Symmetric with HIDE membership.
    func testGenreNotInListMultiDropsAnyOfSelected() async {
        let app = await loadedApp()
        let b = BrowseState()
        b.kind = .song
        b.clauses = [Clause(field: "genre", op: .notInList, values: ["electronic", "funk"])]
        // jazz songs only: alb_2 (jazz) owns sng_4, sng_5.
        XCTAssertEqual(Set(b.results(app).map(\.idString)), ["sng_4", "sng_5"])
    }

    /// none-of (.notInList) keeps an ungenred song (norm('') not in the selected set) —
    /// same ungenred-kept behavior as single-value `.neq`.
    func testGenreNotInListKeepsUngenredSong() {
        let orphan = IndexSong.minimal(id: "sng_x", name: "Orphan", artist: "X")
        let item = BrowseItem.song(orphan, albumName: "", source: nil, genre: nil)
        var clause = Clause(field: "genre", op: .notInList); clause.values = ["funk", "electronic"]
        XCTAssertTrue(FilterEngine.matches(item, clause))
    }

    /// none-of (.notInList) drops a song whose genre IS one of the selected values.
    func testGenreNotInListDropsSelectedGenreSong() {
        let funkSong = IndexSong.minimal(id: "sng_y", name: "Groove", artist: "Y")
        let item = BrowseItem.song(funkSong, albumName: "", source: nil, genre: "funk")
        var clause = Clause(field: "genre", op: .notInList); clause.values = ["funk", "electronic"]
        XCTAssertFalse(FilterEngine.matches(item, clause))
    }

    /// neq keeps a song whose genre is empty/none (PWA norm(undefined)='' !== value).
    func testGenreNeqKeepsUngenredSong() {
        // A song with NO resolvable genre (genre nil) must survive a neq genre filter.
        let orphan = IndexSong.minimal(id: "sng_x", name: "Orphan", artist: "X")
        let item = BrowseItem.song(orphan, albumName: "", source: nil, genre: nil)
        let clause = Clause(field: "genre", op: .neq, value: "electronic")
        XCTAssertTrue(FilterEngine.matches(item, clause))
    }

    /// in-list (any-of) keeps a song matching one selected genre but drops an ungenred
    /// song — PWA `case 'in': values.includes(s)`, norm('') not in the value list.
    func testGenreInListDropsUngenredSong() {
        let orphan = IndexSong.minimal(id: "sng_x", name: "Orphan", artist: "X")
        let item = BrowseItem.song(orphan, albumName: "", source: nil, genre: nil)
        var clause = Clause(field: "genre", op: .inList); clause.values = ["funk", "jazz"]
        XCTAssertFalse(FilterEngine.matches(item, clause))
    }

    /// Pocket membership with MULTI-SELECT is ANY-of: a song in EITHER selected pocket
    /// is kept (PWA membersOf(union) -> isMember). Mirrors BrowserView SHOW over a subset.
    func testMembershipShowMultiPocketIsAnyOf() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pkA = s.createPocket("A")
        s.addSong("sng_1", toPocket: pkA.id)
        let pkB = s.createPocket("B")
        s.addSong("sng_5", toPocket: pkB.id)

        let b = BrowseState()
        b.kind = .song
        b.includeIds = [pkA.id, pkB.id]   // ANY-of across the two pockets
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.idString)), ["sng_1", "sng_5"])
    }

    // MARK: Collection membership (song mode) — mirrors PWA SHOW/HIDE predicates

    func testMembershipShowKeepsOnlyMembers() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addSong("sng_4", toPlaylist: pl.id)

        let b = BrowseState()
        b.kind = .song
        b.includeIds = [pl.id]
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.idString)), ["sng_1", "sng_4"])
    }

    func testMembershipHideDropsMembers() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set")
        s.addAlbum("alb_1", toPlaylist: pl.id)   // sng_1, sng_2, sng_3

        let b = BrowseState()
        b.kind = .song
        b.excludeIds = [pl.id]
        // All 7 songs minus alb_1's three tracks.
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.idString)),
                       ["sng_4", "sng_5", "sng_6", "sng_7"])
    }

    func testMembershipShowAndHideIntersect() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let show = s.createPlaylist("Show")
        s.addAlbum("alb_1", toPlaylist: show.id)  // sng_1, sng_2, sng_3
        let hide = s.createPlaylist("Hide")
        s.addSong("sng_2", toPlaylist: hide.id)

        let b = BrowseState()
        b.kind = .song
        b.includeIds = [show.id]
        b.excludeIds = [hide.id]
        // show ∩ ¬hide = {sng_1, sng_3}
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.idString)), ["sng_1", "sng_3"])
    }

    func testMembershipAnyShowExpandsToAllCollections() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set")
        s.addSong("sng_7", toPlaylist: pl.id)
        let pk = s.createPocket("Pkt")
        s.addSong("sng_5", toPocket: pk.id)

        let b = BrowseState()
        b.kind = .song
        b.includeAny = true     // every playlist + pocket
        XCTAssertEqual(Set(b.results(app, collections: s).map(\.idString)), ["sng_5", "sng_7"])
    }

    func testMembershipNotAppliedInAlbumMode() async {
        let app = await loadedApp()
        let s = wiredStore(app)
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)

        let b = BrowseState()
        b.kind = .album         // membership is song-mode only
        b.includeIds = [pl.id]
        XCTAssertEqual(b.results(app, collections: s).count, 3)  // all albums unaffected
    }

    func testMembershipNotPersisted() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let b = BrowseState(defaults: defaults)
        b.includeAny = true
        b.excludeIds = ["pls_x"]
        b.persist()
        let restored = BrowseState(defaults: defaults)
        XCTAssertFalse(restored.includeAny)   // transient, like the PWA's useState
        XCTAssertTrue(restored.excludeIds.isEmpty)
    }

    // MARK: Hide skips (History mode) — transient, signature-driving, Clear-All-owned

    private func historyState(defaults: UserDefaults? = nil) -> BrowseState {
        BrowseState(defaults: defaults ?? UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                    persistenceKey: "pdj.history.test", historyMode: true)
    }

    func testHideSkipsCountsAsActiveFilterOnlyInHistoryMode() {
        let h = historyState()
        XCTAssertEqual(h.activeFilterCount, 0)
        h.hideSkips = true
        XCTAssertEqual(h.activeFilterCount, 1)   // lights the toolbar's filled filter glyph

        // Unreachable from the Browser UI, but even if set it must never light Browse's glyph.
        let b = BrowseState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        b.kind = .song
        b.hideSkips = true
        XCTAssertEqual(b.activeFilterCount, 0)
    }

    func testHideSkipsChangesFilterSortSignature() {
        let h = historyState()
        let before = h.filterSortSignature()
        h.hideSkips = true
        XCTAssertNotEqual(h.filterSortSignature(), before)   // the .task(id:) recompute driver
        h.hideSkips = false
        XCTAssertEqual(h.filterSortSignature(), before)
    }

    func testClearAllFiltersResetsHideSkips() {
        let h = historyState()
        h.hideSkips = true
        h.clauses = [Clause(field: "explicit", op: .eq, value: "true")]
        h.clearAllFilters()
        XCTAssertTrue(h.clauses.isEmpty)
        XCTAssertFalse(h.hideSkips)
    }

    func testHideSkipsNotPersistedAcrossSnapshotRestore() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let h = historyState(defaults: defaults)
        h.hideSkips = true
        h.persist()
        let restored = BrowseState(defaults: defaults, persistenceKey: "pdj.history.test",
                                   historyMode: true)
        XCTAssertFalse(restored.hideSkips)   // transient, like membership + favorite
    }
}
