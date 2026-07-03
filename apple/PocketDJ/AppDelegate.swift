import Foundation
#if os(iOS)
import UIKit
import BackgroundTasks
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
/// iOS app delegate — the home for the two things SwiftUI can't express:
///   • `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, which the
///     system calls (relaunching the app if needed) when a background download finishes — we
///     stash the completion handler on the shared `TransferCoordinator`, which calls it once
///     from `urlSessionDidFinishEvents`;
///   • BGTaskScheduler registration/handling for the burn-drain + rip-reconcile tasks.
///
/// The delegate reaches the SAME coordinator the SwiftUI `@State` stores use via
/// `TransferCoordinator.shared` (the adaptor is instantiated by SwiftUI, so we can't thread an
/// instance in — the process-wide singleton keeps ownership consistent).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Force the background session into existence so its delegate is alive at launch —
        // a cold background relaunch can then finish in-flight files before the normal store
        // wiring runs.
        TransferCoordinator.shared.activate()
        registerBackgroundTasks()
        return true
    }

    /// The system relaunches the app (if needed) and calls this when a background URLSession
    /// finishes its events. Stash the handler; the coordinator invokes it from
    /// `urlSessionDidFinishEvents` (on the main thread, exactly once).
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == TransferCoordinator.sessionIdentifier else { completionHandler(); return }
        TransferCoordinator.shared.activate()
        TransferCoordinator.shared.backgroundCompletionHandler = completionHandler
    }

    // MARK: BGTaskScheduler

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TransferCoordinator.burnDrainTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Self.handleBurnDrain(task)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TransferCoordinator.ripReconcileTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Self.handleRipReconcile(task)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: StorageManager.bgTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Self.handleStoragePrune(task)
        }
    }

    /// BGProcessingTask: re-arm itself, reconcile any stuck transfers (the background session
    /// keeps running tasks alive; this just repairs orphaned records), then complete.
    private static func handleBurnDrain(_ task: BGProcessingTask) {
        scheduleBurnDrain()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        // `reconcileOnLaunch` finishes asynchronously (it calls `session.getAllTasks`), so
        // complete the BGTask from INSIDE that async callback (mirroring handleRipReconcile) —
        // not synchronously right after firing it, which would mark the task done before the
        // reconcile actually ran.
        TransferCoordinator.shared.reconcileOnLaunch {
            task.setTaskCompleted(success: true)
        }
    }

    /// BGAppRefreshTask: re-arm itself, refresh the public rips manifest so a collection RIP's
    /// progress reconciles, then complete. The rip itself is server-side; we only catch up the
    /// client view.
    private static func handleRipReconcile(_ task: BGAppRefreshTask) {
        scheduleRipReconcile()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task {
            await RipReconcileBridge.shared.refresh?()
            task.setTaskCompleted(success: true)
        }
    }

    /// BGProcessingTask: re-arm itself, run the storage manager's once-a-day soft-cap
    /// prune (a no-op when the cap is unset or the last run is <20 h old — the gate lives
    /// in `StorageManager.pruneIfDue`), then complete.
    private static func handleStoragePrune(_ task: BGProcessingTask) {
        scheduleStoragePrune()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task {
            await StoragePruneBridge.shared.prune?()
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: Submit / re-arm (called from the .background scenePhase hook + each handler)

    static func scheduleBackgroundTasks() {
        scheduleBurnDrain()
        scheduleRipReconcile()
        scheduleStoragePrune()
    }

    private static func scheduleBurnDrain() {
        let request = BGProcessingTaskRequest(identifier: TransferCoordinator.burnDrainTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleRipReconcile() {
        let request = BGAppRefreshTaskRequest(identifier: TransferCoordinator.ripReconcileTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Disk-only work (no network / power constraints). Asks for a ~6 h deferral; the
    /// once-a-day arbiter is `pruneIfDue`'s own gate, so an early or repeated fire is safe.
    private static func scheduleStoragePrune() {
        let request = BGProcessingTaskRequest(identifier: StorageManager.bgTaskId)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// A tiny main-actor bridge so the storage-prune BGTask (which has no store references)
/// can run the daily soft-cap prune. The app sets `prune` at launch to
/// `{ storage.pruneIfDue() }`. Mirrors `RipReconcileBridge`.
@MainActor
final class StoragePruneBridge {
    static let shared = StoragePruneBridge()
    var prune: (() async -> Void)?
}

/// A tiny main-actor bridge so the BGAppRefreshTask (which has no store references) can refresh
/// the rips manifest. The app sets `refresh` at launch to `{ await rips.refreshManifest() }`.
@MainActor
final class RipReconcileBridge {
    static let shared = RipReconcileBridge()
    var refresh: (() async -> Void)?
}
#elseif os(macOS)
/// macOS scene delegate — macOS does NOT suspend the way iOS does and BGTaskScheduler is
/// unavailable, so this only forces the background session into existence (its completion is
/// delivered through the session delegate directly, with no `handleEventsForBackgroundURLSession`
/// handler dance).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TransferCoordinator.shared.activate()
    }
}
#endif
