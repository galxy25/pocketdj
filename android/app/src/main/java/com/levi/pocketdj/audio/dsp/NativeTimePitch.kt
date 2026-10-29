package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.studio.audio.NativeDsp
import kotlin.math.roundToInt

/** The real-time stretcher kernel behind [NativeTimePitch] (JNI in production, a fake in JVM tests). */
interface RtStretchBackend {
    /** Algorithm delay on the input side, in input frames. */
    val inputLatency: Int
    /** Algorithm delay on the output side, in output frames. */
    val outputLatency: Int
    fun setPitchSemitones(semitones: Double)
    /** Consume [inFrames] and write EXACTLY [outFrames] interleaved stereo frames. */
    fun process(input: FloatArray, inFrames: Int, out: FloatArray, outFrames: Int)
    fun reset()
    fun close()
}

internal class JniRtBackend(sampleRate: Int, maxIn: Int, maxOut: Int) : RtStretchBackend {
    private var h = NativeDsp.nativeRtNew(sampleRate, maxIn, maxOut)
    override val inputLatency: Int = NativeDsp.nativeRtInputLatency(h)
    override val outputLatency: Int = NativeDsp.nativeRtOutputLatency(h)
    override fun setPitchSemitones(semitones: Double) { if (h != 0L) NativeDsp.nativeRtSetPitch(h, semitones) }
    override fun process(input: FloatArray, inFrames: Int, out: FloatArray, outFrames: Int) {
        if (h != 0L) NativeDsp.nativeRtProcess(h, input, inFrames, out, outFrames)
    }
    override fun reset() { if (h != 0L) NativeDsp.nativeRtReset(h) }
    override fun close() { if (h != 0L) { NativeDsp.nativeRtFree(h); h = 0 } }
}

/**
 * Splits a tempo into integer per-block output counts without drift: block `n` input frames at
 * `speed` emit `n / speed` output frames; the fraction carries into the next block, so the long-run
 * rate is exact while each block's ratio is a whole-frame pair. Pure (unit-tested).
 */
class RatioPlanner {
    private var carry = 0.0
    fun outFramesFor(inFrames: Int, speed: Float): Int {
        carry += inFrames / speed.toDouble()
        val m = maxOf(1, carry.toInt())
        carry -= m
        return m
    }
    fun reset() { carry = 0.0 }
}

/**
 * Tempo + pitch on the C++ Signalsmith real-time stretcher.
 *
 * Always on: even at 1.0x / 0 st every sample runs through the stretcher, so [latencyFrames] has
 * ONE value for the life of the deck (it never steps when the user nudges tempo, which would
 * detune beat sync). A tempo change is just a different in/out ratio on the next block (see
 * [RatioPlanner]); nothing is rebuilt, allocated or locked on the render thread.
 */
class NativeTimePitch(
    private val sampleRate: Int = 44_100,
    private val maxPushFrames: Int = 4096,
    ringFrames: Int = 32_768,
    private val backend: RtStretchBackend = JniRtBackend(sampleRate, maxPushFrames, maxPushFrames * 2 + 2),
) : TimeStretcher {
    override var speed: Float = 1f; private set
    override var pitchSemitones: Float = 0f; private set

    private val planner = RatioPlanner()
    private val scratch = FloatArray((maxPushFrames * 2 + 2) * CHANNELS)
    private val ring = FloatArray(ringFrames * CHANNELS)
    private val ringCap = ringFrames
    private var ringRead = 0
    private var ringCount = 0
    private var appliedPitch = Float.NaN
    private var closed = false

    override var overflowFrames: Long = 0; private set

    override fun setSpeed(s: Float) { speed = s.coerceIn(TimeStretcher.MIN_SPEED, TimeStretcher.MAX_SPEED) }
    override fun setPitchSemitones(st: Float) { pitchSemitones = st }

    override fun push(input: FloatArray, frames: Int) {
        if (closed) return
        if (pitchSemitones != appliedPitch) { backend.setPitchSemitones(pitchSemitones.toDouble()); appliedPitch = pitchSemitones }
        var done = 0
        while (done < frames) {
            val n = minOf(maxPushFrames, frames - done)
            val m = planner.outFramesFor(n, speed)
            if (done == 0) {
                backend.process(input, n, scratch, m)
            } else {
                // The JNI side reads from index 0; slide the remainder down (only for >maxPush pushes).
                System.arraycopy(input, done * CHANNELS, scratch2(n), 0, n * CHANNELS)
                backend.process(scratch2(n), n, scratch, m)
            }
            writeRing(scratch, m)
            done += n
        }
    }

    private var tail = FloatArray(0)
    private fun scratch2(n: Int): FloatArray {
        if (tail.size < n * CHANNELS) tail = FloatArray(n * CHANNELS)
        return tail
    }

    private fun writeRing(src: FloatArray, n: Int) {
        var nn = n
        var so = 0
        if (ringCount + nn > ringCap) {
            val drop = ringCount + nn - ringCap
            val d = minOf(drop, ringCount)
            ringRead = (ringRead + d) % ringCap
            ringCount -= d
            overflowFrames += drop
            if (drop > d) { so += (drop - d) * CHANNELS; nn -= drop - d }
        }
        var w = (ringRead + ringCount) % ringCap
        for (f in 0 until nn) {
            ring[w * 2] = src[so + f * 2]
            ring[w * 2 + 1] = src[so + f * 2 + 1]
            w++; if (w == ringCap) w = 0
        }
        ringCount += nn
    }

    override val availableFrames: Int get() = ringCount

    override fun pull(out: FloatArray, maxFrames: Int): Int {
        val n = minOf(maxFrames, ringCount)
        var r = ringRead
        for (f in 0 until n) {
            out[f * 2] = ring[r * 2]
            out[f * 2 + 1] = ring[r * 2 + 1]
            r++; if (r == ringCap) r = 0
        }
        ringRead = r
        ringCount -= n
        return n
    }

    /** The stretcher is streaming and always full: there is no tail to flush. */
    override fun endOfStream() {}

    override fun flush() {
        ringRead = 0; ringCount = 0
        planner.reset()
        backend.reset()
    }

    /** Algorithm delay only (no queue), output frames, at the current tempo. */
    fun algorithmicLatencyFrames(): Int = (backend.inputLatency / speed.toDouble()).roundToInt() + backend.outputLatency

    override fun latencyFrames(): Int = algorithmicLatencyFrames() + ringCount

    override fun close() { if (!closed) { closed = true; backend.close() } }

    companion object { private const val CHANNELS = 2 }
}
