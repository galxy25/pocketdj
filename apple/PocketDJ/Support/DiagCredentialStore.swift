import Foundation
import Security

/// Keychain home for the diag-writer IAM key (access key ID + secret). Nothing about the key
/// is compiled in or tracked in git: the owner enters it once in Settings ▸ Debug and it
/// rides iCloud Keychain (`kSecAttrSynchronizable`) to the owner's other devices. With no
/// key stored, `DiagLog` is a no-op.
struct DiagCredentialStore {
    struct Credentials: Equatable {
        let accessKeyID: String
        let secret: String
    }

    var service = "com.levi.pocketdj.diag"

    private let idAccount = "accessKeyID"
    private let secretAccount = "secret"

    func load() -> Credentials? {
        guard let id = read(idAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = read(secretAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return Credentials(accessKeyID: id, secret: secret)
    }

    /// Empty (after trimming) values clear the stored key.
    func save(accessKeyID: String, secret: String) {
        let id = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !sec.isEmpty else { clear(); return }
        write(idAccount, id)
        write(secretAccount, sec)
    }

    func clear() {
        delete(idAccount)
        delete(secretAccount)
    }

    // MARK: Keychain (generic password, synchronizable)

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    private func write(_ account: String, _ value: String) {
        delete(account)
        var q = base(account)
        q[kSecAttrSynchronizable as String] = true
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
