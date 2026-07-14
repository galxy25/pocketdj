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
        /// Total plays before advancing (a performance item's loop count). nil/≤1 ⇒ once.
        /// Excluded from equality — it's a playback parameter, not row identity.
        var repeatCount: Int? = nil
        /// Per-INSTANCE identity for live-queue rows (a song can repeat in a set, so
        /// `id` can't identify a row). Lets the Now Playing panel remove exactly the
        /// row the user tapped even when the queue shifts underneath the tap (a track
        /// ending mid-interaction). Excluded from equality — two Items for the same
        /// track are still equal.
        let uid = UUID()

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.artist == rhs.artist && lhs.lengthMs == rhs.lengthMs
        }
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
    /// The song id of the track the sequencer is currently on, or nil when idle.
    var currentSongId: String? { isRunning && index < queue.count ? queue[index].id : nil }
    /// True when `songId` is a member of the RUNNING queue. The Play-History hook uses this (not
    /// `currentSongId ==`) to attribute a play to the set: tapping a member row to jump ahead
    /// fires the play BEFORE the deferred `adoptNowPlayingIfJumped` moves the index, so a
    /// current-track equality check would mislabel that member play as a Browser single.
    func inRunningQueue(_ songId: String) -> Bool { isRunning && queue.contains { $0.id == songId } }

    /// Resolves the Play-History (source-kind, set name) for a run's `sourceSetlistId`. Wired at
    /// app init to read `CollectionsStore.historyContext`. CAPTURED at `play()` time into
    /// `capturedHistoryContext` so a play mid-run is attributed to THIS run's origin even after a
    /// newer `playNow` has already mutated the shared now-playing source during a navigation gap.
    @ObservationIgnored var historyContextProvider: ((String?) -> (source: PlayHistoryStore.PlaySource, name: String?))?
    private(set) var capturedHistoryContext: (source: PlayHistoryStore.PlaySource, name: String?)?
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
    /// Plays LEFT for the current track (a performance item's repeat count). Set fresh whenever
    /// the index moves onto a new track; decremented on each natural end until it hits 1, at which
    /// point `advance()` moves on. Always ≥ 1 (`normalizedRepeat`).
    private var currentPlaysRemaining = 1

    private let player: PlayerEngine
    private let rips: RipsStore
    private let burns: BurnStore
    private let coordinator: PlaybackCoordinator

    /// SEAM (Item 7, owned by Native2/Server): the global device/cloud playback mode,
    /// injected from settings at `ensurePlayer` time. Defaults to `.cloud` so today's
    /// stream-first behaviour is unchanged until the mode toggle is wired.
    var playbackMode: () -> PlaybackMode = { .cloud }

    /// STUDIO SEAM (spec §8, wired at app init to `StudioStore.localURLForPlayback`):
    /// resolve a studio id (`smp_`/`lp_`/`ptn_`) to its playable LOCAL file. The
    /// returned `release` closure keeps a user-folder file's security scope open
    /// through playback (the BurnStore `res.release` contract — the player calls it on
    /// stop / next load). nil until wired; a nil RESULT (item deleted, dirty pattern
    /// bounce, unreachable folder) makes the row skip forward exactly like an
    /// unresolvable song — no end event would ever fire for it.
    var studioResolve: ((String) -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)?)?

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
        // Snapshot THIS run's history origin now (before any later playNow can mutate the shared
        // now-playing source), so every play in this run is attributed to the right set.
        capturedHistoryContext = historyContextProvider?(sourceSetlistId)
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
        // Apple Music STREAMS through MusicKit's own player, which the PlayerEngine end hook
        // above never sees — so wire its end-of-track straight into the sequencer's advance,
        // else the set freezes after the first streamed song.
        coordinator.appleMusic.onTrackEnded = { [weak self] in self?.handleAppleMusicEnded() }
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
        coordinator.appleMusic.onTrackEnded = nil
        player.stop()
        coordinator.stop()
        rips.setNowPlaying(nil)
        index = 0
        queue = []
        sourceSetlistId = nil
        capturedHistoryContext = nil
    }

    /// Acknowledge + clear the one-shot device-unplayable banner (the surface calls this
    /// once it has shown the transient message).
    func clearDeviceUnplayable() { deviceQueueUnplayable = false }

    /// Manually advance (used by the live-track "Next" affordance + lock-screen NEXT).
    func skipNext() { advanceToNext() }

    /// Manually go back one track (lock-screen PREVIOUS). No-op past the top of the set; never
    /// goes below index 0. Re-resolves + plays the (now) current track.
    func skipPrevious() {
        guard isRunning else { return }
        waitingForLive = false
        index = max(0, index - 1)
        Task { await playCurrent() }
    }

    // MARK: - Live queue edits (the Now Playing panel's Up-Next list)
    //
    // All three mutate ONLY the UPCOMING suffix — `queue[(index+1)...]`. Positions
    // ≤ `index` (the playing track + the played history) are never touched: the
    // end-of-track ownership guard (`handleEnded`) and the manual-jump adoption
    // (`adoptNowPlayingIfJumped`) both key off `queue[index]`, so disturbing it
    // would silently freeze auto-advance mid-set. `advance()` re-checks
    // `queue.count` fresh, so appends are picked up live; none of these restart
    // the current track or bump `CollectionsStore.nowPlayingRevision`.

    /// The not-yet-played tail of the queue (empty when idle or on the last track).
    var upcoming: [Item] {
        guard isRunning, index + 1 < queue.count else { return [] }
        return Array(queue[(index + 1)...])
    }

    /// Reorder within the upcoming tail (`.onMove` shape; offsets are relative to
    /// `upcoming`, i.e. 0 = the track right after the current one). Offsets are
    /// CLAMPED to the live tail: the panel's drag ends against a render-time
    /// snapshot, and a track ending mid-drag shrinks the tail underneath it —
    /// `move(fromOffsets:toOffset:)` would trap on a stale past-the-end toOffset.
    func moveUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        guard isRunning, index + 1 < queue.count else { return }
        var tail = Array(queue[(index + 1)...])
        let src = IndexSet(fromOffsets.filter(tail.indices.contains))
        guard !src.isEmpty else { return }
        tail.move(fromOffsets: src, toOffset: max(0, min(toOffset, tail.count)))
        queue.replaceSubrange((index + 1)..., with: tail)
    }

    /// Remove tracks from the upcoming tail by row IDENTITY (`Item.uid`), not by
    /// position: a ✕ tap races playback by design (the queue can advance between
    /// render and delivery), and a stale positional offset would silently delete
    /// whatever shifted into that slot. Unknown uids are ignored; only rows
    /// STRICTLY after the current track are eligible.
    func removeUpcoming(uids: Set<UUID>) {
        guard isRunning, index + 1 < queue.count, !uids.isEmpty else { return }
        var tail = Array(queue[(index + 1)...])
        tail.removeAll { uids.contains($0.uid) }
        queue.replaceSubrange((index + 1)..., with: tail)
    }

    /// Append tracks to the end of the running queue (the panel's add-search).
    /// No-op when idle: a stopped set has already torn down (`stop()` cleared the
    /// queue) — resurrecting it is a fresh `play(...)`, the caller's call.
    func appendToQueue(_ items: [Item]) {
        guard isRunning, !items.isEmpty else { return }
        queue.append(contentsOf: items)
    }

    /// Insert tracks right AFTER the current one ("Add next"). The current slot
    /// (`queue[index]`) is untouched — the insert only shifts the tail.
    func insertNextInQueue(_ items: [Item]) {
        guard isRunning, !items.isEmpty else { return }
        queue.insert(contentsOf: items, at: min(index + 1, queue.count))
    }

    /// Bump an upcoming row (by identity) to right after the current track
    /// ("Play next"). Unknown/played uids are ignored.
    func moveUpcomingNext(uid: UUID) {
        guard isRunning, index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else { return }
        let item = queue.remove(at: pos)
        queue.insert(item, at: index + 1)
    }

    /// Send an upcoming row (by identity) to the END of the queue ("Move to end").
    func moveUpcomingToEnd(uid: UUID) {
        guard isRunning, index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else { return }
        let item = queue.remove(at: pos)
        queue.append(item)
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
        // Jumped onto a new track (a manual member play) — arm ITS repeat count, not the
        // previous track's leftover, so it loops the right number of times on natural end.
        currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[pos].repeatCount)
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
        // REPEAT only on a NATURAL end: a track that played through loops in place while it has
        // plays left (a performance item's repeat count) instead of advancing. `normalizedRepeat`
        // clamps to [1, 99], so this can never spin forever; `fresh: false` keeps the counter.
        // An explicit skip or a dead source does NOT go through here — it calls `advanceToNext`.
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            Task { await playCurrent(fresh: false) }
            return
        }
        advanceToNext()
    }

    /// Natural end of an Apple Music STREAMING track (MusicKit's player finished the song).
    /// Mirrors `handleEnded` but guards on the Apple Music now-playing id (the streaming path
    /// keys off `coordinator.appleMusic.nowPlaying`, never `rips.nowPlaying`, so the local
    /// ownership guard wouldn't match). Honors the per-track repeat count, then advances.
    private func handleAppleMusicEnded() {
        guard isRunning, index < queue.count,
              coordinator.activeBackend == .appleMusic,
              coordinator.appleMusic.nowPlaying?.songId == queue[index].id else { return }
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            Task { await playCurrent(fresh: false) }
            return
        }
        advanceToNext()
    }

    /// Move to the next track (or end the set) — the NON-repeating advance. Used by an explicit
    /// skip, a dead/unresolvable source, and the end of a track's repeats.
    private func advanceToNext() {
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
            Task { await playCurrent(fresh: true) }
        }
    }

    /// Resolve the SOURCE fresh each track (a burnt file may have been purged since the
    /// queue was built) and start it. Failure (no end event will ever fire) advances now.
    private func playCurrent(fresh: Bool = true) async {
        guard isRunning, index < queue.count else { return }
        // A fresh track (index moved) arms its repeat counter; a repeat (fresh: false) keeps the
        // already-decremented one so it counts down to a single remaining play.
        if fresh { currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[index].repeatCount) }
        // Testing seam (`PDJ_HOLD_PLAYBACK`): keep the set "running" WITHOUT resolving any
        // audio source. Fixture catalogs have no rips/burns, so every track would skip and
        // the set would stop() within a frame — a UI test could never see running-state
        // surfaces (the Now Playing panel). Holding here freezes queue/index exactly as
        // `play(...)` left them. No-op in normal use.
        if ProcessInfo.processInfo.environment["PDJ_HOLD_PLAYBACK"] != nil { return }
        let it = queue[index]

        // STUDIO rows (sample/loop/pattern — spec §8): resolved via the StudioStore seam
        // BEFORE burns/coordinator, and ABOVE the device/cloud split — a studio item is a
        // LOCAL file in both modes (there is no cloud copy of a user's sample), so mode
        // must not gate it. The item's own snapshot title/artist ("Studio") label the
        // now-playing; no startMs/end boundary — studio files are per-item with a natural
        // end. Unresolvable ⇒ skip forward like any dead source.
        if StudioFactory.isStudioId(it.id) {
            guard let res = studioResolve?(it.id) else {
                advanceToNext()
                return
            }
            // A playable studio row IS on-device audio: count it so a device-mode set
            // made of loops never raises the "no burned files" banner (CRITIC-D).
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: nil, rips: rips, player: player,
                          endBoundaryMs: nil, release: res.release)
            return
        }

        let mode = playbackMode()

        // DEVICE mode: play ONLY a burned local file. A track with no burned file is SKIPPED
        // (advance now — no end event would ever fire). If the whole queue has none, the
        // end-of-set advance raises the CRITIC-D banner. Mode-flip mid-set applies to the
        // NEXT track: the current track keeps playing under the mode it started with.
        if mode == .device {
            if let res = burns.localURLForPlayback(forSong: it.id) {
                loadedAnyDeviceTrack = true
                coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
                // SHARED helper so nowPlaying + the inline player + the row toggle stay
                // consistent with the single-row burned path. `res.release` keeps a user-folder
                // file's security scope open through playback.
                playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                              startMs: burns.startMs(forSong: it.id), rips: rips, player: player,
                              endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.id)),
                              release: res.release)
                // Finite local file → the end notification (or length boundary) advances us.
            } else {
                advanceToNext()   // no on-device file for this track → skip it
            }
            return
        }

        // CLOUD mode (default): prefer a burned local file when present (zero-latency,
        // offline), else stream / rip-on-demand via the coordinator (Apple Music → rip).
        if let res = burns.localURLForPlayback(forSong: it.id) {
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: burns.startMs(forSong: it.id), rips: rips, player: player,
                          endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.id)),
                          release: res.release)
        } else {
            await coordinator.play(id: it.id, title: it.title, artist: it.artist)
            // Dead source (no server / rip error) → no end event will fire; advance now.
            if coordinator.lastErrorMessage != nil { advanceToNext(); return }
            // Apple Music STREAM: MusicKit owns the audio but writes NOTHING to the lock-screen /
            // CarPlay card and swallows the system next button (its queue is one song). Hand the
            // card + remote transport to PlayerEngine on MusicKit's behalf: it publishes
            // title/artist/artwork + the live position, and its ⏭/⏮/play-pause drive THIS set +
            // the stream. Auto-advance rides `coordinator.appleMusic.onTrackEnded` (wired in play()).
            if coordinator.activeBackend == .appleMusic {
                player.beginExternalNowPlaying(
                    title: it.title, artist: it.artist, songId: it.id,
                    durationSeconds: coordinator.appleMusic.durationSeconds > 0
                        ? coordinator.appleMusic.durationSeconds
                        : Double(it.lengthMs ?? 0) / 1000,
                    position: { [weak coordinator] in coordinator?.appleMusic.positionSeconds ?? 0 },
                    isPlaying: { [weak coordinator] in coordinator?.appleMusic.isPlaying ?? false },
                    play: { [weak coordinator] in coordinator?.appleMusic.resume() },
                    pause: { [weak coordinator] in coordinator?.appleMusic.pausePlayback() })
                return
            }
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
