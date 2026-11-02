import Foundation


/// STEM LOCK — "keep my stems across tracks" for a Now Playing playback SESSION.
///
/// Off (the default): stems reset on every track change, exactly as before (`NowPlayingDSP`'s
/// controls are ephemeral). On: the stem state of the track that is playing — stems on/off, which
/// of vocals/drums/bass/other are muted, the per-part gains — CARRIES to every following track.
/// The carry is captured from USER stem actions only (`NowPlayingDSP.onUserStemChange`), so a
/// track that can't do stems (no stems / not a local file / a stem stream that failed) never
/// overwrites it: that track plays the full mix under a small "unavailable" indicator, and the
/// lock stays for the tracks after it.
///
/// A locked track ALWAYS starts on the full mix (zero dead air) and hands over to the carried
/// set through the ordinary `NowPlayingDSP` handover once the ENABLED parts are buffered — a
/// partial burned set may go on air without the muted parts (`NowPlayingDSP.stemPartsRequired`),
/// which join silently when they land (`NowPlayingDSP.stemPartsLanded`).
///
/// SESSION scope: the lock lives on `SetlistPlayer`'s durable session — persisted in the session
/// snapshot (`PlaybackSessionStore.Snapshot.stemLock`), restored with it, CLEARED by a new session
/// (a fresh `SetlistPlayer.play`, which mints a new `sessionId`) and by `stop()` / end of set.
/// Live-queue edits, play-now, skips, repeats and restore keep it.
///
/// The download side — `NowPlayingPrefetcher` (`NowPlayingPrefetch.swift`) — pairs the next track's whole-song audio with
/// its stems: whole song FIRST (it is what plays at the boundary), then its enabled stems in
/// `partPriority` order, then the further-ahead tracks, and the muted parts LAST.
enum StemLock {
    /// Download priority of the stem parts (Levi: vocals, drums, other, bass). Muted parts go to
    /// the very end of the queue (skipped entirely in Low Data Mode).
    static let partPriority = ["vocals", "drums", "other", "bass"]

    /// One `stemlock` line: the remote DiagLog stream (song ids only, never titles) + the Now
    /// Playing trace (os_log `nowplaying`, Settings ▸ Debug capture).
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("stemlock", message)
        NPLog.trace("stemlock \(message)")
    }

    /// What the Now Playing surfaces show for the lock on the CURRENT track.
    enum Indicator: Equatable {
        /// The lock is off.
        case off
        /// Locked, carrying "stems off" (or nothing playing yet): plain full mix.
        case idle
        /// Locked with stems: the full mix plays while the carried stems buffer.
        case loading
        /// Locked with stems, and the carried stems are on air.
        case active
        /// Locked with stems, but THIS track can't do stems — full mix; the lock carries on.
        case unavailable
    }
}

/// The persisted Stem Lock state of a session (the carried stem set rides with it).
struct StemLockState: Codable, Equatable {
    var enabled = false
    /// Stems on for the carried set.
    var stemsOn = false
    /// Muted parts (sorted — stable on disk).
    var muted: [String] = []
    /// Per-part gains moved off 1.0.
    var volumes: [String: Double] = [:]

    /// The un-muted parts, in download priority — what a handover waits for.
    var enabledParts: [String] { StemLock.partPriority.filter { !muted.contains($0) } }
    /// The muted parts, in download priority — fetched last.
    var disabledParts: [String] { StemLock.partPriority.filter { muted.contains($0) } }
    /// Lock on AND carrying stems: the only state that changes playback or downloads.
    var wantsStems: Bool { enabled && stemsOn }
    /// One-line summary for DiagLog (`stems=on parts=vocals,drums muted=bass,other`).
    var logSummary: String {
        guard stemsOn else { return "stems=off" }
        var s = "stems=on parts=\(enabledParts.joined(separator: ","))"
        if !muted.isEmpty { s += " muted=\(muted.joined(separator: ","))" }
        if !volumes.isEmpty {
            s += " gains=" + volumes.keys.sorted().map { "\($0):\(String(format: "%.2f", volumes[$0] ?? 1))" }.joined(separator: ",")
        }
        return s
    }
}

