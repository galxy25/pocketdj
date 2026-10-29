import Foundation
import Observation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// RUNNING / WALKING — the Pocket Wheel's body-activity signal (docs/design/pocket-wheel.md §1.4).
//
// The motion coprocessor already records activity, and CoreMotion's history query returns the
// last 7 days — so history needs NO live updates: a settle pass (foreground) asks "what was I
// doing during this play?" after the fact and stamps a raw token, write-once, on the play.
// Live updates run only while a Pocket Wheel run plays with "Adapt to activity" on (Phase 5b).
//
// PLATFORM FENCE: this file is cross-platform. The CoreMotion adapter lives in
// CoreMotionActivitySource.swift behind `#if os(iOS)`; every other platform gets the Noop
// provider and the store reports `isSupported == false`.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Motion permission, CoreMotion-free so it compiles everywhere.
enum MotionAuthorization: String, Codable, Sendable {
    case notDetermined, denied, restricted, authorized
    /// No motion coprocessor on this platform.
    case unsupported
}

/// One activity stretch: `activity` is a `MotionToken`; `confidence` is CoreMotion's
/// 0 = low, 1 = medium, 2 = high.
struct MotionSegment: Equatable, Sendable {
    var start: Date
    var end: Date
    var activity: String
    var confidence: Int
}

/// Where activity comes from. iOS: `CoreMotionActivitySource`. Tests inject a fake with scripted
/// segments (which is also how denied/restricted are exercised without a prompt).
@MainActor
protocol MotionActivityProviding: AnyObject {
    var isSupported: Bool { get }
    var authorization: MotionAuthorization { get }
    /// Activity segments overlapping [from, to]. Empty when unsupported / not authorized. On iOS
    /// the FIRST call triggers the system permission prompt.
    func segments(from: Date, to: Date) async -> [MotionSegment]
    /// Push updates while a run plays (Phase 5b). Each call replaces the previous handler.
    func startLiveUpdates(_ handler: @escaping @MainActor (MotionSegment) -> Void)
    func stopLiveUpdates()
}

/// macOS / tvOS / visionOS / tests: nothing, ever.
@MainActor
final class NoopMotionActivityProvider: MotionActivityProviding {
    init() {}
    var isSupported: Bool { false }
    var authorization: MotionAuthorization { .unsupported }
    func segments(from: Date, to: Date) async -> [MotionSegment] { [] }
    func startLiveUpdates(_ handler: @escaping @MainActor (MotionSegment) -> Void) {}
    func stopLiveUpdates() {}
}

/// The pure settle rule (§1.4) — testable without CoreMotion.
enum MotionSettle {
    /// A play younger than this may still be in progress / its segments not yet written.
    static let minAgeMs: Double = 2 * 60_000
    /// CoreMotion keeps 7 days; stop asking a little before the edge.
    static let horizonMs: Double = 6.5 * 86_400_000
    /// Duration used when the catalog knows no length.
    static let fallbackDurationMs: Double = 180_000
    /// Segments below this confidence say nothing (CMMotionActivityConfidence.medium = 1).
    static let minConfidence = 1

    struct Play: Equatable, Sendable {
        var id: UUID
        var playedAtMs: Double
        /// Audible duration estimate (ms).
        var durationMs: Double
    }

    /// The audible window of a play: catalog length × played fraction when known, else the
    /// whole length, else 3 min. Never under 30 s (a play shorter than that is mostly noise).
    static func duration(lengthMs: Int?, listenedFraction: Double?) -> Double {
        guard let len = lengthMs, len > 0 else { return fallbackDurationMs }
        let f = min(1, max(0, listenedFraction ?? 1))
        return max(30_000, Double(len) * (f > 0 ? f : 1))
    }

    /// Is this play's window eligible to settle NOW (old enough, young enough)?
    static func isEligible(playedAtMs: Double, durationMs: Double, nowMs: Double) -> Bool {
        let age = nowMs - playedAtMs
        return age >= minAgeMs && age <= horizonMs && playedAtMs + durationMs <= nowMs + 1
    }

    /// The winning activity for each eligible play: the activity with the most overlap seconds
    /// among segments with confidence ≥ medium; ties go to the more active state. A play with no
    /// qualifying overlap gets no entry (it is retried until the horizon, then stays nil forever).
    static func settle(plays: [Play], segments: [MotionSegment], nowMs: Double) -> [UUID: String] {
        let usable = segments.filter { $0.confidence >= minConfidence && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return [:] }
        var out: [UUID: String] = [:]
        for p in plays where isEligible(playedAtMs: p.playedAtMs, durationMs: p.durationMs, nowMs: nowMs) {
            let lo = p.playedAtMs / 1000, hi = (p.playedAtMs + p.durationMs) / 1000
            var overlap: [String: Double] = [:]
            for s in usable {
                let a = max(lo, s.start.timeIntervalSince1970), b = min(hi, s.end.timeIntervalSince1970)
                if b > a { overlap[s.activity, default: 0] += b - a }
            }
            guard let best = overlap.max(by: { x, y in
                x.value != y.value ? x.value < y.value
                    : MotionToken.activityRank(x.key) > MotionToken.activityRank(y.key)
            }) else { continue }
            out[p.id] = best.key
        }
        return out
    }

