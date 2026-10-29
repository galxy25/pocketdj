import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 5a — the app-scoped run store: start under `pwr_<id>`, verdict counting
/// from the history log, the live artist ban, restore mid-run, and the 100-played-through stop.
@MainActor
final class PocketRunStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("PDJ_HOLD_PLAYBACK", "1", 1)   // keep the set "running" without resolving audio
    }
    override func tearDown() {
        unsetenv("PDJ_HOLD_PLAYBACK")
        super.tearDown()
    }

    private func tmp(_ s: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-runstore-\(s)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makePlayer() -> SetlistPlayer {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burns = BurnStore(rips: rips, fileURL: tmp("burns"))
        let coordinator = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                              appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
    }

    private func makeStore(_ url: URL? = nil) -> (PocketRunStore, SetlistPlayer, PlayHistoryStore) {
        let history = PlayHistoryStore(fileURL: tmp("hist"))
        let player = makePlayer()
        let store = PocketRunStore(history: history, player: player, fileURL: url ?? tmp("run"))
        store.tickerEnabled = false
        let universe = PocketRunPlannerTests.universe()
        store.candidates = { universe }
        return (store, player, history)
    }

    /// Record a run row's play the way the app's history hook does, then classify it.
    private func play(_ item: SetlistPlayer.Item, history: PlayHistoryStore, store: PocketRunStore,
                      at ms: Double, skipped: Bool) {
        guard let e = history.record(songId: item.id, context: .init(source: .pocket, contextId: nil, contextName: nil),
                                     at: ms),
              let tag = store.tag(forPlan: item.plan) else { return XCTFail("recorded + tagged") }
        history.stampPocketRun(eventId: e.id, tag: tag)
        if skipped { history.markSkipped(eventId: e.id); history.noteListened(eventId: e.id, fraction: 0.05) }
        else { history.noteListened(eventId: e.id, fraction: 1) }
    }

    func testStartPlaysHundredTaggedRowsAndRestoresMidRun() async throws {
        let url = tmp("run-restore")
        let (store, player, _) = makeStore(url)
        await store.start(profile: PocketRunPlannerTests.profile(), seed: 11)
        let run = try XCTUnwrap(store.active)
        XCTAssertEqual(player.queue.count, 100)
        XCTAssertTrue(player.queue.allSatisfy { $0.plan?.runId == run.runId })
        XCTAssertEqual(player.sourceSetlistId, PocketWheelIds.runTag(run.runId))
        XCTAssertEqual(PocketRunStore.runNames[run.tag], run.label)
        XCTAssertTrue(run.label.hasPrefix("Pocket · Tue 8 AM"))
        XCTAssertEqual(store.progress?.done, 0)
        XCTAssertEqual(store.progress?.total, 100)
        // A relaunch mid-run keeps the run (its learned state is derived from history).
        let reopened = PocketRunStore(history: PlayHistoryStore(fileURL: tmp("h2")), player: nil, fileURL: url)
        XCTAssertEqual(reopened.active?.runId, run.runId)
        XCTAssertEqual(reopened.active?.bench, run.bench)
        player.stop()
    }

    func testVerdictsCountAndAFastSkipBansTheArtistForTheRun() async throws {
        let (store, player, history) = makeStore()
        await store.start(profile: PocketRunPlannerTests.profile(), seed: 3)
        let u = PocketRunPlannerTests.universe()
        let t0 = Date().timeIntervalSince1970 * 1000
        play(player.queue[0], history: history, store: store, at: t0 + 1_000, skipped: false)
        let drake = try XCTUnwrap(player.queue.first { u[$0.id]?.features.artistKeys.contains("drake") == true })
        play(drake, history: history, store: store, at: t0 + 2_000, skipped: true)
        store.evaluate()
        XCTAssertEqual(store.active?.playedThrough, 1)
        XCTAssertEqual(store.active?.skips, 1)
        XCTAssertEqual(store.active?.banned.contains("drake"), true, "skip Drake → no more Drake this run")
        // The same events are never counted twice.
        store.evaluate()
        XCTAssertEqual(store.active?.playedThrough, 1)
        player.stop()
    }

    func testRunStopsAtOneHundredPlayedThrough() async throws {
        let (store, player, history) = makeStore()
        await store.start(profile: PocketRunPlannerTests.profile(), seed: 5)
        let t0 = Date().timeIntervalSince1970 * 1000
        let items = Array(player.queue)
        for (i, it) in items.enumerated() {
            play(it, history: history, store: store, at: t0 + Double(i) * 60_000, skipped: false)
        }
        store.evaluate()
        XCTAssertEqual(store.past.last?.playedThrough, 100)
        XCTAssertEqual(store.past.last?.finished, true, "100 played-through ⇒ the run is finished")
        XCTAssertEqual(store.active?.finished, true, "the 'Pocket finished' card shows")
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.runHistory(for: PocketMomentKey(hour: 8, dow: 2, mode: .carPlay)).first?.playedThrough, 100)
        store.dismissFinished()
        XCTAssertNil(store.active)
        player.stop()
    }

    func testHistoryTagAndContextName() async throws {
        let (store, player, _) = makeStore()
        await store.start(profile: PocketRunPlannerTests.profile(), seed: 9)
        let tag = try XCTUnwrap(store.tag(forPlan: player.queue[4].plan))
        XCTAssertEqual(tag.slot, 5)
        XCTAssertEqual(tag.momentKey, "h08|d2|carPlay")
        XCTAssertNil(store.tag(forPlan: nil), "manual rows carry no run tag")
        let ctx = PocketDJApp.historyContext(forSourceSetlistId: player.sourceSetlistId, collections: nil)
        XCTAssertEqual(ctx.source, .pocket)
        XCTAssertEqual(ctx.name, store.active?.label)
        player.stop()
    }
}

