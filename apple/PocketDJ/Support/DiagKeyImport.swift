import Foundation
import Security
import UniformTypeIdentifiers

extension UTType {
    /// `.pdjdiagkey` — the diag-writer key file `scripts/green/export-diag-key.sh` writes.
    /// Mirrors the `com.pocketdj.diagkey` UTExportedTypeDeclaration in project.yml.
    static let pocketDJDiagKey = UTType(exportedAs: "com.pocketdj.diagkey", conformingTo: .json)
}

/// The on-disk key file (schema v1). Written by `scripts/green/export-diag-key.sh` from Secrets
/// Manager so the owner never types the key: import it once (Mac: Settings ▸ Debug ▸ "Import
/// upload key from file…", drag & drop onto that row, or double-click the file) and the
/// "diag-key" credsync doc (`DiagKeySync`) carries it to every device on the Apple ID.
///
///     {"type":"pocketdj-diag-key","schemaVersion":1,"env":"green","account":"623170744161",
///      "accessKeyID":"AKIA…","secret":"…","exportedAt":"…"}
struct DiagKeyFile: Codable, Equatable {
    static let typeTag = "pocketdj-diag-key"
    static let fileExtension = "pdjdiagkey"

    var type: String
    var schemaVersion: Int
    var env: String
    /// The AWS account that owns the key — must own the active logs bucket (`diagLogsBase`).
    var account: String
    var accessKeyID: String
    var secret: String
    var exportedAt: String?

    enum Invalid: Error, Equatable, CustomStringConvertible {
        case notJSON
        case wrongType
        case unsupportedVersion(Int)
        case missing(String)
        case badAccessKeyID
        case badAccount

        var description: String {
            switch self {
            case .notJSON: return "not a PocketDJ diag key file (unreadable JSON)"
            case .wrongType: return "not a PocketDJ diag key file"
            case .unsupportedVersion(let v): return "unsupported key file version \(v)"
            case .missing(let f): return "key file is missing \(f)"
            case .badAccessKeyID: return "key file's access key ID is malformed"
            case .badAccount: return "key file's account is not a 12-digit AWS account id"
            }
        }
    }

