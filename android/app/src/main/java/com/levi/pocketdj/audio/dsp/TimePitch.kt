package com.levi.pocketdj.audio.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Independent tempo + pitch (iOS `AVAudioUnitTimePitch`) on Media3's [SonicAudioProcessor].
 *
 * Push/pull rather than in-place, because the output frame count differs from the input's:
 * [push] float input, [pull] float output. Sonic works in s16, so floats are quantised on the
 * way in and widened on the way out. Media3 only applies a changed speed/pitch on `flush()`, which
 * drops the in-flight tail; to keep live glides (Auto-DJ) click-free we first drain Sonic with
 * end-of-stream into our own output ring, then flush and apply, so nothing already pushed is lost.
 *
 * Zero allocation after construction (direct ByteBuffers + float ring).
 */
class TimePitch(
    private val sampleRate: Int = 44_100,
    private val maxPushFrames: Int = 4096,
    ringFrames: Int = 32_768,
) {
    /** Tempo multiplier 0.5..2.0 (pitch preserved). */
    var speed: Float = 1f; private set
    /** Pitch in semitones (tempo preserved). */
    var pitchSemitones: Float = 0f; private set

    private val sonic = SonicAudioProcessor()
    private val inBuf: ByteBuffer = ByteBuffer.allocateDirect(maxPushFrames * CHANNELS * 2).order(ByteOrder.nativeOrder())
    private val ring = FloatArray(ringFrames * CHANNELS)
    private val ringCap = ringFrames
    private var ringRead = 0
    private var ringCount = 0 // frames
    private var dirty = true
    private var active = false
    private val fmt = AudioProcessor.AudioFormat(sampleRate, CHANNELS, C.ENCODING_PCM_16BIT)
    private var appliedSpeed = 1f
    private var appliedPitch = 0f

    /** Number of Sonic reconfigure+flush cycles (Media3 allocates a new Sonic each); diagnostic. */
    var reconfigureCount = 0; private set

    /** Frames dropped because the consumer fell behind (diagnostic). */
    var overflowFrames: Long = 0; private set

    init {
        sonic.configure(fmt)
    }

    fun setSpeed(s: Float) {
        val v = s.coerceIn(MIN_SPEED, MAX_SPEED)
        if (v != speed) { speed = v; dirty = true }
    }

    fun setPitchSemitones(st: Float) {
        if (st != pitchSemitones) { pitchSemitones = st; dirty = true }
    }

    private val pitchRatio: Float get() = 2.0.pow(pitchSemitones / 12.0).toFloat()

    private fun applyIfDirty() {
        if (!dirty) return
        // Media3 rebuilds Sonic on every apply (allocation + a cold-start seam), so continuous
        // glides are quantised: re-apply only once the tempo moved >= 0.25% or the pitch >= 0.04 st.
        // A sub-threshold residual stays pending (inaudible) until it grows or flush() applies it.
        if (abs(speed / appliedSpeed - 1f) < MIN_REL_STEP && abs(pitchSemitones - appliedPitch) < MIN_PITCH_STEP) return
        dirty = false
        reconfigureCount++
        appliedSpeed = speed; appliedPitch = pitchSemitones
        if (active) { // keep what is already inside Sonic
            sonic.queueEndOfStream()
            drainSonic()
        }
        sonic.setSpeed(speed)
        sonic.setPitch(pitchRatio)
        sonic.configure(fmt)
        sonic.flush()
        active = sonic.isActive
    }

    /** Feed [frames] interleaved stereo frames. */
    fun push(input: FloatArray, frames: Int) {
        applyIfDirty()
        var done = 0
        while (done < frames) {
            val n = minOf(maxPushFrames, frames - done)
            if (!active) {
                writeRing(input, done * CHANNELS, n)
            } else {
                inBuf.clear()
                var i = done * CHANNELS
                val end = i + n * CHANNELS
                while (i < end) {
                    val v = (input[i].coerceIn(-1f, 1f) * 32767f).roundToInt()
                    inBuf.putShort(v.toShort())
                    i++
                }
                inBuf.flip()
                sonic.queueInput(inBuf)
                drainSonic()
            }
            done += n
        }
    }

    /** Signal the end of the stream so the last windows are emitted. */
    fun endOfStream() {
        applyIfDirty()
        if (active) { sonic.queueEndOfStream(); drainSonic() }
    }

    private fun drainSonic() {
        val out = sonic.getOutput()
        val shorts = out.remaining() / 2
        if (shorts <= 0) return
        out.order(ByteOrder.nativeOrder())
        var n = shorts / CHANNELS
        // Overflow: drop the oldest frames.
        if (ringCount + n > ringCap) {
            val drop = ringCount + n - ringCap
            val d = minOf(drop, ringCount)
            ringRead = (ringRead + d) % ringCap
            ringCount -= d
            overflowFrames += drop
            if (drop > d) { // output block itself bigger than the ring: skip its head
                val skip = drop - d
                out.position(out.position() + skip * CHANNELS * 2)
                n -= skip
            }
        }
        var w = (ringRead + ringCount) % ringCap
        for (f in 0 until n) {
            ring[w * 2] = out.getShort() / 32768f
            ring[w * 2 + 1] = out.getShort() / 32768f
            w++; if (w == ringCap) w = 0
        }
        ringCount += n
        out.position(out.limit())
    }

    private fun writeRing(src: FloatArray, srcOff: Int, n: Int) {
        var nn = n
        var so = srcOff
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

    /** Frames ready to [pull]. */
    val availableFrames: Int get() = ringCount

    /** Copy up to [maxFrames] processed frames to [out]; returns how many. */
    fun pull(out: FloatArray, maxFrames: Int): Int {
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

    /**
     * Approximate algorithmic latency in output frames (Sonic's analysis window ~ sampleRate/65
     * pitch-period max, two windows deep), plus what is queued. Used by the engine to line the
     * playhead up; exact enough for a UI clock.
     */
    fun latencyFrames(): Int =
        if (!active) ringCount else (2 * sampleRate / 65 / speed).toInt() + ringCount

    /** Drop everything (seek / load): clears Sonic and the output ring. */
    fun flush() {
        ringRead = 0; ringCount = 0
        dirty = false
        appliedSpeed = speed; appliedPitch = pitchSemitones
        sonic.setSpeed(speed)
        sonic.setPitch(pitchRatio)
        sonic.configure(fmt)
        sonic.flush()
        active = sonic.isActive
    }

    companion object {
        const val MIN_REL_STEP = 0.0025f
        const val MIN_PITCH_STEP = 0.04f
        const val MIN_SPEED = 0.5f
        const val MAX_SPEED = 2.0f
    }
}
