package com.levi.pocketdj.playback.health

import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The RESOLVE-STALL HOP (iOS `hopToOnDeviceRow` + `armResolveStall`). A cloud resolve that has run
 * [STALL_MS] with no audio (a cellular dead zone, a rip still queued server-side) plays the next ON-DEVICE
 * row now (else the next row that starts instantly: a manifest hit) and DEFERS the stalled row right behind
 * it - reordered, never dropped. None within [LOOKAHEAD] -> keep waiting (the request timeouts still bound it).
 */
object ResolveStallHop {
    const val STALL_MS = 6_000L

    /** How far ahead a stalled resolve looks for a playable row. */
    const val LOOKAHEAD = 50

    enum class Kind(val label: String) { ON_DEVICE("on-device"), INSTANT("instant") }

    /** [queueIndex] is the row to pull forward to the cursor. */
    data class Choice(val queueIndex: Int, val kind: Kind)

    /** First on-device row in `index+1 until index+1+lookahead`, else the first instant row; null = none. */
    fun choose(
        queue: List<QueueItem>,
        index: Int,
        onDevice: (QueueItem) -> Boolean,
        instant: (QueueItem) -> Boolean,
        lookahead: Int = LOOKAHEAD,
    ): Choice? {
        if (index < 0 || index >= queue.size) return null
        val end = minOf(queue.size, index + 1 + lookahead)
        if (index + 1 >= end) return null
        val range = (index + 1) until end
        range.firstOrNull { onDevice(queue[it]) }?.let { return Choice(it, Kind.ON_DEVICE) }
        range.firstOrNull { instant(queue[it]) }?.let { return Choice(it, Kind.INSTANT) }
        return null
    }

    /**
     * Move the chosen row to [index]; the stalled row (formerly at [index]) ends up right behind it.
     * Returns the row now at [index].
     */
    fun apply(queue: MutableList<QueueItem>, index: Int, choice: Choice): QueueItem {
        val row = queue.removeAt(choice.queueIndex)
        queue.add(index, row)
        return row
    }
}

/** The 6 s timer around a start's resolve: [onStall] fires if [stillStalled] is still true then. */
class ResolveStallTimer(
    private val scope: CoroutineScope,
    private val stallMs: Long = ResolveStallHop.STALL_MS,
) {
    private var job: Job? = null

    val isArmed: Boolean get() = job?.isActive == true

    fun arm(stillStalled: () -> Boolean, onStall: (waitedSeconds: Int) -> Unit) {
        job?.cancel()
        val wait = stallMs.coerceAtLeast(50)
        job = scope.launch {
            delay(wait)
            if (stillStalled()) onStall((wait / 1000).toInt())
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
    }
}
