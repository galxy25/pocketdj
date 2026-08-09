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
        XCTAssertEqual(s.sequencer.sourceSetlistId, "puzzle_\(s.engine.roundId.uuidString)",
                       "the run is TAGGED so the engine can tell whether it still owns the sequencer")
        XCTAssertEqual(s.engine.queue.count, 7, "the whole 7-song fixture pool samples in")
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertTrue(s.sequencer.isRunning, "audio rides the app-scoped sequencer")
        XCTAssertEqual(s.sequencer.queue.count, 7)
        XCTAssertEqual(s.sequencer.queue.map(\.id), s.engine.queue.map(\.id))
        XCTAssertGreaterThan(s.engine.remainingSeconds, 100)
    }

    /// INVERTED 2026-08 (Levi): targets are no longer required. The ONE thing a round needs
    /// is a non-empty sample. (Previously this asserted `phase == .idle` + a "Pick 1–3 target
    /// collections." error — that refusal is the defect being fixed.) The second half is
    /// unchanged: a settings combination matching zero songs still refuses, with its message.
    func testStartRoundWithNoTargetsStillRuns() async {
        let s = await makeStack()
        var none = s.engine.settings
        none.targetCollectionIds = []
        s.engine.updateSettings(none)
        await s.engine.startRound()
        XCTAssertEqual(s.engine.phase, .running, "targets are optional — the round starts")
        XCTAssertGreaterThan(s.engine.queue.count, 0, "…with a real queue")
        XCTAssertNil(s.engine.lastError)
        XCTAssertNotNil(s.engine.current, "…and a card on screen to file")
        s.engine.endRound()
        s.engine.reset()

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

    /// Also the "silent round" contract: this stack never gets audio ownership, and the
    /// round must top up anyway — a round is playable (assign/skip) with no audio at all,
    /// so gating the queue growth on the sequencer would starve it mid-play.
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

    /// End→Start while a top-up sample is in flight: the stale continuation was armed for
    /// round A, so it must mutate NOTHING of round B — not the queue (A's filters/exclusions
    /// don't apply), not `poolExhausted`, and not the single-flight flag (B resets it itself).
    func testStaleTopUpFromAPreviousRoundNeverTouchesTheNextRound() async throws {
        let s = await makeStack(loader: BigLoader(), roundSeconds: 60)
        await s.engine.startRound()
        for _ in 0..<51 { s.engine.skip() }
        s.engine.tickOnce()                    // arms round A's top-up — sample now in flight
        s.engine.endRound()
        await s.engine.startRound()            // round B: fresh roundId, fresh 60-song queue
        let bRound = s.engine.roundId
        let bQueue = s.engine.queue.map(\.id)
        try await Task.sleep(for: .milliseconds(400))   // round A's stale sample lands
        XCTAssertEqual(s.engine.roundId, bRound)
        XCTAssertEqual(s.engine.queue.map(\.id), bQueue,
                       "round A's 40-song sample never lands in round B's queue")
        XCTAssertFalse(s.engine.poolExhausted)
        // Round B's own top-up still works — the stale round didn't latch the flag.
        for _ in 0..<51 { s.engine.skip() }
        s.engine.tickOnce()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(s.engine.queue.count, 60, "round B tops up normally")
    }

    /// Ownership lost DURING the top-up await: the extras must never be pushed into the
    /// FOREIGN audio queue (that would hijack someone else's playback). The round's own
    /// queue may still grow — it is the engine's data, nothing reads the audio index while
    /// unowned, and the next tick ends the taken-over round anyway.
    func testTopUpAfterTakeoverNeverAppendsToTheForeignAudioQueue() async throws {
        let s = await makeStack(loader: BigLoader(), roundSeconds: 60)
        await s.engine.startRound()
        for _ in 0..<51 { s.engine.skip() }
        s.engine.tickOnce()                    // top-up in flight for THIS round
        // A foreign play claims the sequencer while the sample is airborne.
        s.sequencer.play([SetlistPlayer.Item(id: "other_1", title: "Theirs", artist: "Someone")],
                         sourceSetlistId: "set_other")
        try await Task.sleep(for: .milliseconds(400))
        // The continuation DID run (the round's own queue grew — a silent or taken-over
        // round still tops up)…
        XCTAssertGreaterThan(s.engine.queue.count, 60)
        // …but nothing puzzle-shaped was pushed into the foreign playback. (The audio queue
        // itself is not asserted directly: this stack's items are unplayable, so the
        // sequencer tears any queue down on the next runloop turn — an `await` sees [].)
        XCTAssertTrue(Set(s.sequencer.queue.map(\.id)).isDisjoint(with: Set(s.engine.queue.map(\.id))),
                      "no puzzle song was smuggled into their playback")
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

    // MARK: - Sequencer ownership (the shared SetlistPlayer is app-scoped)

    /// A foreign `play()` mid-round: the user popped to Browse and started a playlist.
    /// The engine must NOT read that queue's index as its own (phantom "expired" rows in
    /// the decision log — a recommendation training signal), must not skip it, and must
    /// not stop it.
    func testForeignPlayMidRoundEndsTheRoundWithoutCorruptingTheDecisionLog() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.assign(toTargetIndex: 0)
        let rowsBefore = s.decisions.decisions.count
        XCTAssertEqual(s.engine.queueIndex, 1)

        let foreign = (0..<20).map {
            SetlistPlayer.Item(id: "other_\($0)", title: "Track \($0)", artist: "Someone")
        }
        s.sequencer.play(foreign, sourceSetlistId: "set_other")
        s.sequencer.skipNext(); s.sequencer.skipNext(); s.sequencer.skipNext()
        XCTAssertGreaterThan(s.sequencer.index, s.engine.queueIndex,
                             "the foreign queue's index climbed past the engine's position")

        s.engine.tickOnce()
        XCTAssertEqual(s.engine.phase, .finished, "ownership loss ends the round cleanly")
        XCTAssertEqual(s.decisions.decisions.count, rowsBefore,
                       "no 'expired' rows are invented off a queue the round doesn't own")
        XCTAssertTrue(s.sequencer.isRunning, "the user's playlist keeps playing")
        XCTAssertEqual(s.sequencer.sourceSetlistId, "set_other")
        XCTAssertEqual(s.sequencer.index, 3, "…and the puzzle never skipped or stopped it")
        XCTAssertEqual(s.sequencer.queue.count, 20, "…nor topped it up")
        XCTAssertEqual(s.scoreboard.recentRuns(.collectorsPuzzle, limit: 5).count, 1,
                       "the interrupted run still records its real score")
        XCTAssertEqual(s.engine.lastRunRecord?.score, 1)
    }

    func testAssignAndSkipAfterTakeoverNeverTouchTheForeignRun() async {
        let s = await makeStack()
        await s.engine.startRound()
        let foreign = [SetlistPlayer.Item(id: "other_1", title: "Theirs", artist: "Someone"),
                       SetlistPlayer.Item(id: "other_2", title: "Theirs 2", artist: "Someone")]
        s.sequencer.play(foreign, sourceSetlistId: "set_other")

        s.engine.assign(toTargetIndex: 0)
        XCTAssertEqual(s.engine.phase, .finished, "an assign against a lost sequencer ends the round")
        XCTAssertEqual(s.engine.score, 0, "no point for a card the round no longer owns")
        XCTAssertEqual(s.sequencer.index, 0, "the foreign track was NOT skipped")
        XCTAssertTrue(s.sequencer.isRunning)
        s.engine.skip()   // and a late skip is inert
        XCTAssertEqual(s.sequencer.index, 0)
        XCTAssertEqual(s.sequencer.sourceSetlistId, "set_other")
    }

    func testEndRoundStopsOnlyItsOwnRun() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.sequencer.play([SetlistPlayer.Item(id: "other_1", title: "Theirs", artist: "Someone")],
                         sourceSetlistId: "set_other")
        s.engine.endRound()   // the End button, after someone else took the sequencer
        XCTAssertEqual(s.engine.phase, .finished)
        XCTAssertTrue(s.sequencer.isRunning, "End must never stop unrelated playback")
        XCTAssertEqual(s.sequencer.sourceSetlistId, "set_other")
    }

    // MARK: - Filing through the Add-to picker ("file into ANY collection")

    /// The whole point of change 3: with NO targets a round is still fully scorable, because
    /// the card is filed through the Add-to sheet into any collection at all.
    func testSheetFilingScoresAdvancesAndLogs() async {
        let s = await makeStack()
        var none = s.engine.settings
        none.targetCollectionIds = []          // the no-targets mode
        s.engine.updateSettings(none)
        await s.engine.startRound()
        let first = s.engine.current!
        // A collection that is NOT a round target — "any collection" is the requirement.
        let elsewhere = s.collections.createPocket("Somewhere Else", songIds: [], description: nil)

        XCTAssertTrue(s.engine.beginFiling(), "the sheet opens for the current card")
        XCTAssertEqual(s.engine.filingSongId, first.id)
        s.engine.endFiling(assignedTo: AddTarget(kind: .pocket, id: elsewhere.id))

        XCTAssertEqual(s.engine.score, 1, "a sheet filing is worth the same point as a target tap")
        XCTAssertEqual(s.engine.queueIndex, 1, "…and advances the round")
        XCTAssertNil(s.engine.filingSongId)
        XCTAssertEqual(s.engine.assignedThisRound.last?.collectionId, elsewhere.id)
        let row = s.decisions.decisions.last!
        XCTAssertEqual(row.action, "assigned", "the rec-engine signal is identical to a target filing")
        XCTAssertEqual(row.songId, first.id)
        XCTAssertEqual(row.collectionId, elsewhere.id)
        XCTAssertEqual(row.positionInRound, 0)
        // …and it exports over the SAME wire with no bridge change.
        let events = PuzzleRecEventBridge.events(from: s.decisions.decisions, sinceMs: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "added")
        XCTAssertEqual(events.first?.collectionId, elsewhere.id)
    }

    /// ONE POINT PER CARD, not per collection. The picker is multi-select by design, so if the
    /// point were credited per ADD a single card would be worth five points and every historical
    /// score would become meaningless. The card advances on the FIRST successful add, which is
    /// what makes the farm structurally impossible.
    func testASecondFilingOfTheSameCardCannotScoreTwice() async {
        let s = await makeStack()
        await s.engine.startRound()
        let first = s.engine.current!
        let a = s.collections.createPocket("Crate B", songIds: [], description: nil)
        let b = s.collections.createPocket("Crate C", songIds: [], description: nil)
        s.engine.beginFiling()
        s.engine.endFiling(assignedTo: AddTarget(kind: .pocket, id: a.id))
        XCTAssertEqual(s.engine.score, 1)
        // The sheet's second tap arrives after the callback already dismissed + advanced.
        s.engine.endFiling(assignedTo: AddTarget(kind: .pocket, id: b.id))
        XCTAssertEqual(s.engine.score, 1, "a second add in the same opening scores nothing")
        XCTAssertEqual(s.engine.queueIndex, 1, "…and does not double-advance")
        XCTAssertNotEqual(s.engine.current?.id, first.id)
        XCTAssertEqual(s.decisions.decisions.filter { $0.action == "assigned" }.count, 1)
    }

    /// Cancel is NOT a skip: no point, no decision row, and — critically — the card STAYS.
    /// A player may cancel to hit a target button instead; burning their card would be the
    /// worst possible surprise in a timed game.
    func testCancelledFilingScoresNothingAndKeepsTheCard() async {
        let s = await makeStack()
        await s.engine.startRound()
        let first = s.engine.current!
        let rows = s.decisions.decisions.count
        s.engine.beginFiling()
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertEqual(s.engine.queueIndex, 0)
        XCTAssertEqual(s.engine.current?.id, first.id, "the card is still on screen")
        XCTAssertEqual(s.decisions.decisions.count, rows, "cancel is not a 'skipped' signal either")
        // …and the card is still filable afterwards.
        XCTAssertTrue(s.engine.beginFiling())
    }

    /// THE TIMER DECISION, asserted: the round clock is HELD while the sheet is open and the
    /// held time is credited back on dismiss — capped, so an open picker can't turn a timed
    /// rush into an untimed one.
    func testFilingHoldsTheClockUpToTheCap() async {
        let s = await makeStack(roundSeconds: 120)
        var t: TimeInterval = 1_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        let before = s.engine.remainingSeconds

        s.engine.beginFiling()
        t += 8                                   // 8 s reading the picker
        XCTAssertEqual(s.engine.remainingSeconds, before,
                       "the displayed clock FREEZES behind the sheet")
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.remainingSeconds, before, "…and the 8 s are credited back")

        // Past the cap: leave the picker open for five minutes and only
        // `maxFilingCreditSeconds` are bought back — you burned the round, you keep the point.
        let deadlineBefore = s.engine.deadlineEpoch
        s.engine.beginFiling()
        t += 300
        XCTAssertEqual(s.engine.remainingSeconds, before,
                       "still frozen — an open sheet is not an untimed game, it is a HELD one")
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.deadlineEpoch - deadlineBefore,
                       CollectorsPuzzleEngine.maxFilingCreditSeconds, accuracy: 0.001,
                       "a 5-minute sheet buys back exactly the 20 s cap, no more")
        XCTAssertEqual(s.engine.remainingSeconds, 0)
        s.engine.tickOnce()
        XCTAssertEqual(s.engine.phase, .finished, "the very next tick ends the spent round")
    }

    /// THE DANGEROUS RACE (there is no pause API on SetlistPlayer, so audio runs on behind the
    /// sheet): if the ticker's drift re-sync were live during a filing, a song ending naturally
    /// under the open picker would write "expired" rows and advance PAST the card being filed —
    /// the point would then score against the wrong song and the round would double-advance.
    func testFilingSuspendsDriftExpiryAndReArmsOnClose() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        s.engine.beginFiling()
        // Audio runs on past the card while the picker is open (3 tracks' worth).
        s.sequencer.skipNext(); s.sequencer.skipNext(); s.sequencer.skipNext()
        for _ in 0..<4 { s.engine.tickOnce() }
        XCTAssertEqual(s.engine.queueIndex, 0, "the ticker is HELD — the card did not move")
        XCTAssertEqual(s.engine.current?.id, card.id)
        XCTAssertTrue(s.decisions.decisions.allSatisfy { $0.action != "expired" },
                      "no phantom 'expired' rows for a card the player is still filing")

        // Closing re-marries the audio to the card the round is showing.
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.current?.id, card.id)
        XCTAssertEqual(s.sequencer.sourceSetlistId, "puzzle_\(s.engine.roundId.uuidString)",
                       "audio was re-armed under THIS round's tag")
        XCTAssertEqual(s.sequencer.queue.first?.id, card.id, "…starting at the card on screen")
    }

    /// A stale sheet — the round ended under it — must file NOTHING rather than score against
    /// a finished round.
    func testStaleFilingAfterTheRoundEndedFilesNothing() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.beginFiling()
        s.engine.endRound()
        let rows = s.decisions.decisions.count
        let recorded = s.engine.lastRunRecord?.score
        s.engine.endFiling(assignedTo: AddTarget(kind: .pocket,
                                                 id: s.collections.pockets[0].id))
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertEqual(s.decisions.decisions.count, rows)
        XCTAssertEqual(s.engine.lastRunRecord?.score, recorded, "the recorded run is untouched")
    }

    /// `endFiling` is reachable from BOTH the sheet's completion callback and the binding's
    /// `onChange` (the callback nils the binding, which fires onChange), so it must credit the
    /// clock once and score once.
    func testEndFilingIsIdempotent() async {
        let s = await makeStack()
        var t: TimeInterval = 2_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        let target = AddTarget(kind: .pocket, id: s.collections.pockets[0].id)
        let deadlineBefore = s.engine.deadlineEpoch
        s.engine.beginFiling()
        t += 5
        s.engine.endFiling(assignedTo: target)   // the callback
        s.engine.endFiling(assignedTo: nil)      // …then onChange, for the same opening
        XCTAssertEqual(s.engine.score, 1)
        XCTAssertEqual(s.engine.queueIndex, 1)
        XCTAssertEqual(s.engine.deadlineEpoch - deadlineBefore, 5, accuracy: 0.001,
                       "the held time is credited exactly once")
    }

    /// A filing cannot begin against a sequencer someone else owns (same contract as
    /// `assign`/`skip`): the round ends instead of scoring into a foreign queue.
    func testBeginFilingAfterTakeoverEndsTheRoundAndOpensNothing() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.sequencer.play([SetlistPlayer.Item(id: "other_1", title: "Theirs", artist: "Someone")],
                         sourceSetlistId: "set_other")
        XCTAssertFalse(s.engine.beginFiling(), "no sheet opens")
        XCTAssertNil(s.engine.filingSongId)
        XCTAssertEqual(s.engine.phase, .finished)
        XCTAssertTrue(s.sequencer.isRunning, "their playback is untouched")
        XCTAssertEqual(s.sequencer.sourceSetlistId, "set_other")
    }

    // MARK: - Multi-collection filing (one card → several crates, still ONE point)

    /// THE REQUEST (Levi 2026-08-08): "gem collector should let me add the song to multiple
    /// collections". The picker no longer self-dismisses on the first add, so the opening stays
    /// live and the FILING SETTLES ON DISMISS — which is what keeps "one point per card"
    /// structural rather than clamped: nothing scores or advances while the sheet is up.
    /// Filing into N crates buys back more clock than filing into one — otherwise USING the
    /// multi-collection feature is score-negative: the same single point, but every second past
    /// the flat 20 s cap was round time the player never got back. The allowance scales with
    /// what was actually filed and is still hard-bounded, so it can never become a pause button.
    func testFilingCreditScalesWithHowManyCollectionsWereFiled() async {
        let s = await makeStack()
        var t: TimeInterval = 1_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        let card = s.engine.current!
        let a = s.collections.pockets[0]
        let b = s.collections.createPocket("Crate B", songIds: [], description: nil)
        let c = s.collections.createPocket("Crate C", songIds: [], description: nil)

        let deadlineBefore = s.engine.deadlineEpoch
        XCTAssertTrue(s.engine.beginFiling())
        for p in [a, b, c] {
            let target = AddTarget(kind: .pocket, id: p.id)
            s.collections.addSong(card.id, to: target)
            s.engine.noteFiled(to: target)
        }
        t += 300                                    // far past any cap
        s.engine.endFiling(assignedTo: nil)
        // 20 s base + 10 s for each crate BEYOND the first = 40 s for three.
        XCTAssertEqual(s.engine.deadlineEpoch - deadlineBefore,
                       CollectorsPuzzleEngine.maxFilingCreditSeconds
                         + CollectorsPuzzleEngine.filingCreditPerExtraTarget * 2,
                       accuracy: 0.001,
                       "three crates buy back the base plus two increments, not the flat base")
        XCTAssertEqual(s.engine.score, 1, "the extra allowance buys TIME, never extra points")
    }

    /// The scaled allowance is bounded: filing into a great many crates cannot stop the clock.
    func testFilingCreditIsCeilinged() async {
        let s = await makeStack()
        var t: TimeInterval = 1_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        let card = s.engine.current!
        let deadlineBefore = s.engine.deadlineEpoch
        XCTAssertTrue(s.engine.beginFiling())
        for i in 0..<20 {
            let p = s.collections.createPocket("Crate \(i)", songIds: [], description: nil)
            let target = AddTarget(kind: .pocket, id: p.id)
            s.collections.addSong(card.id, to: target)
            s.engine.noteFiled(to: target)
        }
        t += 600
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.deadlineEpoch - deadlineBefore,
                       CollectorsPuzzleEngine.maxFilingCreditCeilingSeconds, accuracy: 0.001,
                       "20 crates hit the ceiling, not 20 x the per-target increment")
    }

    func testMultiCollectionFilingScoresExactlyOnePointAndAdvancesOnce() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let a = s.collections.pockets[0]                                    // "Crate A"
        let b = s.collections.createPocket("Crate B", songIds: [], description: nil)
        let c = s.collections.createPocket("Crate C", songIds: [], description: nil)

        XCTAssertTrue(s.engine.beginFiling())
        for p in [a, b, c] {
            let target = AddTarget(kind: .pocket, id: p.id)
            s.collections.addSong(card.id, to: target)   // the picker's own write
            s.engine.noteFiled(to: target)               // …and what it tells the engine
        }
        // WHILE THE SHEET IS OPEN: nothing has scored and the card has not moved.
        XCTAssertEqual(s.engine.score, 0, "a filing scores on DISMISS, not on each add")
        XCTAssertEqual(s.engine.queueIndex, 0)
        XCTAssertEqual(s.engine.current?.id, card.id, "the card the player is still filing")
        XCTAssertEqual(s.engine.filedTargetsThisOpening.count, 3)

        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.score, 1, "three collections, ONE point")
        XCTAssertEqual(s.engine.queueIndex, 1, "…and exactly one advance")
        for p in [a, b, c] {
            XCTAssertTrue(s.collections.pocket(p.id)!.songIds.contains(card.id),
                          "the song really is in \(p.name)")
        }
        // The POINT is capped; the TRAINING SIGNAL is not — the rec engine wants all three.
        XCTAssertEqual(s.decisions.decisions.filter { $0.action == "assigned" && $0.songId == card.id }.count, 3)
        XCTAssertEqual(s.engine.assignedThisRound.count, 1, "one summary row for the card")
        XCTAssertEqual(s.engine.assignedThisRound.last?.collectionName, "Crate A +2 more")
        XCTAssertEqual(s.engine.assignedThisRound.last?.collectionId, a.id, "…named by the first target")
    }

    /// The same flow against PLAYLIST targets — the shape the real picker actually produces
    /// (its rows carry a `sequenceId` for the default chapter), and the one `stillContains`
    /// answers through the node-tree walk rather than a flat `songIds` array.
    func testMultiCollectionFilingWorksForPlaylistTargets() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let one = s.collections.createPlaylist("Crate 2")
        let two = s.collections.createPlaylist("Crate 3")

        XCTAssertTrue(s.engine.beginFiling())
        for pl in [one, two] {
            let target = AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences.first?.nodeId)
            s.collections.addSong(card.id, to: target)
            s.engine.noteFiled(to: target)
        }
        s.engine.endFiling(assignedTo: nil)

        XCTAssertEqual(s.engine.score, 1, "two playlists, one point")
        XCTAssertEqual(s.engine.queueIndex, 1)
        XCTAssertTrue(s.collections.playlist(one.id, contains: card.id))
        XCTAssertTrue(s.collections.playlist(two.id, contains: card.id))
        XCTAssertEqual(s.decisions.decisions.filter { $0.action == "assigned" }.count, 2)
    }

    /// The clock stays HELD across every add in one opening and is credited exactly once on
    /// dismiss — multi-add must not turn one hold into three.
    func testFilingClockStaysHeldAcrossSeveralAddsAndIsCreditedOnce() async {
        let s = await makeStack(roundSeconds: 120)
        var t: TimeInterval = 3_000_000
        s.engine.now = { Date(timeIntervalSince1970: t) }
        await s.engine.startRound()
        let card = s.engine.current!
        let before = s.engine.remainingSeconds
        let deadlineBefore = s.engine.deadlineEpoch

        s.engine.beginFiling()
        for name in ["Crate B", "Crate C", "Crate D"] {
            t += 3                                    // 3 s per collection, 9 s total
            let p = s.collections.createPocket(name, songIds: [], description: nil)
            let target = AddTarget(kind: .pocket, id: p.id)
            s.collections.addSong(card.id, to: target)
            s.engine.noteFiled(to: target)
            XCTAssertEqual(s.engine.remainingSeconds, before,
                           "the clock stays frozen behind the sheet, add after add")
        }
        s.engine.endFiling(assignedTo: nil)
        XCTAssertEqual(s.engine.deadlineEpoch - deadlineBefore, 9, accuracy: 0.001,
                       "one opening, one credit — under the 20 s cap")
        XCTAssertEqual(s.engine.score, 1)
    }

    /// A callback that arrives with no sheet open — before the first `beginFiling`, or after
    /// the opening already settled — records nothing and cannot score.
    func testNoteFiledOutsideAnOpeningIsIgnored() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let target = AddTarget(kind: .pocket, id: s.collections.pockets[0].id)
        s.collections.addSong(card.id, to: target)

        s.engine.noteFiled(to: target)                 // BEFORE any opening
        XCTAssertTrue(s.engine.filedTargetsThisOpening.isEmpty)
        XCTAssertEqual(s.engine.score, 0)

        s.engine.beginFiling()
        s.engine.endFiling(assignedTo: nil)            // an opening that noted nothing = cancel
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertEqual(s.engine.queueIndex, 0, "cancel is not a skip — the card stays")

        s.engine.noteFiled(to: target)                 // AFTER it settled
        XCTAssertTrue(s.engine.filedTargetsThisOpening.isEmpty)
        XCTAssertEqual(s.engine.score, 0)
        XCTAssertTrue(s.decisions.decisions.filter { $0.action == "assigned" }.isEmpty)
    }

    /// The picker's rows are TOGGLES. Adding a collection and then unchecking it filed nothing
    /// there; unchecking them all is a Cancel — no point, and the card must stay, because a
    /// player who changed their mind has not spent their card.
    func testAddingThenRemovingEveryCollectionIsACancel() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let a = s.collections.pockets[0].id
        let target = AddTarget(kind: .pocket, id: a)

        s.engine.beginFiling()
        s.collections.addSong(card.id, to: target)
        s.engine.noteFiled(to: target)
        s.collections.removeSong(card.id, fromPocket: a)     // the row toggled back off
        s.engine.endFiling(assignedTo: nil)

        XCTAssertEqual(s.engine.score, 0)
        XCTAssertEqual(s.engine.queueIndex, 0)
        XCTAssertEqual(s.engine.current?.id, card.id, "the card is still on screen")
        XCTAssertTrue(s.decisions.decisions.filter { $0.action == "assigned" }.isEmpty)
    }

    /// Deduped by (kind,id): a double-tap that re-checks the same collection is one filing.
    func testDuplicateNoteFiledForTheSameCollectionIsDeduped() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let target = AddTarget(kind: .pocket, id: s.collections.pockets[0].id)

        s.engine.beginFiling()
        s.collections.addSong(card.id, to: target)
        s.engine.noteFiled(to: target)
        s.engine.noteFiled(to: target)
        // Dedup is by (kind,id) IGNORING sequenceId — a playlist filed into two chapters is
        // still one collection, and still one point.
        s.engine.noteFiled(to: AddTarget(kind: .pocket, id: target.id, sequenceId: "seq_2"))
        XCTAssertEqual(s.engine.filedTargetsThisOpening.count, 1)
        s.engine.endFiling(assignedTo: nil)

        XCTAssertEqual(s.engine.score, 1)
        XCTAssertEqual(s.decisions.decisions.filter { $0.action == "assigned" }.count, 1)
        XCTAssertEqual(s.engine.assignedThisRound.last?.collectionName, "Crate A",
                       "one collection ⇒ no '+N more' suffix")
    }

    /// The LEGACY single-shot path still scores exactly once, and an explicit target wins over
    /// whatever the opening noted (that is the contract `assign`/tests rely on).
    func testExplicitTargetEndFilingStillScoresOnce() async {
        let s = await makeStack()
        await s.engine.startRound()
        let card = s.engine.current!
        let a = s.collections.pockets[0].id
        let b = s.collections.createPocket("Crate B", songIds: [], description: nil).id

        s.engine.beginFiling()
        s.collections.addSong(card.id, to: AddTarget(kind: .pocket, id: b))
        s.engine.noteFiled(to: AddTarget(kind: .pocket, id: b))
        s.engine.endFiling(assignedTo: AddTarget(kind: .pocket, id: a))

        XCTAssertEqual(s.engine.score, 1)
        XCTAssertEqual(s.engine.queueIndex, 1)
        let assigned = s.decisions.decisions.filter { $0.action == "assigned" }
        XCTAssertEqual(assigned.count, 1, "the explicit target is the whole filing")
        XCTAssertEqual(assigned.last?.collectionId, a)
    }

    /// Both scoring constants are PINNED so a future change is a deliberate act, not a side
    /// effect. `pointsPerFiledCard` is the one-line flip if per-collection scoring is ever
    /// wanted; `maxFilingCreditSeconds` is the anti-abuse bound that makes a long sheet
    /// self-punishing, which is why multi-add needs no separate stall guard.
    func testScoringAndFilingCreditConstantsArePinned() {
        XCTAssertEqual(CollectorsPuzzleEngine.pointsPerFiledCard, 1,
                       "ONE point per card, however many collections it lands in")
        XCTAssertEqual(CollectorsPuzzleEngine.maxFilingCreditSeconds, 20, accuracy: 0.001,
                       "multi-add did NOT relax the filing credit cap")
    }

    func testFiledLabelSummarizesTheCollections() {
        XCTAssertEqual(CollectorsPuzzleEngine.filedLabel([]), "Collection")
        XCTAssertEqual(CollectorsPuzzleEngine.filedLabel(["Crate A"]), "Crate A")
        XCTAssertEqual(CollectorsPuzzleEngine.filedLabel(["Crate A", "Crate B"]), "Crate A +1 more")
        XCTAssertEqual(CollectorsPuzzleEngine.filedLabel(["Crate A", "Crate B", "Crate C"]),
                       "Crate A +2 more")
    }

    func testDecisionsCarryRoundSettings() async {
        let s = await makeStack()
        await s.engine.startRound()
        s.engine.skip()
        XCTAssertEqual(s.decisions.decisions.last?.settings, s.engine.settings,
                       "every decision snapshots the round's weighting settings")
    }
}
