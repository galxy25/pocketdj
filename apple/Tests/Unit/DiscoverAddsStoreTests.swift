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

    /// An INDEXED album carrying an appleMusicId (IndexAlbum is Decodable-only).
    private func indexedAlbum(id: String, appleMusicId: String) -> IndexAlbum {
        let obj: [String: Any] = ["id": id, "name": "N", "artist": "A", "trackList": [String](),
                                  "appleMusicId": appleMusicId]
        return try! JSONDecoder().decode(IndexAlbum.self, from: try! JSONSerialization.data(withJSONObject: obj))
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

    // MARK: Provisional ALBUM support

    func testAddAlbumRoundTripsAndInjects() {
        let s = store()
        var injected: [IndexAlbum] = []
        s.onAlbumAdded = { injected.append($0) }
        s.addAlbum(albumId: "amrec_album_1", appleMusicId: "1", title: "RAM", artist: "Daft Punk",
                   trackIds: ["amrec_10", "amrec_11"], artworkUrl: "https://a/1.jpg", year: 2013)
        // Idempotent per albumId.
        s.addAlbum(albumId: "amrec_album_1", appleMusicId: "1", title: "RAM", artist: "Daft Punk")
        XCTAssertEqual(s.albums.count, 1)
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected[0].id, "amrec_album_1")
        XCTAssertEqual(injected[0].appleMusicId, "1")
        XCTAssertEqual(injected[0].trackList, ["amrec_10", "amrec_11"])
        XCTAssertEqual(injected[0].year, 2013)
        // Round-trip on the same file.
        let reloaded = DiscoverAddsStore(fileURL: s.syncFileURL)
        XCTAssertEqual(reloaded.albums.map(\.albumId), ["amrec_album_1"])
        XCTAssertEqual(reloaded.albums.first?.trackIds, ["amrec_10", "amrec_11"])
    }

    /// WIPE-SAFETY: a document written before album support (NO `albums` key) must decode
    /// with every existing song entry intact — the schema-wipe lesson (albums is optional).
    func testOldDocumentWithoutAlbumsKeyDecodesIntact() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-old-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        { "schemaVersion": 1, "entries": [
            { "songId": "amrec_1", "appleMusicId": "1", "title": "Old", "artist": "X", "addedAtMs": 0 }
          ] }
        """
        try Data(legacy.utf8).write(to: url)
        let s = DiscoverAddsStore(fileURL: url)
        XCTAssertEqual(s.entries.map(\.songId), ["amrec_1"], "legacy song entries survive (no wipe)")
        XCTAssertTrue(s.albums.isEmpty)
        // Adding an album must not disturb the existing song entry on the next round-trip.
        s.addAlbum(albumId: "amrec_album_9", appleMusicId: "9", title: "New", artist: "Y")
        let reloaded = DiscoverAddsStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.songId), ["amrec_1"])
        XCTAssertEqual(reloaded.albums.map(\.albumId), ["amrec_album_9"])
    }

    func testSplitAlbumsSupersedesByAppleMusicId() {
        let albums = [
            DiscoverAddsStore.AlbumEntry(albumId: "amrec_album_1", appleMusicId: "1", title: "A", artist: "X", addedAtMs: 0),
            DiscoverAddsStore.AlbumEntry(albumId: "amrec_album_2", appleMusicId: "2", title: "B", artist: "Y", addedAtMs: 0),
        ]
        let split = DiscoverAddsStore.splitAlbums(albums, indexedByAppleMusicId: ["1": "alb_real1"])
        XCTAssertEqual(split.keep.map(\.albumId), ["amrec_album_2"])
        XCTAssertEqual(split.superseded.map(\.from), ["amrec_album_1"])
        XCTAssertEqual(split.superseded.map(\.to), ["alb_real1"])
        // An album claiming ITSELF must never self-supersede.
        let selfSplit = DiscoverAddsStore.splitAlbums(albums, indexedByAppleMusicId: ["1": "amrec_album_1"])
        XCTAssertEqual(selfSplit.keep.count, 2)
        XCTAssertTrue(selfSplit.superseded.isEmpty)
    }

    func testSyntheticIndexEmitsProvisionalAlbums() {
        let songs = [DiscoverAddsStore.Entry(songId: "amrec_10", appleMusicId: "10", title: "T", artist: "A", addedAtMs: 0)]
        let albums = [DiscoverAddsStore.AlbumEntry(albumId: "amrec_album_1", appleMusicId: "1", title: "RAM",
                                                   artist: "DP", trackIds: ["amrec_10"], addedAtMs: 0)]
        let idx = DiscoverAddsStore.syntheticIndex(songs, albums: albums)
        XCTAssertEqual(idx.albums.map(\.id), ["amrec_album_1"])
        XCTAssertEqual(idx.albums.first?.appleMusicId, "1")
        XCTAssertEqual(idx.songs.map(\.id), ["amrec_10"])
        // The default (song-only) overload still emits no albums — existing callers unchanged.
        XCTAssertTrue(DiscoverAddsStore.syntheticIndex(songs).albums.isEmpty)
    }

    /// supersede-by-appleMusicId REPLACES a provisional Discover album with the real indexed
    /// album (no duplicate) and reports the remap pair.
    func testWithProvisionalSourcesSupersedesProvisionalAlbum() {
        let albums = [
            DiscoverAddsStore.AlbumEntry(albumId: "amrec_album_6", appleMusicId: "6", title: "Landed",
                                         artist: "L", trackIds: [], addedAtMs: 0),
            DiscoverAddsStore.AlbumEntry(albumId: "amrec_album_7", appleMusicId: "7", title: "New",
                                         artist: "N", trackIds: [], addedAtMs: 0),
        ]
        let base = IndexJSON(manifest: Manifest(source: "t", generatedAt: nil, sourceName: "Test", counts: nil),
                             albums: [indexedAlbum(id: "alb_real6", appleMusicId: "6")], songs: [])
        let r = AppModel.withProvisionalSources(discover: [], discoverAlbums: albums,
                                                importedSongs: [], importedAlbums: [], indexes: [base])
        XCTAssertEqual(r.indexes.count, 2, "surviving album rides a synthetic source")
        XCTAssertEqual(r.indexes[1].manifest.sourceName, DiscoverAddsStore.sourceName)
        XCTAssertEqual(r.indexes[1].albums.map(\.id), ["amrec_album_7"], "landed album (6) excluded")
        XCTAssertEqual(r.discoverAlbumSuperseded.map(\.from), ["amrec_album_6"])
        XCTAssertEqual(r.discoverAlbumSuperseded.map(\.to), ["alb_real6"])
    }

    func testReloadFromDiskInjectsNewAlbums() {
        let s = store()
        s.addAlbum(albumId: "amrec_album_1", appleMusicId: "1", title: "A", artist: "X")
        let other = DiscoverAddsStore(fileURL: s.syncFileURL)
        other.addAlbum(albumId: "amrec_album_2", appleMusicId: "2", title: "B", artist: "Y")
        var injected: [String] = []
        s.onAlbumAdded = { injected.append($0.id) }
        s.reloadFromDisk()
        XCTAssertEqual(s.albums.map(\.albumId), ["amrec_album_1", "amrec_album_2"])
        XCTAssertEqual(injected, ["amrec_album_2"], "only the pulled-in album injects")
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
