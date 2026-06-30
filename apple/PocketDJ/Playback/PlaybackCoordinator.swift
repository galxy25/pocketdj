import Foundation
import Observation

/// The matching engine behind the ▶ button. Given a song, it builds a SOURCE-AWARE
/// ordered list of `TrackPlaybackProvider`s and cycles them — calling `tryPlay` on each
/// until one resolves + starts the track. The first to return `true` becomes the active
/// backend; if none does, it surfaces an error.
///
/// Ordering rule (milestone 1): for a song whose origin source is the user's "Apple Music
/// (Local)" catalog, put the Apple Music STREAMING provider FIRST when it `isReady`
/// (enabled + authorized) — so tapping ▶ plays it via Apple Music. The rip server is
/// ALWAYS appended as the terminal fallback (rip-on-demand), so any song still plays even
/// when Apple Music can't resolve/play it. Other streaming backends could slot into the
/// same ordered list later.
///
/// The UI reads one unified, observable surface off this coordinator: `activeBackend`,
/// `isPlaying`, and the per-backend now-playing handoffs — plus `togglePlayPause()` /
/// `stop()` that delegate to whichever provider won. The rip path is transparent: its
/// provider just drives the same `PlayerEngine` the inline waveform/scrubber already binds
/// to, so that verified UI is untouched.
/// Item 7 — the SHARED "play a burned local file" helper, used by BOTH the
/// `SetlistPlayer` sequencer AND the single-row transport so `RipsStore.nowPlaying`
/// (and therefore the inline player + the row pause/resume toggle) stays consistent no
/// matter which surface started the burned file. It mirrors `RipServerPlaybackProvider.tryPlay`
/// for the rip path: stamp `nowPlaying`, then load the SAME `PlayerEngine` the inline
/// waveform/scrubber binds to. `startMs` is the analog seek offset within a shared album mp3.
@MainActor
func playLocalFile(_ url: URL, songId: String, title: String, artist: String,
                   startMs: Int?, rips: RipsStore, player: PlayerEngine,
                   endBoundaryMs: Int? = nil, release: (() -> Void)? = nil) {
    let np = RipsStore.NowPlaying(songId: songId, title: title, artist: artist,
                                  url: url, live: false, startMs: startMs, waveform: nil)
    rips.setNowPlaying(np)
    player.load(url: url, live: false, startMs: startMs, title: title, artist: artist,
                endBoundaryMs: endBoundaryMs, scopeRelease: release)
}

@MainActor
@Observable
final class PlaybackCoordinator {
    /// The rip-on-demand fallback (always present, always last).
    let ripProvider: RipServerPlaybackProvider
    /// Apple Music streaming (tried first for Apple Music (Local) songs when ready).
    let appleMusic: AppleMusicPlaybackProvider

    /// Resolves a song id → its origin source name (e.g. "Apple Music (Local)"), so the
    /// engine can order providers by source. Injected (the app passes `AppModel`'s map) to
    /// keep the coordinator decoupled + unit-testable. Returns nil when unknown.
    var sourceOfSong: (String) -> String? = { _ in nil }

    /// Which backend last won the cycle (nil = nothing playing). Drives the inline player's
    /// branch (rip waveform vs. Apple Music position scrubber) + the "via …" badge.
    private(set) var activeBackend: PlaybackBackend?

    /// A user-presentable failure from the last `play` (e.g. no rip server). UI binds an
    /// alert to it; cleared on dismiss / next successful play.
    var lastErrorMessage: String?

    init(ripProvider: RipServerPlaybackProvider, appleMusic: AppleMusicPlaybackProvider) {
        self.ripProvider = ripProvider
        self.appleMusic = appleMusic
    }

    /// All providers, in the SOURCE-AWARE order to try for `song`:
    ///   • Apple Music FIRST when the song came from the Apple Music (Local) source AND
    ///     the Apple Music provider is ready (enabled + authorized),
    ///   • the rip server ALWAYS last (the universal fallback).
    /// (Another streaming backend would insert ahead of the rip server here later.)
    func providers(for song: IndexSong) -> [any TrackPlaybackProvider] {
        var ordered: [any TrackPlaybackProvider] = []
        if sourceOfSong(song.id) == Config.appleMusicSourceName, appleMusic.isReady {
            ordered.append(appleMusic)
        }
        ordered.append(ripProvider)   // terminal fallback
        return ordered
    }

    /// Run the matching engine: try each provider for `song` in order; the first that
    /// returns true wins (record it as `activeBackend`); if none does, surface the rip
    /// provider's error (the terminal fallback's failure is the actionable one).
    func play(_ song: IndexSong) async {
        lastErrorMessage = nil
        for provider in providers(for: song) {
            // Switching backends: stop the previously-active one so two engines don't both
            // play (e.g. Apple Music wins after a prior rip, or vice-versa).
            if let active = activeBackend, active != provider.backend {
                providerFor(active)?.stop()
            }
            if await provider.tryPlay(song) {
                activeBackend = provider.backend
                // Feature 1 — stream-through-ripping. The Apple Music stream has already
                // STARTED (tryPlay returned true), so kicking off the async rip here adds
                // ZERO playback latency. Fire-and-forget (unawaited, never blocks/delays
                // playback; failures are silent). A plain `Task` inherits this @MainActor —
                // `requestRipIfNeeded` is idempotent and suspends (not blocks) on the POST.
                if provider.backend == .appleMusic {
                    Task { await self.ripProvider.requestAsyncRip(song.id) }
                }
                return
            }
        }
        // No provider claimed the song — surface the rip server's error if it had one.
        if let err = ripProvider.takeLastError() {
            lastErrorMessage = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
        } else {
            lastErrorMessage = "Couldn’t play this track."
        }
    }

    /// Convenience for the row ▶ given only (id, title, artist) — projects a minimal
    /// `IndexSong` and plays it. (The provider chain only needs id/name/artist + the
    /// source map keyed by id, so a minimal projection is sufficient.)
    func play(id: String, title: String, artist: String) async {
        await play(IndexSong.minimal(id: id, name: title, artist: artist))
    }

    // MARK: Unified transport (delegate to the active provider)

    /// Whether the active backend is currently playing (unified play/pause glyph).
    var isPlaying: Bool { activeProvider?.isPlaying ?? false }

    func togglePlayPause() { activeProvider?.togglePlayPause() }

    /// Seek the Apple Music streaming backend (the rip backend scrubs via `PlayerEngine`
    /// directly, so it doesn't route through here).
    func seekAppleMusic(to seconds: Double) { appleMusic.seek(to: seconds) }

    func stop() {
        activeProvider?.stop()
        activeBackend = nil
    }

    /// Is `songId` the Apple Music now-playing song? (The rip path keeps keying off
    /// `RipsStore.nowPlaying` directly — the coordinator doesn't duplicate that state — so
    /// this only answers the Apple Music branch. The row ▶ ORs the two together.)
    func isAppleMusicNowPlaying(_ songId: String) -> Bool {
        activeBackend == .appleMusic && appleMusic.nowPlaying?.songId == songId
    }

    // MARK: Provider lookup

    private var activeProvider: (any TrackPlaybackProvider)? {
        activeBackend.flatMap(providerFor)
    }

    private func providerFor(_ backend: PlaybackBackend) -> (any TrackPlaybackProvider)? {
        switch backend {
        case .ripServer:  return ripProvider
        case .appleMusic: return appleMusic
        }
    }
}
