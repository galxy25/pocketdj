package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * "Rewind to here" (iOS `HistoryView.rewindSlice` / `performRewind`).
 *
 * Two cases, and the difference matters. If the tapped play is still in the RUNNING queue it is a
 * pure cursor move (the live set keeps its identity, edits and origin). If it's from a past run
 * there is no queue to move a cursor in, so the run is reconstructed from the log: the
 * contiguous slice of plays that shared this one's context, starting at it.
 */
internal object Rewind {

    /**
     * This event and every later play that shared its context, in order, stopping at the first
     * play from a DIFFERENT context (that's a different set). Unknown event -> empty. [events]
     * is oldest -> newest (store order).
     */
    fun slice(eventId: String, events: List<PlayEvent>): List<PlayEvent> {
        val start = events.indexOfFirst { it.id == eventId }
        if (start < 0) return emptyList()
        val context = events[start].contextId
        val out = ArrayList<PlayEvent>()
        for (i in start until events.size) {
            if (events[i].contextId != context) break
            out += events[i]
        }
        return out
    }

    /**
     * SAME RUN: the uid of the LAST played row (before the cursor) carrying [songId] — a song can
     * repeat in a set and the most recent occurrence is the one the user is looking at. Null when
     * not running, nothing is played yet, or the song isn't in the played region.
     */
    fun sameRunUid(queue: List<QueueItem>, index: Int, isRunning: Boolean, songId: String): String? {
        if (!isRunning || index <= 0) return null
        val played = queue.subList(0, minOf(index, queue.size))
        return played.lastOrNull { it.id == songId || it.resolveId == songId }?.uid
    }

    /** What a confirmed rewind resolved to. */
    sealed interface Plan {
        /** Cursor move inside the live queue. */
        data class CursorMove(val uid: String) : Plan

        /** Rebuild from the log: play [songIds] under the event's source token. */
        data class Replay(val songIds: List<String>, val name: String, val sourceToken: String) : Plan

        /** The event vanished (a merge removed it) or nothing to play. */
        data object Nothing : Plan
    }

    /**
     * Decide at EXECUTE time (not menu-build time: a cloud merge can change the log under an
     * open menu or confirmation dialog), from the freshest [events] + live queue.
     */
    fun plan(
        eventId: String,
        events: List<PlayEvent>,
        queue: List<QueueItem>,
        index: Int,
        isRunning: Boolean,
    ): Plan {
        val e = events.firstOrNull { it.id == eventId } ?: return Plan.Nothing
        sameRunUid(queue, index, isRunning, e.songId)?.let { return Plan.CursorMove(it) }
        val slice = slice(eventId, events)
        if (slice.isEmpty()) return Plan.Nothing
        return Plan.Replay(
            songIds = slice.map { it.songId },
            name = e.contextName ?: "History",
            sourceToken = e.source.token,
        )
    }
}

/** Result of executing a confirmed rewind, for the host's snackbar. */
internal sealed interface RewindResult {
    data object CursorMoved : RewindResult
    data class Replayed(val name: String) : RewindResult
    data object NothingToPlay : RewindResult
    data class Failed(val message: String) : RewindResult
}

/**
 * Execute a confirmed rewind. Re-reads the event log and the live queue AT EXECUTE TIME. The
 * cursor move runs on Main (the sequencer is Main-thread); the replay goes through
 * `ShellActions.playSongIds`, which already does the onboarding veto and awaits catalog
 * readiness so a rewind can't mint a corrupt Now Playing set against an empty catalog.
 */
internal suspend fun performRewind(
    graph: com.levi.pocketdj.di.AppGraph,
    eventId: String,
    events: List<PlayEvent>,
): RewindResult {
    val sequencer = graph.playbackGraph.sequencer
    val s = sequencer.state.value
    return when (val plan = Rewind.plan(eventId, events, s.queue, s.index, s.isRunning)) {
        Rewind.Plan.Nothing -> RewindResult.NothingToPlay
        is Rewind.Plan.CursorMove -> {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { sequencer.jumpToPlayed(plan.uid) }
            RewindResult.CursorMoved
        }
        is Rewind.Plan.Replay -> try {
            graph.shellGraph.shellActions.playSongIds(plan.songIds, plan.name, source = plan.sourceToken)
            RewindResult.Replayed(plan.name)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            RewindResult.Failed(e.message ?: "Couldn't rewind")
        }
    }
}
