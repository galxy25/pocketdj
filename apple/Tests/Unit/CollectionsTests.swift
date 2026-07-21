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

    // v5 → v6: pockets gained source provenance. An old (v5) pocket with none of the
    // keys must migrate forward with all-nil provenance (hand-made pocket, never synced).
    func testV5PocketMigratesToV6WithNilProvenance() throws {
        let v5 = """
        { "schemaVersion": 5, "pockets": [
            { "id": "pkt_old", "name": "Soul", "songIds": ["sng_1"] }
        ], "playlists": [] }
        """
        let doc = try CollectionsCodec.decode(Data(v5.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)
        let p = try XCTUnwrap(doc.pockets.first)
        XCTAssertNil(p.sourcePlaylistId)
        XCTAssertNil(p.sourceSongIds)
        XCTAssertFalse(p.hasSource)
        XCTAssertFalse(p.syncsWithSource)      // no source ⇒ never auto-syncs
    }

    // v6 provenance survives a full round-trip; nil sourceSyncEnabled means enabled.
    func testV6ProvenanceRoundTrip() throws {
        var doc = CollectionsDocument()
        doc.pockets = [Pocket(id: "pkt_1", name: "My AM Mix", songIds: ["sng_1"],
                              sourcePlaylistId: "pl_abc", sourceName: "Apple Music (Local)",
                              sourceSongIds: ["sng_1"], sourceSyncEnabled: nil, sourceSyncedAt: nil)]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        let p = try XCTUnwrap(back.pockets.first)
        XCTAssertEqual(p.sourcePlaylistId, "pl_abc")
        XCTAssertEqual(p.sourceName, "Apple Music (Local)")
        XCTAssertEqual(p.sourceSongIds, ["sng_1"])
        XCTAssertTrue(p.hasSource)
        XCTAssertTrue(p.syncsWithSource)       // nil toggle ⇒ enabled
        var off = p; off.sourceSyncEnabled = false
        XCTAssertFalse(off.syncsWithSource)
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

    // MARK: Convert playlist → pocket

    /// A playlist's song/album/pocket node refs map to the new pocket's direct members
    /// (order + dedup preserved, albums/pockets kept as refs) and text cues become notes;
    /// the source playlist is untouched.
    func testConvertPlaylistToPocketCollectsRefsDedupedAndOrdered() {
        let s = store()
        let child = s.createPocket("Child")
        let pl = s.createPlaylist("BBQ")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addSong("sng_1", toPlaylist: pl.id)        // duplicate → deduped
        s.addSong("sng_2", toPlaylist: pl.id)
        s.addAlbum("alb_1", toPlaylist: pl.id)
        s.addPocketRef(child.id, toPlaylist: pl.id)
        s.addText("mic break", toPlaylist: pl.id)

        let before = s.pockets.count
        let pocket = s.convertToPocket(playlistId: pl.id)
        let p = try! XCTUnwrap(pocket)
        XCTAssertEqual(p.name, "BBQ")
        XCTAssertEqual(p.songIds, ["sng_1", "sng_2"])     // order + dedup
        XCTAssertEqual(p.albumIds, ["alb_1"])
        XCTAssertEqual(p.childPocketIds, [child.id])      // pockets nested, not expanded
        XCTAssertEqual(p.notes.map(\.text), ["mic break"])
        XCTAssertEqual(p.notes.map(\.position), [0])
        XCTAssertEqual(s.pockets.count, before + 1)       // a brand-new pocket
        XCTAssertNotNil(s.pocket(p.id))
        // Source playlist is left intact (6 nodes added, none removed).
        XCTAssertEqual(s.playlist(pl.id)?.sequences.first?.children?.count, 6)
    }

    /// Refs in nested sub-sequences are collected too, and the new pocket persists.
    func testConvertPlaylistToPocketRecursesAndPersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-conv-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let pl = s1.createPlaylist("Set")
        s1.addSong("sng_1", toPlaylist: pl.id)
        // A sub-sequence node carrying its own song child (mutate the playlist directly).
        var sub = CollectionsFactory.makeSequence("Sub")
        sub.children = [PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: "sng_9")]
        s1.addNode(sub, toPlaylist: pl.id)
        let p = try! XCTUnwrap(s1.convertToPocket(playlistId: pl.id))
        XCTAssertEqual(p.songIds, ["sng_1", "sng_9"])      // recursed into the sub-sequence

        // Reload from disk → the converted pocket survived.
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.pocket(p.id)?.songIds, ["sng_1", "sng_9"])
    }

    /// A read-only "From your sources" playlist converts to a pocket of its songs (deduped).
    func testConvertSourcePlaylistToPocket() {
        let s = store()
        let src = SourcePlaylist(
            playlist: IndexPlaylist(id: "ipl_1", name: "My AM Mix", songIds: ["sng_1", "sng_2", "sng_1"]),
            sourceName: "Apple Music (Local)")
        let p = s.convertToPocket(source: src)
        XCTAssertEqual(p.name, "My AM Mix")
        XCTAssertEqual(p.songIds, ["sng_1", "sng_2"])      // order preserved, deduped
        XCTAssertNotNil(s.pocket(p.id))
    }

    func testConvertUnknownPlaylistReturnsNil() {
        let s = store()
        XCTAssertNil(s.convertToPocket(playlistId: "pls_nope"))
        XCTAssertTrue(s.pockets.isEmpty)
    }

    // MARK: Source sync (v6 — converted pockets follow their source playlist)

    private func sourcePL(_ id: String, _ name: String, _ songIds: [String],
                          source: String = "Apple Music (Local)") -> SourcePlaylist {
        SourcePlaylist(playlist: IndexPlaylist(id: id, name: name, songIds: songIds), sourceName: source)
    }

    func testConvertFromSourceStampsProvenanceAndSnapshot() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2", "sng_1"]))
        XCTAssertEqual(p.sourcePlaylistId, "pl_1")
        XCTAssertEqual(p.sourceName, "Apple Music (Local)")
        XCTAssertEqual(p.sourceSongIds, ["sng_1", "sng_2"])   // deduped snapshot = initial membership
        XCTAssertTrue(p.syncsWithSource)                      // enabled by default
        XCTAssertNil(p.sourceSyncedAt)                        // stamped only by a CHANGING sync
    }

    func testSyncAppendsSourceAdditionsAndRemovesSourceRemovals() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"]))
        s.setSongRepeat("sng_2", count: 3, inPocket: p.id)
        // Source changed upstream: sng_2 removed, sng_3 added.
        let changed = s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_3"])])
        XCTAssertEqual(changed, 1)
        let after = s.pocket(p.id)!
        XCTAssertEqual(after.songIds, ["sng_1", "sng_3"])
        XCTAssertEqual(after.sourceSongIds, ["sng_1", "sng_3"])   // snapshot advanced
        XCTAssertNil(after.songRepeats["sng_2"])                  // removed song's repeat dropped
        XCTAssertNotNil(after.sourceSyncedAt)
    }

    func testSyncPreservesUserEdits() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"]))
        s.addSong("sng_mine", toPocket: p.id)          // user's own addition
        s.removeSong("sng_1", fromPocket: p.id)        // user's own removal
        // Source adds sng_3 (sng_1 still there upstream — but the user removed it here).
        let changed = s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2", "sng_3"])])
        XCTAssertEqual(changed, 1)
        let after = s.pocket(p.id)!
        XCTAssertEqual(after.songIds, ["sng_2", "sng_mine", "sng_3"])  // mine kept, sng_1 NOT resurrected
    }

    func testSyncSkipsDisabledPocketAndUnknownSource() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1"]))
        s.setSourceSyncEnabled(false, forPocket: p.id)
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"])]), 0)
        XCTAssertEqual(s.pocket(p.id)?.songIds, ["sng_1"])   // untouched while off
        s.setSourceSyncEnabled(true, forPocket: p.id)
        // Source playlist missing from this refresh (source disabled / deleted upstream):
        // the pocket must be left alone, never wiped.
        XCTAssertEqual(s.syncConvertedCollections(with: []), 0)
        XCTAssertEqual(s.pocket(p.id)?.songIds, ["sng_1"])
        // Same playlist id under a DIFFERENT source name must not match.
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_9"], source: "My Digital")]), 0)
        XCTAssertEqual(s.pocket(p.id)?.songIds, ["sng_1"])
    }

    func testSyncNoChangeIsANoOp() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"]))
        let before = s.pocket(p.id)!
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"])]), 0)
        let after = s.pocket(p.id)!
        XCTAssertEqual(after.updatedAt, before.updatedAt)    // no save churn
        XCTAssertNil(after.sourceSyncedAt)
    }

    func testSyncedPocketPersistsProvenanceAcrossReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let p = s1.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1"]))
        s1.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"])])
        let s2 = CollectionsStore(fileURL: url)
        let back = s2.pocket(p.id)!
        XCTAssertEqual(back.songIds, ["sng_1", "sng_2"])
        XCTAssertEqual(back.sourcePlaylistId, "pl_1")
        XCTAssertEqual(back.sourceSongIds, ["sng_1", "sng_2"])
        XCTAssertNotNil(back.sourceSyncedAt)
        // A hand-made pocket never participates.
        let hand = s2.createPocket("Hand-made")
        XCTAssertEqual(s2.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_9"])]), 1)
        XCTAssertTrue(s2.pocket(hand.id)!.songIds.isEmpty)
    }

    // MARK: Source sync — duplicated PLAYLISTS (the "Duplicate as editable playlist" path)

    private func playlistSongIds(_ s: CollectionsStore, _ id: String) -> [String] {
        (s.playlist(id)?.sequences ?? []).flatMap { ($0.children ?? []).compactMap(\.songId) }
    }

    func testDuplicateFromSourceStampsProvenance() {
        let s = store()
        let pl = s.createPlaylist("001", songIds: ["sng_1", "sng_2"],
                                  source: sourcePL("pl_1", "001", ["sng_1", "sng_2"]))
        XCTAssertEqual(pl.sourcePlaylistId, "pl_1")
        XCTAssertEqual(pl.sourceName, "Apple Music (Local)")
        XCTAssertEqual(pl.sourceSongIds, ["sng_1", "sng_2"])
        XCTAssertTrue(pl.syncsWithSource)
        // A plain create (no source) stays provenance-free.
        XCTAssertFalse(s.createPlaylist("Hand", songIds: ["sng_9"]).hasSource)
    }

    func testPlaylistSyncAppendsAndRemoves() {
        let s = store()
        let pl = s.createPlaylist("001", songIds: ["sng_1", "sng_2"],
                                  source: sourcePL("pl_1", "001", ["sng_1", "sng_2"]))
        // Source changed upstream: sng_2 removed, sng_3 added.
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "001", ["sng_1", "sng_3"])]), 1)
        XCTAssertEqual(playlistSongIds(s, pl.id), ["sng_1", "sng_3"])   // node removed + appended
        let after = s.playlist(pl.id)!
        XCTAssertEqual(after.sourceSongIds, ["sng_1", "sng_3"])
        XCTAssertNotNil(after.sourceSyncedAt)
    }

    func testPlaylistSyncPreservesUserEditsAndChapters() {
        let s = store()
        let pl = s.createPlaylist("001", songIds: ["sng_1", "sng_2"],
                                  source: sourcePL("pl_1", "001", ["sng_1", "sng_2"]))
        // User adds their own chapter + song, removes sng_1 themselves.
        s.addSequence("Encore", toPlaylist: pl.id)
        let chapter = s.playlist(pl.id)!.sequences.last!
        s.addSong("sng_mine", toPlaylist: pl.id, sequenceId: chapter.nodeId)
        s.removeNode(s.playlist(pl.id)!.sequences[0].children![0].nodeId, fromPlaylist: pl.id)
        // Source adds sng_3 (sng_1 still there upstream — user's removal must stand).
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "001", ["sng_1", "sng_2", "sng_3"])]), 1)
        XCTAssertEqual(playlistSongIds(s, pl.id), ["sng_2", "sng_3", "sng_mine"])
        XCTAssertEqual(s.playlist(pl.id)!.sequences.map(\.name), ["Default", "Encore"])  // chapters intact
    }

    func testPlaylistSyncTogglesAndNoOp() {
        let s = store()
        let pl = s.createPlaylist("001", songIds: ["sng_1"], source: sourcePL("pl_1", "001", ["sng_1"]))
        s.setSourceSyncEnabled(false, forPlaylist: pl.id)
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "001", ["sng_1", "sng_2"])]), 0)
        XCTAssertEqual(playlistSongIds(s, pl.id), ["sng_1"])            // frozen while off
        s.setSourceSyncEnabled(true, forPlaylist: pl.id)
        XCTAssertEqual(s.syncConvertedCollections(with: [sourcePL("pl_1", "001", ["sng_1"])]), 0)  // in sync ⇒ no-op
        XCTAssertNil(s.playlist(pl.id)?.sourceSyncedAt)
        XCTAssertEqual(s.syncConvertedCollections(with: []), 0)         // source missing ⇒ untouched
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

    // MARK: - Repeat count (performance-item loop count)

    func testRepeatCountNormalizationAndStorage() {
        XCTAssertEqual(CollectionMembership.normalizedRepeat(nil), 1)
        XCTAssertEqual(CollectionMembership.normalizedRepeat(0), 1)
        XCTAssertEqual(CollectionMembership.normalizedRepeat(-4), 1)
        XCTAssertEqual(CollectionMembership.normalizedRepeat(3), 3)
        XCTAssertEqual(CollectionMembership.normalizedRepeat(9_999), CollectionMembership.maxRepeat)
        XCTAssertNil(CollectionMembership.storedRepeat(1), "a single play persists no key")
        XCTAssertNil(CollectionMembership.storedRepeat(0))
        XCTAssertEqual(CollectionMembership.storedRepeat(4), 4)
        XCTAssertEqual(CollectionMembership.storedRepeat(9_999), CollectionMembership.maxRepeat)
    }

    func testAddStudioItemWithRepeatToPlaylist() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let seq = pl.sequences[0].nodeId
        s.addSong("lp_a", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: seq), repeatCount: 3)
        let node = s.playlist(pl.id)!.sequences[0].children!.first!
        XCTAssertEqual(node.songId, "lp_a")
        XCTAssertEqual(node.repeatCount, 3)
        XCTAssertEqual(s.repeatCount(forNode: node.nodeId, inPlaylist: pl.id), 3)
        // A single play stores no key (keeps the node byte-identical to a normal add).
        s.addSong("lp_b", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: seq), repeatCount: 1)
        XCTAssertNil(s.playlist(pl.id)!.sequences[0].children!.last!.repeatCount)
    }

    func testSetAndClearRepeatPlaylistNode() {
        let s = store()
        let pl = s.createPlaylist("Set")
        s.addSong("smp_a", toPlaylist: pl.id)
        let nid = s.playlist(pl.id)!.sequences[0].children!.first!.nodeId
        s.setNodeRepeat(nid, count: 5, inPlaylist: pl.id)
        XCTAssertEqual(s.repeatCount(forNode: nid, inPlaylist: pl.id), 5)
        s.setNodeRepeat(nid, count: 1, inPlaylist: pl.id)   // ≤1 clears the field
        XCTAssertNil(s.playlist(pl.id)!.sequences[0].children!.first!.repeatCount)
        XCTAssertEqual(s.repeatCount(forNode: nid, inPlaylist: pl.id), 1)
    }

    func testPocketSongRepeatSetGetAndRemoveClears() {
        let s = store()
        let p = s.createPocket("Pkt")
        s.addSong("tk_a", to: AddTarget(kind: .pocket, id: p.id), repeatCount: 4)
        XCTAssertEqual(s.repeatCount(forSong: "tk_a", inPocket: p.id), 4)
        XCTAssertEqual(s.pocket(p.id)?.songRepeats["tk_a"], 4)
        s.setSongRepeat("tk_a", count: 2, inPocket: p.id)
        XCTAssertEqual(s.repeatCount(forSong: "tk_a", inPocket: p.id), 2)
        // Removing the member clears its repeat sidecar (no orphan key).
        s.removeSong("tk_a", fromPocket: p.id)
        XCTAssertNil(s.pocket(p.id)?.songRepeats["tk_a"])
        XCTAssertEqual(s.repeatCount(forSong: "tk_a", inPocket: p.id), 1)
    }

    func testRepeatCountPersistsAcrossReload() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-repeat-\(UUID().uuidString).json")
        let s1 = CollectionsStore(fileURL: url)
        let pl = s1.createPlaylist("Set")
        s1.addSong("lp_a", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences[0].nodeId), repeatCount: 6)
        let p = s1.createPocket("Pkt")
        s1.addSong("smp_a", to: AddTarget(kind: .pocket, id: p.id), repeatCount: 3)
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.playlist(pl.id)?.sequences[0].children?.first?.repeatCount, 6)
        XCTAssertEqual(s2.pocket(p.id)?.songRepeats["smp_a"], 3)
    }

    func testSetlistTrackShownMsMultipliesByRepeat() {
        let once = SetlistTrack(songId: "lp_a", artist: "Studio", name: "Loop", bpm: 120, camelot: nil, lengthMs: 4_000)
        XCTAssertEqual(once.shownMs, 4_000)
        let thrice = SetlistTrack(songId: "lp_a", artist: "Studio", name: "Loop", bpm: 120, camelot: nil,
                                  lengthMs: 4_000, repeatCount: 3)
        XCTAssertEqual(thrice.shownMs, 12_000)
        // A text cue contributes 0 regardless of a stray repeat.
        let text = SetlistTrack(songId: "", artist: "", name: "cue", bpm: nil, camelot: nil,
                                isText: true, repeatCount: 5)
        XCTAssertEqual(text.shownMs, 0)
    }

    // MARK: Recent-add MRU (F11 Part A)

    func testRecentAddTargetsPushMoveToFrontAndDedupeByKindId() {
        let s = store()
        let a = s.createPocket("A"), b = s.createPocket("B")
        let pl = s.createPlaylist("Set")
        let seq0 = pl.sequences[0].nodeId
        s.addSong("sng_1", to: AddTarget(kind: .pocket, id: a.id))
        s.addSong("sng_2", to: AddTarget(kind: .pocket, id: b.id))
        s.addAlbum("alb_1", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: seq0))
        // Most-recent first: playlist, B, A.
        XCTAssertEqual(s.recentAddTargets.map(\.id), [pl.id, b.id, a.id])
        // Re-adding A moves it to the FRONT (no duplicate entry).
        s.addSong("sng_3", to: AddTarget(kind: .pocket, id: a.id))
        XCTAssertEqual(s.recentAddTargets.map(\.id), [a.id, pl.id, b.id])
        XCTAssertEqual(s.recentAddTargets.count, 3)
    }

    /// Dedupe IGNORES sequenceId: re-adding to a DIFFERENT chapter of the same playlist is the same
    /// MRU target (freshest chapter wins), never a second row.
    func testRecentAddDedupeIgnoresSequenceId() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let seq0 = pl.sequences[0].nodeId
        s.addSequence("Encore", toPlaylist: pl.id)
        let seq1 = s.playlist(pl.id)!.sequences[1].nodeId
        s.addSong("sng_1", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: seq0))
        s.addSong("sng_2", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: seq1))
        XCTAssertEqual(s.recentAddTargets.count, 1)
        XCTAssertEqual(s.recentAddTargets.first?.sequenceId, seq1)   // freshest chapter
    }

    func testRecentAddTargetsCapAtTen() {
        let s = store()
        var ids: [String] = []
        for i in 0..<15 {
            let p = s.createPocket("P\(i)"); ids.append(p.id)
            s.addSong("sng_\(i)", to: AddTarget(kind: .pocket, id: p.id))
        }
        XCTAssertEqual(s.recentAddTargets.count, CollectionsStore.maxRecentTargets)
        // The 10 MOST RECENT survive (newest first).
        XCTAssertEqual(s.recentAddTargets.map(\.id), Array(ids.reversed().prefix(10)))
    }

    /// A source-playlist add (`addSong(_:toIndexPlaylist:)`) must NOT touch the MRU — consistent
    /// with `lastAddTarget` (that path deliberately skips the remembered target).
    func testSourceAddDoesNotRecordRecent() {
        let s = store()
        let src = SourcePlaylist(playlist: IndexPlaylist(id: "ipl_1", name: "AM Mix", songIds: []),
                                 sourceName: "Apple Music (Local)")
        _ = s.addSong("sng_1", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertTrue(s.recentAddTargets.isEmpty)
        XCTAssertNil(s.lastAddTarget)
    }

    func testRecentAddTargetsRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-recent-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let s1 = CollectionsStore(fileURL: url)
        let a = s1.createPocket("A"), b = s1.createPocket("B")
        s1.addSong("sng_1", to: AddTarget(kind: .pocket, id: a.id))
        s1.addSong("sng_2", to: AddTarget(kind: .pocket, id: b.id))
        let s2 = CollectionsStore(fileURL: url)
        XCTAssertEqual(s2.recentAddTargets.map(\.id), [b.id, a.id])
    }

    /// WIPE-SAFETY: an OLD collections document lacking `recentAddTargets` decodes with every
    /// collection intact and the MRU defaulting to [] (never a crash / never a wipe).
    func testOldDocWithoutRecentDecodesWithCollectionsIntact() throws {
        let old = """
        { "schemaVersion": 7,
          "pockets": [ { "id": "pkt_1", "name": "Soul", "songIds": ["sng_1"] } ],
          "playlists": [], "lastAddTarget": { "kind": "pocket", "id": "pkt_1" } }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-oldrecent-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(old.utf8).write(to: url)
        let s = CollectionsStore(fileURL: url)
        XCTAssertEqual(s.pocket("pkt_1")?.songIds, ["sng_1"])   // collections survived
        XCTAssertEqual(s.lastAddTarget?.id, "pkt_1")
        XCTAssertTrue(s.recentAddTargets.isEmpty)               // additive default
    }

    // MARK: Activity hooks (F11 Part B — CollectionsStore.onActivity)

    func testAddFiresOneAddActivity() {
        let s = store()
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        let p = s.createPocket("Soul")
        s.addSong("sng_1", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .add)
        XCTAssertEqual(events.first?.itemId, "sng_1")
        XCTAssertEqual(events.first?.collectionId, p.id)
        XCTAssertEqual(events.first?.collectionKind, "pocket")
        XCTAssertEqual(events.first?.collectionName, "Soul")
    }

    func testRemoveSongFiresOneRemoveActivity() {
        let s = store()
        let p = s.createPocket("Soul")
        s.addSong("sng_1", toPocket: p.id)
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        s.removeSong("sng_1", fromPocket: p.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .remove)
        XCTAssertEqual(events.first?.itemId, "sng_1")
        XCTAssertEqual(events.first?.collectionKind, "pocket")
    }

    func testRemoveNodeFiresOneRemoveActivityWithUnderlyingItemId() {
        let s = store()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        let nodeId = s.playlist(pl.id)!.sequences[0].children!.first!.nodeId
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        s.removeNode(nodeId, fromPlaylist: pl.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .remove)
        XCTAssertEqual(events.first?.itemId, "sng_1")           // underlying song id, not nodeId
        XCTAssertEqual(events.first?.collectionKind, "playlist")
    }

    /// A source-sync RECONCILE mutates the arrays directly (not via removeSong/removeNode), so it
    /// must fire NO activity — a catalog refresh can't spam the history.
    func testReconcileFiresNoActivity() {
        let s = store()
        let p = s.convertToPocket(source: sourcePL("pl_1", "AM Mix", ["sng_1", "sng_2"]))
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        // Source now DROPS sng_2 and ADDS sng_3 → reconcile removes/appends directly.
        let changed = s.syncConvertedCollections(with: [sourcePL("pl_1", "AM Mix", ["sng_1", "sng_3"])])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(s.pocket(p.id)?.songIds, ["sng_1", "sng_3"])   // reconcile did mutate
        XCTAssertTrue(events.isEmpty)                                 // …but fired no activity
    }

    /// FIX 1: the iOS-27 App-Intent add path now routes through the `addSong(_:to:)` choke point
    /// (AddTarget) — the SAME call `AddToPlaylistIntent.perform()` makes — so a Siri/Shortcuts add
    /// emits exactly one add activity AND updates the Recent MRU + lastAddTarget, exactly like an
    /// in-app add (the old low-level add(toPlaylist:)/add(toPocket:) path did neither).
    func testIntentAddPathFiresActivityAndUpdatesMRU() {
        let s = store()
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        let pl = s.createPlaylist("Warmup")
        // Exactly the call the intent's playlist branch now makes (no chapter → bare AddTarget).
        s.addSong("sng_1", to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .add)
        XCTAssertEqual(events.first?.itemId, "sng_1")
        XCTAssertEqual(events.first?.collectionId, pl.id)
        XCTAssertEqual(events.first?.collectionKind, "playlist")
        XCTAssertEqual(s.recentAddTargets.first?.id, pl.id)   // MRU updated
        XCTAssertEqual(s.lastAddTarget?.id, pl.id)
        XCTAssertTrue(s.playlist(pl.id, contains: "sng_1"))   // song actually added
    }

    /// FIX 5: removing a nested child pocket from its parent is a user removal of an item from a
    /// collection, so it fires exactly one remove activity (itemId = child id, itemTitle = its
    /// name, collection = the parent) — like removeSong/removeAlbum/removeNode.
    func testRemoveChildPocketFiresOneRemoveActivity() {
        let s = store()
        let parent = s.createPocket("Parent")
        let child = s.createPocket("Child")
        XCTAssertTrue(s.addChildPocket(child.id, toPocket: parent.id))
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        s.removeChildPocket(child.id, fromPocket: parent.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .remove)
        XCTAssertEqual(events.first?.itemId, child.id)
        XCTAssertEqual(events.first?.itemTitle, "Child")       // the child pocket's name
        XCTAssertEqual(events.first?.collectionId, parent.id)  // scoped to the parent
        XCTAssertEqual(events.first?.collectionKind, "pocket")
        XCTAssertEqual(events.first?.collectionName, "Parent")
    }
}
