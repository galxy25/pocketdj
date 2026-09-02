import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Background-transfer owner (Feature: backgrounded burning + downloading).
///
/// A SINGLE process-wide object that owns the one background `URLSession`
/// (`com.levi.pocketdj.transfers`) and is its `URLSessionDownloadDelegate` /
/// `URLSessionTaskDelegate`. Foreground in-memory `URLSession.shared.data(for:)` dies on
/// suspend; a background `URLSession` download task survives suspension, resumes, and
/// finishes even after a COLD background relaunch — which is the whole point.
///
/// Why a separate object (not folded into RipsStore / BurnStore):
///   • a background session must be created ONCE per identifier per process and must exist
///     at launch time (the delegate has to be alive before the normal store `.task` wiring
///     runs, so a cold background launch can finish in-flight files);
///   • the delegate callbacks arrive on a background queue, so this type is NOT `@MainActor`
///     — it serializes its persisted map behind an `NSLock` and only hops to the main actor
///     to notify `BurnStore` of a finished item;
///   • Burn + single-song download (+ future rip reconcile) all share this one session, so a
///     neutral coordinator avoids RipsStore owning Burn's destination/sidecar concerns.
///
/// IMPORTANT test-safety: this is OPTIONAL on `BurnStore` (`transfers: nil` ⇒ today's
/// in-process serial loop, unchanged). The background path is selected only when a real
/// coordinator is injected (the app), so the existing URLProtocol-stubbed tests are
/// byte-for-byte unchanged.
final class TransferCoordinator: NSObject {
    /// Process-wide instance. Both `PocketDJApp.init` and the App/Scene delegate reference
    /// `.shared`, so the SwiftUI `@State` store and the delegate adaptor talk to the SAME
    /// coordinator (a background session retains its delegate and must be created once —
    /// a second instance with the same identifier would crash / wrong-delegate).
    static let shared = TransferCoordinator()

    /// The background-session identifier (also the key the launch-events handler bridges).
    static let sessionIdentifier = "com.levi.pocketdj.transfers"

    /// iOS BGTask identifiers (must also appear in Info.plist BGTaskSchedulerPermittedIdentifiers).
    static let burnDrainTaskId = "com.levi.pocketdj.burn-drain"
    static let ripReconcileTaskId = "com.levi.pocketdj.rip-reconcile"

    // MARK: Transfer kinds + persisted record

    enum Kind: String, Codable { case burn, download }

    /// One persisted in-flight transfer. The `taskIdentifier` ⇄ `songId` ⇄ destination join
    /// is the ONLY thing that lets the delegate finish a file after a cold background relaunch
    /// (the delegate gets only `downloadTask.taskIdentifier`). The sidecar text is pre-rendered
    /// at enqueue time (on the main actor) so the nonisolated delegate needs no catalog lookup.
    struct TransferRecord: Codable, Equatable {
        var taskIdentifier: Int
        var songId: String
        var kind: Kind
        var audioFileName: String
        var sidecarFileName: String
        var sidecarText: String
        /// True ⇒ files were promised to Application Support `burns/` (no security scope);
        /// false ⇒ the user-picked, security-scoped burn folder.
        var wasAppStorage: Bool
        /// The security-scoped bookmark for the user-picked burn folder, CAPTURED at enqueue
        /// time (on the main actor, where `SettingsStore` is readable) and persisted here as
        /// base64. The background-session delegate runs on a non-main queue with NO inherited
        /// security scope and MUST NOT touch the main actor, so it resolves the destination from
        /// THIS Data (not from a `@MainActor` closure). nil for app-storage burns.
        var burnFolderBookmark: Data?
        var expectedBytes: Int?
        var manifestKey: String
        var source: String
        var bpm: Double?
        var musicalKey: String?
        var camelot: String?
        var durationMs: Int?
        var startMs: Int?
        var rippedAt: Double?
        var title: String
        var artist: String
        var createdAt: Double
    }

    /// The persisted document (`pocketdj-transfers.json`).
    struct TransferDoc: Codable {
        var schemaVersion: Int = 1
        var tasks: [TransferRecord] = []
    }

    // MARK: Finalize hook (set by BurnStore on the main actor)

