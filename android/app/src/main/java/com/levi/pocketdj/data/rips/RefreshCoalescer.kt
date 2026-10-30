package com.levi.pocketdj.data.rips

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Coalesces concurrent refreshes (emulator OOM finding): every [RipJobTracker] job that lands calls the manifest
 * refresh, and a collection rip whose jobs turn ready together fired ~33 concurrent 6.7 MB fetch + decode passes on
 * a heap already holding the catalog -> OutOfMemoryError. A caller waits for any refresh in flight; if a refresh
 * STARTED after the caller arrived has completed meanwhile, its result is fresh enough and is reused (one more
 * pass at most), so N simultaneous callers cost at most two passes and nobody gets data older than its request.
 */
internal class RefreshCoalescer {
    private val mutex = Mutex()
    private val started = AtomicLong(0)

    suspend fun <T> run(current: () -> T, block: suspend () -> T): T {
        val arrival = started.get()
        return mutex.withLock {
            if (started.get() > arrival) return@withLock current()
            started.incrementAndGet()
            block()
        }
    }
}
