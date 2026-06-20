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
