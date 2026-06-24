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

    private let player: PlayerEngine
    private let rips: RipsStore
    private let burns: BurnStore
    private let coordinator: PlaybackCoordinator

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
        // Own the engine's end hook only while running (released in stop()).
        player.onTrackEnded = { [weak self] in self?.handleEnded() }
        Task { await playCurrent() }
    }

    /// Stop the sequence + clear now-playing; resets so the toolbar flips back to Play.
    func stop() {
        isRunning = false
        waitingForLive = false
        player.onTrackEnded = nil          // release ownership of the shared hook
        player.stop()
        coordinator.stop()
        rips.setNowPlaying(nil)
        index = 0
        queue = []
    }

    /// Manually advance (used by the live-track "Next" affordance).
    func skipNext() { advance() }

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
            stop()                          // reached the end — tear down cleanly
        } else {
            Task { await playCurrent() }
        }
    }

    /// Resolve the SOURCE fresh each track (a burnt file may have been purged since the
    /// queue was built) and start it. Failure (no end event will ever fire) advances now.
    private func playCurrent() async {
        guard isRunning, index < queue.count else { return }
        let it = queue[index]

        if let local = burns.localURL(forSong: it.id) {
            // Burnt local file → drive the SAME PlayerEngine the rip path uses (mirrors
            // RipServerPlaybackProvider.tryPlay: set nowPlaying, then load the engine).
            let np = RipsStore.NowPlaying(songId: it.id, title: it.title, artist: it.artist,
                                          url: local, live: false, startMs: nil, waveform: nil)
            rips.setNowPlaying(np)
            player.load(url: local, live: false, startMs: nil, title: it.title, artist: it.artist)
            // Finite local file → the end notification will advance us.
        } else {
            // Stream / rip-on-demand via the coordinator (Apple Music → rip fallback).
            await coordinator.play(id: it.id, title: it.title, artist: it.artist)
            // Dead source (no server / rip error) → no end event will fire; advance now.
            if coordinator.lastErrorMessage != nil { advance(); return }
            // A live HLS capture has no natural end → don't rely on the hook; offer "Next".
            if player.isLive { waitingForLive = true }
        }
    }
}
