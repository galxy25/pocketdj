package com.levi.pocketdj.audio.dsp

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sinh
import kotlin.math.sqrt

/**
 * Common shape of every in-place DSP node in the Mix graph. Audio is INTERLEAVED STEREO float
 * ([CHANNELS] = 2): `buf[2*i]` = L, `buf[2*i+1]` = R, `frames` frames starting at index 0.
 * Nodes process in place with no allocation after construction. A bypassed node must leave the
 * buffer bit-identical.
 */
interface DspNode {
    var bypass: Boolean
    fun process(buf: FloatArray, frames: Int)
    /** Clear all internal history (filter state, delay lines, tails). */
    fun reset()
}

const val CHANNELS = 2

/** RBJ-cookbook biquad, transposed direct form II, independent state per channel. */
class Biquad(private val sampleRate: Float = 44_100f) : DspNode {
    enum class Type { LOW_PASS, HIGH_PASS, BAND_PASS, LOW_SHELF, HIGH_SHELF, PEAK }

    override var bypass: Boolean = false

    var type: Type = Type.LOW_PASS; private set
    var frequency: Float = 1_000f; private set
    var gainDb: Float = 0f; private set
    var q: Float = 0.7071f; private set

    private var b0 = 1.0; private var b1 = 0.0; private var b2 = 0.0
    private var a1 = 0.0; private var a2 = 0.0
    private var z1L = 0.0; private var z2L = 0.0
    private var z1R = 0.0; private var z2R = 0.0

    init { update() }

    /** Configure everything in one go (one coefficient recompute). */
    fun set(type: Type, frequency: Float, q: Float = this.q, gainDb: Float = this.gainDb) {
        this.type = type
        this.frequency = frequency
        this.q = q
        this.gainDb = gainDb
        update()
    }

    fun setFrequency(hz: Float) { frequency = hz; update() }
    fun setGainDb(db: Float) { gainDb = db; update() }

    /** Bandwidth in octaves (AVAudioUnitEQ's measure) to the equivalent Q at the current frequency. */
    fun setBandwidthOctaves(bw: Float) { q = qFromBandwidth(bw.toDouble(), frequency.toDouble(), sampleRate.toDouble()).toFloat(); update() }

    private fun update() {
        val nyq = sampleRate * 0.5f
        val f = frequency.coerceIn(10f, nyq * 0.98f).toDouble()
        val w0 = 2 * PI * f / sampleRate
        val cw = cos(w0)
        val sw = sin(w0)
        val qq = q.toDouble().coerceAtLeast(0.05)
        val alpha = sw / (2 * qq)
        var nb0: Double; var nb1: Double; var nb2: Double
        val na0: Double; val na1: Double; val na2: Double
        when (type) {
            Type.LOW_PASS -> {
                nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = (1 - cw) / 2
                na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
            }
            Type.HIGH_PASS -> {
                nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2
                na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
            }
            Type.BAND_PASS -> { // constant 0 dB peak gain
                nb0 = alpha; nb1 = 0.0; nb2 = -alpha
                na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
            }
            Type.PEAK -> {
                val a = 10.0.pow(gainDb / 40.0)
                nb0 = 1 + alpha * a; nb1 = -2 * cw; nb2 = 1 - alpha * a
                na0 = 1 + alpha / a; na1 = -2 * cw; na2 = 1 - alpha / a
            }
            Type.LOW_SHELF, Type.HIGH_SHELF -> {
                val a = 10.0.pow(gainDb / 40.0)
                val tsa = 2 * sqrt(a) * alpha
                if (type == Type.LOW_SHELF) {
                    nb0 = a * ((a + 1) - (a - 1) * cw + tsa)
                    nb1 = 2 * a * ((a - 1) - (a + 1) * cw)
                    nb2 = a * ((a + 1) - (a - 1) * cw - tsa)
                    na0 = (a + 1) + (a - 1) * cw + tsa
                    na1 = -2 * ((a - 1) + (a + 1) * cw)
                    na2 = (a + 1) + (a - 1) * cw - tsa
                } else {
                    nb0 = a * ((a + 1) + (a - 1) * cw + tsa)
                    nb1 = -2 * a * ((a - 1) + (a + 1) * cw)
                    nb2 = a * ((a + 1) + (a - 1) * cw - tsa)
                    na0 = (a + 1) - (a - 1) * cw + tsa
                    na1 = 2 * ((a - 1) - (a + 1) * cw)
                    na2 = (a + 1) - (a - 1) * cw - tsa
                }
            }
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0
        a1 = na1 / na0; a2 = na2 / na0
    }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var l1 = z1L; var l2 = z2L; var r1 = z1R; var r2 = z2R
        var i = 0
        val n = frames * CHANNELS
        while (i < n) {
            val xl = buf[i].toDouble()
            val yl = b0 * xl + l1
            l1 = b1 * xl - a1 * yl + l2
            l2 = b2 * xl - a2 * yl
            buf[i] = yl.toFloat()
            val xr = buf[i + 1].toDouble()
            val yr = b0 * xr + r1
            r1 = b1 * xr - a1 * yr + r2
            r2 = b2 * xr - a2 * yr
            buf[i + 1] = yr.toFloat()
            i += 2
        }
        z1L = l1; z2L = l2; z1R = r1; z2R = r2
    }

    override fun reset() { z1L = 0.0; z2L = 0.0; z1R = 0.0; z2R = 0.0 }

    companion object {
        /** RBJ: Q for a given bandwidth in octaves at [f0]. */
        fun qFromBandwidth(bw: Double, f0: Double, sampleRate: Double): Double {
            val w0 = 2 * PI * f0.coerceIn(10.0, sampleRate * 0.49) / sampleRate
            val s = sin(w0)
            return 1.0 / (2 * sinh(ln(2.0) / 2 * bw.coerceAtLeast(0.01) * w0 / s))
        }
    }
}
