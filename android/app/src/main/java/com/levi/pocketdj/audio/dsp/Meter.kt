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

    /** iOS-style smoothed levels (peak decay 0.85/window, RMS attack 0.5 / release 0.2), per tap. */
    @Volatile var prePeak = 0f
    @Volatile var preRms = 0f
    @Volatile var postPeak = 0f
    @Volatile var postRms = 0f
    /** System.nanoTime() of the last publish (0 = never); UIs decay to silence when stale. */
    @Volatile var updatedAtNanos = 0L

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
    /** Which smoothed pair this tap feeds: pre-fader (default) or post-fader. */
    private val post: Boolean = false,
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
        val p = maxOf(pL, pR)
        val r = maxOf(levels.rmsL, levels.rmsR)
        if (post) {
            levels.postPeak = maxOf(p, levels.postPeak * PEAK_DECAY)
            levels.postRms += (r - levels.postRms) * (if (r > levels.postRms) RMS_ATTACK else RMS_RELEASE)
        } else {
            levels.prePeak = maxOf(p, levels.prePeak * PEAK_DECAY)
            levels.preRms += (r - levels.preRms) * (if (r > levels.preRms) RMS_ATTACK else RMS_RELEASE)
        }
        levels.updatedAtNanos = System.nanoTime()
        levels.updates = levels.updates + 1
        pL = 0f; pR = 0f; sL = 0.0; sR = 0.0; count = 0
    }

    override fun reset() {
        pL = 0f; pR = 0f; sL = 0.0; sR = 0.0; count = 0
        levels.peakL = 0f; levels.peakR = 0f; levels.rmsL = 0f; levels.rmsR = 0f
        if (post) { levels.postPeak = 0f; levels.postRms = 0f } else { levels.prePeak = 0f; levels.preRms = 0f }
        levels.updatedAtNanos = 0L
    }

    private companion object {
        const val PEAK_DECAY = 0.85f
        const val RMS_ATTACK = 0.5f
        const val RMS_RELEASE = 0.2f
    }
}
