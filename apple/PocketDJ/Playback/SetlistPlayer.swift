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
    struct Item: Equatable { let id: String; let title: String; let artist: String }

    private(set) var queue: [Item] = []
    /// Index into `queue` (NOT track.id — a song can repeat in a setlist).
    private(set) var index = 0
    private(set) var isRunning = false
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
    }

    /// Start playing `items` from the top. No-op for an empty list.
    func play(_ items: [Item]) {
        guard !items.isEmpty else { return }
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

    /// Natural end-of-track. OWNERSHIP GUARD: ignore a stray end-event from an unrelated /
    /// manual single-row play (which changes `rips.nowPlaying`), so only OUR current track
    /// auto-advances.
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
            if let local = burns.localURL(forSong: it.id) {
                loadedAnyDeviceTrack = true
                // SHARED helper so nowPlaying + the inline player + the row toggle stay
                // consistent with the single-row burned path.
                playLocalFile(local, songId: it.id, title: it.title, artist: it.artist,
                              startMs: burns.startMs(forSong: it.id), rips: rips, player: player)
                // Finite local file → the end notification advances us.
            } else {
                advance()   // no on-device file for this track → skip it
            }
            return
        }

        // CLOUD mode (default): prefer a burned local file when present (zero-latency,
        // offline), else stream / rip-on-demand via the coordinator (Apple Music → rip).
        if let local = burns.localURL(forSong: it.id) {
            loadedAnyDeviceTrack = true
            playLocalFile(local, songId: it.id, title: it.title, artist: it.artist,
                          startMs: burns.startMs(forSong: it.id), rips: rips, player: player)
        } else {
            await coordinator.play(id: it.id, title: it.title, artist: it.artist)
            // Dead source (no server / rip error) → no end event will fire; advance now.
            if coordinator.lastErrorMessage != nil { advance(); return }
            // A live HLS capture has no natural end → don't rely on the hook; offer "Next".
            if player.isLive { waitingForLive = true }
        }
    }
}
