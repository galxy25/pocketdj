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

    // v1 → v2: pockets gained `notes`. An old (v1) pocket with NO notes key must
    // migrate forward to v2 with notes == [] (never nil/crash).
    func testV1PocketMigratesToV2WithEmptyNotes() throws {
        let v1 = """
        { "schemaVersion": 1, "pockets": [
            { "id": "pkt_old", "name": "Soul", "kind": "harmonic",
              "songIds": ["sng_1"], "albumIds": [], "childPocketIds": [],
              "createdAt": 0, "updatedAt": 0 }
        ], "playlists": [] }
        """
        let doc = try CollectionsCodec.decode(Data(v1.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)   // bumped to 2
        XCTAssertEqual(doc.pockets.first?.songIds, ["sng_1"])
        XCTAssertEqual(doc.pockets.first?.notes, [])                  // additive default
    }

    // A v2 pocket carrying notes survives a full round-trip with text + order intact.
    func testV2PocketNotesRoundTrip() throws {
        var doc = CollectionsDocument()
        doc.pockets = [Pocket(id: "pkt_1", name: "Poetry",
                              notes: [PocketNote(id: "pnt_1", text: "First", position: 0),
                                      PocketNote(id: "pnt_2", text: "Second", position: 1)])]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.pockets.first?.notes.map(\.text), ["First", "Second"])
        XCTAssertEqual(back.pockets.first?.notes.map(\.id), ["pnt_1", "pnt_2"])
    }

    // Lenient decode: a note with a missing id/position still decodes (id minted,
    // position defaults to 0); an entirely unknown extra key is ignored.
    func testPocketNoteLenientDecode() throws {
        let json = """
        { "schemaVersion": 2, "pockets": [
            { "id": "pkt_1", "name": "P",
              "notes": [ { "text": "bare" }, { "id": "pnt_x", "text": "ok", "position": 5, "future": true } ] }
        ] }
        """
        let doc = try CollectionsCodec.decode(Data(json.utf8))
        let notes = try XCTUnwrap(doc.pockets.first?.notes)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].text, "bare")
        XCTAssertFalse(notes[0].id.isEmpty)              // minted when missing
        XCTAssertEqual(notes[0].position, 0)             // defaulted
        XCTAssertEqual(notes[1].id, "pnt_x")
        XCTAssertEqual(notes[1].position, 5)
    }

    // A newer (v2) doc degrades gracefully when decoded — members survive even if a
    // hypothetical older app ignores `notes` (here we just confirm members intact when
    // notes is present, mirroring the lenient-decode contract).
    func testV2DocMembersSurviveAlongsideNotes() throws {
        let json = """
        { "schemaVersion": 2, "pockets": [
            { "id": "pkt_1", "name": "P", "songIds": ["sng_1","sng_2"], "albumIds": ["alb_1"],
              "notes": [ { "id": "pnt_1", "text": "line" } ] }
        ] }
        """
        let doc = try CollectionsCodec.decode(Data(json.utf8))
        XCTAssertEqual(doc.pockets.first?.songIds, ["sng_1","sng_2"])
        XCTAssertEqual(doc.pockets.first?.albumIds, ["alb_1"])
        XCTAssertEqual(doc.pockets.first?.notes.first?.text, "line")
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

    // MARK: Pocket notes (the "poetry pocket")

    func testPocketNoteAddEditReorderRemove() {
        let s = store()
        let p = s.createPocket("Poetry")
        let n1 = s.addNote("First line", toPocket: p.id)
        let n2 = s.addNote("Second line", toPocket: p.id)
        XCTAssertNotNil(n1); XCTAssertNotNil(n2)
        XCTAssertEqual(s.pocket(p.id)?.notes.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(s.pocket(p.id)?.notes.map(\.position), [0, 1])   // position assigned on add
        // Notes never count as members (so the poetry pocket has 0 songs).
        XCTAssertEqual(s.pocket(p.id)?.memberCount, 0)
        XCTAssertFalse(s.pocket(p.id)?.isEmpty ?? true)                 // but it isn't empty
        // Edit
        s.setNoteText(n1!.id, text: "Edited", inPocket: p.id)
        XCTAssertEqual(s.pocket(p.id)?.notes.first?.text, "Edited")
        // Reorder (swap the two)
        s.movePocketNotes(inPocket: p.id, from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(s.pocket(p.id)?.notes.map(\.text), ["Second line", "Edited"])
        // Remove
        s.removeNote(n2!.id, fromPocket: p.id)
        XCTAssertEqual(s.pocket(p.id)?.notes.map(\.text), ["Edited"])
    }

    func testPocketNotesPersistAndExportImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-pnote-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let p = s1.createPocket("Poetry")
        s1.addNote("A poem", toPocket: p.id)
        // Reloads from disk with notes intact.
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.pocket(p.id)?.notes.first?.text, "A poem")
        // Export → import (same store) keeps the notes on the reminted copy.
        let data = try XCTUnwrap(s2.exportPocket(p.id))
        try s2.importCollection(data: data)
        XCTAssertEqual(s2.pockets.last?.notes.first?.text, "A poem")
        XCTAssertNotEqual(s2.pockets.last?.id, p.id)                    // fresh pocket id
    }

    // MARK: Setlist track editing (remove / reorder / recompute totalMs) + add note

    func testSetlistRemoveReorderRecomputesTotal() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store(); s.app = app
        let sl = s.realize(songIds: ["sng_1", "sng_2"], name: "Edit Me")!   // 222000 + 201000
        XCTAssertEqual(s.setlist(sl.id)?.tracks.count, 2)
        XCTAssertEqual(s.setlist(sl.id)?.totalMs, 222000 + 201000)
        let order0 = s.setlist(sl.id)!.tracks.map(\.songId)
        // Reorder: move track 0 to the end.
        s.moveSetlistTracks(setlistId: sl.id, from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(s.setlist(sl.id)!.tracks.map(\.songId), [order0[1], order0[0]])
        XCTAssertEqual(s.setlist(sl.id)?.totalMs, 222000 + 201000)       // reorder leaves total
        // Remove one → total recomputed from the remaining track.
        let remaining = s.setlist(sl.id)!.tracks[1].songId
        s.removeSetlistTrack(setlistId: sl.id, at: 0)
        XCTAssertEqual(s.setlist(sl.id)?.tracks.count, 1)
        XCTAssertEqual(s.setlist(sl.id)?.tracks.first?.songId, remaining)
        let expected = remaining == "sng_1" ? 222000 : 201000
        XCTAssertEqual(s.setlist(sl.id)?.totalMs, expected)
        // Provenance preserved across edits.
        XCTAssertEqual(s.setlist(sl.id)?.name, "Edit Me")
        XCTAssertFalse(s.setlist(sl.id)!.seed.isEmpty)
    }

    func testSetlistAddNoteIsTextZeroDuration() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = store(); s.app = app
        let sl = s.realize(songIds: ["sng_1"], name: "With Note")!
        let before = s.setlist(sl.id)!.totalMs
        s.addSetlistNote("mic break", toSetlist: sl.id)
        let after = s.setlist(sl.id)!
        XCTAssertEqual(after.tracks.count, 2)
        XCTAssertEqual(after.tracks.last?.isText, true)
        XCTAssertEqual(after.tracks.last?.name, "mic break")
        XCTAssertTrue(after.tracks.last?.songId.isEmpty ?? false)
        XCTAssertEqual(after.totalMs, before)                            // note adds 0 ms
    }

    func testPlaylistAddTextNote() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let seqId = pl.sequences.first!.nodeId
        s.addText("intro spiel", toPlaylist: pl.id, sequenceId: seqId)
        let kids = s.playlist(pl.id)!.sequences.first!.children!
        XCTAssertEqual(kids.count, 1)
        XCTAssertEqual(kids.first?.kind, .text)
        XCTAssertEqual(kids.first?.text, "intro spiel")
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
