import XCTest
@testable import PocketDJ

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultsHaveVinylSource() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(s.sources.count, 1)
        XCTAssertEqual(s.sources.first?.name, "My Vinyl")
        XCTAssertEqual(s.enabledSourceURLs.count, 1)
    }

    func testPersistAndReload() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.ripServerURL = "https://example.test"
        s.ripToken = "abc"
        s.addSource()
        s.sources[1].name = "Apple Music"
        s.sources[1].urlString = "https://cdn.test/am.json"
        s.persist()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.ripServerURL, "https://example.test")
        XCTAssertEqual(reloaded.ripToken, "abc")
        XCTAssertEqual(reloaded.sources.count, 2)
        XCTAssertEqual(reloaded.sources[1].name, "Apple Music")
    }

    func testEnabledSourceURLsSkipsDisabledAndInvalid() {
        let s = SettingsStore(defaults: freshDefaults())
        s.sources[0].enabled = false
        s.addSource()
        s.sources[1].urlString = "https://valid.test/i.json"
        s.addSource()
        s.sources[2].urlString = "   "      // invalid/blank
        XCTAssertEqual(s.enabledSourceURLs.map(\.absoluteString), ["https://valid.test/i.json"])
    }

    func testLoadAppleMusicAddsSourceOnce() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertFalse(s.hasAppleMusic)
        s.loadAppleMusic()
        XCTAssertTrue(s.hasAppleMusic)
        XCTAssertEqual(s.sources.count, 2)
        XCTAssertEqual(s.sources.last?.name, "Apple Music (Local)")
        s.loadAppleMusic()  // idempotent — no duplicate
        XCTAssertEqual(s.sources.count, 2)
    }

    func testResetRestoresDefaults() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.ripToken = "secret"; s.addSource(); s.persist()
        s.resetEverything()
        XCTAssertEqual(s.sources.count, 1)
        XCTAssertEqual(s.ripToken, "")
        // and it's gone from disk
        XCTAssertNil(defaults.data(forKey: "pdj.settings.v1"))
    }
}

final class CatalogMergeTests: XCTestCase {
    func testMergeDedupesById() throws {
        let a = try TestData.index()                 // 3 albums, 7 songs
        let b = try TestData.index()                 // same ids again
        let merged = AppModel.merge([a, b])
        XCTAssertEqual(merged.albums.count, 3)       // deduped, not 6
        XCTAssertEqual(merged.songs.count, 7)
    }

    func testMergeKeepsFirstOccurrence() throws {
        let first = try TestData.index()
        let merged = AppModel.merge([first])
        XCTAssertEqual(merged.albums.first?.id, "alb_1")
        XCTAssertEqual(merged.manifest.sourceName, "Test Crate")
    }

    func testMergeEmpty() {
        let merged = AppModel.merge([])
        XCTAssertTrue(merged.albums.isEmpty)
        XCTAssertEqual(merged.manifest.sourceName, "Collection")
    }

    // MARK: Index playlists (the "From your sources" wiring)

    private func indexWith(source: String, playlists: String) throws -> IndexJSON {
        let json = """
        { "manifest": { "sourceName": "\(source)" }, "albums": [], "songs": [], "playlists": \(playlists) }
        """
        return try JSONDecoder().decode(IndexJSON.self, from: Data(json.utf8))
    }

    func testDecodesIndexPlaylists() throws {
        let idx = try indexWith(source: "Apple", playlists: #"[{"id":"pl_1","name":"001","songIds":["sng_1","sng_2"]}]"#)
        XCTAssertEqual(idx.playlists?.count, 1)
        XCTAssertEqual(idx.playlists?.first?.name, "001")
        XCTAssertEqual(idx.playlists?.first?.songIds, ["sng_1", "sng_2"])
    }

    func testMissingPlaylistsDecodesNil() throws {
        let idx = try TestData.index()       // fixture has no `playlists`
        XCTAssertNil(idx.playlists)
    }

    func testMergeCarriesAndDedupesPlaylists() throws {
        let a = try indexWith(source: "Apple", playlists: #"[{"id":"pl_1","name":"A","songIds":[]}]"#)
        let b = try indexWith(source: "Apple", playlists: #"[{"id":"pl_1","name":"A","songIds":[]},{"id":"pl_2","name":"B","songIds":[]}]"#)
        let merged = AppModel.merge([a, b])
        XCTAssertEqual(merged.playlists?.map(\.id), ["pl_1", "pl_2"])   // deduped by id
    }

    func testSourcePlaylistsTagSourceName() throws {
        let vinyl = try indexWith(source: "My Vinyl", playlists: "[]")
        let apple = try indexWith(source: "Apple Music (Local)", playlists: #"[{"id":"pl_1","name":"001","songIds":["sng_1"]}]"#)
        let tagged = AppModel.sourcePlaylists([vinyl, apple])
        XCTAssertEqual(tagged.count, 1)
        XCTAssertEqual(tagged.first?.sourceName, "Apple Music (Local)")
        XCTAssertEqual(tagged.first?.name, "001")
    }
}
