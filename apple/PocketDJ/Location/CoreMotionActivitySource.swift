#if os(iOS)
import Foundation
import CoreMotion

/// The iOS motion source: `CMMotionActivityManager` over the motion coprocessor. History reads use
/// `queryActivityStarting(from:to:to:)` (7 days retained, zero continuous cost); live updates run
/// only while a Pocket Wheel run asks for them. iOS-only — every other platform gets
/// `NoopMotionActivityProvider` (see MotionActivityProviding.swift).
@MainActor
final class CoreMotionActivitySource: MotionActivityProviding {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "pocketdj.motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var liveRunning = false

    init() {}

    var isSupported: Bool { CMMotionActivityManager.isActivityAvailable() }

    var authorization: MotionAuthorization {
        guard isSupported else { return .unsupported }
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .authorized
        @unknown default:    return .denied
        }
    }

    func segments(from: Date, to: Date) async -> [MotionSegment] {
        guard isSupported, to > from else { return [] }
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .authorized || status == .notDetermined else { return [] }
        let activities: [CMMotionActivity] = await withCheckedContinuation { cont in
            manager.queryActivityStarting(from: from, to: to, to: queue) { list, _ in
                cont.resume(returning: list ?? [])
            }
        }
        return Self.segments(from: activities, until: to)
    }

    /// CoreMotion reports CHANGE points; a segment runs from one activity's start to the next's.
    nonisolated static func segments(from activities: [CMMotionActivity], until end: Date) -> [MotionSegment] {
        var out: [MotionSegment] = []
        for (i, a) in activities.enumerated() {
            guard let token = token(a) else { continue }
            let stop = i + 1 < activities.count ? activities[i + 1].startDate : end
            guard stop > a.startDate else { continue }
            out.append(MotionSegment(start: a.startDate, end: stop, activity: token,
                                     confidence: a.confidence.rawValue))
        }
        return out
    }

    /// The most ACTIVE flag set wins (a sample can carry several, e.g. automotive + stationary at
    /// a red light). Unknown-only samples say nothing.
    nonisolated static func token(_ a: CMMotionActivity) -> String? {
        if a.running { return MotionToken.running }
        if a.walking { return MotionToken.walking }
        if a.cycling { return MotionToken.cycling }
        if a.automotive { return MotionToken.automotive }
        if a.stationary { return MotionToken.stationary }
        return nil
    }

    func startLiveUpdates(_ handler: @escaping @MainActor (MotionSegment) -> Void) {
        guard isSupported, authorization == .authorized else { return }
        if liveRunning { manager.stopActivityUpdates() }
        liveRunning = true
        manager.startActivityUpdates(to: .main) { a in
            guard let a, let token = CoreMotionActivitySource.token(a) else { return }
            let seg = MotionSegment(start: a.startDate, end: Date(), activity: token,
                                    confidence: a.confidence.rawValue)
            MainActor.assumeIsolated { handler(seg) }
        }
    }

    func stopLiveUpdates() {
        guard liveRunning else { return }
        liveRunning = false
        manager.stopActivityUpdates()
    }
}
#endif
