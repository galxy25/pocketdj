import XCTest
@testable import PocketDJ

/// SessionFolders — the per-session on-disk folder resolver (app storage vs the user-picked session
/// folder). These exercise the APP-STORAGE path (no bookmark); the user-folder path mirrors the
/// burnt-music folder, whose bookmark resolution is covered by BurnStore's tests.
final class SessionFoldersTests: XCTestCase {

    func testAppStorageSessionFolderCreatesSubdir() throws {
        let id = "sesstest-\(UUID().uuidString)"
        let folder = try XCTUnwrap(SessionFolders.sessionFolder(id, bookmark: nil))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        XCTAssertFalse(folder.isUserFolder)
        XCTAssertNil(folder.release)                          // app storage → no security scope
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.path))
        XCTAssertEqual(folder.url.lastPathComponent, id)      // one folder per session id
    }

    func testRecordingURLResolvesOnlyExistingFiles() throws {
        let id = "sesstest-\(UUID().uuidString)"
        let folder = try XCTUnwrap(SessionFolders.sessionFolder(id, bookmark: nil))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        // Missing file → nil (don't hand back a URL that isn't there).
        XCTAssertNil(SessionFolders.recordingURL(sessionId: id, fileName: "recording-1.m4a",
                                                 wasUserFolder: false, bookmark: nil))
        // Write the file, then it resolves to exactly that path.
        let file = folder.url.appendingPathComponent("recording-1.m4a")
        try Data([0x00, 0x01]).write(to: file)
        let resolved = try XCTUnwrap(SessionFolders.recordingURL(sessionId: id, fileName: "recording-1.m4a",
                                                                 wasUserFolder: false, bookmark: nil))
        XCTAssertEqual(resolved.url.path, file.path)
        XCTAssertNil(resolved.release)
    }

    /// A recording tagged as living in the USER folder can't resolve when no folder is configured (the
    /// user-picked folder is "gone") — mirrors `BurnStore.itemDir` returning nil for a missing folder.
    func testUserFolderRecordingWithNoBookmarkDoesNotResolve() {
        XCTAssertNil(SessionFolders.recordingURL(sessionId: "x", fileName: "r.m4a",
                                                 wasUserFolder: true, bookmark: nil))
    }
}