    /// Called on the MAIN actor when a burn download finishes, so `BurnStore` can upsert the
    /// `.ready` item + save. Set by `BurnStore` when a coordinator is injected.
    var onBurnFinalized: (@MainActor (TransferRecord, Int) -> Void)?
    /// Called on the MAIN actor when a burn download fails terminally (so the row shows error).
    var onBurnFailed: (@MainActor (TransferRecord, String) -> Void)?
    /// Called on the MAIN actor whenever the run-scoped progress changes (enqueue / finish /
    /// cancel / beginRun), so an `@Observable` store (BurnStore) can MIRROR it for the UI. This
    /// coordinator is a plain `NSObject` (it must be the background-session delegate), so a view
    /// bound to `progressSnapshot` here would never re-render as downloads finish — the
    /// "burning number doesn't update" bug. Set by `BurnStore` when a coordinator is injected.
    var onProgress: (@MainActor (_ enqueued: Int, _ finished: Int) -> Void)?
    /// ADDITIVE (collection mix downloader): called on the MAIN actor as a burn download's bytes
    /// land, with the song id + the byte DELTA since the last publish. Throttled to at most one
    /// publish per task per 0.5 s (deltas accumulate between publishes) so the hot delegate path
    /// never floods the main actor — see the progress-mirroring lesson above. nil ⇒ zero overhead
    /// beyond the throttle bookkeeping; nothing else reads these counters.
    var onBytes: (@MainActor (_ songId: String, _ bytesDelta: Int64) -> Void)?

    /// Live progress snapshot, published to the MAIN actor whenever records change (enqueue /
    /// finish / cancel). The UI reads ONLY this — never the `lock`-guarded counters below — so
    /// there's no data-race-by-convention (the delegate mutates under `lock`; the snapshot is
    /// updated via an explicit main hop). `(enqueued, finished)` for the CURRENT burn run.
    @MainActor private(set) var progressSnapshot: (enqueued: Int, finished: Int) = (0, 0)

    /// Run-scoped progress counters (NOT monotonic across burn runs — `beginRun()` resets them
    /// so a second burn doesn't show "Burning 4 of 5"). Mutated under `lock` on the delegate
    /// queue; the UI never reads these directly (it reads `progressSnapshot`).
    private var enqueuedTotal = 0
    private var finishedTotal = 0

    // MARK: Background-session launch-events bridge (iOS)

    /// Stored by `application(_:handleEventsForBackgroundURLSession:completionHandler:)`; called
    /// (exactly once, on the main thread) from `urlSessionDidFinishEvents`.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: Internals

