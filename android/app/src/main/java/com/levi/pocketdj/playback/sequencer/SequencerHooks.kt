package com.levi.pocketdj.playback.sequencer

import java.util.concurrent.CopyOnWriteArrayList

/** Which engine path produced a row start. */
enum class StartPath { EXO, DSP, AM, GROWING, ALBUM_GLIDE, DJ }

/** A row started (loaded, claimed by an interceptor, rolled in from the preload slot, or advanced without a load). */
data class TrackStart(
    val item: QueueItem,
    val index: Int,
    /** The sequencer play generation that owns this start. */
    val gen: Long,
    val path: StartPath,
    /** A genuinely new track start: not a repeat pass / in-place replay and not a mid-song resume. */
    val fresh: Boolean,
)

/** The current row changed. [fromUid] is null when nothing was current (a fresh run); [seq] is monotonic. */
data class Transition(val fromUid: String?, val toUid: String?, val cause: TransitionCause, val seq: Long)

/** Listener-intent transports (what the person asked for), as opposed to automatic transitions. */
enum class UserTransport { PLAY, PAUSE, SKIP, PREV, SEEK, JUMP, EDIT }

enum class SessionEndReason { STOPPED, REPLACED, FINISHED }

/** The run's source (same triple the durable snapshot stores). */
data class SourceRef(val kind: String, val id: String?, val name: String?)

/**
 * Observer of the sequencer. Every method has an empty default, so a feature overrides only what it needs.
 * Called on the sequencer's dispatcher (Main in production), in registration order; a throwing listener is
 * logged and skipped (see [SequencerHooks]).
 */
interface SequencerListener {
    fun onSessionStarted(sessionId: String, source: SourceRef) {}
    fun onSessionEnded(reason: SessionEndReason) {}
    fun onTrackStarted(start: TrackStart) {}
    fun onTransition(t: Transition) {}
    fun onUserTransport(kind: UserTransport) {}
    fun onQueueChanged(generation: Long) {}
    fun onFirstAudio(item: QueueItem, source: String) {}
    fun onHeld() {}
    fun onResumedFromHold() {}
}

/**
 * The ordered listener list + dispatcher.
 *
 * Guarantees:
 *  - listeners run in registration order;
 *  - an exception from one listener is caught, logged and does not reach the sequencer or the other listeners;
 *  - events are delivered IN EMISSION ORDER even when a listener calls back into the sequencer: an event raised
 *    from inside a listener is queued and delivered after the running event finishes (never interleaved).
 *
 * Thread contract: [emit] is called on the sequencer's single dispatcher; [add]/[remove] are safe from anywhere.
 */
class SequencerHooks(private val log: (String) -> Unit = {}) {
    private val listeners = CopyOnWriteArrayList<SequencerListener>()
    private val pending = ArrayDeque<(SequencerListener) -> Unit>()
    private var draining = false

    fun add(listener: SequencerListener) { listeners.addIfAbsent(listener) }
    fun remove(listener: SequencerListener) { listeners.remove(listener) }
    val count: Int get() = listeners.size

    fun emit(event: (SequencerListener) -> Unit) {
        if (listeners.isEmpty()) return
        pending.addLast(event)
        if (draining) return
        draining = true
        try {
            while (pending.isNotEmpty()) {
                val e = pending.removeFirst()
                for (l in listeners) {
                    try {
                        e(l)
                    } catch (t: Exception) {
                        log("[session] listener ${l.javaClass.simpleName} threw ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
            }
        } finally {
            draining = false
        }
    }
}

// ---- interceptors -------------------------------------------------------------------------------------------

/** What a [StartInterceptor] is asked to start. Mirrors the arguments of the sequencer's own start. */
data class StartAttempt(
    val item: QueueItem,
    val index: Int,
    val count: Int,
    /** The generation this start owns; pass it back to [SetlistSequencer.completeClaimedStart]. */
    val gen: Long,
    val fresh: Boolean,
    val resumeAtMs: Long?,
    val inPlace: Boolean,
    val reResolve: Boolean,
)

/**
 * May claim a row start BEFORE the default resolve/load in the sequencer. Asked in descending [priority] order
 * (ties: registration order); the first to return true owns the start. Suggested priorities: album glide
 * continuation 100, DJ incoming already in the DSP 90, growing-file start 50.
 *
 * A claimer must make the same bookkeeping happen as a normal start by calling
 * [SetlistSequencer.completeClaimedStart] with [StartAttempt.gen] once its audio is installed. It must be
 * cooperative with cancellation: a skip supersedes the attempt and cancels the calling coroutine. An exception
 * (other than cancellation) is logged and counts as "did not claim".
 */
interface StartInterceptor {
    val priority: Int
    suspend fun tryClaim(attempt: StartAttempt): Boolean
}

/** A natural end of the CURRENT row, offered to [AdvanceInterceptor]s after the repeat logic ruled out a replay. */
data class AdvanceAttempt(val from: QueueItem, val index: Int, val next: QueueItem?)

/**
 * May take the advance on a natural end (album glide retargets within the file; the DJ conductor advances at
 * fade start). Returning true means "I own the advance": the sequencer does nothing, and the claimer calls
 * [SetlistSequencer.advanceWithoutLoad] when it is time. Descending [priority]; first to claim wins.
 * Exceptions are logged and count as "did not claim".
 * Offered only on a natural end that reaches handleEnded: a gapless preload roll (handlePreloadedTransition) is
 * committed by the engine and is NOT offered, so an interceptor that must own the advance has to keep the next
 * row from being preloaded.
 */
interface AdvanceInterceptor {
    val priority: Int
    fun onNaturalEnd(attempt: AdvanceAttempt): Boolean
}
