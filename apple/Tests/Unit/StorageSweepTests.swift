import XCTest
@testable import PocketDJ

/// np-mix-mode PHASE 1 — the temporary-asset EXPIRY SWEEP (`StorageManager.sweepTemporary`) and
/// its settings. Data-loss contract: the sweep deletes ONLY what a hold lists, never a pinned
/// file, never anything protected (playing / up next / Mix decks / in flight / the restored
/// session), keeps rows on unreachable folders, and runs chunked with the stamp written first.
/// Hermetic: burns under `appBurnsDirOverride`, settings in a throwaway suite.
@MainActor
final class StorageSweepTests: XCTestCase {
    private var dir: URL!
    private var indexURL: URL!
    private let now: Double = 1_900_000_000_000
    private let hourMs: Double = 3_600_000

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-sweep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-sweep-index-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
        super.tearDown()
    }

    // MARK: Fixtures

    private struct World {
        let burns: BurnStore
        let settings: SettingsStore
        let mgr: StorageManager
    }

    private func item(_ id: String, file: String? = nil, appStorage: Bool = true,
                      source: String = "digital") -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: "T-\(id)", artist: "A",
                           audioFileName: file ?? "\(id).mp3", sidecarFileName: "\(id).txt",
                           source: source, bpm: nil, musicalKey: nil, camelot: nil,
                           durationMs: nil, startMs: nil, bytes: 10, rippedAt: nil,
                           downloadedAt: 1, state: .ready, error: nil, wasAppStorage: appStorage)
    }

    private func makeWorld(_ items: [BurnStore.BurnItem] = [], writeFiles: Bool = true) throws -> World {
        try JSONEncoder().encode(BurnStore.Document(items: items)).write(to: indexURL)
        if writeFiles {
            for it in items where it.wasAppStorage ?? true {
                try write(it.audioFileName); try write(it.sidecarFileName)
            }
        }
        let burns = BurnStore(rips: RipsStore(), fileURL: indexURL)
        burns.appBurnsDirOverride = dir
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-sweep-stats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: statsURL) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        burns.settings = settings
        let mgr = StorageManager(burns: burns, playStats: PlayStatsStore(fileURL: statsURL), settings: settings)
        return World(burns: burns, settings: settings, mgr: mgr)
    }

    private func write(_ name: String, bytes: Int = 10) throws {
        try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent(name))
    }
    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }
    private func stemsOnDisk(_ id: String, _ parts: [String] = ["vocals", "drums", "bass", "other"]) throws {
        for p in parts { try write("stem-\(id)-\(p).mp3") }
    }

    /// A hold that expired `agoHours` before `now` (negative ⇒ still in the future).
    private func hold(_ id: String, audio: Bool = false, parts: [String] = [], agoHours: Double = 1,
                      bytes: Int = 10) -> BurnStore.TemporaryHold {
        BurnStore.TemporaryHold(songId: id, audio: audio, stemParts: parts,
                                createdAtMs: now - (48 + agoHours) * hourMs,
                                expiresAtMs: now - agoHours * hourMs,
                                audioBytes: audio ? bytes : nil,
                                stemBytes: Dictionary(uniqueKeysWithValues: parts.map { ($0, bytes) }))
    }

    // MARK: Deletes ONLY what the hold lists

    func testSweepDeletesOnlyTheListedStemPartsAndNothingPinned() async throws {
        let w = try makeWorld([item("s1")])
        try stemsOnDisk("s1")
        w.burns.injectHoldForTesting(hold("s1", parts: ["vocals", "drums"]))
        let r = await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertEqual(r?.removed, 1)
        XCTAssertFalse(exists("stem-s1-vocals.mp3")); XCTAssertFalse(exists("stem-s1-drums.mp3"))
        XCTAssertTrue(exists("stem-s1-bass.mp3"), "an unlisted (pinned) part is never touched")
        XCTAssertTrue(exists("stem-s1-other.mp3"))
        XCTAssertTrue(exists("s1.mp3"), "the pinned audio is never touched")
        XCTAssertNotNil(w.burns.items["s1"], "the pinned ledger row survives")
        XCTAssertTrue(w.burns.temporaryHolds.isEmpty)
    }

    /// A temporary AUDIO hold removes the row, the audio and its sidecar — but NOT stems the
    /// hold doesn't list (e.g. stems the user burned from Song Detail earlier).
    func testAudioHoldRemovesRowAudioSidecarButNotUnlistedStems() async throws {
        let w = try makeWorld([item("s2")])
        try stemsOnDisk("s2")
        w.burns.injectHoldForTesting(hold("s2", audio: true))
        await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertNil(w.burns.items["s2"])
        XCTAssertFalse(exists("s2.mp3")); XCTAssertFalse(exists("s2.txt"))
        XCTAssertTrue(exists("stem-s2-vocals.mp3"), "unlisted stems are not the hold's to delete")
    }

    func testPinnedSongsWithNoHoldAreNeverSwept() async throws {
        let w = try makeWorld([item("p1"), item("p2"), item("t1")])
        try stemsOnDisk("p1")
        w.burns.injectHoldForTesting(hold("t1", audio: true))
        let r = await w.mgr.sweepTemporary(now: now, reason: "test", ignoreExpiry: true)
        XCTAssertEqual(r?.removed, 1)
        XCTAssertEqual(Set(w.burns.items.keys), ["p1", "p2"])
        XCTAssertTrue(exists("p1.mp3")); XCTAssertTrue(exists("p2.mp3"))
        XCTAssertTrue(exists("stem-p1-vocals.mp3"))
    }

    func testUnexpiredHoldsSurviveAnExpirySweep() async throws {
        let w = try makeWorld([item("u1"), item("e1")])
        w.burns.injectHoldForTesting(hold("u1", audio: true, agoHours: -5))   // expires in 5 h
        w.burns.injectHoldForTesting(hold("e1", audio: true, agoHours: 0))    // expires exactly now
        await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertNotNil(w.burns.items["u1"]); XCTAssertTrue(exists("u1.mp3"))
        XCTAssertNotNil(w.burns.temporaryHolds["u1"])
        XCTAssertNil(w.burns.items["e1"], "expiresAt <= now ⇒ expired")
    }

    // MARK: Protection

    /// An expired hold in use (the current song, up next, a deck, in flight…) is skipped and
    /// re-checked on the next sweep — it lives until nothing uses it.
    func testProtectedExpiredHoldSurvivesAndGoesOnceReleased() async throws {
        let w = try makeWorld([item("np")])
        try stemsOnDisk("np")
        w.burns.injectHoldForTesting(hold("np", audio: true, parts: ["vocals"]))
        var protected: Set<String> = ["np"]
        w.mgr.protectedSongIds = { protected }
        let r1 = await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertEqual(r1?.removed, 0)
        XCTAssertEqual(r1?.skippedProtected, 1)
        XCTAssertTrue(exists("np.mp3")); XCTAssertTrue(exists("stem-np-vocals.mp3"))
        protected = []
        let r2 = await w.mgr.sweepTemporary(now: now + 1, reason: "test")
        XCTAssertEqual(r2?.removed, 1)
        XCTAssertFalse(exists("np.mp3"))
    }

    /// The protected set is matched through the BASE id: a playing base row spares its edition
    /// variant's file and vice versa.
    func testProtectionCoversEditionVariants() async throws {
        let base = "sng_0123456789ab"
        let w = try makeWorld([item("\(base)_clean")])
        w.burns.injectHoldForTesting(hold("\(base)_clean", audio: true))
        w.mgr.protectedSongIds = { [base] }
        await w.mgr.sweepTemporary(now: now, reason: "test", ignoreExpiry: true)
        XCTAssertNotNil(w.burns.items["\(base)_clean"])
    }

    /// The SetlistPlayer's window: current + the next rows, held (restored) sessions included.
    func testSetlistWindowProtectsCurrentUpcomingAndHeldSessions() throws {
        let rips = RipsStore()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sp = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        addTeardownBlock { @MainActor in sp.stop() }
        XCTAssertTrue(sp.protectedWindowSongIds().isEmpty, "no session ⇒ nothing")
        let rows = (0..<8).map { PlaybackSessionStore.Row(songId: "q\($0)", title: "T", artist: "A") }
        sp.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "s", source: .init(kind: "queue"), queue: rows, index: 2, positionMs: 0,
            isPlaying: false, updatedAt: 0))
        XCTAssertTrue(sp.isHeldForResume, "a restore is HELD")
        XCTAssertEqual(sp.protectedWindowSongIds(), ["q2", "q3", "q4", "q5"],
                       "current + prefetchAhead (3) rows of the held session")
    }

    /// Before any restore ran, the PERSISTED session's window is protected (a cold-launch sweep
    /// can beat `SetlistPlayer.restore`).
    func testPersistedSessionWindowIsReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-sweep-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var rows = (0..<6).map { PlaybackSessionStore.Row(songId: "sng_00000000000\($0)", title: "T", artist: "A") }
        rows[2].variant = SongVariant.clean.rawValue
        let snap = PlaybackSessionStore.Snapshot(sessionId: "s", source: .init(kind: "queue"), queue: rows,
                                                 index: 1, positionMs: 0, isPlaying: false, updatedAt: 0)
        try JSONEncoder().encode(snap).write(to: url)
        let store = PlaybackSessionStore(fileURL: url)
        XCTAssertEqual(store.windowSongIds(ahead: 2),
                       ["sng_000000000001", "sng_000000000002", "sng_000000000002_clean", "sng_000000000003"])
    }

    // MARK: Shared analog side / unreachable folder

    func testSharedAnalogSideSurvivesWhileAPinnedSiblingReferencesIt() async throws {
        let side = "Artist-Album-alb_1.mp3"
        let w = try makeWorld([item("a1", file: side, source: "analog"), item("a2", file: side, source: "analog")])
        w.burns.injectHoldForTesting(hold("a2", audio: true))
        await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertNil(w.burns.items["a2"], "the temporary row goes")
        XCTAssertFalse(exists("a2.txt"))
        XCTAssertTrue(exists(side), "the shared side stays while the pinned a1 references it")
        XCTAssertNotNil(w.burns.localURL(forSong: "a1"))
    }

    func testUnreachableUserFolderKeepsItsRowAndHold() async throws {
        // A user-folder item with NO resolvable bookmark ⇒ its dir is unreachable right now.
        let w = try makeWorld([item("uf", appStorage: false)], writeFiles: false)
        w.burns.injectHoldForTesting(hold("uf", audio: true))
        let r = await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertEqual(r?.kept, 1)
        XCTAssertNotNil(w.burns.items["uf"], "never drop a row whose files can't be deleted")
        XCTAssertNotNil(w.burns.temporaryHolds["uf"], "retried next sweep")
    }

    func testDanglingHoldIsSimplyDropped() async throws {
        let w = try makeWorld()
        w.burns.injectHoldForTesting(hold("gone", audio: true))
        let r = await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertEqual(r?.removed, 1)
        XCTAssertTrue(w.burns.temporaryHolds.isEmpty)
    }

    // MARK: Cap (2 GB default) — soonest expiry first

    func testCapEvictsSoonestExpiringFirstAndStopsUnderTheCap() async throws {
        let w = try makeWorld([item("c1"), item("c2"), item("c3")])
        // None expired; 3 × 400 MB = 1.2 GB against a 0.5 GB cap ⇒ evict until ≤ 0.5 GB.
        let mb400 = 400_000_000
        w.burns.injectHoldForTesting(hold("c1", audio: true, agoHours: -30, bytes: mb400))
        w.burns.injectHoldForTesting(hold("c2", audio: true, agoHours: -10, bytes: mb400))
        w.burns.injectHoldForTesting(hold("c3", audio: true, agoHours: -20, bytes: mb400))
        w.settings.npMixBufferCapGB = 0.5
        await w.mgr.sweepTemporary(now: now, reason: "cap")
        XCTAssertNil(w.burns.items["c2"], "soonest expiry goes first")
        XCTAssertNil(w.burns.items["c3"])
        XCTAssertNotNil(w.burns.items["c1"], "under the cap ⇒ stop")
    }

    func testCapNeverEvictsProtectedHolds() async throws {
        let w = try makeWorld([item("c1"), item("c2")])
        w.burns.injectHoldForTesting(hold("c1", audio: true, agoHours: -10, bytes: 900_000_000))
        w.burns.injectHoldForTesting(hold("c2", audio: true, agoHours: -20, bytes: 900_000_000))
        w.settings.npMixBufferCapGB = 0.5
        w.mgr.protectedSongIds = { ["c1"] }
        await w.mgr.sweepTemporary(now: now, reason: "cap")
        XCTAssertNotNil(w.burns.items["c1"], "over cap or not, protected stays")
        XCTAssertNil(w.burns.items["c2"])
    }

    func testPurePlanOrdersExpiredThenCap() {
        let holds = [hold("x", audio: true, agoHours: 1), hold("y", audio: true, agoHours: 5),
                     hold("z", audio: true, agoHours: -1, bytes: 100), hold("w", audio: true, agoHours: -9, bytes: 100)]
        let p = StorageManager.planSweep(holds: holds, now: now, capBytes: 115, protected: ["x"])
        XCTAssertEqual(p.delete, ["y", "z"], "expired (soonest first, protected skipped), then cap by expiry")
        XCTAssertEqual(p.skippedProtected, 1)
    }

    // MARK: Races — pin mid-sweep, single flight

    /// A pin landing BETWEEN chunks (a deck load, a Download tap) is honoured: the re-validated
    /// chunk skips the now-pinned song.
    func testPinBetweenChunksIsHonoured() async throws {
        let ids = (0..<60).map { String(format: "r%03d", $0) }
        let w = try makeWorld(ids.map { item($0) })
        for (i, id) in ids.enumerated() { w.burns.injectHoldForTesting(hold(id, audio: true, agoHours: 100 - Double(i))) }
        var calls = 0
        w.mgr.protectedSongIds = { [burns = w.burns] in
            calls += 1
            // Call 1 = the plan; call 2 = chunk 0's re-read — the pin lands AFTER planning.
            if calls == 2 { burns.pin(songIds: ["r059", "r030"], reason: "mid-sweep") }
            return []
        }
        await w.mgr.sweepTemporary(now: now, reason: "test")
        XCTAssertNotNil(w.burns.items["r059"], "pinned mid-sweep ⇒ kept")
        XCTAssertNotNil(w.burns.items["r030"])
        XCTAssertTrue(exists("r059.mp3"))
        XCTAssertNil(w.burns.items["r000"])
        XCTAssertEqual(w.burns.items.count, 2)
    }

    func testSweepIsSingleFlight() async throws {
        let ids = (0..<30).map { "f\($0)" }
        let w = try makeWorld(ids.map { item($0) })
        for id in ids { w.burns.injectHoldForTesting(hold(id, audio: true)) }
        var second: Task<StorageManager.SweepResult?, Never>?
        w.mgr.protectedSongIds = { [mgr = w.mgr, now] in
            if second == nil { second = Task { await mgr.sweepTemporary(now: now, reason: "dup") } }
            return []
        }
        let first = await w.mgr.sweepTemporary(now: now, reason: "test")
        let dup = await second?.value
        XCTAssertEqual(first?.removed, 30)
        XCTAssertNil(dup ?? nil, "a second sweep while one runs is refused")
    }

    // MARK: Main-thread discipline (the 10-23 launch crash loop)

    /// 2 000 holds: the sweep must run in chunks of 25 (re-reading the protected set per chunk),
    /// yield the main actor between them (a concurrently queued main-actor job runs WHILE the
    /// sweep is still in progress), and write its stamp BEFORE any deletion.
    func testTwoThousandHoldSweepIsChunkedAndYieldsMain() async throws {
        let w = try makeWorld()
        for i in 0..<2_000 { w.burns.injectHoldForTesting(hold("h\(i)", parts: ["vocals"])) }
        var protectedReads = 0
        var stampAtFirstRead: Double?
        w.mgr.protectedSongIds = { [settings = w.settings] in
            if protectedReads == 0 { stampAtFirstRead = settings.lastTemporarySweepAt }
            protectedReads += 1
            return []
        }
        var observedMidSweep = false
        let sweep = Task { await w.mgr.sweepTemporary(now: now, reason: "test") }
        let probe = Task { @MainActor in
            await Task.yield()
            observedMidSweep = w.mgr.isPruning && !w.burns.temporaryHolds.isEmpty
        }
        let r = await sweep.value
        await probe.value
        XCTAssertEqual(r?.removed, 2_000)
        XCTAssertEqual(stampAtFirstRead, now, "the stamp is written FIRST, before the plan")
        XCTAssertEqual(protectedReads, 1 + 2_000 / StorageManager.sweepChunk,
                       "one plan read + one re-read per 25-hold chunk")
        XCTAssertTrue(observedMidSweep, "the main actor ran other work while the sweep was in progress")
    }

    func testSweepIfDueGateAndNoHoldsFastExit() async throws {
        let w = try makeWorld([item("g1")])
        await w.mgr.sweepTemporaryIfDue(now: now, reason: "test")
        XCTAssertNil(w.settings.lastTemporarySweepAt, "no holds ⇒ no stamp, no work")
        w.burns.injectHoldForTesting(hold("g1", audio: true))
        w.settings.lastTemporarySweepAt = now - 10 * 60 * 1000          // 10 min ago
        await w.mgr.sweepTemporaryIfDue(now: now, reason: "test")
        XCTAssertNotNil(w.burns.items["g1"], "inside the 60-min gate ⇒ skipped")
        await w.mgr.sweepTemporaryIfDue(now: now, reason: "test", minIntervalMs: 5 * 60 * 1000)
        XCTAssertNil(w.burns.items["g1"], "foreground's 5-min gate ⇒ runs")
    }

    func testClearNowIgnoresExpiryButHonoursProtection() async throws {
        let w = try makeWorld([item("k1"), item("k2")])
        w.burns.injectHoldForTesting(hold("k1", audio: true, agoHours: -40))
        w.burns.injectHoldForTesting(hold("k2", audio: true, agoHours: -40))
        w.mgr.protectedSongIds = { ["k2"] }
        await w.mgr.sweepTemporary(now: now, reason: "clear", ignoreExpiry: true)
        XCTAssertNil(w.burns.items["k1"])
        XCTAssertNotNil(w.burns.items["k2"])
    }

    /// "Keep all" pins every buffered asset: nothing is swept afterwards.
    func testKeepAllPinsEverything() async throws {
        let w = try makeWorld([item("ka")])
        w.burns.injectHoldForTesting(hold("ka", audio: true))
        XCTAssertEqual(w.burns.pinAllTemporary(reason: "test"), 1)
        await w.mgr.sweepTemporary(now: now, reason: "test", ignoreExpiry: true)
        XCTAssertNotNil(w.burns.items["ka"])
    }

    // MARK: Soft-cap prune interplay

    func testSoftCapPruneEvictsTemporaryBeforePinned() throws {
        let w = try makeWorld([item("pinnedOld"), item("tempNew")])
        // pinnedOld: never played (LRP's first pick); tempNew: buffered.
        w.burns.injectHoldForTesting(hold("tempNew", audio: true, agoHours: -40))
        w.settings.storageSoftCapGB = 25 / StorageManager.bytesPerGB   // 40 B on disk ⇒ evict one song
        w.mgr.pruneNow(now: now)
        XCTAssertNil(w.burns.items["tempNew"], "temporary first")
        XCTAssertNotNil(w.burns.items["pinnedOld"])
        XCTAssertNil(w.burns.temporaryHolds["tempNew"])
    }

    /// REVIEW FIX: the soft-cap prune removes a TEMPORARY song through its hold — the stems the
    /// user pinned for it (not listed by the hold) survive.
    func testSoftCapPruneOfATemporarySongKeepsItsPinnedStems() throws {
        let w = try makeWorld([item("tp")])
        try stemsOnDisk("tp")
        w.burns.injectHoldForTesting(hold("tp", audio: true, agoHours: -40))
        w.settings.storageSoftCapGB = 1 / StorageManager.bytesPerGB
        w.mgr.pruneNow(now: now)
        XCTAssertNil(w.burns.items["tp"])
        XCTAssertFalse(exists("tp.mp3"))
        XCTAssertTrue(exists("stem-tp-vocals.mp3"), "pinned stems are not the temporary hold's")
    }

    // MARK: Settings

    func testBufferSettingsDefaultsAndKeepOption() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertNil(s.npMixBufferTTLHours)
        XCTAssertEqual(s.npMixBufferEffectiveTTLHours, 48, "Q3 default: 48 h")
        XCTAssertEqual(s.npMixBufferCapBytes, 2_000_000_000, "Q6 default: 2 GB")
        s.npMixBufferTTLHours = SettingsStore.npMixBufferKeepSentinel
        XCTAssertNil(s.npMixBufferEffectiveTTLHours, "Keep ⇒ no expiry")
        s.npMixBufferTTLHours = -3
        XCTAssertEqual(s.npMixBufferEffectiveTTLHours, 48, "a corrupt value never means Keep or now")
        s.npMixBufferCapGB = 0
        XCTAssertEqual(s.npMixBufferCapBytes, 2_000_000_000)
        XCTAssertTrue(SettingsStore.npMixBufferTTLOptions.contains(SettingsStore.npMixBufferKeepSentinel),
                      "Q11: Keep is offered")
        XCTAssertTrue(SettingsStore.npMixBufferTTLOptions.contains(48))
    }

    func testBufferSettingsPersistAndOldBlobsDecode() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = SettingsStore(defaults: defaults)
        s.npMixBufferTTLHours = 12
        s.npMixBufferCapGB = 5
        s.lastTemporarySweepAt = 42
        s.persist()
        let again = SettingsStore(defaults: defaults)
        XCTAssertEqual(again.npMixBufferTTLHours, 12)
        XCTAssertEqual(again.npMixBufferCapGB, 5)
        XCTAssertEqual(again.lastTemporarySweepAt, 42)
        // A blob written before these keys existed still decodes (to the defaults).
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsData.default)) as? [String: Any])
        for k in ["npMixBufferTTLHours", "npMixBufferCapGB", "lastTemporarySweepAt"] { obj[k] = nil }
        XCTAssertNil(obj["npMixBufferTTLHours"])
        let old = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.npMixBufferTTLHours)
        XCTAssertNil(old.npMixBufferCapGB)
    }

    func testTTLLabels() {
        XCTAssertEqual(StorageView.ttlLabel(48), "48 h")
        XCTAssertEqual(StorageView.ttlLabel(72), "3 days")
        XCTAssertEqual(StorageView.ttlLabel(168), "7 days")
        XCTAssertEqual(StorageView.ttlLabel(0), "Keep (treat as downloads)")
        XCTAssertEqual(StorageView.expiryPhrase(now + 31 * hourMs, nowMs: now), "in 31 h")
        XCTAssertEqual(StorageView.expiryPhrase(now - 1, nowMs: now), "now")
    }
}
