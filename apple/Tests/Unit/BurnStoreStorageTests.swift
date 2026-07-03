import XCTest
@testable import PocketDJ

/// Storage manager — BurnStore's bulk delete + usage surface. All tests run against a
/// HERMETIC app-burns root (`appBurnsDirOverride`) so they can never touch this machine's
/// real burned files. Items are seeded by writing the store's own Document JSON (the
/// decode-on-init path), and the on-disk files are created with exact byte sizes.
///
/// Everything here deletes DOWNLOADED media only — there is deliberately no catalog or
/// collections involvement to test, because the API never touches them.
@MainActor
final class BurnStoreStorageTests: XCTestCase {

    private var dir: URL!            // the hermetic app-burns root
    private var indexURL: URL!       // the store's ledger json

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-storage-index-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
        super.tearDown()
    }

    // MARK: Fixtures

    private func item(_ id: String, artist: String = "Artist", audio: String,
                      bytes: Int, source: String = "digital", downloadedAt: Double = 0,
                      state: BurnStore.State = .ready, cut: String? = nil) -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: "T-\(id)", artist: artist,
                           audioFileName: audio, sidecarFileName: "\(id).txt",
                           source: source, bpm: nil, musicalKey: nil, camelot: nil,
                           durationMs: nil, startMs: nil, bytes: bytes, rippedAt: nil,
                           downloadedAt: downloadedAt, state: state, error: nil,
                           wasAppStorage: true, cutFileName: cut, cutDownloadedAt: nil)
    }

    /// Seed the ledger + matching files: audio files get their recorded byte size, every
    /// item gets a 1-byte sidecar.
    private func makeStore(_ items: [BurnStore.BurnItem]) throws -> BurnStore {
        let doc = BurnStore.Document(items: items)
        try JSONEncoder().encode(doc).write(to: indexURL)
        var written = Set<String>()
        for it in items where it.state == .ready {
            if !it.audioFileName.isEmpty && written.insert(it.audioFileName).inserted {
                try Data(repeating: 0, count: it.bytes).write(to: dir.appendingPathComponent(it.audioFileName))
            }
            if !it.sidecarFileName.isEmpty {
                try Data([0x1]).write(to: dir.appendingPathComponent(it.sidecarFileName))
            }
        }
        let store = BurnStore(rips: RipsStore(), fileURL: indexURL)
        store.appBurnsDirOverride = dir
        return store
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    // MARK: removeBurns

    func testRemoveBurnsDeletesFilesAndLedgerAndPersists() throws {
        let store = try makeStore([
            item("s1", audio: "a-s1.mp3", bytes: 10),
            item("s2", audio: "a-s2.mp3", bytes: 20),
        ])
        store.removeBurns(songIds: ["s1"])
        XCTAssertFalse(exists("a-s1.mp3"))
        XCTAssertFalse(exists("s1.txt"))
        XCTAssertTrue(exists("a-s2.mp3"))
        XCTAssertNil(store.items["s1"])
        XCTAssertNotNil(store.items["s2"])
        // Persisted: a reloaded store only knows s2.
        let reloaded = BurnStore(rips: RipsStore(), fileURL: indexURL)
        XCTAssertNil(reloaded.items["s1"])
        XCTAssertNotNil(reloaded.items["s2"])
    }

    /// The analog whole-album mp3 is SHARED across the album's songs — it must survive
    /// while any surviving item still references it, and go when the last one does.
    func testRemoveBurnsKeepsSharedAnalogAlbumUntilLastSongGoes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
        ])
        store.removeBurns(songIds: ["s1"])
        XCTAssertTrue(exists("album-alb1.mp3"), "shared album file must survive s2")
        store.removeBurns(songIds: ["s2"])
        XCTAssertFalse(exists("album-alb1.mp3"), "last reference gone → file deleted")
    }

    /// A batch containing BOTH songs of a shared album deletes the album file in one call.
    func testRemoveBurnsBatchDeletesSharedAlbumWhenWholeGroupGoes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
        ])
        store.removeBurns(songIds: ["s1", "s2"])
        XCTAssertFalse(exists("album-alb1.mp3"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRemoveBurnsDeletesCutStemsAndBeatgrid() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 50, source: "analog", cut: "cut-s1.mp3"),
        ])
        try write("cut-s1.mp3", bytes: 5)
        for part in ["vocals", "drums", "bass", "other"] { try write("stem-s1-\(part).mp3", bytes: 3) }
        try write("analysis-s1.json", bytes: 2)
        store.removeBurns(songIds: ["s1"])
        XCTAssertFalse(exists("cut-s1.mp3"))
        XCTAssertFalse(exists("stem-s1-vocals.mp3"))
        XCTAssertFalse(exists("stem-s1-other.mp3"))
        XCTAssertFalse(exists("analysis-s1.json"))
    }

    // MARK: removeAllBurns

    func testRemoveAllBurnsSweepsUntrackedAuxButKeepsForeignFiles() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])
        try write("stem-zzz-vocals.mp3", bytes: 4)   // stems for a song NOT in the ledger
        try write("analysis-zzz.json", bytes: 4)
        try write("keep-me.pdf", bytes: 9)           // a user file in a user-picked folder
        store.removeAllBurns()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(exists("a-s1.mp3"))
        XCTAssertFalse(exists("stem-zzz-vocals.mp3"))
        XCTAssertFalse(exists("analysis-zzz.json"))
        XCTAssertTrue(exists("keep-me.pdf"), "never delete files this app didn't write")
    }

    // MARK: Usage measurement

    func testBurnedUsageBytesCountsOnlyOurFiles() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])   // + 1-byte sidecar
        try write("stem-s1-vocals.mp3", bytes: 7)
        try write("analysis-s1.json", bytes: 3)
        try write("unrelated.bin", bytes: 100)
        XCTAssertEqual(store.burnedUsageBytes(), 10 + 1 + 7 + 3)
    }

    func testUsageByArtistGroupsAndCountsSharedAudioOnce() throws {
        let store = try makeStore([
            item("s1", artist: "Beta", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", artist: "Beta", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s3", artist: "Alpha", audio: "a-s3.mp3", bytes: 30),
            item("s4", artist: "Alpha", audio: "a-s4.mp3", bytes: 40, state: .error),   // not ready → excluded
        ])
        let rows = store.usageByArtist()
        XCTAssertEqual(rows.map(\.artist), ["Alpha", "Beta"])   // sorted
        XCTAssertEqual(rows[0].songIds, ["s3"])
        XCTAssertEqual(rows[0].bytes, 30)
        XCTAssertEqual(rows[1].songIds, ["s1", "s2"])
        XCTAssertEqual(rows[1].bytes, 100, "shared album mp3 counted once, not per song")
    }

    func testReadyBurnedIdsAndApproximateBytes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s3", audio: "a-s3.mp3", bytes: 30, state: .error),
        ])
        XCTAssertEqual(store.readyBurnedIds(in: ["s1", "s2", "s3", "nope"]).sorted(), ["s1", "s2"])
        XCTAssertEqual(store.approximateBytes(forSongs: ["s1", "s2"]), 100)
    }
}
