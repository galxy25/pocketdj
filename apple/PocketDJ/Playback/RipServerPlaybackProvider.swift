import Foundation

/// The FALLBACK playback provider: rip-on-demand, exactly as the row's ▶ has always
/// done it. It wraps the existing `RipsStore` (resolve a playable URL — cached S3 mp3
/// or live HLS) + `PlayerEngine` (the AVPlayer the inline waveform/scrubber binds to)
/// and does NOTHING new — it is a thin relocation of `RowTransport.doPlay`'s body so
/// the matching engine can own the ▶ action without changing rip behavior one bit.
///
/// `tryPlay` ALWAYS returns true: the rip server is the last resort in the provider
/// cycle and rips/streams on demand, so it can always (attempt to) play any song. Real
/// failures (no server, rip error) throw out of `RipsStore.play` and are surfaced by the
/// coordinator — they do NOT mean "try another provider" (there is none after this).
///
/// Because `isPlaying` is `PlayerEngine.isPlaying` and `togglePlayPause()` is
/// `PlayerEngine.toggle()`, the rip path's verified UI (waveform + `PlayerClock`/
/// TimelineView scrubber) and the `player-state` / `player-toggles` test probes keep
/// reading the SAME engine they always have — the coordinator is transparent to them.
@MainActor
final class RipServerPlaybackProvider: TrackPlaybackProvider {
    let backend: PlaybackBackend = .ripServer

    private let rips: RipsStore
    private let player: PlayerEngine

    init(rips: RipsStore, player: PlayerEngine) {
        self.rips = rips
        self.player = player
    }

    /// Always ready — it rips on demand. (A missing rip server surfaces as a thrown
    /// error from `tryPlay`, not as un-readiness, so the engine doesn't silently skip
    /// the only fallback.)
    var isReady: Bool { true }

    /// The live AVPlayer state — the single source of truth the inline player + probes read.
    var isPlaying: Bool { player.isPlaying }

    /// The fallback: resolve a playable URL + arm the inline panel, then load the engine
    /// EXACTLY ONCE (mirrors `RowTransport.doPlay`). Throws-as-error is mapped to the
    /// coordinator's surfaced error via the `CoordinatorPlaybackError` wrapper so a real
    /// failure (no server / rip error) is shown rather than silently "trying the next
    /// provider" (there is none).
    func tryPlay(_ song: IndexSong) async -> Bool {
        do {
            let now = try await rips.play((id: song.id, title: song.name, artist: song.artist),
                                          startMs: nil)
            player.load(url: now.url, live: now.live, startMs: now.startMs,
                        title: now.title, artist: now.artist, songId: now.songId)
            return true
        } catch {
            // Stash so the coordinator can surface it; still "handled" by this terminal
            // provider, so the cycle stops here rather than reporting "no provider".
            lastError = error
            return false
        }
    }

    /// Set when `tryPlay` hit a real rip failure (no server / rip error). The coordinator
    /// reads + clears it to surface the message after the cycle ends with no winner.
    private(set) var lastError: Error?
    func takeLastError() -> Error? { defer { lastError = nil }; return lastError }

    /// Feature 1 — stream-through-ripping. Fire-and-forget: kick off the async rip of a
    /// song that's being streamed elsewhere (Apple Music) so a durable rip is ready
    /// shortly after. The rip POLICY lives with the rip provider (which already owns
    /// `rips`); `requestRipIfNeeded` is idempotent + never throws + never blocks playback.
    func requestAsyncRip(_ songId: String) async {
        await rips.requestRipIfNeeded(songId)
    }

    func togglePlayPause() { player.toggle() }

    func stop() {
        player.stop()
        rips.setNowPlaying(nil)
    }
}
