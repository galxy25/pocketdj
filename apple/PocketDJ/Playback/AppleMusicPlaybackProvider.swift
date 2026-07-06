import Foundation
import Observation

/// The Apple Music STREAMING playback provider — the first backend the matching
/// engine tries for an "Apple Music (Local)" track. It wraps the existing
/// `AppleMusicProvider` (MusicKit account-link + `resolve(_:)` catalog matcher) and
/// adds the `TrackPlaybackProvider` seam the coordinator drives:
///   • `tryPlay` = `resolve(song)`; on a hit, enqueue + play via `ApplicationMusicPlayer`
///     and return true (this provider wins); on a miss return false so the engine falls
///     through to the rip server.
///   • `isPlaying` / position observe `ApplicationMusicPlayer.shared.state` so the unified
///     inline player can show a working play/pause + a position-only scrubber (Apple Music
///     streaming has no waveform).
///
/// MusicKit ships with the SDK, but the ENTITLEMENT that makes playback actually work is
/// runtime-only — so this compiles + links in the default build and simply reports
/// `isReady == false` until the build is signed with the MusicKit entitlement AND the user
/// authorizes. The `#if canImport(MusicKit)` split keeps a toolchain without the framework
/// compiling (the `#else` stub is permanently un-ready).
@MainActor
@Observable
final class AppleMusicPlaybackProvider: TrackPlaybackProvider {
    let backend: PlaybackBackend = .appleMusic

    /// The now-playing handoff for the inline player (title/artist + the namespaced id the
    /// row keys off, so the coordinator knows which row is the Apple Music now-playing one).
    struct NowPlaying: Equatable {
        var songId: String
        var title: String
        var artist: String
    }
    private(set) var nowPlaying: NowPlaying?

    /// Observable playback state for the inline panel's play/pause icon. Set synchronously
    /// in togglePlayPause / tryPlay / stop because `ApplicationMusicPlayer.state.playbackStatus`
    /// is NOT Observation-tracked — a computed property off it never re-renders the icon.
    private(set) var isPlaying: Bool = false

    /// The wrapped account-link + recognizer. Held as the concrete type (not `any
    /// StreamingProvider`) so we can call `resolve(_:)`.
    private let provider: AppleMusicProvider

    init(provider: AppleMusicProvider) {
        self.provider = provider
    }
}

// ============================================================================
// MARK: - Real implementation (MusicKit)
// ============================================================================
#if canImport(MusicKit)
import MusicKit

@available(iOS 16.0, macOS 14.0, *)
extension AppleMusicPlaybackProvider {
    /// Enabled in this build AND the user has authorized MusicKit. (A subscription that
    /// can play catalog content is required for actual audio, but that surfaces as a
    /// failed `play()` rather than blocking the attempt — we still want Apple Music FIRST.)
    var isReady: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    /// Current playback position (seconds) — drives the inline scrubber for this backend.
    var positionSeconds: Double { ApplicationMusicPlayer.shared.playbackTime }

    /// `atMs` (spec §9 cue offset) is applied PLAY-THEN-SEEK: MusicKit exposes no "start
    /// at position" enqueue, so we start playback and then set
    /// `ApplicationMusicPlayer.playbackTime` (via the existing `seek(to:)`). DOCUMENTED
    /// IMPRECISION: the seek lands after playback has audibly started and the streaming
    /// player snaps to its own buffer boundaries, so the cue is accurate to roughly <1 s
    /// (vs. sample-exact for burned/ripped local files) — acceptable per spec §9.
    func tryPlay(_ song: IndexSong, atMs: Int?) async -> Bool {
        guard isReady else { return false }
        // 1) Resolve the song to a catalog track (namespaced `am:<id>` → direct fetch,
        //    else a title/artist search). A miss → false → the engine falls back to rips.
        guard let track = await provider.resolve(song) else { return false }
        // 2) Enqueue the resolved catalog song by its store id + play.
        do {
            let player = ApplicationMusicPlayer.shared
            let id = MusicItemID(track.providerTrackID)
            var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
            req.limit = 1
            let resp = try await req.response()
            guard let catalogSong = resp.items.first else { return false }
            player.queue = [catalogSong]
            try await player.play()
            // 3) Cue: `play()` has returned (playback started), so the position write
            //    sticks — a write before the queue item is ready would be ignored.
            if let atMs, atMs > 0 { seek(to: Double(atMs) / 1000) }
            isPlaying = true
            nowPlaying = NowPlaying(songId: song.id, title: song.name, artist: song.artist)
            return true
        } catch {
            // A real playback failure (e.g. no active subscription) — don't claim the win,
            // let the rip server fall back. The coordinator surfaces no error for this
            // (the fallback will), matching "first attempt is Apple Music; else rip".
            return false
        }
    }

    func togglePlayPause() {
        let player = ApplicationMusicPlayer.shared
        if player.state.playbackStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            isPlaying = true
            Task { try? await player.play() }
        }
    }

    /// Seek the streaming player to an absolute position (seconds).
    func seek(to seconds: Double) {
        ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
    }

    func stop() {
        ApplicationMusicPlayer.shared.stop()
        isPlaying = false
        nowPlaying = nil
    }
}

#else
// ============================================================================
// MARK: - Stub (MusicKit unavailable — keeps the module compiling everywhere)
// ============================================================================
extension AppleMusicPlaybackProvider {
    var isReady: Bool { false }
    var positionSeconds: Double { 0 }
    func tryPlay(_ song: IndexSong, atMs: Int?) async -> Bool { false }
    func togglePlayPause() {}
    func seek(to seconds: Double) {}
    func stop() { nowPlaying = nil }
}
#endif
