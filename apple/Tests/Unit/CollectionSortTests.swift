import XCTest
@testable import PocketDJ

/// The Playlists-screen overhaul: the `CollectionSortOrder` comparator, `markPlayed`'s
/// updatedAt-preserving stamp, the v6→v7 additive-optional schema safety, the USER|SHARED
/// mode partition + search re-scope, and the Shared-tab per-source grouping + collapse memory.

// MARK: - Sort comparator

final class CollectionSortOrderTests: XCTestCase {

    private func pl(_ name: String, updatedAt: Double, lastPlayedAt: Double?) -> Playlist {
        Playlist(id: "pls_\(name)", name: name, sequences: [],
                 lastPlayedAt: lastPlayedAt, createdAt: 0, updatedAt: updatedAt)
    }

    func testNameSortIsCaseInsensitiveAlphabetical() {
        let items = [pl("banana", updatedAt: 100, lastPlayedAt: nil),
                     pl("Apple", updatedAt: 1, lastPlayedAt: nil),
                     pl("cherry", updatedAt: 50, lastPlayedAt: nil)]
        XCTAssertEqual(CollectionSortOrder.name.sorted(items).map(\.name),
                       ["Apple", "banana", "cherry"])
    }

    func testLastUpdatedSortsNewestFirstWithNameTieBreak() {
        let items = [pl("old", updatedAt: 10, lastPlayedAt: nil),
                     pl("newB", updatedAt: 99, lastPlayedAt: nil),
                     pl("newA", updatedAt: 99, lastPlayedAt: nil)]
        // 99 (tie → name A before B), then 10.
        XCTAssertEqual(CollectionSortOrder.lastUpdated.sorted(items).map(\.name),
                       ["newA", "newB", "old"])
    }

    func testRecentlyPlayedSortsNeverPlayedLast() {
        let items = [pl("neverPlayed", updatedAt: 500, lastPlayedAt: nil),
                     pl("playedRecent", updatedAt: 1, lastPlayedAt: 900),
                     pl("playedOld", updatedAt: 2, lastPlayedAt: 100)]
        // Played (900, 100) first newest-first, never-played (nil ⇒ 0) LAST despite high updatedAt.
        XCTAssertEqual(CollectionSortOrder.recentlyPlayed.sorted(items).map(\.name),
                       ["playedRecent", "playedOld", "neverPlayed"])
    }

    func testRecentlyPlayedTieBreaksOnUpdatedThenName() {
        let items = [pl("z", updatedAt: 5, lastPlayedAt: 100),
                     pl("a", updatedAt: 5, lastPlayedAt: 100),
                     pl("y", updatedAt: 9, lastPlayedAt: 100)]
        // Equal lastPlayedAt → updatedAt desc (9 first), then name tie-break (a before z).
        XCTAssertEqual(CollectionSortOrder.recentlyPlayed.sorted(items).map(\.name),
                       ["y", "a", "z"])
    }

    @MainActor
    func testDefaultOnUpgradeIsNameAZ() {
        // A blob with no collectionSort key coalesces to .name (A–Z), the upgrade default.
        let defaults = UserDefaults(suiteName: "pdj.test.sort.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.collectionSort, .name)
    }

    @MainActor
    func testCollectionSortPersistsRoundTrip() {
        let name = "pdj.test.sort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let s1 = SettingsStore(defaults: defaults)
        s1.collectionSort = .recentlyPlayed
        s1.persist()
        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.collectionSort, .recentlyPlayed)
    }
}

// MARK: - markPlayed stamps lastPlayedAt without moving updatedAt

