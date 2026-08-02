import XCTest
@testable import PocketDJ

/// CollectionActivityStore — the device-local, APPEND-ONLY log of add/heart/unheart/remove events
/// behind the History view's Activity segment (F11). Distinct from PlayHistoryStore (no re-count
/// window, no aggregate); its own synced JSON file.
@MainActor
final class CollectionActivityStoreTests: XCTestCase {

    private func makeStore() -> (store: CollectionActivityStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-activity-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (CollectionActivityStore(fileURL: url), url)
    }

    func testRecordsAddEvent() {
        let (store, _) = makeStore()
        let e = store.record(kind: .add, itemId: "sng_1", itemTitle: "Song One",
                             collectionId: "pkt_1", collectionKind: "pocket", collectionName: "Soul", at: 1_000)
        XCTAssertNotNil(e)
        XCTAssertEqual(store.events.count, 1)
        let ev = store.events[0]
        XCTAssertEqual(ev.kind, .add)
        XCTAssertEqual(ev.itemId, "sng_1")
        XCTAssertEqual(ev.itemTitle, "Song One")
        XCTAssertEqual(ev.collectionName, "Soul")
        XCTAssertEqual(ev.at, 1_000)
    }

    func testRecordsHeartUnheartAndRemove() {
        let (store, _) = makeStore()
        store.record(kind: .heart, itemId: "sng_1", at: 1_000)
        store.record(kind: .unheart, itemId: "sng_1", at: 2_000)
        store.record(kind: .remove, itemId: "sng_2", collectionId: "pls_1",
                     collectionKind: "playlist", collectionName: "Set", at: 3_000)
        XCTAssertEqual(store.events.map(\.kind), [.heart, .unheart, .remove])
        // Heart events carry no collection scope.
        XCTAssertNil(store.events[0].collectionId)
        XCTAssertNil(store.events[0].collectionKind)
    }

    /// The SAME song hearted twice is TWO events — no re-count window (unlike PlayHistoryStore).
    func testNoDedupeWindow() {
        let (store, _) = makeStore()
        store.record(kind: .heart, itemId: "sng_1", at: 1_000)
        store.record(kind: .heart, itemId: "sng_1", at: 1_001)
        XCTAssertEqual(store.events.count, 2)
    }

    func testEmptyItemIdIsIgnored() {
        let (store, _) = makeStore()
        XCTAssertNil(store.record(kind: .add, itemId: "", at: 1_000))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testEventIdsAreUnique() {
        let (store, _) = makeStore()
        store.record(kind: .add, itemId: "sng_1", at: 1_000)
        store.record(kind: .add, itemId: "sng_2", at: 2_000)
        XCTAssertNotEqual(store.events[0].id, store.events[1].id)
    }

    func testPersistsAndDecodesOnInitIncludingInstallId() {
        let (store, url) = makeStore()
        store.record(kind: .add, itemId: "sng_1", collectionName: "Soul", at: 1_000)
        store.record(kind: .heart, itemId: "sng_2", at: 2_000)
        let install = store.installId
        let reloaded = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.installId, install)
        XCTAssertEqual(reloaded.events[0].collectionName, "Soul")
        XCTAssertEqual(reloaded.events[1].kind, .heart)
    }

