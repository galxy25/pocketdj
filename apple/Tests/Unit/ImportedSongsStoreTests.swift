import XCTest
@testable import PocketDJ

/// ImportedSongsStore — provisional entries for cross-user transfers: batch add /
/// persistence / live-injection, catalog synthesis, and the amrec_-only supersede
/// (exact-id twins are SHADOWED by merge order, never pruned — R10).
@MainActor
final class ImportedSongsStoreTests: XCTestCase {

    private func store() -> ImportedSongsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-imported-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ImportedSongsStore(fileURL: url)
    }

    private func songEntry(_ id: String, title: String = "T", am: String? = nil) -> ImportedSongsStore.SongEntry {
        ImportedSongsStore.SongEntry(songId: id, title: title, artist: "A",
                                     albumId: nil, album: nil, artworkUrl: nil,
                                     durationMs: 200_000, bpm: 120, key: "A minor",
                                     camelot: "8A", year: 1999, appleMusicId: am, addedAtMs: 0)
    }

    func testBatchAddIsIdempotentPersistsAndInjectsOnce() {
        let s = store()
        var injectedSongs: [[IndexSong]] = []
        var injectedAlbums: [[IndexAlbum]] = []
        s.onAdded = { songs, albums in injectedSongs.append(songs); injectedAlbums.append(albums) }

        let album = ImportedSongsStore.AlbumEntry(albumId: "alb_x", name: "LP", artist: "A",
                                                  trackIds: ["sng_1", "sng_2"],
                                                  artworkUrl: "https://art/x.jpg",
                                                  genre: "Soul", year: 1999, addedAtMs: 0)
        s.add(songs: [songEntry("sng_1"), songEntry("sng_2")], albums: [album])
        s.add(songs: [songEntry("sng_1")], albums: [album])   // dup — no second injection

        XCTAssertEqual(s.songs.map(\.songId), ["sng_1", "sng_2"])
        XCTAssertEqual(s.albums.map(\.albumId), ["alb_x"])
        XCTAssertEqual(injectedSongs.count, 1, "one batch injection; dup add injects nothing")
        XCTAssertEqual(injectedSongs[0].map(\.id), ["sng_1", "sng_2"])
        XCTAssertEqual(injectedAlbums[0].map(\.id), ["alb_x"])

        // Round-trip: a fresh store on the same file decodes both arrays.
        let reloaded = ImportedSongsStore(fileURL: s.syncFileURL)
        XCTAssertEqual(reloaded.songs.map(\.songId), ["sng_1", "sng_2"])
        XCTAssertEqual(reloaded.albums.map(\.albumId), ["alb_x"])
    }

    func testReloadFromDiskSurfacesOnlyNewEntries() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-imported-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = ImportedSongsStore(fileURL: url)
        writer.add(songs: [songEntry("sng_1")])

        let reader = ImportedSongsStore(fileURL: url)
        var injected: [[IndexSong]] = []
        reader.onAdded = { songs, _ in injected.append(songs) }
        writer.add(songs: [songEntry("sng_2")])   // simulates a cloud pull writing the file
        reader.reloadFromDisk()
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected[0].map(\.id), ["sng_2"], "pre-existing sng_1 not re-injected")
    }

    func testCatalogSynthesis() {
        let song = ImportedSongsStore.indexSong(songEntry("sng_9", am: "12345"))
        XCTAssertEqual(song.id, "sng_9")
        XCTAssertEqual(song.length, 200_000)
        XCTAssertEqual(song.bpm, 120)
        XCTAssertEqual(song.camelot, "8A")
        XCTAssertEqual(song.appleMusicId, "12345")

        let album = ImportedSongsStore.indexAlbum(
            .init(albumId: "alb_1", name: "LP", artist: "A", trackIds: ["sng_9"],
                  artworkUrl: "https://x/y.jpg", genre: "Soul", year: 2001, addedAtMs: 0))
        XCTAssertEqual(album.trackList, ["sng_9"])
        XCTAssertEqual(album.artCandidates.first?.absoluteString, "https://x/y.jpg")

        let index = ImportedSongsStore.syntheticIndex(songs: [songEntry("sng_9")],
                                                      albums: [])
        XCTAssertEqual(index.manifest.sourceName, ImportedSongsStore.sourceName)
        XCTAssertEqual(index.songs.map(\.id), ["sng_9"])
    }

    /// R10: only amrec_ ids remap by appleMusicId; catalog sng_ ids keep their exact
    /// identity even when a local twin claims the same appleMusicId.
    func testSupersedePairsAreAmrecOnly() {
        let entries = [
            songEntry("amrec_11", am: "11"),
            songEntry("sng_22", am: "22"),
            songEntry("amrec_33", am: nil),
        ]
        let pairs = ImportedSongsStore.supersedePairs(
            entries, indexedByAppleMusicId: ["11": "sng_real11", "22": "sng_real22"])
        XCTAssertEqual(pairs.map(\.from), ["amrec_11"])
        XCTAssertEqual(pairs.map(\.to), ["sng_real11"])

        // Self-claim never self-supersedes.
        let selfPairs = ImportedSongsStore.supersedePairs(
            [songEntry("amrec_11", am: "11")], indexedByAppleMusicId: ["11": "amrec_11"])
        XCTAssertTrue(selfPairs.isEmpty)
    }

    func testRemoveDropsOnlyNamedSongs() {
        let s = store()
        s.add(songs: [songEntry("amrec_1"), songEntry("sng_2")])
        s.remove(songIds: ["amrec_1"])
        XCTAssertEqual(s.songs.map(\.songId), ["sng_2"])
    }
}
