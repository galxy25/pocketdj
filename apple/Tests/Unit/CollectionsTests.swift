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

    /// Multi-select Add sheet helpers: playlist membership (song + album) + toggle-off removal,
    /// no-op when absent, and studio ids riding the song plumbing. Mirrors the sheet's add ⇄ remove.
    func testPlaylistToggleMembershipAndRemove() {
        let s = store()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addAlbum("alb_1", toPlaylist: pl.id)
        XCTAssertTrue(s.playlist(pl.id, contains: "sng_1"))
        XCTAssertTrue(s.playlist(pl.id, containsAlbum: "alb_1"))
        XCTAssertFalse(s.playlist(pl.id, contains: "sng_2"))

        s.removeSong("sng_1", fromPlaylist: pl.id)
        XCTAssertFalse(s.playlist(pl.id, contains: "sng_1"))
        s.removeAlbum("alb_1", fromPlaylist: pl.id)
        XCTAssertFalse(s.playlist(pl.id, containsAlbum: "alb_1"))
        s.removeSong("sng_ghost", fromPlaylist: pl.id)   // absent ⇒ no-op, no crash

        // Studio ids ride addSong/removeSong verbatim (spec §8).
        s.addSong("lp_b", toPlaylist: pl.id)
        XCTAssertTrue(s.playlist(pl.id, contains: "lp_b"))
        s.removeSong("lp_b", fromPlaylist: pl.id)
        XCTAssertFalse(s.playlist(pl.id, contains: "lp_b"))
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

    func testReimportMergesPlaylistByIdWithoutDuplicating() throws {
        let s = store()
        let pl = s.createPlaylist("Set", songIds: ["sng_1", "sng_2"])
        let data = try XCTUnwrap(s.exportPlaylist(pl.id))
        try s.importCollection(data: data)   // re-import into the SAME store
        // Match-by-id merge: NO duplicate playlist, id preserved, songs deduped (not re-added).
        XCTAssertEqual(s.playlists.count, 1)
        let merged = s.playlists.first!
        XCTAssertEqual(merged.id, pl.id)
        XCTAssertEqual(merged.sequences.first?.children?.compactMap(\.songId), ["sng_1", "sng_2"])
    }

    func testImportDropsChildRefToPocketPresentNowhere() throws {
        let s = store()
        let a = s.createPocket("A"); let b = s.createPocket("B")
        s.addChildPocket(b.id, toPocket: a.id)
        s.addSong("sng_1", toPocket: a.id)
        // Export the PARENT ONLY (its child ref points at B, absent from the export).
        let parentOnly = try XCTUnwrap(s.exportPocket(a.id))
        // Import into a FRESH store where B does not exist → the dangling child ref is dropped, and
        // the pocket's id is preserved (match-by-id).
        let s2 = store()
        try s2.importCollection(data: parentOnly)
        let importedA = s2.pockets.first { $0.id == a.id }
        XCTAssertNotNil(importedA, "id preserved on import")
        XCTAssertEqual(importedA?.songIds, ["sng_1"])
        XCTAssertEqual(importedA?.childPocketIds, [], "ref to a pocket present nowhere is dropped")
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
        // Export → re-import (same store) MERGES by id (not a fresh copy) and keeps the notes.
        let data = try XCTUnwrap(s2.exportPocket(p.id))
        try s2.importCollection(data: data)
        XCTAssertEqual(s2.pockets.count, 1)                             // merged, not duplicated
        XCTAssertEqual(s2.pocket(p.id)?.notes.first?.text, "A poem")
        XCTAssertEqual(s2.pocket(p.id)?.notes.count, 1)                 // note not duplicated
        XCTAssertEqual(s2.pockets.last?.id, p.id)                       // id preserved (match-by-id)
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

    // MARK: R3 — "From your sources" adds were never logged (data loss)

    /// The R3 fix: adding a song to a read-only SOURCE playlist (an Apple Music playlist in "From
    /// your sources") must log exactly ONE add, naming the on-device DUPLICATE it landed in.
    /// Before the fix this path composed two low-level primitives and emitted nothing at all.
    func testSourceAddFiresOneAddActivityNamingTheDuplicate() {
        let s = store()
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        // The source does NOT already contain the song, so the add is real.
        let src = sourcePL("ipl_1", "AM Mix", ["sng_other"])
        let result = s.addSong("sng_new", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .add)
        XCTAssertEqual(events.first?.itemId, "sng_new")
        // The DUPLICATE, not the read-only source — this is what the write-back backfill resolves.
        XCTAssertEqual(events.first?.collectionId, result.playlist.id)
        XCTAssertEqual(events.first?.collectionKind, "playlist")
        XCTAssertEqual(events.first?.collectionName, "AM Mix")
    }

    /// The gate that keeps the fix honest. `duplicateForSource` seeds the new duplicate with EVERY
    /// id in the source, so the first tap on a song the Apple Music playlist ALREADY contains
    /// appends nothing. An unconditional emit would log an add that never happened — and the
    /// write-back backfill would then re-drive it upstream.
    func testSourceAddOfAlreadyPresentSongFiresNoActivity() {
        let s = store()
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        let src = sourcePL("ipl_1", "AM Mix", ["sng_dup"])       // source already has it
        let first = s.addSong("sng_dup", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertTrue(first.alreadyPresent)
        XCTAssertTrue(events.isEmpty, "seeded-duplicate add must not fabricate an activity row")
        // And a genuine re-tap on the now-existing duplicate stays silent too.
        _ = s.addSong("sng_dup", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertTrue(events.isEmpty)
    }

    /// Nesting a pocket in a playlist emitted nothing while its inverse (`removeNode`) DID — the
    /// timeline showed a removal it never showed an add for. The row is named by the POCKET, whose
    /// id resolves to no catalog song.
    func testAddPocketRefFiresOneAddActivityNamedByThePocket() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let child = s.createPocket("Deep Cuts")
        var events: [CollectionsStore.ActivityHook] = []
        s.onActivity = { events.append($0) }
        s.addPocketRef(child.id, toPlaylist: pl.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .add)
        XCTAssertEqual(events.first?.itemId, child.id)
        XCTAssertEqual(events.first?.itemTitle, "Deep Cuts")
        XCTAssertEqual(events.first?.collectionId, pl.id)
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

// MARK: - Two-way source sync (Apple Music write-back on adds to converted/duplicated collections)

/// The PUSH half of converted-collection source sync (Levi 2026-07-22): adding a song to a
/// pocket converted from — or a playlist duplicated from — an Apple Music source list should
/// enqueue an upstream write-back to the real Apple Music playlist, plus a time-bounded backfill
/// that re-drives adds that predate the wiring. Drives the store's `enqueueSourceWriteBack` seam
/// with a stub that mirrors `PlaylistWriteBack.enqueue`'s dedup (true only the first time a
/// (playlist, song) pair is queued), so both the per-add path and the backfill count are exercised
/// with no MusicKit, no account, and no network.
final class WriteBackSourceSyncTests: XCTestCase {

    /// A catalog where sng_am1/sng_am2 carry Apple Music store ids and sng_plain does not.
    private static let amJSON = """
    { "manifest": { "sourceName": "Apple Music (Local)", "counts": { "albums": 1, "songs": 3 } },
      "albums": [ { "id": "alb_am", "artist": "Aria", "name": "AM", "genre": "Pop", "year": 2020,
                    "country": "US", "trackList": ["sng_am1","sng_am2","sng_plain"], "fileType": "m4a" } ],
      "songs": [
        { "id": "sng_am1", "albumId": "alb_am", "artist": "Aria", "name": "One", "trackNumber": 1,
          "year": 2020, "length": 180000, "explicit": false, "appleMusicId": "am_111" },
        { "id": "sng_am2", "albumId": "alb_am", "artist": "Aria", "name": "Two", "trackNumber": 2,
          "year": 2020, "length": 190000, "explicit": false, "appleMusicId": "am_222" },
        { "id": "sng_plain", "albumId": "alb_am", "artist": "Aria", "name": "Three", "trackNumber": 3,
          "year": 2020, "length": 200000, "explicit": false }
      ] }
    """
    private struct AMLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            try JSONDecoder().decode(IndexJSON.self, from: Data(WriteBackSourceSyncTests.amJSON.utf8))
        }
    }

    /// Records every seam call and dedups on (playlistId|songId) like the real queue.
    private final class Capture {
        var calls: [(pid: String, name: String, sid: String, amid: String?,
                     title: String, artist: String, album: String?, durationMs: Int?)] = []
        private var seen = Set<String>()
        func enqueue(_ pid: String, _ name: String, _ sid: String, _ amid: String?,
                     _ title: String, _ artist: String, _ album: String?, _ durationMs: Int?) -> Bool {
            calls.append((pid, name, sid, amid, title, artist, album, durationMs))
            return seen.insert(pid + "|" + sid).inserted
        }
        var cancelCalls: [(pid: String, songIds: Set<String>)] = []
        func cancel(_ pid: String, _ songIds: Set<String>) { cancelCalls.append((pid, songIds)) }
    }

    /// `CollectionsStore.app` is a WEAK reference, so the test must hold the app strongly for
    /// the whole test — otherwise it deallocates the instant `wired()` returns and every
    /// catalog lookup (the `appleMusicId` resolve) silently sees nil. A per-test property is the
    /// simplest strong anchor (XCTestCase makes a fresh instance per test method).
    private var appHold: AppModel?

    @MainActor
    private func wired() async -> (CollectionsStore, Capture) {
        let app = AppModel(loader: AMLoader())
        await app.loadIfNeeded()
        appHold = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-wb-\(UUID().uuidString).json"))
        s.app = app
        let cap = Capture()
        s.enqueueSourceWriteBack = { cap.enqueue($0, $1, $2, $3, $4, $5, $6, $7) }
        s.cancelPendingWriteBacks = { cap.cancel($0, $1) }
        return (s, cap)
    }

    private func amSource(_ id: String, _ name: String, _ songs: [String],
                          source: String = Config.appleMusicSourceName) -> SourcePlaylist {
        SourcePlaylist(playlist: IndexPlaylist(id: id, name: name, songIds: songs), sourceName: source)
    }

    private func addEvent(_ songId: String, in collectionId: String, kind: String = "pocket",
                          atMs: Double, origin: String? = nil) -> CollectionActivityStore.ActivityEvent {
        CollectionActivityStore.ActivityEvent(id: UUID(), at: atMs, kind: .add, itemId: songId,
                                              itemTitle: nil, collectionId: collectionId,
                                              collectionKind: kind, collectionName: "AM Mix",
                                              originInstallId: origin)
    }

    // MARK: Per-add write-back

    @MainActor
    func testAddNewSongToConvertedPocketWritesBack() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(cap.calls.count, 1)
        XCTAssertEqual(cap.calls.first?.pid, "ipl_am")
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
        XCTAssertEqual(cap.calls.first?.amid, "am_222")   // resolved from the catalog, not passed in
    }

    @MainActor
    func testAddSongAlreadyInSourceSnapshotDoesNotWriteBack() async {
        let (s, cap) = await wired()
        // sng_am1 is the source's own song → already in the snapshot → already upstream.
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am1", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertTrue(cap.calls.isEmpty)
    }

    /// A catalog song our indexer never resolved (`appleMusicId` == nil) is STILL enqueued — with
    /// its identity — so the transport can resolve the catalog id ON-DEVICE at delivery. This is
    /// the fix for "The Magic Clap": an Apple Music (Local) song with no store id that IS on Apple
    /// Music. The seam is handed a nil amid + the song's title/artist/album/duration.
    @MainActor
    func testAddSongWithoutAppleMusicIdEnqueuesIdentityForOnDeviceResolution() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_plain", to: AddTarget(kind: .pocket, id: p.id))   // no store id, but IS a catalog song
        XCTAssertEqual(cap.calls.count, 1)
        XCTAssertEqual(cap.calls.first?.sid, "sng_plain")
        XCTAssertNil(cap.calls.first?.amid)                 // nothing to pass — resolve on device
        XCTAssertEqual(cap.calls.first?.title, "Three")     // identity carried for the resolve
        XCTAssertEqual(cap.calls.first?.artist, "Aria")
        XCTAssertEqual(cap.calls.first?.durationMs, 200000)
    }

    /// A STUDIO performance item (not a catalog song — absent from `songsById`) has no upstream and
    /// is never enqueued, even in a linked pocket.
    @MainActor
    func testAddStudioItemToLinkedPocketDoesNotWriteBack() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("smp_notcatalog", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertTrue(cap.calls.isEmpty)
    }

    @MainActor
    func testAddToNonAppleMusicSourcePocketDoesNotWriteBack() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_dig", "Dig Mix", ["sng_am1"], source: "My Digital"))
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertTrue(cap.calls.isEmpty)
    }

    @MainActor
    func testAddToPlainPocketDoesNotWriteBack() async {
        let (s, cap) = await wired()
        let p = s.createPocket("Mine")   // no provenance
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertTrue(cap.calls.isEmpty)
    }

    @MainActor
    func testAddToDuplicatedPlaylistWritesBack() async {
        let (s, cap) = await wired()
        let pl = s.createPlaylist("AM Mix", songIds: ["sng_am1"],
                                  source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am2", to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(cap.calls.count, 1)
        XCTAssertEqual(cap.calls.first?.pid, "ipl_am")
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
    }

    // MARK: Force sync (the collection-row "Force Apple Music sync" action)

    /// The whole point of the force path: a song already in the source SNAPSHOT reads as "already
    /// upstream" and the auto path (correctly) skips it — but the user who KNOWS it isn't actually
    /// in the real playlist (a stale snapshot) can force it. Force BYPASSES the snapshot guard and
    /// enqueues, where the ordinary add returns nothing.
    @MainActor
    func testForceSyncBypassesSnapshotGuard() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        // Auto path: sng_am1 is in the snapshot ⇒ nothing queued.
        s.addSong("sng_am1", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertTrue(cap.calls.isEmpty)
        // Force path: overrides the snapshot ⇒ a job is queued.
        XCTAssertEqual(s.forceWriteBackSong("sng_am1", forTargetKind: .pocket, collectionId: p.id), .queued)
        XCTAssertEqual(cap.calls.map(\.sid), ["sng_am1"])
        XCTAssertEqual(cap.calls.first?.amid, "am_111")
    }

    /// A second force of the same (collection, song) dedups against the queue (the seam returns
    /// false the second time), so the UI can say "already on its way" instead of double-adding.
    @MainActor
    func testForceSyncDedupsOnSecondAttempt() async {
        let (s, _) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        XCTAssertEqual(s.forceWriteBackSong("sng_am2", forTargetKind: .pocket, collectionId: p.id), .queued)
        XCTAssertEqual(s.forceWriteBackSong("sng_am2", forTargetKind: .pocket, collectionId: p.id), .deduped)
    }

    /// A plain pocket (no Apple Music provenance) has no playlist to write to → `.notLinked`,
    /// nothing queued. The UI turns this into "link it first" guidance.
    @MainActor
    func testForceSyncPlainPocketIsNotLinked() async {
        let (s, cap) = await wired()
        let p = s.createPocket("Mine")
        XCTAssertEqual(s.forceWriteBackSong("sng_am2", forTargetKind: .pocket, collectionId: p.id), .notLinked)
        XCTAssertTrue(cap.calls.isEmpty)
    }

    /// A Studio performance item isn't a catalog song → `.notCatalogSong`, even in a linked pocket.
    @MainActor
    func testForceSyncStudioItemIsNotCatalogSong() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        XCTAssertEqual(s.forceWriteBackSong("smp_x", forTargetKind: .pocket, collectionId: p.id), .notCatalogSong)
        XCTAssertTrue(cap.calls.isEmpty)
    }

    // MARK: "From your sources" add — identity-only Apple Music songs are write-back-eligible

    /// The root-cause fix: an Apple Music (Local) song our indexer never resolved a store id for
    /// (`appleMusicId == nil`) must STILL be write-back-eligible when added to an Apple Music source
    /// playlist — carrying its identity so the queue resolves the store id on-device. The old gate
    /// (`!amId.isEmpty`) reported it as "not an Apple Music track" and never synced it.
    @MainActor
    func testAddToIndexPlaylistIdentityOnlyIsWriteBackEligible() async {
        let (s, _) = await wired()
        let src = amSource("ipl_am", "AM Mix", ["sng_am1"])
        let result = s.addSong("sng_plain", toIndexPlaylist: src, appleMusicId: nil)   // no store id
        XCTAssertTrue(result.writeBackEligible)
        XCTAssertNil(result.appleMusicId)          // nothing to pass — resolved on device
        XCTAssertEqual(result.title, "Three")      // identity carried for the resolve
        XCTAssertEqual(result.artist, "Aria")
        XCTAssertEqual(result.durationMs, 200000)
    }

    /// The same identity-only song added to a NON-Apple-Music source stays local — not eligible.
    @MainActor
    func testAddToNonAppleMusicIndexPlaylistIsNotEligible() async {
        let (s, _) = await wired()
        let src = amSource("ipl_dig", "Dig Mix", ["sng_am1"], source: "My Digital")
        let result = s.addSong("sng_plain", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertFalse(result.writeBackEligible)
    }

    // MARK: Backfill

    /// R3 end to end: the activity row a source add now emits must be RICH ENOUGH to drive the
    /// Apple Music write-back backfill. This is the whole point of logging the DUPLICATE's id — a
    /// row naming the read-only source would resolve to no collection and recover nothing.
    @MainActor
    func testSourceAddActivityCanDriveTheWriteBackBackfill() async {
        let (s, cap) = await wired()
        var hooks: [CollectionsStore.ActivityHook] = []
        s.onActivity = { hooks.append($0) }
        let src = amSource("ipl_am", "AM Mix", ["sng_am1"])
        _ = s.addSong("sng_am2", toIndexPlaylist: src, appleMusicId: nil)
        XCTAssertEqual(hooks.count, 1)
        XCTAssertTrue(cap.calls.isEmpty, "the add path itself doesn't enqueue — the caller does")

        // Replay the hook exactly as the app wiring records it, then backfill from it.
        let now = 1_000_000_000_000.0
        let h = hooks[0]
        let ev = CollectionActivityStore.ActivityEvent(
            id: UUID(), at: now - 3_600_000, kind: .add, itemId: h.itemId, itemTitle: h.itemTitle,
            itemArtist: h.itemArtist, collectionId: h.collectionId, collectionKind: h.collectionKind,
            collectionName: h.collectionName, originInstallId: "A")
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 1)
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
    }

    @MainActor
    func testBackfillReDrivesRecentAddsAndIsIdempotent() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        // Simulate an add made BEFORE the write-back wiring: the low-level primitive fires no seam.
        s.addSong("sng_am2", toPocket: p.id)
        XCTAssertTrue(cap.calls.isEmpty)

        let now = 1_000_000_000_000.0
        let ev = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000)   // 1h ago (legacy origin = local)
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 1)
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
        // Idempotent: the seam already saw this pair, so a re-run queues nothing new.
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 0)
    }

    @MainActor
    func testBackfillIgnoresAddsOutsideTheWindow() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am2", toPocket: p.id)
        let now = 1_000_000_000_000.0
        let old = addEvent("sng_am2", in: p.id, atMs: now - 5 * 86_400_000)   // 5 days ago
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [old], days: 2, localInstallId: "A", nowMs: now), 0)
        XCTAssertTrue(cap.calls.isEmpty)
    }

    @MainActor
    func testBackfillSkipsSongRemovedSinceItsAdd() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        // An add event exists, but the song is NOT currently in the pocket (added then removed).
        let now = 1_000_000_000_000.0
        let ev = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000)
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 0)
        XCTAssertTrue(cap.calls.isEmpty)
    }

    @MainActor
    func testBackfillDaysAreClampedToNinety() async {
        let (s, _) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am2", toPocket: p.id)
        let now = 1_000_000_000_000.0
        // 80 days ago: outside a 2-day window, but inside the 90-day ceiling an over-large `days`
        // clamps to.
        let ev = addEvent("sng_am2", in: p.id, atMs: now - 80 * 86_400_000)
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 0)
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 1000, localInstallId: "A", nowMs: now), 1)
    }

    /// A PEER device's attributed add must NOT be re-driven here: its write-back already ran (or
    /// will) on that device, and re-delivering it would duplicate the track in the real Apple Music
    /// playlist (the write-back queue that dedups is device-local). A legacy event (nil origin) and
    /// this install's own events are re-driven; another install's are skipped.
    @MainActor
    func testBackfillSkipsPeerDeviceAddsButKeepsLocalAndLegacy() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        s.addSong("sng_am2", toPocket: p.id)      // present locally, not in snapshot
        s.addSong("sng_plain", toPocket: p.id)    // (no appleMusicId — never eligible anyway)
        let now = 1_000_000_000_000.0
        // Same song, added on a PEER install ("B"): must be skipped even though it's a local member.
        let peer = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000, origin: "B")
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [peer], days: 2, localInstallId: "A", nowMs: now), 0)
        XCTAssertTrue(cap.calls.isEmpty)
        // This install's own add ("A") IS re-driven.
        let mine = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000, origin: "A")
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [mine], days: 2, localInstallId: "A", nowMs: now), 1)
    }

    // MARK: Source-link carry-over (convert playlist→pocket) + re-link recovery

    /// The Levi flow: DUPLICATE an Apple Music list → editable playlist (provenance-stamped) →
    /// CONVERT that playlist to a pocket. The pocket must KEEP the Apple Music link (it used to be
    /// dropped, leaving adds unable to reach Apple Music).
    @MainActor
    func testConvertDuplicatedPlaylistToPocketCarriesProvenance() async {
        let (s, _) = await wired()
        let pl = s.createPlaylist("AM Mix", songIds: ["sng_am1"],
                                  source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        let p = s.convertToPocket(playlistId: pl.id)!
        XCTAssertEqual(p.sourcePlaylistId, "ipl_am")
        XCTAssertEqual(p.sourceName, Config.appleMusicSourceName)
        XCTAssertEqual(p.sourceSongIds, ["sng_am1"])
        XCTAssertTrue(p.syncsWithSource)
    }

    /// A PLAIN (non-duplicated) playlist has no source, so its pocket must NOT gain a phantom link.
    @MainActor
    func testConvertPlainPlaylistToPocketHasNoProvenance() async {
        let (s, _) = await wired()
        let pl = s.createPlaylist("Mine", songIds: ["sng_am1"])
        let p = s.convertToPocket(playlistId: pl.id)!
        XCTAssertFalse(p.hasSource)
        XCTAssertNil(p.sourcePlaylistId)
    }

    /// End-to-end for the carry-over: after convert, an add to that pocket writes back.
    @MainActor
    func testAddToPocketConvertedFromDuplicatedPlaylistWritesBack() async {
        let (s, cap) = await wired()
        let pl = s.createPlaylist("AM Mix", songIds: ["sng_am1"],
                                  source: amSource("ipl_am", "AM Mix", ["sng_am1"]))
        let p = s.convertToPocket(playlistId: pl.id)!
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(cap.calls.count, 1)
        XCTAssertEqual(cap.calls.first?.pid, "ipl_am")
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
    }

    /// Re-link an EXISTING unlinked pocket: stamps provenance (snapshot = source membership) and
    /// PRESERVES the user's own adds — the recovery for a pocket whose link was already lost.
    @MainActor
    func testLinkPocketToSourceStampsProvenanceAndPreservesUserAdds() async {
        let (s, _) = await wired()
        let p = s.createPocket("Trenches")
        s.addSong("sng_am2", toPocket: p.id)                    // user add, not in the source
        XCTAssertTrue(s.linkPocketToSource(p.id, source: amSource("ipl_am", "Trenches", ["sng_am1"])))
        let after = s.pocket(p.id)!
        XCTAssertEqual(after.sourcePlaylistId, "ipl_am")
        XCTAssertEqual(after.sourceName, Config.appleMusicSourceName)
        XCTAssertEqual(after.sourceSongIds, ["sng_am1"])        // snapshot = source membership
        XCTAssertTrue(after.songIds.contains("sng_am2"))        // user add survives
        XCTAssertTrue(after.syncsWithSource)
    }

    @MainActor
    func testLinkPocketToSourceMissingPocketIsNoOp() async {
        let (s, _) = await wired()
        XCTAssertFalse(s.linkPocketToSource("nope", source: amSource("ipl_am", "X", [])))
    }

    /// End-to-end recovery: a song added to a pocket BEFORE it was linked (so no write-back fired)
    /// is pushed once the pocket is linked and the backfill runs over its add history.
    @MainActor
    func testLinkedPocketBackfillPushesEarlierAdds() async {
        let (s, cap) = await wired()
        let p = s.createPocket("Trenches")
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))   // unlinked → nothing pushed
        XCTAssertTrue(cap.calls.isEmpty)
        let now = 1_000_000_000_000.0
        let ev = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000)  // its add-history event
        s.linkPocketToSource(p.id, source: amSource("ipl_am", "Trenches", ["sng_am1"]))
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 1)
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
    }

    /// Re-link a pocket that ALREADY has a source (the ⋯ ▸ "Re-link to Apple Music playlist…" path):
    /// repoints to the chosen playlist and RE-SNAPSHOTS its current membership, so a pocket song that
    /// a wrong/stale snapshot listed as "already upstream" becomes a write-back candidate again.
    @MainActor
    func testRelinkAlreadyLinkedPocketRepointsAndResnapshots() async {
        let (s, cap) = await wired()
        let p = s.createPocket("Trenches")
        // Wrongly linked to a list whose snapshot ALREADY lists sng_am2 → its add reads as upstream.
        s.linkPocketToSource(p.id, source: amSource("ipl_wrong", "Wrong List", ["sng_am1", "sng_am2"]))
        s.addSong("sng_am2", toPocket: p.id)
        XCTAssertEqual(s.pocket(p.id)!.sourcePlaylistId, "ipl_wrong")
        // Re-link to the correct playlist whose CURRENT membership is just sng_am1.
        XCTAssertTrue(s.linkPocketToSource(p.id, source: amSource("ipl_right", "Trenches", ["sng_am1"])))
        let after = s.pocket(p.id)!
        XCTAssertEqual(after.sourcePlaylistId, "ipl_right")      // repointed
        XCTAssertEqual(after.sourceSongIds, ["sng_am1"])         // re-snapshotted to new membership
        XCTAssertTrue(after.songIds.contains("sng_am2"))         // user add preserved
        // The earlier add is now a genuine write-back candidate under the corrected link.
        let now = 1_000_000_000_000.0
        let ev = addEvent("sng_am2", in: p.id, atMs: now - 3_600_000)
        XCTAssertEqual(s.backfillSourceWriteBacks(from: [ev], days: 2, localInstallId: "A", nowMs: now), 1)
        XCTAssertEqual(cap.calls.first?.sid, "sng_am2")
    }

    /// Re-linking a pocket to a DIFFERENT source cancels the OLD source's still-undelivered
    /// write-backs for the pocket's songs, so an add made while it was mis-linked can't land in the
    /// wrong Apple Music playlist.
    @MainActor
    func testRelinkCancelsPendingWriteBacksForOldSource() async {
        let (s, cap) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_old", "Old", ["sng_am1"]))
        s.addSong("sng_am2", to: AddTarget(kind: .pocket, id: p.id))
        s.linkPocketToSource(p.id, source: amSource("ipl_new", "New", ["sng_am1"]))
        XCTAssertEqual(cap.cancelCalls.count, 1)
        XCTAssertEqual(cap.cancelCalls.first?.pid, "ipl_old")            // the OLD source
        XCTAssertTrue(cap.cancelCalls.first?.songIds.contains("sng_am2") ?? false)
    }

    /// Re-linking must NOT silently re-enable "Sync with source" for a user who turned it off.
    @MainActor
    func testRelinkPreservesUserDisabledSync() async {
        let (s, _) = await wired()
        let p = s.convertToPocket(source: amSource("ipl_old", "Old", ["sng_am1"]))
        s.setSourceSyncEnabled(false, forPocket: p.id)
        XCTAssertFalse(s.pocket(p.id)!.syncsWithSource)
        s.linkPocketToSource(p.id, source: amSource("ipl_new", "New", ["sng_am1"]))
        XCTAssertFalse(s.pocket(p.id)!.syncsWithSource, "re-link must not flip sync back on")
    }
}
