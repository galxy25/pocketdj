import XCTest
import Security
@testable import PocketDJ

/// Store semantics run against the in-memory backend (an unsigned simulator host refuses
/// EVERY Keychain write with errSecMissingEntitlement, so the old Keychain-backed round trip
/// failed for environmental reasons only). `testKeychainRoundTripWhenEntitled` exercises the
/// real Keychain where the host is entitled and skips — visibly, with the status — where not.
final class DiagCredentialStoreTests: XCTestCase {
    private let store = DiagCredentialStore(service: "com.levi.pocketdj.diag.tests",
                                            memory: DiagCredentialStore.MemoryBox())

    func testEmptyByDefault() {
        XCTAssertNil(store.load())
    }

    func testRoundTripTrimsWhitespace() {
        XCTAssertEqual(store.save(accessKeyID: " test-id \n", secret: "test-secret "), errSecSuccess)
        XCTAssertEqual(store.load(), .init(accessKeyID: "test-id", secret: "test-secret"))
    }

    func testBlankSaveClears() {
        store.save(accessKeyID: "test-id", secret: "test-secret")
        store.save(accessKeyID: "test-id", secret: "  ")
        XCTAssertNil(store.load())
    }

    /// A refused write must be REPORTED (the old store returned Void and swallowed it).
    func testRefusedWriteReturnsStatus() {
        store.memory?.failWrites = errSecMissingEntitlement
        XCTAssertEqual(store.save(accessKeyID: "id", secret: "s"), errSecMissingEntitlement)
        XCTAssertNil(store.load())
    }

    func testKeychainRoundTripWhenEntitled() throws {
        let real = DiagCredentialStore(service: "com.levi.pocketdj.diag.tests.keychain")
        defer { real.clear() }
        let status = real.save(accessKeyID: " kc-id ", secret: "kc-secret")
        if status == errSecMissingEntitlement {
            throw XCTSkip("test host has no keychain entitlement (unsigned build): OSStatus \(status)")
        }
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(real.load(), .init(accessKeyID: "kc-id", secret: "kc-secret"))
        real.clear()
        XCTAssertNil(real.load())
    }
}
