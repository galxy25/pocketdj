import Foundation
import Observation

/// The user's PocketDJ PROFILE — a stable per-user identity for the beta-distribution era:
/// a random durable `id` (minted once, never regenerated), the display name (the same
/// "PocketDJ name" stamped on performance items + the jukebox DJ line), and `createdAtMs`.
///
/// Persists to Application Support `pocketdj-profile.json` (the PlayStatsStore durable-JSON
/// pattern: atomic save, decode-on-init, PDJ_USE_FIXTURE test seam) and syncs across the
/// user's devices through `CloudSyncService` (CloudKit private DB), so a beta tester's
/// identity + session data follow their Apple ID, not one device.
///
/// NAME OWNERSHIP: `SettingsStore.pocketDJName` remains the wired-everywhere read path
/// (collections.performerName, JukeboxView). The profile is the SYNCED source of truth;
/// `onNameApplied` (wired in PocketDJApp.init) mirrors profile → settings + collections on
/// every local edit AND every cloud pull, so existing consumers never change.
@MainActor
@Observable
final class ProfileStore {

    /// The persisted, versioned document.
    struct Document: Codable {
        var schemaVersion: Int = profileSchemaVersion
        var id: String
        var name: String
        var createdAtMs: Double
    }

    private(set) var id: String
    var name: String
    private(set) var createdAtMs: Double
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }
    /// Mirrors a (local or cloud-pulled) name into settings + collections — see NAME OWNERSHIP.
    @ObservationIgnored var onNameApplied: ((String) -> Void)?

    init(fileURL: URL = ProfileStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            id = doc.id
            name = doc.name
            createdAtMs = doc.createdAtMs
        } else {
            id = UUID().uuidString
            name = ""
            createdAtMs = Date().timeIntervalSince1970 * 1000
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-profile.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches
    /// the user's real profile). Mirrors PlayStatsStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-profile.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// One-time migration: a device that set a PocketDJ name BEFORE profiles existed adopts
    /// it as the profile name (and the profile file materializes on disk so it can sync).
    /// No-op once the profile has a name of its own.
    func migrateIfNeeded(settingsName: String) {
        let trimmed = settingsName.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty, !trimmed.isEmpty else { return }
        name = trimmed
        save()
    }

    /// Apply a local edit (the Settings ▸ Profile field): persist + mirror to consumers.
    func setName(_ newName: String) {
        name = newName
        save()
        onNameApplied?(name)
    }

    /// Re-decode the on-disk document after CloudSyncService downloaded a newer cloud copy,
    /// then mirror the (possibly changed) name into settings/collections. The profile `id`
    /// follows the cloud doc — one identity per Apple ID, not per device.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        id = doc.id
        name = doc.name
        createdAtMs = doc.createdAtMs
        onNameApplied?(name)
    }

    /// Account deletion: erase this device's persisted profile and mint a BRAND-NEW identity
    /// (fresh random `id`, empty name, new `createdAtMs`) so a re-created account starts clean.
    /// Swallows a missing file like the rest of the store, resets @Observable state so the UI
    /// updates immediately, then persists the fresh document (and mirrors the empty name out).
    func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        id = UUID().uuidString
        name = ""
        createdAtMs = Date().timeIntervalSince1970 * 1000
        save()
        onNameApplied?(name)
    }

    private func save() {
        let doc = Document(id: id, name: name, createdAtMs: createdAtMs)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let profileSchemaVersion = 1
