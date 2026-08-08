import XCTest
@testable import PocketDJ

/// The TRI-STATE explicit-versions preference: UNSET (raw nil) by default — the Bool
/// projection reads false but stream substitution stays disarmed until the user chooses;
/// an explicit choice (either direction) persists; a missing blob key coalesces the
/// projection to false while keeping raw nil; reset returns to UNSET.
@MainActor
final class SettingsExplicitPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    func testDefaultIsUnsetAndReadsFalse() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertNil(s.preferExplicitVersionsRaw)      // UNSET — the substitution gate
        XCTAssertFalse(s.preferExplicitVersions)       // projection coalesces to clean
    }

    func testPersistReloadRoundTripBothDirections() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.preferExplicitVersions = true                // explicit choice: prefer explicit
        s.persist()
        let r1 = SettingsStore(defaults: defaults)
        XCTAssertEqual(r1.preferExplicitVersionsRaw, true)
        XCTAssertTrue(r1.preferExplicitVersions)

        r1.preferExplicitVersions = false              // explicit choice: prefer clean
        r1.persist()
        let r2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(r2.preferExplicitVersionsRaw, false)   // SET-false, not unset
        XCTAssertFalse(r2.preferExplicitVersions)
    }

    func testMissingKeyCoalescesFalseAndStaysUnset() throws {
        // A pre-feature blob (no preferExplicitVersions key) must decode with raw nil —
        // never silently promoted to a chosen value by a mere persist of other fields.
        let defaults = freshDefaults()
        let pre = SettingsStore(defaults: defaults)
        pre.persist()                                  // writes a blob with the nil field
        let s = SettingsStore(defaults: defaults)
        XCTAssertNil(s.preferExplicitVersionsRaw)
        XCTAssertFalse(s.preferExplicitVersions)
        s.persist()                                    // still nil after re-persisting
        XCTAssertNil(SettingsStore(defaults: defaults).preferExplicitVersionsRaw)
    }

    func testResetEverythingClearsToUnset() {
        let s = SettingsStore(defaults: freshDefaults())
        s.preferExplicitVersions = true
        XCTAssertEqual(s.preferExplicitVersionsRaw, true)
        s.resetEverything()
        XCTAssertNil(s.preferExplicitVersionsRaw)      // back to the fresh-install UNSET
        XCTAssertFalse(s.preferExplicitVersions)
    }
}
