import XCTest
@testable import PocketDJ

/// Acceptance test A at the unit level: a PORTABLE playlist zip from user A imports on
/// user B's device (whose sources don't cover the songs), the unknown ids materialize
/// as provisional "Imported" catalog entries, and every downstream surface that reads
/// `app.songsById` — burn tuples, CSV, realize — resolves them. Plus the AppModel
/// provisional-source pipeline: merge-order shadowing and the amrec_-only remap.
@MainActor
final class ImportedCatalogFlowTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func indexSong(_ id: String, name: String = "T", am: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": "A", "length": 200_000]
        if let am { obj["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func index(source: String, songs: [IndexSong]) -> IndexJSON {
        IndexJSON(manifest: Manifest(source: source, generatedAt: nil, sourceName: source, counts: nil),
                  albums: [], songs: songs, playlists: nil)
    }

    // MARK: - Export → import → burn (the full flow)

    func testPortableRoundTripMaterializesForeignSongsAndBurnTuplesResolve() throws {
        // USER A: catalog carries the songs; export a playlist portable.
        let exporterCollections = CollectionsStore(fileURL: tempURL("exp"))
        let appA = AppModel()
        exporterCollections.app = appA
        let pl = exporterCollections.createPlaylist("Shared Set", songIds: ["sng_x1", "sng_x2"])
        let songsA: [String: IndexSong] = ["sng_x1": indexSong("sng_x1", name: "One"),
                                           "sng_x2": indexSong("sng_x2", name: "Two")]
        let pocketsById = [String: Pocket]()
        let zip = try PlaylistZip.export(playlist: exporterCollections.playlist(pl.id)!,
                                         pocketsById: pocketsById,
                                         songsById: songsA, albumsById: [:])

        // USER B: empty catalog (vinyl-only user who has none of these ids).
        let appB = AppModel()
        let importedStore = ImportedSongsStore(fileURL: tempURL("imp"))
        importedStore.onAdded = { songs, albums in appB.injectImported(songs: songs, albums: albums) }
        let importerCollections = CollectionsStore(fileURL: tempURL("col"))
        importerCollections.app = appB
        importerCollections.importedSongs = importedStore

        try importerCollections.importPlaylistZip(data: zip)

        // The playlist landed and the foreign songs are first-class catalog citizens.
        XCTAssertEqual(importerCollections.playlists.count, 1)
        XCTAssertNotNil(appB.songsById["sng_x1"])
        XCTAssertEqual(appB.songsById["sng_x1"]?.name, "One")
        XCTAssertEqual(appB.source(ofSong: "sng_x1"), ImportedSongsStore.sourceName)

        // Burn sees them (the acceptance-A gate that used to silently drop them).
        let importedPl = importerCollections.playlists[0]
        let ids = importerCollections.songIds(forPlaylist: importedPl.id)
        XCTAssertEqual(Set(ids), ["sng_x1", "sng_x2"])
        let tuples = importerCollections.burnTuples(ids)
        XCTAssertEqual(tuples.count, 2)
        XCTAssertEqual(Set(tuples.map(\.title)), ["One", "Two"])

        // Idempotent: re-import doesn't duplicate provisional entries.
        try importerCollections.importPlaylistZip(data: zip)
        XCTAssertEqual(importedStore.songs.count, 2)
    }

    func testImportSkipsIdsAlreadyInCatalog() throws {
        let app = AppModel()
        // The catalog ALREADY has sng_k (a real source owns it).
        app.injectDiscoverAdd(indexSong("sng_k", name: "Known"))
        let importedStore = ImportedSongsStore(fileURL: tempURL("imp2"))
        importedStore.onAdded = { songs, albums in app.injectImported(songs: songs, albums: albums) }
        let collections = CollectionsStore(fileURL: tempURL("col2"))
        collections.app = app
        collections.importedSongs = importedStore

        var payload = PortableItems.Payload()
        payload.songs = [.init(id: "sng_k", name: "Known-foreign", artist: "A"),
                         .init(id: "sng_new", name: "New", artist: "A")]
        collections.materializePortableItems(payload)

        XCTAssertEqual(importedStore.songs.map(\.songId), ["sng_new"],
                       "known catalog ids never become provisional entries")
        XCTAssertEqual(app.songsById["sng_k"]?.name, "Known", "existing entry untouched")
    }

    // MARK: - AppModel provisional pipeline

    /// R10: a real source and an imported provisional carrying the SAME id — the real
    /// source wins by merge order (provisional appended last), and the provisional
    /// entry is NOT pruned (no supersede pair for exact-id sng_ twins).
    func testRealSourceShadowsImportedTwinWithoutPruning() {
        let real = index(source: "My Vinyl", songs: [indexSong("sng_dup", name: "Real")])
        let imported = [ImportedSongsStore.SongEntry(
            songId: "sng_dup", title: "Provisional", artist: "A", albumId: nil, album: nil,
            artworkUrl: nil, durationMs: nil, bpm: nil, key: nil, camelot: nil, year: nil,
            appleMusicId: nil, addedAtMs: 0)]
        let r = AppModel.withProvisionalSources(discover: [], importedSongs: imported,
                                                importedAlbums: [], indexes: [real])
        XCTAssertTrue(r.importedSuperseded.isEmpty, "exact-id twins are shadowed, never remapped")
        let derived = AppModel.buildDerived(indexes: r.indexes, albumEdits: [:], songEdits: [:])
        XCTAssertEqual(derived.effective.songsById["sng_dup"]?.name, "Real",
                       "merge is first-wins; the real source owns the id")
        XCTAssertEqual(derived.songSourceById["sng_dup"], "My Vinyl")
    }

    func testImportedAmrecRemapsByAppleMusicIdButSngNever() {
        let real = index(source: "Apple Music (Local)",
                         songs: [indexSong("sng_real", am: "777"), indexSong("sng_other", am: "888")])
        func entry(_ id: String, am: String?) -> ImportedSongsStore.SongEntry {
            .init(songId: id, title: "T", artist: "A", albumId: nil, album: nil, artworkUrl: nil,
                  durationMs: nil, bpm: nil, key: nil, camelot: nil, year: nil,
                  appleMusicId: am, addedAtMs: 0)
        }
        let r = AppModel.withProvisionalSources(
            discover: [],
            importedSongs: [entry("amrec_a", am: "777"), entry("sng_b", am: "888")],
            importedAlbums: [], indexes: [real])
        XCTAssertEqual(r.importedSuperseded.map(\.from), ["amrec_a"])
        XCTAssertEqual(r.importedSuperseded.map(\.to), ["sng_real"])
        // The sng_ import survives as its own provisional row (specific-recording doctrine).
        let synth = r.indexes.last!
        XCTAssertEqual(synth.manifest.sourceName, ImportedSongsStore.sourceName)
        XCTAssertEqual(synth.songs.map(\.id), ["sng_b"])
    }

    func testWithProvisionalSourcesStacksDiscoverThenImported() {
        let real = index(source: "My Vinyl", songs: [indexSong("sng_1")])
        let discover = [DiscoverAddsStore.Entry(songId: "amrec_d", appleMusicId: "999",
                                                title: "D", artist: "X", addedAtMs: 0)]
        let imported = [ImportedSongsStore.SongEntry(
            songId: "sng_i", title: "I", artist: "Y", albumId: nil, album: nil, artworkUrl: nil,
            durationMs: nil, bpm: nil, key: nil, camelot: nil, year: nil,
            appleMusicId: nil, addedAtMs: 0)]
        let r = AppModel.withProvisionalSources(discover: discover, importedSongs: imported,
                                                importedAlbums: [], indexes: [real])
        XCTAssertEqual(r.indexes.map { $0.manifest.sourceName },
                       ["My Vinyl", DiscoverAddsStore.sourceName, ImportedSongsStore.sourceName])
    }
}
