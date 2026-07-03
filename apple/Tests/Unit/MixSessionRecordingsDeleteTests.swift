import XCTest
@testable import PocketDJ

/// Storage manager — "Delete session recordings". Removes every captured take's AUDIO
/// (metadata-tracked and crash-orphaned strays alike, so the next orphan scan can't revive
/// them), clears the recordings metadata, keeps the sessions/events themselves, and never
/// touches an in-flight capture's open file. Hermetic via `SessionFolders.appRootOverride`.
@MainActor
final class MixSessionRecordingsDeleteTests: XCTestCase {

    private var root: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recdel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SessionFolders.appRootOverride = root
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recdel-sessions-\(UUID().uuidString).json")
    }

    override func tearDown() {
        SessionFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    /// Write a take's file into the session's folder + attach its metadata.
    @discardableResult
    private func addTake(_ store: MixSessionStore, sessionId: String, name: String,
                         bytes: Int = 4) throws -> URL {
        let folder = try XCTUnwrap(SessionFolders.sessionFolder(sessionId, bookmark: nil))
        defer { folder.release?() }
        let url = folder.url.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        store.addRecording(toSession: sessionId, fileName: name, startedAt: 1_000,
                           durationMs: 2_000, wasUserFolder: false)
        return url
    }

    func testDeleteAllRecordingsRemovesFilesAndMetadataButKeepsSessions() throws {
        let store = MixSessionStore(fileURL: storeURL)
        store.notePlayed(songId: "s1")          // give the current session some activity
        let current = store.currentId
        let take = try addTake(store, sessionId: current, name: "recording-1.m4a")
        XCTAssertEqual(store.recordings(forSession: current).count, 1)

        store.deleteAllRecordings(bookmark: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: take.path))
        XCTAssertTrue(store.recordings(forSession: current).isEmpty)
        // The session itself (and its played log) survives — only audio goes.
        XCTAssertNotNil(store.session(current))
        XCTAssertEqual(store.playedSongIds(forSession: current), ["s1"])
        // The emptied per-session folder is pruned too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(current).path))
    }

    /// A crash-orphaned stray .m4a (no metadata) is swept as well — otherwise the next
    /// orphan scan would revive it as a "Recovered recording".
    func testDeleteAllRecordingsSweepsStrayFiles() throws {
        let store = MixSessionStore(fileURL: storeURL)
        let strayDir = root.appendingPathComponent("mses_ghost", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        let stray = strayDir.appendingPathComponent("recording-1.m4a")
        try Data([0x0]).write(to: stray)

        store.deleteAllRecordings(bookmark: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayDir.path))
    }

    func testDeleteAllRecordingsSkipsInFlightTake() throws {
        let store = MixSessionStore(fileURL: storeURL)
        let current = store.currentId
        let done = try addTake(store, sessionId: current, name: "recording-1.m4a")
        // The in-flight take exists on disk but has NO metadata yet (filed on stop).
        let folder = try XCTUnwrap(SessionFolders.sessionFolder(current, bookmark: nil))
        defer { folder.release?() }
        let live = folder.url.appendingPathComponent("recording-2.m4a")
        try Data([0x0]).write(to: live)

        store.deleteAllRecordings(bookmark: nil, skippingSessionId: current,
                                  skippingFileName: "recording-2.m4a")

        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path), "finished take deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "open take kept")
    }

    /// A USER-NAMED subfolder in a user-picked session root (their own audio) is never
    /// swept — only app-named `mses_…` session folders are.
    func testDeleteAllRecordingsNeverTouchesUserSubfolders() throws {
        let store = MixSessionStore(fileURL: storeURL)
        let userDir = root.appendingPathComponent("My Voice Memos", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let memo = userDir.appendingPathComponent("idea.m4a")
        try Data([0x0]).write(to: memo)

        store.deleteAllRecordings(bookmark: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: memo.path),
                      "a user's own .m4a in their own folder is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: userDir.path))
    }

    /// A take recorded into a user folder whose bookmark can't resolve right now keeps
    /// its metadata — nothing was deleted, so nothing may be forgotten.
    func testDeleteAllRecordingsKeepsMetadataForUnreachableUserFolderTakes() throws {
        let store = MixSessionStore(fileURL: storeURL)
        store.notePlayed(songId: "s1")
        let current = store.currentId
        store.addRecording(toSession: current, fileName: "recording-1.m4a",
                           startedAt: 1_000, durationMs: 2_000, wasUserFolder: true)

        store.deleteAllRecordings(bookmark: nil)   // user root unreachable (no bookmark)

        XCTAssertEqual(store.recordings(forSession: current).count, 1,
                       "metadata survives — the file was never reachable to delete")
    }

    // MARK: Single-take delete (the session view's per-recording trash)

    func testDeleteRecordingRemovesOneTakeAndKeepsSiblings() throws {
        let store = MixSessionStore(fileURL: storeURL)
        store.notePlayed(songId: "s1")
        let current = store.currentId
        let take1 = try addTake(store, sessionId: current, name: "recording-1.m4a")
        let take2 = try addTake(store, sessionId: current, name: "recording-2.m4a")
        let rec1 = try XCTUnwrap(store.recordings(forSession: current).first)

        XCTAssertTrue(store.deleteRecording(sessionId: current, recordingId: rec1.id, bookmark: nil))

        XCTAssertFalse(FileManager.default.fileExists(atPath: take1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: take2.path), "sibling take untouched")
        XCTAssertEqual(store.recordings(forSession: current).map(\.fileName), ["recording-2.m4a"])
        XCTAssertNotNil(store.session(current), "session + its logs survive")
        XCTAssertEqual(store.playedSongIds(forSession: current), ["s1"])
        // Persisted: a reloaded store agrees (flush() forces the async writer to disk).
        store.flush()
        XCTAssertEqual(MixSessionStore(fileURL: storeURL).recordings(forSession: current).count, 1)
    }

    func testDeleteRecordingPrunesEmptiedSessionFolder() throws {
        let store = MixSessionStore(fileURL: storeURL)
        let current = store.currentId
        _ = try addTake(store, sessionId: current, name: "recording-1.m4a")
        let rec = try XCTUnwrap(store.recordings(forSession: current).first)

        XCTAssertTrue(store.deleteRecording(sessionId: current, recordingId: rec.id, bookmark: nil))

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(current).path),
                       "last take gone → the app-named session folder is tidied away")
    }

    /// A take in a currently-unreachable user folder is refused — nothing deleted,
    /// metadata kept (same no-silent-orphaning rule as delete-all).
    func testDeleteRecordingRefusesUnreachableUserFolderTake() {
        let store = MixSessionStore(fileURL: storeURL)
        let current = store.currentId
        store.addRecording(toSession: current, fileName: "recording-1.m4a",
                           startedAt: 1_000, durationMs: 2_000, wasUserFolder: true)
        let rec = store.recordings(forSession: current)[0]

        XCTAssertFalse(store.deleteRecording(sessionId: current, recordingId: rec.id, bookmark: nil))
        XCTAssertEqual(store.recordings(forSession: current).count, 1, "metadata kept")
    }

    /// A stale record (reachable root, file already gone) just drops its metadata.
    func testDeleteRecordingDropsStaleRecordWhoseFileIsGone() {
        let store = MixSessionStore(fileURL: storeURL)
        let current = store.currentId
        store.addRecording(toSession: current, fileName: "recording-1.m4a",
                           startedAt: 1_000, durationMs: 2_000, wasUserFolder: false)

        XCTAssertTrue(store.deleteRecording(sessionId: current,
                                            recordingId: store.recordings(forSession: current)[0].id,
                                            bookmark: nil))
        XCTAssertTrue(store.recordings(forSession: current).isEmpty)
    }

    func testDeleteRecordingUnknownIdsAreNoOps() {
        let store = MixSessionStore(fileURL: storeURL)
        XCTAssertFalse(store.deleteRecording(sessionId: "nope", recordingId: "rec1", bookmark: nil))
        XCTAssertFalse(store.deleteRecording(sessionId: store.currentId, recordingId: "nope", bookmark: nil))
    }

    func testRecordingsUsageBytesCountsTakes() throws {
        let store = MixSessionStore(fileURL: storeURL)
        try addTake(store, sessionId: store.currentId, name: "recording-1.m4a", bytes: 6)
        try addTake(store, sessionId: store.currentId, name: "recording-2.m4a", bytes: 4)
        XCTAssertEqual(SessionFolders.recordingsUsageBytes(bookmark: nil), 10)
        store.deleteAllRecordings(bookmark: nil)
        XCTAssertEqual(SessionFolders.recordingsUsageBytes(bookmark: nil), 0)
    }
}
