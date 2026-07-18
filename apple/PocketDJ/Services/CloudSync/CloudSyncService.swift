import Foundation
import Observation

/// Cross-device sync of the user's SESSION DATA — document-level, CloudKit private DB.
///
/// The app's per-user state already lives as single-file JSON documents in Application
/// Support (collections, edits, play stats/history, the durable playback + mix-deck
/// sessions, recorded mix-session logs, the profile). This service syncs those FILES
/// whole-document, last-writer-wins, against one `PDJDoc` record each in the user's
/// PRIVATE CloudKit database (`iCloud.com.levi.pocketdj`) — so a beta tester's data
/// follows their Apple ID across devices with zero server cost and zero shared storage.
///
/// Doctrine:
///   • PULL applies only when the cloud copy is strictly newer than the local file
///     (mtime vs the writer's recorded mtime, ±`skewMs` slack). Before overwriting, the
///     local file is backed up to `<name>.pre-cloud` (the user-data-safety rule).
///   • After a pull the owning store's `reload` seam re-decodes from disk — stores read
///     their documents in App.init, so a pull without a reload would only apply next
///     launch. The two restore-later stores (playback-session / mix-decks) have NO
///     reload: their files are pulled BEFORE RootView's restore calls read them
///     (`syncAtLaunch` is awaited first, with a deadline so launch never hangs on CK).
///   • PUSH sends any file whose mtime advanced past the last push — at launch, on
///     foregrounding (throttled), on backgrounding, and from Settings ▸ Profile's
///     "Sync Now".
///   • Whole-document LWW is deliberately simple: the most recently active device wins
///     per document. Media files (burns, studio audio) never sync — documents that
///     reference device-local media are excluded from the registry by design.
///
/// Sync is OFF under PDJ_USE_FIXTURE (tests must never touch a real account) and gated
/// on the Settings toggle + iCloud account availability, both re-checked every pass.
@MainActor
@Observable
final class CloudSyncService {

    /// One registered document: the on-disk file + how to apply a fresh pull.
    struct Entry {
        var key: String
        var fileURL: URL
        /// Re-decode the (just-overwritten) file into the live store. nil ⇒ file-only
        /// (the restore-later stores, whose files are read after `syncAtLaunch`).
        var reload: (() -> Void)?
    }

    /// Clock/mtime slack under which two copies count as "the same write".
    nonisolated static let skewMs: Double = 2_000
    /// Foreground re-syncs are throttled to this gap (launch/manual syncs ignore it).
    nonisolated static let foregroundGapMs: Double = 5 * 60_000

    private(set) var syncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    /// Last observed account availability (drives the Settings ▸ Profile status line).
    private(set) var accountAvailable: Bool?

    @ObservationIgnored private let database: any CloudDocDatabase
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private let stateURL: URL
    /// key → file mtime (epoch ms) at the last successful push/pull (the in-sync watermark).
    @ObservationIgnored private var pushedMtimeMs: [String: Double] = [:]
    @ObservationIgnored private var lastPassAt: Double = 0

    private struct StateFile: Codable {
        var pushedMtimeMs: [String: Double] = [:]
        var lastSyncAtMs: Double?
    }