    private let lock = NSLock()
    /// `onBytes` throttle bookkeeping (guarded by `lock`): accumulated not-yet-published byte
    /// deltas + the last publish stamp, keyed by task identifier. Entries are dropped when the
    /// task finishes (`didFinishDownloadingTo`) or is cancelled (`cancelAll`).
    private var bytesPendingByTask: [Int: Int64] = [:]
    private var lastBytesPublishAt: [Int: TimeInterval] = [:]
    private let fileURL: URL
    private var doc = TransferDoc()
    /// Test seam: when true (unit tests), no real background session is created.
    private let usesRealSession: Bool

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Designated init. `realSession: false` is the unit-test seam (no background session is
    /// created; enqueue/persist/reconcile logic is exercised without touching URLSession).
    init(fileURL: URL = TransferCoordinator.defaultURL(), realSession: Bool = true) {
        self.fileURL = fileURL
        self.usesRealSession = realSession
        super.init()
        load()
    }

    private override convenience init() {
        self.init(fileURL: TransferCoordinator.defaultURL(), realSession: true)
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-transfers.json")
    }

    /// Force the session into existence (so the delegate is alive at launch). Called by the
    /// App/Scene delegate's `didFinishLaunching`.
    func activate() {
        guard usesRealSession else { return }
        _ = session
    }

    /// Reset the run-scoped progress counters at the START of a burn run (called by
    /// `BurnStore.burn` on the main actor). Without this the monotonic totals never reset and a
    /// 2nd burn shows e.g. "Burning 4 of 5". Also re-publishes the cleared snapshot.
    func beginRun() {
        lock.lock()
        enqueuedTotal = 0
        finishedTotal = 0
        lock.unlock()
        publishProgress(enqueued: 0, finished: 0)
    }

    /// Publish the current counters to the main-actor `progressSnapshot` (an explicit hop, so the
    /// UI never reads the `lock`-guarded counters off the delegate queue). Caller must NOT hold
    /// `lock` while this runs on the main thread; we read the counters under `lock` here.
    private func publishProgress() {
        lock.lock()
        let e = enqueuedTotal, f = finishedTotal
        lock.unlock()
        publishProgress(enqueued: e, finished: f)
    }

    private func publishProgress(enqueued: Int, finished: Int) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                progressSnapshot = (enqueued, finished)
                onProgress?(enqueued, finished)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.progressSnapshot = (enqueued, finished)
                    self?.onProgress?(enqueued, finished)
                }
            }
        }
    }

    // MARK: Persistence (atomic on every state change)

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(TransferDoc.self, from: data) {
            doc = decoded
        }
    }

    /// Persist under the lock. Caller must hold `lock`.
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Snapshot of the persisted records (for tests + reconcile).
    var records: [TransferRecord] {
        lock.lock(); defer { lock.unlock() }
        return doc.tasks
    }

    // MARK: Enqueue

    /// Persist `record` (BEFORE `resume()`, so a death between persist and resume is
    /// recoverable) then create + resume a background download task for `url`. The task's real
    /// identifier overwrites the record's placeholder. Returns the live task's identifier.
    @discardableResult
    /// A PRESIGNED S3 URL carries its auth in the query string — adding a bearer header on
    /// top makes S3 reject the request outright (400 InvalidArgument, "Only one auth
    /// mechanism allowed"). That 400's small XML body then used to be finalized as the
    /// "downloaded" mp3 (the MobileOne 2026-09-01 bug: rows listed, nothing ever played).
    /// Static + pure so the regression test pins the predicate directly.
    nonisolated static func shouldAttachBearer(to url: URL, token: String) -> Bool {
        !token.isEmpty && url.query?.contains("X-Amz-Signature") != true
    }

    func enqueueDownload(url: URL, token: String, profileId: String = "", record: TransferRecord) -> Int {
        guard usesRealSession else {
            // Test seam: persist the record only (no real task). Identifier kept as given.
            lock.lock()
            upsertLocked(record)
            enqueuedTotal += 1
            persistLocked()
            lock.unlock()
            publishProgress()
            return record.taskIdentifier
        }
        var request = URLRequest(url: url)
        if Self.shouldAttachBearer(to: url, token: token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Per-user identity rides on the burn download (a rip-server fetch) too, for uniformity.
        PDJIdentityHeaders.apply(to: &request, profileId: profileId)
        let task = session.downloadTask(with: request)
        var rec = record
        rec.taskIdentifier = task.taskIdentifier
        lock.lock()
        upsertLocked(rec)
        enqueuedTotal += 1
        persistLocked()
        lock.unlock()
        publishProgress()
        task.resume()
        return task.taskIdentifier
    }

    /// Replace/insert a record keyed by `songId` (one in-flight transfer per song).
    private func upsertLocked(_ record: TransferRecord) {
        doc.tasks.removeAll { $0.songId == record.songId }
        doc.tasks.append(record)
    }

    private func recordForTaskLocked(_ taskIdentifier: Int) -> TransferRecord? {
        doc.tasks.first { $0.taskIdentifier == taskIdentifier }
    }

    private func removeRecordLocked(songId: String) {
        doc.tasks.removeAll { $0.songId == songId }
    }

    // MARK: Cancel (Stop)

    /// Cancel the background tasks for `songIds` (Stop) + drop their persisted records.
    func cancelAll(songIds: [String]) {
        let ids = Set(songIds)
        lock.lock()
        let toCancel = doc.tasks.filter { ids.contains($0.songId) }.map { $0.taskIdentifier }
        doc.tasks.removeAll { ids.contains($0.songId) }
        for t in toCancel { bytesPendingByTask[t] = nil; lastBytesPublishAt[t] = nil }
        // Stop counts the cancelled items as "enqueued but no longer pending" so the overlay
        // (done < total) clears rather than sticking at the old total.
        enqueuedTotal = max(0, enqueuedTotal - toCancel.count)
        persistLocked()
        lock.unlock()
        publishProgress()
        guard usesRealSession else { return }
        let cancelIds = Set(toCancel)
        session.getAllTasks { tasks in
            for t in tasks where cancelIds.contains(t.taskIdentifier) { t.cancel() }
        }
    }

    /// Cancel everything (full Stop / teardown).
    func cancelAll() {
        lock.lock()
        doc.tasks.removeAll()
        enqueuedTotal = 0
        finishedTotal = 0
        bytesPendingByTask = [:]
        lastBytesPublishAt = [:]
        persistLocked()
        lock.unlock()
        publishProgress()
        guard usesRealSession else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: Reconcile on launch

    /// Cross-check persisted records against the session's live tasks. A record whose task is
    /// gone (finished while we were dead but the delegate never ran) is dropped — the file move
    /// already happened in the delegate, or the temp is gone; either way we don't re-run it.
    /// A live task keeps running and the delegate will finish it. Idempotent.
    func reconcileOnLaunch(completion: (() -> Void)? = nil) {
        guard usesRealSession else { completion?(); return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { completion?(); return }
            let live = Set(tasks.map { $0.taskIdentifier })
            self.lock.lock()
            self.doc.tasks.removeAll { !live.contains($0.taskIdentifier) }
            self.persistLocked()
            self.lock.unlock()
            completion?()
        }
    }

    // MARK: Burn-folder resolution (nonisolated; mirrors BurnStore.resolveBurnFolder)

    /// Resolve the destination dir for a record on a background queue. For an app-storage
    /// record this is Application Support `burns/` (no scope). For a user-folder record it
    /// re-resolves the security-scoped bookmark CAPTURED ON THE RECORD at enqueue time + starts
    /// access (caller stops it), falling back to Application Support if the folder is gone —
    /// NEVER dropping the temp file.
    ///
    /// CRITICAL (the BLOCKER fix): this runs on the background `URLSession` delegate queue, so it
    /// must touch NEITHER the main actor NOR any `@MainActor`-isolated state. The bookmark comes
    /// from `record.burnFolderBookmark` (persisted base64), NOT a `@MainActor` closure — so a
    /// cold-relaunched delegate (whose `BurnStore` may not exist yet) resolves the user folder
    /// purely from disk, and there is no `MainActor.assumeIsolated` off the main thread to trap.
    nonisolated private func resolveDestDir(for record: TransferRecord) -> (url: URL, scoped: Bool)? {
        if record.wasAppStorage {
            return (try? RipsStore.burnsDirectory()).map { ($0, false) }
        }
        if let data = record.burnFolderBookmark {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: opts,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let ok = url.startAccessingSecurityScopedResource()
                if ok && FileManager.default.isWritableFile(atPath: url.path) {
                    return (url, true)
                }
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
        // User folder unavailable → fall back to app storage so the file is never dropped.
        return (try? RipsStore.burnsDirectory()).map { ($0, false) }
    }

    /// Test seam: read the lock-guarded run-scoped counters directly (the UI uses
    /// `progressSnapshot`; tests assert the underlying totals without a main hop).
    nonisolated func countersForTesting() -> (enqueued: Int, finished: Int) {
        lock.lock(); defer { lock.unlock() }
        return (enqueuedTotal, finishedTotal)
    }

    /// Test seam (the regression guard): expose `resolveDestDir` so a test can drive the
    /// USER-FOLDER (bookmark) destination resolution from a BACKGROUND queue and prove it never
    /// touches the main actor (no `MainActor.assumeIsolated` trap). nonisolated by design.
    nonisolated func resolveDestDirForTesting(_ record: TransferRecord) -> (url: URL, scoped: Bool)? {
        resolveDestDir(for: record)
    }

    // MARK: Background-completion bridge

    /// Call + clear the stored launch-events completion handler on the MAIN thread (the
    /// UIApplicationDelegate contract). Safe to call when none is set.
    func runBackgroundCompletionHandler() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        guard let handler else { return }
        if Thread.isMainThread { handler() }
        else { DispatchQueue.main.async { handler() } }
    }
}

// MARK: - URLSessionDownloadDelegate / URLSessionTaskDelegate

extension TransferCoordinator: URLSessionDownloadDelegate {
    /// A download finished. Join the task back to its record, move the temp file to the resolved
    /// burn folder, write the pre-rendered sidecar, then hop to the main actor to finalize the
    /// BurnItem. Runs on a background queue with NO inherited security scope, so it re-resolves
    /// the bookmark itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        let record = recordForTaskLocked(downloadTask.taskIdentifier)
        lock.unlock()
        guard let record else {
            // No record — finished while we had no memory of it; nothing safe to do.
            return
        }

        // An HTTP error page must NEVER be finalized as audio: a 4xx/5xx "download" completes
        // transport-wise with a small error body (S3's 400 XML was 536 bytes), and moving that
        // into place poisons the item as .ready-but-unplayable — rows list, decks silently
        // refuse to load. Fail the record honestly instead so the UI shows an error and a
        // retry goes through the (fixed) request path.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failRecord(record, message: "download failed (HTTP \(http.statusCode))")
            return
        }

        // The temp file vanishes when this method returns, so move it synchronously NOW.
        guard let (dir, scoped) = resolveDestDir(for: record) else {
            failRecord(record, message: "no writable burn folder")
            return
        }
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }

        let audioURL = dir.appendingPathComponent(record.audioFileName)
        var bytes = 0
        do {
            // Analog: the shared `<albumId>.mp3` may already exist from a sibling — don't clobber.
            let analogShared = record.source == "analog" && FileManager.default.fileExists(atPath: audioURL.path)
            if analogShared {
                bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? record.expectedBytes ?? 0
            } else {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try FileManager.default.removeItem(at: audioURL)
                }
                try FileManager.default.moveItem(at: location, to: audioURL)
                bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? record.expectedBytes ?? 0
            }
            // Sidecar from the STORED pre-rendered text (no catalog lookup needed here).
            if !record.sidecarFileName.isEmpty {
                try Data(record.sidecarText.utf8).write(
                    to: dir.appendingPathComponent(record.sidecarFileName), options: .atomic)
            }
        } catch {
            failRecord(record, message: error.localizedDescription)
            return
        }

        // Drop the record + bump progress, then finalize the BurnItem on the main actor.
        lock.lock()
        removeRecordLocked(songId: record.songId)
        finishedTotal += 1
        bytesPendingByTask[downloadTask.taskIdentifier] = nil
        lastBytesPublishAt[downloadTask.taskIdentifier] = nil
        persistLocked()
        lock.unlock()
        publishProgress()

        let finalBytes = bytes
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onBurnFinalized?(record, finalBytes) }
        }
    }

    /// Byte-level progress for a running download (iOS background path). Publishes the accumulated
    /// delta to the main-actor `onBytes` hook at most every 0.5 s per task — the delegate can fire
    /// this many times a second, and the main actor must not pay for a publish per chunk.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let taskId = downloadTask.taskIdentifier
        let record = recordForTaskLocked(taskId)
        let pending = (bytesPendingByTask[taskId] ?? 0) + bytesWritten
        let last = lastBytesPublishAt[taskId] ?? 0
        let publish = now - last >= 0.5
        if publish {
            bytesPendingByTask[taskId] = 0
            lastBytesPublishAt[taskId] = now
        } else {
            bytesPendingByTask[taskId] = pending
        }
        lock.unlock()
        guard publish, let record else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onBytes?(record.songId, pending) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success path handled in didFinishDownloadingTo
        // Cancellation (Stop) is intentional — the record was already removed in cancelAll.
        if (error as NSError).code == NSURLErrorCancelled { return }
        lock.lock()
        let record = recordForTaskLocked(task.taskIdentifier)
        lock.unlock()
        guard let record else { return }
        failRecord(record, message: error.localizedDescription)
    }

    /// iOS only: all background events for the session have been delivered — invoke the stored
    /// launch-events completion handler on the main thread.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        runBackgroundCompletionHandler()
    }

    private func failRecord(_ record: TransferRecord, message: String) {
        lock.lock()
        removeRecordLocked(songId: record.songId)
        persistLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onBurnFailed?(record, message) }
        }
    }
}
