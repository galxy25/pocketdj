import XCTest
@testable import PocketDJ

@MainActor
final class ProfileAudioStoreTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-audio-\(UUID().uuidString)")
        ProfileAudioFolders.rootOverride = tmpRoot
    }
    override func tearDown() {
        ProfileAudioFolders.rootOverride = nil
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        super.tearDown()
    }

    private func store() -> ProfileSourceStore {
        ProfileSourceStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-src-\(UUID().uuidString).json"))
    }
    /// A tiny throwaway source file (bytes are irrelevant — ingest copies byte-exact).
    private func srcFile(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        try? Data("audio-\(name)".utf8).write(to: u)
        return u
    }

    func testIngestRoundTripAndResolve() async throws {
        let s = store()
        let made = await s.ingest(kind: .sample, title: "Kick", originalURL: srcFile("kick"),
                                  durationMs: 2000, bpm: 120)
        let e = try XCTUnwrap(made)
        XCTAssertTrue(ProfileSourceStore.isProfileSongId(e.songId))
        XCTAssertEqual(s.songs.map(\.songId), [e.songId])            // record filed
        let res = try XCTUnwrap(s.localURLForPlayback(id: e.songId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.url.path))
        XCTAssertNil(res.release)                                    // app-managed ⇒ no security scope
        XCTAssertEqual(res.title, "Kick")
        XCTAssertEqual(res.lengthMs, 2000)
        XCTAssertTrue(s.hasLocalAsset(e.songId))
    }

    func testMissingFileResolvesNil() async throws {
        let s = store()
        let made = await s.ingest(kind: .demux, title: "T", originalURL: srcFile("t"))
        let e = try XCTUnwrap(made)
        // Delete the underlying file out from under the record (simulates a fresh device that synced
        // the metadata but not the asset) — resolve + gate must report absence, record stays.
        let url = try XCTUnwrap(ProfileAudioFolders.resolveOriginal(fileName: e.fileName))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(s.localURLForPlayback(id: e.songId))
        XCTAssertFalse(s.hasLocalAsset(e.songId))
        XCTAssertNotNil(s.entry(e.songId))                           // record NOT pruned
    }

    func testBareNameGuardRejectsPathSeparator() {
        XCTAssertNil(ProfileAudioFolders.resolveOriginal(fileName: "../evil.m4a"))
        XCTAssertNil(ProfileAudioFolders.resolveOriginal(fileName: "sub/dir.m4a"))
        XCTAssertNil(ProfileAudioFolders.resolveOriginal(fileName: ""))
    }

    func testStemsAllOrNothing() async throws {
        let s = store()
        let stems = Dictionary(uniqueKeysWithValues: StemPlayer.stems.map { ($0, srcFile($0)) })
        let made = await s.ingest(kind: .demux, title: "Full", originalURL: srcFile("orig"), stems: stems)
        let e = try XCTUnwrap(made)
        XCTAssertEqual(Set(try XCTUnwrap(s.stemURLs(id: e.songId)).keys), Set(StemPlayer.stems))

        // 3-of-4 → ingest returns nil (all-or-nothing) AND files no record.
        var partial = stems; partial.removeValue(forKey: "other")
        let before = s.songs.count
        let e2 = await s.ingest(kind: .demux, title: "Partial", originalURL: srcFile("orig2"), stems: partial)
        XCTAssertNil(e2)
        XCTAssertEqual(s.songs.count, before)
    }

    func testDeleteAssetRemovesFilesAndRecord() async throws {
        let s = store()
        let made = await s.ingest(kind: .sample, title: "X", originalURL: srcFile("x"))
        let e = try XCTUnwrap(made)
        s.deleteAsset(id: e.songId)
        XCTAssertNil(s.entry(e.songId))
        XCTAssertFalse(s.hasLocalAsset(e.songId))
    }

    /// Account deletion (`AccountDeletionService` step 3) must leave NOTHING behind: `clear()`
    /// wipes the JSON metadata AND the whole `profile-audio/` tree (originals + stems), so a
    /// re-created account can't re-surface the deleted user's custom audio. Regression for the
    /// pre-ship review's major finding.
    func testClearWipesJSONAndAllAudio() async throws {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-src-\(UUID().uuidString).json")
        let s = ProfileSourceStore(fileURL: jsonURL)
        let stems = Dictionary(uniqueKeysWithValues: StemPlayer.stems.map { ($0, srcFile($0)) })
        let made = await s.ingest(kind: .demux, title: "Full", originalURL: srcFile("orig"), stems: stems)
        _ = try XCTUnwrap(made)
        let audioDir = try ProfileAudioFolders.dir()
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))   // JSON written
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path))  // original + stems on disk

        s.clear()

        XCTAssertTrue(s.songs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))   // JSON gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDir.path))  // profile-audio/ gone (originals + stems)
    }

    /// The fence predicate: pdj_ song ids match; the pdjalb_ album ids and catalog ids do NOT.
    func testIsProfileSongIdVsAlbumId() {
        XCTAssertTrue(ProfileSourceStore.isProfileSongId("pdj_abc"))
        XCTAssertFalse(ProfileSourceStore.isProfileSongId("pdjalb_samples"))
        XCTAssertFalse(ProfileSourceStore.isProfileSongId("sng_1"))
    }
}
