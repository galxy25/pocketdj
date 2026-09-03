import XCTest
@testable import PocketDJ

/// Tests for `CollectionsStore.songIds(forPlaylist/forPocket/forSetlist/forSource)` —
/// the pure, deduped resolvers that feed the batch RIP / BURN queue (Feature 2). Each
/// collection type resolves differently; all expand albums/pockets, dedupe, and EXCLUDE
/// text/note cues. They run against the shared TestData catalog wired into an AppModel.
///
///   alb_1 = sng_1, sng_2, sng_3   alb_2 = sng_4, sng_5   alb_3 = sng_6, sng_7
@MainActor
final class CollectionsResolverTests: XCTestCase {

    /// `CollectionsStore.app` is a WEAK ref, so the AppModel must be retained by the test
    /// for the store's lifetime — we stash it here and clear it on teardown.
    private var heldApp: AppModel?

    override func tearDown() { heldApp = nil; super.tearDown() }

    private func wiredStore() async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-resolver-\(UUID().uuidString).json"))
        s.app = app
        return s
    }

    // MARK: Playlist resolver (album expand · text excluded)
    //
    // The playlist path preserves PLAY ORDER: an album node expands to its tracks and
    // text/note nodes are excluded, but a song that appears both standalone AND inside an
    // album is NOT de-duplicated (only pocket cycles are guarded, per CollectionCatalog).

    func testSongIdsForPlaylistExpandsAlbumsAndExcludesText() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_4", toPlaylist: pl.id)
        s.addAlbum("alb_1", toPlaylist: pl.id)    // sng_1, sng_2, sng_3
        s.addText("mic break", toPlaylist: pl.id)  // excluded — no text cue leaks in
        s.addSong("sng_5", toPlaylist: pl.id)

        let ids = s.songIds(forPlaylist: pl.id)
        XCTAssertEqual(ids, ["sng_4", "sng_1", "sng_2", "sng_3", "sng_5"])  // play order, album expanded
        XCTAssertFalse(ids.contains(""), "no text/note cue leaks in")
    }

    func testSongIdsForPlaylistKeepsPlayOrderDuplicates() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addAlbum("alb_1", toPlaylist: pl.id)    // sng_1 (again), sng_2, sng_3
        let ids = s.songIds(forPlaylist: pl.id)
        XCTAssertEqual(ids, ["sng_1", "sng_1", "sng_2", "sng_3"],
                       "playlist resolver does NOT song-dedupe — sng_1 appears twice")
    }

    func testSongIdsForPlaylistMissingIsEmpty() async {
        let s = await wiredStore()
        XCTAssertEqual(s.songIds(forPlaylist: "nope"), [])
    }

    // MARK: Pocket resolver (own songs + album tracks + nested · cycle-guarded · dedupe)

    func testSongIdsForPocketResolvesDAGDeduped() async {
        let s = await wiredStore()
        let pkt = s.createPocket("Soul")
        s.addSong("sng_4", toPocket: pkt.id)
        s.addAlbum("alb_1", toPocket: pkt.id)    // sng_1, sng_2, sng_3
        s.addSong("sng_1", toPocket: pkt.id)     // dup of an album track → no-op anyway

        let ids = s.songIds(forPocket: pkt.id)
        XCTAssertEqual(Set(ids), ["sng_1", "sng_2", "sng_3", "sng_4"])
        XCTAssertEqual(ids.count, 4)
    }

    func testSongIdsForPocketNestedCycleGuarded() async {
        let s = await wiredStore()
        let a = s.createPocket("A"); let b = s.createPocket("B")
        s.addSong("sng_1", toPocket: a.id)
        s.addSong("sng_2", toPocket: b.id)
        s.addChildPocket(b.id, toPocket: a.id)
        // Manufacture a cycle in the persisted graph is blocked by addChildPocket, so the
        // guard is exercised via the nested resolve terminating + deduping.
        let ids = s.songIds(forPocket: a.id)
        XCTAssertEqual(Set(ids), ["sng_1", "sng_2"])
    }

    /// Two multi-song pockets sharing one track resolve to the UNION of their rip ids (the
    /// mix downloader's cross-crate dedupe) — sum minus the shared song. Guards the resolve +
    /// union math the field "two crates → total=1" turned out NOT to be about (that was a
    /// partial catalog dropping members before this point).
    func testTwoMultiSongPocketsUnionToSumMinusDupes() async {
        let s = await wiredStore()
        let sap = s.createPocket("sap", songIds: ["sng_1", "sng_2", "sng_3"])   // alb_1 members
        let joy = s.createPocket("joy", songIds: ["sng_3", "sng_4", "sng_5"])   // sng_3 shared
        XCTAssertEqual(s.ripIds(forPocket: sap.id).count, 3)
        XCTAssertEqual(s.ripIds(forPocket: joy.id).count, 3)
        let union = Set(s.ripIds(forPocket: sap.id) + s.ripIds(forPocket: joy.id))
        XCTAssertEqual(union.count, 5, "3 + 3 minus the one shared song = 5, not 1")
    }

    /// `declaredMemberCount` is catalog-INDEPENDENT (the diagnostic that separates an empty
    /// crate from a partial catalog): it counts declared members even for ids the catalog
    /// doesn't know, so it stays honest when a device's catalog is incomplete.
    func testDeclaredMemberCountIsCatalogIndependent() async {
        let s = await wiredStore()
        // Two known + one id absent from the fixture catalog: resolve drops the unknown, but
        // the DECLARED count still sees all three.
        let p = s.createPocket("sap", songIds: ["sng_1", "sng_2", "not_in_catalog"])
        XCTAssertEqual(s.ripIds(forPocket: p.id).count, 2, "catalog resolve drops the unknown id")
        XCTAssertEqual(s.declaredMemberCount(for: .pocket(p.id)), 3,
                       "declared count is the pre-catalog member total — names the partial-catalog gap")
        XCTAssertEqual(s.declaredMemberCount(for: .pocket("nope")), 0)
    }

    func testSongIdsForPocketMissingIsEmpty() async {
        let s = await wiredStore()
        XCTAssertEqual(s.songIds(forPocket: "nope"), [])
    }

    // MARK: Setlist resolver (text cues excluded · empty-id dropped)

    func testSongIdsForSetlistExcludesTextCues() async {
        let s = await wiredStore()
        let sl = s.realize(songIds: ["sng_1", "sng_2"], name: "Live")!
        s.addSetlistNote("crowd hype", toSetlist: sl.id)   // isText cue with empty songId
        let ids = s.songIds(forSetlist: sl.id)
        XCTAssertEqual(Set(ids), ["sng_1", "sng_2"])
        XCTAssertFalse(ids.contains(""), "text cue's empty songId is dropped")
    }

    func testSongIdsForSetlistMissingIsEmpty() async {
        let s = await wiredStore()
        XCTAssertEqual(s.songIds(forSetlist: "nope"), [])
    }

    // MARK: Source resolver (a flat read-only list)

    func testSongIdsForSourceReturnsFlatList() async {
        let s = await wiredStore()
        let src = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_1", name: "001", songIds: ["sng_1", "sng_2", "sng_3"]),
            sourceName: "Apple Music (Local)")
        XCTAssertEqual(s.songIds(forSource: src), ["sng_1", "sng_2", "sng_3"])
    }

    // MARK: burnTuples — drops ids with no catalog song; names the rest

    func testBurnTuplesNamesKnownSongsAndDropsUnknown() async {
        let s = await wiredStore()
        let tuples = s.burnTuples(["sng_1", "ghost", "sng_4"])
        XCTAssertEqual(tuples.map(\.id), ["sng_1", "sng_4"])   // unknown id dropped
        XCTAssertEqual(tuples.first?.title, "Neon")
        XCTAssertEqual(tuples.first?.artist, "Aria")
    }
}
