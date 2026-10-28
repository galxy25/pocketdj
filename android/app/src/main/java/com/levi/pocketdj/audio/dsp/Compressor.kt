package com.levi.pocketdj.audio.dsp

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.pow

/**
 * Feed-forward stereo-linked compressor standing in for `kAudioUnitSubType_DynamicsProcessor`.
 * Parameters use the same units/curves as `FxParams.comp*` (dB, dB, seconds, seconds, dB):
 * threshold, headroom, attack, release, makeup. Headroom maps to ratio (`20/headroom`, 2..20):
 * Punch(5) = 4:1, Glue(10) = 2:1, Limit(0.5) = 20:1.
 */
class Compressor(private val sampleRate: Float = 44_100f) : DspNode {
    override var bypass: Boolean = false

    var thresholdDb = 0f; private set
    var headroomDb = 5f; private set
    var attackSec = 0.02f; private set
    var releaseSec = 0.15f; private set
    var makeupDb = 0f; private set

    var ratio = 4f; private set
    private var makeupLin = 1f
    private var atkCoef = 0f
    private var relCoef = 0f
    private var grDb = 0f // current smoothed gain reduction (>= 0)

    init { recompute() }

    /** Set every parameter at once (matches the iOS `writeSlotParams` compressor branch). */
    fun set(thresholdDb: Float, headroomDb: Float, attackSec: Float, releaseSec: Float, makeupDb: Float) {
        this.thresholdDb = thresholdDb
        this.headroomDb = headroomDb
        this.attackSec = attackSec
        this.releaseSec = releaseSec
        this.makeupDb = makeupDb
        recompute()
    }

    private fun recompute() {
        ratio = (20f / headroomDb.coerceAtLeast(0.1f)).coerceIn(2f, 20f)
        makeupLin = 10.0.pow(makeupDb / 20.0).toFloat()
        atkCoef = coef(attackSec)
        relCoef = coef(releaseSec)
    }

    private fun coef(t: Float): Float =
        if (t <= 0f) 1f else (1.0 - exp(-1.0 / (t * sampleRate))).toFloat()

    /** Static gain reduction (dB, >= 0) for an input level; exposed for tests and metering. */
    fun staticGainReductionDb(levelDb: Float): Float {
        val over = levelDb - thresholdDb
        return if (over <= 0f) 0f else over * (1f - 1f / ratio)
    }

    /** Current smoothed gain reduction in dB (for a GR meter). */
    val gainReductionDb: Float get() = grDb

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var gr = grDb
        var i = 0
        while (i < frames) {
            val l = buf[2 * i]; val r = buf[2 * i + 1]
            val peak = maxOf(abs(l), abs(r))
            val levelDb = if (peak > 1e-9f) 20f * log10(peak) else -180f
            val target = staticGainReductionDb(levelDb)
            gr += (target - gr) * (if (target > gr) atkCoef else relCoef)
            val g = 10.0.pow(-gr / 20.0).toFloat() * makeupLin
            buf[2 * i] = l * g
            buf[2 * i + 1] = r * g
            i++
        }
        grDb = gr
    }

    override fun reset() { grDb = 0f }
}
