import XCTest
@testable import PocketDJ

/// Items 1/2/6 — the reusable "Now Playing" setlist (playNow order/shuffle/reuse) and
/// playlist FOLDERS (create/rename/delete-keeps-playlists/move + migration round-trip).
@MainActor
final class NowPlayingFoldersTests: XCTestCase {
    /// Strongly held for the test's lifetime: CollectionsStore.app is `weak`, so a local
    /// AppModel that goes out of scope would deallocate and silently un-wire the catalog.
    private var heldApp: AppModel?

    private func store() -> CollectionsStore {
        CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-np-\(UUID().uuidString).json"))
    }
    private func wiredStore() async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = store(); s.app = app
        return s
    }

    // MARK: playNow — literal order, no autofill/dedup-surprise

    func testPlayNowKeepsLiteralOrderAndDropsUnknownIds() async {
        let s = await wiredStore()
        // Deliberately out of catalog order + an unresolvable id in the middle.
        let sl = s.playNow(songIds: ["sng_3", "nope", "sng_1"], name: "NP")
        XCTAssertNotNil(sl)
        // Literal order preserved (3 then 1); the unknown id is dropped, NOT autofilled.
        XCTAssertEqual(sl?.tracks.map(\.songId), ["sng_3", "sng_1"])
        XCTAssertTrue(sl!.tracks.allSatisfy { $0.source == .explicit })
        XCTAssertEqual(sl?.id, nowPlayingSetlistId)
        XCTAssertEqual(sl?.playlistId, nowPlayingPlaylistId)
    }

    func testPlayNowShufflePermutesSameSet() async {
        let s = await wiredStore()
        let ids = ["sng_1", "sng_2", "sng_3", "sng_4", "sng_5", "sng_6", "sng_7"]
        let sl = s.playNow(songIds: ids, shuffle: true)
        // Same MULTISET of resolved songs, just (very likely) re-ordered.
        XCTAssertEqual(Set(sl!.tracks.map(\.songId)), Set(ids))
        XCTAssertEqual(sl!.tracks.count, ids.count)
    }

    func testPlayNowReusesAndReplacesReservedSetlist() async {
        let s = await wiredStore()
        let r0 = s.nowPlayingRevision
        _ = s.playNow(songIds: ["sng_1", "sng_2"], name: "First")
        XCTAssertEqual(s.setlists.filter { $0.id == nowPlayingSetlistId }.count, 1)
        XCTAssertEqual(s.nowPlayingRevision, r0 + 1)        // monotonic bump
        _ = s.playNow(songIds: ["sng_3"], name: "Second")
        // STILL exactly one reserved setlist (replaced in place, last-writer-wins).
        XCTAssertEqual(s.setlists.filter { $0.id == nowPlayingSetlistId }.count, 1)
        XCTAssertEqual(s.nowPlayingSetlist()?.tracks.map(\.songId), ["sng_3"])
        XCTAssertEqual(s.nowPlayingSetlist()?.name, "Second")
        XCTAssertEqual(s.nowPlayingRevision, r0 + 2)        // bumped again, never collides
    }

    func testNowPlayingHiddenFromHistoryAndClearedOnReload() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-np-life-\(UUID().uuidString).json")
        let app = AppModel(loader: TestData.StubLoader()); await app.loadIfNeeded()
        let s1 = CollectionsStore(fileURL: url); s1.app = app
        _ = s1.playNow(songIds: ["sng_1"], name: "NP")
        // Never surfaced as a member of its synthetic parent (or any list helper).
        XCTAssertTrue(s1.setlists(forPlaylist: nowPlayingPlaylistId).isEmpty)
        // Reload: the stale reserved setlist is dropped on launch.
        let s2 = CollectionsStore(fileURL: url); s2.app = app
        XCTAssertNil(s2.nowPlayingSetlist())
        XCTAssertFalse(s2.setlists.contains { $0.id == nowPlayingSetlistId })
    }

    func testPlayNowFromPlaylistResolvesOrderedIds() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set", songIds: ["sng_2", "sng_1"])
        let sl = s.playNow(playlistId: pl.id)
        XCTAssertEqual(sl?.tracks.map(\.songId), ["sng_2", "sng_1"])
        XCTAssertEqual(sl?.name, "Set")
    }

    func testPlayNowFromPocketResolvesDagOrder() async {
        let s = await wiredStore()
        let p = s.createPocket("P")
        s.addSong("sng_5", toPocket: p.id)
        s.addSong("sng_4", toPocket: p.id)
        let sl = s.playNow(pocketId: p.id)
        XCTAssertEqual(sl?.tracks.map(\.songId), ["sng_5", "sng_4"])
    }

    // MARK: Folders — CRUD + membership

    func testFolderCreateRenameMove() {
        let s = store()
        let pl = s.createPlaylist("Mix")
        let f = s.createFolder("Parties")
        XCTAssertEqual(s.foldersOrdered().map(\.name), ["Parties"])
        s.setPlaylistFolder(pl.id, folderId: f.id)
        XCTAssertEqual(s.playlists(inFolder: f.id).map(\.id), [pl.id])
        XCTAssertTrue(s.playlists(inFolder: nil).isEmpty)        // moved out of top level
        s.renameFolder(f.id, "Events")
        XCTAssertEqual(s.folder(f.id)?.name, "Events")
        s.setPlaylistFolder(pl.id, folderId: nil)               // back to top level
        XCTAssertEqual(s.playlists(inFolder: nil).map(\.id), [pl.id])
    }

    func testDeleteFolderKeepsPlaylistsAtTopLevel() {
        let s = store()
        let pl = s.createPlaylist("Mix")
        let f = s.createFolder("F")
        s.setPlaylistFolder(pl.id, folderId: f.id)
        s.deleteFolder(f.id)
        XCTAssertNil(s.folder(f.id))
        XCTAssertNotNil(s.playlist(pl.id))                      // playlist survives
        XCTAssertNil(s.playlist(pl.id)?.folderId)               // fell back to top level
        XCTAssertEqual(s.playlists(inFolder: nil).map(\.id), [pl.id])
    }

    func testFoldersOrderedByName() {
        let s = store()
        _ = s.createFolder("Zeta")
        _ = s.createFolder("alpha")
        _ = s.createFolder("Mango")
        XCTAssertEqual(s.foldersOrdered().map(\.name), ["alpha", "Mango", "Zeta"])
    }

    func testFoldersPersistAndMigrationRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-fld-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let pl = s1.createPlaylist("Mix")
        let f = s1.createFolder("F")
        s1.setPlaylistFolder(pl.id, folderId: f.id)
        // Reloads with folder + membership intact.
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.folder(f.id)?.name, "F")
        XCTAssertEqual(s2.playlist(pl.id)?.folderId, f.id)
    }

    // A v2 doc (no folders / folderId) migrates forward to v3 with empty folders + nil
    // folderId (top level) — never crashes, members intact.
    func testV2DocMigratesToV3Folders() throws {
        let v2 = """
        { "schemaVersion": 2, "pockets": [],
          "playlists": [ { "id": "pls_x", "name": "Old", "sequences": [], "createdAt": 0, "updatedAt": 0 } ] }
        """
        let doc = try CollectionsCodec.decode(Data(v2.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)   // bumped to 3
        XCTAssertTrue(doc.folders.isEmpty)
        XCTAssertNil(doc.playlists.first?.folderId)                   // top level
        XCTAssertEqual(doc.playlists.first?.name, "Old")
    }

    // A v3 doc carrying folders + folderId survives a full round-trip.
    func testV3FoldersRoundTrip() throws {
        var doc = CollectionsDocument()
        doc.folders = [PlaylistFolder(id: "fld_1", name: "Parties")]
        var pl = CollectionsFactory.makePlaylist("Mix", now: 0)
        pl.folderId = "fld_1"
        doc.playlists = [pl]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.folders.map(\.name), ["Parties"])
        XCTAssertEqual(back.playlists.first?.folderId, "fld_1")
    }

    // MARK: Pocket folders (v4)

    // A v3 doc (pocket with no folderId key) migrates forward to v4 with folderId == nil
    // (top level) — members intact, never crashes.
    func testV3PocketMigratesToV4WithNilFolderId() throws {
        let v3 = """
        { "schemaVersion": 3, "pockets": [
            { "id": "pkt_x", "name": "Soul", "songIds": ["sng_1"], "createdAt": 0, "updatedAt": 0 }
        ], "playlists": [] }
        """
        let doc = try CollectionsCodec.decode(Data(v3.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)   // bumped to 4
        XCTAssertNil(doc.pockets.first?.folderId)                     // top level
        XCTAssertEqual(doc.pockets.first?.songIds, ["sng_1"])          // members intact
    }

    // A v4 pocket carrying folderId survives a full round-trip.
    func testV4PocketFolderIdRoundTrip() throws {
        var doc = CollectionsDocument()
        doc.folders = [PlaylistFolder(id: "fld_1", name: "Sets")]
        doc.pockets = [Pocket(id: "pkt_1", name: "Soul", folderId: "fld_1")]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.pockets.first?.folderId, "fld_1")
        XCTAssertEqual(back.pockets.first?.name, "Soul")
    }

    func testPocketsInFolderFiltersAndOrders() {
        let s = store()
        let f = s.createFolder("Warmups")
        let pk1 = s.createPocket("Bass")
        let pk2 = s.createPocket("Ambient")
        let pk3 = s.createPocket("Solo")     // stays top-level
        s.setPocketFolder(pk1.id, folderId: f.id)
        s.setPocketFolder(pk2.id, folderId: f.id)
        // Folder members are name-ordered (case-insensitive).
        XCTAssertEqual(s.pockets(inFolder: f.id).map(\.name), ["Ambient", "Bass"])
        // Top level contains only Solo.
        XCTAssertEqual(s.pockets(inFolder: nil).map(\.id), [pk3.id])
    }

    func testSetPocketFolderMovesAndPersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-pkfld-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let f = s1.createFolder("F")
        let pk = s1.createPocket("Groove")
        XCTAssertNil(s1.pocket(pk.id)?.folderId)          // starts top-level
        s1.setPocketFolder(pk.id, folderId: f.id)
        XCTAssertEqual(s1.pocket(pk.id)?.folderId, f.id)
        // Reloads from disk with folderId intact.
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.pocket(pk.id)?.folderId, f.id)
        // Move back to top level.
        s2.setPocketFolder(pk.id, folderId: nil)
        XCTAssertNil(s2.pocket(pk.id)?.folderId)
    }

    func testDeleteFolderResetsPocketFolderIds() {
        let s = store()
        let pl = s.createPlaylist("Mix")
        let pk = s.createPocket("Soul")
        let f = s.createFolder("F")
        s.setPlaylistFolder(pl.id, folderId: f.id)
        s.setPocketFolder(pk.id, folderId: f.id)
        s.deleteFolder(f.id)
        XCTAssertNil(s.folder(f.id))
        // Both the playlist AND the pocket fall back to top level.
        XCTAssertNil(s.playlist(pl.id)?.folderId)
        XCTAssertNil(s.pocket(pk.id)?.folderId)
        XCTAssertEqual(s.playlists(inFolder: nil).map(\.id), [pl.id])
        XCTAssertEqual(s.pockets(inFolder: nil).map(\.id), [pk.id])
    }

    // A full-doc import carrying a pocket with a folderId re-points the pocket at the
    // reminted folder (not the old id), mirroring the existing playlist behavior.
    func testFullDocImportRemapsPocketFolderRef() throws {
        let s = store()
        let doc = """
        { "schemaVersion": 4,
          "folders": [ { "id": "fld_a", "name": "F" } ],
          "pockets": [ { "id": "pkt_a", "name": "Soul", "folderId": "fld_a", "createdAt": 0, "updatedAt": 0 } ],
          "playlists": [] }
        """
        try s.importCollection(data: Data(doc.utf8))
        XCTAssertEqual(s.folders.count, 1)
        let f = s.folders.last!
        XCTAssertNotEqual(f.id, "fld_a")                   // fresh folder id
        let pk = s.pockets.last!
        XCTAssertNotEqual(pk.id, "pkt_a")                  // fresh pocket id
        XCTAssertEqual(pk.folderId, f.id)                  // re-pointed to the reminted folder
    }

    // A pocket imported WITHOUT its folder drops the dangling ref (lands at top level).
    func testImportPocketWithoutFolderDropsDanglingRef() throws {
        let s = store()
        let doc = """
        { "schemaVersion": 4,
          "pockets": [ { "id": "pkt_a", "name": "Soul", "folderId": "fld_missing", "createdAt": 0, "updatedAt": 0 } ],
          "playlists": [] }
        """
        try s.importCollection(data: Data(doc.utf8))
        XCTAssertEqual(s.pockets.count, 1)
        XCTAssertNil(s.pockets.last?.folderId)             // dangling folder ref dropped
    }

    // CRITIC-G: a full-doc import (collections JSON) carries folders + remaps ids so a
    // playlist stays grouped (not silently flattened).
    func testFullDocImportCarriesFoldersWithRemap() throws {
        let s = store()
        let doc = """
        { "schemaVersion": 3,
          "folders": [ { "id": "fld_a", "name": "Parties" } ],
          "playlists": [ { "id": "pls_a", "name": "Mix", "folderId": "fld_a", "sequences": [], "createdAt": 0, "updatedAt": 0 } ] }
        """
        try s.importCollection(data: Data(doc.utf8))
        XCTAssertEqual(s.folders.count, 1)
        let f = s.folders.last!
        XCTAssertNotEqual(f.id, "fld_a")                       // fresh folder id
        let pl = s.playlists.last!
        XCTAssertNotEqual(pl.id, "pls_a")                      // fresh playlist id
        XCTAssertEqual(pl.folderId, f.id)                      // re-pointed to the reminted folder
    }

    // A playlist imported WITHOUT its folder (single-item export) drops the dangling ref
    // (lands at top level) rather than pointing at a non-existent folder.
    func testImportPlaylistWithoutFolderDropsDanglingRef() throws {
        let s = store()
        let doc = """
        { "schemaVersion": 3,
          "playlists": [ { "id": "pls_a", "name": "Mix", "folderId": "fld_missing", "sequences": [], "createdAt": 0, "updatedAt": 0 } ] }
        """
        try s.importCollection(data: Data(doc.utf8))
        XCTAssertEqual(s.playlists.count, 1)                   // playlist imported
        XCTAssertNil(s.playlists.last?.folderId)               // dangling folder ref dropped
    }
}
