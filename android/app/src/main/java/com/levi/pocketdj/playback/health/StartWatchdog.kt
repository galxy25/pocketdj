package com.levi.pocketdj.playback.health

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The START WATCHDOG (iOS `armStartStall`). Armed after a load: at [rekickAfterMs] with no audio (and
 * [stillOwed] true - not listener-paused, same generation) it reports a stall and re-kicks in place; at
 * [escalateAfterMs] it reports again and escalates (hop to a playable row, else advance through the cascade
 * breaker). Cancelled by first audio, a skip (new generation), a pause and stop.
 */
class StartWatchdog(
    private val scope: CoroutineScope,
    private val rekickAfterMs: Long = REKICK_MS,
    private val escalateAfterMs: Long = ESCALATE_MS,
) {
    private var job: Job? = null

    val isArmed: Boolean get() = job?.isActive == true

    fun arm(
        stillOwed: () -> Boolean,
        onRekick: (waitedSeconds: Int) -> Unit,
        onEscalate: (waitedSeconds: Int) -> Unit,
    ) {
        job?.cancel()
        val rekickAt = rekickAfterMs.coerceAtLeast(10)
        val escalateAt = maxOf(rekickAt, escalateAfterMs)
        job = scope.launch {
            delay(rekickAt)
            if (!stillOwed()) return@launch
            onRekick((rekickAt / 1000).toInt())
            delay((escalateAt - rekickAt).coerceAtLeast(10))
            if (!stillOwed()) return@launch
            onEscalate((escalateAt / 1000).toInt())
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
    }

    companion object {
        /** Re-kick a start still not playing after this long... */
        const val REKICK_MS = 8_000L

        /** ...and escalate here. */
        const val ESCALATE_MS = 20_000L
    }
}
