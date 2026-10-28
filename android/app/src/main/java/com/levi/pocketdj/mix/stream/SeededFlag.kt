package com.levi.pocketdj.mix.stream

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * A synchronous view of a suspend boolean (the rip-server-configured check). Seeded with a real
 * [initial] answer so the first read after a cold start is correct, then refreshed in the
 * background at most once per [minIntervalMs] (never a coroutine per read).
 */
class SeededFlag(
    private val read: suspend () -> Boolean,
    private val scope: CoroutineScope,
    initial: Boolean,
    private val minIntervalMs: Long = 5_000,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val value = AtomicBoolean(initial)
    private val last = AtomicLong(clock())

    fun get(): Boolean {
        val now = clock()
        val prev = last.get()
        if (now - prev >= minIntervalMs && last.compareAndSet(prev, now)) {
            scope.launch { value.set(runCatching { read() }.getOrDefault(value.get())) }
        }
        return value.get()
    }
}
