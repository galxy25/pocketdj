import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Background-execution RUNWAY for the silent gap between songs. A backgrounded audio app keeps
/// running only while it renders audio: between songs (the previous item stopped, the next
/// one's URL / Apple Music resolve still on the network) a locked phone or CarPlay session can
/// be SUSPENDED mid-resolve — URLSession and every Task.sleep freeze until the next remote
/// command wakes the app, which then cancels that resolve and starts another (field 2026-10-12:
/// "pausing at the end of songs, had to skip forward multiple times"). A UIKit background task
/// held across the resolve keeps the app alive long enough to land the next song. Ended
/// explicitly (idempotent); system expiration self-ends. No-op on macOS.
@MainActor
final class PlaybackRunway {
    /// Runways currently held (test seam + diagnostics).
    private(set) static var activeCount = 0
    private var ended = false
    let name: String
    let began = Date()
    #if canImport(UIKit) && !os(macOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(_ name: String) {
        self.name = name
        Self.activeCount += 1
        DiagLog.shared.log("runway", "begin name=\(name)")
        #if canImport(UIKit) && !os(macOS)
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                NPLog.trace("runway EXPIRED (\(name))")
                self?.end(reason: "EXPIRED")
            }
        }
        #endif
    }

    /// End the runway (idempotent). `reason` rides the `[runway] end` telemetry row.
    func end(reason: String = "done") {
        guard !ended else { return }
        ended = true
        Self.activeCount -= 1
        DiagLog.shared.log("runway", "\(reason == "EXPIRED" ? "EXPIRED" : "end") name=\(name) "
                           + "held=\(String(format: "%.1f", Date().timeIntervalSince(began)))s reason=\(reason)")
        #if canImport(UIKit) && !os(macOS)
        if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
        #endif
    }
}
