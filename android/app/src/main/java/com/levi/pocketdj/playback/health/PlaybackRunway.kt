package com.levi.pocketdj.playback.health

import com.levi.pocketdj.diag.NPLog
import java.util.concurrent.atomic.AtomicInteger

/** Holds the CPU awake for one start window. Android: a partial `WakeLock` (see [PowerRunwayLock]). */
fun interface RunwayLock {
    /** Acquire a hold for [name], self-releasing after [timeoutMs]. Returns the release action. */
    fun acquire(name: String, timeoutMs: Long): () -> Unit
}

/**
 * Background-execution RUNWAY for the silent gap between songs (iOS `PlaybackRunway`). Between songs the
 * previous item stopped and the next one's resolve (presign / `POST /rip`) is still on the network; a
 * locked phone must not doze mid-resolve. The Android analogue of the UIKit background task is a partial
 * wake lock held from `startPlayCurrent` until first audio (or the cap). Ended explicitly (idempotent).
 *
 * Telemetry grammar (iOS): `[runway] begin name=…` and `[runway] end name=… held=1.2s reason=…`.
 */
class PlaybackRunway(
    val name: String,
    lock: RunwayLock?,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = { NPLog.lane(NPLog.RUNWAY, it) },
    capMs: Long = CAP_MS,
) {
    private val began = nowMs()
    private var ended = false
    private val release: (() -> Unit)? = try {
        lock?.acquire(name, capMs + SAFETY_MS)
    } catch (_: Exception) {
        null // a denied wake lock must never break a start
    }

    init {
        active.incrementAndGet()
        log("begin name=$name")
    }

    val isEnded: Boolean get() = ended

    /** End the runway (idempotent). [reason] rides the `[runway] end` row. */
    fun end(reason: String = "done") {
        if (ended) return
        ended = true
        active.decrementAndGet()
        val held = (nowMs() - began).coerceAtLeast(0) / 1000.0
        log("end name=$name held=${String.format(java.util.Locale.US, "%.1f", held)}s reason=$reason")
        runCatching { release?.invoke() }
    }

    companion object {
        /** Cap for one track start. */
        const val CAP_MS = 25_000L

        /** The wake lock outlives the cap slightly; the explicit end is the real release. */
        private const val SAFETY_MS = 5_000L

        private val active = AtomicInteger(0)

        /** Runways currently held (test seam + diagnostics). */
        val activeCount: Int get() = active.get()
    }
}

/** The production lock: a non-reference-counted partial wake lock per runway. */
class PowerRunwayLock(private val context: android.content.Context) : RunwayLock {
    override fun acquire(name: String, timeoutMs: Long): () -> Unit {
        val pm = context.getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
        val wl = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "pocketdj:$name")
        wl.setReferenceCounted(false)
        wl.acquire(timeoutMs)
        return { if (wl.isHeld) wl.release() }
    }
}
