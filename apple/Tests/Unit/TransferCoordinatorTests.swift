import XCTest
@testable import PocketDJ

/// Tests for the background-transfer coordinator's PERSISTENCE + finalize logic, exercised
/// WITHOUT a real background `URLSession` (the `realSession: false` seam): `enqueueDownload`
/// persists a `TransferRecord` (keyed by songId, one per song) atomically, `cancelAll` drops
/// records, and the persisted doc round-trips on reload. The real background session is only
/// truly exercised on-device (a `URLProtocol` stub can't drive a background session), so these
/// cover the join-map + persistence the cold-launch finalize depends on.
final class TransferCoordinatorTests: XCTestCase {
    private func makeCoordinator() -> (TransferCoordinator, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-transfers-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (TransferCoordinator(fileURL: url, realSession: false), url)
    }

    private func record(songId: String, taskId: Int = 0, source: String = "digital") -> TransferCoordinator.TransferRecord {
        TransferCoordinator.TransferRecord(
            taskIdentifier: taskId, songId: songId, kind: .burn,
            audioFileName: "\(songId).mp3", sidecarFileName: "\(songId).txt",
            sidecarText: "sidecar for \(songId)", wasAppStorage: true,
            burnFolderBookmark: nil, expectedBytes: 8,
            manifestKey: "rips/\(songId).mp3", source: source,
            bpm: 120, musicalKey: "Am", camelot: "8A", durationMs: 1000, startMs: nil,
            rippedAt: nil, title: songId, artist: "A", createdAt: 0)
    }

    // MARK: enqueue persists a record (the cold-launch join map)

    func testEnqueuePersistsRecord() {
        let (coord, url) = makeCoordinator()
        coord.enqueueDownload(url: URL(string: "https://rips.test/rips/sng_1.mp3")!,
                              token: "", record: record(songId: "sng_1", taskId: 7))
        XCTAssertEqual(coord.records.count, 1)
        XCTAssertEqual(coord.records.first?.songId, "sng_1")
        XCTAssertEqual(coord.records.first?.sidecarText, "sidecar for sng_1")
        XCTAssertEqual(coord.countersForTesting().enqueued, 1)

        // It was written to disk atomically (a fresh coordinator on the same file reloads it).
        let reloaded = TransferCoordinator(fileURL: url, realSession: false)
        XCTAssertEqual(reloaded.records.first?.songId, "sng_1")
        XCTAssertEqual(reloaded.records.first?.audioFileName, "sng_1.mp3")
    }

    // MARK: one in-flight record per song (re-enqueue replaces)

    func testReEnqueueReplacesPerSong() {
        let (coord, _) = makeCoordinator()
        coord.enqueueDownload(url: URL(string: "https://rips.test/a")!, token: "", record: record(songId: "sng_1", taskId: 1))
        coord.enqueueDownload(url: URL(string: "https://rips.test/b")!, token: "", record: record(songId: "sng_1", taskId: 2))
        XCTAssertEqual(coord.records.filter { $0.songId == "sng_1" }.count, 1)
        XCTAssertEqual(coord.records.first?.taskIdentifier, 2)
    }

    // MARK: cancelAll(songIds:) drops the targeted records

    func testCancelAllSongIdsDropsRecords() {
        let (coord, _) = makeCoordinator()
        coord.enqueueDownload(url: URL(string: "https://rips.test/a")!, token: "", record: record(songId: "sng_1"))
        coord.enqueueDownload(url: URL(string: "https://rips.test/b")!, token: "", record: record(songId: "sng_2"))
        XCTAssertEqual(coord.records.count, 2)
        coord.cancelAll(songIds: ["sng_1"])
        XCTAssertEqual(coord.records.map { $0.songId }, ["sng_2"])
    }

    func testCancelAllDropsEverything() {
        let (coord, _) = makeCoordinator()
        coord.enqueueDownload(url: URL(string: "https://rips.test/a")!, token: "", record: record(songId: "sng_1"))
        coord.enqueueDownload(url: URL(string: "https://rips.test/b")!, token: "", record: record(songId: "sng_2"))
        coord.cancelAll()
        XCTAssertTrue(coord.records.isEmpty)
    }

