package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.collections.CollectionMembership
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlayAdvancedAway
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlayProgress
import com.levi.pocketdj.playback.PlayStarted
import com.levi.pocketdj.playback.PlayStopped
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.health.AutoAdvanceCascadeBreaker
import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.health.EngineProbe
import com.levi.pocketdj.playback.health.LiveBackstop
import com.levi.pocketdj.playback.health.PauseDiscriminator
import com.levi.pocketdj.playback.health.PlaybackRipWindow
import com.levi.pocketdj.playback.health.PlaybackRunway
import com.levi.pocketdj.playback.health.ResolveStallHop
import com.levi.pocketdj.playback.health.ResolveStallTimer
import com.levi.pocketdj.playback.health.RunwayLock
import com.levi.pocketdj.playback.health.StartWatchdog
import com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The Android `SetlistPlayer` (decision D11): an app-scoped index-cursor queue. It owns
 * `queue[QueueItem(uid)]`, the cursor, repeat/shuffle and the captured history context; the
 * audio engine ([PlayerPort]) holds only the CURRENT row.
 *
 * Threading: every state mutation happens on the one dispatcher of [scope] (Main in production);
 * resolution I/O runs in [playJob], tied to [playGeneration].
 *
 * Hard-won invariants (iOS):
 *  - EVERY start funnels through [startPlayCurrent]: the previous job is cancelled; a job
 *    cancelled before it ran never claims a generation; post-await writes are guarded by the
 *    generation; a superseded resolve's error never advances the newer row.
 *  - Live edits touch only `queue[index+1...]`. Row identity is the uid, never a position.
 *  - Natural end, user skip and dead source are different causes ([AdvanceCause]); a dead source
 *    advances and NEVER replays.
 *  - Repeat mode is sticky across runs; live shuffle is per-run.
 */
