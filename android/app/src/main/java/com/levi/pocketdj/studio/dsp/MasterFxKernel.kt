package com.levi.pocketdj.studio.dsp

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.tan
import kotlin.math.tanh

/** Kotlin mirror of Studio/MasterFX.swift (and cpp/pdjdsp/fx_kernels.cpp MasterFx). */
data class MasterFxParams(
    val phaser: Boolean = false, val phaserRate: Double = 0.5, val phaserDepth: Double = 0.6,
    val ringMod: Boolean = false, val ringFreq: Double = 200.0, val ringMix: Double = 0.5,
    val freeze: Boolean = false,
    val brazil: Boolean = false, val brazilAmount: Double = 0.6,
    val drive: Boolean = false, val driveAmount: Double = 0.5,
    /** Linear gain (from masterGainDb). */
    val masterGain: Double = 1.0,
    val bpm: Double = 120.0,
) {
    val active: Boolean get() = phaser || ringMod || freeze || brazil || drive || abs(masterGain - 1) > 0.001

    /** Layout shared with the JNI `nativeMasterFxUpdate` double[]. */
    fun toNativeArray(): DoubleArray = doubleArrayOf(
        b(phaser), phaserRate, phaserDepth, b(ringMod), ringFreq, ringMix, b(freeze),
        b(brazil), brazilAmount, b(drive), driveAmount, masterGain, bpm,
    )

    private fun b(v: Boolean) = if (v) 1.0 else 0.0

    companion object {
        /** masterGainDb clamped -24...+12 like the iOS init. */
        fun gainFromDb(db: Double): Double = 10.0.pow(max(-24.0, min(12.0, db)) / 20.0)
    }
}

interface MasterFx {
    fun update(p: MasterFxParams)
    fun process(data: Array<FloatArray>, frames: Int, framePos: Double)
    fun close() {}
}

/** Phaser -> ring-mod -> freeze -> Brazilian bass -> drive -> master gain (soft clamp +-1.8). */
class MasterFxKernel(sampleRate: Double, channelCount: Int) : MasterFx {
    private val sr = if (sampleRate > 0) sampleRate else 44_100.0
    private val channels = max(1, channelCount)
    private var p = MasterFxParams()

    private val stages = 4
    private var lfoPhase = 0.0
    private var ringPhase = 0.0
    private val apX = Array(channels) { DoubleArray(stages) }
    private val apY = Array(channels) { DoubleArray(stages) }
    private val freezeLen = max(1, (sr * 0.25).toInt())
    private val freezeBuf = Array(channels) { FloatArray(freezeLen) }
    private val freezeWrite = IntArray(channels)
    private val freezeRead = IntArray(channels)
    private var wasFrozen = false
    private val subLP = DoubleArray(channels)

    override fun update(p: MasterFxParams) { this.p = p }

    override fun process(data: Array<FloatArray>, frames: Int, framePos: Double) {
        val n = min(data.size, channels)
        if (n <= 0) return
        val params = p
        if (!params.active) {
            for (i in 0 until frames) for (c in 0 until n) {
                freezeBuf[c][freezeWrite[c]] = data[c][i]
                freezeWrite[c] = (freezeWrite[c] + 1) % freezeLen
            }
            wasFrozen = false
            return
        }
        val lfoInc = 2 * Math.PI * max(0.02, min(8.0, params.phaserRate)) / sr
        val ringInc = 2 * Math.PI * max(20.0, min(4000.0, params.ringFreq)) / sr
        val beatFrames = 60.0 / max(20.0, min(300.0, params.bpm)) * sr
        val subCoeff = 1 - exp(-2 * Math.PI * 90.0 / sr)
        if (params.freeze && !wasFrozen) for (c in 0 until n) freezeRead[c] = freezeWrite[c]
        wasFrozen = params.freeze
        for (i in 0 until frames) {
            val pos = framePos + i.toDouble()
            val ringS = if (params.ringMod) sin(ringPhase) else 0.0
            var phaserA = 0.0
            if (params.phaser) {
                val lfo = sin(lfoPhase)
                val f = 200.0 * 10.0.pow((lfo + 1) / 2)
                val t = tan(Math.PI * min(0.49, f / sr))
                phaserA = (t - 1) / (t + 1)
            }
            var beatEnv = 0.0
            if (params.brazil) {
                var ph = (pos % beatFrames) / beatFrames
                if (ph < 0) ph += 1
                beatEnv = 1 - ph; beatEnv *= beatEnv
            }
            for (c in 0 until n) {
                val d = data[c]
                var x = d[i].toDouble()
                if (params.phaser) {
                    var s = x
                    for (st in 0 until stages) {
                        val y = phaserA * s + apX[c][st] - phaserA * apY[c][st]
                        apX[c][st] = s; apY[c][st] = y
                        s = y
                    }
                    val wet = 0.5 * (x + s)
                    x = x * (1 - params.phaserDepth) + wet * params.phaserDepth
                }
                if (params.ringMod) x = x * (1 - params.ringMix) + (x * ringS) * params.ringMix
                if (params.freeze) {
                    x = freezeBuf[c][freezeRead[c]].toDouble()
                    freezeRead[c] = (freezeRead[c] + 1) % freezeLen
                } else {
                    freezeBuf[c][freezeWrite[c]] = x.toFloat()
                    freezeWrite[c] = (freezeWrite[c] + 1) % freezeLen
                }
                if (params.brazil) {
                    subLP[c] += subCoeff * (x - subLP[c])
                    x += params.brazilAmount * beatEnv * subLP[c] * 1.6
                }
                if (params.drive) {
                    val g = 1.0 + params.driveAmount * 9.0
                    x = tanh(x * g) / (1.0 + params.driveAmount * 1.5)
                }
                x *= params.masterGain
                d[i] = max(-1.8, min(1.8, x)).toFloat()
            }
            if (params.phaser) { lfoPhase += lfoInc; if (lfoPhase > 2 * Math.PI) lfoPhase -= 2 * Math.PI }
            if (params.ringMod) { ringPhase += ringInc; if (ringPhase > 2 * Math.PI) ringPhase -= 2 * Math.PI }
        }
    }
}
