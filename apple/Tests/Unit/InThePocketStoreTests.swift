import XCTest
@testable import PocketDJ

/// In the Pocket — the app-scoped store end to end with no app graph: build (off-main scorer over
/// a tiny catalog + history) → start (the shared-sequencer seam gets the round under its run tag)
/// → the REAL history log's verdicts → finalize (scoreboard run, upload row, change hook), plus
/// feedback capping, relaunch persistence and "End round".
@MainActor
final class InThePocketStoreTests: XCTestCase {

    /// A finished round for the pure tests (scorer exclusions, learning).
    nonisolated static func round(songs: [String], outcome: InThePocketOutcome?,
                                  targets: [InThePocketTarget] = [.init(dim: "genre", value: "funk", label: "Funk", weight: 1)])
        -> InThePocketRound {
        InThePocketRound(
            id: UUID(), createdAtMs: 1_700_000_000_000, startedAtMs: 1_700_000_000_000,
            endedAtMs: outcome == nil ? nil : 1_700_000_900_000, updatedAtMs: 1_700_000_900_000,
            tzOffsetMin: -420,
            context: InThePocketContext(timeBucket: "evening", dayType: "weekday", dow: 2, ctx: nil),
            contextLabel: nil, mode: .cloud, seed: "1", algoVersion: 1, targets: targets,
            songs: songs.map { InThePocketSong(id: $0, title: $0, artist: "A-\($0)", lengthMs: nil, score: 1, why: []) },
            outcome: outcome, rating: nil, feedback: nil, appVersion: "test")
    }

    private struct Env {
        let store: InThePocketStore
        let history: PlayHistoryStore
        let scores: GameScoreboardStore
        let fileURL: URL
        let clock: Clock
    }

    final class Clock { var ms: Double = 1_791_945_000_000 }