@MainActor
final class CollectionsMarkPlayedTests: XCTestCase {
    private func store(_ url: URL? = nil) -> CollectionsStore {
        CollectionsStore(fileURL: url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-\(UUID().uuidString).json"))
    }

    func testMarkPlayedStampsLastPlayedWithoutMovingUpdatedAt() {
        let s = store()
        let pl = s.createPlaylist("Set")
        let updatedBefore = s.playlist(pl.id)?.updatedAt
        XCTAssertNil(s.playlist(pl.id)?.lastPlayedAt)

        s.markPlayed(playlistId: pl.id)

        XCTAssertNotNil(s.playlist(pl.id)?.lastPlayedAt)
        XCTAssertEqual(s.playlist(pl.id)?.updatedAt, updatedBefore,
                       "playback must NOT disturb updatedAt (the Last-updated signal)")
    }

    func testMarkPlayedPocketStampsWithoutMovingUpdatedAt() {
        let s = store()
        let p = s.createPocket("Soul")
        let updatedBefore = s.pocket(p.id)?.updatedAt
        s.markPlayed(pocketId: p.id)
        XCTAssertNotNil(s.pocket(p.id)?.lastPlayedAt)
        XCTAssertEqual(s.pocket(p.id)?.updatedAt, updatedBefore)
    }

    func testMarkPlayedPersistsAcrossReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-\(UUID().uuidString).json")
        let s1 = store(url)
        let pl = s1.createPlaylist("Set")
        s1.markPlayed(playlistId: pl.id)
        let stamped = s1.playlist(pl.id)?.lastPlayedAt
        XCTAssertNotNil(stamped)
        s1.flushDocumentNow()   // save() encodes+writes async now; land it before re-reading

        let s2 = store(url)   // re-decode from disk (v7)
        XCTAssertEqual(s2.playlist(pl.id)?.lastPlayedAt, stamped)
    }
}

// MARK: - v6 → v7 schema safety (additive-optional, no wipe)

final class CollectionsV7SchemaTests: XCTestCase {

    /// A v6 document (no `lastPlayedAt` key anywhere) must decode with EVERY playlist/pocket
    /// intact, lastPlayedAt defaulted to nil, and the version bumped to 7 (no-op identity).
    func testV6DocumentDecodesWithoutDroppingCollections() throws {
        let v6 = """
        { "schemaVersion": 6, "pockets": [
            { "id": "pkt_old", "name": "Soul", "kind": "harmonic",
              "songIds": ["sng_1"], "createdAt": 0, "updatedAt": 42 }
          ], "playlists": [
            { "id": "pls_old", "name": "Set", "sequences": [
                { "nodeId": "seq_1", "kind": "sequence", "name": "Default", "children": [] }
              ], "createdAt": 0, "updatedAt": 7 }
          ] }
        """
        let doc = try CollectionsCodec.decode(Data(v6.utf8))
        XCTAssertEqual(doc.schemaVersion, collectionsSchemaVersion)   // bumped to 7
        XCTAssertEqual(doc.schemaVersion, 7)
        XCTAssertEqual(doc.playlists.map(\.id), ["pls_old"])          // playlist NOT dropped
        XCTAssertEqual(doc.pockets.map(\.id), ["pkt_old"])            // pocket NOT dropped
        XCTAssertNil(doc.playlists.first?.lastPlayedAt)               // additive default
        XCTAssertNil(doc.pockets.first?.lastPlayedAt)
        XCTAssertEqual(doc.playlists.first?.updatedAt, 7)             // existing fields preserved
        XCTAssertEqual(doc.pockets.first?.updatedAt, 42)
    }

    func testV7LastPlayedRoundTrips() throws {
        var doc = CollectionsDocument()
        doc.playlists = [Playlist(id: "pls_1", name: "Set", sequences: [], lastPlayedAt: 1234)]
        doc.pockets = [Pocket(id: "pkt_1", name: "Soul", lastPlayedAt: 5678)]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.playlists.first?.lastPlayedAt, 1234)
        XCTAssertEqual(back.pockets.first?.lastPlayedAt, 5678)
    }

    /// The migration must be a pure version bump — it does not touch any surviving field.
    func testMigrationIsNoOpIdentity() {
        var doc = CollectionsDocument(schemaVersion: 6)
        doc.playlists = [Playlist(id: "pls_1", name: "Keep", sequences: [], updatedAt: 99)]
        let migrated = CollectionsMigration.migrate(doc)
        XCTAssertEqual(migrated.schemaVersion, collectionsSchemaVersion)
        XCTAssertEqual(migrated.playlists.map(\.id), ["pls_1"])
        XCTAssertEqual(migrated.playlists.first?.updatedAt, 99)
        XCTAssertNil(migrated.playlists.first?.lastPlayedAt)
    }
}

