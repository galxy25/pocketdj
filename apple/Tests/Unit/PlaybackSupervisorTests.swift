import XCTest
@testable import PocketDJ

/// §3 "keep playing" supervisor (setlist lane) — table-driven over the pure core with a fake
/// clock, plus the shell with stub probe / perform closures. The load-bearing NEGATIVE cases:
/// a listener pause (and every other "not ours to touch" state) produces ZERO actions.
@MainActor
final class PlaybackSupervisorTests: XCTestCase {
    private typealias Probe = PlaybackSupervisor.Probe
    private typealias Action = PlaybackSupervisor.Action
    private let t0 = Date(timeIntervalSince1970: 10_000)

    /// The silent-but-wanted local lane: the state the ladder exists for.
    private var silentLocal: Probe {
        var p = Probe()
        p.lane = .local; p.intentPlaying = true; p.songId = "s1"
        return p
    }

    /// Run `ticks` 1 Hz ticks (probe may vary per tick); return (tick index, action) pairs + lines.
    private func run(_ core: inout PlaybackSupervisor.Core, ticks: Int, start: Int = 0,
                     probe: (Int) -> Probe) -> (actions: [(Int, Action)], lines: [String]) {
        var actions: [(Int, Action)] = []
        var lines: [String] = []
        for i in start..<(start + ticks) {
            let (a, l) = core.step(probe(i), now: t0.addingTimeInterval(Double(i)))
            if let a { actions.append((i, a)) }
            lines += l
        }
        return (actions, lines)
    }

    // MARK: Negative table — never touch these (60 ticks each)

    func testNotOursToTouchProducesZeroActionsFor60Ticks() {
        var cases: [(String, Probe)] = []
        var p = silentLocal; p.intentPlaying = false;     cases.append(("listener paused (intent)", p))
        p = silentLocal; p.userPaused = true;             cases.append(("listener paused (item)", p))
        p = silentLocal; p.interruptionOpen = true;       cases.append(("interruption open", p))
        p = silentLocal; p.held = true;                   cases.append(("held restore", p))
        p = silentLocal; p.cascadeHalted = true;          cases.append(("cascade halted", p))
        p = silentLocal; p.lane = .idle;                  cases.append(("no set", p))
        p = silentLocal; p.startPending = true;           cases.append(("start window open (watchdog owns it)", p))
        p = silentLocal; p.trackEnded = true;             cases.append(("track ended (sequencer owns it)", p))
        p = silentLocal; p.lane = .appleMusic;            cases.append(("Apple Music (detector only)", p))
        for (name, probe) in cases {
            var core = PlaybackSupervisor.Core()
            let r = run(&core, ticks: 60) { _ in probe }
            XCTAssertTrue(r.actions.isEmpty, "\(name): expected zero actions, got \(r.actions)")
        }
    }

    func testUserPausedNeverCountsDeadAir() {
        var core = PlaybackSupervisor.Core()
        var p = silentLocal; p.intentPlaying = false
        let r = run(&core, ticks: 130) { _ in p }
        XCTAssertEqual(core.deadAirTotal, 0)
        XCTAssertFalse(r.lines.contains { $0.contains("dead-air") })
    }

    // MARK: The ladder

    func testSilentLocalLaneClimbsL1L2L3OnSchedule() {
        var core = PlaybackSupervisor.Core()
        let r = run(&core, ticks: 40) { _ in self.silentLocal }
        XCTAssertEqual(r.actions.map(\.1), [.rekick, .retryInPlace, .escalate])
        // Silence starts at tick 0 (anchor): L1 @3 s, L2 @+12 s, L3 @+8 s.
        XCTAssertEqual(r.actions.map(\.0), [3, 15, 23])
        XCTAssertTrue(r.lines.first?.hasPrefix("silent owner=PlayerEngine lane=local song=s1") ?? false)
        XCTAssertTrue(r.lines.contains { $0.hasPrefix("step=L1 action=rekick") })
    }

    func testProofResetsTheLadderAndLogsOk() {
        var core = PlaybackSupervisor.Core()
        let r = run(&core, ticks: 30) { i in
            var p = self.silentLocal
            p.audible = i >= 5           // L1 at 3 s worked
            return p
        }
        XCTAssertEqual(r.actions.map(\.1), [.rekick], "sound came back after L1 — nothing more")
        XCTAssertTrue(r.lines.contains { $0.hasPrefix("ok after=5s lane=local stage=L1") })
        XCTAssertEqual(core.stage, 0)
    }

