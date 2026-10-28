package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.collections.CollectionMembership
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlaybackMode
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
    private val log: (String) -> Unit = { NPLog.lane(NPLog.PLAYBACK, it) },
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
    /** An AUTO advance was halted by [autoAdvanceGate]; the deck sits on a stale/ended row until ▶. */
    private var cascadeHalted = false
    /** Id of the row the engine currently holds as the sequencer's own load (in-place replay gate). */
    private var lastLoadedId: String? = null
    private var deviceQueueUnplayable = false
    private var deviceUnplayableSourceId: String? = null
    private var pendingResumeMs: Long? = null
    private var unplayableStreak = 0
    private var memberIds: Set<String>? = null

    val isRunning: Boolean get() = running

    /** A row's resolve/load is in flight (a remote idle ▶ must not double-start it). */
    val isStartPending: Boolean get() = playJob?.isActive == true

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
            playGeneration = playGeneration,
            deviceQueueUnplayable = deviceQueueUnplayable,
            deviceUnplayableSourceId = deviceUnplayableSourceId,
            pausedByCascade = running && cascadeHalted,
        )
    }

    private fun queueEdited() {
        memberIds = null
        publish()
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
        cascadeHalted = false
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
        if (cascadeHalted) { cascadeHalted = false; publish() }
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
        if (cause == AdvanceCause.AUTO && !autoAdvanceGate()) {
            cascadeHalted = true
            publish()
            return
        }
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
        held = false
        pendingResumeMs = null
        playsRemaining = CollectionMembership.normalizedRepeat(queue.getOrNull(index)?.repeatCount)
        publish()
        startPlayCurrent(fresh = false, resumeAtMs = at)
    }

    /** Start the current row from the top (cascade-halted deck, idle ▶). */
    fun startCurrent(): Boolean {
        if (!running || index >= queue.size) return false
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

    // ---- transport passthrough ---------------------------------------------------------------

    suspend fun pause() = port.pause()
    suspend fun resume() = port.resume()
    suspend fun seekTo(positionMs: Long) = port.seekTo(positionMs)
}
