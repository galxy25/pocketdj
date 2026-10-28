package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.mix.model.FxParams
import kotlin.math.sqrt

/**
 * Pre-FX envelope tap driving envelope-sourced FX modulation. Ballistics are TIME-CONSTANT
 * based (8 ms attack / 180 ms release via `FxParams.ballisticsCoef`) so the speed is
 * independent of the host's block size: input is cut into fixed [CHUNK]-frame RMS slices
 * (carried across blocks) and one ballistics step is taken per slice. The drive is
 * `FxParams.envelopeCurve(rms)`: -40..0 dBFS -> 0..1. Read-only on the buffer.
 */
class EnvelopeFollower(private val sampleRate: Float = 44_100f) : DspNode {
    override var bypass: Boolean = false

    /** 0..1 modulation drive. */
    @Volatile var value: Float = 0f; private set
    /** Nanosecond stamp of the last write (0 = never); stale readers treat it as silence. */
    @Volatile var updatedAtNanos: Long = 0L; private set

    private var sumSq = 0.0
    private var count = 0
    private val dt = CHUNK / sampleRate.toDouble()
    private val atk = FxParams.ballisticsCoef(dt, ATTACK_SEC)
    private val rel = FxParams.ballisticsCoef(dt, RELEASE_SEC)
    private var v = 0f

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var i = 0
        while (i < frames) {
            val m = (buf[2 * i] + buf[2 * i + 1]) * 0.5f
            sumSq += (m * m).toDouble()
            if (++count == CHUNK) {
                val target = FxParams.envelopeCurve(sqrt(sumSq / CHUNK).toFloat()).toFloat()
                v += (target - v) * (if (target > v) atk else rel)
                sumSq = 0.0; count = 0
            }
            i++
        }
        value = v
        updatedAtNanos = System.nanoTime()
    }

    override fun reset() { sumSq = 0.0; count = 0; v = 0f; value = 0f; updatedAtNanos = 0L }

    companion object {
        const val CHUNK = 32
        const val ATTACK_SEC = 0.008
        const val RELEASE_SEC = 0.180
    }
}
