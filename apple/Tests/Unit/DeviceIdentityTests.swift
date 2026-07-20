import XCTest
@testable import PocketDJ

/// The per-install identity primitives introduced with account deletion:
///   • `DeviceIdentity` — a stable, minted-once install id that `reset()` forgets (the LAST
///     step of `AccountDeletionService.deleteAccountAndAllData()`, so a re-created account
///     presents as a brand-new install), and
///   • `PDJIdentityHeaders` — the two additive per-user headers that ride every authenticated
///     server call alongside the shared bearer.
///
/// Both are pure and dependency-free, so this locks their contract without standing up the
/// full deletion graph.
final class DeviceIdentityTests: XCTestCase {

    /// Mirrors `DeviceIdentity.defaultsKey` (which is `private`, so it can't be referenced even
    /// under `@testable`). Kept in sync by hand — the value is load-bearing for persistence.
    private let deviceKey = "pdj.device.id"

    private var savedDeviceId: String?

    override func setUp() {
        super.setUp()
        // Snapshot + restore the real key so these tests don't perturb the test host's defaults.
        savedDeviceId = UserDefaults.standard.string(forKey: deviceKey)
    }

    override func tearDown() {
        if let savedDeviceId {
            UserDefaults.standard.set(savedDeviceId, forKey: deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: deviceKey)
        }
        super.tearDown()
    }

    // MARK: - DeviceIdentity

    func testDeviceIdIsFrozenAtFirstAccessAndPersisted() {
        UserDefaults.standard.removeObject(forKey: deviceKey)

        let first = DeviceIdentity.current
        XCTAssertFalse(first.isEmpty, "a device id must always be minted")
        XCTAssertEqual(first, DeviceIdentity.current,
                       "the device id is frozen at first access — repeated reads never re-mint")
        XCTAssertEqual(first, UserDefaults.standard.string(forKey: deviceKey),
                       "current must persist under the documented key")
    }

    func testResetForgetsTheIdThenNextAccessRemintsFresh() {
        _ = DeviceIdentity.current            // ensure something is persisted

        DeviceIdentity.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: deviceKey),
                     "reset() — the final step of account deletion — must forget the stored id")

        // The next access re-mints a fresh, non-empty id and re-persists it. (On iOS the mint
        // re-seeds from the stable vendor id, so the VALUE may repeat; the guarantee tested here
        // is that the id is forgotten and re-established, not that it necessarily changes.)
        let reminted = DeviceIdentity.current
        XCTAssertFalse(reminted.isEmpty)
        XCTAssertEqual(reminted, UserDefaults.standard.string(forKey: deviceKey))
    }

    // MARK: - PDJIdentityHeaders

    func testDeviceHeaderAlwaysRidesAndProfileHeaderCarriesTheId() {
        var request = URLRequest(url: URL(string: "https://rip.example.com/health")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        PDJIdentityHeaders.apply(to: &request, profileId: "profile-123")

        XCTAssertEqual(request.value(forHTTPHeaderField: PDJIdentityHeaders.deviceHeader),
                       DeviceIdentity.current,
                       "the device header always rides, carrying this install's id")
        XCTAssertEqual(request.value(forHTTPHeaderField: PDJIdentityHeaders.profileHeader),
                       "profile-123",
                       "a non-empty profile id rides as the profile header")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token",
                       "identity headers are ADDITIVE — the shared bearer is never touched")
    }

    func testProfileHeaderOmittedWhenIdIsBlank() {
        for blank in ["", "   "] {
            var request = URLRequest(url: URL(string: "https://rip.example.com/health")!)
            PDJIdentityHeaders.apply(to: &request, profileId: blank)

            XCTAssertNil(request.value(forHTTPHeaderField: PDJIdentityHeaders.profileHeader),
                         "no identity yet (\"\(blank)\") ⇒ the profile header is omitted, not sent empty")
            XCTAssertFalse(request.value(forHTTPHeaderField: PDJIdentityHeaders.deviceHeader)?.isEmpty ?? true,
                           "the device header still rides even without a profile")
        }
    }
}
