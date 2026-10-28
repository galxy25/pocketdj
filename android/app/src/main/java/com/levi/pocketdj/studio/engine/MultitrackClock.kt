package com.levi.pocketdj.studio.engine

/**
 * Non-observable playhead clock (port of iOS `MultitrackClock`): a Compose frame loop samples
 * [currentSeconds] each frame; because it is NOT snapshot state, reading it never recomposes the
 * arranger body. Seconds since the shared start (0 during pre-roll / before [start]).
 *
 * [nowNanos] is injectable so the JVM tests drive time deterministically; [latencyMs] is subtracted so
 * the cursor tracks what is audible, not what was last written to the sink.
 */
class MultitrackClock(private val nowNanos: () -> Long = System::nanoTime) {
    @Volatile private var startNanos = 0L
    @Volatile private var running = false
    @Volatile var latencyMs: Int = 0

    val isRunning: Boolean get() = running

    fun start(atNanos: Long = nowNanos()) { startNanos = atNanos; running = true }

    fun stop() { running = false }

    val currentSeconds: Double
        get() {
            if (!running || startNanos <= 0L) return 0.0
            val elapsed = nowNanos() - startNanos - latencyMs * 1_000_000L
            return if (elapsed <= 0L) 0.0 else elapsed / 1e9
        }

    /**
     * The timeline position (ms) for the cursor: [startOffsetMs] + clock, wrapped into the loop
     * region while looping, clamped to [lengthMs].
     */
    fun timelineMs(startOffsetMs: Int, lengthMs: Int, loopStartMs: Int = 0, loopEndMs: Int = 0, looping: Boolean = false): Int =
        positionMs(startOffsetMs, currentSeconds, lengthMs, loopStartMs, loopEndMs, looping)

    companion object {
        /** Pure cursor math (testable): loop playback starts at loopStart, wraps modulo the region. */
        fun positionMs(
            startOffsetMs: Int, seconds: Double, lengthMs: Int,
            loopStartMs: Int = 0, loopEndMs: Int = 0, looping: Boolean = false,
        ): Int {
            val elapsedMs = (seconds * 1000.0).toLong()
            if (looping && loopEndMs > loopStartMs) {
                val region = (loopEndMs - loopStartMs).toLong()
                return (loopStartMs + elapsedMs % region).toInt()
            }
            return (startOffsetMs + elapsedMs).coerceIn(0L, maxOf(0, lengthMs).toLong()).toInt()
        }
    }
}
