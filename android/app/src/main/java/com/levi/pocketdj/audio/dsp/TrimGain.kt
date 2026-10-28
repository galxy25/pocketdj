package com.levi.pocketdj.audio.dsp

import kotlin.math.abs
import kotlin.math.pow

/**
 * Trim / volume-boost gain in dB (iOS: `AVAudioUnitEQ.globalGain = 20*log10(max(volume,1))`).
 * Gain changes glide per-sample (about 5 ms) so a fader move never zippers.
 */
class TrimGain(private val sampleRate: Float = 44_100f) : DspNode {
    override var bypass: Boolean = false

    var gainDb: Float = 0f; private set
    private var target = 1f
    private var current = 1f
    private val coef = (1.0 - Math.exp(-1.0 / (0.005 * sampleRate))).toFloat()

    fun setGainDb(db: Float) {
        gainDb = db
        target = 10.0.pow(db / 20.0).toFloat()
    }

    /** Jump (no glide), e.g. when a deck loads. */
    fun snap() { current = target }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var c = current
        val t = target
        if (c == t) {
            if (t == 1f) return
            val n = frames * CHANNELS
            for (i in 0 until n) buf[i] *= t
            return
        }
        var i = 0
        while (i < frames) {
            c += (t - c) * coef
            if (abs(t - c) < 1e-6f) c = t
            buf[2 * i] *= c
            buf[2 * i + 1] *= c
            i++
        }
        current = c
    }

    override fun reset() { current = target }
}
