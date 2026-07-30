import XCTest
@testable import PocketDJ

/// The on-device "Apple Music" library source (public-mode data-source parity): entry → catalog
/// row mapping, the supersede split against an indexed twin, album grouping, playlist mirrors
/// riding `syntheticIndex`, and the incremental/replace/persist lifecycle. The MusicKit
/// enumeration itself is device-only (sim can't authorize) and is exercised on-device.
@MainActor
final class AppleMusicLibraryStoreTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func entry(_ n: Int, am: String? = nil, album: String? = nil,
                       track: Int? = nil, addedMs: Double = 1000) -> AppleMusicLibraryStore.SongEntry {
        .init(songId: "amlib_i.s\(n)", libraryId: "i.s\(n)", appleMusicId: am,
              title: "Song \(n)", artist: "Artist",
              album: album, albumId: album.map { AppleMusicLibraryIndexer.albumId(title: $0, artist: "Artist") },
              artworkUrl: nil, durationMs: 200_000, trackNumber: track, year: 2024,
              genre: "Rock", addedAtMs: addedMs)
    }

    /// Entry → IndexSong carries the catalog id (streaming), dateAdded (Recently-added), and the
    /// album/track fields the Browser sorts on.
    func testIndexSongMapping() {
        let song = AppleMusicLibraryStore.indexSong(entry(1, am: "12345", album: "LP", track: 3))
        XCTAssertEqual(song.id, "amlib_i.s1")
        XCTAssertEqual(song.appleMusicId, "12345")
        XCTAssertEqual(song.dateAdded, 1000)
        XCTAssertEqual(song.trackNumber, 3)
        XCTAssertEqual(song.length, 200_000)
        XCTAssertNotNil(song.albumId)
    }

    /// The synthetic index emits PLAYLIST mirrors — the first injection source to do so; they
    /// land in `app.indexPlaylists` automatically via the standard sourcePlaylists path.
    func testSyntheticIndexCarriesPlaylists() {
        let songs = [entry(1, am: "111"), entry(2, am: "222")]
        let index = AppleMusicLibraryStore.syntheticIndex(
            songs: songs, albums: [],
            playlists: [.init(id: "amlibpl_p1", name: "Road Trip", songIds: songs.map(\.songId))])
        XCTAssertEqual(index.manifest.sourceName, "Apple Music")
        XCTAssertEqual(index.playlists?.count, 1)
        XCTAssertEqual(index.playlists?.first?.songIds, ["amlib_i.s1", "amlib_i.s2"])
    }

    /// Supersede: an indexed twin (the private catalog landing the same catalog id) claims the
    /// row — the on-device entry yields with a remap pair; entries without a catalog id stay.
    func testSplitYieldsToIndexedTwin() {
        let entries = [entry(1, am: "111"), entry(2, am: "222"), entry(3, am: nil)]
        let split = AppleMusicLibraryStore.split(entries, indexedByAppleMusicId: ["222": "sng_abc"])
        XCTAssertEqual(split.keep.map(\.songId), ["amlib_i.s1", "amlib_i.s3"])
        XCTAssertEqual(split.superseded.count, 1)
        XCTAssertEqual(split.superseded.first?.from, "amlib_i.s2")
        XCTAssertEqual(split.superseded.first?.to, "sng_abc")
    }

    /// withProvisionalSources folds the source in AFTER real sources, prunes superseded rows,
    /// and REMAPS playlist-mirror song ids onto the indexed twins so mirrors stay playable.
    /// `amLibrarySupersedes: true` = the OWNER path (in production only `OwnerIdentity.isOwner()`
    /// sets it; the default is `false` so a hybrid user never supersedes — see the two tests below).
    func testProvisionalMergeRemapsPlaylistMirrors() throws {
        let indexed = try JSONDecoder().decode(IndexJSON.self, from: Data("""
        {"manifest":{"source":"am-local","sourceName":"Apple Music (Local)"},
         "albums":[],
         "songs":[{"id":"sng_abc","name":"Song 2","artist":"Artist","appleMusicId":"222"}]}
        """.utf8))
        let entries = [entry(1, am: "111"), entry(2, am: "222")]
        let result = AppModel.withProvisionalSources(
            discover: [], importedSongs: [], importedAlbums: [],
            amLibrarySongs: entries, amLibraryAlbums: [],
            amLibraryPlaylists: [.init(id: "amlibpl_p1", name: "Mix", songIds: ["amlib_i.s1", "amlib_i.s2"])],
            amLibrarySupersedes: true, indexes: [indexed])
        XCTAssertEqual(result.amLibrarySuperseded.count, 1)
        let synthetic = result.indexes.last
        XCTAssertEqual(synthetic?.manifest.sourceName, "Apple Music")
        XCTAssertEqual(synthetic?.songs.map(\.id), ["amlib_i.s1"])           // superseded row pruned
        XCTAssertEqual(synthetic?.playlists?.first?.songIds, ["amlib_i.s1", "sng_abc"])  // mirror remapped
    }

    /// HYBRID user (integrity audit): a non-owner passes `amLibrarySupersedes: false` (only
    /// `OwnerIdentity.isOwner()` sets it true), so the library NEVER supersedes onto an indexed
    /// twin — a song the user owns that the curator's shared catalog also carries keeps its OWN
    /// row + id + dateAdded. The shared twin here is deliberately named "Apple Music (Local)" —
    /// the SAME sourceName the owner's own index uses — to prove the sourceName scope alone can't
    /// distinguish "mine" from "the curator's": it is the owner GATE (this flag), not the name,
    /// that protects the hybrid user's data.
    func testPublicModeNeverSupersedes() throws {
        let sharedAM = try JSONDecoder().decode(IndexJSON.self, from: Data("""
        {"manifest":{"source":"am-local","sourceName":"Apple Music (Local)"},
         "albums":[],"songs":[{"id":"sng_abc","name":"S","artist":"A","appleMusicId":"222"}]}
        """.utf8))
        let entries = [entry(1, am: "111"), entry(2, am: "222")]
        let result = AppModel.withProvisionalSources(
            discover: [], importedSongs: [], importedAlbums: [],
            amLibrarySongs: entries, amLibraryAlbums: [],
            amLibrarySupersedes: false, indexes: [sharedAM])   // public/hybrid
        XCTAssertTrue(result.amLibrarySuperseded.isEmpty, "no supersede in public mode")
        XCTAssertEqual(result.indexes.last?.songs.map(\.id), ["amlib_i.s1", "amlib_i.s2"],
                       "the user's own row survives even though a shared catalog shares its id")
    }

    /// Even in PRIVATE mode the supersede is scoped to the user's own "Apple Music (Local)"
    /// catalog — a shared "My Vinyl" row carrying the same backfilled appleMusicId must NOT eat
    /// the user's library row (the exact hybrid data-loss case).
    func testSupersedeScopedToOwnAppleMusicSourceOnly() throws {
        let vinyl = try JSONDecoder().decode(IndexJSON.self, from: Data("""
        {"manifest":{"source":"vinyl","sourceName":"My Vinyl"},
         "albums":[],"songs":[{"id":"sng_v","name":"S","artist":"A","appleMusicId":"222"}]}
        """.utf8))
        let entries = [entry(2, am: "222")]
        let result = AppModel.withProvisionalSources(
            discover: [], importedSongs: [], importedAlbums: [],
            amLibrarySongs: entries, amLibraryAlbums: [],
            amLibrarySupersedes: true, indexes: [vinyl])   // private, but twin is a shared vinyl row
        XCTAssertTrue(result.amLibrarySuperseded.isEmpty, "vinyl is not the user's own AM library")
        XCTAssertEqual(result.indexes.last?.songs.map(\.id), ["amlib_i.s2"])
    }

    /// Album grouping: deterministic ids, tracks ordered by trackNumber, art/year adopted.
    func testGroupAlbumsOrdersTracks() {
        let songs = [entry(1, album: "LP", track: 2), entry(2, album: "LP", track: 1),
                     entry(3, album: nil)]
        let albums = AppleMusicLibraryIndexer.groupAlbums(songs)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.trackIds, ["amlib_i.s2", "amlib_i.s1"])
        // Deterministic id — stable across devices for the cloud-synced doc.
        XCTAssertEqual(albums.first?.albumId, AppleMusicLibraryIndexer.albumId(title: "LP", artist: "Artist"))
    }

    /// replaceAll persists + hydrates; applyIncremental appends new songs idempotently and
    /// advances the high-water mark; remove prunes songs and drops emptied albums.
    func testLifecyclePersistsAndIncrements() {
        let url = tempURL("amlib")
        let store = AppleMusicLibraryStore(fileURL: url)
        store.replaceAll(songs: [entry(1, am: "111", album: "LP", track: 1)],
                         albums: AppleMusicLibraryIndexer.groupAlbums([entry(1, am: "111", album: "LP", track: 1)]),
                         playlists: [], lastAddedMs: 1000)
        XCTAssertEqual(AppleMusicLibraryStore(fileURL: url).songs.count, 1)

        store.applyIncremental(songs: [entry(1, am: "111"), entry(2, am: "222", addedMs: 2000)],
                               albums: [], playlists: [], lastAddedMs: 2000)
        XCTAssertEqual(store.songs.count, 2)                    // entry 1 deduped
        XCTAssertEqual(store.lastAddedMs, 2000)

        // supersede drops the row AND carries its add-time forward keyed by the surviving twin.
        store.supersede(pairs: [(from: "amlib_i.s1", to: "sng_indexed")])
        XCTAssertEqual(store.songs.map(\.songId), ["amlib_i.s2"])
        XCTAssertTrue(store.albums.isEmpty)                     // emptied album dropped
        XCTAssertEqual(store.supersededAddedAt["sng_indexed"], 1000)  // user's add-time preserved
        // Survives reload (persisted in the Document).
        XCTAssertEqual(AppleMusicLibraryStore(fileURL: url).supersededAddedAt["sng_indexed"], 1000)
    }
}
