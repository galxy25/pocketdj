import XCTest
@testable import PocketDJ

final class CollectionsSchemaTests: XCTestCase {
    func testRoundTrip() throws {
        var doc = CollectionsDocument()
        doc.pockets = [Pocket(id: "pkt_1", name: "Soul", songIds: ["sng_1"])]
        doc.playlists = [CollectionsFactory.makePlaylist("Set", now: 0)]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.schemaVersion, collectionsSchemaVersion)
        XCTAssertEqual(back.pockets.first?.name, "Soul")
        XCTAssertEqual(back.playlists.first?.sequences.first?.kind, .sequence)
    }
    func testMissingVersionMigrates() throws {
        let doc = try CollectionsCodec.decode(Data(#"{ "pockets": [], "playlists": [] }"#.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)
    }
    func testUnknownFieldsAndMissingListsDegrade() throws {
        let doc = try CollectionsCodec.decode(Data(#"{ "schemaVersion": 1, "future": true }"#.utf8))
        XCTAssertTrue(doc.pockets.isEmpty)
        XCTAssertTrue(doc.playlists.isEmpty)
    }
}

@MainActor
final class CollectionsStoreTests: XCTestCase {
    private func store() -> CollectionsStore {
        CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-\(UUID().uuidString).json"))
    }

    func testPocketCRUDAndDedup() {
        let s = store()
        let p = s.createPocket("Soul")
        s.addSong("sng_1", toPocket: p.id)
        s.addSong("sng_1", toPocket: p.id)        // dedup
        s.addAlbum("alb_1", toPocket: p.id)
        XCTAssertEqual(s.pocket(p.id)?.songIds, ["sng_1"])
        XCTAssertEqual(s.pocket(p.id)?.albumIds, ["alb_1"])
        s.removeSong("sng_1", fromPocket: p.id)
        XCTAssertTrue(s.pocket(p.id)?.songIds.isEmpty ?? false)
        s.renamePocket(p.id, "Funk")
        XCTAssertEqual(s.pocket(p.id)?.name, "Funk")
    }

    func testNestingIsCycleGuarded() {
        let s = store()
        let a = s.createPocket("A"), b = s.createPocket("B")
        XCTAssertTrue(s.addChildPocket(b.id, toPocket: a.id))     // A → B ok
        XCTAssertFalse(s.addChildPocket(a.id, toPocket: b.id))    // B → A would cycle
        XCTAssertFalse(s.addChildPocket(a.id, toPocket: a.id))    // self-nest
        XCTAssertEqual(s.pocket(a.id)?.childPocketIds, [b.id])
        XCTAssertEqual(s.pocket(b.id)?.childPocketIds, [])
    }

    func testDeletePocketCleansParentRefs() {
        let s = store()
        let a = s.createPocket("A"), b = s.createPocket("B")
        s.addChildPocket(b.id, toPocket: a.id)
        s.deletePocket(b.id)
        XCTAssertNil(s.pocket(b.id))
        XCTAssertEqual(s.pocket(a.id)?.childPocketIds, [])        // dangling ref removed
    }

    func testPlaylistDefaultSequenceAndAdds() {
        let s = store()
        let pl = s.createPlaylist("BBQ")
        XCTAssertEqual(pl.sequences.count, 1)                     // default sequence present
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addText("mic break", toPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)?.sequences.first?.children?.count, 2)
        s.addSequence("Encore", toPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)?.sequences.count, 2)
        let nodeId = s.playlist(pl.id)!.sequences.first!.children!.first!.nodeId
        s.removeNode(nodeId, fromPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)?.sequences.first?.children?.count, 1)
    }

    func testRemembersLastAddTargetWithChapter() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let seqId = pl.sequences.first!.nodeId
        let target = AddTarget(kind: .playlist, id: pl.id, sequenceId: seqId)
        s.addSong("sng_1", to: target)
        XCTAssertEqual(s.lastAddTarget, target)
        XCTAssertEqual(s.lastTargetLabel(target), "Set › Default")
        // repeat-add via the remembered target lands in the same chapter
        s.addSong("sng_2", to: s.lastAddTarget!)
        XCTAssertEqual(s.playlist(pl.id)?.sequences.first?.children?.count, 2)
    }

    func testLastAddTargetPersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-last-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let p = s1.createPocket("Soul")
        s1.addSong("sng_1", to: AddTarget(kind: .pocket, id: p.id))
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.lastAddTarget?.kind, .pocket)
        XCTAssertEqual(s2.lastAddTarget?.id, p.id)
    }

    func testMoveNodeReordersWithinChapter() {
        let s = store()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addSong("sng_2", toPlaylist: pl.id)
        s.addSong("sng_3", toPlaylist: pl.id)
        let ids = s.playlist(pl.id)!.sequences[0].children!.map(\.nodeId)
        // Move the last node up one.
        s.moveNodeUp(ids[2], inPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)!.sequences[0].children!.map(\.nodeId), [ids[0], ids[2], ids[1]])
        // Move the first node down one.
        s.moveNodeDown(ids[0], inPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)!.sequences[0].children!.map(\.nodeId), [ids[2], ids[0], ids[1]])
        // Up at the top is a no-op.
        s.moveNodeUp(ids[2], inPlaylist: pl.id)
        XCTAssertEqual(s.playlist(pl.id)!.sequences[0].children!.first?.nodeId, ids[2])
    }

    func testCreatePlaylistFromSongIds() {
        let s = store()
        let pl = s.createPlaylist("From Apple", songIds: ["sng_1", "sng_2"])
        XCTAssertEqual(s.playlist(pl.id)?.sequences.first?.children?.compactMap(\.songId), ["sng_1", "sng_2"])
    }

    func testExportImportPlaylistMintsFreshIds() throws {
        let s = store()
        let pl = s.createPlaylist("Set", songIds: ["sng_1", "sng_2"])
        let data = try XCTUnwrap(s.exportPlaylist(pl.id))
        try s.importCollection(data: data)   // import back into the SAME store
        XCTAssertEqual(s.playlists.count, 2)
        let imported = s.playlists.last!
        XCTAssertNotEqual(imported.id, pl.id)                    // fresh playlist id
        let origNodeIds = Set(pl.sequences.flatMap { $0.children ?? [] }.map(\.nodeId))
        let newNodeIds = Set(imported.sequences.flatMap { $0.children ?? [] }.map(\.nodeId))
        XCTAssertTrue(origNodeIds.isDisjoint(with: newNodeIds))  // fresh node ids
        XCTAssertEqual(imported.sequences.first?.children?.compactMap(\.songId), ["sng_1", "sng_2"])
    }

    func testExportImportPocketRemapsChildRefs() throws {
        let s = store()
        let a = s.createPocket("A"); let b = s.createPocket("B")
        s.addChildPocket(b.id, toPocket: a.id)
        s.addSong("sng_1", toPocket: a.id)
        // Export the parent only → its child ref points outside the import, so it's dropped.
        let parentOnly = try XCTUnwrap(s.exportPocket(a.id))
        try s.importCollection(data: parentOnly)
        let importedA = s.pockets.last!
        XCTAssertNotEqual(importedA.id, a.id)
        XCTAssertEqual(importedA.songIds, ["sng_1"])
        XCTAssertTrue(importedA.childPocketIds.isEmpty)          // ref to non-imported B dropped
    }

    func testRealizeFromSongIdsBuildsSetlist() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store()
        s.app = app
        let sl = s.realize(songIds: ["sng_1", "sng_2"], name: "Apple Mix")
        XCTAssertNotNil(sl)
        XCTAssertEqual(sl?.name, "Apple Mix")
        XCTAssertTrue((sl?.tracks.count ?? 0) >= 2)                    // both explicit songs present
        XCTAssertEqual(s.setlists.count, 1)                           // persisted into history
        XCTAssertTrue(sl!.tracks.contains { $0.songId == "sng_1" })
    }

    func testPersistenceReloads() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-persist-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let p = s1.createPocket("Soul"); s1.addSong("sng_1", toPocket: p.id)
        _ = s1.createPlaylist("Set")
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.pockets.first?.name, "Soul")
        XCTAssertEqual(s2.pockets.first?.songIds, ["sng_1"])
        XCTAssertEqual(s2.playlists.first?.name, "Set")
    }
}
