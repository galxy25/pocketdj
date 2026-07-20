import Foundation
import CryptoKit
import CloudKit

/// The OWNER GATE — "is this install Levi's?" — which decides whether favorites sync
/// two-way with Apple Music or stay purely app-local.
///
/// WHY IT IS NOT AN APPLE MUSIC CHECK. The literal requirement ("only sync if the Apple
/// Music profile matches") is not implementable on any Apple API, verified against the
/// iOS 26.5 SDK and the full Apple Music API symbol index:
///   • MusicKit's `MusicSubscription` carries three capability booleans and no identity;
///     there is no account id, handle, or storefront type in the Swift interface at all.
///   • The Apple Music Web API has no `/v1/me/account`; `/v1/me/storefront` returns a
///     country code shared by millions of users.
///   • The raw Music User Token (`MusicUserTokenProvider`) is a ROTATING, revocable
///     bearer credential — it changes under the same account, so hashing it yields an
///     unstable id, not an identity.
///
/// So we gate on the ICLOUD account instead, via `CKContainer.userRecordID()` — an opaque
/// string that is stable per Apple ID per container and distinct for every other user.
/// This is the right substitute for a second reason: favorites already sync through the
/// PRIVATE CloudKit database, so a non-owner is STRUCTURALLY incapable of reading or
/// writing Levi's favorites regardless of this check. The gate's real job is narrower —
/// keep a tester's ♥ from being written into the tester's own Apple Music account, and
/// route testers to the shipped seed instead.
///
/// FAIL CLOSED. No iCloud account, iCloud Drive off, offline, an empty allowlist, or any
/// thrown error ⇒ **not the owner** ⇒ local-only. The dangerous direction is a stranger
/// being mistaken for the owner, never the reverse: a missed owner check costs Levi one
/// relaunch, a false positive writes into someone else's music library.
///
/// BOOTSTRAP. The hash cannot be known before the app runs, so `Config.ownerICloudHashes`
/// ships EMPTY (⇒ nobody is the owner ⇒ everyone is local-only, the safe default).
/// Settings ▸ Debug ▸ "Owner identity" shows this device's hash with a Copy button; paste
/// it into `Config.ownerICloudHashes` and ship. Capture BOTH values — the record id is
/// container-scoped, so the CloudKit Development and Production environments produce
/// DIFFERENT hashes and a TestFlight build would silently fail the gate with only one.
enum OwnerIdentity {

    /// Domain-separation salt. Keeps the shipped constant from being a usable iCloud
    /// record id if the binary is inspected, and keeps this hash unrelated to any other
    /// hash of the same input elsewhere in the app.
    private static let salt = "pocketdj-owner-v1"

    /// The pure, testable core: iCloud user-record name → the constant we compare against.
    nonisolated static func hash(_ recordName: String) -> String {
        let digest = SHA256.hash(data: Data((recordName + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// This install's owner hash, or nil when it cannot be determined (no account, no
    /// network, CloudKit error). Cached after the first success — the record id does not
    /// change while the app runs, and the Settings row should not re-hit CloudKit.
    private static var cached: String?

    /// True when it is SAFE to construct a `CKContainer` for our container id.
    ///
    /// `CKContainer(identifier:)` does not throw when the container is missing from the app's
    /// entitlements — it **traps**, taking the process with it, and no `do/catch` can save
    /// you. An unsigned simulator/dev build (`CODE_SIGNING_ALLOWED=NO` strips entitlements)
    /// is exactly that case, so a launch-time owner check crashed the app on sight. Note this
    /// only became reachable once `Config.ownerICloudHashes` gained an entry: with an empty
    /// allowlist `isOwner()` short-circuits before ever asking for a hash, which is why the
    /// crash appeared the moment the gate was armed rather than when it was written.
    ///
    /// The rest of the app avoids this by never touching CloudKit under a fixture run
    /// (`CloudSyncService`'s `enabled` closure is `!fixtureRun && …`, and `CKCloudDocDatabase`
    /// builds its container lazily inside those gated calls). This mirrors that doctrine.
    private static var cloudKitIsSafeToTouch: Bool {
        ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil
    }

    static func currentHash() async -> String? {
        if let cached { return cached }
        guard cloudKitIsSafeToTouch else { return nil }    // fail closed, and do not trap
        do {
            let id = try await CKContainer(identifier: CKCloudDocDatabase.containerID).userRecordID()
            cached = id.recordName.isEmpty ? nil : hash(id.recordName)
            return cached
        } catch {
            return nil                                     // fail closed — see doctrine above
        }
    }

    /// True only when this install's hash is in the shipped allowlist. Every failure mode
    /// — unknown hash, empty allowlist, CloudKit unavailable — returns false.
    static func isOwner() async -> Bool {
        guard !Config.ownerICloudHashes.isEmpty, let h = await currentHash() else { return false }
        return Config.ownerICloudHashes.contains(h)
    }

    /// Pure membership test, so the gate's logic is unit-testable without CloudKit.
    nonisolated static func isOwner(hash: String?, allowlist: Set<String>) -> Bool {
        guard let hash, !allowlist.isEmpty else { return false }
        return allowlist.contains(hash)
    }
}
