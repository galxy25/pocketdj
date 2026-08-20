import Foundation
import os

/// Turns the debug capture's "skipped heartbeats" into ATTRIBUTED main-thread stalls: while a
/// Settings ▸ Debug session is capturing, a 100 ms utility-queue timer keeps a trivial beat
/// bouncing off the main queue and measures how stale the last landed beat is. Beats only land
/// when the main run loop is servicing its queue, so a gap IS a main-thread stall — not a
/// heuristic — and every report names the last `marker(_:)` the app planted ("STALL 1240ms
/// after shuffle-tapped (+310ms)") so the exported pocketdj-debug file says what the main
/// thread was doing when it hit.
///
/// Started/stopped by `MixDiag.start()/stop()` (the same lifecycle every other capture-only
/// diagnostic rides), so it costs nothing outside a capture. Markers are safe to plant
/// unconditionally from any thread — a marker outside a capture is one os_log line.
final class MainThreadStallWatchdog: @unchecked Sendable {
    static let shared = MainThreadStallWatchdog()

    /// A beat gap must exceed this before it's a stall. Frame jitter and scheduler noise sit
    /// far below it; the user-visible hangs this exists for are 1000 ms+.
    private let threshold: TimeInterval = 0.3
    private let interval: DispatchTimeInterval = .milliseconds(100)

    private let lock = NSLock()   // guards every var below
    private var lastBeat: TimeInterval = 0
    private var beatInFlight = false
    private var stallStart: TimeInterval?
    private var markerName = "capture-start"
    private var markerAt: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    private static let log = Logger(subsystem: "com.pocketdj", category: "stall")

    /// Monotonic, unaffected by wall-clock changes mid-capture.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Stamp "the main thread is now doing X" — collection open/resolve, shuffle tap,
    /// back-nav, schema reindex, snapshot builds. The stamped name rides the next STALL
    /// report; while capturing it is also echoed into the session so the timeline reads
    /// marker → STALL inline.
    func marker(_ name: String) {
        let t = Self.now()
        lock.lock()
        markerName = name
        markerAt = t
        let capturing = timer != nil
        lock.unlock()
        Self.log.info("marker \(name, privacy: .public)")
        if capturing {
            Task { @MainActor in MixDiag.shared.append("watchdog marker \(name)") }
        }
    }

    /// Begin watching (from `MixDiag.start()`). Idempotent.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        lastBeat = Self.now()
        beatInFlight = false
        stallStart = nil
        markerName = "capture-start"
        markerAt = lastBeat
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Stop watching (from `MixDiag.stop()`). Idempotent.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        stallStart = nil
        lock.unlock()
    }

    private func tick() {
        let t = Self.now()
        var enqueueBeat = false
        lock.lock()
        // At most ONE beat in flight: piling main.async blocks onto a stalled queue would
        // make the watchdog itself part of the recovery cost.
        if !beatInFlight { beatInFlight = true; enqueueBeat = true }
        if stallStart == nil, lastBeat > 0, t - lastBeat > threshold {
            stallStart = lastBeat
        }
        lock.unlock()
        if enqueueBeat {
            DispatchQueue.main.async { [weak self] in self?.beatLanded() }
        }
    }

    /// Runs ON the main queue — the beat. If a stall was open, this landing closes and
    /// reports it (already on main, so the MixDiag append is a direct call).
    private func beatLanded() {
        let t = Self.now()
        lock.lock()
        let started = stallStart
        let (name, at) = (markerName, markerAt)
        let capturing = timer != nil
        lastBeat = t
        beatInFlight = false
        stallStart = nil
        lock.unlock()
        guard let started, capturing else { return }
        let ms = Int((t - started) * 1000)
        guard ms >= Int(threshold * 1000) else { return }
        let sinceMarker = max(0, Int((started - at) * 1000))
        let line = "STALL \(ms)ms after \(name) (+\(sinceMarker)ms)"
        Self.log.error("\(line, privacy: .public)")
        MainActor.assumeIsolated { MixDiag.shared.append("watchdog \(line)") }
    }
}
