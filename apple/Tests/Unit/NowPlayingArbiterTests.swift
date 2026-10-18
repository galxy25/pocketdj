import XCTest
@testable import PocketDJ

/// `NowPlayingArbiter` — a nil owner is not "everyone" once a restore names a preferred engine.
@MainActor
final class NowPlayingArbiterTests: XCTestCase {
    private final class Engine {}

    override func setUp() { super.setUp(); NowPlayingArbiter.shared.resetForTesting() }
    override func tearDown() { NowPlayingArbiter.shared.resetForTesting(); super.tearDown() }

    func testNilOwnerWithPreferredOnlyAdmitsPreferred() {
        let a = Engine(), b = Engine()
        let arb = NowPlayingArbiter.shared
        XCTAssertTrue(arb.isActive(a)); XCTAssertTrue(arb.isActive(b))
        arb.prefer(a)
        XCTAssertTrue(arb.isActive(a))
        XCTAssertFalse(arb.isActive(b), "a parked engine must not answer a remote command meant for the held set")
    }

    func testClaimFiresOwnerChangedOnceAndClearsForeignPreference() {
        let a = Engine(), b = Engine()
        let arb = NowPlayingArbiter.shared
        var changes: [(AnyObject, AnyObject?)] = []
        let before = arb.onOwnerChanged.count
        arb.onOwnerChanged.append { new, old in changes.append((new, old)) }
        defer { arb.onOwnerChanged.remove(at: before) }
        arb.prefer(a)
        arb.claim(b)
        arb.claim(b)
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].0 === b); XCTAssertNil(changes[0].1)
        XCTAssertNil(arb.preferred)
        XCTAssertFalse(arb.isActive(a))
        arb.resign(b)
        XCTAssertTrue(arb.isActive(a))
    }
}
