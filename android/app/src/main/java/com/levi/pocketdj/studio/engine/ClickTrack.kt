package com.levi.pocketdj.studio.engine

import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Metronome synthesis + grid math (iOS `InstrumentEngine` click section). The click is only ever mixed into
 * the LIVE output; take audio is rendered offline from the event log, so the click can never be in a take.
 */
object ClickTrack {
    const val MIN_BPM = 40.0
    const val MAX_BPM = 300.0
    const val DEFAULT_BPM = 120.0
    /** Schedulable lead between "start" and the first (count-in) tick, seconds. */
    const val START_LEAD_SEC = 0.25

    fun clampBpm(bpm: Double): Double = if (bpm.isFinite() && bpm > 0) bpm.coerceIn(MIN_BPM, MAX_BPM) else DEFAULT_BPM

    /** One 4/4 bar in seconds (non-positive input guarded like `StudioPattern.barMs`). */
    fun barSeconds(bpm: Double): Double = 240.0 / (if (bpm.isFinite() && bpm > 0) bpm else DEFAULT_BPM)

    /** Frames in one beat at [bpm] (rounded; the bar is exactly 4 of them so the loop never drifts by more than rounding). */
    fun beatFrames(bpm: Double, sampleRate: Int): Int = (60.0 / clampBpm(bpm) * sampleRate).roundToInt()

    /**
     * ONE bar of mono click: four 30 ms decaying sine ticks, beat 1 at 1600 Hz (the bar tick) and beats 2-4 at
     * 1000 Hz. Length is exactly 4 x [beatFrames].
     */
    fun makeBar(bpm: Double, sampleRate: Int): FloatArray {
        val beat = beatFrames(bpm, sampleRate)
        val out = FloatArray(beat * 4)
        val tickLen = min(beat, (0.03 * sampleRate).toInt())
        for (b in 0 until 4) {
            val freq = if (b == 0) 1600.0 else 1000.0
            val start = b * beat
            for (i in 0 until tickLen) {
                val env = exp(-5.0 * i / tickLen)
                out[start + i] = (sin(2 * PI * freq * i / sampleRate) * env * 0.5).toFloat()
            }
        }
        return out
    }

    /** The next bar boundary at/after `nowSec + lead` on the beat-1 grid (negative bar indices before beat 1 are fine). */
    fun nextBarAnchor(nowSec: Double, beat1Sec: Double, barSec: Double, lead: Double = 0.05): Double {
        if (barSec <= 0) return nowSec + lead
        val n = ceil((nowSec + lead - beat1Sec) / barSec)
        return beat1Sec + n * barSec
    }

    data class BeatOnGrid(val atSec: Double, val beatInBar: Int)

    /**
     * The next BEAT boundary at/after `nowSec + lead` with its index within the bar (0 = accented beat 1).
     * Wild input degrades to "now + lead, beat 0" — never throws.
     */
    fun nextBeatOnGrid(nowSec: Double, gridSec: Double, beatSec: Double, lead: Double = 0.05): BeatOnGrid {
        if (!beatSec.isFinite() || beatSec <= 0 || !nowSec.isFinite() || !gridSec.isFinite()) {
            return BeatOnGrid(if (nowSec.isFinite()) nowSec + lead else lead, 0)
        }
        val raw = ceil((nowSec + lead - gridSec) / beatSec)
        if (!raw.isFinite() || kotlin.math.abs(raw) >= 1e12) return BeatOnGrid(nowSec + lead, 0)
        val n = raw.toLong()
        return BeatOnGrid(gridSec + n * beatSec, (((n % 4) + 4) % 4).toInt())
    }

    /** Remainder of a bar buffer from [beat] (1..3) onward, or null for beat 0 (the loop alone is in phase). */
    fun tailFromBeat(bar: FloatArray, beat: Int): FloatArray? {
        val beatFrames = bar.size / 4
        val b = beat.coerceIn(0, 3)
        if (b == 0 || beatFrames == 0) return null
        return bar.copyOfRange(b * beatFrames, bar.size)
    }

    /**
     * The live click voice: mixed into the engine's output blocks at ABSOLUTE frame positions. [startFrame] is
     * the output frame (engine frame counter) where the bar loop begins; before that it is silent. Thread-safe
     * for one render thread + a control thread: state is swapped as one immutable snapshot.
     */
    class Voice(private val gain: Float = 1f) {
        private class Snapshot(val bar: FloatArray, val startFrame: Long)
        @Volatile private var snap: Snapshot? = null

        val isOn: Boolean get() = snap != null

        fun start(bpm: Double, sampleRate: Int, startFrame: Long) { snap = Snapshot(makeBar(bpm, sampleRate), startFrame) }
        fun stop() { snap = null }

        /** Add the click into interleaved-stereo [out] for the block starting at output frame [blockStartFrame]. */
        fun mixInto(out: FloatArray, frames: Int, blockStartFrame: Long) {
            val s = snap ?: return
            val bar = s.bar
            if (bar.isEmpty()) return
            for (i in 0 until frames) {
                val pos = blockStartFrame + i - s.startFrame
                if (pos < 0) continue
                val v = bar[(pos % bar.size).toInt()] * gain
                out[2 * i] += v; out[2 * i + 1] += v
            }
        }
    }
}
