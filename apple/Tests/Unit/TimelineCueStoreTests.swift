import XCTest
@testable import PocketDJ

/// `TimelineCueStore` — the NAMED BOOKMARKS on the Collection tab's One True Timeline (F8).
/// Positions in the ADD-DATE stream, not audio cue points (those are `StudioStore`'s and share
/// nothing but the word).
@MainActor
final class TimelineCueStoreTests: XCTestCase {

    private func makeStore() -> (store: TimelineCueStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-timeline-cues-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (TimelineCueStore(fileURL: url), url)
    }

    // MARK: - Adding

    func testAddsANamedCue() {
        let (store, _) = makeStore()
        let cue = store.add(name: "The vinyl binge", atMs: 1_700_000_000_000, at: 42)
        XCTAssertNotNil(cue)
        XCTAssertEqual(store.cues.count, 1)
        XCTAssertEqual(store.cues[0].name, "The vinyl binge")
        XCTAssertEqual(store.cues[0].atMs, 1_700_000_000_000)
        XCTAssertEqual(store.cues[0].createdAtMs, 42)
    }

    /// A stray tap must never persist an anonymous marker in the jump menu.
    func testRejectsBlankNameOrNonsensePosition() {
        let (store, _) = makeStore()
        XCTAssertNil(store.add(name: "   ", atMs: 1_000))
        XCTAssertNil(store.add(name: "\n", atMs: 1_000))
        XCTAssertNil(store.add(name: "Fine", atMs: 0))
        XCTAssertTrue(store.cues.isEmpty)
    }

    func testTrimsAndCapsTheName() {
        let (store, _) = makeStore()
        store.add(name: "  Lockdown  ", atMs: 1_000)
        XCTAssertEqual(store.cues[0].name, "Lockdown")
        store.add(name: String(repeating: "x", count: 200), atMs: 2_000)
        XCTAssertEqual(store.cues[1].name.count, TimelineCueStore.maxNameLength)
    }

    /// Always ordered oldest → newest on the axis, whatever order they were created in — so the
    /// menu and the editor never sort in a view body, and two devices render the same list.
    func testCuesStaySortedByPosition() {
        let (store, _) = makeStore()
        store.add(name: "C", atMs: 3_000)
        store.add(name: "A", atMs: 1_000)
        store.add(name: "B", atMs: 2_000)
        XCTAssertEqual(store.cues.map(\.name), ["A", "B", "C"])
    }

    // MARK: - Editing

    func testRenames() {
        let (store, _) = makeStore()
        let cue = store.add(name: "Old", atMs: 1_000)!
        XCTAssertTrue(store.rename(cue.id, to: " New "))
        XCTAssertEqual(store.cues[0].name, "New")
        // Blank rename is refused; the cue keeps its name rather than going unlabelled.
        XCTAssertFalse(store.rename(cue.id, to: "  "))
        XCTAssertEqual(store.cues[0].name, "New")
        XCTAssertFalse(store.rename(UUID(), to: "Ghost"))
    }

    func testMoveRepositionsAndResorts() {
        let (store, _) = makeStore()
        let a = store.add(name: "A", atMs: 1_000)!
        store.add(name: "B", atMs: 2_000)
        XCTAssertTrue(store.move(a.id, toMs: 3_000))
        XCTAssertEqual(store.cues.map(\.name), ["B", "A"])
        XCTAssertFalse(store.move(a.id, toMs: 0))
    }

    func testRemoves() {
        let (store, _) = makeStore()
        let a = store.add(name: "A", atMs: 1_000)!
        store.add(name: "B", atMs: 2_000)
        XCTAssertTrue(store.remove(a.id))
        XCTAssertEqual(store.cues.map(\.name), ["B"])
        XCTAssertFalse(store.remove(a.id))
    }

    func testRevisionMovesOnEveryRealMutation() {
        let (store, _) = makeStore()
        let start = store.revision
        let cue = store.add(name: "A", atMs: 1_000)!
        XCTAssertGreaterThan(store.revision, start)
        let afterAdd = store.revision
        store.rename(cue.id, to: "A")             // no-op rename must not churn
        XCTAssertEqual(store.revision, afterAdd)
        store.rename(cue.id, to: "B")
        XCTAssertGreaterThan(store.revision, afterAdd)
    }