    /// An OLD / empty / missing file decodes safely to an empty log with a fresh install id.
    func testMissingFileDecodesEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-activity-missing-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = CollectionActivityStore(fileURL: url)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.installId.isEmpty)
    }

    /// R3: the artist snapshot survives a persist/decode round trip — it is what keeps a row for an
    /// item this device's catalog can't resolve identifiable instead of a bare id.
    func testItemArtistRoundTrips() {
        let (store, url) = makeStore()
        store.record(kind: .add, itemId: "sng_1", itemTitle: "Running It Up", itemArtist: "Aria",
                     collectionName: "AM Mix", at: 1_000)
        let reloaded = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.events.first?.itemTitle, "Running It Up")
        XCTAssertEqual(reloaded.events.first?.itemArtist, "Aria")
    }

    /// A LEGACY document written before `itemArtist` existed must still decode every event — the
    /// field is additive-optional, so its absence is nil, never a dropped event or a reset log.
    func testLegacyDocumentWithoutItemArtistDecodes() throws {
        let json = """
        { "schemaVersion": 1, "installId": "abc", "events": [
            { "id": "\(UUID().uuidString)", "at": 1000, "kind": "add", "itemId": "sng_1",
              "itemTitle": "Old Row", "collectionName": "Soul" }
        ] }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-activity-legacy-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let store = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events.first?.itemTitle, "Old Row")
        XCTAssertNil(store.events.first?.itemArtist)
    }

    /// A document with unknown extra keys / missing events list still decodes (lenient Codable).
    func testDocumentWithUnknownKeysDecodes() throws {
        let json = """
        { "schemaVersion": 1, "installId": "abc", "future": true }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-activity-unknown-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let store = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(store.installId, "abc")
        XCTAssertTrue(store.events.isEmpty)
    }

    func testClearWipesEventsKeepsInstall() {
        let (store, _) = makeStore()
        store.record(kind: .add, itemId: "sng_1", at: 1_000)
        let install = store.installId
        store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.installId, install)
    }

    func testRevisionBumpsOnRecord() {
        let (store, _) = makeStore()
        let r0 = store.revision
        store.record(kind: .add, itemId: "sng_1", at: 1_000)
        XCTAssertGreaterThan(store.revision, r0)
    }

    /// Cross-profile merge is a set-union by event id: idempotent (re-merging the same events is a
    /// no-op) and re-sorted chronologically.
    func testMergeUnionsByIdIdempotentAndSorted() {
        let (store, _) = makeStore()
        store.record(kind: .add, itemId: "sng_1", at: 2_000)
        let mine = store.events
        let foreign = CollectionActivityStore.ActivityEvent(
            id: UUID(), at: 1_000, kind: .heart, itemId: "sng_9",
            itemTitle: nil, collectionId: nil, collectionKind: nil, collectionName: nil)
        store.merge(with: [foreign])
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.map(\.at), [1_000, 2_000])   // re-sorted by time
        // Idempotent: re-merging what we already hold changes nothing.
        store.merge(with: mine + [foreign])
        XCTAssertEqual(store.events.count, 2)
    }

    func testReloadFromDiskAdoptsDiskDoc() {
        let (store, url) = makeStore()
        store.record(kind: .add, itemId: "sng_1", at: 1_000)
        // A second store writes a different doc to the same URL (simulating a cloud pull).
        let other = CollectionActivityStore(fileURL: url)
        other.record(kind: .heart, itemId: "sng_2", at: 2_000)
        store.reloadFromDisk()
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.last?.kind, .heart)
    }

    /// FIX 2: a CloudSync pull lands device B's rival log on disk that does NOT carry device A's
    /// local event. reloadFromDisk must UNION (keep BOTH the local and the disk-only events),
    /// never wholesale-replace (which would silently lose device A's local add/heart/remove).
    func testReloadFromDiskUnionsRivalEventsNotReplaces() throws {
        let (store, url) = makeStore()
        // Device A's local-only event (in memory + on disk).
        store.record(kind: .add, itemId: "sng_A", collectionName: "Set", at: 1_000)
        // Simulate a cloud pull overwriting the file with device B's log — a DIFFERENT event that
        // does not include device A's local one.
        let rival = CollectionActivityStore.ActivityEvent(
            id: UUID(), at: 2_000, kind: .heart, itemId: "sng_B",
            itemTitle: nil, collectionId: nil, collectionKind: nil, collectionName: nil)
        let diskDoc = CollectionActivityStore.Document(installId: "device-b", events: [rival])
        try JSONEncoder().encode(diskDoc).write(to: url, options: .atomic)

        store.reloadFromDisk()
        // UNION, not replace: device A's local event survives AND device B's rival is adopted,
        // re-sorted chronologically.
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.map(\.itemId), ["sng_A", "sng_B"])
        // The union is persisted back so it rides the next push up.
        let reloaded = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.events.map(\.itemId), ["sng_A", "sng_B"])
    }

    /// The catalog add/remove kinds (2026-07, for the "Recently added" + Remove-from-Library work)
    /// round-trip through record → persist → decode, and — like hearts — carry no collection scope.
    func testRecordsCatalogAddAndRemove() {
        let (store, url) = makeStore()
        store.record(kind: .catalogAdd, itemId: "amrec_1", itemTitle: "New Jam", at: 1_000)
        store.record(kind: .catalogRemove, itemId: "amrec_1", itemTitle: "New Jam", at: 2_000)
        XCTAssertEqual(store.events.map(\.kind), [.catalogAdd, .catalogRemove])
        XCTAssertNil(store.events[0].collectionId)     // catalog events are library-scoped, not collection-scoped
        // The new raw values persist and decode back to the same cases.
        let reloaded = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.events.map(\.kind), [.catalogAdd, .catalogRemove])
        XCTAssertEqual(reloaded.events[0].itemId, "amrec_1")
    }

    /// Forward-compat: a synced doc containing an event whose `kind` is UNKNOWN to this build (a
    /// NEWER app version added an ActivityKind case) must decode to only the KNOWN events — never
    /// reset the WHOLE log to [] (which would then re-push a truncated log and clobber peers' events
    /// in the cloud). Exercises the per-event lenient decode.
    func testUnknownEventKindIsSkippedNotWholeLogDropped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-activity-fwd-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let json = """
        {
          "schemaVersion": 1,
          "installId": "peer",
          "events": [
            { "id": "\(UUID().uuidString)", "at": 1000, "kind": "add", "itemId": "sng_1" },
            { "id": "\(UUID().uuidString)", "at": 2000, "kind": "someFutureKind", "itemId": "sng_x" },
            { "id": "\(UUID().uuidString)", "at": 3000, "kind": "catalogAdd", "itemId": "amrec_9" }
          ]
        }
        """
        try Data(json.utf8).write(to: url)
        let store = CollectionActivityStore(fileURL: url)
        // The unknown-kind event is dropped; the two events this build understands survive.
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.map(\.itemId), ["sng_1", "amrec_9"])
        XCTAssertEqual(store.events.map(\.kind), [.add, .catalogAdd])
        XCTAssertEqual(store.installId, "peer")
    }

    /// FIX 3: clear() deletes the persisted file entirely (no residual empty JSON), matching the
    /// AccountDeletionService "each store removes its file" contract, and keeps the install id.
    func testClearRemovesPersistedFile() {
        let (store, url) = makeStore()
        store.record(kind: .add, itemId: "sng_1", at: 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let install = store.installId
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))   // no residual file
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.installId, install)
    }
}
