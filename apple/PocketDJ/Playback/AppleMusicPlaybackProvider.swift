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
        /// The MusicKit catalog track's artwork URL. Our "Apple Music (Local)" catalog carries
        /// NO cover art (`IndexAlbum.artCandidates` is empty), so this — captured from the
        /// resolved catalog `Song` — is the only cover source for a streamed track. The system
        /// lock-screen/CarPlay card shows art because MusicKit auto-fills it; the app's OWN
        /// surfaces (home deck + widget) need this URL to match.
        var artworkURL: URL?
    }
    private(set) var nowPlaying: NowPlaying?

    /// Observable playback state for the inline panel's play/pause icon. Set synchronously
    /// in togglePlayPause / tryPlay / stop because `ApplicationMusicPlayer.state.playbackStatus`
    /// is NOT Observation-tracked — a computed property off it never re-renders the icon.
    private(set) var isPlaying: Bool = false

    /// The resolved catalog track's length (seconds), captured at play time. Drives the
    /// lock-screen / CarPlay Now Playing card's duration (the streaming player exposes no
    /// duration the sequencer can read) and the end-monitor's completion backstop. 0 ⇒ unknown.
    private(set) var durationSeconds: Double = 0

    /// Fired when the CURRENT streaming track reaches its natural end, so the setlist
    /// sequencer can advance. MusicKit's `ApplicationMusicPlayer` is a SEPARATE player the
    /// sequencer doesn't observe, so WITHOUT this the set freezes after one Apple Music song
    /// (the "plays one song then stops" bug). Owned by `SetlistPlayer` across its play()/stop()
    /// lifecycle (mirroring `PlayerEngine.onTrackEnded`); nil ⇒ no consumer.
    var onTrackEnded: (() -> Void)?

    /// The polling task that watches `ApplicationMusicPlayer` for end-of-track. Cancelled on
    /// stop / superseded on each new `tryPlay`.
    @ObservationIgnored private var endMonitor: Task<Void, Never>?

    /// Wall-clock position smoothing. MusicKit's `playbackTime` is laggy/stale DURING playback
    /// (it advances mainly on state changes), which froze the CarPlay/lock-screen progress bar
    /// and the in-app deck — each ~1 Hz card update re-wrote elapsed with the same stale value,
    /// defeating the OS's own extrapolation. We extrapolate `base + wall-elapsed` so the position
    /// ticks smoothly, snapping forward whenever the real `playbackTime` jumps ahead of us.
    @ObservationIgnored private var positionBase: Double = 0
    @ObservationIgnored private var positionStartWall: Date?

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

    /// Current playback position (seconds) — drives the CarPlay/lock-screen card, the home deck,
    /// and the inline scrubber. Wall-clock-smoothed (see `positionBase`): while playing it's
    /// `base + wall-elapsed`, re-anchored on every start/resume/seek. This deliberately does NOT
    /// read the laggy `playbackTime` on each tick (that reset the OS's own extrapolation to a
    /// stale value → the frozen CarPlay bar); playback advances 1:1 with the wall clock, so the
    /// only divergence is a rare mid-song network stall, self-corrected on the next resume.
    var positionSeconds: Double {
        guard let start = positionStartWall else { return positionBase }
        return positionBase + Date().timeIntervalSince(start)
    }

    /// (Re)start the smooth clock from `seconds` — playback just started/resumed/seeked.
    private func startPositionClock(from seconds: Double) {
        positionBase = max(0, seconds)
        positionStartWall = Date()
    }
    /// Freeze the smooth clock at the current position — playback paused/stopped.
    private func freezePositionClock() {
        positionBase = positionSeconds
        positionStartWall = nil
    }

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
            startPositionClock(from: atMs.map { Double($0) / 1000 } ?? 0)
            durationSeconds = catalogSong.duration ?? 0
            // Capture the catalog artwork URL — the app's own now-playing surfaces (home deck +
            // widget) can't get a cover from our art-less AM-Local catalog, so this is it.
            let artURL = catalogSong.artwork?.url(width: 600, height: 600)
            nowPlaying = NowPlaying(songId: song.id, title: song.name, artist: song.artist,
                                    artworkURL: artURL)
            // 4) Arm the end-of-track monitor so the setlist advances when this streaming song
            //    finishes (nothing else observes MusicKit's player).
            startEndMonitor()
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
            freezePositionClock()
        } else {
            isPlaying = true
            startPositionClock(from: positionSeconds)
            Task { try? await player.play() }
        }
    }

    /// Explicit resume/pause — used by the lock-screen / CarPlay remote play/pause commands,
    /// which must land in a KNOWN state (not toggle blindly off a possibly-stale status).
    func resume() {
        isPlaying = true
        startPositionClock(from: positionSeconds)
        Task { try? await ApplicationMusicPlayer.shared.play() }
    }
    func pausePlayback() {
        ApplicationMusicPlayer.shared.pause()
        isPlaying = false
        freezePositionClock()
    }

    /// Seek the streaming player to an absolute position (seconds).
    func seek(to seconds: Double) {
        ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
        if positionStartWall != nil { startPositionClock(from: seconds) }   // playing → re-anchor
        else { positionBase = max(0, seconds) }                             // paused → hold
    }

    func stop() {
        endMonitor?.cancel(); endMonitor = nil
        ApplicationMusicPlayer.shared.stop()
        isPlaying = false
        positionBase = 0; positionStartWall = nil
        nowPlaying = nil
    }

    /// Poll `ApplicationMusicPlayer` for end-of-track and fire `onTrackEnded` ONCE. MusicKit
    /// gives no reliable end callback, so we watch its state: the single-item queue finishes
    /// as `.stopped`, and — as a backstop when `.stopped` doesn't post — we also treat "played
    /// past the known duration while not paused" as the end. The poll only runs while a
    /// streaming track plays; it's superseded on the next `tryPlay` and cancelled on `stop`.
    /// A ~0.4 s cadence is imperceptible for advancing between streamed songs.
    private func startEndMonitor() {
        endMonitor?.cancel()
        let expected = durationSeconds
        endMonitor = Task { [weak self] in
            let player = ApplicationMusicPlayer.shared
            var everPlayed = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                let status = player.state.playbackStatus
                if status == .playing { everPlayed = true }
                guard everPlayed else { continue }   // ignore the pre-roll before audio starts
                let reachedEnd = expected > 0
                    && player.playbackTime >= expected - 0.5
                    && status != .paused
                if status == .stopped || reachedEnd {
                    self.isPlaying = false
                    self.endMonitor = nil
                    self.onTrackEnded?()
                    return
                }
            }
        }
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
    func resume() {}
    func pausePlayback() {}
    func seek(to seconds: Double) {}
    func stop() { endMonitor?.cancel(); endMonitor = nil; nowPlaying = nil }
}
#endif
