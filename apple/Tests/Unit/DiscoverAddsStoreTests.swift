import XCTest
@testable import PocketDJ

/// Discover eventual consistency: "＋ Add" lands a provisional catalog entry NOW; the
/// nightly indexer's real entry supersedes it later and collection references follow.
@MainActor
final class DiscoverAddsStoreTests: XCTestCase {

    private func store() -> DiscoverAddsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DiscoverAddsStore(fileURL: url)
    }

    /// An INDEXED song carrying an appleMusicId (IndexSong is Decodable-only).
    private func indexedSong(id: String, appleMusicId: String) -> IndexSong {
        let obj: [String: Any] = ["id": id, "name": "T", "artist": "A", "appleMusicId": appleMusicId]
        return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: obj))
    }

    func testAddIsIdempotentPersistsAndInjects() {
        let s = store()
        var injected: [IndexSong] = []
        s.onAdded = { injected.append($0) }
        s.add(songId: "amrec_1", appleMusicId: "1", title: "Witchy", artist: "KAYTRANADA",
              durationMs: 222_000)
        s.add(songId: "amrec_1", appleMusicId: "1", title: "Witchy", artist: "KAYTRANADA")
        XCTAssertEqual(s.entries.count, 1, "same songId adds once")
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected[0].id, "amrec_1")
        XCTAssertEqual(injected[0].name, "Witchy")
        XCTAssertEqual(injected[0].length, 222_000)
        XCTAssertEqual(injected[0].appleMusicId, "1")
        // Round-trip: a fresh store on the same file decodes the entry.
        let reloaded = DiscoverAddsStore(fileURL: s.syncFileURL)
        XCTAssertEqual(reloaded.entries.map(\.songId), ["amrec_1"])
    }

    func testSplitSupersedesByAppleMusicId() {
        let entries = [
            DiscoverAddsStore.Entry(songId: "amrec_1", appleMusicId: "1", title: "A", artist: "X", addedAtMs: 0),
            DiscoverAddsStore.Entry(songId: "amrec_2", appleMusicId: "2", title: "B", artist: "Y", addedAtMs: 0),
        ]
        // Indexed catalog knows storeId 1 as a REAL entry; storeId 2 is still provisional.
        let split = DiscoverAddsStore.split(entries, indexedByAppleMusicId: ["1": "sng_real1"])
        XCTAssertEqual(split.keep.map(\.songId), ["amrec_2"])
        XCTAssertEqual(split.superseded.map(\.from), ["amrec_1"])
        XCTAssertEqual(split.superseded.map(\.to), ["sng_real1"])
        // The provisional id claiming ITSELF (the synthetic source in a later pass)
        // must never self-supersede.
        let selfSplit = DiscoverAddsStore.split(entries, indexedByAppleMusicId: ["1": "amrec_1"])
        XCTAssertEqual(selfSplit.keep.count, 2)
        XCTAssertTrue(selfSplit.superseded.isEmpty)
    }

    func testWithDiscoverAddsFoldsSyntheticSourceAndReportsSupersede() {
        let provisional = [
            DiscoverAddsStore.Entry(songId: "amrec_5", appleMusicId: "5", title: "New", artist: "N", addedAtMs: 0),
            DiscoverAddsStore.Entry(songId: "amrec_6", appleMusicId: "6", title: "Landed", artist: "L", addedAtMs: 0),
        ]
        let base = IndexJSON(manifest: Manifest(source: "t", generatedAt: nil, sourceName: "Test", counts: nil),
                             albums: [], songs: [indexedSong(id: "am_real6", appleMusicId: "6")])
        let (indexes, superseded) = AppModel.withDiscoverAdds(provisional, indexes: [base])
        XCTAssertEqual(indexes.count, 2, "surviving adds ride a synthetic source")
        XCTAssertEqual(indexes[1].manifest.sourceName, DiscoverAddsStore.sourceName)
        XCTAssertEqual(indexes[1].songs.map(\.id), ["amrec_5"])
        XCTAssertEqual(superseded.map(\.from), ["amrec_6"])
        XCTAssertEqual(superseded.map(\.to), ["am_real6"])
        // No provisional entries → untouched.
        let (same, none) = AppModel.withDiscoverAdds([], indexes: [base])
        XCTAssertEqual(same.count, 1)
        XCTAssertTrue(none.isEmpty)
    }

    func testReloadFromDiskInjectsOnlyNewEntries() {
        let s = store()
        s.add(songId: "amrec_1", appleMusicId: "1", title: "A", artist: "X")
        // A second store writing to the same file simulates a cloud pull landing a new doc.
        let other = DiscoverAddsStore(fileURL: s.syncFileURL)
        other.add(songId: "amrec_2", appleMusicId: "2", title: "B", artist: "Y")
        var injected: [String] = []
        s.onAdded = { injected.append($0.id) }
        s.reloadFromDisk()
        XCTAssertEqual(s.entries.map(\.songId), ["amrec_1", "amrec_2"])
        XCTAssertEqual(injected, ["amrec_2"], "only the pulled-in entry injects")
    }

    // MARK: Collections remap

    func testRemapSongIdsWalksPlaylistsPocketsSetlists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-col-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let c = CollectionsStore(fileURL: url)

        let pl = c.createPlaylist("P", songIds: ["amrec_9"])
        let pk = c.createPocket("K", songIds: ["amrec_9", "sng_other"])
        c.setSongRepeat("amrec_9", count: 3, inPocket: pk.id)
        let sl = c.materializeNowPlayingSetlist(
            name: "S", queue: [(id: "amrec_9", title: "T", artist: "X", lengthMs: nil, repeatCount: nil)])
        XCTAssertNotNil(sl)

        c.remapSongIds([(from: "amrec_9", to: "am_real9")])

        func songLeaves(_ nodes: [PlaylistNode]) -> [String] {
            nodes.flatMap { n -> [String] in
                (n.songId.map { [$0] } ?? []) + songLeaves(n.children ?? [])
            }
        }
        XCTAssertEqual(songLeaves(c.playlist(pl.id)!.sequences), ["am_real9"])
        XCTAssertEqual(c.pocket(pk.id)!.songIds, ["am_real9", "sng_other"])
        XCTAssertEqual(c.pocket(pk.id)!.songRepeats["am_real9"], 3)
        XCTAssertNil(c.pocket(pk.id)!.songRepeats["amrec_9"])
        XCTAssertEqual(c.setlist(sl!.id)!.tracks.map(\.songId), ["am_real9"])
        // And it persisted.
        let reloaded = CollectionsStore(fileURL: url)
        XCTAssertEqual(reloaded.pocket(pk.id)?.songIds.first, "am_real9")
    }
}
