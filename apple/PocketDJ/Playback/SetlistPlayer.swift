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
        didSet { sessionRowsMemo = nil; queueIdsMemo = nil; queueGeneration &+= 1 }
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
    /// `preStamped: true` ⇒ `items` already went through `prepareStamped` (the off-main
    /// edition stamp) — skip the synchronous 26k-row re-stamp. Every other caller keeps the
    /// exact sync behavior.
    func play(_ items: [Item], sourceSetlistId: String? = nil, preStamped: Bool = false) {
        guard !items.isEmpty else { return }
        // A fresh play over a RUNNING set is "advancing away" from its current track (the
        // replace is user-initiated); starting from idle advances away from nothing — and
        // neither does replacing the set with one that OPENS ON THE SAME SONG (replaying the
        // current set from its collection to hear this song from the top is a restart, not a
        // skip of the song the user actively chose again).
        if isRunning, let first = items.first, !isRestartOfCurrent(first.id) { noteAdvanceAway() }
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
        Task { await rips.requestEditionRipIfNeeded(base: it.id, decision: decision) }
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
        coordinator.appleMusic.onTrackEnded = { [weak self] reason in self?.handleAppleMusicEnded(reason: reason) }
        // The system remote ⏮ during a stream also lands in MusicKit (it rewinds its one-song
        // queue to 0:00); the provider detects the rewind and fires this so ⏮ steps the SET back.
        coordinator.appleMusic.onTrackRestarted = { [weak self] in self?.handleAppleMusicRestarted() }
    }

    /// Stop the sequence + clear now-playing; resets so the toolbar flips back to Play.
    func stop() {
        playTask?.cancel(); playTask = nil // a resolve still in flight must not load into a stopped deck
        playGeneration &+= 1               // …and its post-await bookkeeping must stand down
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
    func clearDeviceUnplayable() {
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = nil
    }

    /// Manually advance (used by the live-track "Next" affordance + lock-screen NEXT).
    func skipNext() {
        noteAdvanceAway()
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
        // Jumping onto ANOTHER OCCURRENCE of the same song is a restart, not a skip of it.
        if !isRestartOfCurrent(queue[pos].id) { noteAdvanceAway() }
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
            // The EDITION ladder: a substituted row's burned file lives under the variant id,
            // a pre-edition burn under the base.
            if hasDeviceFile(queue[pos]) { loadedAnyDeviceTrack = true }
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
        if reason == .systemSkip {
            NPLog.trace("setlist AM system-skip → advance from index \(index)")
            noteAdvanceAway()   // the live AM position reads ~0 here (the detection tick clobbers
                                // the clock) — SkipTracker's high-water samples carry the truth.
            advanceToNext()
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

    /// THE way to invoke `playCurrent` — every call site funnels through here so the
    /// cancel-the-previous rule can't be forgotten at one of them.
    private func startPlayCurrent(fresh: Bool = true, resumeAtMs: Int? = nil) {
        // Every from-0:00 start announces itself to the skip tracker (a restore-resume
        // re-enters MID-song, so it must not re-zero the high-water mark). For a track change
        // this is redundant (the play hooks re-arm the tracker via `record`); for the replay
        // paths that record nothing — repeat-one / per-track repeat / duplicate row /
        // same-song play-now — it is the ONLY reset the high-water mark gets.
        if resumeAtMs == nil, isRunning, index < queue.count { onTrackRestart?(queue[index].id) }
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
                playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                              startMs: start, rips: rips, player: player,
                              endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: start),
                              atMs: resumeAtMs, release: res.release)
                // Finite local file → the end notification (or length boundary) advances us.
            } else {
                // Nothing on device for this edition. Device mode can't stream, so the row is
                // skipped — but ask for the wanted edition so the NEXT pass has it.
                lazyRipWantedEdition(it)
                advanceToNext()   // no on-device file for this track → skip it
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
            playLocalFile(res.url, songId: it.id, title: it.title, artist: it.artist,
                          startMs: start, rips: rips, player: player,
                          endBoundaryMs: sharedFileEndBoundaryMs(it, startMs: start),
                          atMs: resumeAtMs, release: res.release)
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
            await coordinator.play(id: it.id, title: it.title, artist: it.artist,
                                   atMs: resumeAtMs, variant: it.variant)
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
    func startCurrent() -> Bool {
        guard isRunning, index < queue.count, !isHeldForResume else { return false }
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
