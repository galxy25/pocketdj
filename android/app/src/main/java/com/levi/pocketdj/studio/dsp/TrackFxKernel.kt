package com.levi.pocketdj.studio.dsp

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Kotlin mirror of Studio/TrackFX.swift (and of cpp/pdjdsp/fx_kernels.cpp). Same constants, same
 * operation order, Double state, so KernelsTest can hold it to the native output within 1e-5 on a
 * golden vector generated from the C++ source. Used for offline renders on the JVM/CI path and as the
 * fallback when the native lib is not loaded.
 */
data class TrackFxParams(
    val eqLowDb: Double = 0.0, val eqMidDb: Double = 0.0, val eqHighDb: Double = 0.0,
    val reverb: Double = 0.0, val delay: Double = 0.0, val chorus: Double = 0.0,
    val bpm: Double = 120.0,
) {
    /** True when any effect is audibly engaged (fast raw-sum path otherwise). */
    val active: Boolean
        get() = abs(eqLowDb) > 0.01 || abs(eqMidDb) > 0.01 || abs(eqHighDb) > 0.01 ||
            reverb > 0.001 || delay > 0.001 || chorus > 0.001
}

/** Planar per-track effect kernel (native or Kotlin). `data[c]` is channel c, processed in place. */
interface TrackFx {
    val active: Boolean
    fun update(p: TrackFxParams)
    fun reset()
    fun process(data: Array<FloatArray>, frames: Int)
    fun close() {}
}

/** Direct-Form-I biquad (per channel). Coefficients normalized by a0. */
class Biquad {
    var b0 = 1.0; var b1 = 0.0; var b2 = 0.0; var a1 = 0.0; var a2 = 0.0
    private var x1 = 0.0; private var x2 = 0.0; private var y1 = 0.0; private var y2 = 0.0

    fun reset() { x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0 }

    fun set(c: DoubleArray) { b0 = c[0]; b1 = c[1]; b2 = c[2]; a1 = c[3]; a2 = c[4] }

