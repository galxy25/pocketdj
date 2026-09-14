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
    ///
    /// `atMs` (spec §9 cue offset, ms from the SONG's 0:00) rides into `rips.play`, which
    /// resolves the absolute file position `PlayerEngine.load` seeks to: the song's
    /// shared-analog-album `startMs` + `atMs` when the song lives inside one album mp3,
    /// else `atMs` directly (`NowPlaying.seekMs`). A LIVE in-flight HLS rip CANNOT seek —
    /// the cue is dropped there and `lastCueDropped` records the fact (CuesView disables
    /// those cues up front via `canCueSeek`; this is the after-the-fact backstop).
    func tryPlay(_ song: IndexSong, atMs: Int?) async -> Bool {
        lastCueDropped = false
        // SILENT-PARK INSTRUMENTATION (2026-09-13): the outermost bracket around the whole
        // resolve. Field signature to look for in the `ripreq` lane: a `tryPlay start` with
        // NO `tryPlay ok/fail` after it = the resolve parked somewhere the inner presign/
        // rip-post brackets don't cover; `fail` lines carry the real error domain#code the
        // UI toast flattens away. Ids only, no titles.
        let t0 = Date()
        DiagLog.shared.telemetry("ripreq", "tryPlay start song=\(song.id)")
        do {
            let now = try await rips.play((id: song.id, title: song.name, artist: song.artist),
                                          startMs: nil, atMs: atMs)
            if atMs != nil, now.live { lastCueDropped = true }
            player.load(url: now.url, live: now.live, startMs: now.seekMs ?? now.startMs,
                        title: now.title, artist: now.artist, songId: now.songId)
            DiagLog.shared.telemetry("ripreq", "tryPlay ok song=\(song.id) live=\(now.live) elapsedMs=\(Int(-t0.timeIntervalSinceNow * 1000))")
            return true
        } catch {
            // Stash so the coordinator can surface it; still "handled" by this terminal
            // provider, so the cycle stops here rather than reporting "no provider".
            DiagLog.shared.telemetry("ripreq", "tryPlay fail song=\(song.id) elapsedMs=\(Int(-t0.timeIntervalSinceNow * 1000)) err=\((error as NSError).domain)#\((error as NSError).code) \(String(describing: (error as? RipsStore.RipError)))")
            lastError = error
            return false
        }
    }

    /// True when the LAST `tryPlay` carried a cue offset that could NOT be applied because
    /// the song resolved to a live in-flight HLS rip (unseekable — spec §9). Reset at the
    /// start of every `tryPlay`. The UI's primary defense is `canCueSeek` (disable the cue
    /// before playing); this flag is the honest signal for the race where the rip went live
    /// between the check and the play.
    private(set) var lastCueDropped = false

    /// Can this backend seek `songId` to a cue RIGHT NOW? Only a DURABLE cached S3 mp3
    /// seeks; a song that would rip on demand (or is mid-rip) streams live HLS, which
    /// cannot. CuesView keys the "still ripping" disabled state off this (via
    /// `PlaybackCoordinator.cueSeekSupported(for:)`).
    func canCueSeek(_ songId: String) -> Bool { rips.cachedURL(songId) != nil }

    /// Can this backend start `songId` WITHOUT WAITING? Only a durable cached mp3 can:
    /// anything else makes `tryPlay` park inside `ensureURL(allowLive:)` until the capture
    /// goes live, which is minutes when the rip server is draining a backfill queue — and
    /// because the provider cycle is sequential, a streaming provider sitting BEHIND this
    /// one never gets its turn. The coordinator reads this to let a streamable row stream
    /// now instead of waiting on a rip that is merely queued (see `providers(for:)`).
    /// Same predicate as `canCueSeek`, kept separate because the two questions are
    /// independent — this one is about LATENCY, that one about SEEKABILITY.
    func canPlayImmediately(_ songId: String) -> Bool { rips.cachedURL(songId) != nil }

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
