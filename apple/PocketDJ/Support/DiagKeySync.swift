import Foundation
import Security

/// The diag-writer key's CREDSYNC lane: one "diag-key" cloud doc (CloudKit private DB, the
/// same `CloudSyncService` LWW machinery as "settings-credentials") so the key is entered ONCE
/// on any device and every other device on the Apple ID adopts it — including the Apple TV,
/// which has no realistic key-typing flow, and devices where iCloud Keychain is off.
///
/// WHY IT EXISTS (2026-10-12 outage): 4ca541e moved the key out of the binary into a
/// Keychain-only store fed by a manual Settings ▸ Debug entry. Nothing delivered it, so every
/// TestFlight build from 2026-10-06 on was a SILENT no-op on every device that never had the
/// key typed in — iOS stopped uploading after the last pre-change build (b1791077967) and the
/// replacement IAM key minted 2026-10-07 was never used by anything.
///
/// Its OWN doc (not a field on SettingsCredentialsDocument) on purpose: an older build
/// re-encodes the credentials doc WITHOUT unknown fields on every pull, which would strip a
/// new field and LWW-ping-pong it against newer builds forever. Older builds simply never
/// register "diag-key".
///
/// EMPTY-NEVER-WINS (the credsync clobber guard, by construction):
///   • `materialize()` writes the file only from a NON-EMPTY Keychain key, and only when the
///     content changed (byte compare on a sorted-keys encoding ⇒ mtime means "key changed").
///     A keyless device never creates the doc, so it can never LWW-race the cloud copy.
///   • `applyPulled()` adopts only a non-empty pulled key. An empty/undecodable pull is
///     ignored — it can never clear a device's key. Removing the key is a per-device act
///     (Settings ▸ Debug); revoking it fleet-wide is an IAM key rotation.
struct DiagKeySync {
    struct Document: Codable, Equatable {
        var schemaVersion: Int = 1
        var accessKeyID: String
        var secret: String
    }

    enum PullResult: Equatable {
        case adopted
        case unchanged
        case ignoredEmpty
        case saveFailed(OSStatus)
    }

    let fileURL: URL
    let store: DiagCredentialStore

    /// The app's instance: the real Application Support file + the launch-default store
    /// (both fixture-isolated under PDJ_USE_FIXTURE so tests never touch the owner's key).
    static let app = DiagKeySync(fileURL: launchURL(), store: .launchDefault())

    static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("pdj-fixture-diag-key.json")
        }
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-diag-key.json")
    }

    private static func encode(_ doc: Document) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(doc)
    }

    /// Mirror the Keychain key into the synced file IFF it is non-empty and its content
    /// changed. Returns true when the file was (re)written — i.e. a push is now pending.
    @discardableResult
    func materialize() -> Bool {
        guard let creds = store.load(),
              let data = Self.encode(Document(accessKeyID: creds.accessKeyID, secret: creds.secret))
        else { return false }
        if (try? Data(contentsOf: fileURL)) == data { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    /// After `CloudSyncService` pulled a newer "diag-key" doc onto `fileURL`: adopt it into
    /// the Keychain unless it is empty (never clears) or already what we hold.
    func applyPulled() -> PullResult {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return .ignoredEmpty }
        let id = doc.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = doc.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return .ignoredEmpty }
        if store.load() == DiagCredentialStore.Credentials(accessKeyID: id, secret: secret) { return .unchanged }
        let status = store.save(accessKeyID: id, secret: secret)
        return status == errSecSuccess ? .adopted : .saveFailed(status)
    }
}
