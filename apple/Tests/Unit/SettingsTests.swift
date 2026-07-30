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

    func testDefaultRecentlyAddedDefaultsClampsAndPersists() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.defaultRecentlyAddedCount, SettingsStore.recentlyAddedDefaultCount)  // 3650
        // Clamp below 1 → 1.
        s.defaultRecentlyAddedCount = 0
        XCTAssertEqual(s.defaultRecentlyAddedCount, 1)
        // Clamp above the max.
        s.defaultRecentlyAddedCount = SettingsStore.recentlyAddedMaxCount + 999
        XCTAssertEqual(s.defaultRecentlyAddedCount, SettingsStore.recentlyAddedMaxCount)
        // Round-trips.
        s.defaultRecentlyAddedCount = 500
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultRecentlyAddedCount, 500)
    }

    /// The Private-syncing default is CAPTURED ONCE at store construction (private iff an import
    /// server is configured), so later ripServerURL edits never silently flip a state the user
    /// has already seen; an explicit choice persists across reloads; and the legacy check-build
    /// "local"/"remote" string migrates to the Bool.
    func testAppleMusicPrivateSyncCapturedAtInitAndPersists() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertFalse(s.appleMusicPrivateSync)                // fresh install captures public
        s.ripServerURL = "http://imac.local:8787"
        XCTAssertFalse(s.appleMusicPrivateSync)                // captured — a later URL edit can't flip it
        s.appleMusicPrivateSync = true                         // explicit choice
        s.persist()
        XCTAssertTrue(SettingsStore(defaults: defaults).appleMusicPrivateSync)

        // An existing iMac blob (server URL set, never chosen) captures PRIVATE at init.
        let imacDefaults = freshDefaults()
        let pre = SettingsStore(defaults: imacDefaults)
        pre.ripServerURL = "http://imac.local:8787"
        pre.appleMusicPrivateSyncRaw = nil                     // simulate a pre-feature blob
        pre.persist()
        XCTAssertTrue(SettingsStore(defaults: imacDefaults).appleMusicPrivateSync)

        // Legacy migration: a check-build blob that persisted appleMusicSyncMode = "local".
        let legacyDefaults = freshDefaults()
        var legacy = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SettingsData.default)) as! [String: Any]
        legacy["appleMusicSyncMode"] = "local"
        legacyDefaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: "pdj.settings.v1")
        XCTAssertTrue(SettingsStore(defaults: legacyDefaults).appleMusicPrivateSync)
    }

    func testPersistAndReload() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.ripServerURL = "https://example.test"
        s.ripToken = "abc"
        s.ripFromCloud = true
        s.addSource()
        s.sources[1].name = "Apple Music"
        s.sources[1].urlString = "https://cdn.test/am.json"
        s.persist()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.ripServerURL, "https://example.test")
        XCTAssertEqual(reloaded.ripToken, "abc")
        XCTAssertTrue(reloaded.ripFromCloud)
        XCTAssertEqual(reloaded.sources.count, 2)
        XCTAssertEqual(reloaded.sources[1].name, "Apple Music")
    }

    func testRipFromCloudDefaultsOff() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertFalse(s.ripFromCloud)
    }

    /// The PocketDJ (performer) name defaults to "", round-trips, and resets to "".
    func testPocketDJNamePersistsAndReloads() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.pocketDJName, "")
        s.pocketDJName = "Levi Schoen"
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).pocketDJName, "Levi Schoen")
        s.resetEverything()
        XCTAssertEqual(s.pocketDJName, "")
    }

    /// `lastSection` (the iOS "reopen where you left off" seam): defaults to nil
    /// (= the home menu), round-trips through persist/reload — including "" for an
    /// explicit home — and, being Optional in SettingsData, survives legacy blobs.
    func testLastSectionPersistsAndReloads() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertNil(s.lastSection)

        s.lastSection = "Mix"
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).lastSection, "Mix")

        s.lastSection = ""            // the user left off ON the home menu
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).lastSection, "")

        s.resetEverything()
        XCTAssertNil(s.lastSection)
    }

    /// REGRESSION (Codable back-compat): an older `pdj.settings.v1` blob written before
    /// `ripFromCloud` existed has no such key. Because `ripFromCloud` is `Bool?` in
    /// SettingsData, the blob must still decode — preserving sources/ripServerURL — and
    /// ripFromCloud must come back false. A non-optional Bool would fail decode and
    /// silently reset ALL settings to defaults.
    func testLegacyBlobWithoutRipFromCloudDecodesAndPreservesSettings() {
        let defaults = freshDefaults()
        let legacy = """
        {
          "sources": [{"id":"\(UUID().uuidString)","name":"Old Crate","urlString":"https://old.test/i.json","enabled":true}],
          "ripServerURL": "https://legacy.test",
          "ripToken": "legacy-token",
          "searchAccessKeyID": "",
          "searchSecretKey": "",
          "searchEndpoint": ""
        }
        """
        defaults.set(Data(legacy.utf8), forKey: "pdj.settings.v1")

        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.ripServerURL, "https://legacy.test", "legacy settings must survive (not reset to default)")
        XCTAssertEqual(s.ripToken, "legacy-token")
        XCTAssertEqual(s.sources.count, 1)
        XCTAssertEqual(s.sources.first?.name, "Old Crate")
        XCTAssertFalse(s.ripFromCloud, "missing key coalesces to false")
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

    func testLoadMyDigitalAddsSourceOnce() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertFalse(s.hasMyDigital)
        s.loadMyDigital()
        XCTAssertTrue(s.hasMyDigital)
        XCTAssertEqual(s.sources.count, 2)
        XCTAssertEqual(s.sources.last?.name, "My Digital")
        XCTAssertEqual(s.sources.last?.urlString, Config.digitalIndexURL.absoluteString)
        s.loadMyDigital()  // idempotent — no duplicate
        XCTAssertEqual(s.sources.count, 2)
    }

    func testResetRestoresDefaults() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.ripToken = "secret"; s.ripFromCloud = true; s.addSource(); s.persist()
        s.resetEverything()
        XCTAssertEqual(s.sources.count, 1)
        XCTAssertEqual(s.ripToken, "")
        XCTAssertFalse(s.ripFromCloud)
        // and it's gone from disk
        XCTAssertNil(defaults.data(forKey: "pdj.settings.v1"))
    }

    // MARK: Auto-Mix crossfade settings

    func testAutoMixDefaults() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(s.autoMixLeadSeconds, 15)
        XCTAssertEqual(s.autoMixFadeSeconds, 3)
        XCTAssertEqual(s.skipFadeSeconds, 15)            // manual-skip fade default
        XCTAssertEqual(s.cueOutputChannel, .right)        // cue defaults to the right channel
        XCTAssertFalse(s.beatPulseEnabled)                // beat pulse defaults OFF
    }

    func testAutoMixPersistsAndReloads() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.autoMixLeadSeconds = 20
        s.autoMixFadeSeconds = 5
        s.skipFadeSeconds = 25
        s.cueOutputChannel = .left
        s.beatPulseEnabled = true
        s.persist()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.autoMixLeadSeconds, 20)
        XCTAssertEqual(reloaded.autoMixFadeSeconds, 5)
        XCTAssertEqual(reloaded.skipFadeSeconds, 25)
        XCTAssertEqual(reloaded.cueOutputChannel, .left)
        XCTAssertTrue(reloaded.beatPulseEnabled)
    }

    /// REGRESSION (Codable back-compat): a legacy blob predating the auto-mix keys must still
    /// decode (preserving other settings) and coalesce the missing keys to 15 / 3.
    func testLegacyBlobWithoutAutoMixDecodesWithDefaults() {
        let defaults = freshDefaults()
        let legacy = """
        {
          "sources": [{"id":"\(UUID().uuidString)","name":"Old Crate","urlString":"https://old.test/i.json","enabled":true}],
          "ripServerURL": "https://legacy.test",
          "ripToken": "legacy-token",
          "searchAccessKeyID": "",
          "searchSecretKey": "",
          "searchEndpoint": ""
        }
        """
        defaults.set(Data(legacy.utf8), forKey: "pdj.settings.v1")

        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.ripServerURL, "https://legacy.test", "legacy settings must survive")
        XCTAssertEqual(s.autoMixLeadSeconds, 15, "missing key coalesces to default")
        XCTAssertEqual(s.autoMixFadeSeconds, 3)
        XCTAssertEqual(s.skipFadeSeconds, 15, "missing skip-fade key coalesces to default")
        XCTAssertEqual(s.cueOutputChannel, .right, "missing cue-channel key coalesces to default")
        XCTAssertFalse(s.beatPulseEnabled, "missing beat-pulse key coalesces to off")
    }

    func testResetRestoresAutoMixDefaults() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.autoMixLeadSeconds = 30; s.autoMixFadeSeconds = 8; s.skipFadeSeconds = 40
        s.cueOutputChannel = .left; s.beatPulseEnabled = true; s.persist()
        s.resetEverything()
        XCTAssertEqual(s.autoMixLeadSeconds, 15)
        XCTAssertEqual(s.autoMixFadeSeconds, 3)
        XCTAssertEqual(s.skipFadeSeconds, 15)
        XCTAssertEqual(s.cueOutputChannel, .right)
        XCTAssertFalse(s.beatPulseEnabled)
    }

    // MARK: Mix deck layout (iOS "view mode")

    func testMixDeckLayoutDefaultsToStacked() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(s.mixDeckLayout, .stacked, "portrait default is the stacked layout")
    }

    func testMixDeckLayoutPersistsAndReloads() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.mixDeckLayout = .single
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).mixDeckLayout, .single)
        s.mixDeckLayout = .sideBySide
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).mixDeckLayout, .sideBySide)
    }

    /// REGRESSION (Codable back-compat): a legacy blob predating the deck-layout key must still
    /// decode (preserving other settings) and coalesce the missing key to the stacked default.
    func testLegacyBlobWithoutMixDeckLayoutDefaultsStacked() {
        let defaults = freshDefaults()
        let legacy = """
        {
          "sources": [],
          "ripServerURL": "https://legacy.test",
          "ripToken": "",
          "searchAccessKeyID": "",
          "searchSecretKey": "",
          "searchEndpoint": ""
        }
        """
        defaults.set(Data(legacy.utf8), forKey: "pdj.settings.v1")
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.ripServerURL, "https://legacy.test", "legacy settings must survive")
        XCTAssertEqual(s.mixDeckLayout, .stacked, "missing key coalesces to the stacked default")
    }

    func testResetRestoresMixDeckLayout() {
        let s = SettingsStore(defaults: freshDefaults())
        s.mixDeckLayout = .single
        s.persist()
        s.resetEverything()
        XCTAssertEqual(s.mixDeckLayout, .stacked)
    }

    // MARK: Storage soft cap (unset by default ⇒ the app never auto-manages storage)

    func testStorageCapDefaultsUnsetAndPersists() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertNil(s.storageSoftCapGB, "no cap by default — storage stays user-managed")
        XCTAssertNil(s.lastStoragePruneAt)
        s.storageSoftCapGB = 32
        s.lastStoragePruneAt = 1_234
        s.persist()
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.storageSoftCapGB, 32)
        XCTAssertEqual(reloaded.lastStoragePruneAt, 1_234)
    }

    func testLegacyBlobWithoutStorageCapDecodesUnset() {
        let defaults = freshDefaults()
        let legacy = """
        {
          "sources": [],
          "ripServerURL": "https://legacy.test",
          "ripToken": "",
          "searchAccessKeyID": "",
          "searchSecretKey": "",
          "searchEndpoint": ""
        }
        """
        defaults.set(Data(legacy.utf8), forKey: "pdj.settings.v1")
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.ripServerURL, "https://legacy.test", "legacy settings must survive")
        XCTAssertNil(s.storageSoftCapGB, "missing key decodes as UNSET, not a default cap")
        XCTAssertNil(s.lastStoragePruneAt)
    }

    func testResetClearsStorageCap() {
        let s = SettingsStore(defaults: freshDefaults())
        s.storageSoftCapGB = 64; s.lastStoragePruneAt = 99; s.persist()
        s.resetEverything()
        XCTAssertNil(s.storageSoftCapGB)
        XCTAssertNil(s.lastStoragePruneAt)
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
