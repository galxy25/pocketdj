package com.levi.pocketdj.mix.nowplaying

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * DISK GUARD (np-mix-mode §2.3), run before EVERY lane step (Stem Lock steps too): a step may start only
 * when at least [FREE_SPACE_FLOOR_BYTES] stay free AFTER it and the temporary footprint plus the step
 * stays under the buffer cap. Otherwise the injected [sweep] frees temporary assets first (bound to
 * `StorageManager.sweepTemporary(capOverrideBytes)` by P2-MM-5); if that is not enough the step is
 * skipped and the indicator reads "Storage full".
 */
class DiskGuard(
    /** Free bytes on the volume; null = unreadable (only the cap is checked). Called off-main. */
    private val freeBytes: () -> Long?,
    /** The temporary-asset footprint in bytes. Called off-main. */
    private val footprintBytes: () -> Long,
    private val capBytes: () -> Long,
    /** Free [need] bytes of temporary assets (soonest expiry first, never protected). Returns after sweeping. */
    private val sweep: suspend (capOverrideBytes: Long) -> Unit = {},
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    sealed interface Verdict {
        data object Ok : Verdict
        /** Free this many bytes of temporary assets first. */
        data class Evict(val bytes: Long) : Verdict
    }

    /**
     * May this step start? Checks, sweeps once on a refusal (the cap override is the footprint that would
     * satisfy BOTH constraints) and re-checks. False = skip the step ("Storage full").
     */
    suspend fun admit(stepBytes: Long = ESTIMATED_STEP_BYTES): Boolean {
        val first = withContext(io) { verdict(freeBytes(), footprintBytes(), capBytes(), stepBytes) }
        if (first is Verdict.Ok) return true
        val need = (first as Verdict.Evict).bytes
        val footprint = withContext(io) { footprintBytes() }
        sweep((footprint - need).coerceAtLeast(0L))
        val second = withContext(io) { verdict(freeBytes(), footprintBytes(), capBytes(), stepBytes) }
        return second is Verdict.Ok
    }

    companion object {
        /** The free-space floor the lane keeps (1 GB, decimal like the caps). */
        const val FREE_SPACE_FLOOR_BYTES = 1_000_000_000L
        /** A step's size estimate for the guard (a ~4-5 min mp3 or one stem part). */
        const val ESTIMATED_STEP_BYTES = 10_000_000L

        /**
         * PURE (iOS `diskVerdict`): may a step of [stepBytes] start with [freeBytes] free and the temporary
         * [footprint] against [capBytes]? Evict = the larger of the cap overshoot and the free-space shortfall.
         */
        fun verdict(freeBytes: Long?, footprint: Long, capBytes: Long, stepBytes: Long = ESTIMATED_STEP_BYTES): Verdict {
            var need = 0L
            if (footprint + stepBytes > capBytes) need = footprint + stepBytes - capBytes
            if (freeBytes != null && freeBytes - stepBytes < FREE_SPACE_FLOOR_BYTES) {
                need = maxOf(need, FREE_SPACE_FLOOR_BYTES + stepBytes - freeBytes)
            }
            return if (need > 0) Verdict.Evict(need) else Verdict.Ok
        }
    }
}
