import Foundation
import Observation

/// Feature 3 — Setlist PLAY ALL. A thin sequencer that plays a setlist's tracks IN ORDER,
/// one at a time, auto-advancing when each finishes. For each track it chooses the SOURCE:
///   • a BURNT local file (`BurnStore.localURL(forSong:)`) → played directly through the
///     SAME `PlayerEngine` the inline player binds to, or
///   • otherwise STREAM via `PlaybackCoordinator` (Apple Music / rip-on-demand).
/// Both routes set `RipsStore.nowPlaying`, so the existing per-row `InlinePlayerSlot`
/// lights up the current track with zero new player UI.
///
/// Auto-advance rides `PlayerEngine.onTrackEnded` (the finite-item end notification). A
/// LIVE HLS track has no end event, so the sequencer surfaces a "Next" affordance
/// (`waitingForLive`) rather than freezing. A dead/unplayable source (coordinator error or
/// a purged burnt file) advances immediately. Stops at the end.
@MainActor
@Observable
final class SetlistPlayer {
    /// One playable track. `id` is the catalog songId; title/artist label the now-playing.
    /// `lengthMs` (the track's known length from the catalog/setlist snapshot) drives the
    /// position boundary so a track inside a shared album-rip file advances at its OWN end,
    /// not the album file's; nil ⇒ rely on the natural end.
    struct Item: Equatable {
        let id: String; let title: String; let artist: String
        var lengthMs: Int? = nil
    }

    private(set) var queue: [Item] = []
    /// Index into `queue` (NOT track.id — a song can repeat in a setlist).
    private(set) var index = 0
    private(set) var isRunning = false
    /// The id of the COLLECTION currently playing (a setlist id) — so a detail screen knows
    /// whether IT is the one playing (vs. another set playing in the background after the user
    /// navigated away). nil when idle. This is what makes playback survive navigation: the
    /// sequencer is app-scoped, so leaving a screen never tears it down — only starting a
    /// DIFFERENT collection (a fresh `play`) replaces it.
    private(set) var sourceSetlistId: String?
    /// True when the current track is a live stream with no natural end — the UI shows a
    /// "Next" control so the set never silently freezes on it.
    private(set) var waitingForLive = false

    /// CRITIC-D — set when a DEVICE-mode run finished without EVER loading a single burned
    /// file (the whole queue was unplayable on-device). One-shot, non-optional signal the
    /// playback surface reads to show a transient "no burned files" banner — so device mode
    /// never silently dead-ends with nothing playing. Cleared on the next `play(_:)`.
    private(set) var deviceQueueUnplayable = false
    /// Tracks (within the current run) whether ANY track has loaded a burned file — so a
    /// device-mode set that reaches the end with nothing loaded can raise the banner.
    private var loadedAnyDeviceTrack = false

    private let player: PlayerEngine
    private let rips: RipsStore
    private let burns: BurnStore
    private let coordinator: PlaybackCoordinator

    /// SEAM (Item 7, owned by Native2/Server): the global device/cloud playback mode,
    /// injected from settings at `ensurePlayer` time. Defaults to `.cloud` so today's
    /// stream-first behaviour is unchanged until the mode toggle is wired.
    var playbackMode: () -> PlaybackMode = { .cloud }

    init(player: PlayerEngine, rips: RipsStore, burns: BurnStore, coordinator: PlaybackCoordinator) {
        self.player = player
        self.rips = rips
        self.burns = burns
        self.coordinator = coordinator
        // Arm the now-playing observation ONCE; it self-re-arms on every change (see
        // `adoptNowPlayingIfJumped`). Single arm avoids stacking observers across play() calls.
        observeNowPlaying()
    }

    /// Start playing `items` from the top, tagged with the source collection's id (so a
    /// detail screen can tell whether IT is the one playing). No-op for an empty list. A
    /// fresh `play` replaces whatever was running — that's the ONLY thing that stops a set.
    func play(_ items: [Item], sourceSetlistId: String? = nil) {
        guard !items.isEmpty else { return }
        self.sourceSetlistId = sourceSetlistId
        queue = items
        index = 0
        isRunning = true
        deviceQueueUnplayable = false   // fresh run — clear any prior banner signal
        loadedAnyDeviceTrack = false
        // Own the engine's end hook + lock-screen next/previous only while running (released in
        // stop()). The lock screen / Control Center next/prev now advance the SET.
        player.onTrackEnded = { [weak self] in self?.handleEnded() }
        player.onNext = { [weak self] in self?.skipNext() }
        player.onPrevious = { [weak self] in self?.skipPrevious() }
        player.setNextPreviousEnabled(true)
        Task { await playCurrent() }
    }