    /// "What am I doing now" from the last few minutes of segments: the latest qualifying
    /// segment's activity, or nil.
    static func current(from segments: [MotionSegment]) -> String? {
        segments.filter { $0.confidence >= minConfidence }.max { $0.end < $1.end }?.activity
    }
}

/// The app-scoped motion opt-in + settle pass. OPT-IN, default OFF (same posture as places &
/// trips). Its own tiny document (`pocketdj-listening-motion.json`, device-local, never synced):
/// the opt-in is per device, because the coprocessor and the permission are.
@MainActor
@Observable
final class ListeningMotionStore {
    #if os(iOS)
    nonisolated static let platformSupportsMotion = true
    #else
    nonisolated static let platformSupportsMotion = false
    #endif

    private(set) var isEnabled = false
    /// Bumped after every settle pass that stamped something (UI/debug only).
    private(set) var lastSettledCount = 0
    let isSupported: Bool
    var authorization: MotionAuthorization { provider.authorization }
    /// Enabled AND permitted — lookups can return something.
    var isActive: Bool { isSupported && isEnabled && authorization == .authorized }

    @ObservationIgnored private let provider: MotionActivityProviding
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var settleInFlight = false

    struct Document: Codable { var isEnabled: Bool }

    init(fileURL: URL = ListeningMotionStore.defaultURL(), provider: MotionActivityProviding? = nil,
         platformSupported: Bool = ListeningMotionStore.platformSupportsMotion) {
        self.fileURL = fileURL
        self.provider = provider ?? ListeningMotionStore.platformProvider()
        self.isSupported = platformSupported && self.provider.isSupported
        if let data = try? Data(contentsOf: fileURL), let doc = try? JSONDecoder().decode(Document.self, from: data) {
            isEnabled = doc.isEnabled && isSupported
        }
    }

    static func platformProvider() -> MotionActivityProviding {
        #if os(iOS)
        return CoreMotionActivitySource()
        #else
        return NoopMotionActivityProvider()
        #endif
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-listening-motion.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-listening-motion.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Turn the opt-in on/off. ON asks for permission (iOS prompts on the first query) and runs
    /// a settle pass; OFF stops any live updates. Tokens already stamped stay on their plays.
    func setEnabled(_ on: Bool) async {
        guard isSupported else { return }
        isEnabled = on
        persist()
        if on {
            // The permission prompt fires on the first query.
            _ = await provider.segments(from: now().addingTimeInterval(-60), to: now())
        } else {
            provider.stopLiveUpdates()
        }
    }

    /// One settle pass over this install's unsettled plays (foreground cadence). `lengthOf` maps a
    /// song id to its catalog length. Returns how many plays were stamped.
    @discardableResult
    func settle(history: PlayHistoryStore, lengthOf: (String) -> Int?) async -> Int {
        guard isActive, !settleInFlight else { return 0 }
        settleInFlight = true
        defer { settleInFlight = false }
        let nowMs = now().timeIntervalSince1970 * 1000
        var plays: [MotionSettle.Play] = []
        for e in history.events.reversed() {
            if nowMs - e.playedAt > MotionSettle.horizonMs { break }
            guard e.motion == nil, !history.isFromAnotherDevice(e) else { continue }
            let d = MotionSettle.duration(lengthMs: lengthOf(SongVariant.baseId(e.songId)),
                                          listenedFraction: e.listenedFraction)
            guard MotionSettle.isEligible(playedAtMs: e.playedAt, durationMs: d, nowMs: nowMs) else { continue }
            plays.append(.init(id: e.id, playedAtMs: e.playedAt, durationMs: d))
        }
        guard let earliest = plays.map(\.playedAtMs).min() else { return 0 }
        let segs = await provider.segments(from: Date(timeIntervalSince1970: earliest / 1000), to: now())
        let tokens = MotionSettle.settle(plays: plays, segments: segs, nowMs: nowMs)
        history.stampMotion(tokens)
        lastSettledCount = tokens.count
        if !tokens.isEmpty {
            DiagLog.shared.log("pocketwheel", "motion settle stamped=\(tokens.count) of=\(plays.count)")
        }
        return tokens.count
    }

    /// The activity over the last `window` (default 5 min) — the centre ▶'s `mode_now` input.
    func currentActivity(window: TimeInterval = 5 * 60) async -> String? {
        guard isActive else { return nil }
        let segs = await provider.segments(from: now().addingTimeInterval(-window), to: now())
        return MotionSettle.current(from: segs)
    }

    /// Live updates while a Pocket Wheel run plays (Phase 5b). No-op unless active.
    func startLiveUpdates(_ handler: @escaping @MainActor (MotionSegment) -> Void) {
        guard isActive else { return }
        provider.startLiveUpdates(handler)
    }
    func stopLiveUpdates() { provider.stopLiveUpdates() }

    /// Account deletion / erase: opt-out (stamped plays are part of history and go with it).
    func clearLocal() {
        provider.stopLiveUpdates()
        isEnabled = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Document(isEnabled: isEnabled)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
