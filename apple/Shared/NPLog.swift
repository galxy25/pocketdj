import Foundation
import os

/// The NOW PLAYING trace — a dedicated debug pipe for the cross-surface playback path:
/// system-card writes (MPNowPlayingInfoCenter), arbiter ownership, transport routing, the
/// widget snapshot/cover pipeline, and the widget process's timeline reads.
///
/// Every line goes to os_log UNCONDITIONALLY (subsystem `com.levi.pocketdj`, category
/// `nowplaying`) — and because this file is compiled into BOTH the app and the widget
/// extension, ONE capture shows both processes interleaved:
///
///   log stream --info --debug --predicate 'subsystem == "com.levi.pocketdj" AND category == "nowplaying"'
///
/// or after the fact:
///
///   log show --last 10m --info --debug --predicate 'subsystem == "com.levi.pocketdj" AND category == "nowplaying"' > np-trace.txt
///
/// App-side lines are ALSO mirrored into the Settings ▸ Debug capture buffer (`MixDiag`)
/// when a session is on — wired via `mirror` at app init; nil in the widget process.
enum NPLog {
    private static let log = Logger(subsystem: "com.levi.pocketdj", category: "nowplaying")
    /// App-side hook into the Settings ▸ Debug capture buffer; nil in the widget process.
    @MainActor static var mirror: ((String) -> Void)?
    /// Which process a line came from — the widget sets this to "widget" at first use so an
    /// interleaved capture reads unambiguously. Defaults to "app".
    nonisolated(unsafe) static var processTag = "app"

    static func trace(_ message: @autoclosure () -> String) {
        let line = "[\(processTag)] \(message())"
        log.info("\(line, privacy: .public)")
        Task { @MainActor in mirror?("np \(line)") }
    }
}