    private var played: [(items: [SetlistPlayer.Item], tag: String)] = []
    private var owned: String?
    private var changes = 0

    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-itp-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEnv(fileURL: URL? = nil, history: PlayHistoryStore? = nil) -> Env {
        let clock = Clock()
        let history = history ?? PlayHistoryStore(fileURL: temp("history"))
        let scores = GameScoreboardStore(fileURL: temp("scores"))
        let url = fileURL ?? temp("rounds")
        let store = InThePocketStore(history: history, scoreboard: scores, fileURL: url)
        store.tickerEnabled = false
        store.now = { Date(timeIntervalSince1970: clock.ms / 1000) }
        let songs = (1...6).map { IndexSong.minimal(id: "sng_00000000000\($0)", name: "Song \($0)", artist: "Ada",
                                                    appleMusicId: "10\($0)") }
        store.catalogSnapshot = { (Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }), [:]) }
        store.audioAvailability = { .init(canStreamAppleMusic: true) }
        store.play = { [weak self] items, tag in self?.played.append((items, tag)); self?.owned = tag }
        store.ownsRun = { [weak self] tag in self?.owned == tag }
        store.onRoundsChanged = { [weak self] in self?.changes += 1 }
        store.appVersion = "9.9"
        return Env(store: store, history: history, scores: scores, fileURL: url, clock: clock)
    }

    /// Two plays of Ada four days ago — enough history for an artist profile, outside the
    /// 48-hour exclusion.
    private func seedHistory(_ env: Env) {
        for (i, id) in ["sng_000000000001", "sng_000000000002"].enumerated() {
            let ev = env.history.record(songId: id, artist: "Ada", context: .browser,
                                        at: env.clock.ms - 4 * 86_400_000 + Double(i) * 300_000)
            env.history.noteListened(eventId: ev!.id, fraction: 1)
        }
    }

    private func builtRound(_ env: Env, seed: UInt64 = 3) async -> InThePocketRound {
        seedHistory(env)
        await env.store.buildRound(seed: seed)
        guard let r = env.store.current else { XCTFail("no round: \(env.store.buildState)"); fatalError() }
        return r
    }

    /// Record the round's song `i` starting `minutes` after ▶ (the SetlistPlayer → history path).
    @discardableResult
    private func playSong(_ env: Env, _ round: InThePocketRound, _ i: Int, at minutes: Double) -> PlayHistoryStore.PlayEvent {
        env.history.record(songId: round.songs[i].id, title: round.songs[i].title, artist: round.songs[i].artist,
                           context: .init(source: .game, contextId: nil, contextName: "In the Pocket"),
                           at: round.startedAtMs! + minutes * 60_000)!
    }

    // MARK: - Tests

    func testBuildStartTrackFinalize() async throws {
        let env = makeEnv()
        let built = await builtRound(env)
        XCTAssertEqual(built.songs.count, 3, "no cloud results ⇒ a three-song history round")
        XCTAssertTrue([.history, .cold].contains(built.mode))
        XCTAssertEqual(built.seed, "3")
        XCTAssertEqual(built.appVersion, "9.9")
        XCTAssertNil(built.startedAtMs)

        env.store.start()
        XCTAssertEqual(played.count, 1)
        XCTAssertEqual(played[0].tag, InThePocketStore.runTag(built.id))
        XCTAssertEqual(played[0].items.map(\.id), built.songs.map(\.id))
        let round = try XCTUnwrap(env.store.current)
        XCTAssertNotNil(env.store.activeRound)

        let e0 = playSong(env, round, 0, at: 0.1)
        env.clock.ms = round.startedAtMs! + 1 * 60_000
        env.store.evaluate()
        XCTAssertEqual(env.store.currentSongIndex, 0)
        XCTAssertEqual(env.store.current?.songs.map(\.state), [.playing, .pending, .pending])

        env.history.noteListened(eventId: e0.id, fraction: 1)
        playSong(env, round, 1, at: 4)
        let e2 = playSong(env, round, 2, at: 8)
        env.clock.ms = round.startedAtMs! + 9 * 60_000
        env.store.evaluate()
        XCTAssertNil(env.store.current?.outcome)
        XCTAssertTrue(env.store.uploadWires(installId: "I").isEmpty, "an unfinished round never uploads")

        env.history.noteListened(eventId: e2.id, fraction: 0.96)
        env.store.evaluate()
        let done = try XCTUnwrap(env.store.current)
        XCTAssertEqual(done.outcome, .pocket)
        XCTAssertEqual(done.songs.map(\.state), [.completed, .completed, .completed])
        XCTAssertNil(env.store.activeRound)
        XCTAssertEqual(changes, 1, "a finished round asks for an upload")
        let run = try XCTUnwrap(env.scores.recentRuns(.inThePocket, limit: 1).first)
        XCTAssertEqual(run.score, 3)
        XCTAssertEqual(run.detail?["outcome"], "pocket")
        XCTAssertEqual(env.scores.inThePocketStats().pockets, 1)
        let wires = env.store.uploadWires(installId: "INSTALL")
        XCTAssertEqual(wires.count, 1)
        XCTAssertEqual(wires[0].outcome, "pocket")
        XCTAssertEqual(wires[0].songs.map(\.outcome), ["completed", "completed", "completed"])
        XCTAssertEqual(wires[0].startedAtMs % 60_000, 0, "coarse time on the wire")
        // Evaluating again changes nothing (no second scoreboard row).
        env.store.evaluate()
        XCTAssertEqual(env.scores.recentRuns(.inThePocket, limit: 5).count, 1)
    }

    func testASkipBreaksTheRoundAndRecordsIt() async throws {
        let env = makeEnv()
        _ = await builtRound(env)
        env.store.start()
        let round = try XCTUnwrap(env.store.current)
        let e0 = playSong(env, round, 0, at: 0.1)
        env.history.markSkipped(eventId: e0.id)
        playSong(env, round, 1, at: 1)
        env.clock.ms = round.startedAtMs! + 1.1 * 60_000
        env.store.evaluate()
        XCTAssertEqual(env.store.current?.outcome, .broke(at: 1))
        XCTAssertEqual(env.scores.recentRuns(.inThePocket, limit: 1).first?.detail?["outcome"], "broke")
        XCTAssertEqual(env.store.uploadWires(installId: "I").first?.brokeAt, 1)
    }

    func testEndRoundAndTakeoverAbandon() async throws {
        let env = makeEnv()
        _ = await builtRound(env)
        env.store.start()
        let round = try XCTUnwrap(env.store.current)
        let e0 = playSong(env, round, 0, at: 0.1)
        env.history.noteListened(eventId: e0.id, fraction: 0.2)
        env.clock.ms = round.startedAtMs! + 60_000
        env.store.endActiveRound()
        XCTAssertEqual(env.store.current?.outcome, .abandoned)
        XCTAssertEqual(env.store.current?.songs.map(\.state), [.playing, .notPlayed, .notPlayed])
        XCTAssertEqual(env.store.uploadWires(installId: "I").first?.songs.first?.outcome, "partial")

        // A second round taken over by another surface (the sequencer runs something else).
        env.store.dismissCurrent()
        await env.store.buildRound(seed: 11)
        env.store.start()
        let r2 = try XCTUnwrap(env.store.current)
        owned = "someone-else"
        env.clock.ms = r2.startedAtMs! + 1_000
        env.store.evaluate()                     // first sight of the loss: settling
        XCTAssertNil(env.store.current?.outcome)
        env.clock.ms += InThePocketRoundEvaluator.settleMs
        env.store.evaluate()
        XCTAssertEqual(env.store.current?.outcome, .abandoned)
    }

    func testFeedbackIsCappedSavedAndAFinishedRoundsEditAsksForUpload() async throws {
        let env = makeEnv()
        _ = await builtRound(env)
        env.store.start()
        let id = try XCTUnwrap(env.store.currentRoundId)
        env.store.saveFeedback(roundId: id, text: "  " + String(repeating: "é", count: 2500) + "  ", rating: 9)
        let r = try XCTUnwrap(env.store.current)
        XCTAssertEqual(r.feedback?.utf16.count, InThePocketRound.maxFeedbackChars)
        XCTAssertNil(r.rating, "out-of-range rating is dropped")
        XCTAssertEqual(changes, 0, "during the round nothing uploads yet")
        env.store.endActiveRound()
        XCTAssertEqual(changes, 1)
        let before = try XCTUnwrap(env.store.current).updatedAtMs
        env.store.saveFeedback(roundId: id, text: "funkier please", rating: 4)
        XCTAssertEqual(changes, 2, "a finished round's edit re-uploads")
        XCTAssertGreaterThan(try XCTUnwrap(env.store.current).updatedAtMs, before)
        env.store.saveFeedback(roundId: id, text: "funkier please  ", rating: 4)
        XCTAssertEqual(changes, 2, "no change, no upload")
        XCTAssertEqual(env.store.uploadWires(installId: "I").first?.feedback, "funkier please")
        XCTAssertEqual(env.store.uploadWires(installId: "I").first?.rating, 4)
    }

    func testRoundsPersistAcrossRelaunchAndTrackingResumes() async throws {
        let env = makeEnv()
        _ = await builtRound(env)
        env.store.start()
        let id = try XCTUnwrap(env.store.currentRoundId)
        let relaunched = makeEnv(fileURL: env.fileURL, history: env.history)
        XCTAssertEqual(relaunched.store.currentRoundId, id)
        XCTAssertNotNil(relaunched.store.activeRound, "a playing round is still active after a relaunch")
        relaunched.store.clearLocal()
        XCTAssertTrue(relaunched.store.rounds.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.fileURL.path))
    }

    func testBuildFailsGracefullyWithNothingPlayable() async {
        let env = makeEnv()
        env.store.audioAvailability = { .init() }
        await env.store.buildRound(seed: 1)
        XCTAssertNil(env.store.current)
        guard case .failed = env.store.buildState else { return XCTFail("expected a failure message") }
    }
}