    /// The start watchdog owns a track start; the supervisor's ladder clock only starts once
    /// the start window closes (no double re-kick at the same moment).
    func testLadderAnchorsWhenTheStartWindowCloses() {
        var core = PlaybackSupervisor.Core()
        let r = run(&core, ticks: 20) { i in
            var p = self.silentLocal
            p.startPending = i < 10
            return p
        }
        XCTAssertEqual(r.actions.first?.0, 13, "L1 = 3 s after the window closed at tick 10, not at tick 3")
        XCTAssertGreaterThanOrEqual(core.deadAirTotal, 19, "the start window's silence still counts as dead air")
    }

    /// L2 re-opens a start window (the retried row's start) → the start watchdog owns it, the
    /// supervisor stands down, and its own L3 never doubles the watchdog's escalation.
    func testRetryHandsTheRowToTheStartWatchdog() {
        var core = PlaybackSupervisor.Core()
        let r = run(&core, ticks: 60) { i in
            var p = self.silentLocal
            p.startPending = i >= 16          // the retry at 15 s opened a start window
            return p
        }
        XCTAssertEqual(r.actions.map(\.1), [.rekick, .retryInPlace])
    }

    func testRetriesPerSongAreCappedThenEscalate() {
        PlaybackSupervisor.Core.maxRetriesPerSong = 1
        defer { PlaybackSupervisor.Core.maxRetriesPerSong = 2 }
        var core = PlaybackSupervisor.Core()
        // Episode 1: L1, L2 (retry) then audio briefly returns.
        var r = run(&core, ticks: 17) { i in var p = self.silentLocal; p.audible = i == 16; return p }
        XCTAssertEqual(r.actions.map(\.1), [.rekick, .retryInPlace])
        // Episode 2 on the same song: the retry budget is spent → L2 slot escalates.
        r = run(&core, ticks: 20, start: 17) { _ in self.silentLocal }
        XCTAssertEqual(r.actions.map(\.1), [.rekick, .escalate])
    }

    func testAListenerPauseMidLadderStopsIt() {
        var core = PlaybackSupervisor.Core()
        let r = run(&core, ticks: 60) { i in
            var p = self.silentLocal
            if i >= 5 { p.intentPlaying = false; p.userPaused = true }   // paused after L1
            return p
        }
        XCTAssertEqual(r.actions.map(\.1), [.rekick])
    }

    func testCascadeHaltLogsOnceAndHolds() {
        var core = PlaybackSupervisor.Core()
        var p = silentLocal; p.cascadeHalted = true
        let r = run(&core, ticks: 30) { _ in p }
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.lines.filter { $0.hasPrefix("halted") }.count, 1)
    }

    func testDeadAirTotalIsReportedEverySixtySeconds() {
        var core = PlaybackSupervisor.Core()
        // Apple Music silent for 70 s (detector only): no actions, but the dead air is reported.
        var p = silentLocal; p.lane = .appleMusic
        let r = run(&core, ticks: 125) { _ in p }
        XCTAssertTrue(r.actions.isEmpty)
        let reports = r.lines.filter { $0.hasPrefix("dead-air total=") }
        XCTAssertEqual(reports.count, 2, "one line per 60 s window with dead air")
        XCTAssertTrue(reports[1].contains("last60=60s"), reports[1])
        XCTAssertEqual(Int(core.deadAirTotal.rounded()), 124)
    }

    // MARK: Shell — stub probe / perform closures + the injected clock

    func testShellPerformsTheCoreActions() {
        var now = t0
        var performed: [Action] = []
        var logged: [String] = []
        var probe = silentLocal
        let sup = PlaybackSupervisor(probe: { probe }, perform: { performed.append($0) })
        sup.now = { now }
        sup.log = { logged.append($0) }
        for _ in 0..<5 { sup.tick(); now = now.addingTimeInterval(1) }
        XCTAssertEqual(performed, [.rekick])
        XCTAssertEqual(sup.actionsTaken, [.rekick])
        probe.intentPlaying = false
        for _ in 0..<60 { sup.tick(); now = now.addingTimeInterval(1) }
        XCTAssertEqual(performed, [.rekick], "paused → the shell performs nothing more")
        XCTAssertTrue(logged.contains { $0.hasPrefix("silent") })
    }

    /// The production wiring over a real (idle) sequencer: nothing running → idle lane → inert.
    func testProductionWiringIsInertWithNoSet() {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-supburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let sup = PlaybackSupervisor(setlist: seq, player: player, coordinator: coord)
        var logged: [String] = []
        sup.log = { logged.append($0) }
        var now = t0
        sup.now = { now }
        for _ in 0..<30 { sup.tick(); now = now.addingTimeInterval(1) }
        XCTAssertTrue(sup.actionsTaken.isEmpty)
        XCTAssertTrue(logged.isEmpty)
        XCTAssertEqual(sup.probe().lane, .idle)
    }
}
