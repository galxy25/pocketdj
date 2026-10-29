import Foundation
import Observation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

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
        /// Edition override — a cleanOnly collection substituting the clean cut, OR the
        /// global "Prefer explicit versions" preference stamped at `play()` (see
        /// `EditionPolicy`). Excluded from equality like `repeatCount` — a playback
        /// parameter, not row identity (`uid` covers instance identity).
        var variant: SongVariant? = nil
        /// True when `variant` is a content RESTRICTION (a clean-only collection / a frozen
        /// setlist stamp) rather than the global preference. Locked rows never fall back to
        /// another edition's file and are never re-stamped by the live preference — that is
        /// what makes the collection's clean flag BEAT the global toggle. Excluded from
        /// equality for the same reason as `variant`.
        var editionLocked: Bool = false
        /// The wanted edition's CATALOG ID, carried from the `EditionPolicy.Decision` that
        /// stamped this row — the lazy rip's hard gate (no id ⇒ nothing is ever enqueued).
        /// Excluded from equality; a playback parameter, not row identity.
        var editionCatalogId: String? = nil

        /// This row's edition decision, reassembled for the storage + rip layers.
        var editionDecision: EditionPolicy.Decision {
            EditionPolicy.Decision(
                edition: variant,
                reason: variant == nil ? .none : (editionLocked ? .collectionCleanOnly : .globalPreference),
                catalogId: editionCatalogId)
        }
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

    private(set) var queue: [Item] = [] {
        // Any queue mutation (fresh play, live edits, shuffle wrap, edition re-stamps)
        // invalidates the O(n) projections memoized below — both exist because rebuilding
        // them per call was an O(26k) main-thread cost on every skip / track start.
        // `queueGeneration` is what lets the DEFERRED cold rebuild (see `persistSession`)
        // recognize it is stale: a snapshot built for generation N must never be memoized
        // or persisted once the queue has moved to N+1.
        didSet {
            sessionRowsMemo = nil; queueIdsMemo = nil; queueGeneration &+= 1
            scheduleStemLockReplan()           // a live-queue edit can change the upcoming tracks
            scheduleRipWindowReconcile()       // …and which rows are inside the rip-ahead window
        }
    }
    /// Monotonic queue identity for the off-main session-row projection (see above).
    @ObservationIgnored private var queueGeneration = 0
    /// A cold session-row projection is being built off-main; further snapshots wait for it
    /// (its landing persists with the then-current position, so nothing is lost).
    @ObservationIgnored private var sessionRowsBuildInFlight = false
    /// The `positionMs` intent of the call that kicked the cold build (play/index moves pass
    /// an explicit 0 so a kill mid-advance never resumes the new track at the old offset).
    @ObservationIgnored private var pendingColdPositionMs: Int?
    /// The queue generation `pendingColdPositionMs` was stamped AGAINST. A superseded
    /// generation's explicit stamp (an index-move 0, a resume offset) must never be persisted
    /// against a NEWER queue — a mid-build queue edit otherwise restored at the wrong offset.
    @ObservationIgnored private var pendingColdPositionGen = 0
    /// Memoized `PlaybackSessionStore.Row` projection of `queue` — `persistSession` fires on
    /// every index move (every skip), and re-mapping a 26k-track queue each time was most of
    /// the skip's main-thread cost on huge sets.
    @ObservationIgnored private var sessionRowsMemo: [PlaybackSessionStore.Row]?
    /// Memoized song-id set of `queue` for `inRunningQueue` (the play-history attribution
    /// hook calls it on every track start; a linear scan of 26k rows per start adds up).
    @ObservationIgnored private var queueIdsMemo: Set<String>?
    /// Index into `queue` (NOT track.id — a song can repeat in a setlist).
    private(set) var index = 0
    private(set) var isRunning = false
    /// True while THIS player's engine actually owns the system Now Playing card
    /// (`NowPlayingArbiter`) — the "is `queue`/`index` really what's audible" check.
    ///
    /// `isRunning` alone is not proof of that: Mix plays through its own engine entirely, and
    /// never touches this player's `isRunning`/`queue`/`index` when a deck starts — the two
    /// engines are that separate. So after switching to a Mix session, `isRunning` and the old
    /// recommendation `queue` can sit stale for as long as the app stays open, and every SYNC
    /// surface reading them directly (the deck, the mini bar, CarPlay's Now Playing card, the
    /// widgets) would keep showing 👍/👎 — and filing a verdict — against a song that stopped
    /// sounding the moment Mix took over. Gate on this alongside `isRunning` wherever "what's
    /// playing right now" has to mean audibly, not just "this queue hasn't been torn down yet".
    var isNowPlayingOwner: Bool { NowPlayingArbiter.shared.isActive(player) }
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
    func inRunningQueue(_ songId: String) -> Bool {
        guard isRunning else { return false }
        let ids: Set<String>
        if let memo = queueIdsMemo { ids = memo }
        else { ids = Set(queue.map(\.id)); queueIdsMemo = ids }
        return ids.contains(songId)
    }

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

    /// Fired when the user ADVANCES AWAY from the current track — in-app/remote ⏭, the AM
    /// `systemSkip` end reason, a jump to another row, a play-now, or a fresh play replacing a
    /// running set. NEVER on a natural end / repeat / length-boundary or dead-source
    /// auto-advance / ⏮ / stop. Payload: (songId, song-relative positionMs — nil when the old
    /// track's clock is already gone (the adopt path), durationMs or nil when unknown).
    /// Skip CLASSIFICATION lives in `SkipTracker`, not here — this only reports what happened.
    @ObservationIgnored var onAdvanceAway: ((String, Int?, Int?) -> Void)?
    /// ~1 Hz position sample for the current track (rides the existing session ticker) —
    /// feeds `SkipTracker`'s high-water mark. Payload mirrors `onAdvanceAway`.
    @ObservationIgnored var onPositionSample: ((String, Int, Int?) -> Void)?
    /// Fired when the row at `index` starts FROM 0:00 — every sequencer-initiated start except
    /// a restore-resume (which re-enters mid-song). For a track change the payload is redundant
    /// (the play hooks record and re-arm the tracker); it is LOAD-BEARING for the replays that
    /// record NOTHING — repeat-one, a per-track repeat pass, a duplicate consecutive row, a
    /// same-song play-now — where the rip path's same-id dedupe means no `onPlay` ever fires:
    /// without this signal the SkipTracker's high-water mark kept pass 1's peak and shielded a
    /// genuine ⏭ during the replay from ever counting as a skip.
    @ObservationIgnored var onTrackRestart: ((String) -> Void)?

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

    // MARK: Rip-ahead window + auto-advance cascade breaker (2026-10-13 "Potential" cascade)

    /// The playback rips THIS session got queued (see `PlaybackRipWindow`).
    @ObservationIgnored private(set) var ripWindow = PlaybackRipWindow()
    @ObservationIgnored private var ripWindowReconcileQueued = false
    /// Sends `POST /rip-cancel` for ids that left the window. Defaults to
    /// `RipsStore.cancelCollection`; tests capture the ids instead.
    @ObservationIgnored var cancelPlaybackRips: (([String]) -> Void)?
    /// Consecutive quick auto-advances (see `AutoAdvanceCascadeBreaker`).
    @ObservationIgnored private var cascade = AutoAdvanceCascadeBreaker()
    /// Audible seconds the CURRENT track has produced (sampled by the session ticker; reset on
    /// every start). Feeds the cascade breaker and the rip window's "heard" exemption.
    @ObservationIgnored private(set) var trackAudibleSeconds: Double = 0
    @ObservationIgnored private var lastAudibleSample: Date?
    /// The cascade breaker stopped auto-advance: the deck holds the current row paused until
    /// the listener acts (▶ retries this row; ⏭/⏮/jump move on).
    private(set) var pausedByCascade = false
    /// A short status for the deck ("Playback paused — Apple Music was interrupted"); nil when
    /// there is nothing to say. Cleared by any transport action or once audio flows again.
    private(set) var playbackNotice: String?
    static let appleMusicInterruptedNotice = "Playback paused — Apple Music was interrupted"
    static let cascadeGenericNotice = "Playback paused — the last few tracks didn’t play"

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
    /// The `sourceSetlistId` of the run that RAISED that flag.
    ///
    /// ── WHY THE FLAG ALONE WAS NOT ENOUGH (a four-month-dead alert) ──────────────────────────
    /// Every surface binds the banner on "the flag is up AND this run is mine", and the only
    /// identity available was `sourceSetlistId` — which `stop()` sets to nil, and `advanceToNext`
    /// calls `stop()` on the line BEFORE it raises the flag. So the test was always nil-vs-id and
    /// the alert could never fire, on any screen, for any set. Device mode dead-ending in silence
    /// is the exact failure it was written to prevent.
    ///
    /// Captured before the teardown and published beside the flag, so the pair survives the run
    /// that produced it. Cleared with it (`clearDeviceUnplayable`) and on the next `play`/`restore`.
    private(set) var deviceUnplayableSourceId: String?
    /// Tracks (within the current run) whether ANY track has loaded a burned file — so a
    /// device-mode set that reaches the end with nothing loaded can raise the banner.
    private var loadedAnyDeviceTrack = false
    /// Plays LEFT for the current track (a performance item's repeat count). Set fresh whenever
    /// the index moves onto a new track; decremented on each natural end until it hits 1, at which
    /// point `advance()` moves on. Always ≥ 1 (`normalizedRepeat`).
    private var currentPlaysRemaining = 1
    /// Monotonic claim ticket for `playCurrent`'s async cloud resolve — a newer skip/jump bumps
    /// it, and an older resolve returning late checks it and stands down (see the SUPERSEDE
    /// GUARD comment at the await). Local-file branches are synchronous and never race.
    private var playGeneration = 0

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
    @ObservationIgnored var dsp: NowPlayingDSP? {
        didSet { wireStemLockHooks() }
    }

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
        // Rip-ahead window: playback rips are gated to the playing row + the next N, and every
        // one the server queues for this session is tracked so it can be cancelled later.
        rips.playbackRipGate = { [weak self] id in self?.playbackRipAllowed(id) ?? true }
        rips.onPlaybackRipQueued = { [weak self] id in self?.notePlaybackRipQueued(id) }
        // P0-1 — a ▶ that reaches the IDLE engine (remote command, interruption `.ended`, widget,
        // intent) is routed through the SAME ladder the in-app panel uses
        // (`NowPlayingPanel.togglePlayPause`). Wired HERE, not in `armEngineHooks`, because it
        // must be live while the deck is HELD (a restore arms no hooks): the head unit's
        // play-on-connect used to hit `engine.play REFUSED (idle)` and nothing else.
        // Apple Music is left alone (macOS idles the engine while MusicKit owns the audio — a
        // restart there would replay the row from 0:00), and a start already in flight is not
        // restarted (the resolve / start watchdog own it).
        player.onIdlePlay = { [weak self] in
            guard let self, self.isRunning else { return nil }
            if self.isHeldForResume { self.resumeFromHold(); return "resumeHeld" }
            if self.coordinator.activeBackend == .appleMusic { return nil }
            if self.isStartPending { return "startInFlight" }
            if self.pausedByCascade || !self.player.hasLoadedItem {
                return self.startCurrent(by: "idlePlay") ? "startCurrent" : nil
            }
            return nil
        }
        // P1-7 — the start window (runway + start watchdog) closes on the FIRST real audio of
        // either lane: the AVPlayer rendering, or MusicKit reporting `.playing`.
        player.onFirstAudio = { [weak self] in self?.handleFirstAudio(source: "player") }
        coordinator.appleMusic.onFirstAudio = { [weak self] in self?.handleFirstAudio(source: "appleMusic") }
        // P0-4 — the engine's interruption `.ended` reads (never writes) the provider's
        // "the listener paused this stream" flag; the provider's `.interrupted` auto-resume
        // stands down while our session has an open interruption (a call).
        player.appleMusicPauseWasIntentional = { [weak coordinator] in coordinator?.appleMusic.pauseIsIntentional ?? false }
        coordinator.appleMusic.sessionInterruptionOpen = { [weak player] in player?.interruptionOpen ?? false }
        // STALE MUSICKIT CARD (drive 2026-10-28): leaving Apple Music releases MusicKit; the
        // engine drops its AM impersonation at once, so the card + remote commands are ours.
        coordinator.appleMusic.onReleased = { [weak player] in player?.leaveExternalPlayback(reason: "amReleased") }
        // …and if MusicKit resumes anyway (a stale system card's ▶), it is silenced and ▶ plays
        // OUR current row. Wired here (not armEngineHooks) so it is live while the deck is held.
        coordinator.appleMusic.onStrayPlay = { [weak self] in self?.reclaimFromStrayMusicKit() }
        player.onLocalInterruptionBegan = { [weak coordinator] in
            coordinator?.appleMusic.scheduleStrayPlayCheck(source: "interruption")
        }
    }

    /// What the set does after a stray MusicKit play was silenced.
    enum StrayReclaimAction: String, Equatable {
        case none, resumeHeld, resumeEngine, startCurrent
    }

    /// Pure verdict for `reclaimFromStrayMusicKit`. The listener pressed ▶ (on a stale MusicKit
    /// card), so play what the deck shows: a held deck resumes, a loaded local row resumes, a
    /// row with nothing loaded (and no start in flight) starts. An Apple Music row that is the
    /// active backend is never "stray" (the provider owns MusicKit then) — defensive no-op.
    nonisolated static func strayReclaimAction(isRunning: Bool, isHeld: Bool, appleMusicActive: Bool,
                                               engineHasLocalItem: Bool, startPending: Bool) -> StrayReclaimAction {
        guard isRunning, !appleMusicActive else { return .none }
        if isHeld { return .resumeHeld }
        if engineHasLocalItem { return .resumeEngine }
        if startPending { return .none }   // the in-flight start will sound; don't restart it
        return .startCurrent
    }

    /// MusicKit started playing while the set's current row is NOT an Apple Music stream, and
    /// the provider silenced it (`AppleMusicPlaybackProvider.checkForStrayPlay`).
    func reclaimFromStrayMusicKit() {
        let action = Self.strayReclaimAction(isRunning: isRunning, isHeld: isHeldForResume,
                                             appleMusicActive: coordinator.activeBackend == .appleMusic,
                                             engineHasLocalItem: player.hasLocalItem,
                                             startPending: isStartPending)
        DiagLog.shared.log("playback", "stray musickit reclaim action=\(action.rawValue) song=\(index < queue.count ? queue[index].id : "-")")
        switch action {
        case .none: break
        case .resumeHeld: resumeFromHold()
        case .resumeEngine: player.reclaimAfterStrayExternalPlay()
        case .startCurrent: startCurrent(by: "strayMusicKit")
        }
    }

    // MARK: Start window — runway until first audio + the start watchdog (plan P1-7)

    /// Background runway cap for one track start (inside the ~30 s background budget).
    static var startRunwayCapSeconds: Double = 25
    /// Start watchdog: re-kick a local-lane start still not playing after this long…
    static var startStallRekickSeconds: Double = 8
    /// …and escalate (hop to an on-device row, else advance through the cascade breaker) here.
    static var startStallEscalateSeconds: Double = 20
    /// A remote ▶ refused before the restore ran is honoured by a restore this soon after it.
    static var pendingRemotePlayMaxAge: TimeInterval = 15

    @ObservationIgnored private var startWindow: (gen: Int, songId: String, runway: PlaybackRunway)?
    @ObservationIgnored private var startWindowCapTask: Task<Void, Never>?
    @ObservationIgnored private var startStallTask: Task<Void, Never>?
    /// A track start is in flight (from `playCurrent` until first audio / the cap / stop).
    var isStartPending: Bool { startWindow != nil }

    /// Open the start window for generation `gen`: a background runway held until the track
    /// actually renders (BOTH lanes — the local-file branch used to have none, so a locked
    /// phone with nothing rendering was suspended mid-start: "Fever" 17:07:29), capped.
    private func beginStartWindow(_ it: Item, gen: Int) {
        endStartWindow(reason: "superseded")
        let runway = PlaybackRunway("pocketdj-start-\(it.id)")
        startWindow = (gen, it.id, runway)
        let cap = Self.startRunwayCapSeconds
        startWindowCapTask = Task { [weak self, runway] in
            // Short sleeps so a deallocated sequencer releases its runway promptly.
            let deadline = Date().addingTimeInterval(cap)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                if self == nil { runway.end(reason: "owner-gone"); return }
            }
            guard let self else { runway.end(reason: "owner-gone"); return }
            if self.startWindow?.gen == gen { self.endStartWindow(reason: "cap") }
        }
    }

    private func endStartWindow(reason: String) {
        guard let w = startWindow else { return }
        startWindow = nil
        startWindowCapTask?.cancel(); startWindowCapTask = nil
        w.runway.end(reason: reason)
    }

    private func handleFirstAudio(source: String) {
        DeadAirMeter.shared.firstAudio()
        endStallEpisode(reason: "firstAudio.\(source)")
        startStallTask?.cancel(); startStallTask = nil
        endStartWindow(reason: "firstAudio.\(source)")
    }

    #if DEBUG
    /// Tests: is this sequencer's start runway held right now?
    var startRunwayHeldForTesting: Bool { startWindow != nil }
    var startStallArmedForTesting: Bool { startStallTask != nil }
    #endif

    private func logTrackStart(_ it: Item, backend: String, resumeAtMs: Int?) {
        DeadAirMeter.shared.trackStarting(backend: backend)
        DiagLog.shared.log("playback", "track start song=\(it.id) index=\(index)/\(queue.count) backend=\(backend) resumeAtMs=\(resumeAtMs ?? 0)")
    }

    /// Arm the START WATCHDOG after a local-lane load (burned / studio / profile / stem cut /
    /// presigned / HLS): at `startStallRekickSeconds` with no audio (and no listener pause) log
    /// `start-stall` and re-kick in place; at `startStallEscalateSeconds` escalate through the
    /// resolve-stall hop, else `advanceToNext(.auto)` — counted by the cascade breaker, so a
    /// dead zone still halts after a few quick advances instead of skipping the whole set.
    /// Cancelled by first audio, a skip (new generation), a pause, and stop.
    private func armStartStall(gen: Int, songId: String) {
        startStallTask?.cancel()
        let rekickAt = Self.startStallRekickSeconds
        let escalateAt = max(rekickAt, Self.startStallEscalateSeconds)
        startStallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, rekickAt) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.startStallStillOwed(gen) else { return }
            self.logStartStall(songId, waited: rekickAt)
            self.player.rekick(by: "player.startStall")
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, escalateAt - rekickAt) * 1_000_000_000))
            guard !Task.isCancelled, self.startStallStillOwed(gen) else { return }
            self.logStartStall(songId, waited: escalateAt)
            self.startStallTask = nil
            self.escalateStalledStart(reason: "start-stall \(Int(escalateAt))s")
        }
    }

    private func startStallStillOwed(_ gen: Int) -> Bool {
        isRunning && playGeneration == gen && !isHeldForResume && !pausedByCascade && !mixEngaged
            && coordinator.activeBackend != .appleMusic
            && player.hasLoadedItem && player.timeControlStatus != .playing
            && !player.pausedByListener && !player.interruptionOpen && !player.trackEndAlreadySignaled
    }

    private func logStartStall(_ songId: String, waited: Double) {
        let status: String
        switch player.timeControlStatus {
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        case .playing: status = "playing"
        @unknown default: status = "?"
        }
        #if canImport(UIKit) && !os(macOS)
        let appState: String = {
            switch UIApplication.shared.applicationState {
            case .active: return "fg"
            case .inactive: return "inactive"
            case .background: return "bg"
            @unknown default: return "?"
            }
        }()
        #else
        let appState = "fg"
        #endif
        DiagLog.shared.log("playback", "start-stall song=\(songId) waited=\(Int(waited)) status=\(status) "
                           + "reason=\(player.reasonForWaitingToPlay) itemStatus=\(player.itemStatusDescription) "
                           + "err=\(player.itemErrorDescription) appState=\(appState) runway=\(startWindow != nil ? 1 : 0)")
    }

    /// The current row could not get to audio: hop to the next ON-DEVICE row (deferring this
    /// one right behind it), else advance — through the cascade breaker (`.auto`).
    func escalateStalledStart(reason: String) {
        guard isRunning, index < queue.count, !isHeldForResume, !pausedByCascade else { return }
        if hopToOnDeviceRow(reason: reason) { return }
        DiagLog.shared.log("playback", "advance: \(reason) song=\(queue[index].id) — no on-device row to hop to")
        advanceToNext(.auto)
    }

    // MARK: Supervisor hooks (§3 — the supervisor only ever calls these while intent == playing)

    /// L2: re-resolve + restart the CURRENT row at its current position (a fresh presign /
    /// another provider). NOT a user transport — the cascade breaker is not reset.
    func supervisorRetryInPlace() {
        guard isRunning, index < queue.count, !isHeldForResume, !pausedByCascade else { return }
        let at = sessionPositionMs()
        DiagLog.shared.log("supervisor", "retry in place song=\(queue[index].id) atMs=\(at)")
        startPlayCurrent(fresh: false, resumeAtMs: at > 1000 ? at : nil)
    }

    /// L3: hop / advance through the cascade breaker.
    func supervisorEscalate() { escalateStalledStart(reason: "supervisor L3") }

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
    /// `preStamped: true` ⇒ `items` already went through `prepareStamped` (the off-main
    /// edition stamp) — skip the synchronous 26k-row re-stamp. Every other caller keeps the
    /// exact sync behavior.
    func play(_ items: [Item], sourceSetlistId: String? = nil, preStamped: Bool = false) {
        guard !items.isEmpty else { return }
        // Telemetry funnel: EVERY "start playing this set" in the app lands here (rows, intents,
        // CarPlay, widgets), so one line captures them all — and doubles as the play-signal the
        // rec engine's remote analysis reads.
        DiagLog.shared.telemetry("action", "set start count=\(items.count) first=\(items.first?.title ?? "?")")
        // A fresh play over a RUNNING set is "advancing away" from its current track (the
        // replace is user-initiated); starting from idle advances away from nothing — and
        // neither does replacing the set with one that OPENS ON THE SAME SONG (replaying the
        // current set from its collection to hear this song from the top is a restart, not a
        // skip of the song the user actively chose again).
        if isRunning, let first = items.first, !isRestartOfCurrent(first.id) { noteAdvanceAway() }
        // The previous session's playback rips (minus the row that was sounding and anything
        // heard) are cancelled — a fresh run has its own window.
        if isRunning { endRipWindowSession(reason: "new-session") }
        noteUserTransport()
        _ = player.consumePendingRemotePlay(maxAge: 0)   // a fresh play answers any latched ▶
        self.sourceSetlistId = sourceSetlistId
        // Snapshot THIS run's history origin now (before any later playNow can mutate the shared
        // now-playing source), so every play in this run is attributed to the right set.
        capturedHistoryContext = historyContextProvider?(sourceSetlistId)
        capturedOrigin = originProvider?(sourceSetlistId)
        queue = preStamped ? items : stampEditions(items, sourceSetlistId: sourceSetlistId)
        index = 0
        // Live shuffle is per-run (repeat mode is sticky). The one-shot `playNow(shuffle:)` already
        // randomized the incoming order when requested; the live toggle starts OFF for the new queue.
        shuffleEnabled = false
        canonicalOrder = nil
        isRunning = true
        deviceQueueUnplayable = false   // fresh run — clear any prior banner signal
        deviceUnplayableSourceId = nil
        loadedAnyDeviceTrack = false
        // A fresh play over a restored-but-held deck simply replaces it (the natural expiry).
        isHeldForResume = false
        pendingResumeMs = nil
        armEngineHooks()
        // STEM LOCK is per SESSION: a fresh run (new `sessionId`) starts unlocked.
        resetStemLock()
        // Durable session: a fresh run gets a fresh identity + an immediate snapshot, and the
        // ~1 Hz position sampler starts feeding the store's throttled refresh.
        sessionId = "pses_" + UUID().uuidString
        persistSession(positionMs: 0)
        startPositionTicker()
        startPlayCurrent()
    }

    // MARK: Edition selection (the ONE place the preference is applied to a queue)

    /// THE edition decision for a queued row, resolved fresh at `play()` — wired in
    /// PocketDJApp to `EditionPolicy.decide` over the live catalog + settings. Arguments: the
    /// base song id and whether the run's origin collection carries the clean-only flag.
    /// Unwired (tests, previews) ⇒ every row is `.unchanged`, i.e. today's behaviour exactly.
    @ObservationIgnored var editionDecider: ((String, Bool) -> EditionPolicy.Decision)?
    /// O(1) probe: would `editionDecider` substitute ANYTHING right now? (False when the
    /// global "Prefer explicit versions" preference is unset.) Lets `stampEditions` skip
    /// its full-queue map in the common no-preference case; nil ⇒ assume active.
    @ObservationIgnored var editionDeciderActive: (() -> Bool)?
    /// VALUE inputs for the OFF-MAIN edition stamp (`prepareStamped`): the catalog dictionary
    /// (O(1) CoW grab) + the raw tri-state preference. Wired in PocketDJApp next to
    /// `editionDecider`; nil (tests/previews) falls back to the sync in-place stamp.
    @ObservationIgnored var editionStampInputs: (() -> (songsById: [String: IndexSong],
                                                        preferExplicitRaw: Bool?))?

    /// Stamp `items` OFF the main actor: same precedence, same output as `stampEditions`
    /// (production wires `editionDecider` to exactly `EditionPolicy.decide`, which is what the
    /// pure twin calls) — but the 26k-row map runs detached, so a huge set's ▶ no longer pays
    /// it on the main thread. Callers pass the result to `play(_:sourceSetlistId:preStamped: true)`.
    func prepareStamped(_ items: [Item], sourceSetlistId: String?) async -> [Item] {
        let cleanOnly = cleanOnlyOrigin?(sourceSetlistId) ?? false
        guard editionDecider != nil || cleanOnly else { return items }
        guard let inputs = editionStampInputs?() else {
            // No value seam wired (tests with a custom decider): keep the sync path's answer.
            return stampEditions(items, sourceSetlistId: sourceSetlistId)
        }
        if !cleanOnly, editionDeciderActive?() == false,
           !items.contains(where: { $0.variant != nil }) { return items }
        let (songsById, raw) = inputs
        return await Task.detached(priority: .userInitiated) {
            Self.stampEditionsPure(items, cleanOnly: cleanOnly, songsById: songsById,
                                   preferExplicitRaw: raw)
        }.value
    }

    /// The pure per-row stamp — `stampEditions`' map body with `EditionPolicy.decide` inlined
    /// over a value snapshot (which is precisely what the app wires `editionDecider` to), so
    /// the detached path and the sync path produce identical rows. Keep in lockstep.
    nonisolated static func stampEditionsPure(_ items: [Item], cleanOnly: Bool,
                                              songsById: [String: IndexSong],
                                              preferExplicitRaw: Bool?) -> [Item] {
        items.map { it in
            var out = it
            if it.variant != nil {
                // Frozen wins, always, and is a restriction. Re-resolve only its catalog id.
                out.editionLocked = true
                out.editionCatalogId = EditionPolicy.decide(song: songsById[it.id],
                                                            collectionCleanOnly: true,
                                                            preferExplicitRaw: preferExplicitRaw).catalogId
                return out
            }
            if cleanOnly {
                out.editionLocked = true          // no preference substitution inside a clean-only run
                return out
            }
            let d = EditionPolicy.decide(song: songsById[it.id], collectionCleanOnly: false,
                                         preferExplicitRaw: preferExplicitRaw)
            out.variant = d.edition
            out.editionLocked = d.reason == .collectionCleanOnly
            out.editionCatalogId = d.catalogId
            return out
        }
    }

    /// Does the collection this run came from carry the clean-only flag? Wired to
    /// `CollectionsStore`; defaults false. Read ONCE per run — it is what makes the collection
    /// flag beat the global toggle.
    @ObservationIgnored var cleanOnlyOrigin: ((String?) -> Bool)?

    /// Stamp every row with the edition it should actually play. This is the ONLY place the
    /// global preference reaches a queue, so the precedence can't be scattered:
    ///   • a row that already carries a FROZEN edition keeps it, LOCKED (a cleanOnly
    ///     realize/playNow already decided it; a later toggle flip must not undo it) — its
    ///     catalog id is re-resolved so the lazy rip can still acquire it;
    ///   • a run from a clean-only collection is locked WHOLESALE — including its rows that
    ///     carry no stamp (the already-clean ones), which is what stops prefer-explicit from
    ///     upgrading them to explicit inside a clean-only pocket;
    ///   • everything else asks `editionDecider` (→ `EditionPolicy.decide`).
    private func stampEditions(_ items: [Item], sourceSetlistId: String?) -> [Item] {
        let cleanOnly = cleanOnlyOrigin?(sourceSetlistId) ?? false
        // Nothing to stamp only when BOTH inputs are absent — a clean-only run still has to
        // lock its rows even with no decider wired, or the restriction would be lost.
        guard editionDecider != nil || cleanOnly else { return items }
        // Prefer-explicit OFF and not clean-only: the decider returns `.unchanged` for every
        // row, so the whole 26k-row map is a no-op — skip it (it ran on every play of a huge
        // set). Any row already carrying a frozen variant still needs its catalog-id
        // re-resolve, so a single stamped row disables the shortcut.
        if !cleanOnly, editionDeciderActive?() == false,
           !items.contains(where: { $0.variant != nil }) { return items }
        return items.map { it in
            var out = it
            if let frozen = it.variant {
                // Frozen wins, always, and is a restriction. Re-resolve only its catalog id.
                out.editionLocked = true
                out.editionCatalogId = editionDecider?(it.id, true).catalogId
                return out
            }
            if cleanOnly {
                out.editionLocked = true          // no preference substitution inside a clean-only run
                return out
            }
            let d = editionDecider?(it.id, false) ?? .unchanged
            out.variant = d.edition
            out.editionLocked = d.reason == .collectionCleanOnly
            out.editionCatalogId = d.catalogId
            return out
        }
    }

    /// LAZY RIP ON MISS — ask the server for the edition this row wanted but doesn't have,
    /// through the SAME durable queue, dedup and enqueue path as every other rip
    /// (`RipsStore.requestEditionRipIfNeeded` → `requestRipIfNeeded` under the variant id).
    /// One song, on demand, at the moment of use. Fire-and-forget: it never blocks or delays
    /// playback, and it is idempotent at three layers, so repeated misses while a rip is in
    /// flight enqueue exactly ONCE. Nothing is enqueued when that edition's catalog id is
    /// unknown.
    ///
    /// OWNER-GATED, exactly like the passive stream-through-rip fan-out in
    /// `PlaybackCoordinator.play`: a hybrid user streaming from their own subscription must
    /// never silently enqueue captures on the shared server keyed by a shared id.
    private func lazyRipWantedEdition(_ it: Item) {
        guard let want = it.variant, coordinator.isCatalogOwner() else { return }
        var decision = it.editionDecision
        // A RESTORED row carries its edition but not the catalog id (the durable snapshot
        // stores the edition, not the id) — re-resolve it from the live catalog, else the
        // hard gate would refuse to acquire anything after a relaunch.
        if decision.catalogId == nil {
            decision.catalogId = coordinator.variantAppleMusicIdOfSong(it.id, want)
        }
        Task { await rips.requestEditionRipIfNeeded(base: it.id, decision: decision, playback: true) }
    }

    /// Is there a burned file this row could play on device, honouring its edition decision?
    /// (The ladder — wanted edition, legacy, other edition — so a prefer-explicit row whose
    /// explicit rip hasn't landed still counts its legacy burn as playable.)
    private func hasDeviceFile(_ it: Item) -> Bool {
        EditionPolicy.resolveStored(base: it.id, decision: it.editionDecision,
                                    isStored: { self.burns.localURL(forSong: $0) != nil }) != nil
    }

    /// Own the engines' end hooks + lock-screen next/previous while running (released in
    /// `stop()`). Shared by `play()`, `resumeFromHold()`, and the held-state exits — a
    /// RESTORED (held) deck deliberately does NOT arm these until real playback starts.
    private func armEngineHooks() {
        // The lock screen / Control Center next/prev advance the SET.
        player.onTrackEnded = { [weak self] in self?.handleEnded() }
        player.onTrackFailed = { [weak self] in self?.handleFailed() }
        player.onNext = { [weak self] in self?.skipNext() }
        player.onPrevious = { [weak self] in self?.skipPrevious() }
        player.setNextPreviousEnabled(true)
        // P0-6: keep the card/remote ownership across the gap between two tracks while the set
        // runs (cleared in stop()).
        player.holdsOwnershipAcrossTracks = true
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
        coordinator.appleMusic.onTrackEnded = { [weak self] reason in self?.handleAppleMusicEnded(reason: reason) }
        // The system remote ⏮ during a stream also lands in MusicKit (it rewinds its one-song
        // queue to 0:00); the provider detects the rewind and fires this so ⏮ steps the SET back.
        coordinator.appleMusic.onTrackRestarted = { [weak self] in self?.handleAppleMusicRestarted() }
        // An EXTERNAL interruption of the stream (Music.app taking over — e.g. a same-Mac rip
        // capture) is not the end of the track: the row holds, paused; ▶ resumes it.
        coordinator.appleMusic.onInterrupted = { [weak self] in self?.handleAppleMusicInterrupted() }
        coordinator.appleMusic.onNearEnd = { [weak self] in self?.handleAppleMusicNearEnd() }
    }

    /// Stop the sequence + clear now-playing; resets so the toolbar flips back to Play.
    func stop() {
        if isRunning { endRipWindowSession(reason: "stop") }
        cascade.reset(); pausedByCascade = false; playbackNotice = nil
        playTask?.cancel(); playTask = nil // a resolve still in flight must not load into a stopped deck
        playGeneration &+= 1               // …and its post-await bookkeeping must stand down
        endMixEngagement()                 // F4: drop any DSP hand-off before tearing the run down
        isRunning = false
        waitingForLive = false
        startStallTask?.cancel(); startStallTask = nil
        endStartWindow(reason: "stop")
        DeadAirMeter.shared.transitionAbandoned(reason: "stop")
        // P0-6: release the across-tracks hold FIRST so `player.stop()` below resigns the card;
        // P0-2: and a held set that resigned is no longer the preferred remote target.
        player.holdsOwnershipAcrossTracks = false
        if NowPlayingArbiter.shared.preferred === player { NowPlayingArbiter.shared.prefer(nil) }
        player.noteListenerIntent(false)
        player.onTrackEnded = nil          // release ownership of the shared hook
        player.onTrackFailed = nil
        resolveStallTask?.cancel(); resolveStallTask = nil
        liveBackstopTask?.cancel(); liveBackstopTask = nil
        endStallEpisode(reason: "stop")
        player.onNext = nil
        player.onPrevious = nil
        player.setNextPreviousEnabled(false)
        player.onRepeatModeChange = nil
        player.onShuffleChange = nil
        player.setRepeatShuffleCommandsEnabled(false)
        coordinator.appleMusic.onTrackEnded = nil
        coordinator.appleMusic.onTrackRestarted = nil
        coordinator.appleMusic.onInterrupted = nil
        coordinator.appleMusic.onNearEnd = nil
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
        resetStemLock()                    // the session is over — so is its Stem Lock
        sessionStore?.clear()
    }

    /// Acknowledge + clear the one-shot device-unplayable banner (the surface calls this
    /// once it has shown the transient message).
    func clearDeviceUnplayable() {
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = nil
    }

    /// Manually advance (used by the live-track "Next" affordance + lock-screen NEXT).
    func skipNext() {
        DiagLog.shared.telemetry("action", "skip next from=\(queue.indices.contains(index) ? queue[index].title : "?")")
        noteAdvanceAway()
        exitHoldIfNeeded()
        advanceToNext(.user)
    }

    /// Manually go back one track (lock-screen PREVIOUS). No-op past the top of the set; never
    /// goes below index 0. Re-resolves + plays the (now) current track.
    func skipPrevious() {
        guard isRunning else { return }
        DiagLog.shared.telemetry("action", "skip previous")
        noteUserTransport()
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
        startPlayCurrent()
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
    /// An `ArraySlice` VIEW, not a copy: consumers window it (`prefix`) or read
    /// `count`/`isEmpty`, and materializing a 26k-track tail per read was the dominant
    /// main-thread cost after starting a huge set (the Now Playing panel alone read this
    /// three times per body pass — ~12 MB of array copies behind the push animation).
    /// NOTE for subscripters: a slice keeps the parent's indices — iterate/prefix it,
    /// never index it from 0.
    var upcoming: ArraySlice<Item> {
        guard isRunning, index + 1 < queue.count else { return [] }
        return queue[(index + 1)...]
    }

    /// The already-played head of the queue (`queue[0..<index]`, oldest first) — the
    /// "previously played" list behind the Now Playing panel's history toggle. Pure
    /// projection: played rows stay in the queue (`advanceToNext` only moves the index)
    /// and ride every durable-session snapshot, so a restored run keeps its history.
    var played: [Item] {
        guard isRunning, index > 0 else { return [] }
        return Array(queue[..<min(index, queue.count)])
    }

    /// The uid of the upcoming row at 0-based OFFSET (0 = the track right after the current
    /// one) — the positional→identity bridge for the panel's `.onDelete`. Exists because
    /// `upcoming` is a parent-indexed slice: subscripting it with a row offset reads the
    /// wrong element (or traps below `startIndex`), which is exactly how the full-suite
    /// crash after the slice change surfaced. nil for out-of-tail offsets (a stale render).
    func upcomingUid(atOffset offset: Int) -> UUID? {
        guard isRunning, offset >= 0 else { return nil }
        let i = index + 1 + offset
        guard i < queue.count else { return nil }
        return queue[i].uid
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

    /// Insert tracks immediately before an existing upcoming row (by identity) — the Now
    /// Playing expanded view's drop target when a "previously played" row is dragged onto
    /// a specific Up Next slot. An unknown/played anchor (the tail shifted underneath a
    /// slow drag) falls back to appending at the end, same as any other stale-uid Up Next op.
    func insertInQueue(_ items: [Item], before uid: UUID) {
        guard isRunning, !items.isEmpty else { return }
        guard index + 1 < queue.count,
              let pos = queue[(index + 1)...].firstIndex(where: { $0.uid == uid }) else {
            appendToQueue(items)
            return
        }
        queue.insert(contentsOf: items, at: pos)
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
        DiagLog.shared.telemetry("action", "jump to upcoming \(queue[pos].title)")
        // Jumping onto ANOTHER OCCURRENCE of the same song is a restart, not a skip of it.
        if !isRestartOfCurrent(queue[pos].id) { noteAdvanceAway() }
        noteUserTransport()
        exitHoldIfNeeded()
        waitingForLive = false
        index = pos
        persistSession(positionMs: 0)
        startPlayCurrent()
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
        // Play-now of the SONG ALREADY PLAYING = "hear it from the top" — a restart the user
        // actively chose, never a skip verdict against the exact song they asked for again.
        if !isRestartOfCurrent(item.id) { noteAdvanceAway() }
        noteUserTransport()
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
        startPlayCurrent()
    }

    /// Shift playback BACK onto a played row (by identity) — "Rewind to here".
    /// `jumpToUpcoming` mirrored at the head: the needle lands exactly on the tapped row and
    /// the rows between it and the old current return to the upcoming tail (the same region a
    /// repeated ⏮ walks, one tap). Unknown/current/upcoming uids are a safe no-op — the tap
    /// races playback by design.
    func jumpToPlayed(uid: UUID) {
        guard isRunning, index > 0,
              let pos = queue[..<min(index, queue.count)].firstIndex(where: { $0.uid == uid }) else { return }
        // Rewinding onto an EARLIER OCCURRENCE of the same song is a restart, not a skip of it.
        if !isRestartOfCurrent(queue[pos].id) { noteAdvanceAway() }
        noteUserTransport()
        exitHoldIfNeeded()
        waitingForLive = false
        index = pos
        persistSession(positionMs: 0)
        startPlayCurrent()
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
        // The burn lookup walks the row's EDITION ladder (a substituted row's file lives under the
        // variant id, a legacy burn under the base) even though `np.songId` is the base — the same
        // split `playCurrent` resolves through.
        return StudioFactory.isStudioId(np.songId) || hasDeviceFile(queue[index])
            || stemLockStreamedFile?(queue[index].resolveId) == np.url   // Stem Lock: a prefetched cut
    }

    /// The full F4 eligibility gate: mixable current track AND no active Mix-tab session (mutually
    /// exclusive — one DSP surface). The view passes `mix.isRunning || mix.autoMixing` for `mixActive`.
    func mixAvailable(mixActive: Bool) -> Bool { currentTrackMixable && !mixActive }

    /// FIRST touch of a mix control: swap the current track's audio off the `AVPlayer` into
    /// `NowPlayingDSP` AT the current position, and publish the DSP's card through `PlayerEngine`'s
    /// external-source path so the lock-screen/CarPlay card keeps exactly ONE writer (the same
    /// mechanism the Apple Music hand-off uses). Idempotent — a no-op once engaged, or when the track
    /// isn't mixable / the DSP isn't wired. A brief, possibly-audible transition is accepted.
    func engageMix() { engageMix(atSeconds: nil, play: nil) }

    /// `engageMix` with the position + play state stated by the caller instead of read off the
    /// AVPlayer — the Stem Lock engages in the SAME turn the AVPlayer was handed the new track,
    /// before its clock (or a resume seek) has moved and before it reports playing.
    private func engageMix(atSeconds at: Double?, play: Bool?) {
        guard isRunning, index < queue.count, !mixEngaged, let dsp, currentTrackMixable,
              let np = rips.nowPlaying else { return }
        let it = queue[index]
        let startSec = Double(np.startMs ?? 0) / 1000
        let atSeconds = at ?? max(0, player.currentTime - startSec)   // AVPlayer clock is absolute-in-file
        let wasPlaying = play ?? player.isPlaying
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
            rate: { [weak dsp] in dsp?.rate ?? 1 },   // the card's cursor moves at the DSP's tempo
            play: { [weak dsp] in dsp?.resume() },
            pause: { [weak dsp] in dsp?.pause() })
        // 3) Only now that the AVPlayer is idle, start the DSP audio if we were playing — so exactly one
        //    engine ever sounds during the swap — and re-publish the card from the DSP's live state
        //    at once (it was published paused a moment ago, before the DSP sounded).
        if wasPlaying { dsp.resume() }
        player.refreshExternalNowPlaying()
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
            startPlayCurrent(fresh: true)
            return
        }
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            startPlayCurrent(fresh: false)   // reloads the AVPlayer for the repeat
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

    // MARK: - Stem Lock (carry the Now Playing stem set across tracks — see `StemLock`)

    /// The session's Stem Lock and the stem set it carries. Off by default; persisted in the
    /// durable session; cleared by a new session (`play`) and by `stop()`.
    private(set) var stemLock = StemLockState()
    /// The song (by row id) whose carried stems could not be brought up — drives the
    /// "unavailable" indicator. Cleared on every track start.
    private(set) var stemLockUnavailableSongId: String?
    /// The download lane pairing upcoming tracks' whole songs with their stems (wired at app
    /// init; nil in tests that don't exercise it — the lock then only carries the stem state).
    @ObservationIgnored var stemLockPrefetcher: StemLockPrefetcher? {
        didSet {
            stemLockPrefetcher?.onStepFinished = { [weak self] step, ok in self?.stemLockStepFinished(step, ok) }
        }
    }
    /// SEAM: a COMPLETE whole-song stream file for an audio id that the burn ledger didn't adopt
    /// (an analog per-song cut) — wired to the shared `MixStreamLoader`. nil = none.
    @ObservationIgnored var stemLockStreamedFile: ((String) -> URL?)?
    /// SEAM: can this audio id's whole song be fetched right now (ripped + server + network)?
    @ObservationIgnored var stemLockSongFetchable: ((String) -> Bool)?
    /// True while the lock itself drives the DSP (its stem calls must not read as user changes).
    @ObservationIgnored private var applyingStemLock = false
    /// When the lock asked the current track for its stems (the handover-timing line).
    @ObservationIgnored private var stemLockRequestedAt: (songId: String, at: Date)?
    @ObservationIgnored private var stemLockReplanQueued = false

    /// What the Now Playing surfaces show for the lock on the current track.
    var stemLockIndicator: StemLock.Indicator {
        guard stemLock.enabled else { return .off }
        guard stemLock.stemsOn, let id = currentSongId, !isHeldForResume else { return .idle }
        if stemLockUnavailableSongId == id { return .unavailable }
        guard mixEngaged, let dsp else { return .loading }        // the track is still starting
        if dsp.stemsOnAir { return .active }
        return dsp.stemsLoading ? .loading : .unavailable          // a request that dropped
    }

    /// Turn the session's Stem Lock on/off. ON captures the CURRENT track's stem state as the
    /// set to carry (stems off when the track isn't engaged); OFF forgets it — later tracks reset
    /// as before (the current track keeps whatever it is playing). No-op with no session.
    func setStemLock(_ on: Bool) {
        guard isRunning else { return }
        var st = StemLockState()
        if on {
            st.enabled = true
            captureStemLock(into: &st)
        }
        stemLock = st
        stemLockUnavailableSongId = nil
        if !on { stemLockPrefetcher?.cancelAll() }
        StemLock.log("lock \(on ? "ON" : "OFF") session=\(sessionId) song=\(currentSongId ?? "-")\(on ? " carry " + st.logSummary : "")")
        persistSession()
        scheduleStemLockReplan()
    }

    /// The current track's stem state (when the DSP owns it) into `st`.
    private func captureStemLock(into st: inout StemLockState) {
        guard mixEngaged, let dsp else { st.stemsOn = false; st.muted = []; st.volumes = [:]; return }
        st.stemsOn = dsp.stemMode
        st.muted = dsp.mutedStems.sorted()
        st.volumes = dsp.stemVolumes
    }

    /// New session / stop: unlocked, nothing carried, nothing downloading for it.
    private func resetStemLock() {
        if stemLock.enabled { StemLock.log("lock cleared (session ended / new session)") }
        stemLock = StemLockState()
        stemLockUnavailableSongId = nil
        stemLockRequestedAt = nil
        stemLockPrefetcher?.cancelAll()
    }

    /// The DSP's user-change + handover hooks (re-armed whenever the DSP seam is set).
    private func wireStemLockHooks() {
        dsp?.onUserStemChange = { [weak self] in self?.stemControlsChangedByUser() }
        dsp?.onStemsOnAir = { [weak self] songId in self?.stemsWentOnAir(songId) }
    }

    /// The listener changed the stem state mid-track: that is what carries forward now.
    private func stemControlsChangedByUser() {
        guard stemLock.enabled, !applyingStemLock, mixEngaged, let dsp else { return }
        var st = stemLock
        captureStemLock(into: &st)
        guard st != stemLock else { return }
        stemLock = st
        // An unmuted part the partial set lacks becomes an ENABLED part: it must arrive first.
        if dsp.stemPartsRequired != nil { dsp.stemPartsRequired = Set(st.enabledParts) }
        if st.stemsOn, let id = currentSongId, stemLockUnavailableSongId == id, dsp.stemMode {
            stemLockUnavailableSongId = nil
        }
        StemLock.log("carry updated mid-track song=\(currentSongId ?? "-") \(st.logSummary)")
        persistSession()
        scheduleStemLockReplan()
    }

    private func stemsWentOnAir(_ songId: String) {
        guard stemLock.wantsStems, let req = stemLockRequestedAt, req.songId == songId else { return }
        stemLockRequestedAt = nil
        let ms = Int(Date().timeIntervalSince(req.at) * 1000)
        StemLock.log("handover song=\(songId) full mix → stems after \(ms)ms @\(String(format: "%.2f", dsp?.currentTime ?? 0))s")
    }

    /// A NEW track just started (the AVPlayer was handed its source this turn — or the stream /
    /// Apple Music resolve just landed). Locked with stems: hand it to the DSP on the full mix at
    /// once (zero dead air — it plays from its first sample) with the carried mutes/gains, and ask
    /// for the stems; the DSP's handover crosses over as soon as the ENABLED parts are buffered.
    /// A track that can't do stems keeps the full mix and flags the indicator; the lock stays.
    /// `liveClock`: the audio started earlier (an adopted row ▶) — engage at the AVPlayer's
    /// current position instead of the song's top / the resume offset.
    private func applyStemLockOnTrackStart(resumeAtMs: Int?, liveClock: Bool = false) {
        stemLockUnavailableSongId = nil
        stemLockRequestedAt = nil
        defer { scheduleStemLockReplan() }
        guard stemLock.enabled, isRunning, index < queue.count else { return }
        let it = queue[index]
        guard stemLock.stemsOn else {
            StemLock.log("carry song=\(it.id) stems=off → full mix")
            return
        }
        guard let dsp, currentTrackMixable, mixSessionActive?() != true else {
            stemLockUnavailableSongId = it.id
            StemLock.log("carry song=\(it.id) \(stemLock.logSummary) → UNAVAILABLE (not a local file) — full mix, lock kept")
            return
        }
        if !mixEngaged {
            engageMix(atSeconds: liveClock ? nil : (resumeAtMs.map { Double($0) / 1000 } ?? 0),
                      play: !player.pausedByListener)
        }
        guard mixEngaged else {
            stemLockUnavailableSongId = it.id
            StemLock.log("carry song=\(it.id) → UNAVAILABLE (DSP refused the file) — full mix, lock kept")
            return
        }
        applyingStemLock = true
        defer { applyingStemLock = false }
        dsp.applyCarriedStemControls(muted: Set(stemLock.muted), volumes: stemLock.volumes)
        dsp.stemPartsRequired = Set(stemLock.enabledParts)
        let t0 = Date()
        stemLockRequestedAt = (it.id, t0)
        guard dsp.applyStemMode(true) else {
            stemLockRequestedAt = nil
            stemLockUnavailableSongId = it.id
            StemLock.log("carry song=\(it.id) \(stemLock.logSummary) → UNAVAILABLE (no stems) — full mix, lock kept")
            return
        }
        let local = burns.stemPartsBurned(forSong: it.id)
        StemLock.log("carry song=\(it.id) \(stemLock.logSummary) local=\(local.sorted().joined(separator: ",")) → \(dsp.stemsOnAir ? "on air" : "full mix first, stems loading")")
    }

    /// A prefetch step finished: a stem part of the PLAYING track joins its partial set.
    private func stemLockStepFinished(_ step: StemLockPrefetcher.Step, _ ok: Bool) {
        guard ok, case let .stem(songId, _) = step, mixEngaged, currentSongId == songId else { return }
        dsp?.stemPartsLanded(songId)
    }

    /// Coalesce re-plans (a queue edit + a track start in one turn plan once).
    private func scheduleStemLockReplan() {
        guard let pf = stemLockPrefetcher, stemLock.enabled || !pf.isIdle, !stemLockReplanQueued else { return }
        stemLockReplanQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stemLockReplanQueued = false
            self.replanStemLock()
        }
    }

    /// Re-plan the Stem Lock download lane from the current queue position (see
    /// `StemLockPrefetcher.plan` for the order). Lock off / stems off / held / idle: cancel —
    /// the ordinary presign prefetch is all that runs then (no speculative stem fetch).
    func replanStemLock() {
        guard let pf = stemLockPrefetcher else { return }
        guard stemLock.wantsStems, isRunning, !isHeldForResume, index < queue.count else { pf.cancelAll(); return }
        let upcoming = queue[(index + 1)..<min(queue.count, index + 1 + Self.prefetchAhead)]
            .filter { !StudioFactory.isStudioId($0.id) && !ProfileSourceStore.isProfileSongId($0.id) }
            .map(stemLockTrack)
        var current: StemLockPrefetcher.Track?
        if mixEngaged, let dsp, dsp.stemMode, !dsp.unwiredStemParts.isEmpty {
            let t = stemLockTrack(queue[index])
            // A missing part that is on disk by now (landed between events) joins right here.
            if !t.stemsLocal.isDisjoint(with: dsp.unwiredStemParts) { dsp.stemPartsLanded(t.songId) }
            current = t
        }
        pf.apply(StemLockPrefetcher.plan(current: current, upcoming: upcoming, carry: stemLock,
                                         network: pf.network(), window: Self.prefetchAhead))
    }

    private func stemLockTrack(_ it: Item) -> StemLockPrefetcher.Track {
        // Device mode plays ONLY burned files — the lock never downloads a whole song into it.
        let fetchable = playbackMode() != .device && (stemLockSongFetchable?(it.resolveId) ?? false)
        return .init(songId: it.id, audioId: it.resolveId, title: it.title, artist: it.artist,
                     songLocal: hasDeviceFile(it) || stemLockStreamedFile?(it.resolveId) != nil,
                     songFetchable: fetchable,
                     stemsLocal: burns.stemPartsBurned(forSong: it.id),
                     stemsRemote: burns.stemsRemote(forSong: it.id))
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
        // A CONFIRMED foreign jump — the user played another row over the current track. This
        // sits BEFORE the not-in-set early return on purpose: a NON-member single taking over
        // is also "jumping to another row". The old track's clock is already gone (now-playing
        // was re-stamped by the new play), so `liveClock: false` → the tracker's samples decide.
        // No double-fire with `playNow(_:)`: that path moves `index` first, so this guard makes
        // its adopt a no-op.
        noteAdvanceAway(liveClock: false)
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
        noteUserTransport()          // a manual member play is the listener acting
        resetTrackAudible()
        // A manual member play makes a RESTORED (held) deck live: real audio is sounding, so
        // arm the end hooks + position sampler exactly as a resume would.
        exitHoldIfNeeded()
        index = pos
        waitingForLive = false
        persistSession(positionMs: 0)
        // Jumped onto a new track (a manual member play) — arm ITS repeat count, not the
        // previous track's leftover, so it loops the right number of times on natural end.
        currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[pos].repeatCount)
        reconcileRipWindow()
        if am {
            // The row ▶ started the stream but knows nothing about cards — run the same
            // handoff `playCurrent`'s AM branch does (macOS: abdicate; iOS: impersonate).
            handOffCardToAppleMusic(for: queue[pos])
        } else {
            // The EDITION ladder: a substituted row's burned file lives under the variant id,
            // a pre-edition burn under the base.
            if hasDeviceFile(queue[pos]) { loadedAnyDeviceTrack = true }
            player.setEndBoundary(ms: sharedFileEndBoundaryMs(queue[pos], startMs: rips.nowPlaying?.startMs),
                                  songStartMs: rips.nowPlaying?.startMs)
        }
        // The row's own play started the audio a hop ago: the lock takes it over from wherever
        // the AVPlayer's clock is now.
        applyStemLockOnTrackStart(resumeAtMs: nil, liveClock: true)
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
            startPlayCurrent(fresh: true)
            return
        }
        // REPEAT only on a NATURAL end: a track that played through loops in place while it has
        // plays left (a performance item's repeat count) instead of advancing. `normalizedRepeat`
        // clamps to [1, 99], so this can never spin forever; `fresh: false` keeps the counter.
        // An explicit skip or a dead source does NOT go through here — it calls `advanceToNext`.
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            startPlayCurrent(fresh: false)
            return
        }
        advanceToNext()
    }

    /// The current item FAILED mid-song (network error on a streamed mp3): a dead source —
    /// advance (no repeat), same ownership guard as `handleEnded`.
    private func handleFailed() {
        guard isRunning, index < queue.count,
              let npId = rips.nowPlaying?.songId, queue[index].matches(npId) else { return }
        DiagLog.shared.log("playback", "advance: item failed mid-song song=\(queue[index].id) index=\(index)")
        advanceToNext()
    }

    /// End of an Apple Music STREAMING track (MusicKit's player finished — or was system-⏭'d
    /// past — the song). Mirrors `handleEnded` but guards on the Apple Music now-playing id
    /// (the streaming path keys off `coordinator.appleMusic.nowPlaying`, never
    /// `rips.nowPlaying`, so the local ownership guard wouldn't match).
    ///
    /// `reason` decides the repeat semantics: only a `.natural` end honors repeat-one and the
    /// per-track repeat count. A `.systemSkip` (lock-screen/CarPlay ⏭ — iOS delivers it to
    /// MusicKit itself, which parks its one-song queue; the end-monitor detects the park) must
    /// advance exactly like the in-app ⏭. Without the discriminator, repeat-one replayed the
    /// same track on every car ⏭ — the set could never advance from the wheel.
    private func handleAppleMusicEnded(reason: AppleMusicPlaybackProvider.EndReason) {
        guard isRunning, index < queue.count,
              coordinator.activeBackend == .appleMusic,
              let npId = coordinator.appleMusic.nowPlaying?.songId,
              queue[index].matches(npId) else { return }
        if reason == .neverStarted {
            // MusicKit accepted the play but the stream never started: a dead source — advance
            // (never replay it under repeat-one; that would sit silent forever).
            DiagLog.shared.log("playback", "advance: AM never started song=\(queue[index].id) index=\(index)")
            advanceToNext()
            return
        }
        if reason == .systemSkip {
            NPLog.trace("setlist AM system-skip → advance from index \(index)")
            noteAdvanceAway()   // the live AM position reads ~0 here (the detection tick clobbers
                                // the clock) — SkipTracker's high-water samples carry the truth.
            advanceToNext(.user)   // the listener's ⏭ (car / lock screen) — never a cascade
            return
        }
        // Repeat-ONE (whole-session mode): replay the current AM track from the top.
        if repeatMode == .one {
            startPlayCurrent(fresh: true)
            return
        }
        if currentPlaysRemaining > 1 {
            currentPlaysRemaining -= 1
            startPlayCurrent(fresh: false)
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
    /// WHY the set is advancing — the cascade breaker's input. `.user`: a transport the listener
    /// pressed (resets the breaker). `.auto`: the sequencer moved on by itself after a start
    /// attempt (end of track, dead source, a stream that never started) — counted. A row this
    /// device can't play at all (device mode with no burn, an unresolvable studio/profile row)
    /// is `.unplayableHere`: an instant, deliberate skip, neither counted nor resetting.
    enum AdvanceCause { case user, auto, unplayableHere }

    private func advanceToNext(_ cause: AdvanceCause = .auto) {
        guard isRunning else { return }
        // Dead-air clock: an auto-advance is the between-tracks gap; a skip is listener-driven.
        DeadAirMeter.shared.transitionBegan(cause: cause == .user ? "skip" : "advance")
        switch cause {
        case .user:
            noteUserTransport()
        case .unplayableHere:
            break
        case .auto:
            // Halted: nothing advances by itself until the listener acts.
            if pausedByCascade { return }
            if cascade.shouldHalt(afterAudibleSeconds: trackAudibleSeconds) {
                haltCascade()
                return
            }
        }
        // The auto-advance = the "completed a track" ML signal (vs the explicit-skip lines above).
        DiagLog.shared.log("playback", "advance from=\(queue.indices.contains(index) ? queue[index].id : "?") index=\(index)/\(queue.count)")
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
                startPlayCurrent(fresh: true)
                return
            }
            // CRITIC-D — a DEVICE-mode set that reached the end having never loaded a single
            // burned file: raise the one-shot banner so the surface tells the DJ nothing was
            // playable on-device (rather than silently ending with no audio).
            let unplayable = playbackMode() == .device && !loadedAnyDeviceTrack
            // CAPTURE THE RUN'S IDENTITY FIRST — `stop()` nils `sourceSetlistId`, and every screen
            // that shows this banner needs to know whether the dead run was ITS run.
            let raisedBy = sourceSetlistId
            stop()                          // reached the end — tear down cleanly (clears the session)
            if unplayable {
                deviceQueueUnplayable = true
                deviceUnplayableSourceId = raisedBy
            }
        } else {
            persistSession(positionMs: 0)
            startPlayCurrent(fresh: true)
        }
    }

    /// The one in-flight `playCurrent` task. Every start CANCELS the previous one — a skip
    /// storm must land on the LAST pressed row, and cancellation is what stops a superseded
    /// row's still-resolving cloud fetch from loading its (now unwanted) audio over the newer
    /// row: the URLSession awaits inside the resolve throw on cancel, so the stale path dies
    /// before it reaches `player.load`. The `playGeneration` guard inside `playCurrent` is the
    /// backstop for a resolve already past its last cancellation point.
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// A cloud resolve slower than this hops to an on-device row (seconds).
    static var resolveStallSeconds: Double = 6
    /// A live capture still playing this long past its known length is abandoned (seconds).
    static var liveEndGraceSeconds: Double = 45
    /// How many upcoming rows get their presigned URL resolved ahead of the boundary.
    static let prefetchAhead = 3
    /// How far ahead a stalled resolve looks for an on-device row to play instead.
    static let hopLookahead = 50
    @ObservationIgnored private var resolveStallTask: Task<Void, Never>?
    /// Rows (by `Item.uid`) the stall hop abandoned in the CURRENT stall episode — consecutive
    /// hops with no row reaching first audio. Never hop targets until the episode ends
    /// (`endStallEpisode`: first audio, a user transport, stop).
    @ObservationIgnored private var stallEpisodeAbandoned: Set<UUID> = []
    /// Stall hops taken this run (diagnostics + tests).
    @ObservationIgnored private(set) var stallHopCount = 0
    #if DEBUG
    /// Tests: force `rowStartsInstantly` for a song id (nil ⇒ the real answer) — models an
    /// Apple Music row whose catalog Song is prefetched but whose audio still streams.
    @ObservationIgnored var startsInstantlyOverrideForTesting: ((String) -> Bool?)?
    #endif

    /// A row produced audio (or the listener acted / the run stopped): the stall episode is
    /// over, so a later stall may hop to a row abandoned in this one again.
    private func endStallEpisode(reason: String) {
        guard !stallEpisodeAbandoned.isEmpty else { return }
        DiagLog.shared.log("playback", "stall episode end reason=\(reason) abandoned=\(stallEpisodeAbandoned.count)")
        stallEpisodeAbandoned.removeAll()
    }
    @ObservationIgnored private var liveBackstopTask: Task<Void, Never>?
    /// The generation whose cloud resolve is still awaiting (nil when none is).
    @ObservationIgnored private var resolvingGeneration: Int?

    /// Resolve the next rows' presigned URLs WHILE this one plays (cloud mode, ripped rows with
    /// no device file) — the boundary then starts the next song with no network round trip.
    /// Apple Music rows get their catalog resolve run ahead too (`prefetchAppleMusic`) — that
    /// resolve used to start only at the boundary, the AM→AM gap.
    private func prefetchUpcoming() {
        guard isRunning, playbackMode() != .device, index + 1 < queue.count else { return }
        let rows = queue[(index + 1)..<min(queue.count, index + 1 + Self.prefetchAhead)]
            .filter { !StudioFactory.isStudioId($0.id) && !ProfileSourceStore.isProfileSongId($0.id) && !hasDeviceFile($0) }
        guard !rows.isEmpty else { return }
        // AM first: the presign prefetch caches rip URLs, which would flip a fallback-only AM
        // row to rip-first — decide the AM set on the ordering the start will see NOW.
        coordinator.prefetchAppleMusic(rows.map { ($0.id, $0.title, $0.artist, $0.variant) })
        rips.prefetchPresigned(rows.map(\.resolveId))
    }

    /// The Apple Music track is about to end (`onNearEnd`): when the NEXT row will play through
    /// our own AVPlayer (a burned file / a cloud rip), pre-arm a mixable audio session now. A
    /// locked phone cannot ACTIVATE a non-mixable session once MusicKit's audio stops
    /// ('!int', CannotInterruptOthers) — the AM→downloaded boundary sat silent 18–38 s until
    /// the app came to the foreground (drive logs 2026-10-24).
    private func handleAppleMusicNearEnd() {
        guard isRunning, index + 1 < queue.count else { return }
        let next = queue[index + 1]
        let local = rowOnDevice(next)
            || !coordinator.streamsAppleMusicFirst(id: next.id, title: next.title, artist: next.artist, variant: next.variant)
        guard local else { return }
        player.prearmHandoffSession(reason: "am-near-end next=\(next.id)")
    }

    /// Is this row playable from THIS device with no network (burned file / studio / profile)?
    private func rowOnDevice(_ it: Item) -> Bool {
        if StudioFactory.isStudioId(it.id) {
            guard let res = studioResolve?(it.id) else { return false }
            res.release?(); return true
        }
        if ProfileSourceStore.isProfileSongId(it.id) {
            guard let res = profileResolve?(it.id) else { return false }
            res.release?(); return true
        }
        return hasDeviceFile(it)
    }

    /// The cloud resolve for generation `gen` has run `resolveStallSeconds` with no audio (a
    /// cellular dead zone): play the next ON-DEVICE row now and DEFER the stalled row right
    /// behind it (reordered, never dropped). No on-device row ⇒ keep waiting (the request
    /// timeouts still bound it).
    private func armResolveStall(gen: Int) {
        resolveStallTask?.cancel()
        let wait = Self.resolveStallSeconds
        resolveStallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning,
                  self.resolvingGeneration == gen, self.playGeneration == gen,
                  self.index < self.queue.count else { return }
            // No eligible hop target ⇒ the current row is NOT touched: its resolve keeps going
            // (no cancel, no restart from zero) and plays the moment it lands. The request
            // timeouts / the AM never-started verdict / the cascade breaker still bound it.
            if !self.hopToOnDeviceRow(reason: "resolve stalled \(Int(wait))s") {
                DiagLog.shared.log("playback", "resolve stalled \(Int(wait))s song=\(self.queue[self.index].id) — no on-device/instant row to hop to (abandoned=\(self.stallEpisodeAbandoned.count)); keep buffering")
            }
        }
    }

    /// Can this row start with NO network round trip before play — on-device, a rip whose
    /// presigned URL is already cached, or an Apple Music row already pre-resolved? The stall
    /// hop's fallback when no on-device row is near: a row still waiting on a QUEUED rip sat
    /// silent 47 s with nothing to hop to (drive log 2026-10-25 05:15, "icameisaww").
    private func rowStartsInstantly(_ it: Item) -> Bool {
        #if DEBUG
        if let forced = startsInstantlyOverrideForTesting?(it.id) { return forced }
        #endif
        if StudioFactory.isStudioId(it.id) || ProfileSourceStore.isProfileSongId(it.id) { return false }
        return coordinator.startsInstantly(id: it.id, resolveId: it.resolveId, title: it.title,
                                           artist: it.artist, variant: it.variant)
    }

    /// Play the next ON-DEVICE row now (else the next row that starts instantly — see
    /// `rowStartsInstantly`) and DEFER the current (stalled) row right behind it — reordered,
    /// never dropped. Shared by the resolve stall, the start watchdog, and the supervisor's L3.
    /// Returns false when no such row is within `hopLookahead`.
    ///
    /// STALL EPISODE (drive log 2026-10-27 07:12, ios-3712BFDE): "instant" only means no
    /// round trip BEFORE play — an Apple Music row whose catalog Song is prefetched still
    /// STREAMS, so on weak signal it stalls too, and two such rows hopped back and forth every
    /// 6 s, each hop cancelling the other's partial buffer. So every row a hop abandons is
    /// remembered until some row reaches first audio (or the listener transports / stops), and
    /// is never a hop target again within that episode. Several distinct hops per episode are
    /// fine; with no eligible row left the caller leaves the current row buffering.
    @discardableResult
    private func hopToOnDeviceRow(reason: String) -> Bool {
        guard index < queue.count else { return false }
        let stalled = queue[index]
        let end = min(queue.count, index + 1 + Self.hopLookahead)
        guard index + 1 < end else { return false }
        let range = (index + 1)..<end
        let abandoned = stallEpisodeAbandoned.union([stalled.uid])
        let eligible = range.filter { !abandoned.contains(queue[$0].uid) }
        let kind: String
        let j: Int
        if let d = eligible.first(where: { rowOnDevice(queue[$0]) }) { j = d; kind = "on-device" }
        else if let c = eligible.first(where: { rowStartsInstantly(queue[$0]) }) { j = c; kind = "instant" }
        else { return false }
        stallEpisodeAbandoned.insert(stalled.uid)
        stallHopCount &+= 1
        // [.., stalled, x, y, row, ..] → [.., row, stalled, x, y, ..]: the hop target plays NOW
        // and the stalled row is the very next one (instant by then if its download landed).
        // The stalled row's in-flight resolve is cancelled + superseded by the restart below and
        // must NEVER start it early — it plays only when the hop target ends.
        let row = queue.remove(at: j)
        queue.insert(row, at: index)
        DiagLog.shared.log("playback", "\(reason) song=\(stalled.id) → hop to \(kind) \(row.id) (deferred stalled row) abandoned=\(stallEpisodeAbandoned.count)")
        persistSession(positionMs: 0)
        startPlayCurrent(fresh: true)
        return true
    }

    /// A LIVE capture (stream-through-rip) has no length boundary and ends only on the server's
    /// ENDLIST — a wedged capture / a playlist reload dying on cellular left the set silent on
    /// `waitingForLive` until someone pressed Next. Backstop: once it has PLAYED its known length
    /// plus `liveEndGraceSeconds` (time the listener had it paused doesn't count), advance.
    private func armLiveBackstop(gen: Int, lengthMs: Int?) {
        liveBackstopTask?.cancel()
        guard let lengthMs, lengthMs > 0 else { return }
        let budget = Double(lengthMs) / 1000 + Self.liveEndGraceSeconds
        let step = min(1.0, max(0.05, Self.liveEndGraceSeconds / 2))
        liveBackstopTask = Task { [weak self] in
            var played = 0.0
            while played < budget {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isRunning, self.playGeneration == gen,
                      self.waitingForLive else { return }
                if !self.player.pausedByListener { played += step }   // a deliberate pause doesn't count
            }
            guard let self, !Task.isCancelled, self.playGeneration == gen, self.waitingForLive else { return }
            DiagLog.shared.log("playback", "advance: live capture past its length+grace song=\(self.queue.indices.contains(self.index) ? self.queue[self.index].id : "?")")
            self.advanceToNext()
        }
    }

    /// THE way to invoke `playCurrent` — every call site funnels through here so the
    /// cancel-the-previous rule can't be forgotten at one of them.
    private func startPlayCurrent(fresh: Bool = true, resumeAtMs: Int? = nil) {
        // Every from-0:00 start announces itself to the skip tracker (a restore-resume
        // re-enters MID-song, so it must not re-zero the high-water mark). For a track change
        // this is redundant (the play hooks re-arm the tracker via `record`); for the replay
        // paths that record nothing — repeat-one / per-track repeat / duplicate row /
        // same-song play-now — it is the ONLY reset the high-water mark gets.
        if resumeAtMs == nil, isRunning, index < queue.count { onTrackRestart?(queue[index].id) }
        resetTrackAudible()
        reconcileRipWindow()     // the playhead (may have) moved: rips outside the window go
        playTask?.cancel()
        playTask = Task { await playCurrent(fresh: fresh, resumeAtMs: resumeAtMs) }
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
        // A task that was cancelled BEFORE it got to run (a skip storm enqueues many) must do
        // nothing at all — above all it must NOT claim a generation below: a dead straggler
        // bumping the counter would rob the one LIVE task of its claim, and its dead-source
        // advance/stop would then never run (a foreign single that failed to resolve kept its
        // run "running" forever — the puzzle takeover test caught exactly that).
        if Task.isCancelled { return }
        // Claim the generation for THIS start attempt — every branch, including the synchronous
        // local-file ones, so an older cloud resolve still in flight is superseded no matter
        // what kind of row the newer skip landed on (see the SUPERSEDE GUARD at the await).
        playGeneration &+= 1
        let playGen = playGeneration
        // …and at the COORDINATOR too: the local-file branches below never call
        // `coordinator.play`, so without this an older row's resolve still in flight (the row the
        // stall hop just deferred) has nothing newer to be superseded by and can land its audio
        // over this row — the "jumps back to the buffered song" bug (drive log 2026-10-28 03:01).
        coordinator.supersedePendingPlay()
        let it = queue[index]
        resolveStallTask?.cancel(); resolveStallTask = nil
        liveBackstopTask?.cancel(); liveBackstopTask = nil
        startStallTask?.cancel(); startStallTask = nil   // the previous start's watchdog is moot
        endStartWindow(reason: "superseded")              // …and so is its runway
        DeadAirMeter.shared.transitionBegan(cause: "start")   // no-op inside an open advance/skip
        resolvingGeneration = nil
        prefetchUpcoming()   // the NEXT songs' URLs resolve while this one plays
        // P1-7: every branch that actually STARTS audio opens a start window (runway until first
        // audio) just before it loads; local-lane loads also arm the start watchdog right after.
        // (An unplayable row skips without one — a device-mode skip storm must not churn runways.)
        func startedLocal(_ backend: String) {
            logTrackStart(it, backend: backend, resumeAtMs: resumeAtMs)
            armStartStall(gen: playGen, songId: it.id)
        }

        // STUDIO rows (sample/loop/pattern — spec §8): resolved via the StudioStore seam
        // BEFORE burns/coordinator, and ABOVE the device/cloud split — a studio item is a
        // LOCAL file in both modes (there is no cloud copy of a user's sample), so mode
        // must not gate it. The item's own snapshot title/artist ("Studio") label the
        // now-playing; no startMs/end boundary — studio files are per-item with a natural
        // end. Unresolvable ⇒ skip forward like any dead source.
        if StudioFactory.isStudioId(it.id) {
            guard let res = studioResolve?(it.id) else {
                advanceToNext(.unplayableHere)
                return
            }
            // A playable studio row IS on-device audio: count it so a device-mode set
            // made of loops never raises the "no burned files" banner (CRITIC-D).
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
            beginStartWindow(it, gen: playGen)
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: nil, rips: rips, player: player,
                          endBoundaryMs: nil, atMs: resumeAtMs, release: res.release)
            applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)
            startedLocal("studio")
            return
        }

        // PROFILE ("Pocket DJ") rows: device-local original resolved via the profileResolve seam,
        // ABOVE the device/cloud split like studio rows — a profile item is a local file in both
        // modes. `pdj_` is outside StudioFactory.studioPrefixes, so this never collides with the
        // studio arm; unresolvable (absent asset) ⇒ skip forward.
        if ProfileSourceStore.isProfileSongId(it.id) {
            guard let res = profileResolve?(it.id) else {
                advanceToNext(.unplayableHere)
                return
            }
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()
            beginStartWindow(it, gen: playGen)
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: nil, rips: rips, player: player,
                          endBoundaryMs: nil, atMs: resumeAtMs, release: res.release)
            applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)
            startedLocal("profile")
            return
        }

        let mode = playbackMode()

        // DEVICE mode: play ONLY a burned local file. A track with no burned file is SKIPPED
        // (advance now — no end event would ever fire). If the whole queue has none, the
        // end-of-set advance raises the CRITIC-D banner. Mode-flip mid-set applies to the
        // NEXT track: the current track keeps playing under the mode it started with.
        // The EDITION this row should play (`EditionPolicy`, stamped at `play()`). Burned-file
        // lookups walk its storage ladder: the wanted edition, then — for a PREFERENCE only,
        // never for a clean-only restriction — the LEGACY un-suffixed burn, then the other
        // edition. `isWanted == false` ⇒ we degraded onto some other cut and must lazily
        // acquire the right one (`lazyRipWantedEdition`).
        let decision = it.editionDecision

        if mode == .device {
            // The DECISION (not the bare id) at every burned-file lookup: a cleanOnly
            // substitution must play the CLEAN variant's burned file — an explicit base burn
            // present on the device is deliberately not a fallback (skip-not-fallback).
            // `songId: it.id` (base) stays in playLocalFile so history/stats key the real song.
            if let res = burns.localURLForPlayback(forSong: it.id, decision: decision) {
                loadedAnyDeviceTrack = true
                coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
                if !res.isWanted { lazyRipWantedEdition(it) }
                // SHARED helper so nowPlaying + the inline player + the row toggle stay
                // consistent with the single-row burned path. `res.release` keeps a user-folder
                // file's security scope open through playback.
                let start = burns.startMs(forSong: res.id)
                beginStartWindow(it, gen: playGen)
                playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                              startMs: start, rips: rips, player: player,
                              endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: start),
                              atMs: resumeAtMs, release: res.release)
                applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)
                startedLocal("burned")
                // Finite local file → the end notification (or length boundary) advances us.
            } else {
                // Nothing on device for this edition. Device mode can't stream, so the row is
                // skipped — but ask for the wanted edition so the NEXT pass has it.
                lazyRipWantedEdition(it)
                advanceToNext(.unplayableHere)   // no on-device file for this track → skip it
            }
            return
        }

        // CLOUD mode (default): prefer a burned local file when present (zero-latency,
        // offline), else stream / rip-on-demand via the coordinator (Apple Music → rip).
        // Same edition rule as device mode — a substituted row only ever plays its variant's
        // audio (burned, streamed, or ripped), never the base explicit cut.
        if let res = burns.localURLForPlayback(forSong: it.id, decision: decision) {
            loadedAnyDeviceTrack = true
            coordinator.stopAppleMusicIfActive()   // advancing off a stream → silence it
            if !res.isWanted { lazyRipWantedEdition(it) }
            let start = burns.startMs(forSong: res.id)
            beginStartWindow(it, gen: playGen)
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: start, rips: rips, player: player,
                          endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: start),
                          atMs: resumeAtMs, release: res.release)
            applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)
            startedLocal("burned")
        } else if stemLock.wantsStems, let url = stemLockStreamedFile?(it.resolveId) {
            // STEM LOCK: the prefetch finished this song as a per-song CUT stream (an analog cut
            // isn't adopted into the burn ledger) — play that local file, so the carried stems
            // can take it over, instead of streaming the same bytes again.
            coordinator.stopAppleMusicIfActive()
            beginStartWindow(it, gen: playGen)
            playLocalFile(url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: nil, rips: rips, player: player,
                          endBoundaryMs: nil, atMs: resumeAtMs)
            applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)
            startedLocal("stemcut")
        } else {
            // SILENCE THE OUTGOING TRACK FIRST. Resolving a cloud row is an async round-trip
            // (an Apple Music lookup, or a rip that may still be queued), and until it lands
            // the engine still holds the PREVIOUS row's item. Left running, it keeps sounding
            // under the new row's title — and then swallows the next ▶, because
            // `PlayerEngine.toggle()` resumes whatever it holds, not what the deck shows
            // (Levi, 2026-08-17: the deck read "Waiting" while "FR FR" played on). A skip that
            // goes briefly silent while the next source resolves is the honest behaviour.
            // Apple Music is left alone deliberately: when IT is the active backend the
            // provider cycle in `coordinator.play` stops it only if the backend actually
            // changes, which keeps an AM→AM advance gapless.
            if coordinator.activeBackend != .appleMusic { player.stop() }
            // INSTANT metadata: the lock-screen/CarPlay card shows THIS row's title/artist now,
            // while the audio resolves — so skipping through a set reads like seeking, not like
            // seconds of the previous song's card per press (Levi, 2026-08-19). Arbiter-guarded
            // inside; a resolve that lands on Apple Music replaces it (iOS impersonation writes
            // the real card; macOS `idleForExternalPlayback` scrubs ours for MusicKit's own).
            player.announceUpcoming(title: it.title, artist: it.artist, songId: it.id)
            // SUPERSEDE GUARD for rapid skips: this playCurrent claimed `playGen` at entry; a
            // newer skip/jump claims a newer one (every branch bumps it, including the
            // synchronous local ones). If, by the time OUR slow resolve returns, someone newer
            // has claimed the deck, this run must do NOTHING — neither advance, nor arm
            // boundaries for, nor hand the card to, a track the listener already skipped past
            // (the stems-toggle generation discipline: commit only at your own generation).
            // ZERO DEAD AIR in the gap: hold a background runway (a locked phone / CarPlay is
            // otherwise suspended here — nothing renders audio) and arm the stall hop. The runway
            // is the START WINDOW's: held across the resolve AND until first audio (P1-7).
            beginStartWindow(it, gen: playGen)
            resolvingGeneration = playGen
            armResolveStall(gen: playGen)
            let t0 = Date()
            await coordinator.play(id: it.id, title: it.title, artist: it.artist,
                                   atMs: resumeAtMs, variant: it.variant)
            if resolvingGeneration == playGen { resolvingGeneration = nil }
            if playGen == playGeneration { resolveStallTask?.cancel(); resolveStallTask = nil }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if ms > 3000 || coordinator.lastErrorMessage != nil {
                DiagLog.shared.log("playback", "resolve song=\(it.id) ms=\(ms) err=\(coordinator.lastErrorMessage != nil ? 1 : 0) cancelled=\(Task.isCancelled ? 1 : 0) backend=\(coordinator.activeBackend.map { "\($0)" } ?? "-")")
            }
            // `Task.isCancelled` first: a superseding skip cancels this task, which makes the
            // resolve throw into `lastErrorMessage` — without this check the error branch below
            // would read that CANCELLATION as a dead source and spuriously advance the deck a
            // second row (the canceller may not have bumped the generation yet when we resume).
            guard !Task.isCancelled, playGen == playGeneration else { return }   // superseded
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
                applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)   // (unavailable: not a local file)
                // The start window stays open until MusicKit REPORTS playing (`onFirstAudio`) or
                // its cap; the provider's never-started verdict owns a dead AM start.
                if coordinator.appleMusic.audioConfirmed {
                    DeadAirMeter.shared.firstAudio()
                    endStallEpisode(reason: "firstAudio.appleMusic")
                    endStartWindow(reason: "firstAudio.appleMusic")
                }
                logTrackStart(it, backend: "appleMusic", resumeAtMs: resumeAtMs)
                return
            }
            applyStemLockOnTrackStart(resumeAtMs: resumeAtMs)       // a stream: full mix, lock kept
            startedLocal(player.isLive ? "hls" : "presigned")
            // A live HLS capture has no natural end → don't rely on the hook; offer "Next".
            if player.isLive {
                waitingForLive = true
                armLiveBackstop(gen: playGen, lengthMs: it.lengthMs)
            } else {
                // A cloud rip of an ANALOG album is ONE shared mp3 + per-song startMs (the rip
                // server transcodes the whole side once), so its natural end only fires at the
                // END OF THE WHOLE FILE — arm the per-song length boundary to advance at this
                // track's own end. A digital cloud rip is per-song (startMs nil → no boundary,
                // the natural end governs). `nowPlaying.startMs` is what the rip path resolved.
                player.setEndBoundary(ms: sharedFileEndBoundaryMs(it, startMs: rips.nowPlaying?.startMs),
                                      songStartMs: rips.nowPlaying?.startMs)
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
                 variant: $0.variant.flatMap(SongVariant.init(rawValue:)),
                 editionLocked: $0.editionLocked ?? false)
        }
        index = min(max(0, snap.index), queue.count - 1)
        // The snapshot's rows ARE the session projection — warm the memo with them (the queue
        // didSet above just cleared it) so the first persist after ▶ (`resumeFromHold`'s
        // adoption) stays SYNCHRONOUS instead of deferring to the detached cold build. Without
        // this, a kill right after ▶ lost the adoption entirely and the restored set never
        // persisted its position (`updatePosition` no-ops while no session is current).
        sessionRowsMemo = snap.queue
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
        // The session's Stem Lock (and the stem set it carries) rides the snapshot too: the
        // first ▶ (`resumeFromHold` → `playCurrent`) re-applies it to the resumed track.
        stemLock = snap.stemLock ?? StemLockState()
        stemLockUnavailableSongId = nil
        canonicalOrder = shuffleEnabled ? queue.map(\.uid) : nil
        currentPlaysRemaining = CollectionMembership.normalizedRepeat(queue[index].repeatCount)
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = nil
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
        // P0-2: while nobody owns the card, the HELD set is the remote target — a parked Mix
        // snapshot must not answer the head unit's ▶ (the card itself stays untouched: the
        // engine's card writes are still idle-guarded).
        NowPlayingArbiter.shared.prefer(player)
        // P0-1: the head unit's play-on-connect often lands BEFORE this restore ran (refused and
        // latched by the idle engine) — honour it now, once, if it is recent.
        if let t = player.consumePendingRemotePlay(maxAge: Self.pendingRemotePlayMaxAge) {
            DiagLog.shared.telemetry("action", "remote play (pre-restore, \(Int(-t.timeIntervalSinceNow))s ago) → resume held session")
            resumeFromHold()
        }
    }

    /// The first ▶ after a restore: arm the engine hooks, then start REAL playback of the
    /// current track AT the saved position (local files seek via `playLocalFile(atMs:)`;
    /// Apple Music re-plays + seeks via the coordinator's cue seam). The playback surfaces
    /// (NowPlayingPanel / WidgetSync) route their play-toggle here while `isHeldForResume`.
    func resumeFromHold() {
        guard isRunning, isHeldForResume else { return }
        DiagLog.shared.telemetry("action", "resume held session")
        noteUserTransport()
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
        startPlayCurrent(fresh: false, resumeAtMs: at)
    }

    /// ▶ on a deck whose CURRENT row never actually started sounding — the cloud resolve
    /// produced no audio (a rip still queued, a stream that missed), so the engine is idle
    /// and a plain `toggle()` is simply REFUSED, leaving ▶ dead until the row is skipped
    /// past. Re-resolve and start the displayed row instead, so ▶ always means "play what
    /// the deck is showing". `fresh: false` on purpose — this is a RETRY of the current row,
    /// so its repeat counter must not be re-armed. Returns false when there is nothing to
    /// start (no run, or a held deck, which routes to `resumeFromHold` instead).
    @discardableResult
    func startCurrent(by caller: String = "?") -> Bool {
        guard isRunning, index < queue.count, !isHeldForResume else { return false }
        DiagLog.shared.log("playback", "start current by=\(caller) song=\(queue[index].id) pending=\(isStartPending ? 1 : 0)")
        noteUserTransport()
        startPlayCurrent(fresh: false)
        return true
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
        guard sessionStore != nil, isRunning else { return }
        guard let rows = sessionRowsMemo else {
            // COLD memo — the first snapshot right after a queue commit. Projecting a 26k-track
            // queue inline was a main-actor stall landing exactly on the ▶/🔀 tap, so the map
            // runs DETACHED and its landing persists with the then-current state. The explicit
            // `positionMs` intent (play/index moves pass 0) is carried across the hop; a queue
            // that moved on invalidates the build via `queueGeneration` and re-kicks.
            if positionMs != nil {
                pendingColdPositionMs = positionMs
                pendingColdPositionGen = queueGeneration
            }
            guard !sessionRowsBuildInFlight else { return }
            sessionRowsBuildInFlight = true
            let gen = queueGeneration
            let q = queue
            Task.detached(priority: .userInitiated) { [weak self] in
                let rows = Self.projectSessionRows(q)
                await MainActor.run {
                    guard let self else { return }
                    self.sessionRowsBuildInFlight = false
                    guard self.isRunning else { self.pendingColdPositionMs = nil; return }
                    guard self.queueGeneration == gen else {
                        // Re-kick for the new queue — carrying the explicit position intent
                        // ONLY if it was stamped against that queue. A stamp from the
                        // superseded generation (the old play's 0, a pre-edit resume offset)
                        // must not ride onto the new queue's snapshot.
                        let carried = self.pendingColdPositionGen == self.queueGeneration
                            ? self.pendingColdPositionMs : nil
                        self.pendingColdPositionMs = nil
                        self.persistSession(positionMs: carried)
                        return
                    }
                    self.sessionRowsMemo = rows
                    let pos = self.pendingColdPositionMs
                    self.pendingColdPositionMs = nil
                    self.persistSnapshot(rows: rows, positionMs: pos)
                }
            }
            return
        }
        persistSnapshot(rows: rows, positionMs: positionMs)
    }

    /// Land the freshest session snapshot SYNCHRONOUSLY — the scenePhase `.background` flush.
    /// The first snapshot after a queue commit is normally deferred behind the detached 26k
    /// projection above; a suspension→kill inside that window (tap ▶ then immediately swipe
    /// home) would persist NOTHING for the new queue, so the relaunch restored the PREVIOUS
    /// session — losing durability at the exact moment durable sessions exist for. Suspension
    /// is imminent and no UI is on screen here, so paying the projection inline is correct.
    func flushSessionSnapshotNow() {
        guard sessionStore != nil, isRunning else { return }
        if sessionRowsMemo == nil { sessionRowsMemo = Self.projectSessionRows(queue) }
        // Consume the pending explicit intent (only if stamped against THIS queue); the
        // still-in-flight detached build's landing then persists a harmless live-position
        // duplicate of the same rows.
        let pos = pendingColdPositionGen == queueGeneration ? pendingColdPositionMs : nil
        pendingColdPositionMs = nil
        persistSession(positionMs: pos)
    }

    /// The pure `queue` → session-row projection (shared by the warm sync path's memo fill —
    /// historically inline — and the detached cold build above).
    private nonisolated static func projectSessionRows(_ queue: [Item]) -> [PlaybackSessionStore.Row] {
        queue.map {
            PlaybackSessionStore.Row(songId: $0.id, title: $0.title, artist: $0.artist,
                                     lengthMs: $0.lengthMs, repeatCount: $0.repeatCount,
                                     variant: $0.variant?.rawValue,
                                     editionLocked: $0.editionLocked ? true : nil)
        }
    }

    /// Assemble + save the snapshot from an already-projected row array (memo-warm callers
    /// come straight here; the cold build lands here after its detached projection).
    private func persistSnapshot(rows: [PlaybackSessionStore.Row], positionMs: Int?) {
        guard let sessionStore, isRunning else { return }
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
            stemLock: stemLock.enabled ? stemLock : nil,
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

    /// The current track's duration in ms, best-effort (nil = unknown, which the SkipTracker
    /// treats as "never a skip"). Prefers the catalog length stamped on the queue row; falls
    /// back to the owning backend's clock.
    private func currentDurationMs() -> Int? {
        guard isRunning, index < queue.count else { return nil }
        if let ms = queue[index].lengthMs, ms > 0 { return ms }
        if coordinator.activeBackend == .appleMusic {
            let d = coordinator.appleMusic.durationSeconds
            return d > 0 ? Int(d * 1000) : nil
        }
        // `player.duration` is the WHOLE FILE — only trust it when this row is not a slice of
        // a shared album rip (startMs 0 ⇒ the file IS the song).
        if (rips.nowPlaying?.startMs ?? 0) == 0, player.duration > 0 { return Int(player.duration * 1000) }
        return nil
    }

    /// True when `destinationId` IS the song the deck is currently on — the transport is a
    /// RESTART ("play it from the top"), not an advance-away, so the skip hook stays silent.
    /// Base-id comparison: a substituted row plays under its variant id while the incoming
    /// destination carries the base one.
    private func isRestartOfCurrent(_ destinationId: String) -> Bool {
        guard isRunning, index < queue.count else { return false }
        return SongVariant.baseId(destinationId) == SongVariant.baseId(queue[index].id)
    }

    /// Report an advance-away to the skip hook — called by the user-initiated transports
    /// BEFORE the index moves / a hold exits, so `sessionPositionMs()` still reads the OLD
    /// track. `liveClock: false` = the old track's clock is already gone (the adopt path);
    /// the tracker falls back to its sampled high-water mark.
    private func noteAdvanceAway(liveClock: Bool = true) {
        guard isRunning, index < queue.count else { return }
        // A LIVE HLS capture has no natural end — its "Next" affordance is the ONLY way
        // forward, and the listener has heard 100% of the audio that exists so far. Advancing
        // off it sits with the length-boundary advance on the not-a-skip list.
        guard !waitingForLive else { return }
        onAdvanceAway?(queue[index].id, liveClock ? sessionPositionMs() : nil, currentDurationMs())
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
                self.sampleAudible()
                self.sessionStore?.updatePosition(ms: self.sessionPositionMs(),
                                                  isPlaying: self.sessionIsPlaying())
                if self.index < self.queue.count {
                    self.onPositionSample?(self.queue[self.index].id, self.sessionPositionMs(),
                                           self.currentDurationMs())
                }
            }
        }
    }
}