    // MARK: - Nearest

    func testNearestFindsACueWithinTolerance() {
        let (store, _) = makeStore()
        store.add(name: "A", atMs: 1_000)
        store.add(name: "B", atMs: 10_000)
        XCTAssertEqual(store.nearest(to: 1_400, toleranceMs: 500)?.name, "A")
        XCTAssertNil(store.nearest(to: 5_000, toleranceMs: 500))
    }

    // MARK: - Persistence

    func testPersistsAcrossReload() {
        let (store, url) = makeStore()
        store.add(name: "The vinyl binge", atMs: 1_700_000_000_000)
        store.add(name: "Lockdown", atMs: 1_580_000_000_000)
        let reopened = TimelineCueStore(fileURL: url)
        XCTAssertEqual(reopened.cues.map(\.name), ["Lockdown", "The vinyl binge"])
    }

    func testClearRemovesTheDocumentEntirely() {
        let (store, url) = makeStore()
        store.add(name: "A", atMs: 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.clear()
        XCTAssertTrue(store.cues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "account deletion must leave no residual document")
    }

    /// A missing / empty / partial / forward-version document loads DEGRADED, never resetting the
    /// store by throwing — the durable-JSON contract every store here follows.
    func testDecodesLeniently() {
        let dir = FileManager.default.temporaryDirectory
        func load(_ json: String) -> TimelineCueStore {
            let url = dir.appendingPathComponent("pdj-cue-lenient-\(UUID().uuidString).json")
            try? json.data(using: .utf8)!.write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return TimelineCueStore(fileURL: url)
        }
        XCTAssertTrue(load("{}").cues.isEmpty)
        XCTAssertTrue(load("{\"schemaVersion\":99}").cues.isEmpty)
        // One malformed cue must not take the good ones with it.
        let mixed = load("""
        {"schemaVersion":1,"cues":[
          {"id":"\(UUID().uuidString)","name":"Good","atMs":1000},
          {"name":"No id","atMs":2000}
        ]}
        """)
        XCTAssertEqual(mixed.cues.map(\.name), ["Good"])
    }

    /// Cloud pull: WHOLE-DOCUMENT replace (LWW). Deliberately not a union — a union cannot express
    /// a DELETE without tombstones, so a cue removed on the phone would be resurrected by the Mac.
    func testReloadFromDiskAdoptsTheDocumentIncludingDeletions() {
        let (store, url) = makeStore()
        store.add(name: "A", atMs: 1_000)
        store.add(name: "B", atMs: 2_000)
        // Simulate a pull that dropped "A".
        let doc = TimelineCueStore.Document(cues: [store.cues[1]])
        try? JSONEncoder().encode(doc).write(to: url, options: .atomic)
        XCTAssertFalse(store.reloadFromDisk(), "a pull must never report a superset to push back")
        XCTAssertEqual(store.cues.map(\.name), ["B"])
    }

    /// …and a pull that changed nothing must not bump the revision (which would churn every view
    /// keyed on it, once per sync pass, forever).
    func testReloadOfAnIdenticalDocumentIsInert() {
        let (store, _) = makeStore()
        store.add(name: "A", atMs: 1_000)
        let rev = store.revision
        store.reloadFromDisk()
        XCTAssertEqual(store.revision, rev)
        XCTAssertEqual(store.cues.count, 1)
    }

    func testCapDropsTheOldestCreatedCue() {
        let (store, _) = makeStore()
        var cues: [TimelineCueStore.Cue] = []
        for n in 0...TimelineCueStore.maxCues {
            cues.append(TimelineCueStore.Cue(id: UUID(), name: "c\(n)",
                                             atMs: Double(1_000 + n), createdAtMs: Double(n)))
        }
        store.replaceAll(cues)
        XCTAssertEqual(store.cues.count, TimelineCueStore.maxCues)
        XCTAssertFalse(store.cues.contains { $0.name == "c0" })
        XCTAssertTrue(store.cues.contains { $0.name == "c\(TimelineCueStore.maxCues)" })
    }

    /// Registered with CloudSyncService as "timeline-cues", so it MUST be in `cloudDocKeys` or its
    /// cloud copy would survive an account deletion (the gap "rec-feedback" had).
    func testCueDocumentIsWipedOnAccountDeletion() {
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("timeline-cues"))
    }
}
