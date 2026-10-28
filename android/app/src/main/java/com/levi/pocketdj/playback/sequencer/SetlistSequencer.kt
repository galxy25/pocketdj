package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.collections.CollectionMembership
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlayContext
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
    private val log: (String) -> Unit = { NPLog.lane(NPLog.PLAYBACK, it.removePrefix("[playback] ")) },
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

    /** Listened fraction of the current track right now (0..1), or null when unknown. */
    @Volatile var progressProvider: () -> Double? = { null }

    /** Persist the sticky repeat mode. */
    @Volatile var onRepeatModeChanged: (RepeatMode) -> Unit = {}

    /** Cascade-breaker seam: return false to HALT an [AdvanceCause.AUTO] advance. */
    @Volatile var autoAdvanceGate: () -> Boolean = { true }

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

    private val _state = MutableStateFlow(SequencerState(repeatMode = initialRepeatMode))
    val state: StateFlow<SequencerState> = _state.asStateFlow()

    // ---- mutable core (single-threaded by contract) ---------------------------------------
    private val queue = ArrayList<QueueItem>()
    private var index = 0
    private var running = false
    private var held = false
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
    val isStartPending: Boolean get() = playJob?.isActive == true || startWindow != null

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
            sourceSetlistId = sourceSetlistId,
            capturedContext = capturedContext,
            capturedOrigin = capturedOrigin,
            repeatMode = repeatMode,
            shuffleEnabled = shuffleEnabled,
            playbackNotice = notice,
            waitingForLive = waitingForLive,
            pausedByCascade = pausedByCascade,
            playGeneration = playGeneration,
            deviceQueueUnplayable = deviceQueueUnplayable,
            deviceUnplayableSourceId = deviceUnplayableSourceId,
        )
    }

    private fun queueEdited() {
        memberIds = null
        publish()
        scheduleRipWindowReconcile()
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
    ) {
        if (items.isEmpty()) return
        log("[playback] set start count=${items.size} source=${sourceSetlistId ?: "-"}")
        val first = items.first()
        if (running && !isRestartOfCurrent(first.id)) noteAdvanceAway()
        // The previous session's playback rips (minus the row that was sounding and anything heard) are
        // cancelled - a fresh run has its own window.
        if (running) endRipWindowSession("new-session")
        noteUserTransport()
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
        pendingResumeMs = null
        notice = null
        deviceQueueUnplayable = false
        deviceUnplayableSourceId = null
        startedAnyRow = false
        lastLoadedId = null
        unplayableStreak = 0
        memberIds = null
        publish()
        startPlayCurrent()
    }

    private fun stamp(items: List<QueueItem>, setlistId: String?): List<QueueItem> {
        val decider = editionDecider
        if (!decider.isActive()) return items
        val cleanOnly = cleanOnlyProvider(setlistId)
        return items.map { if (it.editionLocked) it else decider.decide(it, cleanOnly) }
    }

    /** Tear the run down (natural end included): cancels any in-flight resolve, clears the queue. */
    fun stop() {
        val wasRunning = running
        endRun()
        if (wasRunning) scope.launch { runCatching { port.stop() } }
    }

    /**
     * End the run WITHOUT touching the player - a foreign play (an album queue) has taken the
     * engine over and must keep sounding.
     */
    fun abandonRun() = endRun()

    private fun endRun() {
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
        running = false
        held = false
        notice = null
        index = 0
        queue.clear()
        sourceSetlistId = null
        capturedContext = null
        capturedOrigin = null
        pendingResumeMs = null
        unplayableStreak = 0
        lastLoadedId = null
        memberIds = null
        publish()
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

    private fun startPlayCurrent(fresh: Boolean = true, resumeAtMs: Long? = null, inPlace: Boolean = false) {
        resetTrackAudible()
        reconcileRipWindow() // the playhead (may have) moved: rips outside the window go
        ensureHealthTicker()
        playJob?.cancel()
        // LAZY + assign + start: an inline-dispatching scope may run (and even recurse into) this
        // body before launch() returns; the handle must already be in place so a nested start
        // cancels THIS job, not a stale one.
        val job = scope.launch(start = CoroutineStart.LAZY) { playCurrent(fresh, resumeAtMs, inPlace) }
        playJob = job
        job.start()
    }

    private suspend fun playCurrent(fresh: Boolean, resumeAtMs: Long?, inPlace: Boolean) {
        if (!running || index >= queue.size) return
        // A job cancelled BEFORE it ran must do nothing - above all it must not claim a generation.
        if (!currentCoroutineContext().isActive) return
        if (fresh) playsRemaining = CollectionMembership.normalizedRepeat(queue[index].repeatCount)
        val gen = ++playGeneration
        val item = queue[index]
        val at = index
        // A new generation retires the previous start's timers; the start window + resolve stall guard this one.
        cancelHealthTimers()
        waitingForLive = false
        firstAudioPending = true
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
                handleFirstAudio("replay") // the engine already holds the row: audio is immediate
                return
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
                advanceToNext(AdvanceCause.AUTO)
            }
            return
        }
        if (owns(gen)) {
            startedAnyRow = true
            lastLoadedId = item.id
            if (source !is RipOnDemandSource) {
                // Loaded: the network resolve is over. The start watchdog owns it from here.
                stallTimer.cancel()
                armStartStall(gen, item.id)
            } // a rip-on-demand row stays under the resolve stall until noteSourceResolved()
        }
    }

    /**
     * Count one failed row (unplayable, load error, mid-song failure). A full lap of failures with
     * repeat ALL stops the run instead of spinning forever on a wrapped set (until PB-3's cascade
     * breaker). The streak resets only when a row plays through or the listener acts.
     */
    private fun failureLapComplete(): Boolean {
        if (++unplayableStreak >= queue.size.coerceAtLeast(1) && repeatMode == RepeatMode.ALL) {
            finishRun()
            return true
        }
        return false
    }

    private fun owns(gen: Long): Boolean = running && gen == playGeneration

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
        outcomes?.emit(queue[index].id, false, 1.0)
        unplayableStreak = 0
        if (repeatMode == RepeatMode.ONE) {
            startPlayCurrent(fresh = true, inPlace = true)
            return
        }
        if (playsRemaining > 1) {
            playsRemaining--
            startPlayCurrent(fresh = false, inPlace = true)
            return
        }
        advanceToNext(AdvanceCause.AUTO)
    }

    /** The row failed mid-song (dead source): advance, never replay. */
    fun handleFailed(songId: String) {
        if (!running || index >= queue.size || !queue[index].matches(songId)) return
        log("[playback] advance: item failed mid-song song=${queue[index].id} index=$index/${queue.size}")
        lastLoadedId = null
        if (failureLapComplete()) return
        advanceToNext(AdvanceCause.AUTO)
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
        noteUserTransport()
        noteAdvanceAway()
        exitHoldIfNeeded()
        retirePendingStart() // the manual play owns the engine now; a pending resolve must not load over it
        index = pos
        playsRemaining = CollectionMembership.normalizedRepeat(queue[pos].repeatCount)
        log("[playback] adopt jump index=${pos + 1}/${queue.size} song=$songId")
        publish()
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
        noteAdvanceAway()
        exitHoldIfNeeded()
        unplayableStreak = 0
        advanceToNext(AdvanceCause.USER)
    }

    /** ⏮: never below 0; at the top it restarts (or wraps to the last row with repeat ALL). */
    fun skipPrevious() {
        if (!running) return
        noteUserTransport()
        exitHoldIfNeeded()
        if (index == 0) {
            if (repeatMode == RepeatMode.ALL && queue.size > 1) index = queue.size - 1
        } else {
            index -= 1
        }
        publish()
        startPlayCurrent()
    }

    private fun advanceToNext(cause: AdvanceCause) {
        if (!running) return
        when (cause) {
            AdvanceCause.USER -> noteUserTransport()
            AdvanceCause.UNPLAYABLE_HERE -> Unit
            AdvanceCause.AUTO -> {
                // Halted: nothing advances by itself until the listener acts.
                if (pausedByCascade || !autoAdvanceGate()) return
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
        val dupNext = cause == AdvanceCause.AUTO && fromId != null && queue.getOrNull(index + 1)?.id == fromId
        index += 1
        if (index >= queue.size) {
            if (repeatMode == RepeatMode.ALL && queue.isNotEmpty()) {
                index = 0
                // Reshuffle the whole queue on a shuffle wrap so the next pass differs;
                // canonicalOrder is untouched so shuffle-OFF still restores.
                if (shuffleEnabled) reshuffleEntireQueue()
                queueEdited()
                startPlayCurrent(fresh = true, inPlace = cause == AdvanceCause.AUTO && fromId != null && queue.getOrNull(0)?.id == fromId)
                return
            }
            finishRun()
        } else {
            publish()
            startPlayCurrent(fresh = true, inPlace = dupNext)
        }
    }

    /** Past the end: tear down; a device-mode run that loaded nothing raises the one-shot banner. */
    private fun finishRun() {
        val nothingStarted = !startedAnyRow
        val device = modeProvider() == PlaybackMode.DEVICE
        val raisedBy = sourceSetlistId
        stop()
        if (nothingStarted) {
            // Device mode keeps its banner signal; cloud mode (every row unplayable / failed) gets a
            // notice the UI surfaces so a dead set never ends in silence with no feedback.
            if (device) deviceQueueUnplayable = true
            deviceUnplayableSourceId = raisedBy
            notice = if (device) "Nothing in this set is on this device" else "None of these tracks are playable on this device yet"
            publish()
        }
    }

    private fun isRestartOfCurrent(destinationId: String): Boolean =
        running && queue.getOrNull(index)?.matches(destinationId) == true

    /** The listener moved away from the current track by their own action (never a natural end). */
    private fun noteAdvanceAway() {
        val cur = queue.getOrNull(index) ?: return
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
    ) {
        if (items.isEmpty() || running) return
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
        pendingResumeMs = resumeAtMs
        queueEdited()
        onHeldRestored()
    }

    /** First explicit ▶ on a held deck: start the current row, mid-song when a position was saved. */
    fun resumeFromHold() {
        if (!running || !held) return
        val at = pendingResumeMs
        noteUserTransport()
        held = false
        pendingResumeMs = null
        playsRemaining = CollectionMembership.normalizedRepeat(queue.getOrNull(index)?.repeatCount)
        publish()
        startPlayCurrent(fresh = false, resumeAtMs = at)
    }

    /** Start the current row from the top (cascade-halted deck, idle ▶). */
    fun startCurrent(): Boolean {
        if (!running || index >= queue.size) return false
        noteUserTransport()
        discriminator.noteListenerIntent(true)
        held = false
        publish()
        startPlayCurrent()
        return true
    }

    private fun exitHoldIfNeeded() {
        if (!held) return
        held = false
        pendingResumeMs = null
    }

    // ---- repeat & shuffle -------------------------------------------------------------------

    fun cycleRepeatMode() = setRepeatMode(repeatMode.next)

    /** No-op when unchanged. Safe while idle: the mode simply rides the next run. */
    fun setRepeatMode(mode: RepeatMode) {
        if (mode == repeatMode) return
        repeatMode = mode
        onRepeatModeChanged(mode)
        publish()
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
        queueEdited()
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
     * Reorder within the tail (SwiftUI `.onMove` shape; offsets relative to the tail, 0 = right
     * after the current). Stale offsets are dropped and [toOffset] is CLAMPED to the live tail.
     */
    fun moveUpcoming(fromOffsets: Collection<Int>, toOffset: Int) {
        if (!running || index + 1 >= queue.size) return
        val tail = queue.subList(index + 1, queue.size).toMutableList()
        val src = fromOffsets.filter { it in tail.indices }.toSortedSet().toList()
        if (src.isEmpty()) return
        val dest = toOffset.coerceIn(0, tail.size)
        val moved = src.map { tail[it] }
        val remaining = tail.filterIndexed { i, _ -> i !in src }
        val insertAt = (dest - src.count { it < dest }).coerceIn(0, remaining.size)
        val out = remaining.toMutableList().also { it.addAll(insertAt, moved) }
        replaceTail(out)
        queueEdited()
    }

    /** Remove tail rows by IDENTITY (a stale position would delete whatever shifted into the slot). */
    fun removeUpcoming(uids: Set<String>) {
        if (!running || index + 1 >= queue.size || uids.isEmpty()) return
        val tail = queue.subList(index + 1, queue.size).filter { it.uid !in uids }
        if (tail.size == queue.size - index - 1) return
        replaceTail(tail)
        queueEdited()
    }

    /** Append to the end of the running queue. No-op when idle (resurrecting is a fresh [play]). */
    fun appendToQueue(items: List<QueueItem>) {
        if (!running || items.isEmpty()) return
        queue.addAll(items)
        queueEdited()
    }

    /**
     * Game seam: append rows stamped with [runTag]; the tag rides into each row's
     * [PlayContext.runTag]. No-op when idle.
     */
    fun appendRows(items: List<QueueItem>, runTag: String) =
        appendToQueue(items.map { it.copy(runTag = runTag) })

    /** "Add next": right AFTER the current one. */
    fun insertNextInQueue(items: List<QueueItem>) {
        if (!running || items.isEmpty()) return
        queue.addAll(minOf(index + 1, queue.size), items)
        queueEdited()
    }

    /** Before an upcoming row by identity; an unknown/played anchor falls back to append. */
    fun insertInQueue(items: List<QueueItem>, beforeUid: String) {
        if (!running || items.isEmpty()) return
        val pos = (index + 1 until queue.size).firstOrNull { queue[it].uid == beforeUid }
        if (pos == null) {
            appendToQueue(items)
            return
        }
        queue.addAll(pos, items)
        queueEdited()
    }

    /** Jukebox "Surprise Slot": a random slot in the tail; [slot] is injectable for tests. */
    fun insertRandomInQueue(
        items: List<QueueItem>,
        slot: (IntRange) -> Int = { random.nextInt(it.first, it.last + 1) },
    ) {
        if (!running || items.isEmpty()) return
        val lo = minOf(index + 1, queue.size)
        val at = slot(lo..queue.size).coerceIn(lo, queue.size)
        queue.addAll(at, items)
        queueEdited()
    }

    /** "Play next". Unknown/played uids are ignored. */
    fun moveUpcomingNext(uid: String) {
        val pos = upcomingPos(uid) ?: return
        queue.add(index + 1, queue.removeAt(pos))
        queueEdited()
    }

    /** "Move to end". */
    fun moveUpcomingToEnd(uid: String) {
        val pos = upcomingPos(uid) ?: return
        queue.add(queue.removeAt(pos))
        queueEdited()
    }

    private fun upcomingPos(uid: String): Int? {
        if (!running || index + 1 >= queue.size) return null
        return (index + 1 until queue.size).firstOrNull { queue[it].uid == uid }
    }

    /** Up Next "Play now": step the cursor onto EXACTLY this row (uid, not song id). */
    fun jumpToUpcoming(uid: String) {
        val pos = upcomingPos(uid) ?: return
        if (!isRestartOfCurrent(queue[pos].id)) noteAdvanceAway()
        noteUserTransport()
        exitHoldIfNeeded()
        index = pos
        publish()
        startPlayCurrent()
    }

    /**
     * "PLAY NOW" of a (fresh) item: splice it right after the current row and step onto it, so the
     * interrupted track stays in the played region and the tail is untouched. A duplicate uid is
     * refreshed - the uid-keyed edits rely on uniqueness.
     */
    fun playNow(item: QueueItem) {
        if (!running) return
        if (!isRestartOfCurrent(item.id)) noteAdvanceAway()
        noteUserTransport()
        exitHoldIfNeeded()
        val fresh = if (queue.any { it.uid == item.uid }) item.freshInstance() else item
        val at = minOf(index + 1, queue.size)
        queue.add(at, fresh)
        index = at
        queueEdited()
        startPlayCurrent()
    }

    /** "Rewind to here": the needle lands on a played row; rows between return to the tail. */
    fun jumpToPlayed(uid: String) {
        if (!running || index <= 0) return
        val pos = (0 until minOf(index, queue.size)).firstOrNull { queue[it].uid == uid } ?: return
        if (!isRestartOfCurrent(queue[pos].id)) noteAdvanceAway()
        noteUserTransport()
        exitHoldIfNeeded()
        index = pos
        publish()
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
            endRun()
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
        if (!firstAudioPending && startWindow == null) return
        firstAudioPending = false
        meter?.firstAudio(currentBackend, clockMs())
        startWatchdog.cancel()
        stallTimer.cancel()
        startWindow?.let { log("[playback] start-ok song=${it.songId} after=${clockMs() - it.beganMs}ms") }
        endStartWindow("firstAudio.$source")
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
                advanceToNext(AdvanceCause.AUTO)
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
        val choice = ResolveStallHop.choose(queue, index, rowOnDevice, rowStartsInstantly) ?: return false
        val stalled = queue[index]
        val row = ResolveStallHop.apply(queue, index, choice)
        log("[playback] $reason song=${stalled.id} \u2192 hop to ${choice.kind.label} ${row.id} (deferred stalled row)")
        queueEdited()
        startPlayCurrent()
        return true
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
        advanceToNext(AdvanceCause.AUTO)
    }

    // ---- supervisor hooks (only ever called while the listener intends to hear sound) ---------------

    /** L2: re-resolve + restart the CURRENT row at its current position. NOT a user transport. */
    fun supervisorRetryInPlace() {
        if (!running || index >= queue.size || held || pausedByCascade) return
        val at = engine?.positionMs ?: 0L
        NPLog.lane(NPLog.SUPERVISOR, "retry in place song=${queue[index].id} atMs=$at")
        startPlayCurrent(fresh = false, resumeAtMs = if (at > 1000) at else null)
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

    suspend fun pause() = port.pause()
    suspend fun resume() = port.resume()
    suspend fun seekTo(positionMs: Long) = port.seekTo(positionMs)
}