    /// Stop the sequence + clear now-playing; resets so the toolbar flips back to Play.
    func stop() {
        isRunning = false
        waitingForLive = false
        player.onTrackEnded = nil          // release ownership of the shared hook
        player.onNext = nil
        player.onPrevious = nil
        player.setNextPreviousEnabled(false)
        player.stop()
        coordinator.stop()
        rips.setNowPlaying(nil)
        index = 0
        queue = []
        sourceSetlistId = nil
    }

    /// Acknowledge + clear the one-shot device-unplayable banner (the surface calls this
    /// once it has shown the transient message).
    func clearDeviceUnplayable() { deviceQueueUnplayable = false }

    /// Manually advance (used by the live-track "Next" affordance + lock-screen NEXT).
    func skipNext() { advance() }

    /// Manually go back one track (lock-screen PREVIOUS). No-op past the top of the set; never
    /// goes below index 0. Re-resolves + plays the (now) current track.
    func skipPrevious() {
        guard isRunning else { return }
        waitingForLive = false
        index = max(0, index - 1)
        Task { await playCurrent() }
    }

    // MARK: - Internals

    /// The absolute position (ms) at which a track that SHARES a multi-song file should
    /// advance: its per-song start offset within the shared mp3 + its known length. Returns
    /// nil for a PER-SONG file (no shared offset → `startMs` nil): those have their OWN natural
    /// end, so we must NOT cut them at the catalog length (which can be missing/short). ONLY
    /// analog album rips share one mp3 across songs, and they carry a non-nil per-song
    /// `startMs` — so a non-nil `startMs` is exactly the signal that the length boundary is
    /// needed (the natural `.AVPlayerItemDidPlayToEndTime` would otherwise only fire at the
    /// END OF THE WHOLE album file).
    private func sharedFileEndBoundaryMs(_ it: Item, startMs: Int?) -> Int? {
        guard let startMs, let len = it.lengthMs, len > 0 else { return nil }
        return startMs + len
    }

    /// The queue index of the occurrence of `id` NEAREST to `ref`, preferring a FORWARD
    /// occurrence on a tie (the DJ usually taps a row later in the set). A setlist may repeat a
    /// song and the now-playing handoff carries no queue position, so this is the best
    /// disambiguation available from the song id alone.
    private func nearestOccurrence(of id: String, to ref: Int) -> Int? {
        var best: Int?
        for i in queue.indices where queue[i].id == id {
            guard let b = best else { best = i; continue }
            let di = abs(i - ref), db = abs(b - ref)
            if di < db || (di == db && i >= ref) { best = i }
        }
        return best
    }

    /// Observe `RipsStore.nowPlaying` so a manual row ▶ on a track that's IN this running set
    /// REPOSITIONS the sequencer to it (and keeps auto-advancing) instead of the set silently
    /// stopping when that manually-started track ends. One-shot tracking, re-armed on each
    /// change (the first line of `adoptNowPlayingIfJumped`). `onChange` is a nonisolated
    /// `@Sendable` closure, so it can only hop back onto the main actor — it can't re-arm
    /// synchronously; the one-turn gap is sub-millisecond and unreachable by a human tap.
    /// Armed ONCE in `init` and self-perpetuating — never re-armed from `play()` (that would
    /// stack observers and fan out). Dies when this player deallocates (`weak self`).
    private func observeNowPlaying() {
        withObservationTracking {
            _ = rips.nowPlaying?.songId
        } onChange: { [weak self] in
            Task { @MainActor in self?.adoptNowPlayingIfJumped() }
        }
    }

