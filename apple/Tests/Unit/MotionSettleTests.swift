import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 1 — the retroactive motion settle (§1.4), driven by a fake provider with
/// scripted segments: overlap winner, the confidence filter, the 7-day horizon, ties, and plays
/// still pending (< 2 min old / window not over).
@MainActor
final class MotionSettleTests: XCTestCase {

    private let t0 = 1_793_115_000_000.0   // a fixed "now" (epoch ms)
    private func d(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
    private func seg(_ fromMinAgo: Double, _ toMinAgo: Double, _ activity: String, conf: Int = 2) -> MotionSegment {
        MotionSegment(start: d(t0 - fromMinAgo * 60_000), end: d(t0 - toMinAgo * 60_000),
                      activity: activity, confidence: conf)
    }
    private func play(minAgo: Double, minutes: Double = 3) -> MotionSettle.Play {
        .init(id: UUID(), playedAtMs: t0 - minAgo * 60_000, durationMs: minutes * 60_000)
    }

    // MARK: - Pure rule

    func testMostOverlapWins() {
        let p = play(minAgo: 30, minutes: 4)                          // 30 → 26 min ago
        let segs = [seg(31, 29, MotionToken.walking),                // 1 min overlap
                    seg(29, 20, MotionToken.running)]                // 3 min overlap
        XCTAssertEqual(MotionSettle.settle(plays: [p], segments: segs, nowMs: t0)[p.id], "running")
    }

    func testLowConfidenceSegmentsAreIgnored() {
        let p = play(minAgo: 30, minutes: 4)
        let segs = [seg(31, 20, MotionToken.running, conf: 0),        // low — says nothing
                    seg(28, 27, MotionToken.walking, conf: 1)]        // medium — counts
        XCTAssertEqual(MotionSettle.settle(plays: [p], segments: segs, nowMs: t0)[p.id], "walking")
        XCTAssertTrue(MotionSettle.settle(plays: [p], segments: [seg(31, 20, "running", conf: 0)], nowMs: t0).isEmpty)
    }

    func testTiesGoToTheMoreActiveState() {
        let p = play(minAgo: 30, minutes: 4)                          // 30 → 26
        let segs = [seg(30, 28, MotionToken.automotive), seg(28, 26, MotionToken.walking)]   // 2 min each
        XCTAssertEqual(MotionSettle.settle(plays: [p], segments: segs, nowMs: t0)[p.id], "walking")
        let segs2 = [seg(30, 28, MotionToken.stationary), seg(28, 26, MotionToken.cycling)]
        XCTAssertEqual(MotionSettle.settle(plays: [p], segments: segs2, nowMs: t0)[p.id], "cycling")
    }

    func testPendingAndHorizon() {
        let fresh = play(minAgo: 1, minutes: 0.5)                     // < 2 min old
        let ongoing = play(minAgo: 3, minutes: 4)                     // window still running
        let old = MotionSettle.Play(id: UUID(), playedAtMs: t0 - 7 * 86_400_000, durationMs: 180_000)
        let segs = [MotionSegment(start: d(t0 - 8 * 86_400_000), end: d(t0), activity: "running", confidence: 2)]
        let out = MotionSettle.settle(plays: [fresh, ongoing, old], segments: segs, nowMs: t0)
        XCTAssertNil(out[fresh.id], "under 2 min old: still pending")
        XCTAssertNil(out[ongoing.id], "its window hasn't ended")
        XCTAssertNil(out[old.id], "beyond the 6.5-day horizon: never asked")
        XCTAssertEqual(MotionSettle.settle(plays: [play(minAgo: 10)], segments: segs, nowMs: t0).values.first, "running")
    }

    func testNoOverlapLeavesThePlayUnsettled() {
        let p = play(minAgo: 60)
        XCTAssertTrue(MotionSettle.settle(plays: [p], segments: [seg(30, 10, "running")], nowMs: t0).isEmpty)
    }

    func testDurationEstimate() {
        XCTAssertEqual(MotionSettle.duration(lengthMs: nil, listenedFraction: nil), 180_000)
        XCTAssertEqual(MotionSettle.duration(lengthMs: 240_000, listenedFraction: nil), 240_000)
        XCTAssertEqual(MotionSettle.duration(lengthMs: 240_000, listenedFraction: 0.5), 120_000)
        XCTAssertEqual(MotionSettle.duration(lengthMs: 240_000, listenedFraction: 0.01), 30_000, "floored at 30 s")
    }

    func testCurrentActivityIsTheLatestQualifyingSegment() {
        XCTAssertEqual(MotionSettle.current(from: [seg(5, 3, "walking"), seg(3, 0, "running"), seg(2, 0, "automotive", conf: 0)]),
                       "running")
        XCTAssertNil(MotionSettle.current(from: [seg(5, 0, "running", conf: 0)]))
    }

    // MARK: - Store + fake provider

    private final class FakeProvider: MotionActivityProviding {
        var isSupported = true
        var authorization: MotionAuthorization = .authorized
        var scripted: [MotionSegment] = []
        var queries = 0
        func segments(from: Date, to: Date) async -> [MotionSegment] {
            queries += 1
            guard authorization == .authorized else { return [] }
            return scripted.filter { $0.end > from && $0.start < to }
        }
        func startLiveUpdates(_ handler: @escaping @MainActor (MotionSegment) -> Void) {}
        func stopLiveUpdates() {}
    }

    private func tmp(_ stem: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-motion-\(stem)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStoreSettlesOwnUnsettledPlaysOnly() async {
        let fake = FakeProvider()
        fake.scripted = [seg(120, 0, MotionToken.running)]
        let store = ListeningMotionStore(fileURL: tmp("store"), provider: fake, platformSupported: true)
        store.now = { Date(timeIntervalSince1970: self.t0 / 1000) }
        await store.setEnabled(true)
        let history = PlayHistoryStore(fileURL: tmp("hist"))
        let mine = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s1", playedAt: t0 - 30 * 60_000, source: .pocket,
                                              contextId: nil, contextName: nil, title: nil, artist: nil,
                                              originInstallId: history.installId)
        let peer = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s2", playedAt: t0 - 30 * 60_000, source: .pocket,
                                              contextId: nil, contextName: nil, title: nil, artist: nil,
                                              originInstallId: "peer")
        history.replaceAll([mine, peer])
        let n = await store.settle(history: history, lengthOf: { _ in 200_000 })
        XCTAssertEqual(n, 1)
        XCTAssertEqual(history.events.first { $0.id == mine.id }?.motion, "running")
        XCTAssertNil(history.events.first { $0.id == peer.id }?.motion)
        // Second pass: nothing left to settle, no query needed.
        let before = fake.queries
        let again = await store.settle(history: history, lengthOf: { _ in 200_000 })
        XCTAssertEqual(again, 0)
        XCTAssertEqual(fake.queries, before, "no eligible plays ⇒ no CoreMotion query")
        let now = await store.currentActivity()
        XCTAssertEqual(now, "running")
    }

