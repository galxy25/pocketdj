import XCTest
@testable import PocketDJ

/// StorageManager — the soft-cap prune engine. The cap is UNSET by default, and an unset
/// cap must mean the app NEVER deletes media on its own; when set, the once-a-day pass
/// evicts least-recently-played burned songs (never-played first, oldest download breaking
/// ties) until the burned footprint fits, skipping anything currently loaded/playing.
/// Hermetic: burns live under `appBurnsDirOverride`, settings in a throwaway suite.
@MainActor
final class StorageManagerTests: XCTestCase {

    private var dir: URL!
    private var indexURL: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-prune-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-prune-index-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
        super.tearDown()
    }

    // MARK: Fixtures

    /// Three ready 10-byte digital burns (30 bytes total, sidecars excluded by bytes: 0…
    /// sidecar files are 0-byte so the arithmetic stays in the audio).
    private func makeWorld(items: [(id: String, downloadedAt: Double)])
        throws -> (burns: BurnStore, stats: PlayStatsStore, settings: SettingsStore, mgr: StorageManager) {
        let burnItems = items.map {
            BurnStore.BurnItem(songId: $0.id, title: $0.id, artist: "A",
                               audioFileName: "audio-\($0.id).mp3", sidecarFileName: "\($0.id).txt",
                               source: "digital", bpm: nil, musicalKey: nil, camelot: nil,
                               durationMs: nil, startMs: nil, bytes: 10, rippedAt: nil,
                               downloadedAt: $0.downloadedAt, state: .ready, error: nil,
                               wasAppStorage: true)
        }
        try JSONEncoder().encode(BurnStore.Document(items: burnItems)).write(to: indexURL)
        for it in burnItems {
            try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent(it.audioFileName))
            try Data().write(to: dir.appendingPathComponent(it.sidecarFileName))
        }
        let burns = BurnStore(rips: RipsStore(), fileURL: indexURL)
        burns.appBurnsDirOverride = dir
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-prune-stats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: statsURL) }
        let stats = PlayStatsStore(fileURL: statsURL)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let mgr = StorageManager(burns: burns, playStats: stats, settings: settings)
        return (burns, stats, settings, mgr)
    }

    private func gb(_ bytes: Int) -> Double { Double(bytes) / StorageManager.bytesPerGB }

    // MARK: Unset cap ⇒ fully manual

    func testUnsetCapNeverPrunes() throws {
        let w = try makeWorld(items: [("s1", 1), ("s2", 2), ("s3", 3)])
        XCTAssertNil(w.settings.storageSoftCapGB, "cap must default to UNSET")
        XCTAssertNil(w.mgr.pruneNow(now: 1_000))
        w.mgr.pruneIfDue(now: 1_000)
        XCTAssertEqual(w.burns.items.count, 3, "no cap ⇒ nothing is ever auto-deleted")
        XCTAssertNil(w.settings.lastStoragePruneAt)
    }

    // MARK: LRP order

    func testPruneEvictsLeastRecentlyPlayedFirstAndStopsUnderCap() throws {
        // s3 never played (oldest download), s1 played long ago, s2 played just now.
        let w = try makeWorld(items: [("s1", 100), ("s2", 200), ("s3", 50)])
        w.stats.notePlayed("s1", at: 10_000)
        w.stats.notePlayed("s2", at: 99_000)
        w.settings.storageSoftCapGB = gb(15)   // usage 30 (audio) → evict twice to reach ≤15
        let result = try XCTUnwrap(w.mgr.pruneNow(now: 100_000))
        XCTAssertEqual(result.evicted, 2)
        XCTAssertNil(w.burns.items["s3"], "never-played goes first")
        XCTAssertNil(w.burns.items["s1"], "then the least-recently-played")
        XCTAssertNotNil(w.burns.items["s2"], "most-recent survives — prune stops under the cap")
        XCTAssertLessThanOrEqual(result.usageBytes, 15)
        XCTAssertEqual(result.freedBytes, 20)
        XCTAssertEqual(w.settings.lastStoragePruneAt, 100_000)
    }

    func testNeverPlayedTieBreaksOnOldestDownload() throws {
        let w = try makeWorld(items: [("s1", 300), ("s2", 100), ("s3", 200)])
        w.settings.storageSoftCapGB = gb(25)   // one eviction suffices (30 → 20)
        _ = w.mgr.pruneNow(now: 1_000)
        XCTAssertNil(w.burns.items["s2"], "oldest download evicted first among never-played")
        XCTAssertNotNil(w.burns.items["s1"])
        XCTAssertNotNil(w.burns.items["s3"])
    }

    /// A substituted (cleanOnly) burn is keyed by its RESOLVING id ("sng_…_clean") while its
    /// plays are recorded against the BASE song, so the LRP sort must read recency through
    /// `SongVariant.baseId`. Without that, every variant burn reports never-played and is
    /// evicted ahead of genuinely cold files — here the freshly-played clean cut would be
    /// dropped (its download is the oldest, so it also loses the never-played tie-break)
    /// while an untouched song survives.
    func testVariantBurnRecencyReadsThroughTheBaseSong() throws {
        let variantId = "sng_1a7f6bc854af_clean"
        let w = try makeWorld(items: [(variantId, 100), ("s_cold", 300), ("s_warm", 400)])
        w.stats.notePlayed("sng_1a7f6bc854af", at: 99_000)   // the play keys the BASE song
        w.stats.notePlayed("s_warm", at: 50_000)
        w.settings.storageSoftCapGB = gb(25)                 // 30 → one eviction
        let result = try XCTUnwrap(w.mgr.pruneNow(now: 100_000))
        XCTAssertEqual(result.evicted, 1)
        XCTAssertNil(w.burns.items["s_cold"], "the genuinely never-played burn goes first")
        XCTAssertNotNil(w.burns.items[variantId],
                        "a just-played variant burn is not 'never played' — its stats key the base id")
        XCTAssertNotNil(w.burns.items["s_warm"])
    }

    // MARK: Protected (currently playing / deck-loaded) songs

    func testPruneSkipsProtectedSongs() throws {
        let w = try makeWorld(items: [("s1", 1), ("s2", 2), ("s3", 3)])
        w.mgr.protectedSongIds = { ["s1", "s2"] }
        w.settings.storageSoftCapGB = gb(5)    // wants to evict everything…
        let result = try XCTUnwrap(w.mgr.pruneNow(now: 1_000))
        XCTAssertEqual(result.evicted, 1)
        XCTAssertNil(w.burns.items["s3"])
        XCTAssertNotNil(w.burns.items["s1"], "an open file is never pruned")
        XCTAssertNotNil(w.burns.items["s2"])
        XCTAssertGreaterThan(result.usageBytes, result.capBytes,
                             "still over cap because the protected set can't be touched")
    }

    /// Orphan aux cache (stems/grids for songs with no burned audio) is swept BEFORE any
    /// real burned song is evicted — cheap space first.
    func testPruneSweepsOrphanAuxBeforeEvictingSongs() throws {
        let w = try makeWorld(items: [("s1", 1)])   // 10 audio bytes
        // 20 bytes of orphan stem cache for a song that was never burned.
        try Data(repeating: 0, count: 20).write(to: dir.appendingPathComponent("stem-zzz-vocals.mp3"))
        w.settings.storageSoftCapGB = gb(12)        // 30 → sweep orphan (10 left) fits
        let result = try XCTUnwrap(w.mgr.pruneNow(now: 1_000))
        XCTAssertEqual(result.evicted, 0, "orphan sweep sufficed — no song evicted")
        XCTAssertNotNil(w.burns.items["s1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stem-zzz-vocals.mp3").path))
        XCTAssertEqual(result.freedBytes, 20)
    }

    // MARK: The once-a-day gate

    func testPruneIfDueHonorsDailyGate() throws {
        let w = try makeWorld(items: [("s1", 1), ("s2", 2)])
        w.settings.storageSoftCapGB = gb(5)
        let day: Double = 24 * 3600 * 1000

        // Ran 1 h ago → not due.
        w.settings.lastStoragePruneAt = day - 3_600_000
        w.mgr.pruneIfDue(now: day)
        XCTAssertEqual(w.burns.items.count, 2)

        // Ran 21 h ago (> the 20 h gate) → due.
        w.settings.lastStoragePruneAt = day - 21 * 3_600_000
        w.mgr.pruneIfDue(now: day)
        XCTAssertLessThan(w.burns.items.count, 2)
        XCTAssertEqual(w.settings.lastStoragePruneAt, day)
    }

    func testPruneIfDueRunsWhenNeverRan() throws {
        let w = try makeWorld(items: [("s1", 1), ("s2", 2)])
        w.settings.storageSoftCapGB = gb(5)
        XCTAssertNil(w.settings.lastStoragePruneAt)
        w.mgr.pruneIfDue(now: 1_000)
        XCTAssertLessThan(w.burns.items.count, 2)
    }

    func testUnderCapStampsRunWithoutEvicting() throws {
        let w = try makeWorld(items: [("s1", 1)])
        w.settings.storageSoftCapGB = gb(1_000)
        let result = try XCTUnwrap(w.mgr.pruneNow(now: 42_000))
        XCTAssertEqual(result.evicted, 0)
        XCTAssertEqual(w.burns.items.count, 1)
        XCTAssertEqual(w.settings.lastStoragePruneAt, 42_000)
    }
}
