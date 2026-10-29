package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.QueuePlan
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * "Play next" / "Add to queue" from anywhere (row context menus, Now Playing search). A running
 * set takes the rows next / at the end; a sounding Browse single is first folded into a one-row
 * run so the rows land BEHIND it; with nothing playing the rows start a run.
 */
object QueueAdd {
    enum class Path { INSERT_INTO_RUN, ADOPT_THEN_INSERT, START_RUN, NOTHING }

    /** Pure decision (JVM-tested). */
    fun path(itemsEmpty: Boolean, running: Boolean, sounding: Boolean): Path = when {
        itemsEmpty -> Path.NOTHING
        running -> Path.INSERT_INTO_RUN
        sounding -> Path.ADOPT_THEN_INSERT
        else -> Path.START_RUN
    }

    suspend fun add(graph: AppGraph, items: List<QueueItem>, next: Boolean) {
        val sequencer = graph.playbackGraph.sequencer
        val playing = graph.playbackController.nowPlaying.value
        val running = withContext(Dispatchers.Main) { sequencer.isRunning }
        when (path(items.isEmpty(), running, playing != null && playing.songId.isNotEmpty())) {
            Path.NOTHING -> Unit
            Path.INSERT_INTO_RUN -> withContext(Dispatchers.Main) {
                if (next) sequencer.insertNextInQueue(items) else sequencer.appendToQueue(items)
            }
            Path.ADOPT_THEN_INSERT -> {
                val p = playing!!
                val pos = runCatching { graph.playbackController.currentPositionMs() }.getOrDefault(0L)
                withContext(Dispatchers.Main) {
                    sequencer.adoptForeign(QueueItem(p.songId, p.title ?: p.songId, p.artist, p.durationMs), pos, null)
                    if (next) sequencer.insertNextInQueue(items) else sequencer.appendToQueue(items)
                }
            }
            Path.START_RUN -> graph.playbackController.playQueue(
                items.map { QueuePlan.QueueEntry(it.id, it.repeatCount, it.title, it.artist, it.lengthMs) },
            )
        }
    }
}
