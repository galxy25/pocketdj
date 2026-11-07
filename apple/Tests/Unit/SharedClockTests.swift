import XCTest
@testable import PocketDJ

/// The Remote session's shared clock (NTP-style offset to the host). Pure math first, then the
/// ping/pong API under a skewed participant clock with asymmetric network delay on a virtual
/// timeline, then the controller wiring over a LoopbackTransport.
@MainActor
final class SharedClockTests: XCTestCase {

    /// A virtual "true" timeline every device clock is derived from.
    private final class TrueTime { var t: Double = 1_000_000 }

    func testOffsetMathSymmetricDelayIsExact() {
        // Participant runs 5 s BEHIND the host; 40 ms each way.
        let skew = -5_000.0
        let tTrue0 = 10_000.0
        let t0 = tTrue0 + skew
        let t1 = tTrue0 + 40
        let t2 = t1 + 1
        let t3 = (tTrue0 + 81) + skew
        let s = SharedClock.sample(t0: t0, t1: t1, t2: t2, t3: t3)
        XCTAssertEqual(s.offsetMs, 5_000, accuracy: 0.001)
        XCTAssertEqual(s.rttMs, 80, accuracy: 0.001)
    }

    func testAsymmetricDelayErrorIsHalfTheAsymmetryAndBoundedByHalfRtt() {
        let skew = 2_500.0
        let fwd = 10.0, back = 90.0
        let tTrue0 = 50_000.0
        let s = SharedClock.sample(t0: tTrue0 + skew, t1: tTrue0 + fwd, t2: tTrue0 + fwd,
                                   t3: tTrue0 + fwd + back + skew)
        let err = s.offsetMs - (-skew)
        XCTAssertEqual(err, (fwd - back) / 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(err), s.rttMs / 2 + 0.001)
    }

    func testKeepsTheLowestRttOfTheLastEightSamples() {
        let c = SharedClock(localNow: { 0 })
        c.reset(hostId: "H", isHost: false)
        XCTAssertFalse(c.isSynced)
        XCTAssertNil(c.sharedNow)
        // An excellent sample first, then 8 worse ones push it out of the window.
        c.ingest(.init(offsetMs: 100, rttMs: 2))
        XCTAssertEqual(c.offsetMs, 100)
        for i in 0..<8 { c.ingest(.init(offsetMs: Double(200 + i), rttMs: Double(50 + i))) }
        XCTAssertEqual(c.samples.count, SharedClock.sampleCap)
        XCTAssertEqual(c.best?.rttMs, 50, "the rtt-2 sample aged out; the best of the last 8 wins")
        XCTAssertEqual(c.offsetMs, 200)
        // A better new sample takes over immediately.
        c.ingest(.init(offsetMs: 150, rttMs: 5))
        XCTAssertEqual(c.offsetMs, 150)
    }

    func testPingPongUnderSkewAndAsymmetricDelayConvergesOnTheFastestExchange() {
        let truth = TrueTime()
        let skew = 7_000.0                      // participant clock runs 7 s AHEAD of the host
        let host = SharedClock(localNow: { truth.t })
        let part = SharedClock(localNow: { truth.t + skew })
        host.reset(hostId: "H", isHost: true)
        part.reset(hostId: "H", isHost: false)
        // Eight exchanges with varying, asymmetric paths; exchange 5 is the fastest + most symmetric.
        let paths: [(Double, Double)] = [(30, 120), (80, 20), (45, 60), (25, 90), (6, 8), (70, 70), (40, 15), (90, 30)]
        for (fwd, back) in paths {
            let ping = part.makePing()
            truth.t += fwd
            let pong = host.pong(for: ping)
            truth.t += back
            part.ingest(pong, from: "H")
            truth.t += 1_000
        }
        XCTAssertEqual(part.best?.rttMs ?? -1, 14, accuracy: 0.001)
        XCTAssertEqual(part.offsetMs ?? 0, -skew + (6 - 8) / 2, accuracy: 0.001)
        // Conversions: shared ≈ host time, and back.
        XCTAssertEqual(part.sharedNow ?? 0, truth.t - 1, accuracy: 0.001)
        let shared = host.localNow()
        XCTAssertEqual(part.localTime(forShared: shared) ?? 0, truth.t + skew + 1, accuracy: 0.001)
        // A pong from anyone but the measured host is ignored.
        let before = part.samples.count
        part.ingest(RemotePong(id: "x", t0: 0, t1: 0, t2: 0), from: "someone-else")
        XCTAssertEqual(part.samples.count, before)
        // Host hand-over: samples reset, not synced until re-measured.
        part.reset(hostId: "H2", isHost: false)
        XCTAssertFalse(part.isSynced)
    }

    func testControllersExchangePingsOverLoopbackAndEstimateTheSkew() async {
        let truth = TrueTime()
        let hub = LoopbackHub()
        let a = hub.join(id: "A"), b = hub.join(id: "B")
        let resolver = RemoteSongResolver(catalogItem: { _ in nil })
        let host = RemoteSessionController(target: nil, resolver: resolver, deviceName: "A", platform: "t",
                                           clock: SharedClock(localNow: { truth.t }))
        let part = RemoteSessionController(target: nil, resolver: resolver, deviceName: "B", platform: "t",
                                           clock: SharedClock(localNow: { truth.t - 3_210 }))
        host.attach(a, mode: .listenTogether, asHost: true, autoTick: false)
        part.attach(b, mode: .listenTogether, asHost: false, autoTick: false)
        await RemoteTestSupport.waitUntil { part.hostId == "A" }
        part.tick()                                   // sends the first ping
        await RemoteTestSupport.waitUntil { part.clock.isSynced }
        XCTAssertEqual(part.clock.offsetMs ?? 0, 3_210, accuracy: 0.001)
        XCTAssertEqual(part.clock.sharedNow ?? 0, truth.t, accuracy: 0.001)
    }
}

/// Shared async helpers for the Remote suites — every wait is on the asserted condition.
@MainActor
enum RemoteTestSupport {
    static func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                          _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
