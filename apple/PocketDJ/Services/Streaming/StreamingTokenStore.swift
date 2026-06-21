import Foundation
import Security

/// Tiny Keychain-backed store for a provider's OAuth tokens + account label.
/// OAuth refresh/access tokens are secrets and must NOT live in UserDefaults or a
/// backup zip — only here, in the Keychain, scoped by `service`. The non-secret
/// account label is mirrored to UserDefaults so the UI can show "Signed in as …"
/// without a Keychain read.
struct StreamingTokenStore {
    let service: String   // e.g. "com.levi.pocketdj.youtube"

    private var refreshKey: String { "\(service).refresh" }
    private var accessKey: String  { "\(service).access" }
    private var labelKey: String   { "\(service).label" }

    var refreshToken: String? { read(refreshKey) }
    var accessToken: String?  { read(accessKey) }
    var accountLabel: String? { UserDefaults.standard.string(forKey: labelKey) }

    func save(refresh: String?, access: String?, label: String?) {
        if let refresh { write(refreshKey, refresh) }
        if let access  { write(accessKey, access) }
        if let label   { UserDefaults.standard.set(label, forKey: labelKey) }
    }

    func clear() {
        delete(refreshKey); delete(accessKey)
        UserDefaults.standard.removeObject(forKey: labelKey)
    }

    // MARK: Keychain (generic password, one item per key)

    private func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    private func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