class SetlistSequencer(
    private val scope: CoroutineScope,
    private val port: PlayerPort,
    private val registry: RowResolverRegistry,
    private val modeProvider: () -> PlaybackMode = { PlaybackMode.CLOUD },
    initialRepeatMode: RepeatMode = RepeatMode.OFF,
    private val random: Random = Random.Default,
    private val log: (String) -> Unit = ::defaultLog,
    /** Wall clock (ms) for audible-time sampling and the runway; tests pass virtual time. */
    private val clockMs: () -> Long = System::currentTimeMillis,
) {
    /** Captured ONCE at [play]: the History context of the run (CollectionsStore.historyContext). */
    @Volatile var historyContextProvider: (String?) -> PlayContext? = { null }

    /** Captured ONCE at [play]: (source token, collection id) of the navigable origin. */
    @Volatile var originProvider: (String?) -> Pair<String, String>? = { null }

    /** Does the run's origin collection carry the clean-only flag? Feeds the [EditionDecider]. */
    @Volatile var cleanOnlyProvider: (String?) -> Boolean = { false }

    @Volatile var editionDecider: EditionDecider = EditionDecider.Unchanged

    /** Fan-out target for natural-end / skip outcomes. */
    @Volatile var outcomes: PlayOutcomeRegistry? = null

    /** PB-5: the strict <50 % classifier. When set it owns advance-away verdicts; null = legacy path. */
    @Volatile var skipTracker: com.levi.pocketdj.playback.outcome.SkipTracker? = null

    /** Listened fraction of the current track right now (0..1), or null when unknown. */
    @Volatile var progressProvider: () -> Double? = { null }

    /** Persist the sticky repeat mode. */
    @Volatile var onRepeatModeChanged: (RepeatMode) -> Unit = {}

    /** Cascade-breaker seam: return false to HALT an automatic ([AdvanceCause.isAuto]) advance. */
    @Volatile var autoAdvanceGate: () -> Boolean = { true }

    // ---- parity-2 extension seams (P2-PB-2) -----------------------------------------------------------

    /** Ordered listener bus: session / track / transition / queue / hold events (see [SequencerListener]). */
    val hooks = SequencerHooks { log(it) }

    /** Features' durable-session state (Mix Mode, FX Lock, DJ Mode): written by the session writer, restored HELD. */
    val sessionExtras = SessionExtras()

    /**
     * P2-ALB-4: the shared-album-file layout provider (null = album runs off: every analog row keeps its own window).
     * Bound by the controller to the rips manifest + the user's boundary edits.
     */
    @Volatile var albumTimelines: com.levi.pocketdj.playback.album.AlbumTimelineSource? = null

    /** The cause of the latest current-row change (null before any); the album run claims in-place skips only for non-natural ones. */
    @Volatile var lastTransitionCause: TransitionCause? = null
        private set

    /**
     * The album-run plan for the row at [pos] loading from [source] ([PlayRequest.albumRun]); null when runs are off or the
     * row is not a song of an in-order run.
     */
    fun albumPlanFor(pos: Int, source: RowSource, fresh: Boolean, resumeAtMs: Long?): com.levi.pocketdj.playback.album.AlbumRun.Plan? {
        val provider = albumTimelines ?: return null
        val item = queue.getOrNull(pos) ?: return null
        val startMs = when (source) {
            is LocalFileSource -> source.file.startMs
            is StreamSource -> source.action.clipStartMs
            else -> null
        } ?: return null
        val tl = provider.timeline(item.id) ?: return null
        return com.levi.pocketdj.playback.album.AlbumRun.plan(queue, pos, tl, startMs, effectiveRepeatMode == RepeatMode.ONE, fresh, resumeAtMs)
    }

    @Volatile private var startInterceptors: List<StartInterceptor> = emptyList()
    @Volatile private var advanceInterceptors: List<AdvanceInterceptor> = emptyList()

    /** Registered claimers, highest priority first (stable for ties). */
    fun addStartInterceptor(i: StartInterceptor) {
        startInterceptors = (startInterceptors + i).sortedByDescending { it.priority }
    }

    fun removeStartInterceptor(i: StartInterceptor) { startInterceptors = startInterceptors - i }

    fun addAdvanceInterceptor(i: AdvanceInterceptor) {
        advanceInterceptors = (advanceInterceptors + i).sortedByDescending { it.priority }
    }

    fun removeAdvanceInterceptor(i: AdvanceInterceptor) { advanceInterceptors = advanceInterceptors - i }

    /** Bumped on every current-row change; [lastUserTransitionSeq] is the seq of the latest [TransitionCause.USER] one. */
    @Volatile var transitionSeq = 0L
        private set
    @Volatile var lastUserTransitionSeq = 0L
        private set

    /** Bumped on every queue mutation (a new run, an edit, a hop, a shuffle, a clear). */
    @Volatile var queueGeneration = 0L
        private set

    private var causeOverride: TransitionCause? = null

    /**
     * Run [block] with every current-row change tagged [cause] instead of its natural cause (an external driver such
     * as Remote uses [TransitionCause.REMOTE]). While REMOTE, transports are not reported as listener intent.
     */
    fun <T> applyingCause(cause: TransitionCause, block: () -> T): T {
        val prev = causeOverride
        causeOverride = cause
        try {
            return block()
        } finally {
            causeOverride = prev
        }
    }

    // ---- P2-PB-3: external-driver seams (Remote is the first user; generic) ---------------------------------

    private var externalDepth = 0

    /**
     * Run [block] as an EXTERNAL-DRIVER apply (a Remote session): every current-row change inside it is tagged
     * [TransitionCause.REMOTE], ▶/⏸ inside it are not the listener's intent, and [transportGate] is bypassed.
     */
    fun <T> applyingExternal(block: () -> T): T {
        externalDepth++
        try {
            return applyingCause(TransitionCause.REMOTE, block)
        } finally {
            externalDepth--
        }
    }

    /**
     * Wired to the Remote session: returns true when this device is a Backseat CONTROLLER and the request was
     * forwarded to the session (the sequencer must not touch local audio). Null / false = every transport behaves
     * exactly as before. Consulted by every transport entry; bypassed inside [applyingExternal].
     */
    @Volatile var transportGate: ((TransportRedirect) -> Boolean)? = null

    /** True = [request] went to the Remote session; the caller must not touch local audio. */
    private fun redirected(request: TransportRedirect): Boolean {
        if (externalDepth > 0) return false
        val gate = transportGate ?: return false
        if (!gate(request)) return false
        log("[session] local transport -> session (controller) request=${request::class.simpleName}")
        return true
    }

    /** Bumped on every ▶/⏸ the LISTENER pressed (never by a cascade halt, an interruption, a stall or an external apply). */
    @Volatile var userPlayIntentSeq = 0L
        private set
    @Volatile var lastUserPlayIntent = false
        private set

    /** The listener pressed ▶ (`playing = true`) or ⏸ - recorded for the Remote session. Ignored inside [applyingExternal]. */
    fun noteListenerPlayIntent(playing: Boolean) {
        if (externalDepth > 0 || causeOverride == TransitionCause.REMOTE) return
        userPlayIntentSeq++
        lastUserPlayIntent = playing
    }

    /** The current HOLD was made by an external driver (start-paused / controller silence), not by a restore. */
    private var heldByRemote = false

    /** A start-paused hold: the first ▶ starts a genuinely NEW track at the cue (not a mid-song resume). */
    private var heldIsCuedStart = false

    val isHeldByRemote: Boolean get() = held && heldByRemote

    // ---- P2-PB-3: pocket-run seams -------------------------------------------------------------------------------

    /**
     * Does the run with this source id force repeat off? Pocket Wheel runs are exactly N played-through songs, so
     * playback ignores repeat while one owns the sequencer, WITHOUT touching the sticky [repeatMode]. Default: the
     * `pwr_` run tag; pocket runs may bind another predicate.
     */
    @Volatile var repeatForcedOff: (String?) -> Boolean = { it?.startsWith(POCKET_WHEEL_RUN_PREFIX) == true }

    val isRepeatForcedOff: Boolean get() = running && repeatForcedOff(sourceSetlistId)

    /** The repeat mode playback obeys (and every repeat surface shows): OFF while forced off, else the sticky mode. */
    val effectiveRepeatMode: RepeatMode get() = if (isRepeatForcedOff) RepeatMode.OFF else repeatMode

    /** DJ Mode is on (the next-up pick is then held: a random insert never lands ahead of it). Bound by DJ. */
    @Volatile var djModeEnabled: () -> Boolean = { false }

    // ---- PB-3 zero-dead-air seams ---------------------------------------------------------------

    /**
     * Engine facts + re-kick. Attaching one ARMS the machinery that needs real audio facts: the start
     * watchdog, the audible-time sampler and the auto-advance cascade breaker. Without it (unit tests of the
     * queue semantics) those stay inert, so a harness that never produces audio is not read as a cascade.
     */
    @Volatile var engine: EngineProbe? = null

    /** Who paused (listener vs interruption) - fed by the controller from Media3's playWhenReady reasons. */
    val discriminator = PauseDiscriminator()

    @Volatile var meter: DeadAirMeter? = null
    @Volatile var runwayLock: RunwayLock? = null

    /** Can this row play with NO network (burned / local file)? Drives the stall hop. */
    @Volatile var rowOnDevice: (QueueItem) -> Boolean = { false }

    /** Can this row start with no network round trip before play (a manifest rip)? The hop's fallback. */
    @Volatile var rowStartsInstantly: (QueueItem) -> Boolean = { false }

    /** `POST /rip-cancel` for ids that left the rip window (fire-and-forget; the graph supplies it). */
    @Volatile var cancelPlaybackRips: ((List<String>) -> Unit)? = null

    /** A user surface (collection Rip / Rip+Burn / recognizer) asked for this rip: never cancel it. */
    @Volatile var isUserRequestedRip: (String) -> Boolean = { false }

    /** Apple Music engine active? Picks the cascade notice variant. */
    @Volatile var appleMusicActive: () -> Boolean = { false }

    // ---- PB-10: gapless preload window ---------------------------------------------------------------

    /** Decision + bookkeeping for engine window slot 1. Disabled by default (= PB-3 behaviour); the controller arms it. */
    val preloader = NextRowPreloader(enabled = false)
    private var preloadJob: Job? = null
    private var preloadToken = 0L

    /** Feature flag: pre-add the next resolved local / rip row so the boundary is gapless. */
    var preloadEnabled: Boolean
        get() = preloader.enabled
        set(value) {
            if (preloader.enabled == value) return
            preloader.enabled = value
            reconcilePreload()
        }

    private val _state = MutableStateFlow(SequencerState(repeatMode = initialRepeatMode))
    val state: StateFlow<SequencerState> = _state.asStateFlow()

    // ---- mutable core (single-threaded by contract) ---------------------------------------
    private val queue = ArrayList<QueueItem>()
    private var index = 0
    private var running = false
    private var held = false
    /** PB-4: identity of ONE run (`pses_<uuid>`), fresh per [play], re-adopted by a restore. */
    @Volatile var sessionId: String? = null
        private set
    private var sourceSetlistId: String? = null
    private var capturedContext: PlayContext? = null
    private var capturedOrigin: Pair<String, String>? = null
    private var repeatMode = initialRepeatMode
    private var shuffleEnabled = false
    private var canonicalOrder: List<String>? = null
    private var notice: String? = null
    private var playGeneration = 0L
    private var playsRemaining = 1
    private var playJob: Job? = null
    private var startedAnyRow = false
    /** Id of the row the engine currently holds as the sequencer's own load (in-place replay gate). */
    private var lastLoadedId: String? = null
    private var deviceQueueUnplayable = false
    private var deviceUnplayableSourceId: String? = null
    private var pendingResumeMs: Long? = null
    private var unplayableStreak = 0
    private var memberIds: Set<String>? = null

    // PB-3 state
    private val breaker = AutoAdvanceCascadeBreaker()
    private var trackAudibleSeconds = 0.0
    private var lastAudibleSampleMs: Long? = null
    private var pausedByCascade = false
    private var waitingForLive = false
    private val ripWindow = PlaybackRipWindow()
    private var ripReconcileQueued = false
    private var firstAudioPending = false

    /** Q21: uid of the row whose start (resolve + load + first audio) is in flight; guards a duplicate load. */
    private var startingUid: String? = null

    private var currentBackend = "none"
    private var startWindow: StartWindow? = null
    private var startCapJob: Job? = null
    private var healthTicker: Job? = null
    private val startWatchdog = StartWatchdog(scope)
    private val stallTimer = ResolveStallTimer(scope)
    private val liveBackstop = LiveBackstop(scope)

    private class StartWindow(val gen: Long, val songId: String, val runway: PlaybackRunway, val beganMs: Long)

    val isRunning: Boolean get() = running

    /** A row's resolve/load is in flight (a remote idle ▶ must not double-start it). */
    /** True while the current row is a rip-on-demand placeholder still resolving (set by the controller). */
    @Volatile var ripWaitProbe: (() -> Boolean)? = null

    val isStartPending: Boolean
        get() = playJob?.isActive == true || startWindow != null ||
            (firstAudioPending && ripWaitProbe?.invoke() == true)

    /** The cascade breaker halted the run: the deck holds the current row paused until the listener acts. */
    val isPausedByCascade: Boolean get() = pausedByCascade

    /** The current row is a live capture with no natural end (the UI offers "Next"). */
    val isWaitingForLive: Boolean get() = waitingForLive

    /** Audible seconds the CURRENT track has produced (cascade breaker + rip window input). */
    val audibleSecondsOfCurrent: Double get() = trackAudibleSeconds

    /** The rip ids this session got queued and may still cancel (diagnostics + tests). */
    val trackedPlaybackRips: Set<String> get() = ripWindow.requested

    /** Running, not held, and no row has produced audio yet (cascade-halted / never-started deck). */
    val currentNeverSounded: Boolean get() = running && !held && !startedAnyRow && playJob?.isActive != true

    /** Fired after [restoreHeld] installed a held deck (PB-2: consumes a latched remote ▶). */
    @Volatile var onHeldRestored: () -> Unit = {}
    val isHeldForResume: Boolean get() = held

    /** Held-restore rows (uids) that lacked a persisted edition while the decider was blind: re-decided at resume. */
    private var pendingRedecideUids: Set<String> = emptySet()

    fun setPendingRedecide(uids: Set<String>) { pendingRedecideUids = uids }

    private fun redecidePending() {
        val uids = pendingRedecideUids
        if (uids.isEmpty()) return
        pendingRedecideUids = emptySet()
        val decider = editionDecider
        if (!decider.isActive() || !decider.isReady()) return
        val cleanOnly = cleanOnlyProvider(sourceSetlistId)
        for (i in queue.indices) {
            val q = queue[i]
            if (q.uid in uids && !q.editionLocked) queue[i] = decider.decide(q.copy(variant = null, resolveId = q.id), cleanOnly)
        }
    }

    /** PB-4: the offset the first ▶ of a held deck resumes at (song-relative ms), or null. */
    val resumeOffsetMs: Long? get() = pendingResumeMs

    /** PB-4: the offset [resumeFromHold] last consumed (null after any fresh play / clear). */
    @Volatile var lastResumeOffsetMs: Long? = null
        private set

    /** PB-4: the engine holds THIS cursor row (not the previous row still loaded mid-resolve). */
    val currentRowLoaded: Boolean get() = lastLoadedId != null && lastLoadedId == queue.getOrNull(index)?.id

    /** Cursor position (game runs read it before [appendRows]). */
    fun currentIndex(): Int = index

    /** `queue[index].id` while running. */
    val currentSongId: String? get() = if (running) queue.getOrNull(index)?.id else null

    /** Is [songId] (by song or storage id) a row of the running queue? Memoized per queue edit. */
    fun inRunningQueue(songId: String): Boolean {
        if (!running) return false
        val ids = memberIds ?: buildSet {
            for (q in queue) {
                add(q.id)
                add(q.resolveId)
            }
        }.also { memberIds = it }
        return songId in ids
    }

    // ---- publish ------------------------------------------------------------------------
    private fun publish() {
        _state.value = SequencerState(
            queue = queue.toList(),
            index = index,
            isRunning = running,
            isHeldForResume = held,
            sessionId = sessionId,
            sourceSetlistId = sourceSetlistId,
            capturedContext = capturedContext,
            capturedOrigin = capturedOrigin,
            repeatMode = repeatMode,
            shuffleEnabled = shuffleEnabled,
            repeatForcedOff = isRepeatForcedOff,
            playbackNotice = notice,
            waitingForLive = waitingForLive,
            pausedByCascade = pausedByCascade,
            playGeneration = playGeneration,
            deviceQueueUnplayable = deviceQueueUnplayable,
            deviceUnplayableSourceId = deviceUnplayableSourceId,
            queueGeneration = queueGeneration,
            transitionSeq = transitionSeq,
        )
    }

    private fun queueEdited() {
        memberIds = null
        val g = if (running) bumpQueueGeneration() else queueGeneration
        publish()
        if (running) announceQueue(g)
        reconcilePreload()
        scheduleRipWindowReconcile()
    }

    private fun bumpQueueGeneration(): Long {
        val g = ++queueGeneration
        log("[session] queueGen=$g size=${queue.size}")
        return g
    }

    private fun announceQueue(g: Long) = hooks.emit { it.onQueueChanged(g) }

    /** Public seam for user pause/seek/resume that the media-session player handles itself (REMOTE-cause suppressed). */
    fun reportUserTransport(kind: UserTransport) = fireUser(kind)

    private fun fireUser(kind: UserTransport) {
        if (causeOverride == TransitionCause.REMOTE || externalDepth > 0) return
        when (kind) {
            UserTransport.PLAY -> noteListenerPlayIntent(true)
            UserTransport.PAUSE -> noteListenerPlayIntent(false)
            else -> Unit
        }
        hooks.emit { it.onUserTransport(kind) }
    }

    /** A listener-driven queue edit: report the intent, then the mutation. */
    private fun userQueueEdited() {
        if (running) fireUser(UserTransport.EDIT)
        queueEdited()
    }

    /** The current row changed from [fromUid] (null = nothing was current): record + announce it. */
    private fun noteTransition(fromUid: String?, cause: TransitionCause) {
        val toUid = queue.getOrNull(index)?.uid
        if (fromUid == toUid) return
        val c = causeOverride ?: cause
        lastTransitionCause = c
        val seq = ++transitionSeq
        if (c == TransitionCause.USER) lastUserTransitionSeq = seq
        log("[session] transition cause=$c seq=$seq from=${fromUid ?: "-"} to=${toUid ?: "-"}")
        val t = Transition(fromUid, toUid, c, seq)
        hooks.emit { it.onTransition(t) }
    }

    private fun currentUid(): String? = if (running) queue.getOrNull(index)?.uid else null

    private fun pathFor(backend: String): StartPath = if (backend == "appleMusic") StartPath.AM else StartPath.EXO

    private fun fireTrackStarted(item: QueueItem, at: Int, gen: Long, path: StartPath, fresh: Boolean) {
        val ts = TrackStart(item, at, gen, path, fresh)
        hooks.emit { it.onTrackStarted(ts) }
    }

    /** The History play of a start no engine event will report (an advance or claim with no load). */
    private fun emitHistoryStart(item: QueueItem) {
        PlayEventBus.emit(
            PlayStarted(
                songId = item.id,
                title = item.title,
                artist = item.artist,
                context = requestContext(item),
                atMs = clockMs(),
                originCollectionId = originCollectionIdFor(),
            ),
        )
    }

    // ---- start / stop ---------------------------------------------------------------------

    /**
     * Start a run. Empty = no-op. A fresh play over a running set replaces it. The History context
     * and navigable origin are captured ONCE here (a later rename or playNow cannot retag rows).
     * Live shuffle resets per run; repeat mode is sticky.
     */
    fun play(
        items: List<QueueItem>,
        sourceSetlistId: String? = null,
        preStamped: Boolean = false,
        /** Explicit History context (wins over [historyContextProvider]). */
        context: PlayContext? = null,
        startIndex: Int = 0,
        /** External driver: cue the first row at this offset (ms) - the cue travels WITH the start. */
        atMs: Long? = null,
        /** External driver: park the new run on its row, HELD (the first ▶ starts it at [atMs]). */
        startPaused: Boolean = false,
    ) {
        if (items.isEmpty()) return
        if (redirected(TransportRedirect.Play(items, startIndex))) return
        log("[playback] set start count=${items.size} source=${sourceSetlistId ?: "-"}")
        val first = items.first()
        val replacing = running
        val fromUid = currentUid()
        if (running && !isRestartOfCurrent(first.id)) noteAdvanceAway()
        // The previous session's playback rips (minus the row that was sounding and anything heard) are
        // cancelled - a fresh run has its own window.
        if (running) endRipWindowSession("new-session")
        noteUserTransport()
        fireUser(UserTransport.PLAY)
        if (replacing) {
            sessionExtras.clearHeld()
            hooks.emit { it.onSessionEnded(SessionEndReason.REPLACED) }
        }
        this.sourceSetlistId = sourceSetlistId
        capturedContext = context ?: historyContextProvider(sourceSetlistId)
        capturedOrigin = originProvider(sourceSetlistId)
        queue.clear()
        queue.addAll(if (preStamped) items else stamp(items, sourceSetlistId))
        index = startIndex.coerceIn(0, items.lastIndex)
        shuffleEnabled = false
        canonicalOrder = null
        running = true
        held = false
        heldByRemote = false
        heldIsCuedStart = false
        sessionId = "pses_" + java.util.UUID.randomUUID().toString().uppercase()
        pendingResumeMs = null
        lastResumeOffsetMs = null
        notice = null
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = null
        startedAnyRow = false
        lastLoadedId = null
        unplayableStreak = 0
        memberIds = null
        endNotedUid = null
        val g = bumpQueueGeneration()
        publish()
        val sid = sessionId
        if (sid != null) {
            val src = SourceRef(capturedContext?.source ?: PlayContext.SOURCE_SETLIST, sourceSetlistId, capturedContext?.contextName)
            log("[session] started id=$sid source=${src.kind}")
            hooks.emit { it.onSessionStarted(sid, src) }
        }
        announceQueue(g)
        noteTransition(fromUid, TransitionCause.USER)
        val cue = atMs?.takeIf { it > 0 }
        if (startPaused) {
            // Whatever the previous run was sounding (or starting) goes quiet; the new run is parked on its row.
            cancelStartAndSilence("start-paused")
            playsRemaining = CollectionMembership.normalizedRepeat(queue.getOrNull(index)?.repeatCount)
            held = true
            heldByRemote = true
            heldIsCuedStart = true
            pendingResumeMs = cue
            publish()
            reconcilePreload()
            hooks.emit { it.onHeld() }
            return
        }
        startPlayCurrent(fresh = true, resumeAtMs = cue, cued = cue != null)
    }

    private fun stamp(items: List<QueueItem>, setlistId: String?): List<QueueItem> {
        val decider = editionDecider
        if (!decider.isActive()) return items
        val cleanOnly = cleanOnlyProvider(setlistId)
        return items.map { if (it.editionLocked) it else decider.decide(it, cleanOnly) }
    }

    /**
     * Live inserts (iOS appendToQueue/insertNext/playNow insert unstamped): only a clean-only run stamps, so the
     * explicit-no-clean-cut skip and the clean substitution hold; the global Prefer-explicit stays play()-time only.
     */
    private fun stampInsert(items: List<QueueItem>): List<QueueItem> {
        if (!editionDecider.isActive() || !cleanOnlyProvider(sourceSetlistId)) return items
        return items.map { if (it.editionLocked) it else editionDecider.decide(it, true) }
    }

    /** Tear the run down (natural end included): cancels any in-flight resolve, clears the queue. */
    fun stop() = stopRun(SessionEndReason.STOPPED)

    private fun stopRun(reason: SessionEndReason) {
        val wasRunning = running
        endRun(reason)
        if (wasRunning) scope.launch { runCatching { port.stop() } }
    }

    /**
     * A play that bypassed the sequencer (album queue, non-member single, full-track AM) took the
     * audio over. Monotonic; game run players compare it to the value at their own play to detect
     * a takeover even when the sequencer's run was merely kept (single) or abandoned (queue).
     */
    @Volatile var foreignPlayCount: Int = 0
        private set

    fun noteForeignPlay() { foreignPlayCount++ }

    /**
     * End the run WITHOUT touching the player - a foreign play (an album queue) has taken the
     * engine over and must keep sounding.
     */
    fun abandonRun() = endRun(SessionEndReason.REPLACED)

    private fun endRun(reason: SessionEndReason = SessionEndReason.STOPPED) {
        val wasRunning = running
        endStallEpisode("stop")
        endNotedUid = null
        sessionExtras.clearHeld()
        pendingRedecideUids = emptySet()
        if (running) {
            skipTracker?.checkpoint() // a stop / set end never advances away: still land the final fraction
            PlayEventBus.emit(PlayStopped(queue.getOrNull(index)?.id))
        }
        endRipWindowSession("stop") // before the queue is cleared: the playing row is exempt
        cancelHealthTimers()
        endStartWindow("stop")
        meter?.transitionAbandoned("stop")
        healthTicker?.cancel()
        healthTicker = null
        firstAudioPending = false
        waitingForLive = false
        pausedByCascade = false
        breaker.reset()
        trackAudibleSeconds = 0.0
        lastAudibleSampleMs = null
        playJob?.cancel()
        playJob = null
        playGeneration++ // a resolve past its last cancellation point must stand down
        resetPreload()
        running = false
        held = false
        heldByRemote = false
        heldIsCuedStart = false
        sessionId = null
        notice = null
        index = 0
        queue.clear()
        sourceSetlistId = null
        capturedContext = null
        capturedOrigin = null
        pendingResumeMs = null
        lastResumeOffsetMs = null
        unplayableStreak = 0
        lastLoadedId = null
        memberIds = null
        if (wasRunning) {
            val g = bumpQueueGeneration()
            publish()
            log("[session] ended reason=$reason")
            hooks.emit { it.onSessionEnded(reason) }
            announceQueue(g)
        } else {
            publish()
        }
    }

    /**
     * A foreign play (a Browse single that is not a row of this set, an AM take-over) owns the engine:
     * retire any in-flight start of the sequencer's own so it can never load over the user's pick.
     * The run itself is kept (cursor untouched).
     */
    fun retirePendingStart() {
        playJob?.cancel()
        playJob = null
        playGeneration++
        lastLoadedId = null
        cancelHealthTimers()
        endStartWindow("superseded")
        if (firstAudioPending) meter?.transitionAbandoned("superseded")
        firstAudioPending = false
        if (running) publish()
    }

    /** Acknowledge the one-shot device-unplayable banner. */
    fun clearDeviceUnplayable() {
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = null
        notice = null
        publish()
    }

    // ---- the ONE start funnel -----------------------------------------------------------

    private fun startPlayCurrent(
        fresh: Boolean = true,
        resumeAtMs: Long? = null,
        inPlace: Boolean = false,
        reResolve: Boolean = false,
        /** [resumeAtMs] is a start CUE of a new track (external driver), not a mid-song resume. */
        cued: Boolean = false,
    ) {
        if (pausedByCascade) { pausedByCascade = false; publish() }
        spendCurrentUserNext()
        if (inPlace) queue.getOrNull(index)?.let { skipTracker?.noteTrackRestarted(it.id) }
        endNotedUid = null
        resetTrackAudible()
        reconcileRipWindow() // the playhead (may have) moved: rips outside the window go
        ensureHealthTicker()
        playJob?.cancel()
        // LAZY + assign + start: an inline-dispatching scope may run (and even recurse into) this
        // body before launch() returns; the handle must already be in place so a nested start
        // cancels THIS job, not a stale one.
        val job = scope.launch(start = CoroutineStart.LAZY) { playCurrent(fresh, resumeAtMs, inPlace, reResolve, cued) }
        playJob = job
        job.start()
    }

    private suspend fun playCurrent(fresh: Boolean, resumeAtMs: Long?, inPlace: Boolean, reResolve: Boolean, cued: Boolean = false) {
        if (!running || index >= queue.size) return
        // A job cancelled BEFORE it ran must do nothing - above all it must not claim a generation.
        if (!currentCoroutineContext().isActive) return
        if (fresh) playsRemaining = CollectionMembership.normalizedRepeat(queue[index].repeatCount)
        val gen = ++playGeneration
        resetPreload() // a load replaces the whole engine playlist: slot 1 is gone with it
        val item = queue[index]
        val at = index
        // A new generation retires the previous start's timers; the start window + resolve stall guard this one.
        cancelHealthTimers()
        if (item.cleanOnlySkip) {
            // Q94: BEFORE any resolve / load / start window. The row keeps its queue slot (no index shift).
            log("[playback] advance: unplayable song=${item.id} index=$at/${queue.size} reason=${UnplayableSource.Reason.CLEAN_ONLY_EXPLICIT}")
            if (failureLapComplete()) return
            advanceToNext(AdvanceCause.UNPLAYABLE_HERE)
            return
        }
        waitingForLive = false
        firstAudioPending = true
        startingUid = item.uid
        meter?.transitionBegan("start") // no-op inside an open advance/skip: a hop stays ONE transition
        beginStartWindow(item, gen)
        armResolveStall(gen)
        publish()

        // Same row again (repeat-ONE / repeatCount pass / consecutive duplicate row): restart the
        // item the engine already holds. A fresh load would be a PLAYLIST_CHANGED transition and a
        // second History row; iOS records nothing for a replay.
        if (inPlace && resumeAtMs == null && lastLoadedId == item.id) {
            val restarted = try {
                port.replay(item.id)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
            if (!owns(gen)) return
            if (restarted) {
                log("[playback] replay in place song=${item.id} index=${at + 1}/${queue.size}")
                fireTrackStarted(item, at, gen, pathFor(currentBackend), fresh = false)
                handleFirstAudio("replay") // the engine already holds the row: audio is immediate
                return
            }
        }

        // P2-PB-2 seam: a registered interceptor may claim the start BEFORE the default resolve/load.
        val claimers = startInterceptors
        if (claimers.isNotEmpty()) {
            val attempt = StartAttempt(item, at, queue.size, gen, fresh, resumeAtMs, inPlace, reResolve)
            for (claimer in claimers) {
                val claimed = try {
                    claimer.tryClaim(attempt)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log("[session] start interceptor ${claimer.javaClass.simpleName} threw ${e.javaClass.simpleName}: ${e.message}")
                    false
                }
                if (!owns(gen)) return // superseded while the interceptor worked
                if (claimed) {
                    log("[session] start claimed by ${claimer.javaClass.simpleName} song=${item.id} gen=$gen")
                    return
                }
            }
        }

        val mode = modeProvider()
        val source = try {
            registry.resolve(item, mode)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            UnplayableSource(UnplayableSource.Reason.METADATA_ONLY)
        }
        if (!owns(gen)) return // superseded while resolving

        if (source is UnplayableSource) {
            log("[playback] advance: unplayable song=${item.id} index=$at/${queue.size} reason=${source.reason}")
            if (failureLapComplete()) return
            advanceToNext(AdvanceCause.UNPLAYABLE_HERE)
            return
        }
        val request = PlayRequest(
            item = item,
            source = source,
            context = requestContext(item),
            originCollectionId = originCollectionIdFor(),
            resumeAtMs = resumeAtMs,
            index = at,
            count = queue.size,
            reResolve = reResolve,
            generation = gen,
            albumRun = albumPlanFor(at, source, fresh, resumeAtMs),
        )
        log("[playback] track start song=${item.id} index=${at + 1}/${queue.size} backend=${source.backend}")
        currentBackend = source.backend
        meter?.trackStarting(source.backend)
        try {
            port.load(request)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A superseded load's error must never advance the newer row.
            if (owns(gen)) {
                log("[playback] advance: load failed song=${item.id} index=$at/${queue.size} err=${e.message}")
                lastLoadedId = null
                if (failureLapComplete()) return
                advanceToNext(AdvanceCause.AUTO_SKIP)
            }
            return
        }
        if (owns(gen)) {
            startedAnyRow = true
            lastLoadedId = item.id
            fireTrackStarted(item, at, gen, pathFor(source.backend), cued || (fresh && !inPlace && resumeAtMs == null))
            if (source !is RipOnDemandSource) {
                // Loaded: the network resolve is over. The start watchdog owns it from here.
                stallTimer.cancel()
                // First audio may already have landed during load() (Apple Music confirms PLAYING inside
                // play()): the window is closed, and a stray watchdog would later hop a song already playing.
                if (firstAudioPending) armStartStall(gen, item.id)
            } // a rip-on-demand row stays under the resolve stall until noteSourceResolved()
        }
    }

    /**
     * Count one failed row (unplayable, load error, mid-song failure). A full lap of failures with
     * repeat ALL stops the run instead of spinning forever on a wrapped set (until PB-3's cascade
     * breaker). The streak resets only when a row plays through or the listener acts.
     */
    private fun failureLapComplete(): Boolean {
        if (++unplayableStreak >= queue.size.coerceAtLeast(1) && effectiveRepeatMode == RepeatMode.ALL) {
            finishRun()
            return true
        }
        return false
    }

    private fun owns(gen: Long): Boolean = running && gen == playGeneration

    /**
     * A [StartInterceptor] that claimed the start of generation [gen] reports its audio is installed. Runs the same
     * bookkeeping a normal load does (start window + stall watchdog stay armed from [playCurrent]; the backend is
     * noted for the dead-air meter; the History play is recorded unless [emitHistory] is false because an engine
     * event will report it) and announces `onTrackStarted`. False when [gen] is no longer current.
     */
    fun completeClaimedStart(
        gen: Long,
        path: StartPath,
        backend: String = path.name.lowercase(),
        emitHistory: Boolean = true,
        fresh: Boolean = true,
    ): Boolean {
        if (!owns(gen)) return false
        val item = queue.getOrNull(index) ?: return false
        startedAnyRow = true
        lastLoadedId = item.id
        currentBackend = backend
        meter?.trackStarting(backend)
        log("[playback] track start song=${item.id} index=${index + 1}/${queue.size} backend=$backend claimed=true")
        if (emitHistory) emitHistoryStart(item)
        stallTimer.cancel()
        if (firstAudioPending) armStartStall(gen, item.id)
        fireTrackStarted(item, index, gen, path, fresh)
        return true
    }

    /** Uid of the row whose natural end was already reported (outcome + skip tracker): never reported twice. */
    private var endNotedUid: String? = null

    private fun noteNaturalEndOf(item: QueueItem) {
        if (endNotedUid == item.uid) return
        endNotedUid = item.uid
        outcomes?.emit(item.id, false, 1.0)
        skipTracker?.noteNaturalEnd(item.id)
        unplayableStreak = 0
    }

    private class NoLoad(val path: StartPath, val backend: String, val rendering: Boolean)

    /**
     * A normal advance minus [PlayerPort.load]: the cursor moves exactly as [advanceToNext] moves it (gate, cascade
     * breaker, repeat-ALL wrap, finish), with the repeat counter, skip tracker verdict, ONE History play, dead-air
     * meter, transition record and hooks - but the engine is NOT asked to load; the caller (album glide, DJ
     * conductor) has already put the next row's audio on air. [rendering] says the engine is already producing it
     * (closes the dead-air transition now); false leaves it to [onFirstAudio]. Returns false when nothing advanced
     * (not running, held, or halted by the gate/breaker).
     */
    fun advanceWithoutLoad(
        cause: AdvanceCause = AdvanceCause.NATURAL_END,
        path: StartPath = StartPath.ALBUM_GLIDE,
        backend: String = path.name.lowercase(),
        rendering: Boolean = true,
    ): Boolean {
        if (!running || held) return false
        val cur = queue.getOrNull(index) ?: return false
        val genBefore = playGeneration
        when (cause) {
            AdvanceCause.USER -> { noteAdvanceAway(); unplayableStreak = 0 }
            AdvanceCause.NATURAL_END -> noteNaturalEndOf(cur)
            else -> Unit
        }
        advanceToNext(cause, NoLoad(path, backend, rendering))
        return playGeneration != genBefore || !running
    }

    /** Ask the natural-end interceptors; true when one took the advance. */
    private fun offerNaturalEnd(): Boolean {
        val claimers = advanceInterceptors
        if (claimers.isEmpty()) return false
        val cur = queue.getOrNull(index) ?: return false
        val attempt = AdvanceAttempt(cur, index, queue.getOrNull(index + 1))
        for (c in claimers) {
            val claimed = try {
                c.onNaturalEnd(attempt)
            } catch (e: Exception) {
                log("[session] advance interceptor ${c.javaClass.simpleName} threw ${e.javaClass.simpleName}: ${e.message}")
                false
            }
            if (claimed) {
                log("[session] natural end claimed by ${c.javaClass.simpleName} song=${cur.id}")
                return true
            }
        }
        return false
    }

    private fun requestContext(item: QueueItem): PlayContext {
        val base = capturedContext ?: PlayContext(PlayContext.SOURCE_SETLIST)
        return if (item.runTag != null) base.copy(runTag = item.runTag) else base
    }

    private fun originCollectionIdFor(): String? =
        if (sourceSetlistId == com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID) capturedOrigin?.second else null

    // ---- engine events ---------------------------------------------------------------------

    /**
     * The row [songId] played through (NATURAL end). Ignored unless it is the row under the cursor
     * (an ended foreign single must never advance the set). ONE replays; remaining plays loop;
     * otherwise advance.
     */
    fun handleEnded(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        noteNaturalEndOf(queue[index])
        if (effectiveRepeatMode == RepeatMode.ONE) {
            startPlayCurrent(fresh = true, inPlace = true)
            return
        }
        if (playsRemaining > 1) {
            playsRemaining--
            startPlayCurrent(fresh = false, inPlace = true)
            return
        }
        if (offerNaturalEnd()) return
        advanceToNext(AdvanceCause.NATURAL_END)
    }

    // ---- PB-8: Apple Music rows (iOS handleAppleMusicEnded / handleAppleMusicRestarted) ------------

    /**
     * An Apple Music row ended. Ownership guard like [handleEnded]. [reason] decides repeat semantics:
     * NEVER_STARTED = dead source (advance, never replay under repeat-one); SYSTEM_SKIP = the listener's
     * lock-screen / Auto next, which the SDK handled itself (advance exactly like the in-app next, never a
     * cascade); NATURAL honours repeat-one / the per-track repeat count.
     */
    fun handleAppleMusicEnded(songId: String, reason: com.levi.pocketdj.playback.am.EndReason) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        when (reason) {
            com.levi.pocketdj.playback.am.EndReason.NEVER_STARTED -> {
                log("[playback] advance: AM never started song=${queue[index].id} index=$index/${queue.size}")
                lastLoadedId = null
                if (failureLapComplete()) return
                advanceToNext(AdvanceCause.AUTO_SKIP)
            }
            com.levi.pocketdj.playback.am.EndReason.SYSTEM_SKIP -> {
                log("[playback] setlist AM system-skip -> advance from index $index")
                noteAdvanceAway() // the live AM position reads ~0 here; SkipTracker's high-water samples carry the truth
                advanceToNext(AdvanceCause.USER)
            }
            com.levi.pocketdj.playback.am.EndReason.NATURAL -> handleEnded(songId)
        }
    }

    /** System previous during an AM stream (the SDK's one-song queue rewound): the in-app previous. */
    fun handleAppleMusicRestarted(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        log("[playback] setlist AM restart -> skipPrevious from index $index")
        skipPrevious()
    }

    /**
     * Another player took over the AM stream (stopped far short of its length): HOLD - nothing advances,
     * the notice says why, ▶ resumes at the interruption point. Reading it as the end advanced the set,
     * whose next start queued another capture (iOS 2026-10-13 cascade).
     */
    fun noteAppleMusicInterrupted(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        log("[playback] AM interrupted song=${queue[index].id} -> hold")
        notice = com.levi.pocketdj.playback.health.AutoAdvanceCascadeBreaker.APPLE_MUSIC_NOTICE
        publish()
    }

    /** The interrupted AM row is back on air: drop the hold notice. */
    fun noteAppleMusicResumed(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        if (notice == com.levi.pocketdj.playback.health.AutoAdvanceCascadeBreaker.APPLE_MUSIC_NOTICE) {
            notice = null
            publish()
        }
    }

    /** The row failed mid-song (dead source): advance, never replay. */
    fun handleFailed(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        log("[playback] advance: item failed mid-song song=${queue[index].id} index=$index/${queue.size}")
        lastLoadedId = null
        if (failureLapComplete()) return
        advanceToNext(AdvanceCause.AUTO_SKIP)
    }

    /**
     * A manual single-row play of [songId] (audio already started by the caller) that is IN the
     * running queue repositions the cursor to the NEAREST occurrence (forward preferred) so the set
     * keeps auto-advancing instead of silently ending. A non-member leaves the index untouched.
     * Returns whether the cursor was adopted.
     */
    fun adoptCursor(songId: String): Boolean {
        if (!running || index >= queue.size) return false
        if (queue[index].matches(songId)) {
            // The manual play of the current row owns the engine; a pending start must not load over it.
            retirePendingStart()
            return true
        }
        val pos = nearestOccurrence(songId, index) ?: return false
        val fromUid = currentUid()
        noteUserTransport()
        fireUser(UserTransport.JUMP)
        noteAdvanceAway()
        exitHoldIfNeeded()
        retirePendingStart() // the manual play owns the engine now; a pending resolve must not load over it
        index = pos
        playsRemaining = CollectionMembership.normalizedRepeat(queue[pos].repeatCount)
        log("[playback] adopt jump index=${pos + 1}/${queue.size} song=$songId")
        publish()
        noteTransition(fromUid, TransitionCause.USER)
        return true
    }

    private fun nearestOccurrence(id: String, ref: Int): Int? {
        var best: Int? = null
        for (i in queue.indices) {
            if (!queue[i].matches(id)) continue
            val b = best
            if (b == null) {
                best = i
                continue
            }
            val di = kotlin.math.abs(i - ref)
            val db = kotlin.math.abs(b - ref)
            if (di < db || (di == db && i >= ref)) best = i
        }
        return best
    }

    // ---- advancing --------------------------------------------------------------------------

    /** ⏭ (UI, lock screen, remote). */
    fun skipNext() {
        if (!running) return
        if (redirected(TransportRedirect.SkipNext)) return
        fireUser(UserTransport.SKIP)
        noteAdvanceAway()
        exitHoldIfNeeded()
        unplayableStreak = 0
        advanceToNext(AdvanceCause.USER)
    }

    /** ⏮: never below 0; at the top it restarts (or wraps to the last row with repeat ALL). */
    fun skipPrevious() {
        if (!running) return
        if (redirected(TransportRedirect.SkipPrevious)) return
        val fromUid = currentUid()
        noteUserTransport()
        fireUser(UserTransport.PREV)
        exitHoldIfNeeded()
        // Clean-only skip rows are never played: step back PAST them (iOS drops them from the queue, so
        // previous always reaches the real previous song). All earlier rows skipped = restart the current one.
        var i = index
        var found = false
        for (step in 0 until queue.size) {
            i = if (i == 0) {
                if (effectiveRepeatMode == RepeatMode.ALL && queue.size > 1) queue.size - 1 else break
            } else {
                i - 1
            }
            if (i == index) break
            if (!queue[i].cleanOnlySkip) { found = true; break }
        }
        if (found) index = i
        publish()
        noteTransition(fromUid, TransitionCause.USER)
        startPlayCurrent()
    }

    private fun advanceToNext(cause: AdvanceCause, noLoad: NoLoad? = null) {
        if (!running) return
        when (cause) {
            AdvanceCause.USER -> noteUserTransport()
            AdvanceCause.UNPLAYABLE_HERE -> Unit
            AdvanceCause.NATURAL_END, AdvanceCause.AUTO_SKIP, AdvanceCause.STALL_HOP -> {
                endStallEpisode("advance")
                // Halted: nothing advances by itself until the listener acts.
                if (pausedByCascade) return
                if (!autoAdvanceGate()) {
                    // Gate halt: the deck sits on a stale/ended row until ▶ (same flag as the cascade breaker).
                    pausedByCascade = true
                    publish()
                    return
                }
                if (engine != null && breaker.shouldHalt(trackAudibleSeconds)) {
                    haltCascade()
                    return
                }
            }
        }
        // Dead-air clock: an auto-advance is the between-tracks gap; a skip is listener-driven.
        meter?.transitionBegan(if (cause == AdvanceCause.USER) "skip" else "advance")
        waitingForLive = false
        log("[playback] advance from=${queue.getOrNull(index)?.id ?: "?"} index=$index/${queue.size} cause=$cause")
        val fromId = queue.getOrNull(index)?.id
        val fromUid = currentUid()
        val dupNext = cause.isAuto && fromId != null && queue.getOrNull(index + 1)?.id == fromId
        index += 1
        if (index >= queue.size) {
            if (effectiveRepeatMode == RepeatMode.ALL && queue.isNotEmpty()) {
                index = 0
                // Reshuffle the whole queue on a shuffle wrap so the next pass differs;
                // canonicalOrder is untouched so shuffle-OFF still restores.
                if (shuffleEnabled) reshuffleEntireQueue()
                queueEdited()
                noteTransition(fromUid, cause.toTransitionCause())
                if (noLoad != null) {
                    startWithoutLoad(noLoad)
                } else {
                    startPlayCurrent(fresh = true, inPlace = cause.isAuto && fromId != null && queue.getOrNull(0)?.id == fromId)
                }
                return
            }
            finishRun()
        } else {
            publish()
            noteTransition(fromUid, cause.toTransitionCause())
            if (noLoad != null) startWithoutLoad(noLoad) else startPlayCurrent(fresh = true, inPlace = dupNext)
        }
    }

    /** The start bookkeeping of a row whose audio is already on air (see [advanceWithoutLoad]); no engine load. */
    private fun startWithoutLoad(noLoad: NoLoad) {
        spendCurrentUserNext()
        val item = queue.getOrNull(index) ?: return
        val at = index
        endNotedUid = null
        playJob?.cancel()
        playJob = null
        cancelHealthTimers()
        playsRemaining = CollectionMembership.normalizedRepeat(item.repeatCount)
        val gen = ++playGeneration
        resetTrackAudible()
        reconcileRipWindow()
        ensureHealthTicker()
        startedAnyRow = true
        lastLoadedId = item.id
        firstAudioPending = true
        startingUid = item.uid
        waitingForLive = false
        currentBackend = noLoad.backend
        meter?.trackStarting(noLoad.backend)
        beginStartWindow(item, gen)
        emitHistoryStart(item)
        log("[playback] track start song=${item.id} index=${at + 1}/${queue.size} backend=${noLoad.backend} noLoad=true")
        publish()
        fireTrackStarted(item, at, gen, noLoad.path, true)
        if (noLoad.rendering) handleFirstAudio("advance") else armStartStall(gen, item.id)
    }

    /** Past the end: tear down; a device-mode run that loaded nothing raises the one-shot banner. */
    private fun finishRun() {
        val nothingStarted = !startedAnyRow
        val device = modeProvider() == PlaybackMode.DEVICE
        val raisedBy = sourceSetlistId
        val allCleanSkipped = queue.isNotEmpty() && queue.all { it.cleanOnlySkip }
        stopRun(SessionEndReason.FINISHED)
        if (nothingStarted) {
            // Device mode keeps its banner signal; cloud mode (every row unplayable / failed) gets a
            // notice the UI surfaces so a dead set never ends in silence with no feedback.
            if (device) deviceQueueUnplayable = true
            deviceUnplayableSourceId = raisedBy
            notice = when {
                allCleanSkipped -> "No clean versions in this set"
                device -> "Nothing in this set is on this device"
                else -> "None of these tracks are playable on this device yet"
            }
            publish()
        }
    }

    private fun isRestartOfCurrent(destinationId: String): Boolean =
        running && queue.getOrNull(index)?.matches(destinationId) == true

    /** The listener moved away from the current track by their own action (never a natural end). */
    private fun noteAdvanceAway() {
        // iOS guard: a "Next" off a live HLS capture is never a skip.
        if (waitingForLive) return
        val cur = queue.getOrNull(index) ?: return
        val tracker = skipTracker
        if (tracker != null) {
            val e = engine
            val pos = if (e != null && e.hasLoadedItem) e.positionMs else null
            // Catalog length first (growing-file / stream-through rips report no engine duration).
            val dur = cur.lengthMs?.takeIf { it > 0 } ?: if (e != null && e.hasLoadedItem) e.durationMs else null
            PlayEventBus.emit(PlayAdvancedAway(cur.id, pos, dur))
            tracker.noteAdvanceAway(cur.id, pos, dur)
            return
        }
        val f = progressProvider() ?: return
        outcomes?.emit(cur.id, f < 0.5, f)
    }

    // ---- held / resume ----------------------------------------------------------------------

    /** Load a restored session WITHOUT audio (durable-session restore): first ▶ resumes it. */
    fun restoreHeld(
        items: List<QueueItem>,
        index: Int,
        sourceSetlistId: String?,
        context: PlayContext?,
        origin: Pair<String, String>?,
        repeatMode: RepeatMode,
        shuffle: Boolean,
        resumeAtMs: Long?,
        canonicalOrder: List<String>? = null,
        sessionId: String? = null,
        /** The persisted optional session state (Mix Mode / FX Lock / DJ Mode): delivered HELD to [sessionExtras]. */
        extras: com.levi.pocketdj.playback.durable.SnapshotExtras? = null,
    ) {
        if (items.isEmpty() || running) return
        // iOS parity (SetlistPlayer restore): a `puzzle_` run tag is a ghost after relaunch - the game
        // engine does not survive, so strip the tag from the source id, context and rows.
        val ghost = sourceSetlistId?.startsWith(GHOST_RUN_PREFIX) == true ||
            context?.runTag?.startsWith(GHOST_RUN_PREFIX) == true
        val items = if (ghost) items.map { if (it.runTag != null) it.copy(runTag = null) else it } else items
        val sourceSetlistId = if (ghost) null else sourceSetlistId
        val context = if (ghost) context?.copy(runTag = null, contextId = null) else context
        this.sessionId = sessionId ?: ("pses_" + java.util.UUID.randomUUID().toString().uppercase())
        queue.clear()
        queue.addAll(items)
        this.index = index.coerceIn(0, items.lastIndex)
        this.sourceSetlistId = sourceSetlistId
        capturedContext = context
        capturedOrigin = origin
        this.repeatMode = repeatMode
        shuffleEnabled = shuffle
        this.canonicalOrder = if (shuffle) (canonicalOrder ?: items.map { it.uid }) else null
        startedAnyRow = false
        lastLoadedId = null
        running = true
        held = true
        heldByRemote = false
        heldIsCuedStart = false
        pendingResumeMs = resumeAtMs
        endNotedUid = null
        memberIds = null
        val g = bumpQueueGeneration()
        publish()
        val sid = this.sessionId
        if (sid != null) {
            val src = SourceRef(capturedContext?.source ?: PlayContext.SOURCE_SETLIST, sourceSetlistId, capturedContext?.contextName)
            hooks.emit { it.onSessionStarted(sid, src) }
        }
        announceQueue(g)
        reconcilePreload()
        scheduleRipWindowReconcile()
        // HELD: features receive their stored state but arm nothing until the first play (onResumedFromHold).
        if (extras != null) sessionExtras.restoreHeld(extras) { log(it) }
        log("[session] held restore id=${this.sessionId} rows=${queue.size} index=${this.index}")
        hooks.emit { it.onHeld() }
        onHeldRestored()
    }

    /**
     * Audio is sounding outside any run (album queue, browse single, AM, stream): fold it into a
     * one-row run resumed at [positionMs] so queue inserts land AFTER it instead of replacing it.
     * No-op when a run already exists.
     */
    fun adoptForeign(current: QueueItem, positionMs: Long, context: PlayContext?) {
        if (running) return
        restoreHeld(
            items = listOf(current),
            index = 0,
            sourceSetlistId = null,
            context = context,
            origin = null,
            repeatMode = repeatMode,
            shuffle = false,
            resumeAtMs = positionMs,
        )
        resumeFromHold()
    }

    /** First explicit ▶ on a held deck: start the current row, mid-song when a position was saved. */
    fun resumeFromHold() {
        if (!running || !held) return
        if (redirected(TransportRedirect.SetPlaying(true))) return
        val at = pendingResumeMs
        val cuedStart = heldByRemote && heldIsCuedStart
        lastResumeOffsetMs = at
        noteUserTransport()
        fireUser(UserTransport.PLAY)
        leaveHold()
        redecidePending()
        playsRemaining = CollectionMembership.normalizedRepeat(queue.getOrNull(index)?.repeatCount)
        publish()
        startPlayCurrent(fresh = cuedStart, resumeAtMs = at, cued = cuedStart)
    }

    /** Start the current row from the top (cascade-halted deck, idle ▶). */
    fun startCurrent(): Boolean {
        if (!running || index >= queue.size) return false
        if (redirected(TransportRedirect.LocalStart)) return true // a Backseat controller never sounds
        // Q21 (BEFORE noteUserTransport, which clears the cascade halt): ▶ while this very row's start is still
        // in flight must not load (and POST /rip) a second time.
        if (!held && !pausedByCascade && firstAudioPending && startingUid == queue[index].uid) {
            log("[playback] play during start - not reloading song=${queue[index].id}")
            noteUserTransport()
            discriminator.noteListenerIntent(true)
            return true
        }
        noteUserTransport()
        fireUser(UserTransport.PLAY)
        discriminator.noteListenerIntent(true)
        leaveHold(clearOffset = false)
        publish()
        startPlayCurrent()
        return true
    }

    /** Leave the held state (if held) and announce it; the held offset is spent. */
    private fun leaveHold(clearOffset: Boolean = true) {
        if (!held) return
        held = false
        heldByRemote = false
        heldIsCuedStart = false
        if (clearOffset) pendingResumeMs = null
        sessionExtras.clearHeld()
        hooks.emit { it.onResumedFromHold() }
    }

    private fun exitHoldIfNeeded() = leaveHold()

    // ---- repeat & shuffle -------------------------------------------------------------------

    fun cycleRepeatMode() = setRepeatMode(effectiveRepeatMode.next)

    /** No-op when unchanged. Safe while idle: the mode simply rides the next run. */
    fun setRepeatMode(mode: RepeatMode) {
        // A pocket run's repeat is off by contract: the listener's sticky mode rides through the run untouched
        // (never written), and the surfaces keep showing OFF.
        if (isRepeatForcedOff) {
            log("[session] setRepeatMode($mode) ignored: repeat forced off")
            return
        }
        if (mode == repeatMode) return
        fireUser(UserTransport.EDIT)
        repeatMode = mode
        onRepeatModeChanged(mode)
        publish()
        reconcilePreload()
    }

    fun toggleShuffle() = setShuffle(!shuffleEnabled)

    /**
     * ON permutes the upcoming tail (remembering the pre-shuffle order the first time); OFF restores
     * that relative order with later-added rows at the end. Never touches `queue[index]` or the head.
     */
    fun setShuffle(on: Boolean) {
        if (on == shuffleEnabled) return
        shuffleEnabled = on
        if (on) {
            if (canonicalOrder == null) canonicalOrder = queue.map { it.uid }
            shuffleUpcomingTail()
        } else {
            restoreUpcomingOrder()
        }
        setUserNext(null, keepingCurrentPick = true) // the pick may have been shuffled away from next
        userQueueEdited()
    }

    private fun shuffleUpcomingTail() {
        if (!running || index + 1 >= queue.size) return
        val tail = queue.subList(index + 1, queue.size).toMutableList()
        tail.shuffle(random)
        replaceTail(tail)
    }

    private fun restoreUpcomingOrder() {
        val canon = canonicalOrder ?: return
        if (!running || index + 1 >= queue.size) return
        val rank = HashMap<String, Int>(canon.size)
        canon.forEachIndexed { i, uid -> rank.putIfAbsent(uid, i) }
        val tail = queue.subList(index + 1, queue.size).toMutableList()
        // sortedBy is stable: later-added rows (no rank) keep arrival order at the end.
        replaceTail(tail.sortedBy { rank[it.uid] ?: Int.MAX_VALUE })
    }

    private fun reshuffleEntireQueue() {
        if (queue.size > 1) queue.shuffle(random)
    }

    private fun replaceTail(tail: List<QueueItem>) {
        while (queue.size > index + 1) queue.removeAt(queue.size - 1)
        queue.addAll(tail)
    }

    // ---- live queue edits (ONLY queue[index+1...]) -------------------------------------------

    /** The uid of the upcoming row at 0-based OFFSET (0 = right after the current): position -> identity. */
    fun upcomingUid(atOffset: Int): String? {
        if (!running || atOffset < 0) return null
        return queue.getOrNull(index + 1 + atOffset)?.uid
    }

    /**
     * Mark the listener's NEXT-UP pick at [pos] (must be `index + 1`; null = none) and clear the mark everywhere
     * else: only the next slot is ever held. [keepingCurrentPick]: an edit elsewhere keeps the existing pick if it is
     * STILL next. Returns the uid of a NEWLY placed pick (null when none / kept) so the caller can announce it.
     */
    private fun setUserNext(pos: Int?, keepingCurrentPick: Boolean = false): String? {
        if (!running) return null
        val keep = keepingCurrentPick && queue.getOrNull(index + 1)?.djUserNext == true
        val target = if (keep) index + 1 else if (pos != null && pos == index + 1) pos else null
        for (i in index + 1 until queue.size) {
            val want = i == target
            if (queue[i].djUserNext != want) queue[i] = queue[i].copy(djUserNext = want)
        }
        return if (!keep && target != null) queue.getOrNull(target)?.uid else null
    }

    /** The listener's next-up pick is PLAYING now: its hold is spent at EVERY start. */
    private fun spendCurrentUserNext() {
        val cur = queue.getOrNull(index) ?: return
        if (running && cur.djUserNext) queue[index] = cur.copy(djUserNext = false)
    }

    /** A queue edit landed [uid] at `index + 1`: tell the listeners (DJ sets the pick). Call AFTER the edit is published. */
    private fun announceLandedNext(uid: String?) {
        if (uid == null) return
        log("[session] row landed next uid=$uid")
        hooks.emit { it.onRowLandedNext(uid) }
    }

    /**
     * Reorder within the tail (SwiftUI `.onMove` shape; offsets relative to the tail, 0 = right
     * after the current). Stale offsets are dropped and [toOffset] is CLAMPED to the live tail.
     * Moved run rows are PINNED (a re-plan never moves them again); a row dragged to the top is the next-up pick.
     */
    fun moveUpcoming(fromOffsets: Collection<Int>, toOffset: Int) {
        if (!running || index + 1 >= queue.size) return
        val tail = queue.subList(index + 1, queue.size).toMutableList()
        val src = fromOffsets.filter { it in tail.indices }.toSortedSet().toList()
        if (src.isEmpty()) return
        val dest = toOffset.coerceIn(0, tail.size)
        val remaining = tail.filterIndexed { i, _ -> i !in src }
        val insertAt = (dest - src.count { it < dest }).coerceIn(0, remaining.size)
        // A drop that changes nothing (same-position drag) is not an edit: no pins, no pick.
        if (remaining.toMutableList().also { r -> r.addAll(insertAt, src.map { tail[it] }) }.map { it.uid } == tail.map { it.uid }) return
        val moved = src.map { tail[it].pinnedCopy() }
        val out = remaining.toMutableList().also { it.addAll(insertAt, moved) }
        replaceTail(out)
        val toTop = dest == 0
        val landed = setUserNext(if (toTop) index + 1 else null, keepingCurrentPick = !toTop)
        userQueueEdited()
        announceLandedNext(landed)
    }

    /** Remove tail rows by IDENTITY (a stale position would delete whatever shifted into the slot). */
    fun removeUpcoming(uids: Set<String>) {
        if (!running || index + 1 >= queue.size || uids.isEmpty()) return
        val tail = queue.subList(index + 1, queue.size).filter { it.uid !in uids }
        if (tail.size == queue.size - index - 1) return
        replaceTail(tail)
        setUserNext(null, keepingCurrentPick = true) // the row that slid into next wasn't chosen
        userQueueEdited()
    }

    /** Append to the end of the running queue. No-op when idle (resurrecting is a fresh [play]). */
    fun appendToQueue(items: List<QueueItem>) {
        if (!running || items.isEmpty()) return
        queue.addAll(stampInsert(items.map { it.pinnedCopy() }))
        userQueueEdited()
    }

    /**
     * Game seam: append rows stamped with [runTag]; the tag rides into each row's
     * [PlayContext.runTag]. No-op when idle.
     */
    fun appendRows(items: List<QueueItem>, runTag: String) =
        appendToQueue(items.map { it.copy(runTag = runTag) })

    /**
     * A run's top-up rows (pocket runs, game runs): edition-stamped EXACTLY like the rows [play] stamped (clean-only
     * AND prefer-explicit), tagged [runTag], then appended. They are planner material, not the listener's edit:
     * not pinned, no EDIT intent. No-op when idle.
     */
    fun appendRunRows(items: List<QueueItem>, runTag: String? = null) {
        if (!running || items.isEmpty()) return
        val tagged = if (runTag == null) items else items.map { it.copy(runTag = runTag) }
        queue.addAll(stamp(tagged, sourceSetlistId))
        queueEdited()
    }

    /** "Add next": right AFTER the current one. */
    fun insertNextInQueue(items: List<QueueItem>) {
        if (!running || items.isEmpty()) return
        queue.addAll(minOf(index + 1, queue.size), stampInsert(items.map { it.pinnedCopy() }))
        val landed = setUserNext(index + 1) // Play Next: the first of them is the pick
        userQueueEdited()
        announceLandedNext(landed)
    }

    /** Before an upcoming row by identity; an unknown/played anchor falls back to append. */
    fun insertInQueue(items: List<QueueItem>, beforeUid: String) {
        if (!running || items.isEmpty()) return
        val pos = (index + 1 until queue.size).firstOrNull { queue[it].uid == beforeUid }
        if (pos == null) {
            appendToQueue(items)
            return
        }
        queue.addAll(pos, stampInsert(items.map { it.pinnedCopy() }))
        // Dropped into the next-up slot -> the listener's pick; mid-queue -> planner material.
        val landed = setUserNext(if (pos == index + 1) pos else null, keepingCurrentPick = pos != index + 1)
        userQueueEdited()
        announceLandedNext(landed)
    }

    /**
     * Jukebox "Surprise Slot": a random slot in the tail; [slot] is injectable for tests. With DJ Mode on, the
     * listener's held next-up pick keeps its place: the random row never lands ahead of it.
     */
    fun insertRandomInQueue(
        items: List<QueueItem>,
        slot: (IntRange) -> Int = { random.nextInt(it.first, it.last + 1) },
    ) {
        if (!running || items.isEmpty()) return
        val pickHeld = djModeEnabled() && queue.getOrNull(index + 1)?.djUserNext == true
        val lo = minOf(index + if (pickHeld) 2 else 1, queue.size)
        val at = slot(lo..queue.size).coerceIn(lo, queue.size)
        queue.addAll(at, stampInsert(items.map { it.pinnedCopy() }))
        // A request that lands NEXT is held there; a mid-queue one the DJ may re-order.
        val landed = setUserNext(if (at == index + 1) at else null, keepingCurrentPick = at != index + 1)
        userQueueEdited()
        announceLandedNext(landed)
    }

    /** "Play next". Unknown/played uids are ignored. */
    fun moveUpcomingNext(uid: String) {
        val pos = upcomingPos(uid) ?: return
        queue.add(index + 1, queue.removeAt(pos).pinnedCopy())
        val landed = setUserNext(index + 1) // "Play next": the listener's pick
        userQueueEdited()
        announceLandedNext(landed)
    }

    /** "Move to end". */
    fun moveUpcomingToEnd(uid: String) {
        val pos = upcomingPos(uid) ?: return
        queue.add(queue.removeAt(pos).pinnedCopy())
        setUserNext(null, keepingCurrentPick = true) // sent to the end: planner material
        userQueueEdited()
    }

    private fun upcomingPos(uid: String): Int? {
        if (!running || index + 1 >= queue.size) return null
        return (index + 1 until queue.size).firstOrNull { queue[it].uid == uid }
    }

    // ---- P2-PB-3: pocket-run re-plan -------------------------------------------------------------------------------

    /** Remaining seconds of the current track, or null when unknown (then `index + 1` is not replaceable). */
    private fun currentRunwaySeconds(): Double? {
        val cur = queue.getOrNull(index) ?: return null
        val e = engine?.takeIf { it.hasLoadedItem }
        val dur = e?.durationMs ?: cur.lengthMs ?: return null
        val pos = e?.positionMs ?: pendingResumeMs ?: 0L
        return (dur - pos) / 1000.0
    }

    /** May the row at absolute position [i] be replaced RIGHT NOW? (iOS `isReplaceablePosition`.) */
    private fun isReplaceablePosition(i: Int): Boolean {
        if (!running || i <= index || i >= queue.size) return false // never the playing / played rows
        val plan = queue[i].plan ?: return false // manual rows are the listener's
        if (plan.pinned) return false // moved rows too
        if (i == index + 1) {
            val remaining = currentRunwaySeconds() ?: return false
            if (remaining < REPLACE_NEXT_MIN_RUNWAY_SECONDS) return false
        }
        return true
    }

    private fun ripInFlight(it: QueueItem): Boolean = it.id in ripWindow.requested || it.resolveId in ripWindow.requested

    /** The upcoming rows of run [runId] a re-plan may touch NOW (re-checked again at apply time). */
    fun replaceableUpcomingRows(runId: String): List<ReplaceableRow> {
        if (!running || index + 1 >= queue.size) return emptyList()
        return (index + 1 until queue.size).mapNotNull { i ->
            val plan = queue[i].plan
            if (plan == null || plan.runId != runId || !isReplaceablePosition(i)) return@mapNotNull null
            ReplaceableRow(
                uid = queue[i].uid,
                songId = queue[i].id,
                slot = plan.slot,
                collectionId = plan.collectionId,
                requiresInstant = ripInFlight(queue[i]),
                prevSongId = queue[i - 1].id,
                nextSongId = queue.getOrNull(i + 1)?.id,
            )
        }
    }

    /**
     * Swap / drop upcoming rows by IDENTITY (uid; stale uids are ignored). The protection rules are evaluated HERE,
     * at apply time, because the queue may have advanced since the re-plan was computed: the playing row is never
     * touched, the next row only with >= 30 s of runway, manual (`plan == null`) and moved (`pinned`) rows never, and
     * a row whose rip is in flight only by a replacement that starts instantly (an in-flight capture is never traded
     * for another). A replacement takes the replaced row's `canonicalOrder` slot, so shuffle-off ordering stays
     * coherent; touching the prefetch window re-arms the preloader. Returns how many rows changed.
     */
    fun replaceUpcoming(replacements: Map<String, QueueItem>, removing: Set<String>): Int {
        if (!running || index + 1 >= queue.size || (replacements.isEmpty() && removing.isEmpty())) return 0
        val taken = HashSet<String>(queue.size * 2)
        queue.forEach { taken.add(it.uid) }
        var changed = 0
        var touchedWindow = false
        val dropped = ArrayList<Int>()
        var canon = canonicalOrder
        for (i in index + 1 until queue.size) {
            val row = queue[i]
            val raw = replacements[row.uid]
            if (raw != null) {
                if (!isReplaceablePosition(i)) continue
                // The same edition policy every queued row gets at play() (clean-only / prefer-explicit).
                var rep = stamp(listOf(raw), sourceSetlistId).firstOrNull() ?: raw
                if (ripInFlight(row) && !(rowOnDevice(rep) || rowStartsInstantly(rep))) continue
                // uids must stay unique: a replacement reusing a live uid becomes a fresh instance.
                if (rep.uid != row.uid && !taken.add(rep.uid)) rep = rep.freshInstance().also { taken.add(it.uid) }
                queue[i] = rep
                if (canon != null && rep.uid != row.uid) canon = canon.map { if (it == row.uid) rep.uid else it }
                changed++
                if (NextRowPreloader.inWindow(index, i)) touchedWindow = true
            } else if (row.uid in removing) {
                if (!isReplaceablePosition(i)) continue
                dropped.add(i)
                changed++
                if (NextRowPreloader.inWindow(index, i)) touchedWindow = true
            }
        }
        if (changed == 0) return 0
        for (i in dropped.asReversed()) queue.removeAt(i)
        canonicalOrder = canon
        if (touchedWindow) {
            // queueEdited() -> reconcilePreload() empties a stale slot 1 on the ENGINE and re-resolves the new next row.
            log("[session] replaceUpcoming touched prefetch window - re-arming preload")
        }
        setUserNext(null, keepingCurrentPick = true)
        queueEdited() // publishes, bumps queueGeneration (-> persisted) and re-arms preload + rip window
        return changed
    }

    /**
     * Replace the first [count] upcoming rows with [items] in ONE queue mutation (rows after them are kept): a
     * Remote speaker re-syncs the session's window without truncating the rest of a long local set.
     */
    fun replaceUpcomingSegment(count: Int, items: List<QueueItem>) {
        if (!running) return
        val lo = minOf(index + 1, queue.size)
        val hi = minOf(queue.size, lo + maxOf(0, count))
        val stamped = stampInsert(items)
        for (k in hi - 1 downTo lo) queue.removeAt(k)
        queue.addAll(lo, stamped)
        setUserNext(null, keepingCurrentPick = true)
        queueEdited()
    }

    /** External driver: insert [items] before the upcoming row [beforeUid] (null / unknown = append). Not the listener's edit. */
    fun insertUpcoming(items: List<QueueItem>, beforeUid: String?) {
        if (!running || items.isEmpty()) return
        applyingExternal {
            if (beforeUid == null) appendToQueue(items) else insertInQueue(items, beforeUid)
        }
    }

    /** While HELD, move the resume point (an external driver seeking a paused / held speaker). */
    fun setHeldResumePosition(ms: Long) {
        if (!held) return
        pendingResumeMs = ms.takeIf { it > 0 }
    }

    /** Cancel any start in flight and silence the engine (no notice, no cascade flag). */
    private fun cancelStartAndSilence(reason: String) {
        playJob?.cancel()
        playJob = null
        playGeneration++ // a resolve still in flight must not start audio now
        cancelHealthTimers()
        endStartWindow(reason)
        if (firstAudioPending) meter?.transitionAbandoned(reason)
        firstAudioPending = false
        waitingForLive = false
        scope.launch { runCatching { port.pause() } }
        discriminator.noteListenerIntent(false)
    }

    /**
     * A Remote session made this device a CONTROLLER: go silent and STAY silent. A start in flight is cancelled (a
     * plain pause raced it: the pause was a no-op while nothing sounded yet, then the start landed audibly), the
     * engine is paused, and the deck parks HELD at its position - so every later ▶ goes through [resumeFromHold] /
     * [transportGate], i.e. to the session. Idempotent.
     */
    fun silenceForController() {
        if (!running) return
        val sounding = engine?.isPlaying == true
        if (held && !isStartPending && !sounding) return
        val pos = if (held) (pendingResumeMs ?: 0L) else engine?.takeIf { it.hasLoadedItem }?.positionMs ?: 0L
        cancelStartAndSilence("remote-controller")
        val wasHeld = held
        held = true
        heldByRemote = true
        if (!wasHeld) heldIsCuedStart = false
        pendingResumeMs = pos.takeIf { it > 0 }
        publish()
        reconcilePreload()
        if (!wasHeld) hooks.emit { it.onHeld() }
    }

    /** Up Next "Play now": step the cursor onto EXACTLY this row (uid, not song id). */
    fun jumpToUpcoming(uid: String, atMs: Long? = null) {
        val pos = upcomingPos(uid) ?: return
        if (redirected(TransportRedirect.Jump(uid))) return
        val fromUid = currentUid()
        if (!isRestartOfCurrent(queue[pos].id)) noteAdvanceAway()
        noteUserTransport()
        fireUser(UserTransport.JUMP)
        exitHoldIfNeeded()
        index = pos
        publish()
        noteTransition(fromUid, TransitionCause.USER)
        // The start cue travels WITH the jump: a seek after it would land on the old backend.
        val cue = atMs?.takeIf { it > 0 }
        startPlayCurrent(fresh = true, resumeAtMs = cue, cued = cue != null)
    }

    /**
     * "PLAY NOW" of a (fresh) item: splice it right after the current row and step onto it, so the
     * interrupted track stays in the played region and the tail is untouched. A duplicate uid is
     * refreshed - the uid-keyed edits rely on uniqueness.
     */
    fun playNow(item: QueueItem) {
        if (!running) return
        if (redirected(TransportRedirect.PlayNow(item))) return
        val fresh = if (queue.any { it.uid == item.uid }) item.freshInstance() else item
        val stamped = stampInsert(listOf(fresh)).single()
        if (stamped.cleanOnlySkip) {
            notice = "Explicit - skipped in this clean-only set"
            publish()
            return
        }
        val fromUid = currentUid()
        if (!isRestartOfCurrent(item.id)) noteAdvanceAway()
        noteUserTransport()
        fireUser(UserTransport.JUMP)
        exitHoldIfNeeded()
        val at = minOf(index + 1, queue.size)
        queue.add(at, stamped)
        index = at
        queueEdited()
        noteTransition(fromUid, TransitionCause.USER)
        startPlayCurrent()
    }

    /** "Rewind to here": the needle lands on a played row; rows between return to the tail. */
    fun jumpToPlayed(uid: String) {
        if (!running || index <= 0) return
        val pos = (0 until minOf(index, queue.size)).firstOrNull { queue[it].uid == uid } ?: return
        if (redirected(TransportRedirect.Jump(uid))) return
        val fromUid = currentUid()
        if (!isRestartOfCurrent(queue[pos].id)) noteAdvanceAway()
        noteUserTransport()
        fireUser(UserTransport.JUMP)
        exitHoldIfNeeded()
        index = pos
        publish()
        noteTransition(fromUid, TransitionCause.USER)
        startPlayCurrent()
    }

    // ---- arbitrary stream (jukebox Tune-In) ---------------------------------------------------

    /**
     * Play an arbitrary stream at [seekMs]. A HELD (restored, unstarted) queue is left exactly as
     * it is; a running set is replaced (the audio engine is taken over, so its cursor must not
     * linger and advance on the stream's end).
     */
    suspend fun playUrl(title: String, artist: String?, url: String, seekMs: Long = 0) {
        if (running && !held) {
            playJob?.cancel()
            endRun(SessionEndReason.REPLACED)
        } else if (running) {
            playJob?.cancel()
            playGeneration++ // a held deck has no job; the bump just retires any straggler
        }
        lastLoadedId = null
        log("[playback] play url title=$title seek=${seekMs}ms")
        port.loadUrl(UrlRequest(title, artist, url, seekMs))
    }

    // ---- PB-3: start window, stall hop, watchdogs ----------------------------------------------------

    /**
     * Open the start window for generation [gen]: a runway (wake lock) held until the track actually renders,
     * capped at [PlaybackRunway.CAP_MS]. `isStartPending` is true for its whole life.
     */
    private fun beginStartWindow(item: QueueItem, gen: Long) {
        endStartWindow("superseded")
        val runway = PlaybackRunway("pocketdj-start-${item.id}", runwayLock, clockMs)
        startWindow = StartWindow(gen, item.id, runway, clockMs())
        startCapJob = scope.launch {
            kotlinx.coroutines.delay(PlaybackRunway.CAP_MS)
            if (startWindow?.gen == gen) endStartWindow("cap")
        }
    }

    private fun endStartWindow(reason: String) {
        val w = startWindow ?: return
        startWindow = null
        startCapJob?.cancel()
        startCapJob = null
        w.runway.end(reason)
    }

    private fun cancelHealthTimers() {
        startWatchdog.cancel()
        stallTimer.cancel()
        liveBackstop.cancel()
    }

    /**
     * The engine produced the row's FIRST audio (Media3 isPlaying with READY). Closes the dead-air transition,
     * the start window and the watchdogs. Idempotent per start; ignores a stale row's audio via [songId].
     */
    fun onFirstAudio(songId: String? = null, source: String = "player") {
        if (!running || held) return
        if (songId != null && queue.getOrNull(index)?.matches(songId) != true) return
        handleFirstAudio(source)
    }

    private fun handleFirstAudio(source: String) {
        // Steady-state audio of the current row also ends the episode (a mid-song rebuffer or a hop with no
        // start window must not leave earlier rows ineligible as hop targets for the rest of the session).
        endStallEpisode("first-audio")
        if (!firstAudioPending && startWindow == null) return
        firstAudioPending = false
        queue.getOrNull(index)?.let { cur -> hooks.emit { it.onFirstAudio(cur, source) } }
        meter?.firstAudio(currentBackend, clockMs())
        startWatchdog.cancel()
        stallTimer.cancel()
        startWindow?.let { log("[playback] start-ok song=${it.songId} after=${clockMs() - it.beganMs}ms") }
        endStartWindow("firstAudio.$source")
        reconcilePreload() // the current row is READY: now resolve + pre-add the next one
    }

    // ---- PB-10: preload window ------------------------------------------------------------------------

    private fun resetPreload() {
        preloadToken++
        preloadJob?.cancel()
        preloadJob = null
        preloader.noteCleared()
    }

    private fun preloadArmed(): Boolean =
        preloader.enabled && running && !held && !pausedByCascade && !waitingForLive && !firstAudioPending

    /**
     * Make engine window slot 1 hold exactly the row that plays next by natural end (or nothing).
     * A stale slot is emptied immediately (same dispatcher turn when the scope dispatches inline);
     * resolution of the new next row then runs under [preloadToken] + [playGeneration] guards.
     */
    fun reconcilePreload() {
        val token = ++preloadToken
        preloadJob?.cancel()
        preloadJob = null
        val armed = preloadArmed()
        if (!armed && preloader.slot == null) return
        val rawTarget = if (armed) {
            preloader.target(queue, index, effectiveRepeatMode, shuffleEnabled, playsRemaining, true)
        } else {
            null
        }
        if (rawTarget == null && preloader.slot == null) return
        val gen = playGeneration
        // P2-ALB-4: the next row of an in-order album run is the SAME file's next song - the run item moves onto it
        // in place, so it is never preloaded (a window slot would only duplicate the file).
        val target = rawTarget?.takeIf { t ->
            t.index != index + 1 || !com.levi.pocketdj.playback.album.AlbumRun.isRunContinuation(
                queue, index, albumTimelines?.timeline(queue[index].id), effectiveRepeatMode == RepeatMode.ONE,
            )
        }
        if (target == null && preloader.slot == null) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            if (preloader.isStale(target)) {
                try { port.preloadNext(null) } catch (e: CancellationException) { throw e } catch (e: Exception) { }
                preloader.noteCleared()
                log("[playback] preload cleared")
            }
            if (target == null) return@launch
            if (preloader.slot?.uid == target.item.uid) return@launch // already the next row
            val source = try {
                registry.resolve(target.item, modeProvider())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (token != preloadToken || !owns(gen)) return@launch
            val plan = preloader.decide(target, source)
            if (plan !is NextRowPreloader.Plan.Add && plan !is NextRowPreloader.Plan.Replace) {
                if (plan is NextRowPreloader.Plan.Remove) {
                    try { port.preloadNext(null) } catch (e: CancellationException) { throw e } catch (e: Exception) { }
                    preloader.noteCleared()
                }
                return@launch
            }
            val request = PlayRequest(
                item = target.item,
                source = source!!,
                context = requestContext(target.item),
                originCollectionId = originCollectionIdFor(),
                resumeAtMs = null,
                index = target.index,
                count = queue.size,
            )
            val ok = try {
                port.preloadNext(request)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
            if (ok && (token != preloadToken || !owns(gen))) {
                // The engine now holds slot 1 but this pass was superseded: never leave it untracked.
                if (owns(gen)) {
                    preloader.noteInstalled(target.item, source) // a newer reconcile will keep or replace it
                } else {
                    try { port.preloadNext(null) } catch (e: CancellationException) { throw e } catch (e: Exception) { }
                    preloader.noteCleared()
                }
                return@launch
            }
            if (token != preloadToken || !owns(gen)) return@launch
            if (ok) {
                preloader.noteInstalled(target.item, source)
                log("[playback] preload song=${target.item.id} index=${target.index + 1}/${queue.size} backend=${source.backend}")
            }
        }
        preloadJob = job
        job.start()
    }

    /**
     * The engine rolled onto its window slot 1 by itself (MEDIA_ITEM_TRANSITION_REASON_AUTO). Advance the
     * cursor to the PRELOADED row's uid (never blindly +1: a live edit may have moved things), fire the
     * per-track start bookkeeping once, and close the dead-air transition at ~0. Returns false when
     * [songId] is not the preloaded row (the caller treats it as a stray engine event).
     */
    fun handlePreloadedTransition(songId: String, rendering: Boolean = true): Boolean {
        if (!running || held) return false
        // A skip/jump already moved the cursor and its load is pending: that load owns the engine, not this event.
        if (playJob?.isActive == true) return false
        val slot = preloader.consumeAutoTransition(songId) ?: return false
        val from = queue.getOrNull(index)
        val pos = queue.indexOfFirst { it.uid == slot.uid }
        preloadToken++
        preloadJob?.cancel()
        preloadJob = null
        if (from == null || pos < 0) {
            // The row left the queue after the engine had already committed to it: realign by reloading the cursor row.
            log("[playback] preload transition for song=$songId lost its row; advancing normally")
            if (from != null) {
                outcomes?.emit(from.id, false, 1.0)
                skipTracker?.noteNaturalEnd(from.id)
            }
            unplayableStreak = 0
            advanceToNext(AdvanceCause.NATURAL_END)
            return true
        }
        // Gate + breaker run BEFORE the cursor moves: a halt sits on the ENDED row (PB-3 / iOS), never the new one.
        if (!autoAdvanceGate()) {
            pausedByCascade = true
            scope.launch { runCatching { port.pause() } }
            publish()
            reconcilePreload()
            return true
        }
        if (engine != null && breaker.shouldHalt(trackAudibleSeconds)) {
            haltCascade()
            return true
        }
        outcomes?.emit(from.id, false, 1.0)
        skipTracker?.noteNaturalEnd(from.id)
        unplayableStreak = 0
        endNotedUid = null
        index = pos
        val item = queue[pos]
        meter?.transitionBegan("advance")
        log("[playback] advance from=${from.id} index=$pos/${queue.size} cause=${AdvanceCause.NATURAL_END} preloaded=true")
        waitingForLive = false
        cancelHealthTimers()
        playsRemaining = CollectionMembership.normalizedRepeat(item.repeatCount)
        val gen = ++playGeneration
        resetTrackAudible()
        reconcileRipWindow()
        startedAnyRow = true
        lastLoadedId = item.id
        firstAudioPending = true
        startingUid = item.uid
        currentBackend = slot.source.backend
        meter?.trackStarting(slot.source.backend)
        beginStartWindow(item, gen)
        log("[playback] track start song=${item.id} index=${pos + 1}/${queue.size} backend=${slot.source.backend} preloaded=true")
        publish()
        noteTransition(from.uid, TransitionCause.NATURAL_END)
        fireTrackStarted(item, pos, gen, StartPath.EXO, true)
        if (rendering) {
            handleFirstAudio("preload") // the engine is already rendering it: gap ~0
        } else {
            // Still buffering: the real gap closes on the first onIsPlayingChanged(true); the stall watchdog covers it.
            armStartStall(gen, item.id)
        }
        return true
    }

    /** A rip-on-demand row's url resolved (the data source is about to read it): the start watchdog takes over. */
    fun noteSourceResolved(songId: String) {
        if (!running || held) return
        val cur = queue.getOrNull(index) ?: return
        if (!cur.matches(songId) || !firstAudioPending) return
        stallTimer.cancel()
        armStartStall(playGeneration, cur.id)
    }

    /**
     * The current row switched to a live HLS capture: no natural end, scrubber disabled, "Next" offered.
     * Arms the [LiveBackstop] (known length + 45 s of un-paused play).
     */
    fun noteLive(songId: String) {
        if (!running || held) return
        val cur = queue.getOrNull(index) ?: return
        if (!cur.matches(songId)) return
        val gen = playGeneration
        waitingForLive = true
        currentBackend = "hls"
        meter?.trackStarting("hls")
        publish()
        liveBackstop.arm(
            lengthMs = cur.lengthMs,
            isPausedByListener = { discriminator.pausedByListener },
            stillWaiting = { running && playGeneration == gen && waitingForLive },
            onExpire = {
                log("[playback] advance: live capture past its length+grace song=${queue.getOrNull(index)?.id ?: "?"}")
                advanceToNext(AdvanceCause.NATURAL_END)
            },
        )
    }

    private fun armResolveStall(gen: Long) {
        stallTimer.arm(
            stillStalled = {
                running && playGeneration == gen && index < queue.size && firstAudioPending && !held && !pausedByCascade
            },
            onStall = { waited ->
                if (!hopToPlayableRow("resolve stalled ${waited}s")) {
                    log(
                        "[playback] resolve stalled ${waited}s song=${queue.getOrNull(index)?.id ?: "?"} " +
                            "\u2014 no on-device/instant row to hop to; waiting",
                    )
                }
            },
        )
    }

    /**
     * Play the next ON-DEVICE row now (else the next row that starts instantly) and DEFER the current
     * (stalled) row right behind it - reordered, never dropped. Shared by the resolve stall, the start
     * watchdog and the supervisor's L3. False when no such row is within the lookahead.
     */
    private fun hopToPlayableRow(reason: String): Boolean {
        if (index >= queue.size) return false
        val stalled = queue[index]
        val choice = ResolveStallHop.choose(
            queue, index, rowOnDevice, rowStartsInstantly, abandoned = stallEpisodeAbandoned,
        ) ?: return false
        stallEpisodeAbandoned = stallEpisodeAbandoned + stalled.uid
        val row = ResolveStallHop.apply(queue, index, choice)
        log("[playback] $reason song=${stalled.id} \u2192 hop to ${choice.kind.label} ${row.id} (deferred stalled row)")
        queueEdited()
        noteTransition(stalled.uid, TransitionCause.STALL_HOP)
        startPlayCurrent()
        return true
    }

    /** Uids hopped away from since the last first audio / user transport / stop (one stall EPISODE). */
    private var stallEpisodeAbandoned: Set<String> = emptySet()

    /** First audio, any user transport, or stop ends the episode; logged only if a hop happened. */
    private fun endStallEpisode(reason: String) {
        if (stallEpisodeAbandoned.isEmpty()) return
        log("[playback] stall episode end reason=$reason abandoned=${stallEpisodeAbandoned.size}")
        stallEpisodeAbandoned = emptySet()
    }

    private fun armStartStall(gen: Long, songId: String) {
        if (engine == null) return
        startWatchdog.arm(
            stillOwed = { startStallStillOwed(gen) },
            onRekick = { waited ->
                logStartStall(songId, waited)
                engine?.rekick("player.startStall")
            },
            onEscalate = { waited ->
                logStartStall(songId, waited)
                escalateStalledStart("start-stall ${waited}s")
            },
        )
    }

    private fun startStallStillOwed(gen: Long): Boolean {
        val e = engine ?: return false
        return running && playGeneration == gen && !held && !pausedByCascade &&
            e.hasLoadedItem && !e.isPlaying && !e.trackEnded &&
            !discriminator.pausedByListener && !discriminator.interruptionOpen
    }

    private fun logStartStall(songId: String, waited: Int) {
        val pos = engine?.positionMs ?: 0
        log("[playback] start-stall song=$songId waited=$waited status=waiting pos=${pos}ms runway=${if (startWindow != null) 1 else 0}")
    }

    /**
     * The current row could not get to audio: hop to the next playable row (deferring this one right behind
     * it), else advance - through the cascade breaker (AUTO).
     */
    fun escalateStalledStart(reason: String) {
        if (!running || index >= queue.size || held || pausedByCascade) return
        if (hopToPlayableRow(reason)) return
        log("[playback] advance: $reason song=${queue[index].id} \u2014 no on-device row to hop to")
        advanceToNext(AdvanceCause.STALL_HOP)
    }

    // ---- supervisor hooks (only ever called while the listener intends to hear sound) ---------------

    /** L2: re-resolve + restart the CURRENT row at its current position. NOT a user transport. */
    fun supervisorRetryInPlace() {
        if (!running || index >= queue.size || held || pausedByCascade) return
        val at = engine?.positionMs ?: 0L
        NPLog.lane(NPLog.SUPERVISOR, "retry in place song=${queue[index].id} atMs=$at")
        startPlayCurrent(fresh = false, resumeAtMs = if (at > 1000) at else null, reResolve = true)
    }

    /** L3: hop / advance through the cascade breaker. */
    fun supervisorEscalate() = escalateStalledStart("supervisor L3")

    // ---- PB-3: audible time, cascade breaker, rip window ----------------------------------------------

    private fun resetTrackAudible() {
        trackAudibleSeconds = 0.0
        lastAudibleSampleMs = clockMs()
    }

    private fun ensureHealthTicker() {
        if (engine == null || healthTicker?.isActive == true) return
        healthTicker = scope.launch {
            while (isActive) {
                kotlinx.coroutines.delay(1_000)
                sampleAudible()
            }
        }
    }

    /** One 1 Hz sample: accumulate audible time while the engine is really rendering this run's row. */
    fun sampleAudible() {
        val now = clockMs()
        val dtMs = lastAudibleSampleMs?.let { now - it } ?: 0L
        lastAudibleSampleMs = now
        val e = engine ?: return
        if (!running || held) return
        if (e.hasLoadedItem && !pausedByCascade) {
            queue.getOrNull(index)?.let { cur ->
                val pos = e.positionMs
                val dur = cur.lengthMs?.takeIf { it > 0 } ?: e.durationMs
                skipTracker?.samplePosition(cur.id, pos, dur)
                PlayEventBus.emit(PlayProgress(cur.id, pos, dur))
            }
        }
        if (!(e.hasLoadedItem && e.isPlaying)) return
        addAudibleSeconds((dtMs / 1000.0).coerceIn(0.0, 5.0))
    }

    /**
     * Test seam + the ticker's sink. Once the track has really played the run is not a cascade (reset + clear
     * any stale notice); past [PlaybackRipWindow.HEARD_SECONDS] its rip is exempt from window cancellation.
     */
    fun addAudibleSeconds(seconds: Double) {
        val before = trackAudibleSeconds
        trackAudibleSeconds += seconds
        if (before < AutoAdvanceCascadeBreaker.MIN_AUDIBLE_SECONDS &&
            trackAudibleSeconds >= AutoAdvanceCascadeBreaker.MIN_AUDIBLE_SECONDS
        ) {
            breaker.reset()
            if (!pausedByCascade && notice != null) {
                notice = null
                publish()
            }
        }
        if (before < PlaybackRipWindow.HEARD_SECONDS && trackAudibleSeconds >= PlaybackRipWindow.HEARD_SECONDS &&
            running && index < queue.size
        ) {
            ripWindow.keep(setOf(queue[index].id, queue[index].resolveId))
        }
    }

    /** The listener acted: whatever happened before is not a cascade any more. */
    private fun noteUserTransport() {
        endStallEpisode("user")
        breaker.reset()
        pausedByCascade = false
        notice = null
    }

    /**
     * Stop auto-advancing: hold the CURRENT row (the queue position is kept), silence it, and say why.
     * Play retries this row ([startCurrent]); skip / previous / jump move on as usual.
     */
    private fun haltCascade() {
        val row = queue.getOrNull(index)?.id ?: "?"
        log(
            "[playback] cascade-stop song=$row index=$index/${queue.size} " +
                "quickAdvances=${AutoAdvanceCascadeBreaker.LIMIT} backend=$currentBackend audible=${trackAudibleSeconds.toInt()}s",
        )
        playJob?.cancel()
        playJob = null
        playGeneration++ // a resolve still in flight must not start audio now
        cancelHealthTimers()
        endStartWindow("cascade-halt")
        meter?.transitionAbandoned("cascade-halt")
        firstAudioPending = false
        waitingForLive = false
        scope.launch { runCatching { port.pause() } }
        discriminator.noteListenerIntent(false) // halted: nothing may "keep playing" it until play
        pausedByCascade = true
        notice = if (appleMusicActive()) {
            AutoAdvanceCascadeBreaker.APPLE_MUSIC_NOTICE
        } else {
            AutoAdvanceCascadeBreaker.GENERIC_NOTICE
        }
        publish()
        reconcilePreload() // disarmed: empties slot 1 so the engine cannot roll on past the halt
    }

    /** The ids inside the rip window: the playing row + the next [PlaybackRipWindow.AHEAD], base + resolve. */
    fun currentRipWindowIds(): Set<String> {
        if (!running || index >= queue.size) return emptySet()
        return PlaybackRipWindow.windowIds(queue.map { PlaybackRipWindow.Row(it.id, it.resolveId) }, index)
    }

    /** May a playback rip for [id] be requested right now? A song outside the running set is not this session's call. */
    fun playbackRipAllowed(id: String): Boolean {
        if (!running || held || !inRunningQueue(id)) return true
        return id in currentRipWindowIds()
    }

    /**
     * The server queued a playback rip. Track it when it is this session's (a member row inside the window);
     * one that landed after the playhead already left the window (a slow POST under a skip storm) is
     * cancelled at once.
     */
    fun notePlaybackRipQueued(id: String) {
        if (!running || !inRunningQueue(id) || isUserRequestedRip(id)) return
        if (id in currentRipWindowIds()) ripWindow.record(id) else cancelRipIds(listOf(id), "late-outside-window")
    }

    /** Cancel every tracked rip that is no longer inside the window. */
    fun reconcileRipWindow() {
        if (!running || ripWindow.requested.isEmpty()) return
        cancelRipIds(ripWindow.evict(currentRipWindowIds()), "outside-window")
    }

    /** Coalesce queue-edit reconciles (a reshuffle and a track start in one turn reconcile once). */
    private fun scheduleRipWindowReconcile() {
        if (ripWindow.requested.isEmpty() || ripReconcileQueued) return
        ripReconcileQueued = true
        scope.launch {
            ripReconcileQueued = false
            reconcileRipWindow()
        }
    }

    /** The session is ending (stop / replaced by a fresh play): cancel everything it queued except the sounding row. */
    private fun endRipWindowSession(reason: String) {
        if (ripWindow.requested.isEmpty()) return
        val cur = queue.getOrNull(index)
        val playing = if (running && cur != null) setOf(cur.id, cur.resolveId) else emptySet()
        cancelRipIds(ripWindow.endSession(playing), reason)
    }

    private fun cancelRipIds(ids: List<String>, reason: String) {
        // Belt and braces: a user surface may have asked for the same song since we tracked it.
        val toCancel = ids.filter { !isUserRequestedRip(it) }
        if (toCancel.isEmpty()) return
        NPLog.lane(NPLog.RIPREQ, "rip window cancel n=${toCancel.size} reason=$reason ids=${toCancel.joinToString(",")}")
        cancelPlaybackRips?.invoke(toCancel)
    }

    // ---- transport passthrough ---------------------------------------------------------------

    suspend fun pause() {
        if (redirected(TransportRedirect.SetPlaying(false))) return
        reportUserTransport(UserTransport.PAUSE)
        port.pause()
    }
    suspend fun resume() {
        if (redirected(TransportRedirect.SetPlaying(true))) return
        fireUser(UserTransport.PLAY)
        port.resume()
    }
    suspend fun seekTo(positionMs: Long) { fireUser(UserTransport.SEEK); port.seekTo(positionMs) }
}

/** `[session] ...` lines go to the `session` lane (adb logcat -s PocketDJ.session); the rest to `playback`. */
private fun defaultLog(line: String) {
    if (line.startsWith("[session] ")) {
        NPLog.lane(NPLog.SESSION, line.removePrefix("[session] "))
    } else {
        NPLog.lane(NPLog.PLAYBACK, line.removePrefix("[playback] "))
    }
}

private const val GHOST_RUN_PREFIX = "puzzle_"