/// Phase 5b — adapt to activity mid-run.
@MainActor
final class PocketRunActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_115_000)
    private func seg(_ a: String, at s: Double, conf: Int = 2) -> MotionSegment {
        MotionSegment(start: t0.addingTimeInterval(s), end: t0.addingTimeInterval(s + 1), activity: a, confidence: conf)
    }

    func testSustainedChangeNeedsThreeMinutes() {
        var t = ActivityTracker()
        t.note(seg("running", at: 0))
        XCTAssertNil(t.sustainedMode(now: t0.addingTimeInterval(170)))
        XCTAssertEqual(t.sustainedMode(now: t0.addingTimeInterval(181)), .running)
        t.note(seg("running", at: 120))             // same activity: the clock keeps running
        XCTAssertEqual(t.sustainedMode(now: t0.addingTimeInterval(181)), .running)
        t.note(seg("walking", at: 200))             // change: restart
        XCTAssertNil(t.sustainedMode(now: t0.addingTimeInterval(300)))
        XCTAssertEqual(t.sustainedMode(now: t0.addingTimeInterval(381)), .walking)
        t.note(seg("stationary", at: 400))
        XCTAssertNil(t.sustainedMode(now: t0.addingTimeInterval(1_000)), "stationary never re-targets")
        t.note(seg("automotive", at: 1_000, conf: 0))
        XCTAssertEqual(t.activity, "stationary", "low confidence ignored")
    }

    func testRetargetReplacesUpcomingRowsFromTheNewProfile() async throws {
        setenv("PDJ_HOLD_PLAYBACK", "1", 1)
        defer { unsetenv("PDJ_HOLD_PLAYBACK") }
        let tmp = { (s: String) -> URL in
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-retarget-\(s)-\(UUID().uuidString).json")
            self.addTeardownBlock { try? FileManager.default.removeItem(at: u) }
            return u
        }
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let engine = PlayerEngine()
        let burns = BurnStore(rips: rips, fileURL: tmp("b"))
        let player = SetlistPlayer(player: engine, rips: rips, burns: burns,
                                   coordinator: PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: engine),
                                                                    appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider())))
        let store = PocketRunStore(history: PlayHistoryStore(fileURL: tmp("h")), player: player, fileURL: tmp("r"))
        store.tickerEnabled = false
        let universe = PocketRunPlannerTests.universe()
        store.candidates = { universe }
        await store.start(profile: PocketRunPlannerTests.profile(), seed: 1)
        var running = PocketRunPlannerTests.profile()
        running.collections = ["pkt_late": 1]
        running.genres = ["electronic": 1]
        running.mode = .running
        await store.retarget(to: running, mode: .running)
        XCTAssertEqual(store.active?.retargetedMode, .running)
        let upcoming = player.upcoming.dropFirst()   // the next row may be runway-protected; the rest are free
        let late = upcoming.filter { universe[$0.id]?.memberships["pkt_late"] != nil }.count
        XCTAssertGreaterThan(late, upcoming.count / 2, "the rest of the run now leans to the new mode's pocket")
        XCTAssertEqual(player.queue.count, 100, "re-targeting substitutes; it never extends the run")
        player.stop()
    }
}
