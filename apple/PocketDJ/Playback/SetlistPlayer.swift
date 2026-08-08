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
        /// Edition override (a cleanOnly collection substituting the clean cut). Excluded
        /// from equality like `repeatCount` — a playback parameter, not row identity
        /// (`uid` covers instance identity).
        var variant: SongVariant? = nil
        /// Per-INSTANCE identity for live-queue rows (a song can repeat in a set, so
        /// `id` can't identify a row). Lets the Now Playing panel remove exactly the
        /// row the user tapped even when the queue shifts underneath the tap (a track
        /// ending mid-interaction). Excluded from equality — two Items for the same
        /// track are still equal.
        let uid = UUID()

        /// The id playback RESOLVES under — the variant songId when an edition override is
        /// set (burned files, rips, stems, streams all key on it), else the base id.
        /// History/stats/favorites keep keying `id` (the real song).
        var resolveId: String { variant.map { SongVariant.variantId(id, $0) } ?? id }

        /// Whether an OBSERVED now-playing id identifies THIS row — the ownership test every
        /// end-of-track / jump guard uses. A substituted row answers to BOTH of its ids
        /// because the two play paths stamp different ones: a stream / rip resolves under
        /// `resolveId` ("sng_…_clean", set by the coordinator's minimal song), while a burned
        /// file plays under the base `id` (`playLocalFile(songId: it.id)`, so the card + stats
        /// keep the real song). A plain row's two ids coincide, so it never answers to a
        /// variant id — a foreign edition of the same song stays a foreign play.
        func matches(_ observedId: String) -> Bool { observedId == id || observedId == resolveId }

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

    /// Resolves the NAVIGABLE origin collection (kind + collection id) for a run's
    /// `sourceSetlistId` — wired at app init to `CollectionsStore.originCollection`.
    /// CAPTURED at `play()` (the historyContextProvider doctrine: a later playNow must not
    /// retag this run) and PERSISTED in the durable-session snapshot, so the Up Next
    /// header's collection button re-opens the right collection even after a restore.
    @ObservationIgnored var originProvider: ((String?) -> (kind: PlayHistoryStore.PlaySource, id: String)?)?
    private(set) var capturedOrigin: (kind: PlayHistoryStore.PlaySource, id: String)?

    // MARK: Durable playback session (force-quit → relaunch restore)

    /// The durable-session store (injected at app init, like `historyContextProvider`; nil in
    /// most unit tests). Every structural change to the run — play, index move, live-queue
    /// edit — snapshots into it immediately; the playing position rides a throttled refresh.
    @ObservationIgnored var sessionStore: PlaybackSessionStore?
    /// Identity of the CURRENT run's persisted session — fresh per `play()`, re-adopted by a
    /// restore (so a restored run keeps overwriting the same snapshot).
    @ObservationIgnored private var sessionId = ""
    /// True after `restore(from:)` until the first transport action: the set is ACTIVE (the
    /// home deck renders played/current/up-next) but NO audio has started — no AVAudioSession
    /// touch, no system Now Playing card (the app isn't playing anything). The first ▶ goes
    /// through `resumeFromHold()`, which starts real playback AT the saved position.
    private(set) var isHeldForResume = false
    /// The saved mid-song position (ms from the song's 0:00) the first ▶ resumes at.
    @ObservationIgnored private var pendingResumeMs: Int?
    /// ~1 Hz position sampler feeding the store's throttled refresh while a set runs.
    @ObservationIgnored private var positionTicker: Task<Void, Never>?
    /// True when the current track is a live stream with no natural end — the UI shows a
    /// "Next" control so the set never silently freezes on it.
    private(set) var waitingForLive = false

    /// F4 — true while the Now Playing mix mini-panel has swapped the current track's audio off the
    /// `AVPlayer` into `NowPlayingDSP` (the DSP owns the audio; the AVPlayer is idle, and the system
    /// Now Playing card is published on the DSP's behalf via `PlayerEngine.beginExternalNowPlaying`,
    /// so there is still exactly ONE card writer). Ephemeral — reset to false on every track change.
    private(set) var mixEngaged = false

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

    /// Whole-session repeat mode (off / all / one) — see `RepeatMode`. Sticky across `play()`
    /// calls (a system-player convention) and restored from the durable session. `.all` wraps the
    /// queue at its end; `.one` replays the current track on natural end (an explicit ⏭ still
    /// advances). Observed by the Now Playing deck + widget; mirrored to the lock-screen /
    /// CarPlay `changeRepeatModeCommand`.
    private(set) var repeatMode: RepeatMode = .off
    /// Whether the running queue's UPCOMING tail is live-shuffled. Reset per `play()` (the new
    /// queue is presented in its given order — the one-shot `playNow(shuffle:)` handles initial
    /// randomization). Toggling ON permutes `queue[(index+1)...]`; OFF restores the tail's
    /// pre-shuffle order. Never touches the current/played region (the live-queue-edit contract).
    private(set) var shuffleEnabled = false
    /// The original relative order (by `Item.uid`) captured the FIRST time shuffle is enabled in a
    /// run, so shuffle-OFF can restore the upcoming tail's pre-shuffle order. Session-only (uids are
    /// per-instance and not persisted) — a restored run whose shuffle was on keeps its shuffled
    /// order (which is what was playing) and can't recover a pre-shuffle order it never saw.
    @ObservationIgnored private var canonicalOrder: [UUID]?

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

    /// PROFILE ("Pocket DJ") SEAM (wired at app init to `ProfileSourceStore.localURLForPlayback`):
    /// resolve a `pdj_` id to its device-local original. Same tuple as `studioResolve`; `release` is
    /// always nil (app-managed audio holds no security scope). A nil RESULT (absent local file, e.g.
    /// a metadata-synced item whose asset isn't on this device) makes the row skip forward.
    var profileResolve: ((String) -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)?)?

    /// F4 SEAM (wired at app init): the single-deck DSP engine the Now Playing mix mini-panel drives.
    /// nil in unit tests that don't exercise the hand-off. The sequencer owns the AVPlayer↔DSP swap so
    /// end-advance, the durable session, and the single-owner lock-screen card stay coherent across it.
    @ObservationIgnored var dsp: NowPlayingDSP?

    /// F4 SEAM (wired at app init): reads whether a Mix-tab session (deck / Auto-DJ) is active —
    /// `MixEngine.isRunning || autoMixing`. A Mix session and the Now Playing mix panel are mutually
    /// exclusive (one DSP surface at a time), so when this flips TRUE the panel HIDES; but a live DSP
    /// engagement would keep rendering a hidden, uncontrollable second audio source. Setting the seam
    /// arms the observation (`didSet`), which tears the engagement down the moment a Mix session starts.
    /// nil in unit tests that don't exercise the mutual exclusion (no cost then).
    @ObservationIgnored var mixSessionActive: (() -> Bool)? {
        didSet { observeMixSessionForEngagement() }
    }

    init(player: PlayerEngine, rips: RipsStore, burns: BurnStore, coordinator: PlaybackCoordinator) {
        self.player = player
        self.rips = rips
        self.burns = burns
        self.coordinator = coordinator
        // Arm the now-playing observation ONCE; it self-re-arms on every change (see
        // `adoptNowPlayingIfJumped`). Single arm avoids stacking observers across play() calls.
        observeNowPlaying()
        // Durable session: play/pause flips persist the position IMMEDIATELY (the throttled
        // ticker alone would leave the paused position up to a tick stale). Same one-shot
        // self-re-arming pattern as observeNowPlaying.
        observePlayStateForSession()
    }

    /// Observe the play/pause state of BOTH backends; on any flip, write the session
    /// position immediately (the store passes transitions through un-throttled). Armed once
    /// in `init`, self-perpetuating; a no-op while idle or held.
    private func observePlayStateForSession() {
        withObservationTracking {
            _ = player.isPlaying
            _ = coordinator.appleMusic.isPlaying
            _ = dsp?.isPlaying          // F4: while the DSP owns audio, its play/pause drives the session
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePlayStateForSession()
                guard self.isRunning, !self.isHeldForResume else { return }
                self.sessionStore?.updatePosition(ms: self.sessionPositionMs(),
                                                  isPlaying: self.sessionIsPlaying())
            }
        }
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
        capturedOrigin = originProvider?(sourceSetlistId)
        queue = items
        index = 0
        // Live shuffle is per-run (repeat mode is sticky). The one-shot `playNow(shuffle:)` already
        // randomized the incoming order when requested; the live toggle starts OFF for the new queue.
        shuffleEnabled = false
        canonicalOrder = nil
        isRunning = true
        deviceQueueUnplayable = false   // fresh run — clear any prior banner signal
        loadedAnyDeviceTrack = false
        // A fresh play over a restored-but-held deck simply replaces it (the natural expiry).
        isHeldForResume = false
        pendingResumeMs = nil
        armEngineHooks()
        // Durable session: a fresh run gets a fresh identity + an immediate snapshot, and the
        // ~1 Hz position sampler starts feeding the store's throttled refresh.
        sessionId = "pses_" + UUID().uuidString
        persistSession(positionMs: 0)
        startPositionTicker()
        Task { await playCurrent() }
    }

    /// Own the engines' end hooks + lock-screen next/previous while running (released in
    /// `stop()`). Shared by `play()`, `resumeFromHold()`, and the held-state exits — a
    /// RESTORED (held) deck deliberately does NOT arm these until real playback starts.
    private func armEngineHooks() {
        // The lock screen / Control Center next/prev advance the SET.
        player.onTrackEnded = { [weak self] in self?.handleEnded() }
        player.onNext = { [weak self] in self?.skipNext() }
        player.onPrevious = { [weak self] in self?.skipPrevious() }
        player.setNextPreviousEnabled(true)
        // Lock-screen / Control Center / CarPlay repeat + shuffle (the system Now Playing card's
        // changeRepeatMode / changeShuffleMode commands) drive the SET's modes while it runs. Only
        // enabled while a set is running, so a single-song play shows no repeat/shuffle glyphs.
        player.onRepeatModeChange = { [weak self] in self?.setRepeatMode($0) }
        player.onShuffleChange = { [weak self] in self?.setShuffle($0) }
        player.setRepeatShuffleCommandsEnabled(true)
        player.setRemoteRepeatMode(repeatMode)
        player.setRemoteShuffle(shuffleEnabled)
        // Apple Music STREAMS through MusicKit's own player, which the PlayerEngine end hook
        // above never sees — so wire its end-of-track straight into the sequencer's advance,
        // else the set freezes after the first streamed song.
        coordinator.appleMusic.onTrackEnded = { [weak self] in self?.handleAppleMusicEnded() }
        // The system remote ⏮ during a stream also lands in MusicKit (it rewinds its one-song
        // queue to 0:00); the provider detects the rewind and fires this so ⏮ steps the SET back.
        coordinator.appleMusic.onTrackRestarted = { [weak self] in self?.handleAppleMusicRestarted() }
    }

    /// Stop the sequence + clear now-playing; resets so the toolbar flips back to Play.
    func stop() {
        endMixEngagement()                 // F4: drop any DSP hand-off before tearing the run down
        isRunning = false
        waitingForLive = false
        player.onTrackEnded = nil          // release ownership of the shared hook
        player.onNext = nil
        player.onPrevious = nil
        player.setNextPreviousEnabled(false)
        player.onRepeatModeChange = nil
        player.onShuffleChange = nil
        player.setRepeatShuffleCommandsEnabled(false)
        coordinator.appleMusic.onTrackEnded = nil
        coordinator.appleMusic.onTrackRestarted = nil
        player.stop()
        coordinator.stop()
        rips.setNowPlaying(nil)
        index = 0
        queue = []
        sourceSetlistId = nil
        capturedHistoryContext = nil
        capturedOrigin = nil
        // Durable session: a stopped set (natural end included) must NOT rehydrate next launch.
        positionTicker?.cancel(); positionTicker = nil
        isHeldForResume = false
        pendingResumeMs = nil
        sessionId = ""
        sessionStore?.clear()
    }

    /// Acknowledge + clear the one-shot device-unplayable banner (the surface calls this
    /// once it has shown the transient message).
    func clearDeviceUnplayable() { deviceQueueUnplayable = false }

    /// Manually advance (used by the live-track "Next" affordance + lock-screen NEXT).
    func skipNext() {
        exitHoldIfNeeded()
        advanceToNext()
    }

    /// Manually go back one track (lock-screen PREVIOUS). No-op past the top of the set; never
    /// goes below index 0. Re-resolves + plays the (now) current track.
    func skipPrevious() {
        guard isRunning else { return }
        exitHoldIfNeeded()
        waitingForLive = false
        if index == 0 {
            // Repeat-ALL wraps ⏮ from the top back to the last track; otherwise stay at 0
            // (⏮ on the first track restarts it — today's `max(0, index-1)` behaviour).
            if repeatMode == .all, queue.count > 1 { index = queue.count - 1 }
        } else {
            index -= 1
        }
        persistSession(positionMs: 0)
        Task { await playCurrent() }
    }

    // MARK: - Repeat & shuffle (Now Playing deck / widget / lock-screen)

    /// Cycle the whole-session repeat mode off → all → one → off (the Now Playing / widget repeat
    /// button). Sticky across runs; persisted; mirrored to the lock-screen / CarPlay card.
    func cycleRepeatMode() { setRepeatMode(repeatMode.next) }

    /// Set the whole-session repeat mode explicitly (the lock-screen / CarPlay changeRepeatMode
    /// command routes here). No-op when unchanged. Safe while idle/held — the mode simply rides
    /// the next run; only a running set persists it.
    func setRepeatMode(_ mode: RepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        player.setRemoteRepeatMode(mode)
        persistSession()
    }

    /// Toggle live shuffle of the upcoming tail (the Now Playing / widget shuffle button).
    func toggleShuffle() { setShuffle(!shuffleEnabled) }

    /// Enable/disable live shuffle of the UPCOMING tail (`queue[(index+1)...]`). ON permutes the
    /// tail (remembering the pre-shuffle order the first time); OFF restores that order. Never
    /// touches `queue[index]` or the played head — the same contract every live-queue edit honors.
    /// The lock-screen / CarPlay changeShuffleMode command routes here.
    func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        if on {
            if canonicalOrder == nil { canonicalOrder = queue.map(\.uid) }
            shuffleUpcomingTail()
        } else {
            restoreUpcomingOrder()
        }
        player.setRemoteShuffle(on)
        persistSession()
    }

    /// Permute the upcoming tail in place (never the current/played region).
    private func shuffleUpcomingTail() {
        guard isRunning, index + 1 < queue.count else { return }
        var tail = Array(queue[(index + 1)...])
        tail.shuffle()
        queue.replaceSubrange((index + 1)..., with: tail)
    }

    /// Restore the upcoming tail to its captured pre-shuffle relative order. Items added AFTER the
    /// shuffle (unknown to `canonicalOrder`) sort to the end, preserving their arrival order.
    private func restoreUpcomingOrder() {
        guard let canon = canonicalOrder, isRunning, index + 1 < queue.count else { return }
        let rank = Dictionary(canon.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var tail = Array(queue[(index + 1)...])
        tail.sort { (rank[$0.uid] ?? Int.max) < (rank[$1.uid] ?? Int.max) }
        queue.replaceSubrange((index + 1)..., with: tail)
    }

    /// Reshuffle the ENTIRE queue (used on a repeat-all wrap, where every item is upcoming again).
    private func reshuffleEntireQueue() {
        guard queue.count > 1 else { return }
        queue.shuffle()
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

    /// The already-played head of the queue (`queue[0..<index]`, oldest first) — the
    /// "previously played" list behind the Now Playing panel's history toggle. Pure
    /// projection: played rows stay in the queue (`advanceToNext` only moves the index)
    /// and ride every durable-session snapshot, so a restored run keeps its history.
    var played: [Item] {
        guard isRunning, index > 0 else { return [] }
        return Array(queue[..<min(index, queue.count)])
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
        persistSession()
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
        persistSession()
    }

    /// Append tracks to the end of the running queue (the panel's add-search).
    /// No-op when idle: a stopped set has already torn down (`stop()` cleared the
    /// queue) — resurrecting it is a fresh `play(...)`, the caller's call.
    func appendToQueue(_ items: [Item]) {
        guard isRunning, !items.isEmpty else { return }
        queue.append(contentsOf: items)
        persistSession()
    }

    /// Insert tracks right AFTER the current one ("Add next"). The current slot
    /// (`queue[index]`) is untouched — the insert only shifts the tail.
    func insertNextInQueue(_ items: [Item]) {
        guard isRunning, !items.isEmpty else { return }
        queue.insert(contentsOf: items, at: min(index + 1, queue.count))
        persistSession()
    }

    /// Insert tracks at a RANDOM slot in the upcoming tail (Jukebox Hero's "Surprise
    /// Slot"): anywhere from right after the current track to the very end, uniformly.
    /// Same contract as the other live edits — only the tail moves, never `queue[index]`.
    /// The slot is injectable so tests pin it; production uses the full-range default.
    func insertRandomInQueue(_ items: [Item],
                             slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        guard isRunning, !items.isEmpty else { return }
        let lo = min(index + 1, queue.count)
        queue.insert(contentsOf: items, at: slot(lo...queue.count))
        persistSession()
    }

    /// Bump an upcoming row (by identity) to right after the current track
    /// ("Play next"). Unknown/played uids are ignored.
    func moveUpcomingNext(uid: UUID) {
        guard isRunning, index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else { return }
        let item = queue.remove(at: pos)
        queue.insert(item, at: index + 1)
        persistSession()
    }

    /// Send an upcoming row (by identity) to the END of the queue ("Move to end").
    func moveUpcomingToEnd(uid: UUID) {
        guard isRunning, index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else { return }
        let item = queue.remove(at: pos)
        queue.append(item)
        persistSession()
    }

    /// Shift playback to an upcoming row (by identity) — an Up-Next "Play now". Moves the
    /// index straight onto EXACTLY the tapped row (uid, not songId — a song can repeat in a
    /// set) and starts it through the SAME play-current path a skip uses, so source routing
    /// (burned file vs stream vs Apple Music), history recording, and the system card all
    /// behave identically to a normal ⏭. `playCurrent(fresh:)` arms the row's repeat count +
    /// end boundary. Rows jumped over simply land in the played region (`queue[0..<index]`)
    /// — NOT recorded as played (history records on track start). An unknown/played uid is a
    /// safe no-op: the tap races playback by design (the queue can shift underneath it).
    func jumpToUpcoming(uid: UUID) {
        guard isRunning, index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else { return }
        exitHoldIfNeeded()
        waitingForLive = false
        index = pos
        persistSession(positionMs: 0)
        Task { await playCurrent() }
    }

    /// "PLAY NOW" — start `item` immediately, interrupting whatever is playing, and let the queue
    /// carry on from where it was afterwards.
    ///
    /// Deliberately DISTINCT from `jumpToPlayed` (which is "Rewind to here"). Play-now does not move
    /// the needle backwards: it splices a FRESH copy of the track in right after the current row and
    /// steps onto it, so the interrupted track stays in the played region and the tail that was
    /// coming up is untouched. Rewinding, by contrast, replays everything from the chosen point
    /// forward. Both are offered on a played row because they answer different questions — "play
    /// that again right now" vs "take me back to there".
    ///
    /// The caller passes a fresh `Item` (a new uid): reusing the tapped row's would put a duplicate
    /// per-instance identity in the queue, which the uid-keyed live-queue edits rely on being unique.
    func playNow(_ item: Item) {
        guard isRunning else { return }
        exitHoldIfNeeded()
        waitingForLive = false
        let at = min(index + 1, queue.count)
        queue.insert(item, at: at)
        index = at
        persistSession(positionMs: 0)
        // `fresh: true` (the default) is LOAD-BEARING here, not incidental: the index moved to a
        // different track, and `fresh` is what tears down an F4 Now Playing mix engagement. Passing
        // false left the DSP rendering the INTERRUPTED track while the AVPlayer started this one —
        // two songs at once, breaking the one-audio-owner rule — and left `dsp.onReachedEnd` armed,
        // so the old track's end fired an advance that skipped the very track the user asked to
        // play now. `adoptNowPlayingIfJumped`'s double-audio guard can't rescue it either: it
        // early-returns because the index already points at the row now-playing publishes.
        // (The other `fresh: false` callers all stay on the SAME row, which is why they're safe.)
        // fresh also arms the repeat counter from `queue[index]` — which IS this item, so nothing
        // needs arming by hand.
        Task { await playCurrent() }
    }

    /// Shift playback BACK onto a played row (by identity) — "Rewind to here".
    /// `jumpToUpcoming` mirrored at the head: the needle lands exactly on the tapped row and
    /// the rows between it and the old current return to the upcoming tail (the same region a
    /// repeated ⏮ walks, one tap). Unknown/current/upcoming uids are a safe no-op — the tap
    /// races playback by design.
    func jumpToPlayed(uid: UUID) {
        guard isRunning, index > 0,
              let pos = queue[..<min(index, queue.count)].firstIndex(where: { $0.uid == uid }) else { return }
        exitHoldIfNeeded()
        waitingForLive = false
        index = pos
        persistSession(positionMs: 0)
        Task { await playCurrent() }
    }

    // MARK: - F4 Mix mini-panel (AVPlayer ↔ NowPlayingDSP hand-off)

    /// Whether the CURRENT track can be mixed — i.e. the actual playing source is a LOCAL file (a
    /// burned or studio track), not Apple Music, not a live stream, not a rip STREAM of an also-burned
    /// song. Keyed off `RipsStore.nowPlaying.url` being a file URL (the source the player ACTUALLY
    /// loaded), so a stream never offers mix even when a burned copy also exists. The Mix-tab exclusion
    /// (one DSP surface at a time) is applied by the caller via `mixAvailable(mixActive:)`.
    var currentTrackMixable: Bool {
        guard isRunning, index < queue.count, !isHeldForResume else { return false }
        guard coordinator.activeBackend != .appleMusic, !player.isLive else { return false }
        guard let np = rips.nowPlaying, queue[index].matches(np.songId), !np.live, np.url.isFileURL else { return false }
        // A local file is playing (burned OR studio). Studio ids have no BurnStore file but ARE local.
        // The burn lookup keys `resolveId` (a substituted row's file lives under the variant id)
        // even though `np.songId` is the base — the same split `playCurrent` resolves through.
        return StudioFactory.isStudioId(np.songId) || burns.localURL(forSong: queue[index].resolveId) != nil
    }

    /// The full F4 eligibility gate: mixable current track AND no active Mix-tab session (mutually
    /// exclusive — one DSP surface). The view passes `mix.isRunning || mix.autoMixing` for `mixActive`.
    func mixAvailable(mixActive: Bool) -> Bool { currentTrackMixable && !mixActive }

    /// FIRST touch of a mix control: swap the current track's audio off the `AVPlayer` into
    /// `NowPlayingDSP` AT the current position, and publish the DSP's card through `PlayerEngine`'s
    /// external-source path so the lock-screen/CarPlay card keeps exactly ONE writer (the same
    /// mechanism the Apple Music hand-off uses). Idempotent — a no-op once engaged, or when the track
    /// isn't mixable / the DSP isn't wired. A brief, possibly-audible transition is accepted.
    func engageMix() {
        guard isRunning, index < queue.count, !mixEngaged, let dsp, currentTrackMixable,
              let np = rips.nowPlaying else { return }
        let it = queue[index]
        let startSec = Double(np.startMs ?? 0) / 1000
        let atSeconds = max(0, player.currentTime - startSec)   // AVPlayer clock is absolute-in-file
        let wasPlaying = player.isPlaying
        dsp.onReachedEnd = { [weak self] in self?.handleDSPEnded() }
        // 1) Open the file WITHOUT sounding yet (`play: false`) so `dsp.duration` is known — the
        //    AVPlayer is still the only voice at this instant, so no double-audio. This must precede
        //    the card publish so a per-song local track whose catalog `lengthMs` is nil still gets a
        //    real card duration (the DSP slice length) instead of a 0-length card with no scrubber.
        dsp.engage(url: np.url, startMs: np.startMs, lengthMs: it.lengthMs,
                   atSeconds: atSeconds, songId: it.id, play: false)
        // 2) Idle the AVPlayer + claim the card (beginExternalNowPlaying pauses it + replaces its item),
        //    now with the correct duration in hand — single card writer preserved.
        player.beginExternalNowPlaying(
            title: it.title, artist: it.artist, songId: it.id,
            durationSeconds: it.lengthMs.map { Double($0) / 1000 } ?? dsp.duration,
            position: { [weak dsp] in dsp?.currentTime ?? 0 },
            isPlaying: { [weak dsp] in dsp?.isPlaying ?? false },
            play: { [weak dsp] in dsp?.resume() },
            pause: { [weak dsp] in dsp?.pause() })
        // 3) Only now that the AVPlayer is idle, start the DSP audio if we were playing — so exactly one
        //    engine ever sounds during the swap.
        if wasPlaying { dsp.resume() }
        mixEngaged = true
        NPLog.trace("setlist ENGAGE mix → DSP id=\(it.id) at=\(Int(atSeconds))s playing=\(wasPlaying)")
        persistSession()
    }

    /// The DSP's slice reached its natural end (while it owns the audio) — mirror `handleEnded`: honor
    /// the per-track repeat count, else advance. Either way the DSP is torn down first so the next
    /// track (or the repeat) plays cleanly through the AVPlayer.
    private func handleDSPEnded() {
        guard mixEngaged, isRunning, index < queue.count else { return }
        endMixEngagement()
        // Repeat-ONE: replay the current track from the top (through the AVPlayer) instead of
        // advancing. Only on a NATURAL end — an explicit ⏭ goes through `advanceToNext`.
        if repeatMode == .one {
            Task { await playCurrent(fresh: true) }
            return
        }
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            Task { await playCurrent(fresh: false) }   // reloads the AVPlayer for the repeat
            return
        }
        advanceToNext()
    }

    /// Tear down the DSP hand-off WITHOUT reloading (the caller — a track change / repeat / stop — then
    /// loads the next source through the AVPlayer, which reclaims the card via `player.load`). Resets
    /// the ephemeral control state. A no-op when not engaged.
    private func endMixEngagement() {
        guard mixEngaged else { return }
        dsp?.onReachedEnd = nil
        dsp?.disengage()
        dsp?.resetControls()
        mixEngaged = false
    }

    /// Observe the Mix-tab session seam; when it flips ACTIVE while the Now Playing mix panel is
    /// engaged, tear the DSP hand-off down (the panel hides in that state, so a still-rendering DSP
    /// would be a hidden second audio source alongside the Mix decks). Hands the current track's audio
    /// backend back to the idle AVPlayer via `endMixEngagement`. Self-re-arming one-shot tracking
    /// (mirrors `observeNowPlaying`), first armed by the `mixSessionActive` `didSet`. A no-op — so it
    /// never loops — when no seam is wired, nothing is engaged, or the session isn't active.
    @MainActor
    private func observeMixSessionForEngagement() {
        withObservationTracking {
            _ = mixSessionActive?()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeMixSessionForEngagement()
                if self.mixEngaged, self.mixSessionActive?() == true { self.endMixEngagement() }
            }
        }
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
        for i in queue.indices where queue[i].matches(id) {
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
            // An Apple Music row ▶ never touches `rips.nowPlaying` — its identity lands on
            // the coordinator instead. Track it (and the backend flip, which arrives one
            // main-actor turn later) so AM jumps adopt exactly like rip/burned ones.
            _ = coordinator.appleMusic.nowPlaying?.songId
            _ = coordinator.activeBackend
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
        // The manual play's identity comes from whichever backend OWNS the audio: an Apple
        // Music row ▶ sets `coordinator.appleMusic.nowPlaying`, never `rips.nowPlaying` —
        // keying off the rip path alone left AM jumps unadopted (deck + widget stale on the
        // old track, transport routed to the idle engine, end guard silently stopping the set).
        let am = coordinator.activeBackend == .appleMusic
        // `matches` (not `id ==`): the sequencer's OWN substituted play resolves under the
        // VARIANT id ("sng_…_clean"), which must stay a no-op here — treating it as a foreign
        // jump would run `endMixEngagement` against our own track.
        guard let npId = am ? coordinator.appleMusic.nowPlaying?.songId : rips.nowPlaying?.songId,
              !queue[index].matches(npId) else { return }
        // F4 (double-audio guard): ANY nowPlaying change to a DIFFERENT track means the AVPlayer / AM
        // now owns that track's audio (its play path already reclaimed the card) — so tear down any
        // orphaned DSP engagement here, BEFORE the not-in-set early return below. Otherwise a NON-member
        // single-row play (a Browse/collection single) would return early with the DSP still rendering
        // the OLD set track → two songs at once. A non-member play thus stops the DSP while leaving the
        // set index untouched (matching pre-F4, where the single reused the same AVPlayer and stopped
        // the set audio); the in-set adopt below then proceeds unchanged.
        endMixEngagement()
        guard let pos = nearestOccurrence(of: npId, to: index) else { return }   // not in set
        NPLog.trace("setlist ADOPT jump → index \(pos) id=\(npId) via \(am ? "appleMusic" : "rip")")
        // A manual member play makes a RESTORED (held) deck live: real audio is sounding, so
        // arm the end hooks + position sampler exactly as a resume would.
        exitHoldIfNeeded()
        index = pos
        waitingForLive = false
        persistSession(positionMs: 0)
        // Jumped onto a new track (a manual member play) — arm ITS repeat count, not the
        // previous track's leftover, so it loops the right number of times on natural end.
        currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[pos].repeatCount)
        if am {
            // The row ▶ started the stream but knows nothing about cards — run the same
            // handoff `playCurrent`'s AM branch does (macOS: abdicate; iOS: impersonate).
            handOffCardToAppleMusic(for: queue[pos])
        } else {
            // `resolveId`: a substituted row's burned file lives under the variant id.
            if burns.localURL(forSong: queue[pos].resolveId) != nil { loadedAnyDeviceTrack = true }
            player.setEndBoundary(ms: sharedFileEndBoundaryMs(queue[pos], startMs: rips.nowPlaying?.startMs))
        }
    }

    /// Hand the system Now Playing card to the Apple Music stream for `it` — the shared tail
    /// of BOTH ways a set lands on an AM track (our own `playCurrent` and adopting a manual
    /// row ▶). On iOS/CarPlay MusicKit writes NOTHING to the card and swallows ⏭ (its queue
    /// is one song), so PlayerEngine impersonates it (title/artist/artwork + live position;
    /// ⏭/⏮/play-pause drive THIS set + the stream). On macOS MusicKit's
    /// ApplicationMusicPlayer ALREADY publishes a full Control Center entry, so a second
    /// writer would show a DUPLICATE source — there our engine only goes inert.
    private func handOffCardToAppleMusic(for it: Item) {
        #if os(macOS)
        player.idleForExternalPlayback()
        #else
        player.beginExternalNowPlaying(
            title: it.title, artist: it.artist, songId: it.id,
            durationSeconds: coordinator.appleMusic.durationSeconds > 0
                ? coordinator.appleMusic.durationSeconds
                : Double(it.lengthMs ?? 0) / 1000,
            position: { [weak coordinator] in coordinator?.appleMusic.positionSeconds ?? 0 },
            isPlaying: { [weak coordinator] in coordinator?.appleMusic.isPlaying ?? false },
            play: { [weak coordinator] in coordinator?.appleMusic.resume() },
            pause: { [weak coordinator] in coordinator?.appleMusic.pausePlayback() })
        #endif
    }

    /// Natural end-of-track. OWNERSHIP GUARD: ignore a stray end-event from an unrelated /
    /// manual single-row play (which changes `rips.nowPlaying`), so only OUR current track
    /// auto-advances. A manual play of an IN-SET track is first adopted by
    /// `adoptNowPlayingIfJumped` (index moves onto it), so this guard then passes for it.
    private func handleEnded() {
        guard isRunning, index < queue.count,
              let npId = rips.nowPlaying?.songId, queue[index].matches(npId) else { return }
        // Repeat-ONE (whole-session mode) takes precedence: replay the current track from the top.
        // Only on a NATURAL end — an explicit ⏭ / dead source goes through `advanceToNext`.
        if repeatMode == .one {
            Task { await playCurrent(fresh: true) }
            return
        }
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
              let npId = coordinator.appleMusic.nowPlaying?.songId,
              queue[index].matches(npId) else { return }
        // Repeat-ONE (whole-session mode): replay the current AM track from the top.
        if repeatMode == .one {
            Task { await playCurrent(fresh: true) }
            return
        }
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            Task { await playCurrent(fresh: false) }
            return
        }
        advanceToNext()
    }

    /// The system remote ⏮ during an Apple Music stream (detected as MusicKit's one-song-queue
    /// rewind — see `AppleMusicPlaybackProvider.trackRestarted`). Same ownership guard as
    /// `handleAppleMusicEnded`, then the in-app ⏮ semantics: step the set back one track.
    private func handleAppleMusicRestarted() {
        guard isRunning, index < queue.count,
              coordinator.activeBackend == .appleMusic,
              let npId = coordinator.appleMusic.nowPlaying?.songId,
              queue[index].matches(npId) else { return }
        NPLog.trace("setlist AM restart → skipPrevious from index \(index)")
        skipPrevious()
    }

    /// Move to the next track (or end the set) — the NON-repeating advance. Used by an explicit
    /// skip, a dead/unresolvable source, and the end of a track's repeats.
    private func advanceToNext() {
        guard isRunning else { return }
        waitingForLive = false
        index += 1
        if index >= queue.count {
            // Repeat-ALL: wrap to the top and keep going instead of stopping. (Repeat-ONE is
            // handled on natural end in the `handle*Ended` paths, so it never reaches here; an
            // explicit ⏭ past the end with repeat-one/off still stops.)
            if repeatMode == .all, !queue.isEmpty {
                index = 0
                // Reshuffle the whole queue on a shuffle wrap so the next pass differs (standard
                // player behaviour); `canonicalOrder` is untouched so shuffle-OFF still restores.
                if shuffleEnabled { reshuffleEntireQueue() }
                persistSession(positionMs: 0)
                Task { await playCurrent(fresh: true) }
                return
            }
            // CRITIC-D — a DEVICE-mode set that reached the end having never loaded a single
            // burned file: raise the one-shot banner so the surface tells the DJ nothing was
            // playable on-device (rather than silently ending with no audio).
            let unplayable = playbackMode() == .device && !loadedAnyDeviceTrack
            stop()                          // reached the end — tear down cleanly (clears the session)
            if unplayable { deviceQueueUnplayable = true }
        } else {
            persistSession(positionMs: 0)
            Task { await playCurrent(fresh: true) }
        }
    }

    /// Resolve the SOURCE fresh each track (a burnt file may have been purged since the
    /// queue was built) and start it. Failure (no end event will ever fire) advances now.
    /// `resumeAtMs` (restore-resume only) starts the track mid-song — it rides every source
    /// branch's existing cue seam (`playLocalFile(atMs:)` / `coordinator.play(atMs:)`), so
    /// boundaries and history behave exactly like a normal start.
    private func playCurrent(fresh: Bool = true, resumeAtMs: Int? = nil) async {
        guard isRunning, index < queue.count else { return }
        // F4: a NEW track (index moved) supersedes any Now Playing mix engagement — tear the DSP down
        // and reset controls BEFORE loading the new source (the load reclaims the card off the AVPlayer).
        // A repeat / hand-back (fresh: false) keeps the current engagement.
        if fresh { endMixEngagement() }
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
                          endBoundaryMs: nil, atMs: resumeAtMs, release: res.release)
            return
        }

        // PROFILE ("Pocket DJ") rows: device-local original resolved via the profileResolve seam,
        // ABOVE the device/cloud split like studio rows — a profile item is a local file in both
        // modes. `pdj_` is outside StudioFactory.studioPrefixes, so this never collides with the
        // studio arm; unresolvable (absent asset) ⇒ skip forward.
        if ProfileSourceStore.isProfileSongId(it.id) {
            guard let res = profileResolve?(it.id) else {
                advanceToNext()
                return
            }
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: nil, rips: rips, player: player,
                          endBoundaryMs: nil, atMs: resumeAtMs, release: res.release)
            return
        }

        let mode = playbackMode()

        // DEVICE mode: play ONLY a burned local file. A track with no burned file is SKIPPED
        // (advance now — no end event would ever fire). If the whole queue has none, the
        // end-of-set advance raises the CRITIC-D banner. Mode-flip mid-set applies to the
        // NEXT track: the current track keeps playing under the mode it started with.
        if mode == .device {
            // `resolveId` (NOT `id`) at every burned-file lookup: a cleanOnly substitution
            // must play the CLEAN variant's burned file — an explicit base burn present on
            // the device is deliberately not a fallback (skip-not-fallback). `songId: it.id`
            // (base) stays in playLocalFile so history/stats key the real song.
            if let res = burns.localURLForPlayback(forSong: it.resolveId) {
                loadedAnyDeviceTrack = true
                coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
                // SHARED helper so nowPlaying + the inline player + the row toggle stay
                // consistent with the single-row burned path. `res.release` keeps a user-folder
                // file's security scope open through playback.
                playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                              startMs: burns.startMs(forSong: it.resolveId), rips: rips, player: player,
                              endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.resolveId)),
                              atMs: resumeAtMs, release: res.release)
                // Finite local file → the end notification (or length boundary) advances us.
            } else {
                advanceToNext()   // no on-device file for this track → skip it
            }
            return
        }

        // CLOUD mode (default): prefer a burned local file when present (zero-latency,
        // offline), else stream / rip-on-demand via the coordinator (Apple Music → rip).
        // Same `resolveId` rule as device mode — a substituted row only ever plays its
        // variant's audio (burned, streamed, or ripped), never the base explicit cut.
        if let res = burns.localURLForPlayback(forSong: it.resolveId) {
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: burns.startMs(forSong: it.resolveId), rips: rips, player: player,
                          endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: burns.startMs(forSong: it.resolveId)),
                          atMs: resumeAtMs, release: res.release)
        } else {
            await coordinator.play(id: it.id, title: it.title, artist: it.artist,
                                   atMs: resumeAtMs, variant: it.variant)
            // Dead source (no server / rip error) → no end event will fire; advance now.
            if coordinator.lastErrorMessage != nil { advanceToNext(); return }
            // Apple Music STREAM: MusicKit owns the audio. On iOS/CarPlay it writes NOTHING to
            // the system card and swallows the next button (its queue is one song), so we hand the
            // card + remote transport to PlayerEngine on MusicKit's behalf (title/artist/artwork +
            // live position; ⏭/⏮/play-pause drive THIS set + the stream). On macOS, MusicKit's
            // ApplicationMusicPlayer ALREADY publishes a full Control Center Now Playing entry, so
            // taking over would show a DUPLICATE second source — there we only idle our AVPlayer.
            // Auto-advance rides `coordinator.appleMusic.onTrackEnded` (wired in play()) either way.
            if coordinator.activeBackend == .appleMusic {
                handOffCardToAppleMusic(for: it)
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

    // MARK: - Durable playback session (persist + restore)

    /// Relaunch entry point (RootView's launch task): rehydrate the deck from the persisted
    /// snapshot — HELD, never auto-playing. Skipped when a set is already running or any
    /// backend already owns audio (the app was launched by an App Intent / widget that
    /// started playback first), and under the `PDJ_DISABLE_SESSION_RESTORE` seam.
    func restorePersistedSessionIfIdle() {
        guard let sessionStore else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["PDJ_DISABLE_SESSION_RESTORE"] == nil else { return }
        guard !isRunning, coordinator.activeBackend == nil, !player.isPlaying else { return }
        sessionStore.seedFixtureIfRequested()
        guard let snap = sessionStore.load() else { return }
        restore(from: snap)
    }

    /// Rebuild the run from a snapshot: fresh-uid queue, index cursor, source identity, and
    /// the captured history context — marked ACTIVE-BUT-HELD so the Now Playing home deck
    /// (and the widget / CarPlay Up Next) render played/current/up-next, WITHOUT starting
    /// audio, touching AVAudioSession, or claiming the system Now Playing card (the
    /// one-audio-owner rule: the card belongs to whoever is actually sounding — nobody yet).
    /// The engine hooks stay un-armed until real playback starts (`resumeFromHold` /
    /// skip / jump), mirroring the `PDJ_HOLD_PLAYBACK` discipline. First ▶ resumes AT the
    /// saved position; everything after that is a 100% normal run. No-op mid-run.
    func restore(from snap: PlaybackSessionStore.Snapshot) {
        guard !isRunning, !snap.queue.isEmpty else { return }
        queue = snap.queue.map {
            Item(id: $0.songId, title: $0.title, artist: $0.artist,
                 lengthMs: $0.lengthMs, repeatCount: $0.repeatCount,
                 variant: $0.variant.flatMap(SongVariant.init(rawValue:)))
        }
        index = min(max(0, snap.index), queue.count - 1)
        // A Collectors Puzzle run tags the sequencer with `puzzle_<roundId>` — but the round
        // engine does NOT survive a relaunch, so a restored run-tag is a ghost: it would make
        // every surface that treats the tag as "a live round owns the sequencer" (the MwF
        // queue-accepted append, for one) silently refuse forever. The QUEUE restores fine;
        // the round identity must not.
        let restoredSourceId = snap.source.id
        sourceSetlistId = restoredSourceId?.hasPrefix(CollectorsPuzzleEngine.runTagPrefix) == true
            ? nil : restoredSourceId
        // Reconstruct the run's history origin from the stored kind + name, so plays after
        // the resume are attributed to the same set the pre-kill plays were.
        capturedHistoryContext = (PlayHistoryStore.PlaySource(rawValue: snap.source.kind) ?? .setlist,
                                  snap.source.name)
        // And the NAVIGABLE origin — the Up Next collection button's ghost-state fix: a
        // restored session still knows which collection it came from.
        if let ok = snap.source.originKind, let kind = PlayHistoryStore.PlaySource(rawValue: ok),
           let oid = snap.source.originId {
            capturedOrigin = (kind, oid)
        } else {
            capturedOrigin = nil
        }
        sessionId = snap.sessionId
        pendingResumeMs = snap.positionMs > 0 ? snap.positionMs : nil
        // Repeat/shuffle ride the snapshot (optional → default off/false for pre-existing files).
        // The queue's shuffled ORDER is already baked into `snap.queue`; only the toggle state is
        // reconstructed here. Seed `canonicalOrder` from the restored order so a later shuffle-OFF
        // has a target (best-effort — the true pre-shuffle order isn't persisted). The lock-screen
        // command state is (re)pushed by `armEngineHooks` when real playback starts.
        repeatMode = RepeatMode(rawValue: snap.repeatMode ?? "") ?? .off
        shuffleEnabled = snap.shuffleEnabled ?? false
        canonicalOrder = shuffleEnabled ? queue.map(\.uid) : nil
        currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[index].repeatCount)
        deviceQueueUnplayable = false
        loadedAnyDeviceTrack = false
        waitingForLive = false
        isHeldForResume = true
        isRunning = true
        // A RESTORE IS NOT A WRITE. This used to end in `persistSession()`, which re-adopted the
        // snapshot as the store's current session — and in doing so rewrote the session FILE.
        // That one line caused two user-visible bugs, because the file's mtime is the ONLY key
        // ordering the session document across devices (CloudSyncService compares mtimes; the
        // payload's own `updatedAt` is written but never read):
        //
        //  • CARPLAY WIPED A GOOD SESSION. A CarPlay scene restores without ever having pulled
        //    from iCloud first (the launch pull lives in RootView's task, which a template scene
        //    never runs), so the restore-write pushed the local copy over a newer cloud one.
        //  • A DEVICE UNTOUCHED FOR DAYS STOLE THE SESSION. Merely OPENING the app stamped the
        //    file to "now", so the stale device won the next sync and the real session was lost.
        //
        // Leaving `current` nil is what makes this safe rather than merely quieter: `flush()` and
        // `updatePosition()` both guard on `current`, so the file is untouched until playback
        // actually starts (`resumeFromHold`, or any skip/jump through the normal persist paths).
        // The mtime therefore now means "last actually played here", which is exactly the
        // liveness ordering the sync needs — no extra timestamp field required.
        NPLog.trace("setlist RESTORE held session=\(sessionId) index=\(index)/\(queue.count) resumeMs=\(pendingResumeMs ?? 0)")
    }

    /// The first ▶ after a restore: arm the engine hooks, then start REAL playback of the
    /// current track AT the saved position (local files seek via `playLocalFile(atMs:)`;
    /// Apple Music re-plays + seeks via the coordinator's cue seam). The playback surfaces
    /// (NowPlayingPanel / WidgetSync) route their play-toggle here while `isHeldForResume`.
    func resumeFromHold() {
        guard isRunning, isHeldForResume else { return }
        isHeldForResume = false
        armEngineHooks()
        startPositionTicker()
        let at = pendingResumeMs
        pendingResumeMs = nil
        // NOW the session is live on this device, so adopt it into the store — this is the write
        // `restore(from:)` deliberately no longer makes. It must happen here and not be left to
        // the position ticker: `updatePosition` no-ops while `current` is nil, so without this the
        // resumed set would never persist its position at all. Passing the resume offset keeps a
        // kill immediately after ▶ resuming where the user actually was, not at 0:00.
        persistSession(positionMs: at)
        // fresh: false — restore() already armed the current row's repeat counter.
        Task { await playCurrent(fresh: false, resumeAtMs: at) }
    }

    /// A held deck acted on by anything OTHER than ▶ (skip / jump / a manual member play):
    /// drop the pending resume position and go live — arm the hooks + position sampler so
    /// the action's playback behaves exactly like a normal run's. No-op when not held.
    private func exitHoldIfNeeded() {
        guard isHeldForResume else { return }
        isHeldForResume = false
        pendingResumeMs = nil
        armEngineHooks()
        startPositionTicker()
    }

    // MARK: Session snapshot plumbing

    /// Snapshot the ENTIRE run into the session store — called on every structural change
    /// (play / index move / live-queue edit; that's how jukebox guest requests survive a
    /// force-quit). `positionMs` nil ⇒ read the live position; index moves pass 0 so a kill
    /// right after an advance never resumes the NEW track at the OLD track's offset.
    private func persistSession(positionMs: Int? = nil) {
        guard let sessionStore, isRunning else { return }
        let rows = queue.map {
            PlaybackSessionStore.Row(songId: $0.id, title: $0.title, artist: $0.artist,
                                     lengthMs: $0.lengthMs, repeatCount: $0.repeatCount,
                                     variant: $0.variant?.rawValue)
        }
        let ctx = capturedHistoryContext
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: sessionId,
            source: PlaybackSessionStore.SourceRef(kind: (ctx?.source ?? .setlist).rawValue,
                                                   id: sourceSetlistId, name: ctx?.name,
                                                   originKind: capturedOrigin?.kind.rawValue,
                                                   originId: capturedOrigin?.id),
            queue: rows, index: index,
            positionMs: positionMs ?? sessionPositionMs(),
            isPlaying: sessionIsPlaying(),
            repeatMode: repeatMode.rawValue,
            shuffleEnabled: shuffleEnabled,
            updatedAt: Date().timeIntervalSince1970 * 1000)
        sessionStore.save(snap)
    }

    /// Whether the run is audibly playing, by whichever backend owns the audio (the
    /// NowPlayingPanel routing rule). A held (restored, not yet resumed) deck is never playing.
    private func sessionIsPlaying() -> Bool {
        if isHeldForResume { return false }
        if mixEngaged, let dsp { return dsp.isPlaying }   // F4: DSP owns the audio
        return coordinator.activeBackend == .appleMusic ? coordinator.appleMusic.isPlaying
                                                        : player.isPlaying
    }

    /// The current song's position in ms FROM ITS OWN 0:00 — the restore-resume coordinate.
    /// Local/rip playback subtracts the shared-album-file `startMs` (PlayerEngine's clock is
    /// absolute within the file); Apple Music reports song-relative seconds directly. While
    /// held, the pending resume position IS the position.
    private func sessionPositionMs() -> Int {
        if isHeldForResume { return pendingResumeMs ?? 0 }
        // F4: the DSP clock is already SONG-RELATIVE (it schedules the song's slice from 0), so no
        // shared-album startMs subtraction — unlike the AVPlayer clock below.
        if mixEngaged, let dsp { return max(0, Int(dsp.currentTime * 1000)) }
        if coordinator.activeBackend == .appleMusic {
            return max(0, Int(coordinator.appleMusic.positionSeconds * 1000))
        }
        let start = rips.nowPlaying?.startMs ?? 0
        return max(0, Int(player.currentTime * 1000) - start)
    }

    /// ~1 Hz sampler feeding the store's position refresh while the set runs. The store
    /// throttles playing-state writes (~5 s) and passes pause/resume transitions through
    /// immediately, so this stays cheap (reads two clocks, usually writes nothing).
    private func startPositionTicker() {
        positionTicker?.cancel()
        positionTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.isRunning, !self.isHeldForResume else { continue }
                self.sessionStore?.updatePosition(ms: self.sessionPositionMs(),
                                                  isPlaying: self.sessionIsPlaying())
            }
        }
    }
}
