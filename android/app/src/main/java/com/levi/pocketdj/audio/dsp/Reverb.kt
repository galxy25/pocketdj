package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.mix.model.FxParams

/**
 * Freeverb-style reverb (8 parallel damped combs + 4 series allpasses per channel, 23-sample
 * stereo spread) replacing `AVAudioUnitReverb`. [loadPreset] is the analogue of
 * `loadFactoryPreset`: it re-tunes the tank AND clears its tail, so call it ONLY on an actual
 * variant change (never per strength/glide tick) - [presetLoads] counts those. [wetDryMix] 0..100
 * mirrors `AVAudioUnitReverb.wetDryMix` and is the only per-tick parameter.
 */
class Reverb(private val sampleRate: Float = 44_100f) : DspNode {
    override var bypass: Boolean = false

    private class Tank(sizes: IntArray) {
        val bufs = Array(sizes.size) { FloatArray(sizes[it]) }
        val pos = IntArray(sizes.size)
        val store = FloatArray(sizes.size)
        fun clear() { for (b in bufs) b.fill(0f); pos.fill(0); store.fill(0f) }
    }

    private val scale = sampleRate / 44_100f
    private val combL = Tank(COMB.map { (it * scale).toInt().coerceAtLeast(8) }.toIntArray())
    private val combR = Tank(COMB.map { ((it + SPREAD) * scale).toInt().coerceAtLeast(8) }.toIntArray())
    private val apL = Tank(ALLPASS.map { (it * scale).toInt().coerceAtLeast(8) }.toIntArray())
    private val apR = Tank(ALLPASS.map { ((it + SPREAD) * scale).toInt().coerceAtLeast(8) }.toIntArray())

    var preset: FxParams.ReverbPreset? = null; private set
    var presetLoads: Int = 0; private set
    var wetDryMix: Float = 0f; private set

    private var feedback = 0.84f
    private var damp = 0.2f
    private var preDelayNone = true

    fun setWetDryMix(pct: Float) { wetDryMix = pct.coerceIn(0f, 100f) }

    fun loadPreset(p: FxParams.ReverbPreset) {
        preset = p
        presetLoads++
        when (p) {
            FxParams.ReverbPreset.MEDIUM_ROOM -> { feedback = 0.78f; damp = 0.50f }
            FxParams.ReverbPreset.PLATE -> { feedback = 0.86f; damp = 0.15f }
            FxParams.ReverbPreset.MEDIUM_HALL -> { feedback = 0.90f; damp = 0.35f }
            FxParams.ReverbPreset.CATHEDRAL -> { feedback = 0.97f; damp = 0.25f }
        }
        reset()
    }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        val wet = wetDryMix / 100f
        val dry = 1f - wet
        val fb = feedback
        val d1 = damp
        val d2 = 1f - damp
        var i = 0
        while (i < frames) {
            val inL = buf[2 * i]; val inR = buf[2 * i + 1]
            val x = (inL + inR) * GAIN
            var accL = 0f; var accR = 0f
            for (c in 0 until COMB.size) {
                val bl = combL.bufs[c]; val pl = combL.pos[c]
                val ol = bl[pl]
                combL.store[c] = ol * d2 + combL.store[c] * d1
                bl[pl] = x + combL.store[c] * fb
                combL.pos[c] = if (pl + 1 == bl.size) 0 else pl + 1
                accL += ol

                val br = combR.bufs[c]; val pr = combR.pos[c]
                val or = br[pr]
                combR.store[c] = or * d2 + combR.store[c] * d1
                br[pr] = x + combR.store[c] * fb
                combR.pos[c] = if (pr + 1 == br.size) 0 else pr + 1
                accR += or
            }
            for (a in 0 until ALLPASS.size) {
                val bl = apL.bufs[a]; val pl = apL.pos[a]
                val bufOut = bl[pl]
                val yl = -accL + bufOut
                bl[pl] = accL + bufOut * 0.5f
                apL.pos[a] = if (pl + 1 == bl.size) 0 else pl + 1
                accL = yl

                val br = apR.bufs[a]; val pr = apR.pos[a]
                val bo = br[pr]
                val yr = -accR + bo
                br[pr] = accR + bo * 0.5f
                apR.pos[a] = if (pr + 1 == br.size) 0 else pr + 1
                accR = yr
            }
            buf[2 * i] = inL * dry + accL * wet * WET_SCALE
            buf[2 * i + 1] = inR * dry + accR * wet * WET_SCALE
            i++
        }
    }

    override fun reset() { combL.clear(); combR.clear(); apL.clear(); apR.clear() }

    private companion object {
        val COMB = intArrayOf(1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)
        val ALLPASS = intArrayOf(556, 441, 341, 225)
        const val SPREAD = 23
        const val GAIN = 0.015f
        const val WET_SCALE = 3f
    }
}
