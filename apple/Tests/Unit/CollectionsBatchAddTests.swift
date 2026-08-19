import XCTest
@testable import PocketDJ

/// `CollectionsStore.addSongs(_:to:)` — the drag-&-drop / paste / multi-select batch add:
/// one document write, dedup against membership (pocket) / existing song nodes (playlist),
/// default-chapter routing, MRU stamped once, one activity event per ADDED id.
@MainActor
final class CollectionsBatchAddTests: XCTestCase {

    private func makeStore(_ name: String = #function) -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-batchadd-\(name)-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        return CollectionsStore(fileURL: url)
    }

    private func playlistSongIds(_ store: CollectionsStore, _ id: String, chapter: Int = 0) -> [String] {
        (store.playlist(id)?.sequences[chapter].children ?? []).compactMap(\.songId)
    }

    func testAddSongsToPocketDedupsAgainstMembershipAndWithinBatch() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        store.addSong("sng_1", toPocket: p.id)
        let added = store.addSongs(["sng_1", "sng_2", "sng_2", "sng_3"],
                                   to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.pocket(p.id)?.songIds, ["sng_1", "sng_2", "sng_3"])
    }

    func testAddSongsToPocketAppendsInOrder() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        _ = store.addSongs(["sng_3", "sng_1", "sng_2"], to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(store.pocket(p.id)?.songIds, ["sng_3", "sng_1", "sng_2"])
    }

    func testAddSongsToPlaylistSkipsExistingSongNodes() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSong("sng_1", toPlaylist: pl.id)
        let added = store.addSongs(["sng_1", "sng_2"], to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(added, 1)
        XCTAssertEqual(playlistSongIds(store, pl.id), ["sng_1", "sng_2"])
    }

    func testAddSongsToPlaylistTargetsDefaultChapterWhenNoSequenceId() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        _ = store.addSongs(["sng_1"], to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 0), ["sng_1"])
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 1), [])
    }

    func testAddSongsToNamedChapter() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        _ = store.addSongs(["sng_1", "sng_2"],
                           to: AddTarget(kind: .playlist, id: pl.id, sequenceId: chapterId))
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 0), [])
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 1), ["sng_1", "sng_2"])
    }

    /// Dedup against nodes in ANY chapter — a song already in chapter 2 is not re-added
    /// to the default chapter by a drop.
    func testAddSongsToPlaylistDedupsAcrossChapters() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        store.addSong("sng_1", toPlaylist: pl.id, sequenceId: chapterId)
        let added = store.addSongs(["sng_1", "sng_2"], to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(added, 1)
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 0), ["sng_2"])
    }

    func testAddSongsStampsRecentAndLastTargetOnce() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        let target = AddTarget(kind: .pocket, id: p.id)
        _ = store.addSongs(["sng_1", "sng_2", "sng_3"], to: target)
        XCTAssertEqual(store.lastAddTarget, target)
        XCTAssertEqual(store.recentAddTargets.filter { $0.kind == .pocket && $0.id == p.id }.count, 1)
    }

    func testAddSongsReturnsZeroOnAllDuplicatesAndDoesNotTouchUpdatedAt() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        store.addSong("sng_1", toPocket: p.id)
        let before = store.pocket(p.id)!.updatedAt
        var events = 0
        store.onActivity = { _ in events += 1 }
        let added = store.addSongs(["sng_1", "sng_1"], to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.pocket(p.id)!.updatedAt, before)
        XCTAssertEqual(events, 0)                                 // nothing added ⇒ no activity
        XCTAssertEqual(store.pocket(p.id)?.songIds, ["sng_1"])
    }

    func testAddSongsEmitsOneActivityPerAddedId() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSong("sng_1", toPlaylist: pl.id)
        var added: [String] = []
        store.onActivity = { hook in
            XCTAssertEqual(hook.kind, .add)
            XCTAssertEqual(hook.collectionId, pl.id)
            added.append(hook.itemId)
        }
        _ = store.addSongs(["sng_1", "sng_2", "sng_3"], to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(added, ["sng_2", "sng_3"])                 // only the NEW ids, in order
    }

    /// Studio ids ride the same string plumbing verbatim (prefix-agnostic doctrine).
    func testAddSongsCarriesStudioIdsVerbatim() {
        let store = makeStore()
        let p = store.createPocket("Perf")
        let added = store.addSongs(["smp_abc", "sng_1"], to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.pocket(p.id)?.songIds, ["smp_abc", "sng_1"])
    }

    // MARK: Chapter-scoped dedupe (the Add-to sheet's deliberate-duplication path)

    /// `.targetChapter` dedupe: a song already in ANOTHER chapter still lands in the chosen
    /// one — parity with the single-song sheet path, which never dedups. (`.wholeCollection`
    /// stays the drop/paste default, pinned by testAddSongsToPlaylistDedupsAcrossChapters.)
    func testAddSongsTargetChapterDedupePlacesCrossChapterDuplicate() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        store.addSong("sng_1", toPlaylist: pl.id)                    // chapter 0 member
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        let added = store.addSongs(["sng_1", "sng_2"],
                                   to: AddTarget(kind: .playlist, id: pl.id, sequenceId: chapterId),
                                   dedupe: .targetChapter)
        XCTAssertEqual(added, 2)                                     // sng_1 deliberately duplicated
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 0), ["sng_1"])
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 1), ["sng_1", "sng_2"])
    }

    func testAddSongsTargetChapterStillDedupsWithinThatChapter() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        store.addSong("sng_1", toPlaylist: pl.id, sequenceId: chapterId)
        let added = store.addSongs(["sng_1"],
                                   to: AddTarget(kind: .playlist, id: pl.id, sequenceId: chapterId),
                                   dedupe: .targetChapter)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 1), ["sng_1"])
    }

    // MARK: Empty-chapter self-heal (lossy decode / foreign import)

    /// A playlist that decoded with NO chapters ("sequences": [] — reachable via lossy decode
    /// of an unknown node kind, or a doctored import) self-heals the default chapter instead
    /// of reporting a phantom success (the old guard bailed inside the mutation but still
    /// stamped MRU, emitted History rows, and would have queued Apple Music write-backs).
    func testAddSongsSelfHealsEmptySequencesAndReportsTruthfully() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-batchadd-heal-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let seed = CollectionsStore(fileURL: url)
        let pl = seed.createPlaylist("Set")
        seed.flushDocumentNow()   // save() encodes+writes async now; land it before doctoring the file
        // Doctor the on-disk document into the representable-but-never-UI-minted state.
        var doc = try CollectionsCodec.decode(Data(contentsOf: url))
        doc.playlists[0].sequences = []
        try CollectionsCodec.encode(doc).write(to: url)

        let store = CollectionsStore(fileURL: url)
        XCTAssertEqual(store.playlist(pl.id)?.sequences.count, 0)    // precondition holds
        var emitted = 0
        store.onActivity = { _ in emitted += 1 }
        let added = store.addSongs(["sng_1", "sng_2"], to: AddTarget(kind: .playlist, id: pl.id))
        XCTAssertEqual(added, 2)                                     // healed AND landed
        XCTAssertEqual(store.playlist(pl.id)?.sequences.count, 1)
        XCTAssertEqual(playlistSongIds(store, pl.id), ["sng_1", "sng_2"])
        XCTAssertEqual(emitted, 2)                                   // History told the truth
    }

    // MARK: Batch activity emission (ONE log write per gesture)

    /// With the batch seam wired, N added songs emit ONE batch (and zero per-id hooks) —
    /// the recorder does one document write for the whole gesture.
    func testAddSongsEmitsOneBatchWhenWired() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        var batches: [[CollectionsStore.ActivityHook]] = []
        var singles = 0
        store.onActivityBatch = { batches.append($0) }
        store.onActivity = { _ in singles += 1 }
        _ = store.addSongs(["sng_1", "sng_2", "sng_3"], to: AddTarget(kind: .pocket, id: p.id))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.itemId), ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(singles, 0)
    }

    // MARK: Batch removes (the Add sheet's multi-song toggle-OFF)

    func testRemoveSongsFromPocketBatchesAndSkipsNonMembers() {
        let store = makeStore()
        let p = store.createPocket("Crate")
        _ = store.addSongs(["sng_1", "sng_2", "sng_3"], to: AddTarget(kind: .pocket, id: p.id))
        var batches: [[CollectionsStore.ActivityHook]] = []
        store.onActivityBatch = { batches.append($0) }
        store.removeSongs(["sng_1", "sng_3", "sng_missing"], fromPocket: p.id)
        XCTAssertEqual(store.pocket(p.id)?.songIds, ["sng_2"])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.itemId), ["sng_1", "sng_3"])  // only actual members
        XCTAssertTrue(batches[0].allSatisfy { $0.kind == .remove })
    }

    /// The batch membership set: every chapter's `.song` nodes, one tree walk — what the
    /// Add-to sheet's `.songs` checkmark resolves against instead of per-id tree walks.
    func testPlaylistSongIdSetCoversAllChapters() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        store.addSong("sng_1", toPlaylist: pl.id)
        store.addSong("sng_2", toPlaylist: pl.id, sequenceId: chapterId)
        XCTAssertEqual(store.playlistSongIdSet(pl.id), ["sng_1", "sng_2"])
        XCTAssertEqual(store.playlistSongIdSet("pl_missing"), [])
    }

    func testRemoveSongsFromPlaylistClearsEveryChapter() {
        let store = makeStore()
        let pl = store.createPlaylist("Set")
        store.addSequence("B side", toPlaylist: pl.id)
        let chapterId = store.playlist(pl.id)!.sequences[1].nodeId
        store.addSong("sng_1", toPlaylist: pl.id)
        store.addSong("sng_1", toPlaylist: pl.id, sequenceId: chapterId)
        store.addSong("sng_2", toPlaylist: pl.id)
        store.removeSongs(["sng_1", "sng_9"], fromPlaylist: pl.id)
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 0), ["sng_2"])
        XCTAssertEqual(playlistSongIds(store, pl.id, chapter: 1), [])
    }
}