    func testStoreIsInertWhenDeniedOrOff() async {
        let fake = FakeProvider()
        fake.scripted = [seg(120, 0, MotionToken.running)]
        fake.authorization = .denied
        let url = tmp("denied")
        let store = ListeningMotionStore(fileURL: url, provider: fake, platformSupported: true)
        store.now = { Date(timeIntervalSince1970: self.t0 / 1000) }
        let history = PlayHistoryStore(fileURL: tmp("hist2"))
        history.replaceAll([PlayHistoryStore.PlayEvent(id: UUID(), songId: "s1", playedAt: t0 - 30 * 60_000,
                                                       source: .pocket, contextId: nil, contextName: nil,
                                                       title: nil, artist: nil, originInstallId: history.installId)])
        let offCount = await store.settle(history: history, lengthOf: { _ in nil })
        XCTAssertEqual(offCount, 0, "off by default")
        await store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.isActive, "enabled but denied ⇒ inert")
        let deniedCount = await store.settle(history: history, lengthOf: { _ in nil })
        XCTAssertEqual(deniedCount, 0)
        XCTAssertNil(history.events.first?.motion)
        // The opt-in persists.
        let reread = ListeningMotionStore(fileURL: url, provider: fake, platformSupported: true)
        XCTAssertTrue(reread.isEnabled)
        // An unsupported platform never enables.
        let mac = ListeningMotionStore(fileURL: url, provider: fake, platformSupported: false)
        XCTAssertFalse(mac.isSupported)
        XCTAssertFalse(mac.isEnabled)
    }

    func testNoopProviderIsInert() async {
        let noop = NoopMotionActivityProvider()
        XCTAssertFalse(noop.isSupported)
        XCTAssertEqual(noop.authorization, .unsupported)
        let segs = await noop.segments(from: Date(timeIntervalSince1970: 0), to: Date())
        XCTAssertTrue(segs.isEmpty)
    }
}
