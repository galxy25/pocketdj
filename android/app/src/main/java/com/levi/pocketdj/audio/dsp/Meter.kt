package com.levi.pocketdj.audio.dsp

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Lock-free level holder the UI polls (VU meters). Written from the render thread, read from the
 * UI thread; individual `@Volatile` floats are enough because each is independently meaningful.
 */
class MixDeckLevels {
    @Volatile var peakL = 0f
    @Volatile var peakR = 0f
    @Volatile var rmsL = 0f
    @Volatile var rmsR = 0f
    /** Monotonic count of published windows (lets a poller detect a stalled tap). */
    @Volatile var updates = 0L

    val peak: Float get() = maxOf(peakL, peakR)
    val rms: Float get() = maxOf(rmsL, rmsR)
}

/**
 * Read-only level tap: peak and RMS per channel accumulated over [windowFrames] (default 4096,
 * the engine's VU cadence) regardless of the block size it is fed, then published to [levels].
 * Never modifies the buffer ([bypass] merely stops metering).
 */
class Meter(
    val levels: MixDeckLevels = MixDeckLevels(),
    private val windowFrames: Int = 4096,
) : DspNode {
    override var bypass: Boolean = false

    private var pL = 0f; private var pR = 0f
    private var sL = 0.0; private var sR = 0.0
    private var count = 0

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var i = 0
        while (i < frames) {
            val l = buf[2 * i]; val r = buf[2 * i + 1]
            val al = abs(l); val ar = abs(r)
            if (al > pL) pL = al
            if (ar > pR) pR = ar
            sL += (l * l).toDouble(); sR += (r * r).toDouble()
            count++
            if (count == windowFrames) publish()
            i++
        }
    }

    private fun publish() {
        levels.peakL = pL; levels.peakR = pR
        levels.rmsL = sqrt(sL / count).toFloat(); levels.rmsR = sqrt(sR / count).toFloat()
        levels.updates = levels.updates + 1
        pL = 0f; pR = 0f; sL = 0.0; sR = 0.0; count = 0
    }

    override fun reset() {
        pL = 0f; pR = 0f; sL = 0.0; sR = 0.0; count = 0
        levels.peakL = 0f; levels.peakR = 0f; levels.rmsL = 0f; levels.rmsR = 0f
    }
}
