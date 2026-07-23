import XCTest
@testable import PocketDJ

/// DebugSessionStore — the persisted archive of captured debug sessions (Settings ▸ Debug,
/// MISC4). Verifies archive → newest-first ordering, text round-trip via the sibling file,
/// per-session + delete-all removal (files AND metadata), the empty-capture no-op, and that
/// the JSON index survives a re-init (relaunch). Hermetic: an injected throwaway directory.
@MainActor
final class DebugSessionStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-debugsessions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeStore() -> DebugSessionStore { DebugSessionStore(directory: dir) }

    func testArchiveStoresNewestFirstWithTextRoundTrip() {
        let store = makeStore()
        let s1 = store.archive(startedAt: Date(timeIntervalSince1970: 1_000),
                               endedAt: Date(timeIntervalSince1970: 1_060),
                               lineCount: 3, text: "one")
        let s2 = store.archive(startedAt: Date(timeIntervalSince1970: 2_000),
                               endedAt: Date(timeIntervalSince1970: 2_060),
                               lineCount: 5, text: "two")
        XCTAssertNotNil(s1); XCTAssertNotNil(s2)
        XCTAssertEqual(store.sessions.count, 2)
        // Newest first.
        XCTAssertEqual(store.sessions.first?.id, s2?.id)
        XCTAssertEqual(store.sessions.last?.id, s1?.id)
        XCTAssertEqual(store.sessions.first?.lineCount, 5)
        // Text round-trips from the sibling file.
        XCTAssertEqual(store.text(for: s1!), "one")
        XCTAssertEqual(store.text(for: s2!), "two")
    }

    func testEmptyCaptureIsNoOp() {
        let store = makeStore()
        let s = store.archive(startedAt: Date(), endedAt: nil, lineCount: 0, text: "")
        XCTAssertNil(s)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testDeleteRemovesMetadataAndFile() {
        let store = makeStore()
        let s1 = store.archive(startedAt: Date(timeIntervalSince1970: 1_000), endedAt: nil,
                               lineCount: 1, text: "a")!
        let s2 = store.archive(startedAt: Date(timeIntervalSince1970: 2_000), endedAt: nil,
                               lineCount: 1, text: "b")!
        let fileURL = dir.appendingPathComponent(s1.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.delete(s1)
        XCTAssertEqual(store.sessions.map(\.id), [s2.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeleteAllClearsEverything() {
        let store = makeStore()
        _ = store.archive(startedAt: Date(timeIntervalSince1970: 1_000), endedAt: nil, lineCount: 1, text: "a")
        _ = store.archive(startedAt: Date(timeIntervalSince1970: 2_000), endedAt: nil, lineCount: 1, text: "b")
        XCTAssertEqual(store.sessions.count, 2)

        store.deleteAll()
        XCTAssertTrue(store.sessions.isEmpty)
        // No leftover .txt files.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "txt" } ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testIndexSurvivesReinit() {
        do {
            let store = makeStore()
            _ = store.archive(startedAt: Date(timeIntervalSince1970: 1_000),
                              endedAt: Date(timeIntervalSince1970: 1_060), lineCount: 4, text: "persisted")
        }
        // A fresh instance over the same directory reloads the index from disk.
        let reopened = makeStore()
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertEqual(reopened.sessions.first?.lineCount, 4)
        XCTAssertEqual(reopened.text(for: reopened.sessions.first!), "persisted")
    }
}
