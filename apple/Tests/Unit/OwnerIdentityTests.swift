import XCTest
import CryptoKit
@testable import PocketDJ

/// The owner gate's pure core — "is this install Levi's?", the switch that decides whether
/// ♥ sync two-way with Apple Music or stay app-local.
///
/// Every branch here must FAIL CLOSED. The asymmetry is the whole point: a missed owner
/// check costs Levi one relaunch, a false positive writes into a stranger's music library.
final class OwnerIdentityTests: XCTestCase {

    func testHashIsStableSaltedAndDistinctPerAccount() {
        let a = OwnerIdentity.hash("_9a3f1c2b4d5e6f708192a3b4c5d6e7f8")
        XCTAssertEqual(a, OwnerIdentity.hash("_9a3f1c2b4d5e6f708192a3b4c5d6e7f8"),
                       "the same iCloud record name must hash identically every launch — the shipped constant depends on it")
        XCTAssertEqual(a.count, 64)                                  // SHA-256, lowercase hex
        XCTAssertEqual(a, a.lowercased())
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))

        // A different Apple ID must land somewhere else entirely, even one character apart.
        XCTAssertNotEqual(a, OwnerIdentity.hash("_9a3f1c2b4d5e6f708192a3b4c5d6e7f9"))
        XCTAssertNotEqual(OwnerIdentity.hash(""), a)

        // SALTED: the shipped allowlist entry must not be a plain digest of the record id,
        // or inspecting the binary would hand out a usable iCloud record name.
        let unsalted = SHA256.hash(data: Data("_9a3f1c2b4d5e6f708192a3b4c5d6e7f8".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(a, unsalted, "the domain-separation salt must actually be mixed in")
    }

    func testIsOwnerRequiresAnExactMatchAndFailsClosed() {
        let mine = OwnerIdentity.hash("_owner-record")
        let theirs = OwnerIdentity.hash("_tester-record")

        XCTAssertTrue(OwnerIdentity.isOwner(hash: mine, allowlist: [mine, theirs]))
        XCTAssertTrue(OwnerIdentity.isOwner(hash: mine, allowlist: [mine]))

        // Each failure mode independently means "not the owner".
        XCTAssertFalse(OwnerIdentity.isOwner(hash: nil, allowlist: [mine, theirs]),
                       "no iCloud account / CloudKit error ⇒ local-only")
        XCTAssertFalse(OwnerIdentity.isOwner(hash: mine, allowlist: []),
                       "an empty allowlist means NOBODY is the owner — the shipped default")
        XCTAssertFalse(OwnerIdentity.isOwner(hash: nil, allowlist: []))
        XCTAssertFalse(OwnerIdentity.isOwner(hash: theirs, allowlist: [mine]),
                       "another Apple ID is never the owner")

        // Membership is exact — no prefix, suffix, or case-insensitive near-miss counts.
        XCTAssertFalse(OwnerIdentity.isOwner(hash: String(mine.dropLast()), allowlist: [mine]))
        XCTAssertFalse(OwnerIdentity.isOwner(hash: mine + "0", allowlist: [mine]))
        XCTAssertFalse(OwnerIdentity.isOwner(hash: mine.uppercased(), allowlist: [mine]))
    }

    /// The bootstrap invariant: whatever `Config.ownerICloudHashes` currently holds, an
    /// arbitrary install is not the owner. Ships EMPTY, so today that is everyone.
    func testArbitraryInstallIsNotOwnerUnderTheShippedAllowlist() {
        XCTAssertFalse(OwnerIdentity.isOwner(hash: OwnerIdentity.hash("_some-other-tester"),
                                             allowlist: Config.ownerICloudHashes))
    }
}
