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
}
