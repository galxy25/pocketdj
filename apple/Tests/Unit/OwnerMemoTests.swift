import XCTest
@testable import PocketDJ

/// The remembered owner answer — what lets the OWNER skip the redundant catalog rebuild — and
/// the tri-state gate that keeps it from misbehaving offline.
@MainActor
final class OwnerMemoTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!
    private var heldApp: AppModel?

    override func setUp() {
        super.setUp()
        suiteName = "pdj.ownermemo.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        heldApp = nil
        super.tearDown()
    }

    private func model(owner: Bool?) -> AppModel {
        let app = AppModel(loader: TestData.StubLoader())
        app.defaults = suite
        app.ownerResolver = { owner }
        heldApp = app
        return app
    }

    // MARK: The gate's tri-state

    func testEmptyAllowlistIsDeterminedNotUnknown() {
        // Nobody being the owner is a real answer, not a failure — so it must not be nil, or a
        // public build would hold a stale `true` forever.
        XCTAssertEqual(OwnerIdentity.isOwner(hash: nil, allowlist: []), false)
        XCTAssertEqual(OwnerIdentity.isOwner(hash: "abc", allowlist: []), false)
    }

    func testKnownHashMembership() {
        XCTAssertTrue(OwnerIdentity.isOwner(hash: "abc", allowlist: ["abc", "def"]))
        XCTAssertFalse(OwnerIdentity.isOwner(hash: "zzz", allowlist: ["abc"]))
    }

    // MARK: The memo

    func testAResolvedAnswerIsRemembered() async {
        let app = model(owner: true)
        await app.loadIfNeeded()
        XCTAssertTrue(app.resolvedIsOwner)
        XCTAssertTrue(suite.bool(forKey: "pdj.catalog.lastKnownIsOwner"),
                      "a real resolution is remembered for the next launch's seed")
    }

    /// The case the tri-state exists for. Offline (`nil`) must HOLD the remembered answer, not
    /// fall to false — otherwise an offline launch un-dedupes a catalog the last one deduped and
    /// the user watches duplicate rows appear.
    func testAnUndeterminedAnswerHoldsTheRememberedOne() async {
        suite.set(true, forKey: "pdj.catalog.lastKnownIsOwner")
        let app = model(owner: nil)
        await app.loadIfNeeded()
        XCTAssertTrue(app.resolvedIsOwner, "offline holds the last known answer")
        XCTAssertTrue(suite.bool(forKey: "pdj.catalog.lastKnownIsOwner"),
                      "and does not overwrite it with a guess")
    }

    /// A non-owner can never acquire a `true`: only a genuine resolution is written, and a
    /// genuine resolution for them is `false`.
    func testANonOwnerNeverAcquiresOwnership() async {
        let app = model(owner: false)
        await app.loadIfNeeded()
        XCTAssertFalse(app.resolvedIsOwner)
        XCTAssertFalse(suite.bool(forKey: "pdj.catalog.lastKnownIsOwner"))
    }

    /// Losing ownership (removed from the allowlist, signed out of iCloud) must take effect —
    /// a resolved `false` overwrites a remembered `true`.
    func testLosingOwnershipClearsTheMemo() async {
        suite.set(true, forKey: "pdj.catalog.lastKnownIsOwner")
        let app = model(owner: false)
        await app.loadIfNeeded()
        XCTAssertFalse(app.resolvedIsOwner)
        XCTAssertFalse(suite.bool(forKey: "pdj.catalog.lastKnownIsOwner"),
                       "a resolved false must overwrite a remembered true")
    }

    /// Fresh install: nothing remembered ⇒ the old fail-closed behaviour exactly.
    func testFreshInstallDefaultsToNotOwner() async {
        let app = model(owner: nil)
        await app.loadIfNeeded()
        XCTAssertFalse(app.resolvedIsOwner)
    }
}
