import XCTest
@testable import PocketDJ

/// DeadAirMeter — the persisted dead-air metric: per-transition gaps keyed by from→to backend,
/// continuous active/dead seconds from the supervisor, a per-day rollup that survives relaunch.
@MainActor
final class DeadAirMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var url: URL!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("deadair-\(UUID().uuidString).json")
        lines = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func makeMeter() -> DeadAirMeter {
        let m = DeadAirMeter(fileURL: url)
        m.calendar = Calendar(identifier: .gregorian)
        m.calendar.timeZone = TimeZone(identifier: "UTC")!
        m.log = { [weak self] in self?.lines.append($0) }
        return m
    }

    /// Play one track to first audio so the meter knows the `from` backend.
    private func prime(_ m: DeadAirMeter, backend: String) {
        m.transitionBegan(cause: "start", now: t0)
        m.trackStarting(backend: backend)
        m.firstAudio(now: t0)
    }

    func testAdvanceGapIsKeyedByFromToBackend() {
        let m = makeMeter()
        prime(m, backend: "appleMusic")
        m.transitionBegan(cause: "advance", now: t0.addingTimeInterval(200))
        m.trackStarting(backend: "appleMusic")
        m.firstAudio(now: t0.addingTimeInterval(202.5))
        let d = m.day(t0)
        XCTAssertEqual(d.byPair["appleMusic→appleMusic"]?.n, 1)
        XCTAssertEqual(d.byPair["appleMusic→appleMusic"]?.seconds ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(d.gapsOver1s, 1)
        XCTAssertEqual(d.gapsOver3s, 0)
        XCTAssertTrue(lines.contains { $0.hasPrefix("gap=2.50s from=appleMusic to=appleMusic cause=advance") })
    }

    /// A start that hops rows (stall → on-device hop) is ONE transition from its original start.
    func testHopInsideOneSilenceStaysOneTransitionFromOriginalStart() {
        let m = makeMeter()
        prime(m, backend: "appleMusic")
        m.transitionBegan(cause: "advance", now: t0.addingTimeInterval(100))
        m.trackStarting(backend: "burned")
        m.transitionBegan(cause: "start", now: t0.addingTimeInterval(120))   // the hop's playCurrent
        m.trackStarting(backend: "burned")
        m.firstAudio(now: t0.addingTimeInterval(130))
        let d = m.day(t0)
        XCTAssertEqual(d.transitions, 2, "prime + one hop transition")
        XCTAssertEqual(d.byPair["appleMusic→burned"]?.seconds ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(d.gapsOver10s, 1)
    }

    func testAbandonedTransitionIsNotRecorded() {
        let m = makeMeter()
        prime(m, backend: "burned")
        m.transitionBegan(cause: "advance", now: t0.addingTimeInterval(10))
        m.transitionAbandoned(reason: "paused")
        m.firstAudio(now: t0.addingTimeInterval(500))   // the listener's later ▶
        XCTAssertNil(m.day(t0).byPair["burned→burned"])
        XCTAssertEqual(m.day(t0).transitions, 1, "only the prime")
    }

    func testNonAdvanceCausesArePrefixed() {
        let m = makeMeter()
        prime(m, backend: "burned")
        m.transitionBegan(cause: "skip", now: t0.addingTimeInterval(5))
        m.trackStarting(backend: "appleMusic")
        m.firstAudio(now: t0.addingTimeInterval(7))
        XCTAssertNotNil(m.day(t0).byPair["skip:burned→appleMusic"])
        XCTAssertNotNil(m.day(t0).byPair["start:none→burned"])
    }

    func testContinuousSplitAndRatio() {
        let m = makeMeter()
        m.accumulate(active: 100, dead: 4, transitionDead: 3, now: t0)
        let d = m.day(t0)
        XCTAssertEqual(d.activeSeconds, 100)
        XCTAssertEqual(d.deadSeconds, 4)
        XCTAssertEqual(d.transitionDeadSeconds, 3)
        XCTAssertEqual(d.midSongDeadSeconds, 1)
        XCTAssertEqual(d.deadRatio, 0.04, accuracy: 1e-9)
    }

    func testDaysRollOverAndPersistAcrossRelaunch() {
        let m = makeMeter()
        m.accumulate(active: 60, dead: 2, transitionDead: 2, now: t0)
        m.accumulate(active: 30, dead: 1, transitionDead: 0, now: t0.addingTimeInterval(86_400))
        m.flush(now: t0.addingTimeInterval(86_400))
        let reloaded = makeMeter()
        XCTAssertEqual(reloaded.document.days.count, 2)
        XCTAssertEqual(reloaded.day(t0).activeSeconds, 60)
        XCTAssertEqual(reloaded.day(t0.addingTimeInterval(86_400)).midSongDeadSeconds, 1)
    }

    func testSummaryLoggedEveryActiveWindow() {
        let m = makeMeter()
        let saved = DeadAirMeter.summaryEveryActiveSeconds
        DeadAirMeter.summaryEveryActiveSeconds = 10
        defer { DeadAirMeter.summaryEveryActiveSeconds = saved }
        for i in 0..<10 { m.accumulate(active: 1, dead: 0, transitionDead: 0, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(lines.filter { $0.hasPrefix("day=") }.count, 1)
    }

    // MARK: Supervisor feeds

    func testSupervisorCountsActiveAndTransitionDeadSeconds() {
        var core = PlaybackSupervisor.Core()
        var p = PlaybackSupervisor.Probe()
        p.lane = .appleMusic; p.intentPlaying = true; p.songId = "s1"
        p.audible = true
        for i in 0..<10 { _ = core.step(p, now: t0.addingTimeInterval(Double(i))) }
        p.audible = false; p.startPending = true
        for i in 10..<13 { _ = core.step(p, now: t0.addingTimeInterval(Double(i))) }
        p.startPending = false
        for i in 13..<15 { _ = core.step(p, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(core.activeTotal, 14, accuracy: 0.001, "first tick has no dt")
        XCTAssertEqual(core.deadAirTotal, 5, accuracy: 0.001)
        XCTAssertEqual(core.transitionDeadTotal, 3, accuracy: 0.001)
    }

    func testSupervisorPausedListenerIsNeitherActiveNorDead() {
        var core = PlaybackSupervisor.Core()
        var p = PlaybackSupervisor.Probe()
        p.lane = .local; p.intentPlaying = false
        for i in 0..<20 { _ = core.step(p, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(core.activeTotal, 0)
        XCTAssertEqual(core.deadAirTotal, 0)
    }

    func testSupervisorShellFeedsMeterAndAbandonsOnPause() {
        let m = makeMeter()
        prime(m, backend: "burned")
        var p = PlaybackSupervisor.Probe()
        p.lane = .local; p.intentPlaying = true; p.startPending = true
        var clock = t0
        let sup = PlaybackSupervisor(probe: { p }, perform: { _ in })
        sup.now = { clock }
        sup.log = { _ in }
        sup.meter = m
        m.transitionBegan(cause: "advance", now: clock)
        for _ in 0..<4 { sup.tick(); clock.addTimeInterval(1) }
        XCTAssertEqual(m.day(t0).transitionDeadSeconds, 3, accuracy: 0.001)
        p.intentPlaying = false
        sup.tick()
        XCTAssertNil(m.open, "a listener pause abandons the open transition")
    }
}
