import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// One synced document as it exists in the cloud: an opaque JSON payload (the same bytes the
/// owning store persists to Application Support) plus the write metadata `CloudSyncService`
/// compares for last-writer-wins.
struct CloudDoc: Sendable, Equatable {
    var key: String
    var payload: Data
    /// Epoch ms of the WRITER's local file when it pushed — the LWW comparison value.
    var modifiedAtMs: Double
    /// The pushing device's name (surfaced in Settings ▸ Profile for "last sync" context).
    var deviceName: String
}

/// The CloudKit seam `CloudSyncService` talks through — a protocol so unit tests drive the
/// full sync engine against an in-memory database (no CloudKit, no account, no network).
/// Keys are the static registry names ("collections", "profile", …) so NO CKQuery is ever
/// needed (queryable-index schema traps avoided): everything is fetch-by-record-ID.
protocol CloudDocDatabase: Sendable {
    /// Whether an iCloud account is signed in + reachable (⇒ sync can run at all).
    func accountAvailable() async -> Bool
    /// Cheap metadata probe: key → modifiedAtMs for each key that EXISTS in the cloud
    /// (absent keys simply missing from the result). Never fetches payload assets.
    func fetchMeta(keys: [String]) async throws -> [String: Double]
    /// Full fetch of one document (nil when it doesn't exist in the cloud).
    func fetch(_ key: String) async throws -> CloudDoc?
    /// Upsert one document (blind overwrite — the caller already did the LWW comparison).
    func save(_ doc: CloudDoc) async throws
}

#if canImport(CloudKit)
/// The real CloudKit implementation: one `PDJDoc` record per document in the PRIVATE
/// database's default zone, recordName `doc-<key>`, payload as a `CKAsset` (documents like
/// collections/history can exceed the ~1 MB in-record data limit). Schema materializes
/// just-in-time in the Development environment on first save; promoting it to Production is
/// the one-time CloudKit Console step documented in docs/design/user-profiles-cloudkit.md.
struct CKCloudDocDatabase: CloudDocDatabase {
    static let containerID = "iCloud.com.levi.pocketdj"
    static let recordType = "PDJDoc"

    private var db: CKDatabase { CKContainer(identifier: Self.containerID).privateCloudDatabase }
    private func recordID(_ key: String) -> CKRecord.ID { CKRecord.ID(recordName: "doc-\(key)") }

    func accountAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: Self.containerID).accountStatus()
        return status == .available
    }

    func fetchMeta(keys: [String]) async throws -> [String: Double] {
        let results = try await db.records(for: keys.map(recordID), desiredKeys: ["modifiedAtMs"])
        var meta: [String: Double] = [:]
        for key in keys {
            guard case .success(let record)? = results[recordID(key)] else { continue }
            if let ms = record["modifiedAtMs"] as? Double { meta[key] = ms }
        }
        return meta
    }

    func fetch(_ key: String) async throws -> CloudDoc? {
        let record: CKRecord
        do {
            record = try await db.record(for: recordID(key))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard let asset = record["payload"] as? CKAsset,
              let fileURL = asset.fileURL,
              let payload = try? Data(contentsOf: fileURL),
              let ms = record["modifiedAtMs"] as? Double else { return nil }
        return CloudDoc(key: key, payload: payload, modifiedAtMs: ms,
                        deviceName: record["deviceName"] as? String ?? "")
    }

    func save(_ doc: CloudDoc) async throws {
        // CKAsset needs an on-disk file; stage the payload in tmp for the upload's lifetime.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cloudsync-\(doc.key)-\(UUID().uuidString).json")
        try doc.payload.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }
        let record = CKRecord(recordType: Self.recordType, recordID: recordID(doc.key))
        record["payload"] = CKAsset(fileURL: staging)
        record["modifiedAtMs"] = doc.modifiedAtMs
        record["deviceName"] = doc.deviceName
        // .allKeys = blind overwrite: the caller compared timestamps; a concurrent writer
        // losing this race is exactly the LWW semantic the sync doc promises.
        _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}
#endif