// MARK: - USER | SHARED mode partition + search re-scope

final class PlaylistModeTests: XCTestCase {

    func testUserModeIgnoresSourceMatches() {
        // User tab: playlist/pocket matches count; source matches are invisible.
        XCTAssertTrue(PlaylistMode.user.hasMatches(playlists: 1, pockets: 0, sources: 0))
        XCTAssertTrue(PlaylistMode.user.hasMatches(playlists: 0, pockets: 2, sources: 0))
        XCTAssertFalse(PlaylistMode.user.hasMatches(playlists: 0, pockets: 0, sources: 9),
                       "a User search must not surface Shared results")
    }

    func testSharedModeIgnoresUserMatches() {
        XCTAssertTrue(PlaylistMode.shared.hasMatches(playlists: 0, pockets: 0, sources: 1))
        XCTAssertFalse(PlaylistMode.shared.hasMatches(playlists: 5, pockets: 5, sources: 0),
                       "a Shared search must not surface your own collections")
    }

    func testRawValueIsStableForAppStorage() {
        // @AppStorage persists the rawValue — keep it stable across launches.
        XCTAssertEqual(PlaylistMode.user.rawValue, "user")
        XCTAssertEqual(PlaylistMode.shared.rawValue, "shared")
        XCTAssertEqual(PlaylistMode(rawValue: "shared"), .shared)
    }
}

// MARK: - Shared-tab per-source grouping + collapse memory

final class PlaylistSourcesTests: XCTestCase {

    private func sp(_ id: String, _ name: String, source: String) -> SourcePlaylist {
        SourcePlaylist(playlist: IndexPlaylist(id: id, name: name, songIds: []), sourceName: source)
    }

    func testGroupsFollowAvailableSourcesOrder() {
        let items = [sp("a", "A", source: "Vinyl"),
                     sp("b", "B", source: "Apple Music (Local)"),
                     sp("c", "C", source: "Vinyl")]
        let grouped = PlaylistSources.grouped(items, availableSources: ["Apple Music (Local)", "Vinyl"])
        XCTAssertEqual(grouped.map(\.source), ["Apple Music (Local)", "Vinyl"])
        XCTAssertEqual(grouped.first(where: { $0.source == "Vinyl" })?.playlists.map(\.id), ["a", "c"])
    }

    func testUnknownSourcesAppendedAlphabetically() {
        let items = [sp("a", "A", source: "Zed"),
                     sp("b", "B", source: "Known"),
                     sp("c", "C", source: "Alpha")]
        // "Known" is in availableSources first; "Zed"/"Alpha" unknown → alpha-appended.
        let grouped = PlaylistSources.grouped(items, availableSources: ["Known"])
        XCTAssertEqual(grouped.map(\.source), ["Known", "Alpha", "Zed"])
    }

    func testExpandedPersistenceRoundTripDefaultsCollapsed() {
        let name = "pdj.test.sources.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        // Missing key ⇒ empty set ⇒ everything collapsed by default.
        XCTAssertTrue(PlaylistSources.loadExpanded(from: defaults).isEmpty)

        PlaylistSources.persistExpanded(["Vinyl", "My Digital"], to: defaults)
        XCTAssertEqual(PlaylistSources.loadExpanded(from: defaults), ["Vinyl", "My Digital"])

        PlaylistSources.persistExpanded([], to: defaults)
        XCTAssertTrue(PlaylistSources.loadExpanded(from: defaults).isEmpty)
    }
}