// MARK: - Rip-ahead window + cascade breaker

extension SetlistPlayer {
    /// The playing row + the next `PlaybackRipWindow.ahead` rows, as rip ids (base + resolve).
    func currentRipWindowIds() -> Set<String> {
        guard isRunning, index < queue.count else { return [] }
        let end = min(queue.count, index + 1 + PlaybackRipWindow.ahead)
        return PlaybackRipWindow.windowIds(rows: queue[index..<end].map { ($0.id, $0.resolveId) }, index: 0)
    }

    /// `RipsStore.playbackRipGate`: may a playback rip for `id` be requested right now? A song
    /// that isn't in the running set (no set, or a Browse single) is not this session's call.
    func playbackRipAllowed(_ id: String) -> Bool {
        guard isRunning, !isHeldForResume, inRunningQueue(SongVariant.baseId(id)) else { return true }
        return currentRipWindowIds().contains(id)
    }

    /// `RipsStore.onPlaybackRipQueued`: the server queued a playback rip. Track it when it is
    /// this session's (a member row inside the window); one that landed after the playhead
    /// already left the window (a slow POST under a skip storm) is cancelled at once.
    func notePlaybackRipQueued(_ id: String) {
        guard isRunning, inRunningQueue(SongVariant.baseId(id)), !rips.isUserRequestedRip(id) else { return }
        if currentRipWindowIds().contains(id) {
            ripWindow.record(id)
        } else {
            cancelRipIds([id], reason: "late-outside-window")
        }
    }