    init(database: any CloudDocDatabase,
         enabled: @escaping () -> Bool,
         stateURL: URL = CloudSyncService.defaultStateURL()) {
        self.database = database
        self.enabled = enabled
        self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL),
           let st = try? JSONDecoder().decode(StateFile.self, from: data) {
            pushedMtimeMs = st.pushedMtimeMs
            if let ms = st.lastSyncAtMs { lastSyncAt = Date(timeIntervalSince1970: ms / 1000) }
        }
    }

    nonisolated static func defaultStateURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-cloudsync-state.json")
    }

    func register(_ key: String, fileURL: URL, reload: (() -> Void)? = nil) {
        entries.append(Entry(key: key, fileURL: fileURL, reload: reload))
    }

    /// True when a pass may run at all (toggle + fixture guard; account is checked async).
    private var mayRun: Bool {
        guard enabled() else { return false }
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil else { return false }
        return !entries.isEmpty
    }

    /// The launch pass — awaited by RootView's task BEFORE the durable-session restores so
    /// a fresh device restores CLOUD session files, not empty ones. Bounded by `deadline`:
    /// if CloudKit is slow the pass keeps running in the background and this returns, so
    /// launch never hangs on the network (a late pull still lands for next launch).
    func syncAtLaunch(deadline: TimeInterval = 8) async {
        guard mayRun else { return }
        let pass = Task { await self.runPass(manual: false) }
        _ = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await pass.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(deadline)); return false }
            let first = await group.next() ?? false
            group.cancelAll()   // cancels the TIMER; runPass itself checks cancellation between docs
            return first
        }
    }

    /// Foreground re-sync (throttled) — freshness beyond launch without churning every activation.
    func syncOnForeground() {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastPassAt > Self.foregroundGapMs else { return }
        Task { await runPass(manual: false) }
    }

    /// Settings ▸ Profile "Sync Now".
    func syncNow() async { await runPass(manual: true) }

    /// Backgrounding: push-only, fire-and-forget (the OS gives seconds — pulls can wait).
    func pushOnBackground() {
        guard mayRun else { return }
        Task { await pushDirty() }
    }

    // MARK: - The pass

    private func runPass(manual: Bool) async {
        guard mayRun, !syncing else { return }
        syncing = true
        defer { syncing = false }
        lastError = nil
        lastPassAt = Date().timeIntervalSince1970 * 1000

        let available = await database.accountAvailable()
        accountAvailable = available
        guard available else {
            lastSummary = "iCloud account unavailable"
            return
        }
        var pulled: [String] = [], pushed: [String] = []
        do {
            let meta = try await database.fetchMeta(keys: entries.map(\.key))
            for entry in entries {
                if Task.isCancelled && !manual { break }
                let localMs = fileMtimeMs(entry.fileURL)
                let cloudMs = meta[entry.key]
                if let cloudMs, cloudMs > (localMs ?? 0) + Self.skewMs {
                    if let doc = try await database.fetch(entry.key) {
                        try applyPull(doc, to: entry)
                        pulled.append(entry.key)
                    }
                } else if let localMs,
                          localMs > (cloudMs ?? 0) + Self.skewMs,
                          localMs > (pushedMtimeMs[entry.key] ?? 0) + 1 {
                    try await push(entry, mtimeMs: localMs)
                    pushed.append(entry.key)
                }
            }
            lastSyncAt = Date()
            lastSummary = Self.summary(pulled: pulled, pushed: pushed)
            saveState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pushDirty() async {
        guard await database.accountAvailable() else { return }
        var pushed = false
        for entry in entries {
            guard let localMs = fileMtimeMs(entry.fileURL),
                  localMs > (pushedMtimeMs[entry.key] ?? 0) + 1 else { continue }
            if (try? await push(entry, mtimeMs: localMs)) != nil { pushed = true }
        }
        if pushed { saveState() }
    }

    private func applyPull(_ doc: CloudDoc, to entry: Entry) throws {
        // Data safety: the pre-pull local copy survives as <name>.pre-cloud.
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.fileURL.path) {
            let backup = entry.fileURL.appendingPathExtension("pre-cloud")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: entry.fileURL, to: backup)
        }
        try doc.payload.write(to: entry.fileURL, options: .atomic)
        entry.reload?()
        // The fresh file's mtime is "now" (> cloud's modifiedAtMs) — watermark it so the
        // next pass doesn't bounce the identical bytes straight back up.
        pushedMtimeMs[entry.key] = fileMtimeMs(entry.fileURL) ?? doc.modifiedAtMs
    }

    @discardableResult
    private func push(_ entry: Entry, mtimeMs: Double) async throws -> Bool {
        guard let payload = try? Data(contentsOf: entry.fileURL) else { return false }
        try await database.save(CloudDoc(key: entry.key, payload: payload,
                                         modifiedAtMs: mtimeMs, deviceName: Self.deviceName))
        pushedMtimeMs[entry.key] = mtimeMs
        return true
    }

    private func fileMtimeMs(_ url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func saveState() {
        let st = StateFile(pushedMtimeMs: pushedMtimeMs,
                           lastSyncAtMs: lastSyncAt.map { $0.timeIntervalSince1970 * 1000 })
        if let data = try? JSONEncoder().encode(st) { try? data.write(to: stateURL, options: .atomic) }
    }

    private nonisolated static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    private static func summary(pulled: [String], pushed: [String]) -> String {
        if pulled.isEmpty && pushed.isEmpty { return "Everything in sync" }
        var parts: [String] = []
        if !pulled.isEmpty { parts.append("pulled \(pulled.joined(separator: ", "))") }
        if !pushed.isEmpty { parts.append("pushed \(pushed.joined(separator: ", "))") }
        return parts.joined(separator: " · ").capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