    // MARK: doc round-trips (schemaVersion preserved)

    func testDocRoundTrips() {
        let (coord, url) = makeCoordinator()
        coord.enqueueDownload(url: URL(string: "https://rips.test/a")!, token: "", record: record(songId: "sng_x"))
        let data = try! Data(contentsOf: url)
        let decoded = try! JSONDecoder().decode(TransferCoordinator.TransferDoc.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.tasks.count, 1)
        XCTAssertEqual(decoded.tasks.first?.songId, "sng_x")
    }

    // MARK: USER-FOLDER (bookmark) destination resolution OFF the main actor (the BLOCKER guard)

    /// Regression guard for the crash the app-storage tests missed: a backgrounded burn into a
    /// user-picked (security-scoped) folder resolves its destination on the background-session
    /// delegate queue (NOT the main actor). It must resolve purely from the bookmark Data STORED
    /// on the TransferRecord — with NO `@MainActor` access (no `MainActor.assumeIsolated`, which
    /// would TRAP off the main thread). This drives `resolveDestDir` (via the public delegate
    /// shim) from a background queue and asserts it returns the right dir without crashing.
    func testUserFolderDestinationResolvesOffMainActorFromRecordBookmark() {
        let (coord, _) = makeCoordinator()

        // A real, writable directory standing in for the user-picked burn folder.
        let userFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-userfolder-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: userFolder) }

        // The bookmark captured at enqueue time (mirrors BurnStore.makeBookmark).
        let bookmark = BurnStore.makeBookmark(for: userFolder)
        XCTAssertNotNil(bookmark, "a security-scoped bookmark must be mintable for the folder")

        var rec = record(songId: "sng_user", taskId: 1)
        rec.wasAppStorage = false              // a USER-folder burn (the path that used to trap)
        rec.burnFolderBookmark = bookmark      // captured at enqueue, persisted base64

        // Resolve from a BACKGROUND queue (the delegate-queue condition). If `resolveDestDir`
        // still touched the main actor via `MainActor.assumeIsolated`, this would crash here.
        let exp = expectation(description: "resolved off the main actor")
        var resolved: (url: URL, scoped: Bool)?
        DispatchQueue.global(qos: .background).async {
            XCTAssertFalse(Thread.isMainThread, "must resolve OFF the main thread")
            resolved = coord.resolveDestDirForTesting(rec)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        // It resolved to the user folder (not a crash, not the app-storage fallback).
        XCTAssertEqual(resolved?.url.standardizedFileURL.path, userFolder.standardizedFileURL.path)
        if resolved?.scoped == true { resolved?.url.stopAccessingSecurityScopedResource() }
    }

    /// An app-storage record resolves to Application Support `burns/` (no scope), also off main.
    func testAppStorageDestinationResolvesOffMainActor() {
        let (coord, _) = makeCoordinator()
        let rec = record(songId: "sng_app", taskId: 2)   // wasAppStorage: true by default
        let exp = expectation(description: "resolved")
        var resolved: (url: URL, scoped: Bool)?
        DispatchQueue.global(qos: .background).async {
            resolved = coord.resolveDestDirForTesting(rec)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.scoped, false)
        XCTAssertTrue(resolved?.url.path.contains("burns") ?? false)
    }

    // MARK: background-completion handler is called once on the main thread, then cleared

    func testRunBackgroundCompletionHandlerCallsOnceAndClears() {
        let (coord, _) = makeCoordinator()
        var count = 0
        coord.backgroundCompletionHandler = { count += 1 }
        coord.runBackgroundCompletionHandler()
        XCTAssertEqual(count, 1)
        XCTAssertNil(coord.backgroundCompletionHandler, "handler is nil'd after invocation")
        // A second call (no handler) is a harmless no-op.
        coord.runBackgroundCompletionHandler()
        XCTAssertEqual(count, 1)
    }
}
