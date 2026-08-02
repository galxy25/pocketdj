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
/// Sync is gated on the injected `enabled` closure (in the app: the Settings toggle AND
/// no PDJ_USE_FIXTURE — tests must never touch a real account) + iCloud account
/// availability, re-checked every pass.
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
    /// ONBOARDING PUSH GATE (R1): while the zero-to-hero flow is unresolved, NO push may
    /// run — a store file materialized mid-onboarding (an empty mix-session flush, an
    /// intent-written collections doc) must never LWW-overwrite a returning user's cloud
    /// data. nil ⇒ always allowed (tests / pre-onboarding builds). Wired in PocketDJApp
    /// to `{ onboarding.isComplete }`; pulls are deliberately NOT gated.
    @ObservationIgnored var pushAllowed: (() -> Bool)?
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

    /// True when a pass may run at all (account availability is checked async per pass).
    /// The PDJ_USE_FIXTURE guard lives in the APP's `enabled` closure (PocketDJApp.init),
    /// not here — the unit-test scheme sets that env var globally, and the sync engine
    /// itself must stay drivable by tests (against the in-memory database).
    private var mayRun: Bool { enabled() && !entries.isEmpty }

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

    // MARK: - Onboarding (zero-to-hero stage 1)

    /// What the stage-1 "Link with iCloud" probe found in the cloud.
    enum ProfileProbe: Equatable {
        /// Sync is disabled (fixture run / toggle off) — the probe never touches CloudKit.
        case disabled
        /// No iCloud account signed in / reachable.
        case noAccount
        /// Account is up but the probe errored or timed out — NOT the same as `.fresh`:
        /// treating a slow network as "no profile" would let a typed name LWW-clobber the
        /// real cloud identity. UX: continue with sync enabled, no name entry, no
        /// start-fresh — a later successful pass reconciles.
        case unknown
        /// Account is up and no profile doc exists — a genuinely new iCloud user.
        case fresh
        /// A profile doc exists; `name` decoded from it ("" when unnamed).
        case existing(name: String)
    }

    /// Probe the cloud for an existing profile, bounded by `deadline` (a probe must never
    /// hang the first-run flow; timeout ⇒ `.unknown`, never `.fresh`).
    func probeCloudProfile(deadline: TimeInterval = 10) async -> ProfileProbe {
        guard enabled() else { return .disabled }
        let db = database
        let work = Task { () -> ProfileProbe in
            guard await db.accountAvailable() else { return .noAccount }
            do {
                guard let doc = try await db.fetch("profile") else { return .fresh }
                let decoded = try? JSONDecoder().decode(ProfileStore.Document.self, from: doc.payload)
                return .existing(name: decoded?.name ?? "")
            } catch {
                return .unknown
            }
        }
        let result = await withTaskGroup(of: ProfileProbe?.self) { group -> ProfileProbe in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: .seconds(deadline)); return nil }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            work.cancel()
            return first ?? .unknown
        }
        switch result {
        case .noAccount:          accountAvailable = false
        case .fresh, .existing:   accountAvailable = true
        case .disabled, .unknown: break   // nothing learned about the account
        }
        return result
    }

    /// Stage-1 "Restore my stuff": pull-FORCED, no deadline. Applies EVERY cloud doc
    /// regardless of local mtimes — the launch-pass LWW comparison would skip a doc
    /// whose local file was just materialized (an intent-written collections file, a
    /// backgrounding flush), which on a fresh install is always junk relative to the
    /// cloud copy the user explicitly asked to restore. `.pre-cloud` backups still
    /// taken (the user-data-safety rule). Pushes: none (this is a restore, and the
    /// onboarding push gate is closed anyway). Returns the pulled doc keys; nil ⇒ the
    /// pass couldn't run (disabled / no account) — the UI returns to the choice rather
    /// than advancing (an incomplete restore must never look complete).
    func restoreForOnboarding() async -> [String]? {
        guard mayRun, !syncing else { return nil }
        syncing = true
        defer { syncing = false }
        lastError = nil
        lastPassAt = Date().timeIntervalSince1970 * 1000
        let available = await database.accountAvailable()
        accountAvailable = available
        guard available else {
            lastSummary = "iCloud account unavailable"
            return nil
        }
        var pulled: [String] = []
        do {
            let meta = try await database.fetchMeta(keys: entries.map(\.key))
            for entry in entries where meta[entry.key] != nil {
                if let doc = try await database.fetch(entry.key) {
                    try applyPull(doc, to: entry)
                    pulled.append(entry.key)
                }
            }
            lastSyncAt = Date()
            lastSummary = pulled.isEmpty ? "Nothing to restore"
                                         : "Restored \(pulled.joined(separator: ", "))"
            saveState()
            return pulled
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

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
                          localMs > (pushedMtimeMs[entry.key] ?? 0) + 1,
                          pushAllowed?() ?? true {
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

    /// The backgrounding push. This used to upload BLIND — any file newer than this device's own
    /// last-push watermark went up, with no idea what was already in the cloud. That is how a
    /// device could publish a stale document over a strictly newer one from another device: the
    /// watermark only says "what I last sent", never "what someone else has since sent".
    ///
    /// One `fetchMeta` probe fixes it. It fetches modification times only — no asset payloads —
    /// so this stays a cheap, single round trip on the way to the background.
    /// Internal (not private) so tests can await the push directly — `pushOnBackground` is
    /// deliberately fire-and-forget and gives them nothing to synchronize on.
    func pushDirty() async {
        guard pushAllowed?() ?? true else { return }
        guard await database.accountAvailable() else { return }
        let candidates = entries.filter { entry in
            guard let localMs = fileMtimeMs(entry.fileURL) else { return false }
            return localMs > (pushedMtimeMs[entry.key] ?? 0) + 1
        }
        guard !candidates.isEmpty else { return }

        // A probe FAILURE — offline on the way to the background is the common case — falls back to
        // the old blind push. Losing a set the user just played offline is worse than the narrow
        // risk of overwriting: the local file is only a candidate here because it advanced past
        // this device's own last push, i.e. the user really did something on this device.
        var cloud: [String: Double] = [:]
        do { cloud = try await database.fetchMeta(keys: candidates.map(\.key)) }
        catch { cloud = [:] }

        var pushed = false
        for entry in candidates {
            guard let localMs = fileMtimeMs(entry.fileURL) else { continue }
            // Absent from the probe ⇒ never uploaded ⇒ push. Only a strictly newer cloud copy skips.
            if let cloudMs = cloud[entry.key], cloudMs > localMs + Self.skewMs { continue }
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
        // Watermark the mtime of the bytes we JUST PULLED, and do it BEFORE `reload()`.
        //
        // The watermark's job is "don't bounce the identical bytes straight back up". Reading the
        // mtime AFTER reload broke that for any store whose reload MERGES rather than replaces:
        // `CollectionActivityStore.reloadFromDisk` unions the peer's events with this device's and
        // SAVES the superset, so the post-reload mtime belongs to a file that is strictly newer
        // than what the cloud has. Watermarking that value told the next pass "already pushed",
        // and the merged superset was never published — each device kept its own union privately
        // and the peers never learned the other's rows. Capturing it here means a merge-on-reload
        // legitimately leaves the file dirty, so it rides the next push exactly as it should.
        let pulledMtime = fileMtimeMs(entry.fileURL) ?? doc.modifiedAtMs
        entry.reload?()
        if let afterReload = fileMtimeMs(entry.fileURL), afterReload != pulledMtime {
            // The reload MERGED and re-saved: this file is now a superset of what the cloud holds,
            // and it must go back up. Clear the watermark outright rather than recording the
            // pre-reload mtime — the push gate is `localMs > watermark + 1`, and a merge-save lands
            // well under a millisecond after the pull for a small log (measured: ~0.35 ms at 10
            // events), so an mtime-based watermark would silently fail to clear that epsilon and
            // the superset would never publish. A cleared watermark doesn't depend on timing at all.
            pushedMtimeMs[entry.key] = nil
        } else {
            // Nothing changed on reload — watermark the bytes we just pulled so the next pass
            // doesn't bounce them straight back up.
            pushedMtimeMs[entry.key] = pulledMtime
        }
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

    /// Full local reset (Settings ▸ Storage "Erase everything" / re-onboarding): drop the
    /// in-sync watermark and delete the persisted state file, then sweep every
    /// `<name>.pre-cloud` backup that `applyPull` left in Application Support. Without this a
    /// document the user just erased would be resurrected — either re-pushed off a stale
    /// watermark or restored from its `.pre-cloud` copy. The synced docs themselves are NOT
    /// removed here (the orchestrator clears those via each store); CloudKit is untouched.
    /// File-not-found is swallowed, matching `applyPull` / `saveState`.
    func clearLocalSyncState() {
        let fm = FileManager.default
        pushedMtimeMs = [:]
        try? fm.removeItem(at: stateURL)
        for entry in entries {
            let backup = entry.fileURL.appendingPathExtension("pre-cloud")
            try? fm.removeItem(at: backup)
        }
        lastSyncAt = nil
        lastSummary = nil
        lastError = nil
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
