package com.levi.pocketdj.audio.dsp

import kotlin.math.abs

/**
 * Lookahead brick-wall peak limiter (the master safety net, iOS `kAudioUnitSubType_PeakLimiter`).
 *
 * Per frame: required gain = ceiling/peak (capped at 1); a sliding minimum over the lookahead
 * window L, then a box average over L, gives a gain curve that is guaranteed <= the required gain
 * at the moment each (L-1)-frame-delayed sample leaves, with smooth attack and release. A final
 * hard clamp makes `|out| <= ceiling` unconditional. Latency = [latencyFrames].
 * Below the ceiling the gain is exactly 1.0, so the signal passes bit-identical (just delayed).
 */
class Limiter(sampleRate: Float = 44_100f, lookaheadMs: Float = 3f, val ceiling: Float = 1f) : DspNode {
    override var bypass: Boolean = false

    private val look = maxOf(2, (sampleRate * lookaheadMs / 1000f).toInt())
    val latencyFrames: Int get() = look - 1

    private val dLen = look - 1
    private val delay = FloatArray(dLen * CHANNELS)
    private var dPos = 0
    // Monotonic deque over target gains.
    private val dqVal = FloatArray(look)
    private val dqIdx = LongArray(look)
    private var dqHead = 0
    private var dqSize = 0
    // Box average of the min-filtered gain.
    private val avgBuf = FloatArray(look) { 1f }
    private var avgPos = 0
    private var avgSum = look.toDouble()
    private var n = 0L

    /** Lowest gain applied since the last [takeMinGain]; for a GR meter. */
    private var minGain = 1f
    /** Frames whose pre-clamp output exceeded the ceiling (should stay 0: the gain curve alone limits). */
    var clampedSamples = 0L; private set
    fun takeMinGain(): Float { val g = minGain; minGain = 1f; return g }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var i = 0
        while (i < frames) {
            val l = buf[2 * i]; val r = buf[2 * i + 1]
            val peak = maxOf(abs(l), abs(r))
            val target = if (peak > ceiling) ceiling / peak else 1f

            // Sliding minimum over the last `look` targets.
            // Evict the expired head BEFORE pushing: the ring holds `look` slots and a push onto a
            // full ring would overwrite the head and corrupt the window minimum.
            if (dqSize > 0 && dqIdx[dqHead] <= n - look) { dqHead = (dqHead + 1) % look; dqSize-- }
            while (dqSize > 0 && dqVal[(dqHead + dqSize - 1) % look] >= target) dqSize--
            dqVal[(dqHead + dqSize) % look] = target
            dqIdx[(dqHead + dqSize) % look] = n
            dqSize++
            val m = dqVal[dqHead]

            // Box average of the last `look` minima.
            avgSum += (m - avgBuf[avgPos]).toDouble()
            avgBuf[avgPos] = m
            avgPos = (avgPos + 1) % look
            val g = (avgSum / look).toFloat().coerceAtMost(1f)
            if (g < minGain) minGain = g

            // Delay line: emit the oldest, store the newest.
            val ol = delay[2 * dPos]; val orr = delay[2 * dPos + 1]
            delay[2 * dPos] = l; delay[2 * dPos + 1] = r
            dPos++; if (dPos == dLen) dPos = 0
            val yl = ol * g; val yr = orr * g
            if (abs(yl) > ceiling + 1e-6f || abs(yr) > ceiling + 1e-6f) clampedSamples++
            buf[2 * i] = yl.coerceIn(-ceiling, ceiling)
            buf[2 * i + 1] = yr.coerceIn(-ceiling, ceiling)
            n++; i++
        }
    }

    override fun reset() {
        delay.fill(0f); dPos = 0; dqHead = 0; dqSize = 0
        avgBuf.fill(1f); avgPos = 0; avgSum = look.toDouble(); minGain = 1f
    }
}
