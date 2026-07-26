import XCTest
@testable import PocketDJ

@MainActor
final class ProfileSourceStoreTests: XCTestCase {
    private func store() -> ProfileSourceStore {
        ProfileSourceStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-profile-\(UUID().uuidString).json"))
    }
    private func sample(_ id: String, _ title: String) -> ProfileSourceStore.SongEntry {
        .init(songId: id, title: title, kind: .sample, fileName: "\(id).m4a",
              durationMs: 2_000, bpm: 120, key: nil, camelot: "8A", addedAtMs: 0)
    }
    private func demux(_ id: String, _ title: String) -> ProfileSourceStore.SongEntry {
        .init(songId: id, title: title, kind: .demux, fileName: "\(id).m4a",
              durationMs: 180_000, bpm: 90, key: nil, camelot: nil, addedAtMs: 0)
    }

    /// An empty store still synthesizes BOTH default albums (the filing destinations), tagged with
    /// the profile name as source + artist.
    func testSyntheticIndexSeedsTwoDefaultAlbums() {
        let idx = ProfileSourceStore.syntheticIndex(songs: [], profileName: "Levi")
        XCTAssertEqual(idx.manifest.sourceName, "Levi")
        XCTAssertEqual(idx.manifest.source, "profile-source")
        XCTAssertEqual(Set(idx.albums.map(\.id)),
                       [ProfileSourceStore.samplesAlbumId, ProfileSourceStore.demuxesAlbumId])
        XCTAssertEqual(idx.albums.first { $0.id == ProfileSourceStore.samplesAlbumId }?.name,
                       "Pocket DJ Samples")
        XCTAssertTrue(idx.albums.allSatisfy { $0.artist == "Levi" })
        XCTAssertTrue(idx.albums.allSatisfy { $0.trackList.isEmpty })
        XCTAssertTrue(idx.songs.isEmpty)
    }

    /// A sample files into "Pocket DJ Samples", a demux into "Pocket DJ Demuxes"; artist = profile.
    func testKindRoutesToDefaultAlbumAndArtistIsProfile() {
        let idx = ProfileSourceStore.syntheticIndex(
            songs: [sample("pdj_s", "Kick"), demux("pdj_d", "Track — Vox")], profileName: "DJ Nova")
        XCTAssertEqual(idx.songs.first { $0.id == "pdj_s" }?.artist, "DJ Nova")
        XCTAssertEqual(idx.songs.first { $0.id == "pdj_s" }?.albumId, ProfileSourceStore.samplesAlbumId)
        XCTAssertEqual(idx.songs.first { $0.id == "pdj_d" }?.albumId, ProfileSourceStore.demuxesAlbumId)
        XCTAssertEqual(idx.albums.first { $0.id == ProfileSourceStore.samplesAlbumId }?.trackList, ["pdj_s"])
        XCTAssertEqual(idx.albums.first { $0.id == ProfileSourceStore.demuxesAlbumId }?.trackList, ["pdj_d"])
    }

    /// add() dedupes by id, persists, and fires onAdded with the fresh rows + rebuilt albums; a new
    /// store from the same URL reloads them.
    func testAddPersistsDedupesAndFiresOnAdded() {
        let s = store()
        var addedSongs: [IndexSong] = [], addedAlbums: [IndexAlbum] = []
        s.onAdded = { songs, albums in addedSongs = songs; addedAlbums = albums }
        s.profileName = "Levi"
        s.add([sample("pdj_a", "A"), demux("pdj_b", "B")])
        s.add([sample("pdj_a", "A")])   // dup id ⇒ ignored
        XCTAssertEqual(s.songs.map(\.songId), ["pdj_a", "pdj_b"])
        XCTAssertEqual(addedSongs.map(\.id), ["pdj_a", "pdj_b"])
        XCTAssertEqual(addedSongs.first?.artist, "Levi")
        XCTAssertEqual(Set(addedAlbums.map(\.id)),
                       [ProfileSourceStore.samplesAlbumId, ProfileSourceStore.demuxesAlbumId])

        let reloaded = ProfileSourceStore(fileURL: s.syncFileURL)
        XCTAssertEqual(reloaded.songs.map(\.songId), ["pdj_a", "pdj_b"])
    }

    /// sourceName falls back to the default when the profile is unnamed / blank.
    func testSourceNameFallsBackToDefault() {
        let s = store()
        s.profileName = "   "
        XCTAssertEqual(s.sourceName, ProfileSourceStore.defaultName)
        s.profileName = "Nova"
        XCTAssertEqual(s.sourceName, "Nova")
    }
}
