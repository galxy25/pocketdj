package com.levi.pocketdj.audio.dsp

import kotlin.math.exp
import kotlin.math.PI

/**
 * Feedback delay with a low-pass in the feedback path, standing in for `AVAudioUnitDelay`
 * (the "flanger" family: flange/chorus/echo are all just short or long delays here, as on iOS).
 * Units mirror the AU: [delayTime] seconds, [feedback] -100..100 %, [wetDryMix] 0..100 %,
 * [lowPassCutoff] Hz.
 *
 * Callers must derive delayTime from the BASE strength only (`FxParams.modDelayTime(v, base)`),
 * never the modulated value: a delay-length jump moves the read pointer mid-waveform and clicks.
 * As a belt-and-braces measure the read position glides (about 20 ms) toward the target.
 */
class ModDelay(private val sampleRate: Float = 44_100f, maxDelaySec: Float = 1f) : DspNode {
    override var bypass: Boolean = false

    private val cap = (sampleRate * maxDelaySec).toInt() + 4
    private val lineL = FloatArray(cap)
    private val lineR = FloatArray(cap)
    private var w = 0

    var delayTime = 0.004; private set
    var feedback = 0f; private set
    var wetDryMix = 0f; private set
    var lowPassCutoff = 15_000f; private set

    private var curDelay = delayTime * sampleRate // samples (glides)
    private var lpA = 0f
    private var lpL = 0f
    private var lpR = 0f
    private val glide = (1.0 - exp(-1.0 / (0.02 * sampleRate))).toFloat()

    init { setLowPassCutoff(lowPassCutoff) }

    fun setDelayTime(sec: Double) { delayTime = sec.coerceIn(0.0005, cap / sampleRate - 0.001) }
    fun setFeedback(pct: Float) { feedback = pct.coerceIn(-100f, 100f) }
    fun setWetDryMix(pct: Float) { wetDryMix = pct.coerceIn(0f, 100f) }
    fun setLowPassCutoff(hz: Float) {
        lowPassCutoff = hz
        lpA = exp(-2.0 * PI * hz.coerceIn(20f, sampleRate * 0.49f) / sampleRate).toFloat()
    }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        val wet = wetDryMix / 100f
        val dry = 1f - wet
        val fb = feedback / 100f
        val target = (delayTime * sampleRate).toFloat()
        var cur = curDelay.toFloat()
        var i = 0
        while (i < frames) {
            cur += (target - cur) * glide
            val rp = w - cur
            var ri = rp.toInt()
            var fr = rp - ri
            if (rp < 0f) { ri -= 1; fr = rp - ri }
            var i0 = ri % cap; if (i0 < 0) i0 += cap
            var i1 = i0 + 1; if (i1 == cap) i1 = 0
            val dl = lineL[i0] + (lineL[i1] - lineL[i0]) * fr
            val dr = lineR[i0] + (lineR[i1] - lineR[i0]) * fr
            lpL = dl * (1f - lpA) + lpL * lpA
            lpR = dr * (1f - lpA) + lpR * lpA
            val inL = buf[2 * i]; val inR = buf[2 * i + 1]
            lineL[w] = inL + lpL * fb
            lineR[w] = inR + lpR * fb
            w++; if (w == cap) w = 0
            buf[2 * i] = inL * dry + lpL * wet
            buf[2 * i + 1] = inR * dry + lpR * wet
            i++
        }
        curDelay = cur.toDouble()
    }

    /** Jump the read head straight to [delayTime] (no glide), e.g. when the node leaves bypass. */
    fun snap() { curDelay = delayTime * sampleRate }

    override fun reset() {
        lineL.fill(0f); lineR.fill(0f); w = 0; lpL = 0f; lpR = 0f
        curDelay = delayTime * sampleRate
    }
}
