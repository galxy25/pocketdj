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

    #if DEBUG
    /// Test seam — unit tests can't drive MusicKit (no entitlement/authorization headless),
    /// so the SetlistPlayer adoption tests stamp the streamed now-playing state directly.
    func setNowPlayingForTests(_ np: NowPlaying?) { nowPlaying = np }
    #endif

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
    var onTrackEnded: ((EndReason) -> Void)?

    /// Fired when the streaming track was RESTARTED from outside (the system remote ⏮, which
    /// iOS delivers to MusicKit itself — it rewinds its one-song queue to 0:00 and tells nobody).
    /// The setlist sequencer turns this into a step BACK, mirroring the in-app ⏮. Owned by
    /// `SetlistPlayer` alongside `onTrackEnded`; nil ⇒ no consumer.
    var onTrackRestarted: (() -> Void)?

    /// The highest `playbackTime` the end-monitor has observed for the CURRENT track — the
    /// baseline for the backward-jump (system ⏮) detection. Reset by `tryPlay`, re-based by
    /// our own `seek(to:)` so an in-app scrub can never read as a restart.
    @ObservationIgnored private var monitorMaxPlaybackTime: Double = 0

    /// The polling task that watches `ApplicationMusicPlayer` for end-of-track. Cancelled on
    /// stop / superseded on each new `tryPlay`.
    @ObservationIgnored private var stateMonitor: Task<Void, Never>?

    /// Monotonic ticket for `tryPlay`'s supersede guard — a newer call invalidates an older
    /// one still parked at a network await (see the guard comment in `tryPlay`).
    @ObservationIgnored private var tryPlayGeneration = 0

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

    /// The end-monitor's per-tick "is the current track OVER?" verdict, extracted pure so
    /// it's unit-testable (MusicKit itself can't run headless).
    ///
    /// `paused` alone is NOT ended — the listener can pause from MusicKit's own system card
    /// (the monitor's external-pause sync). But iOS routes the lock-screen / CarPlay ⏭ to
    /// MusicKit ITSELF (never our `MPRemoteCommandCenter` handler): it "skips" past its
    /// ONE-SONG queue and parks the player PAUSED with the position reset to ~0 (or pinned
    /// at the track's end) — a state a real listener pause never lands in mid-song
    /// (`playbackTime` is exact on state changes, and a pause anchors AT the pause point).
    /// Those parked-paused shapes must count as ended, else the set freezes on the old
    /// track — the "system ⏭ stops the song but never advances" bug.
    nonisolated static func trackEnded(stopped: Bool, paused: Bool,
                                       playbackTime: Double, expectedDuration: Double) -> Bool {
        endReason(stopped: stopped, paused: paused,
                  playbackTime: playbackTime, expectedDuration: expectedDuration) != nil
    }

    /// WHY the track ended. The set's reaction differs: a `.natural` end honors repeat-one /
    /// per-track repeat counts (replay the song), while a `.systemSkip` — the listener pressed
    /// ⏭ on the lock screen / CarPlay, which iOS delivers to MusicKit itself, never to our
    /// remote handler — must advance EXACTLY like the in-app ⏭ does. Before the reason was
    /// plumbed through, repeat-one swallowed the skip-park as a natural end and REPLAYED the
    /// same song: with repeat-one on, the car's ⏭ could never leave the track (Levi,
    /// 2026-08-19). nil ⇒ not ended.
    enum EndReason { case natural, systemSkip }
    nonisolated static func endReason(stopped: Bool, paused: Bool,
                                      playbackTime: Double, expectedDuration: Double) -> EndReason? {
        if stopped { return .natural }
        let atEnd = expectedDuration > 0 && playbackTime >= expectedDuration - 0.5
        // Paused parked at the very top (≤1 s) = the system-skip artifact, not a listener
        // pause — a pause in the first second of a track is the one (vanishingly rare)
        // false positive, and its cost is only an early advance (now: an advance rather
        // than a repeat-one replay, which is also what a listener pausing at 0:00 after
        // pressing ⏭ actually wanted).
        if paused {
            if playbackTime <= 1.0 && !atEnd { return .systemSkip }
            return atEnd ? .natural : nil
        }
        return atEnd ? .natural : nil
    }

    /// Whether a still-PLAYING track was restarted from outside — the system remote ⏮,
    /// which iOS delivers to MusicKit itself: it rewinds its one-song queue to 0:00 with no
    /// state change we could observe. The signal is `playbackTime` (monotonic per item apart
    /// from seeks, all of which route through our `seek(to:)` and re-base `maxObserved`)
    /// making a hard backward jump to the top. Undetectable inside the first ~10 s —
    /// indistinguishable from MusicKit's laggy position reads — so an early ⏮ just restarts
    /// the song (Apple's own near-the-top ⏮ behavior anyway).
    nonisolated static func trackRestarted(playbackTime: Double, maxObserved: Double) -> Bool {
        playbackTime < 2.0 && maxObserved > 10.0
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
        // SUPERSEDE GUARD (provider-level): a skip storm can leave an OLDER tryPlay parked at
        // one of the two network awaits below while a NEWER one already queued its song — the
        // stale one resuming would re-queue the OLD song over the new audio and stamp
        // `nowPlaying` with it. Claim a ticket at entry; after each await, a stale ticket
        // stands down (mirrors SetlistPlayer's playGeneration; both layers are needed because
        // the sequencer's cancel can land between this provider's suspension points).
        tryPlayGeneration &+= 1
        let ticket = tryPlayGeneration
        // 1) Resolve the song to a catalog track (namespaced `am:<id>` → direct fetch,
        //    else a title/artist search). A miss → false → the engine falls back to rips.
        guard let track = await provider.resolve(song) else { return false }
        guard ticket == tryPlayGeneration else { return false }   // superseded mid-resolve
        // 2) Enqueue the resolved catalog song by its store id + play.
        do {
            let player = ApplicationMusicPlayer.shared
            let id = MusicItemID(track.providerTrackID)
            var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
            req.limit = 1
            let resp = try await req.response()
            guard let catalogSong = resp.items.first else { return false }
            guard ticket == tryPlayGeneration else { return false }   // superseded mid-fetch
            player.queue = [catalogSong]
            try await player.play()
            // 3) Cue: `play()` has returned (playback started), so the position write
            //    sticks — a write before the queue item is ready would be ignored.
            if let atMs, atMs > 0 { seek(to: Double(atMs) / 1000) }
            isPlaying = true
            startPositionClock(from: atMs.map { Double($0) / 1000 } ?? 0)
            monitorMaxPlaybackTime = atMs.map { Double($0) / 1000 } ?? 0
            durationSeconds = catalogSong.duration ?? 0
            // Capture the catalog artwork URL — the app's own now-playing surfaces (home deck +
            // widget) can't get a cover from our art-less AM-Local catalog, so this is it.
            let artURL = catalogSong.artwork?.url(width: 600, height: 600)
            NPLog.trace("AM play title=\(song.name) dur=\(Int(durationSeconds)) artURL=\(artURL != nil)")
            nowPlaying = NowPlaying(songId: song.id, title: song.name, artist: song.artist,
                                    artworkURL: artURL)
            // 4) Arm the end-of-track monitor so the setlist advances when this streaming song
            //    finishes (nothing else observes MusicKit's player).
            startStateMonitor()
            return true
        } catch {
            // A real playback failure (e.g. no active subscription) — don't claim the win,
            // let the rip server fall back. The coordinator surfaces no error for this
            // (the fallback will), matching "first attempt is Apple Music; else rip".
            NPLog.trace("AM tryPlay FAILED title=\(song.name): \(error.localizedDescription)")
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
        // Re-base the ⏮-restart baseline: OUR OWN backward scrub must never read as a
        // system-⏮ backward jump (which would spuriously step the set back).
        monitorMaxPlaybackTime = max(0, seconds)
    }

    func stop() {
        stateMonitor?.cancel(); stateMonitor = nil
        ApplicationMusicPlayer.shared.stop()
        isPlaying = false
        positionBase = 0; positionStartWall = nil
        nowPlaying = nil
    }

    /// Poll `ApplicationMusicPlayer` — the SINGLE reconciliation loop for the streaming track.
    /// Three jobs, all needed because MusicKit is an OS-level player other UIs can drive:
    ///  1. STATE SYNC: the user can pause/resume from MusicKit's OWN system card (the macOS
    ///     menu-bar entry), which never calls our methods — so our `isPlaying` mirror and the
    ///     wall-clock position MUST follow the real `playbackStatus`, not just our own calls.
    ///  2. END-OF-TRACK: the single-item queue finishes as `.stopped` (with a played-past-
    ///     duration backstop) → fire `onTrackEnded` ONCE so the setlist advances.
    ///  3. CLOCK ANCHORING: `playbackTime` is accurate ON state changes — re-anchor the smooth
    ///     wall-clock there so an externally-driven pause/resume can't drift the position.
    /// Superseded on the next `tryPlay`, cancelled on `stop`; ~0.4 s cadence is imperceptible.
    private func startStateMonitor() {
        stateMonitor?.cancel()
        let expected = durationSeconds
        stateMonitor = Task { [weak self] in
            let player = ApplicationMusicPlayer.shared
            var everPlayed = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                let status = player.state.playbackStatus
                if status == .playing {
                    everPlayed = true
                    if !self.isPlaying {              // resumed from OUTSIDE (MusicKit's card)
                        NPLog.trace("AM monitor: external RESUME at \(Int(player.playbackTime))s")
                        self.isPlaying = true
                        self.startPositionClock(from: player.playbackTime)
                    }
                } else if everPlayed, status == .paused, self.isPlaying {
                    NPLog.trace("AM monitor: external PAUSE at \(Int(player.playbackTime))s")
                    self.isPlaying = false            // paused from OUTSIDE — freeze at the
                    self.positionBase = player.playbackTime   // exact (state-change) position
                    self.positionStartWall = nil
                }
                guard everPlayed else { continue }   // ignore the pre-roll before audio starts
                let t = player.playbackTime
                if t > self.monitorMaxPlaybackTime { self.monitorMaxPlaybackTime = t }
                // System remote ⏮ also lands in MusicKit (never our handler): it rewinds its
                // one-song queue to 0:00 while STAYING .playing — no state change to observe,
                // only the backward jump of the otherwise-monotonic playbackTime. Mirror the
                // in-app ⏮: step the set back one track.
                if status == .playing,
                   Self.trackRestarted(playbackTime: t, maxObserved: self.monitorMaxPlaybackTime) {
                    NPLog.trace("AM monitor: RESTART detected (t=\(Int(t)) max=\(Int(self.monitorMaxPlaybackTime))) → previous")
                    self.monitorMaxPlaybackTime = t
                    self.startPositionClock(from: t)
                    self.onTrackRestarted?()
                    continue
                }
                // `trackEnded` covers .stopped, played-past-duration, AND the system-skip
                // artifact (lock-screen/CarPlay ⏭ goes to MusicKit, which exhausts its
                // one-song queue and parks PAUSED at ~0 / the end — see the func doc).
                if let reason = Self.endReason(stopped: status == .stopped, paused: status == .paused,
                                               playbackTime: t, expectedDuration: expected) {
                    NPLog.trace("AM monitor: track ENDED reason=\(reason) (status=\(status) t=\(Int(t)) expected=\(Int(expected)))")
                    self.isPlaying = false
                    self.freezePositionClock()
                    self.stateMonitor = nil
                    self.onTrackEnded?(reason)
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
    func stop() { stateMonitor?.cancel(); stateMonitor = nil; nowPlaying = nil }
}
#endif
