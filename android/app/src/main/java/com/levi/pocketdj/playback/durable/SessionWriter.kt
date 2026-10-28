package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.SequencerState

/**
 * Turns sequencer state changes into session-store writes (iOS `persistSession` call sites).
 *
 * Rules (acceptance):
 *  - a fresh play (new sessionId) and every index move persist position 0, so a kill right after an
 *    advance never resumes the NEW track at the OLD track's offset;
 *  - every live edit (queue rows, repeat, shuffle) persists immediately at the live position;
 *  - a HELD (restored, not yet resumed) deck is never written - a restore is not a write; the first
 *    real play adopts the session, persisting the resume offset;
 *  - the run ending (running -> idle) clears the file; launch with no run never touches it;
 *  - [tick] feeds the live position / play state (the store throttles + persists transitions).
 *
 * Pure: no threads, no Android. [SessionWriterShell] in PlaybackGraph feeds it from the state flow.
 */
class SessionWriter(
    private val store: PlaybackSessionStore,
    /** Song-relative position of the current row (ms). */
    private val position: () -> Long,
    private val isPlaying: () -> Boolean,
    /** The held deck's pending resume offset (read while held, applied at the first real play). */
    private val heldOffset: () -> Long? = { null },
    /** False while the engine does not hold the current row yet (position would be stale). */
    private val positionValid: () -> Boolean = { true },
    /** The offset a launch-time resume consumed before this writer observed the deck (it never saw it held). */
    private val consumedResumeOffset: () -> Long? = { null },
    private val stemLock: () -> SessionStemLock? = { null },
) {
    private var last: SequencerState? = null
    private var heldOffsetMs: Long? = null

    /** Feed every published sequencer state, in order. */
    fun onState(st: SequencerState) {
        val prev = last
        last = st
        if (!st.isRunning) {
            // Only a run that existed on this launch clears the file: a cold start with no run must not
            // delete the snapshot the restore is about to read.
            if (prev?.isRunning == true) store.clear()
            heldOffsetMs = null
            return
        }
        if (st.isHeldForResume) {
            heldOffsetMs = heldOffset()
            return
        }
        val fresh = prev == null || !prev.isRunning || prev.sessionId != st.sessionId
        val resumed = prev?.isRunning == true && prev.isHeldForResume && !fresh
        val moved = prev != null && prev.index != st.index
        when {
            resumed -> {
                // skip / jump while held (exitHoldIfNeeded) moved the cursor: the offset is dropped.
                val at = if (moved) 0L else heldOffsetMs ?: 0L
                heldOffsetMs = null
                save(st, at)
            }
            // A latched remote play consumed the launch restore before we observed it held: keep its offset.
            (prev == null || !prev.isRunning) && !moved -> {
                heldOffsetMs = null
                save(st, consumedResumeOffset() ?: 0L)
            }
            fresh || moved -> {
                heldOffsetMs = null
                save(st, 0)
            }
            prev != null && structurallyChanged(prev, st) -> save(st, livePosition(st))
        }
    }

    /** ~1 Hz while a run exists: position / play-state refresh (the store throttles). */
    fun tick() {
        val st = last ?: return
        if (!st.isRunning || st.isHeldForResume) return
        if (!positionValid()) return
        store.updatePosition(position(), isPlaying())
    }

    private fun livePosition(st: SequencerState): Long =
        if (positionValid()) position() else store.currentSnapshot?.positionMs ?: 0L

    private fun structurallyChanged(a: SequencerState, b: SequencerState): Boolean =
        a.queue != b.queue || a.repeatMode != b.repeatMode || a.shuffleEnabled != b.shuffleEnabled ||
            a.sourceSetlistId != b.sourceSetlistId

    private fun save(st: SequencerState, positionMs: Long) {
        val ctx = st.capturedContext ?: PlayContext(PlayContext.SOURCE_SETLIST)
        store.save(
            SessionSnapshot(
                sessionId = st.sessionId ?: return,
                source = SessionSourceRef(
                    kind = ctx.source,
                    id = st.sourceSetlistId,
                    name = ctx.contextName,
                    originKind = st.capturedOrigin?.first,
                    originId = st.capturedOrigin?.second,
                ),
                queue = st.queue.map(SessionSnapshot::row),
                index = st.index,
                positionMs = positionMs.coerceAtLeast(0),
                isPlaying = isPlaying(),
                repeatMode = st.repeatMode.token,
                shuffleEnabled = st.shuffleEnabled,
                stemLock = stemLock()?.takeIf { it.enabled },
            ),
        )
    }
}
