import Foundation

/// A backend that can attempt to play one of our catalog songs. The
/// `PlaybackCoordinator` (the matching engine) holds a SOURCE-AWARE ordered list
/// of these and asks each, in turn, to `tryPlay` a song until one succeeds — the
/// "cycle providers until one resolves the track" design that lets Apple Music,
/// the rip server, and (later) Spotify / YouTube slot in behind one ▶ button.
///
/// Two responsibilities:
///   • RESOLVE + START (`tryPlay`) — find the song in this backend and begin
///     playback. Return `false` to mean "I couldn't match it — try the next
///     provider" (never throw for a plain miss; reserve errors for real failures
///     you want surfaced). Return `true` once playback has been kicked off.
///   • DRIVE the active session — once a provider wins, the coordinator delegates
///     `togglePlayPause()` / `stop()` to it and reads its `isPlaying` so the one
///     unified inline player reflects whichever backend is live.
///
/// `@MainActor` because every conformer drives observable UI state (and MusicKit /
/// AVFoundation playback must be touched on the main thread).
@MainActor
protocol TrackPlaybackProvider: AnyObject {
    /// Stable identity for the active-provider record + UI branching.
    var backend: PlaybackBackend { get }

    /// Can this provider attempt playback RIGHT NOW? (e.g. Apple Music: the build
    /// opted in AND the user has authorized MusicKit). A provider that is not ready
    /// is skipped by the coordinator's ordering, so the next one gets the song.
    var isReady: Bool { get }

    /// Whether the provider's current track is actively playing (drives the unified
    /// play/pause glyph + the test `player-state` probe when this backend is active).
    var isPlaying: Bool { get }

    /// Attempt to resolve `song` in this backend and start playback. Returns `true`
    /// when playback was started (this provider "wins" and becomes active); `false`
    /// when the song couldn't be matched (the coordinator tries the next provider).
    func tryPlay(_ song: IndexSong) async -> Bool

    /// Pause if playing, resume if paused (the now-playing ▶ toggle).
    func togglePlayPause()

    /// Stop playback and tear down this provider's now-playing session.
    func stop()
}

/// Which backend is driving playback — used to record the winner and to branch the
/// inline player UI (the rip path keeps its waveform + scrubber; Apple Music shows a
/// position-only scrubber with a "via Apple Music" badge). Extend as providers land.
enum PlaybackBackend: String, Hashable {
    case ripServer
    case appleMusic
    // case spotify, youTube  // later

    /// Short "via …" label for the inline player's backend indicator.
    var viaLabel: String {
        switch self {
        case .ripServer:  return "via rip"
        case .appleMusic: return "via Apple Music"
        }
    }
}
