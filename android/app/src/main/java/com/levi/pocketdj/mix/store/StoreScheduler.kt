package com.levi.pocketdj.mix.store

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** A cancellable pending task. */
fun interface Cancellable { fun cancel() }

/**
 * Delayed-task seam for the Mix stores' trailing-edge debounces (iOS used `Task.sleep`).
 * Production runs on one daemon thread; tests inject a manual scheduler so debounce
 * behaviour is deterministic.
 */
interface StoreScheduler {
    fun schedule(delayMs: Long, task: Runnable): Cancellable

    companion object {
        val DEFAULT: StoreScheduler by lazy {
            val ex = Executors.newSingleThreadScheduledExecutor { r ->
                Thread(r, "pdj-mix-store-timer").apply { isDaemon = true }
            }
            object : StoreScheduler {
                override fun schedule(delayMs: Long, task: Runnable): Cancellable {
                    val f: ScheduledFuture<*> = ex.schedule(task, delayMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
                    return Cancellable { f.cancel(false) }
                }
            }
        }
    }
}