    /// Cancel every tracked rip that is no longer inside the window.
    func reconcileRipWindow() {
        guard isRunning, !ripWindow.requested.isEmpty else { return }
        cancelRipIds(ripWindow.evict(keeping: currentRipWindowIds()), reason: "outside-window")
    }

    /// Coalesce queue-edit reconciles (a reshuffle and a track start in one turn reconcile once).
    func scheduleRipWindowReconcile() {
        guard !ripWindow.requested.isEmpty, !ripWindowReconcileQueued else { return }
        ripWindowReconcileQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ripWindowReconcileQueued = false
            self.reconcileRipWindow()
        }
    }

    /// The session is ending (stop / replaced by a fresh `play`): cancel everything it queued
    /// except the row that was sounding.
    func endRipWindowSession(reason: String) {
        let playing: Set<String> = index < queue.count ? [queue[index].id, queue[index].resolveId] : []
        cancelRipIds(ripWindow.endSession(playing: playing), reason: reason)
    }

    private func cancelRipIds(_ ids: [String], reason: String) {
        // Belt and braces: a user surface may have asked for the same song since we tracked it.
        let ids = ids.filter { !rips.isUserRequestedRip($0) }
        guard !ids.isEmpty else { return }
        DiagLog.shared.log("rip", "rip window cancel n=\(ids.count) reason=\(reason) ids=\(ids.joined(separator: ","))")
        if let cancelPlaybackRips {
            cancelPlaybackRips(ids)
        } else {
            let rips = self.rips
            Task { await rips.cancelCollection(ids) }
        }
    }

    // MARK: Audible time

    func resetTrackAudible() {
        trackAudibleSeconds = 0
        lastAudibleSample = Date()
    }

    /// Whether the CURRENT track is producing audio right now (by whichever backend owns it).
    /// Apple Music counts only once MusicKit has REPORTED playing — its `isPlaying` is set the
    /// moment `play()` is accepted, which a stream that never starts would otherwise count.
    private func currentTrackAudible() -> Bool {
        guard !isHeldForResume else { return false }
        if mixEngaged, let dsp { return dsp.isPlaying }
        if coordinator.activeBackend == .appleMusic {
            return coordinator.appleMusic.isPlaying && coordinator.appleMusic.audioConfirmed
        }
        return player.isPlaying && player.hasLoadedItem
    }

    /// One session-ticker sample: accumulate audible time; once the track has really played,
    /// the run is not a cascade (reset + clear any stale notice) and, past `heardSeconds`, its
    /// rip is exempt from window cancellation (it is a song the listener heard).
    func sampleAudible() {
        let now = Date()
        let dt = lastAudibleSample.map { now.timeIntervalSince($0) } ?? 0
        lastAudibleSample = now
        guard currentTrackAudible() else { return }
        addAudibleSeconds(min(max(0, dt), 5))
    }

    /// Test seam + the ticker's sink.
    func addAudibleSeconds(_ seconds: Double) {
        let before = trackAudibleSeconds
        trackAudibleSeconds += seconds
        if before < AutoAdvanceCascadeBreaker.minAudibleSeconds,
           trackAudibleSeconds >= AutoAdvanceCascadeBreaker.minAudibleSeconds {
            cascade.reset()
            if !pausedByCascade { playbackNotice = nil }
        }
        if before < PlaybackRipWindow.heardSeconds, trackAudibleSeconds >= PlaybackRipWindow.heardSeconds,
           isRunning, index < queue.count {
            ripWindow.keep([queue[index].id, queue[index].resolveId])
        }
    }

    // MARK: Cascade breaker

    /// The listener acted: whatever happened before is not a cascade any more.
    func noteUserTransport() {
        cascade.reset()
        endStallEpisode(reason: "user")
        pausedByCascade = false
        playbackNotice = nil
    }

    /// Stop auto-advancing: hold the CURRENT row (the queue position is kept), silence it, and
    /// say why. ▶ retries this row (`startCurrent`); ⏭/⏮/jump move on as usual.
    func haltCascade() {
        let row = index < queue.count ? queue[index].id : "?"
        let backend = coordinator.activeBackend.map { "\($0)" } ?? "-"
        DiagLog.shared.log("playback", "cascade-stop song=\(row) index=\(index)/\(queue.count) quickAdvances=\(AutoAdvanceCascadeBreaker.limit) backend=\(backend) audible=\(Int(trackAudibleSeconds))s")
        playTask?.cancel(); playTask = nil
        playGeneration &+= 1                  // a resolve still in flight must not start audio now
        resolveStallTask?.cancel(); resolveStallTask = nil
        liveBackstopTask?.cancel(); liveBackstopTask = nil
        startStallTask?.cancel(); startStallTask = nil
        endStartWindow(reason: "cascade-halt")
        DeadAirMeter.shared.transitionAbandoned(reason: "cascade-halt")
        waitingForLive = false
        if coordinator.activeBackend == .appleMusic { coordinator.appleMusic.pausePlayback() }
        player.pause()
        player.noteListenerIntent(false)      // halted: nothing may "keep playing" it until ▶
        pausedByCascade = true
        playbackNotice = coordinator.appleMusic.isReady ? Self.appleMusicInterruptedNotice
                                                         : Self.cascadeGenericNotice
        persistSession()
    }

    /// The Apple Music stream was interrupted from outside (not ended): the row holds, paused at
    /// the interruption point; ▶ resumes it (the provider re-queues + seeks). Tell the listener.
    func handleAppleMusicInterrupted() {
        guard isRunning, index < queue.count, coordinator.activeBackend == .appleMusic,
              let npId = coordinator.appleMusic.nowPlaying?.songId, queue[index].matches(npId) else { return }
        DiagLog.shared.log("playback", "hold: AM interrupted song=\(queue[index].id) index=\(index) — not advancing")
        playbackNotice = Self.appleMusicInterruptedNotice
        persistSession()
    }
}