    fun process(x: Double): Double {
        val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    companion object {
        /** RBJ low shelf; returns {b0,b1,b2,a1,a2} normalized by a0. */
        fun lowShelf(dB: Double, f0: Double, sr: Double): DoubleArray {
            val a = 10.0.pow(dB / 40); val w0 = 2 * Math.PI * f0 / sr
            val cw = cos(w0); val sw = sin(w0); val alpha = sw / 2 * sqrt(2.0); val t = 2 * sqrt(a) * alpha
            val a0 = (a + 1) + (a - 1) * cw + t
            val b0 = a * ((a + 1) - (a - 1) * cw + t)
            val b1 = 2 * a * ((a - 1) - (a + 1) * cw)
            val b2 = a * ((a + 1) - (a - 1) * cw - t)
            val a1 = -2 * ((a - 1) + (a + 1) * cw)
            val a2 = (a + 1) + (a - 1) * cw - t
            return doubleArrayOf(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }

        fun highShelf(dB: Double, f0: Double, sr: Double): DoubleArray {
            val a = 10.0.pow(dB / 40); val w0 = 2 * Math.PI * f0 / sr
            val cw = cos(w0); val sw = sin(w0); val alpha = sw / 2 * sqrt(2.0); val t = 2 * sqrt(a) * alpha
            val a0 = (a + 1) - (a - 1) * cw + t
            val b0 = a * ((a + 1) + (a - 1) * cw + t)
            val b1 = -2 * a * ((a - 1) + (a + 1) * cw)
            val b2 = a * ((a + 1) + (a - 1) * cw - t)
            val a1 = 2 * ((a - 1) - (a + 1) * cw)
            val a2 = (a + 1) - (a - 1) * cw - t
            return doubleArrayOf(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }

        fun peaking(dB: Double, f0: Double, q: Double, sr: Double): DoubleArray {
            val a = 10.0.pow(dB / 40); val w0 = 2 * Math.PI * f0 / sr
            val cw = cos(w0); val sw = sin(w0); val alpha = sw / (2 * q)
            val a0 = 1 + alpha / a
            val b0 = 1 + alpha * a
            val b1 = -2 * cw
            val b2 = 1 - alpha * a
            val a1 = -2 * cw
            val a2 = 1 - alpha / a
            return doubleArrayOf(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }
    }
}

/** Feedback comb with a one-pole damping low-pass in the loop (Freeverb block). */
class Comb(size: Int) {
    private val buf = DoubleArray(max(1, size))
    private var idx = 0
    private var store = 0.0
    var feedback = 0.0; var damp1 = 0.0; var damp2 = 0.0
    fun reset() { buf.fill(0.0); store = 0.0 }
    fun process(x: Double): Double {
        val y = buf[idx]
        store = y * damp2 + store * damp1
        buf[idx] = x + store * feedback
        idx += 1; if (idx >= buf.size) idx = 0
        return y
    }
}

/** Schroeder all-pass (Freeverb block). */
class AllPass(size: Int) {
    private val buf = DoubleArray(max(1, size))
    private var idx = 0
    private val feedback = 0.5
    fun reset() { buf.fill(0.0) }
    fun process(x: Double): Double {
        val bufout = buf[idx]
        val y = -x + bufout
        buf[idx] = x + bufout * feedback
        idx += 1; if (idx >= buf.size) idx = 0
        return y
    }
}

/** One track's FX kernel: 3-band EQ -> chorus -> bpm-synced 1/8 delay -> Freeverb-lite. */
class TrackFxKernel(sampleRate: Double, channelCount: Int) : TrackFx {
    private val sr = if (sampleRate > 0) sampleRate else 44_100.0
    private val channels = max(1, channelCount)
    private var p = TrackFxParams()

    private val eq = Array(channels) { Array(3) { Biquad() } }
    private var eqOn = false

    private val delayBuf = Array(channels) { DoubleArray(max(1, (sr * 2).toInt() + 1)) }
    private val delayWrite = IntArray(channels)
    private var delayFrames = max(1, (sr * 2).toInt())
    private val delayFeedback = 0.34
    private var delayWet = 0.0

    private val chorusBuf = Array(channels) {
        DoubleArray(max(2, ((CHORUS_BASE_MS + CHORUS_DEPTH_MS + 2) / 1000 * sr).toInt() + 2))
    }
    private val chorusWrite = IntArray(channels)
    private val chorusPhase = DoubleArray(channels) { it * 0.5 }
    private var chorusWet = 0.0

    private val combs: Array<Array<Comb>>
    private val allpasses: Array<Array<AllPass>>
    private var reverbWet = 0.0

    init {
        val scale = sr / 44_100.0
        combs = Array(channels) { c -> Array(COMB_TUNINGS.size) { Comb((COMB_TUNINGS[it] * scale).toInt() + if (c == 1) SPREAD else 0) } }
        allpasses = Array(channels) { c -> Array(ALLPASS_TUNINGS.size) { AllPass((ALLPASS_TUNINGS[it] * scale).toInt() + if (c == 1) SPREAD else 0) } }
        update(p)
    }

    override val active: Boolean get() = p.active

    override fun update(p: TrackFxParams) {
        this.p = p
        eqOn = abs(p.eqLowDb) > 0.01 || abs(p.eqMidDb) > 0.01 || abs(p.eqHighDb) > 0.01
        val lo = Biquad.lowShelf(p.eqLowDb, 120.0, sr)
        val mid = Biquad.peaking(p.eqMidDb, 1000.0, 0.9, sr)
        val hi = Biquad.highShelf(p.eqHighDb, 8000.0, sr)
        for (ch in eq) { ch[0].set(lo); ch[1].set(mid); ch[2].set(hi) }
        val eighth = 60.0 / max(20.0, min(300.0, p.bpm)) / 2
        delayFrames = max(1, min(delayBuf[0].size - 1, (eighth * sr).toInt()))
        delayWet = max(0.0, min(1.0, p.delay))
        chorusWet = max(0.0, min(1.0, p.chorus))
        reverbWet = max(0.0, min(1.0, p.reverb))
        val room = 0.70 + 0.28 * reverbWet
        for (cs in combs) for (k in cs) { k.feedback = room; k.damp1 = 0.2; k.damp2 = 0.8 }
    }

    override fun reset() {
        for (ch in eq) for (b in ch) b.reset()
        for (c in 0 until channels) { delayBuf[c].fill(0.0); delayWrite[c] = 0; chorusBuf[c].fill(0.0); chorusWrite[c] = 0 }
        for (cs in combs) for (k in cs) k.reset()
        for (a in allpasses) for (k in a) k.reset()
    }

    override fun process(data: Array<FloatArray>, frames: Int) {
        val n = min(data.size, channels)
        if (n <= 0 || frames <= 0 || !p.active) return
        val phaseInc = 2 * Math.PI * CHORUS_RATE_HZ / sr
        val chorusBase = CHORUS_BASE_MS / 1000 * sr
        val chorusDepth = CHORUS_DEPTH_MS / 1000 * sr
        for (c in 0 until n) {
            val d = data[c]
            for (i in 0 until frames) {
                var s = d[i].toDouble()
                if (eqOn) s = eq[c][2].process(eq[c][1].process(eq[c][0].process(s)))
                if (chorusWet > 0) {
                    val lfo = (sin(chorusPhase[c]) + 1) / 2
                    val dly = chorusBase + lfo * chorusDepth
                    val buf = chorusBuf[c]
                    val wet = interp(buf, chorusWrite[c].toDouble() - dly)
                    buf[chorusWrite[c]] = s
                    chorusWrite[c] += 1; if (chorusWrite[c] >= buf.size) chorusWrite[c] = 0
                    chorusPhase[c] += phaseInc; if (chorusPhase[c] > 2 * Math.PI) chorusPhase[c] -= 2 * Math.PI
                    s += wet * chorusWet * 0.7
                }
                if (delayWet > 0) {
                    val cnt = delayBuf[c].size
                    val rd = (delayWrite[c] - delayFrames + cnt) % cnt
                    val echo = delayBuf[c][rd]
                    delayBuf[c][delayWrite[c]] = s + echo * delayFeedback
                    delayWrite[c] += 1; if (delayWrite[c] >= cnt) delayWrite[c] = 0
                    s += echo * delayWet * 0.8
                }
                if (reverbWet > 0) {
                    val input = s * 0.5
                    var acc = 0.0
                    for (k in combs[c]) acc += k.process(input)
                    acc = allpasses[c][0].process(acc)
                    acc = allpasses[c][1].process(acc)
                    s += acc * reverbWet * 0.5
                }
                d[i] = s.toFloat()
            }
        }
    }

    private fun interp(buf: DoubleArray, pos: Double): Double {
        val n = buf.size
        var p = pos
        while (p < 0) p += n.toDouble()
        val i0 = p.toInt() % n
        val i1 = (i0 + 1) % n
        val frac = p - floor(p)
        return buf[i0] * (1 - frac) + buf[i1] * frac
    }

    companion object {
        const val CHORUS_BASE_MS = 18.0
        const val CHORUS_DEPTH_MS = 6.0
        const val CHORUS_RATE_HZ = 0.8
        val COMB_TUNINGS = intArrayOf(1116, 1188, 1277, 1356)
        val ALLPASS_TUNINGS = intArrayOf(556, 441)
        const val SPREAD = 23
    }
}
