package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.TransitionCause

/**
 * A player with no audio (iOS `InMemoryRemoteTarget`): the queue / index / play-state / position bookkeeping of the
 * sequencer and nothing else. Position advances on an injectable clock while playing. Used by tests and the
 * showcase seed's fake "Car" speaker.
 */
class InMemoryRemoteTarget(private val now: () -> Double = { System.currentTimeMillis().toDouble() }) : RemotePlaybackTarget {
    private var queue: List<QueueItem> = emptyList()
        set(v) { field = v; queueGeneration++ }

    override var queueGeneration: Long = 0; private set
    override var currentIndex: Int = 0; private set
    override var isRunning: Boolean = false; private set
    override var isPlaying: Boolean = false; private set
    override var repeatMode: RepeatMode = RepeatMode.OFF; private set
    override var shuffleEnabled: Boolean = false; private set
    override var isTransitioning: Boolean = false
    override var hasCoarsePosition: Boolean = false
    override var isSystemPaused: Boolean = false; private set
    override var transitionSeq: Long = 0; private set
    override var lastTransitionCause: TransitionCause = TransitionCause.USER; private set
    override var lastUserTransitionSeq: Long = 0; private set
    override var userPlayIntentSeq: Long = 0; private set
    override var lastUserPlayIntent: Boolean = false; private set

    /** A start in flight that WILL sound when it settles ([settlePendingStart]): the race a plain pause can't win. */
    var pendingStartWillPlay: Boolean = false; private set

    private var basePositionMs = 0L
    private var baseAt = 0.0
    private val _log = mutableListOf<String>()

    /** Every mutating call, in order (tests assert what the reconciler did). */
    val log: List<String> get() = _log

    override val queueCount: Int get() = queue.size
    override fun item(at: Int): QueueItem = queue[at]
    override val positionMs: Long
        get() = if (isPlaying) basePositionMs + Math.round(now() - baseAt) else basePositionMs

    private fun setPosition(ms: Long) { basePositionMs = maxOf(0L, ms); baseAt = now() }

    private fun transition(cause: TransitionCause) {
        transitionSeq++
        lastTransitionCause = cause
        if (cause == TransitionCause.USER) lastUserTransitionSeq = transitionSeq
    }

    override fun play(items: List<QueueItem>, startIndex: Int, atMs: Long, startPaused: Boolean) {
        if (items.isEmpty()) return
        _log += if (startPaused) "play(paused)" else "play"
        queue = items
        currentIndex = startIndex.coerceIn(0, items.size - 1)
        isRunning = true
        shuffleEnabled = false
        pendingStartWillPlay = false
        isPlaying = !startPaused
        if (!startPaused) isSystemPaused = false
        setPosition(atMs)
        transition(TransitionCause.REMOTE)
    }

    override fun jumpToUpcoming(uid: String, atMs: Long) {
        val i = queue.indexOfFirst { it.uid == uid }
        if (i < 0 || i <= currentIndex) return
        _log += if (atMs > 1_000) "jump@$atMs" else "jump"
        isSystemPaused = false // a jump loads (and sounds) the row
        currentIndex = i
        setPosition(if (atMs > 1_000) atMs else 0)
        transition(TransitionCause.REMOTE)
    }

    override fun replaceUpcoming(count: Int, items: List<QueueItem>) {
        if (!isRunning) return
        _log += "replaceUpcoming"
        val lo = minOf(currentIndex + 1, queue.size)
        val hi = minOf(queue.size, lo + maxOf(0, count))
        queue = queue.subList(0, lo) + items + queue.subList(hi, queue.size)
    }

    override fun insertUpcoming(items: List<QueueItem>, beforeUid: String?) {
        if (!isRunning || items.isEmpty()) return
        _log += "insert"
        val i = beforeUid?.let { u -> queue.indexOfFirst { it.uid == u } } ?: -1
        queue = if (i > currentIndex) queue.subList(0, i) + items + queue.subList(i, queue.size) else queue + items
    }

    override fun appendToQueue(items: List<QueueItem>) {
        if (!isRunning || items.isEmpty()) return
        _log += "append"
        queue = queue + items
    }

    override fun setPlaying(on: Boolean) {
        if (!isRunning || on == isPlaying) return
        _log += if (on) "resume" else "pause"
        setPosition(positionMs)
        isPlaying = on
        if (on) isSystemPaused = false
    }

    override fun seek(toMs: Long) { _log += "seek"; setPosition(toMs) }
    override fun setRepeatMode(mode: RepeatMode) { repeatMode = mode }
    override fun setShuffle(on: Boolean) { shuffleEnabled = on }

    override fun silenceForController() {
        if (!(isPlaying || pendingStartWillPlay || isTransitioning)) return
        _log += "silence"
        setPosition(positionMs)
        isPlaying = false
        pendingStartWillPlay = false
        isTransitioning = false
    }

    // ---- simulated local user actions (what the Now Playing UI would do) -----------------------------------

    fun userSkipNext() {
        if (!isRunning || currentIndex + 1 >= queue.size) return
        currentIndex++
        setPosition(0)
        transition(TransitionCause.USER)
    }

    fun userSetPlaying(on: Boolean) {
        userPlayIntentSeq++
        lastUserPlayIntent = on
        setPosition(positionMs); isPlaying = on
        if (on) isSystemPaused = false
    }

    fun userSeek(ms: Long) = setPosition(ms)
    fun userAppend(items: List<QueueItem>) { queue = queue + items }
    fun userRemoveUpcoming(offset: Int) {
        val i = currentIndex + 1 + offset
        if (i in queue.indices) queue = queue.toMutableList().also { it.removeAt(i) }
    }
    fun userPlay(items: List<QueueItem>) {
        queue = items; currentIndex = 0; isRunning = true; isPlaying = true; setPosition(0)
        transition(TransitionCause.USER)
    }

    // ---- simulated player-driven events (no listener involved) ----------------------------------------------

    /** The player moved on BY ITSELF ([cause]: a natural end, a stall hop, a dead source). Past the last row it stops the set. */
    fun simulateAutoAdvance(cause: TransitionCause) {
        if (!isRunning) return
        transition(cause)
        if (currentIndex + 1 < queue.size) {
            currentIndex++
            setPosition(0)
        } else {
            isRunning = false
            isPlaying = false
            queue = emptyList()
            currentIndex = 0
        }
    }

    /** The device's SYSTEM paused it (noisy / focus loss without resume): no listener intent recorded. */
    fun simulateSystemPause() {
        if (!isPlaying) return
        setPosition(positionMs)
        isPlaying = false
        isSystemPaused = true
    }

    /** A start in flight: nothing sounds yet, and it WILL sound when it settles. */
    fun beginPendingStart() {
        isTransitioning = true
        pendingStartWillPlay = true
        setPosition(positionMs)
        isPlaying = false
    }

    fun settlePendingStart() {
        isTransitioning = false
        if (pendingStartWillPlay) { pendingStartWillPlay = false; setPosition(positionMs); isPlaying = true }
    }
}
