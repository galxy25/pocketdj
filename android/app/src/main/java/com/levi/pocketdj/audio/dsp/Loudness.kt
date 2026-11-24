package com.levi.pocketdj.audio.dsp

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.tan
import kotlinx.serialization.Serializable

/** DJ Mode volume leveling (port of iOS `LoudnessLeveling`): the target and the gain clamp. */
object LoudnessLeveling {
    const val TARGET_LUFS = -14.0
    const val MIN_GAIN_DB = -12.0
    const val MAX_GAIN_DB = 6.0
    /** Seconds a newly-known gain ramps over (never a step). */
    const val RAMP_SECONDS = 2.0

    /** `clamp(target - measured, -12..+6)`; null when the loudness is unknown (play at 0 dB). */
    fun gainDb(lufs: Double?): Double? {
        if (lufs == null || !lufs.isFinite()) return null
        return min(MAX_GAIN_DB, max(MIN_GAIN_DB, TARGET_LUFS - lufs))
    }

    /** Gain to apply: unknown loudness => 0 dB. */
    fun gainDbOrZero(lufs: Double?): Double = gainDb(lufs) ?: 0.0

    fun linear(db: Double): Double = 10.0.pow(db / 20.0)
}

/** The slice of a file to measure (a song on a shared album side); null [lengthMs] = to the end. */
@Serializable
data class LoudnessSegment(val startMs: Int, val lengthMs: Int? = null)

/** Cancellation flag polled by the blocking decode loop. */
class LoudnessCancelFlag {
    private val flag = AtomicBoolean(false)
    val isCancelled: Boolean get() = flag.get()
    fun cancel() { flag.set(true) }
}

/**
 * ITU-R BS.1770-4 integrated loudness, pure DSP (port of iOS `LoudnessAnalyzer` meter).
 * K-weighting (high-shelf pre-filter + RLB high-pass, derived per sample rate), 400 ms blocks at a
 * 100 ms hop, gates at -70 LUFS absolute then -10 LU relative. Mono is ONE channel.
 */
object Loudness {
    class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double) {
        private var x1 = 0.0; private var x2 = 0.0; private var y1 = 0.0; private var y2 = 0.0
        fun process(x: Double): Double {
            val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    fun preFilter(fs: Double): Biquad {
        val f0 = 1681.974450955533; val g = 3.999843853973347; val q = 0.7071752369554196
        val k = tan(PI * f0 / fs)
        val vh = 10.0.pow(g / 20); val vb = vh.pow(0.4996667741545416)
        val a0 = 1 + k / q + k * k
        return Biquad((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    }

    fun rlbFilter(fs: Double): Biquad {
        val f0 = 38.13547087602444; val q = 0.5003270373238773
        val k = tan(PI * f0 / fs)
        val a0 = 1 + k / q + k * k
        return Biquad(1.0, -2.0, 1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    }

    /** BS.1770 block loudness of a channel-summed mean square. */
    fun lufs(meanSquare: Double): Double = if (meanSquare > 0) -0.691 + 10 * log10(meanSquare) else Double.NEGATIVE_INFINITY

    /** Streaming meter: K-weights, accumulates 100 ms sub-block energies, gates at the end. */
    class Meter(val channels: Int, sampleRate: Double) {
        private val hop = max(1, (sampleRate * 0.1).roundToInt())
        private val stage1 = Array(channels) { preFilter(sampleRate) }
        private val stage2 = Array(channels) { rlbFilter(sampleRate) }
        private var acc = 0.0
        private var accFrames = 0
        private var subBlocks = DoubleArray(256)
        var subBlockCount = 0; private set

        /** Interleaved [channels]-channel samples. */
        fun processInterleaved(s: FloatArray, frames: Int, offset: Int = 0) {
            for (f in 0 until frames) {
                var e = 0.0
                for (c in 0 until channels) {
                    val y = stage2[c].process(stage1[c].process(s[offset + f * channels + c].toDouble()))
                    e += y * y
                }
                push(e)
            }
        }

        /**
         * The mono-sum path: average the [srcChannels] of interleaved [s], run the ONE chain on the
         * sum, scale its energy by [srcChannels] (identical channels then read as stereo). Requires
         * a 1-channel meter.
         */
        fun processMonoSum(s: FloatArray, frames: Int, srcChannels: Int, offset: Int = 0) {
            require(channels == 1)
            val inv = 1.0 / max(1, srcChannels)
            for (f in 0 until frames) {
                var m = 0.0
                for (c in 0 until srcChannels) m += s[offset + f * srcChannels + c].toDouble()
                val y = stage2[0].process(stage1[0].process(m * inv))
                push(y * y * srcChannels)
            }
        }

        private fun push(e: Double) {
            acc += e; accFrames++
            if (accFrames == hop) {
                if (subBlockCount == subBlocks.size) subBlocks = subBlocks.copyOf(subBlocks.size * 2)
                subBlocks[subBlockCount++] = acc / hop
                acc = 0.0; accFrames = 0
            }
        }

        /** Gated integrated loudness; null with < 400 ms of audio or when everything is gated. */
        fun integratedLoudness(): Double? {
            if (subBlockCount < 4) return null
            val n = subBlockCount - 3
            val blocks = DoubleArray(n) { (subBlocks[it] + subBlocks[it + 1] + subBlocks[it + 2] + subBlocks[it + 3]) / 4 }
            val absGated = blocks.filter { lufs(it) > -70 }
            if (absGated.isEmpty()) return null
            val rel = lufs(absGated.sum() / absGated.size) - 10
            val gated = absGated.filter { lufs(it) > rel }
            if (gated.isEmpty()) return null
            return lufs(gated.sum() / gated.size)
        }
    }

    /** One-shot over an interleaved buffer. */
    fun integratedLoudness(samples: FloatArray, channels: Int = 1, sampleRate: Double): Double? {
        if (channels <= 0 || sampleRate <= 0) return null
        val m = Meter(channels, sampleRate)
        m.processInterleaved(samples, samples.size / channels)
        return m.integratedLoudness()
    }
}