    /// Reacts to a `nowPlaying` change. If a set is running and the now-playing song is a
    /// DIFFERENT queue member than the current index (a manual jump from a row ▶), move the
    /// index onto it and arm its length boundary so it auto-advances. The sequencer's OWN
    /// plays set `nowPlaying` to `queue[index]`, so the equality guard makes those a no-op —
    /// no restart loop. The adopted track's boundary is keyed off `nowPlaying.startMs` (the
    /// source the row actually loaded) so a shared-album track is bounded and a per-song one
    /// keeps its natural end. (Duplicate occurrences: disambiguated by `nearestOccurrence`; an
    /// exact-tie jump to another occurrence of the CURRENT song stays put — see the guard.)
    private func adoptNowPlayingIfJumped() {
        observeNowPlaying()   // re-arm for the next change (always, even on the no-op paths)
        guard isRunning, index < queue.count else { return }
        guard let npId = rips.nowPlaying?.songId, queue[index].id != npId else { return }
        guard let pos = nearestOccurrence(of: npId, to: index) else { return }   // not in set
        index = pos
        waitingForLive = false
        if burns.localURL(forSong: queue[pos].id) != nil { loadedAnyDeviceTrack = true }
        player.setEndBoundary(ms: sharedFileEndBoundaryMs(queue[pos], startMs: rips.nowPlaying?.startMs))
    }

    /// Natural end-of-track. OWNERSHIP GUARD: ignore a stray end-event from an unrelated /
    /// manual single-row play (which changes `rips.nowPlaying`), so only OUR current track
    /// auto-advances. A manual play of an IN-SET track is first adopted by
    /// `adoptNowPlayingIfJumped` (index moves onto it), so this guard then passes for it.
    private func handleEnded() {
        guard isRunning, index < queue.count,
              rips.nowPlaying?.songId == queue[index].id else { return }
        advance()
    }

    private func advance() {
        guard isRunning else { return }
        waitingForLive = false
        index += 1
        if index >= queue.count {
            // CRITIC-D — a DEVICE-mode set that reached the end having never loaded a single
            // burned file: raise the one-shot banner so the surface tells the DJ nothing was
            // playable on-device (rather than silently ending with no audio).
            let unplayable = playbackMode() == .device && !loadedAnyDeviceTrack
            stop()                          // reached the end — tear down cleanly
            if unplayable { deviceQueueUnplayable = true }
        } else {
            Task { await playCurrent() }
        }
    }

    /// Resolve the SOURCE fresh each track (a burnt file may have been purged since the
    /// queue was built) and start it. Failure (no end event will ever fire) advances now.
    private func playCurrent() async {
        guard isRunning, index < queue.count else { return }
        let it = queue[index]
        let mode = playbackMode()

        // DEVICE mode: play ONLY a burned local file. A track with no burned file is SKIPPED
        // (advance now — no end event would ever fire). If the whole queue has none, the
        // end-of-set advance raises the CRITIC-D banner. Mode-flip mid-set applies to the
        // NEXT track: the current track keeps playing under the mode it started with.
        if mode == .device {
            if let res = burns.localURLForPlayback(forSong: it.id) {
                loadedAnyDeviceTrack = true
                // SHARED helper so nowPlaying + the inline player + the row toggle stay
                // consistent with the single-row burned path. `res.release` keeps a user-folder
                // file's security scope open through playback.
                playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                              startMs: burns.startMs(forSong: it.id), rips: rips, player: player,
                              endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.id)),
                              release: res.release)
                // Finite local file → the end notification (or length boundary) advances us.
            } else {
                advance()   // no on-device file for this track → skip it
            }
            return
        }

        // CLOUD mode (default): prefer a burned local file when present (zero-latency,
        // offline), else stream / rip-on-demand via the coordinator (Apple Music → rip).
        if let res = burns.localURLForPlayback(forSong: it.id) {
            loadedAnyDeviceTrack = true
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: burns.startMs(forSong: it.id), rips: rips, player: player,
                          endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.id)),
                          release: res.release)
        } else {
            await coordinator.play(id: it.id, title: it.title, artist: it.artist)
            // Dead source (no server / rip error) → no end event will fire; advance now.
            if coordinator.lastErrorMessage != nil { advance(); return }
            // A live HLS capture has no natural end → don't rely on the hook; offer "Next".
            if player.isLive {
                waitingForLive = true
            } else {
                // A cloud rip of an ANALOG album is ONE shared mp3 + per-song startMs (the rip
                // server transcodes the whole side once), so its natural end only fires at the
                // END OF THE WHOLE FILE — arm the per-song length boundary to advance at this
                // track's own end. A digital cloud rip is per-song (startMs nil → no boundary,
                // the natural end governs). `nowPlaying.startMs` is what the rip path resolved.
                player.setEndBoundary(ms: sharedFileEndBoundaryMs(it, startMs: rips.nowPlaying?.startMs))
            }
        }
    }
}