    /// Decode + validate. Values are trimmed; nothing secret ever appears in an error.
    static func decode(_ data: Data) -> Result<DiagKeyFile, Invalid> {
        guard let raw = try? JSONDecoder().decode(Loose.self, from: data) else { return .failure(.notJSON) }
        guard raw.type == typeTag else { return .failure(.wrongType) }
        guard let v = raw.schemaVersion else { return .failure(.missing("schemaVersion")) }
        guard v == 1 else { return .failure(.unsupportedVersion(v)) }
        func nonEmpty(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let env = nonEmpty(raw.env) else { return .failure(.missing("env")) }
        guard let account = nonEmpty(raw.account) else { return .failure(.missing("account")) }
        guard let id = nonEmpty(raw.accessKeyID) else { return .failure(.missing("accessKeyID")) }
        guard let secret = nonEmpty(raw.secret) else { return .failure(.missing("secret")) }
        guard id.range(of: #"^(AKIA|ASIA)[A-Z0-9]{16}$"#, options: .regularExpression) != nil
        else { return .failure(.badAccessKeyID) }
        guard account.range(of: #"^[0-9]{12}$"#, options: .regularExpression) != nil
        else { return .failure(.badAccount) }
        return .success(DiagKeyFile(type: typeTag, schemaVersion: v, env: env, account: account,
                                    accessKeyID: id, secret: secret, exportedAt: raw.exportedAt))
    }

    /// Every field optional so a missing one is reported by NAME rather than as "not JSON".
    private struct Loose: Decodable {
        var type: String?
        var schemaVersion: Int?
        var env: String?
        var account: String?
        var accessKeyID: String?
        var secret: String?
        var exportedAt: String?
    }

    /// The AWS account baked into a logs-bucket URL (`pocketdj-logs-<account>.s3.…`), or nil
    /// when the host doesn't follow that naming (then no pairing check is possible).
    static func bucketAccount(of logsBase: URL) -> String? {
        guard let host = logsBase.host?.lowercased(),
              let r = host.range(of: #"^pocketdj-logs-[0-9]{12}\."#, options: .regularExpression)
        else { return nil }
        return String(host[r].dropFirst("pocketdj-logs-".count).dropLast())
    }
}

/// Import a `.pdjdiagkey` file: validate → pair-check against the active logs bucket →
/// DiagCredentialStore → DiagKeySync (materialize + push) → DiagLog reload. Pure-ish so unit
/// tests drive it with an in-memory store, a temp file, and a fixed logs URL.
@MainActor
struct DiagKeyImporter {
    /// The key's account doesn't own the active env's logs bucket: every upload would 403.
    struct Mismatch: Equatable {
        let keyEnv: String
        let keyAccount: String
        let activeEnv: String
        let bucketAccount: String

        var warning: String {
            "This key is for \(keyEnv) (account \(keyAccount)), but the app is uploading to the \(activeEnv) logs bucket (account \(bucketAccount)). Uploads would fail with 403 until the endpoint config flips to \(keyEnv)."
        }
    }

    enum Outcome: Equatable {
        /// Saved. `mismatch` is non-nil only when the caller forced past one.
        case imported(env: String, account: String, mismatch: Mismatch?)
        /// Not saved: the caller must confirm (`force: true`) to import anyway.
        case needsConfirmation(Mismatch)
        case invalid(String)
        case saveFailed(OSStatus)
    }

    var sync: DiagKeySync
    /// The live logs bucket (`Config.diagLogsBase`) and the active env name.
    var logsBase: () -> URL
    var activeEnv: () -> String
    /// Push the freshly materialized "diag-key" doc to iCloud (CloudSyncService.pushDirty).
    var push: () async -> Void
    var log: (String) -> Void
    var reloadCredentials: () -> Void

    static func app(push: @escaping () async -> Void) -> DiagKeyImporter {
        DiagKeyImporter(sync: .app,
                        logsBase: { Config.diagLogsBase },
                        activeEnv: { Config.endpoints.config.env },
                        push: push,
                        log: { DiagLog.shared.log("diag", $0) },
                        reloadCredentials: { DiagLog.shared.reloadCredentials() })
    }

    /// Read a (possibly security-scoped) file URL.
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    func importFile(at url: URL, force: Bool = false) async -> Outcome {
        let data: Data
        do { data = try Self.read(url) } catch {
            log("key import failed: unreadable file (\(type(of: error)))")
            return .invalid("couldn't read the file")
        }
        return await importData(data, force: force)
    }

    func importData(_ data: Data, force: Bool = false) async -> Outcome {
        let file: DiagKeyFile
        switch DiagKeyFile.decode(data) {
        case .success(let f): file = f
        case .failure(let why):
            log("key import rejected: \(why)")
            return .invalid(why.description)
        }
        let env = activeEnv()
        var mismatch: Mismatch?
        if let bucket = DiagKeyFile.bucketAccount(of: logsBase()), bucket != file.account {
            mismatch = Mismatch(keyEnv: file.env, keyAccount: file.account, activeEnv: env, bucketAccount: bucket)
        }
        if let mismatch, !force {
            log("key import held: env=\(file.env) account=\(file.account) ≠ active env=\(env) bucket account=\(mismatch.bucketAccount)")
            return .needsConfirmation(mismatch)
        }
        let status = sync.store.save(accessKeyID: file.accessKeyID, secret: file.secret)
        guard status == errSecSuccess else {
            log("key import failed: keychain=\(status) env=\(file.env)")
            return .saveFailed(status)
        }
        reloadCredentials()
        let pending = sync.materialize()
        log("key imported env=\(file.env) account=\(file.account) activeEnv=\(env) paired=\(mismatch == nil) synced=\(pending ? "pending-push" : "unchanged")")
        await push()
        return .imported(env: file.env, account: file.account, mismatch: mismatch)
    }

    /// Delete the imported file (it holds the secret in clear). Returns an error text on failure.
    static func deleteFile(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.removeItem(at: url); return nil } catch {
            return "Couldn't delete \(url.lastPathComponent) — delete it yourself (it holds the key in clear)."
        }
    }
}
