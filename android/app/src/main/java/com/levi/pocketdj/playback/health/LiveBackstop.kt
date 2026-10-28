package com.levi.pocketdj.playback.health

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * LIVE BACKSTOP (iOS `armLiveBackstop`). A live capture (stream-through rip) has no length boundary and
 * ends only on the server's ENDLIST - a wedged capture left the set silent on `waitingForLive`. Once it has
 * PLAYED its known length plus [graceMs] (time the listener had it paused does not count), advance.
 */
class LiveBackstop(
    private val scope: CoroutineScope,
    private val graceMs: Long = GRACE_MS,
) {
    private var job: Job? = null

    val isArmed: Boolean get() = job?.isActive == true

    /** No known length -> nothing to bound by, so no backstop (same as iOS). */
    fun arm(
        lengthMs: Long?,
        isPausedByListener: () -> Boolean,
        stillWaiting: () -> Boolean,
        onExpire: () -> Unit,
    ) {
        job?.cancel()
        job = null
        if (lengthMs == null || lengthMs <= 0) return
        val budget = lengthMs + graceMs
        val step = minOf(1_000L, maxOf(50L, graceMs / 2))
        job = scope.launch {
            var played = 0L
            while (played < budget) {
                delay(step)
                if (!stillWaiting()) return@launch
                if (!isPausedByListener()) played += step
            }
            if (stillWaiting()) onExpire()
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
    }

    companion object {
        /** A live capture still playing this long past its known length is abandoned. */
        const val GRACE_MS = 45_000L
    }
}
