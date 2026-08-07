import XCTest
@testable import PocketDJ

/// The Collectors Puzzle round engine over fixture stores: sampling → sequencer start,
/// assign/skip scoring, deadline end + scoreboard record, drift re-sync ("expired"),
/// top-up, and per-decision settings snapshots. Injected `now` clock, seeded rng,
/// countdown skipped — assertions run synchronously after each await (the
/// NowPlayingQueueTests discipline: the sequencer's playCurrent Tasks haven't run).
@MainActor
final class CollectorsPuzzleEngineTests: XCTestCase {

    private struct Stack {
        let app: AppModel
        let sequencer: SetlistPlayer
        let collections: CollectionsStore
        let scoreboard: GameScoreboardStore
        let decisions: PuzzleDecisionStore
        let engine: CollectorsPuzzleEngine
    }

    /// A generated catalog big enough that the initial sample leaves pool behind (top-up).
    private struct BigLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            var songs: [[String: Any]] = []
            for i in 0..<120 {
                songs.append(["id": "big_\(i)", "albumId": "alb_big", "artist": "Bulk",
                              "name": "Track \(i)", "length": 200_000])
            }
            let obj: [String: Any] = [
                "manifest": ["sourceName": "Big", "counts": ["albums": 1, "songs": songs.count]],
                "albums": [["id": "alb_big", "artist": "Bulk", "name": "Bulk Album",
                            "genre": "Electronic", "trackList": songs.map { $0["id"] as! String }]],
                "songs": songs,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj)
            return try JSONDecoder().decode(IndexJSON.self, from: data)
        }
    }

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-puz-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStack(loader: CatalogLoading = TestData.StubLoader(),
                           roundSeconds: Int = 120) async -> Stack {
        let app = AppModel(loader: loader)
        await app.loadIfNeeded()
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: tempURL("burns"))
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        let favorites = FavoritesStore(fileURL: tempURL("fav"))
        let playStats = PlayStatsStore(fileURL: tempURL("stats"))
        let scoreboard = GameScoreboardStore(fileURL: tempURL("scores"))
        let decisions = PuzzleDecisionStore(fileURL: tempURL("dec"))
        let engine = CollectorsPuzzleEngine(
            app: app, sequencer: sequencer, collections: collections,
            favorites: favorites, playStats: playStats,
            scoreboard: scoreboard, decisions: decisions,
            defaults: UserDefaults(suiteName: "test.puzzle.\(UUID().uuidString)")!)
        engine.countdownEnabled = false
        engine.rng = PRNG.seededRng("engine-test")
        var settings = PuzzleSettings()
        settings.roundSeconds = roundSeconds
        let pocket = collections.createPocket("Crate A", songIds: [], description: nil)
        settings.targetCollectionIds = [pocket.id]
        engine.updateSettings(settings)
        return Stack(app: app, sequencer: sequencer, collections: collections,
                     scoreboard: scoreboard, decisions: decisions, engine: engine)
    }

    func testStartRoundBuildsQueueAndStartsSequencer() async {
        let s = await makeStack()
        XCTAssertEqual(s.engine.phase, .idle)
        await s.engine.startRound()
        XCTAssertEqual(s.engine.phase, .running)
        XCTAssertEqual(s.engine.queue.count, 7, "the whole 7-song fixture pool samples in")
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertTrue(s.sequencer.isRunning, "audio rides the app-scoped sequencer")
        XCTAssertEqual(s.sequencer.queue.count, 7)
        XCTAssertEqual(s.sequencer.queue.map(\.id), s.engine.queue.map(\.id))
        XCTAssertGreaterThan(s.engine.remainingSeconds, 100)
    }

    func testStartRoundRequiresTargetsAndMatchingSongs() async {
        let s = await makeStack()
        var none = s.engine.settings
        none.targetCollectionIds = []
        s.engine.updateSettings(none)
        await s.engine.startRound()
        XCTAssertEqual(s.engine.phase, .idle)
        XCTAssertNotNil(s.engine.lastError)

        // A settings combination matching zero songs refuses to start with the message.
        var impossible = s.engine.settings
        impossible.targetCollectionIds = [s.collections.pockets[0].id]
        impossible.yearMin = 3000
        s.engine.updateSettings(impossible)
        await s.engine.startRound()
        XCTAssertEqual(s.engine.phase, .idle)
        XCTAssertEqual(s.engine.lastError, "No songs match these settings.")
    }

    func testAssignAddsToCollectionScoresAndAdvances() async {
        let s = await makeStack()
        await s.engine.startRound()
        let first = s.engine.current!
        let target = s.engine.settings.targetCollectionIds[0]
        s.engine.assign(toTargetIndex: 0)
        XCTAssertEqual(s.engine.score, 1)
        XCTAssertEqual(s.engine.queueIndex, 1, "assign advances the engine")
        XCTAssertEqual(s.sequencer.index, 1, "…and skips the sequencer with it")
        XCTAssertTrue(s.collections.pocket(target)!.songIds.contains(first.id),
                      "the song landed in the target through the normal addSong choke point")
        XCTAssertEqual(s.engine.assignedThisRound.count, 1)
        let row = s.decisions.decisions.last!
        XCTAssertEqual(row.action, "assigned")
        XCTAssertEqual(row.songId, first.id)
        XCTAssertEqual(row.collectionId, target)
        XCTAssertEqual(row.positionInRound, 0)
    }

    func testSkipRecordsNoPoint() async {
        let s = await makeStack()
        await s.engine.startRound()
        let first = s.engine.current!
        s.engine.skip()
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertEqual(s.engine.queueIndex, 1)
        let row = s.decisions.decisions.last!
        XCTAssertEqual(row.action, "skipped")
        XCTAssertEqual(row.songId, first.id)
    }

    func testDeadlineEndsRoundAndRecordsScoreboard() async {
        let s = await makeStack()
        var t: TimeInterval = 1_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        s.engine.assign(toTargetIndex: 0)
        XCTAssertEqual(s.engine.phase, .running)
        t += Double(s.engine.settings.roundSeconds) + 1   // the wall clock passes the deadline
        s.engine.tickOnce()
        XCTAssertEqual(s.engine.phase, .finished)
        XCTAssertFalse(s.sequencer.isRunning, "endRound stops the audio")
        XCTAssertEqual(s.scoreboard.recentRuns(.collectorsPuzzle, limit: 5).count, 1)
        XCTAssertEqual(s.scoreboard.bestScore(.collectorsPuzzle), 1)
        XCTAssertEqual(s.engine.lastRunRecord?.score, 1)
        XCTAssertEqual(s.engine.lastRunRecord?.detail?["assigned"], "1")
    }

    func testNewHighScoreFlag() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.assign(toTargetIndex: 0)
        s.engine.endRound()
        XCTAssertTrue(s.engine.isNewHighScore, "1 beats the empty board")
        s.engine.reset()
        XCTAssertEqual(s.engine.phase, .idle)
        await s.engine.startRound()
        s.engine.endRound()   // score 0 — recorded, but no new high
        XCTAssertFalse(s.engine.isNewHighScore)
        XCTAssertEqual(s.scoreboard.recentRuns(.collectorsPuzzle, limit: 5).count, 2,
                       "zero-score runs still land in recent runs")
    }

    func testExternalAdvanceRecordsExpired() async {
        let s = await makeStack()
        await s.engine.startRound()
        let first = s.engine.current!
        // A lock-screen ⏭ (or natural track end) advances the AUDIO without the engine.
        s.sequencer.skipNext()
        XCTAssertEqual(s.engine.queueIndex, 0, "engine hasn't noticed yet")
        s.engine.tickOnce()
        XCTAssertEqual(s.engine.queueIndex, 1, "drift re-sync adopts the audio position")
        XCTAssertEqual(s.engine.score, 0, "no double-scoring")
        let row = s.decisions.decisions.last!
        XCTAssertEqual(row.action, "expired")
        XCTAssertEqual(row.songId, first.id)
    }

    func testTopUpAppendsToQueue() async throws {
        let s = await makeStack(loader: BigLoader(), roundSeconds: 60)
        await s.engine.startRound()
        XCTAssertEqual(s.engine.queue.count, 60, "initial sample = max(60, roundSeconds)")
        // Burn through until under 10 remain → the next tick tops up.
        for _ in 0..<51 { s.engine.skip() }
        XCTAssertEqual(s.engine.queueIndex, 51)
        s.engine.tickOnce()
        try await Task.sleep(for: .milliseconds(300))   // detached top-up sample lands
        XCTAssertGreaterThan(s.engine.queue.count, 60, "top-up appended fresh songs")
        XCTAssertEqual(Set(s.engine.queue.map(\.id)).count, s.engine.queue.count,
                       "top-up excludes already-shown ids — no duplicates")
        XCTAssertFalse(s.engine.poolExhausted)
    }

    func testPoolExhaustionFlagsCatalogExhausted() async throws {
        let s = await makeStack()   // 7-song fixture: the first sample IS the whole pool
        await s.engine.startRound()
        s.engine.tickOnce()         // queue.count - queueIndex = 7 < 10 → top-up finds nothing
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(s.engine.poolExhausted)
        XCTAssertEqual(s.engine.queue.count, 7, "nothing appended")
        XCTAssertEqual(s.engine.phase, .running, "the round continues with remaining time")
    }

    func testDecisionsCarryRoundSettings() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.skip()
        XCTAssertEqual(s.decisions.decisions.last?.settings, s.engine.settings,
                       "every decision snapshots the round's weighting settings")
    }
}
