package com.levi.pocketdj.shell

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The ON_STOP flush funnel (replaces iOS scenePhase .background flushes). Debounced writers
 * register a [Flushable]; [flushAll] runs them in registration order, each isolated so a
 * throwing closure never stops the others, bounded overall by [timeoutMs].
 */
class FlushRegistry(
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val log: (String) -> Unit = { android.util.Log.i("PocketDJ", it) },
) {
    private class Entry(val name: String, val flushable: Flushable)

    private val entries = CopyOnWriteArrayList<Entry>()

    /** Register [flushable]; returns a handle that unregisters it. Re-using a name replaces it. */
    fun register(name: String, flushable: Flushable): () -> Unit {
        val entry = Entry(name, flushable)
        entries.removeAll { it.name == name }
        entries.add(entry)
        return { entries.remove(entry) }
    }

    val names: List<String> get() = entries.map { it.name }

    /**
     * Runs every flushable sequentially in registration order. @return the names that
     * completed without error. Stops starting new closures when the budget is spent.
     */
    suspend fun flushAll(extra: List<Flushable> = emptyList()): List<String> {
        val done = ArrayList<String>()
        val all = entries.map { it.name to it.flushable } +
            extra.mapIndexed { i, f -> "module#$i" to f }
        val t0 = System.nanoTime()
        val finished = withTimeoutOrNull(timeoutMs) {
            for ((name, f) in all) {
                try {
                    f.flush()
                    done += name
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    log("[flush] $name failed: $e")
                }
            }
            true
        }
        val ms = (System.nanoTime() - t0) / 1_000_000
        log("[flush] ${done.size}/${all.size} ok in ${ms}ms" + if (finished == null) " (TIMED OUT)" else "")
        return done
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 2_000L
    }
}
