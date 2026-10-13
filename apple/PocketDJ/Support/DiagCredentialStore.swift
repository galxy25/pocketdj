import Foundation
import Security

/// Keychain home for the diag-writer IAM key (access key ID + secret). Nothing about the key
/// is compiled in or tracked in git: the owner enters it once in Settings ▸ Debug, it rides
/// iCloud Keychain (`kSecAttrSynchronizable`) where that is available, AND the "diag-key"
/// cloud doc (`DiagKeySync`, CloudKit private DB — the credsync channel) to every other
/// device on the Apple ID, Apple TV included. With no key stored, `DiagLog` buffers but
/// cannot upload, and says so (Settings ▸ Debug readout + os_log + a `[diag]` line).
///
/// STATUS, NOT SILENCE (2026-10-12): the old store ignored every OSStatus, so a refused Save
/// looked exactly like a successful one. Writes now return the final status (Settings ▸ Debug
/// shows it), fall back to a device-local item if a synchronizable add is refused, and use
/// the data-protection keychain on macOS so "synchronizable" means what it means on iOS.
/// (An UNSIGNED simulator test host refuses every Keychain write with
/// errSecMissingEntitlement — probed: synchronizable and local alike — which is why the old
/// round-trip test failed there; a signed build has the entitlement. Tests use `memory`.)
struct DiagCredentialStore {
    struct Credentials: Equatable, Codable {
        let accessKeyID: String
        let secret: String
    }

    var service = "com.levi.pocketdj.diag"
    /// Test seam: when set, items live in this in-memory box instead of the Keychain (an
    /// unsigned simulator test host has NO keychain entitlement — every SecItemAdd returns
    /// errSecMissingEntitlement, synchronizable or not — so Keychain-backed logic can't be
    /// exercised there). nil in the app.
    var memory: MemoryBox?

    final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        /// Force every write to fail with this status (simulates a Keychain refusal).
        var failWrites: OSStatus?
        init() {}
        func get(_ k: String) -> String? { lock.withLock { items[k] } }
        func set(_ k: String, _ v: String?) { lock.withLock { items[k] = v } }
    }

    private let idAccount = "accessKeyID"
    private let secretAccount = "secret"

    /// The store the app uses. Under PDJ_USE_FIXTURE (the unit/UI-test schemes) a separate
    /// service so a test run can never read, overwrite, or clear the owner's real key.
    static func launchDefault() -> DiagCredentialStore {
        ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil
            ? DiagCredentialStore(service: "com.levi.pocketdj.diag.fixture")
            : DiagCredentialStore()
    }

    func load() -> Credentials? {
        guard let id = read(idAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = read(secretAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return Credentials(accessKeyID: id, secret: secret)
    }

    /// Empty (after trimming) values clear the stored key. Returns the Keychain status of
    /// the write (`errSecSuccess` when both halves landed) so callers can surface a failure.
    @discardableResult
    func save(accessKeyID: String, secret: String) -> OSStatus {
        let id = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !sec.isEmpty else { clear(); return errSecSuccess }
        let s1 = write(idAccount, id)
        guard s1 == errSecSuccess else { return s1 }
        return write(secretAccount, sec)
    }

    func clear() {
        delete(idAccount)
        delete(secretAccount)
    }

    // MARK: Keychain (generic password; synchronizable when entitled, device-local otherwise)

    /// The item "flavours" tried in order. Data-protection keychain on macOS so the
    /// synchronizable attribute means the same thing it does on iOS (the legacy file
    /// keychain has no iCloud sync); the legacy keychain stays as a last resort there.
    private enum Flavor: CaseIterable { case synced, local, legacyMac }

    private func base(_ account: String, _ flavor: Flavor) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        switch flavor {
        case .synced, .local:
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true
            #endif
        case .legacyMac:
            break
        }
        return q
    }

    private var flavors: [Flavor] {
        #if os(macOS)
        return Flavor.allCases
        #else
        return [.synced, .local]
        #endif
    }

    private func write(_ account: String, _ value: String) -> OSStatus {
        if let memory {
            if let fail = memory.failWrites { return fail }
            memory.set(service + "/" + account, value)
            return errSecSuccess
        }
        delete(account)
        var last: OSStatus = errSecParam
        for flavor in flavors {
            var q = base(account, flavor)
            q[kSecAttrSynchronizable as String] = (flavor == .synced) ? true : nil
            q[kSecValueData as String] = Data(value.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            last = SecItemAdd(q as CFDictionary, nil)
            if last == errSecSuccess { return last }
        }
        return last
    }

    private func read(_ account: String) -> String? {
        if let memory { return memory.get(service + "/" + account) }
        for flavor in flavors where flavor != .local {   // `.synced`'s query (SynchronizableAny) covers `.local`
            var q = base(account, flavor)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    private func delete(_ account: String) {
        if let memory { memory.set(service + "/" + account, nil); return }
        for flavor in flavors where flavor != .local {
            SecItemDelete(base(account, flavor) as CFDictionary)
        }
    }
}
