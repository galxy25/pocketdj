package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SequencerListener
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.Transition
import com.levi.pocketdj.playback.sequencer.TransitionCause
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

/**
 * Production [RemotePlaybackTarget] over the app-scoped [SetlistSequencer] (iOS `SetlistPlayerRemoteTarget`).
 *
 * Every mutation runs as an external APPLY ([SetlistSequencer.applyingExternal]): tagged [TransitionCause.REMOTE],
 * never listener intent, and past the controller transport gate. Suspend transports are launched UNDISPATCHED
 * inside the apply so the gate/intent checks (which run before the first suspension) see the external depth.
 *
 * The platform facts the sequencer cannot know are seams, wired by P2-REM-3 / the graph:
 * [systemPaused] (PlaybackService pause classification), [coarsePosition] (the Apple Music backend is active) and
 * [extraSilencers] (NP DSP host, Mix decks), run on every [silenceForController] (the controller re-asserts it each tick).
 */
class SequencerRemoteTarget(
    private val seq: SetlistSequencer,
    private val scope: CoroutineScope,
    private val systemPaused: () -> Boolean = { false },
    private val coarsePosition: () -> Boolean = { seq.appleMusicActive() },
    private val extraSilencers: () -> List<() -> Unit> = { RemoteControllerGate.shared.silencerSnapshot() },
) : RemotePlaybackTarget {

    @Volatile private var lastCause: TransitionCause = TransitionCause.USER

    private val listener = object : SequencerListener {
        override fun onTransition(t: Transition) { lastCause = t.cause }
    }

    init { seq.hooks.add(listener) }

    /** Unhook from the sequencer (the session ended / the graph is torn down). */
    fun close() { seq.hooks.remove(listener) }

    private val state get() = seq.state.value

    override val queueGeneration: Long get() = seq.queueGeneration
    override val queueCount: Int get() = state.queue.size
    override val currentIndex: Int get() = state.index
    override val isRunning: Boolean get() = state.isRunning
    override fun item(at: Int): QueueItem = state.queue[at]

    override val isPlaying: Boolean
        get() = state.isRunning && !seq.isHeldForResume && seq.engine?.let { it.hasLoadedItem && it.isPlaying } == true

    override val positionMs: Long
        get() = if (seq.isHeldForResume) seq.resumeOffsetMs ?: 0L else seq.engine?.takeIf { it.hasLoadedItem }?.positionMs ?: 0L

    override val repeatMode: RepeatMode get() = state.repeatMode
    override val shuffleEnabled: Boolean get() = state.shuffleEnabled
    override val isTransitioning: Boolean get() = seq.isStartPending
    override val hasCoarsePosition: Boolean get() = coarsePosition()
    override val isSystemPaused: Boolean get() = systemPaused()
    override val transitionSeq: Long get() = seq.transitionSeq
    override val lastTransitionCause: TransitionCause get() = lastCause
    override val lastUserTransitionSeq: Long get() = seq.lastUserTransitionSeq
    override val userPlayIntentSeq: Long get() = seq.userPlayIntentSeq
    override val lastUserPlayIntent: Boolean get() = seq.lastUserPlayIntent

    override fun play(items: List<QueueItem>, startIndex: Int, atMs: Long, startPaused: Boolean) {
        if (items.isEmpty()) return
        val i = startIndex.coerceIn(0, items.size - 1)
        seq.applyingExternal {
            seq.play(items, startIndex = i, atMs = atMs.takeIf { it > CUE_MIN_MS }, startPaused = startPaused)
        }
    }

    override fun jumpToUpcoming(uid: String, atMs: Long) {
        seq.applyingExternal { seq.jumpToUpcoming(uid, atMs.takeIf { it > CUE_MIN_MS }) }
    }

    override fun replaceUpcoming(count: Int, items: List<QueueItem>) {
        seq.applyingExternal { seq.replaceUpcomingSegment(count, items) }
    }

    override fun insertUpcoming(items: List<QueueItem>, beforeUid: String?) {
        if (items.isEmpty()) return
        seq.insertUpcoming(items, beforeUid) // already an external apply
    }

    override fun appendToQueue(items: List<QueueItem>) {
        if (items.isEmpty()) return
        seq.applyingExternal { seq.appendToQueue(items) }
    }

    /** ▶/⏸ through the sequencer's own routing (held deck -> resume at its point), only when the state differs. */
    override fun setPlaying(on: Boolean) {
        if (!state.isRunning || on == isPlaying) return
        seq.applyingExternal {
            when {
                on && seq.isHeldForResume -> seq.resumeFromHold()
                on && (seq.isPausedByCascade || seq.currentNeverSounded) -> seq.startCurrent()
                on -> scope.launch(start = CoroutineStart.UNDISPATCHED) { seq.resume() }
                seq.isHeldForResume -> Unit // already silent
                else -> scope.launch(start = CoroutineStart.UNDISPATCHED) { seq.pause() }
            }
        }
    }

    override fun seek(toMs: Long) {
        val ms = maxOf(0L, toMs)
        // A held (paused-loaded) deck has no audio to seek: move its resume point.
        if (seq.isHeldForResume) { seq.setHeldResumePosition(ms); return }
        seq.applyingExternal { scope.launch(start = CoroutineStart.UNDISPATCHED) { seq.seekTo(ms) } }
    }

    override fun setRepeatMode(mode: RepeatMode) { seq.applyingExternal { seq.setRepeatMode(mode) } }
    override fun setShuffle(on: Boolean) { seq.applyingExternal { seq.setShuffle(on) } }

    override fun silenceForController() {
        seq.silenceForController()
        extraSilencers().forEach { runCatching(it) }
    }

    companion object {
        /** Cues at or below this are "from the top" (iOS `atMs > 1_000`). */
        const val CUE_MIN_MS = 1_000L
    }
}
