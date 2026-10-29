package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.studio.audio.NativeDsp

/**
 * Independent tempo + pitch for a Mix / Now Playing deck (the single audio-layer stretcher
 * contract). Push/pull: [push] interleaved stereo float input, [pull] interleaved stereo output;
 * the output frame count differs from the input's by the tempo [speed].
 *
 * Implementations: [NativeTimePitch] (C++ Signalsmith via JNI, the default) and [TimePitch]
 * (Media3 Sonic, used when libpdjdsp is absent: JVM unit tests, a missing ABI).
 *
 * Render-thread contract: no allocation, no locks; a ratio change takes effect at the next [push].
 */
interface TimeStretcher {
    /** Tempo multiplier [MIN_SPEED]..[MAX_SPEED] (pitch preserved). */
    val speed: Float
    /** Pitch in semitones (tempo preserved). */
    val pitchSemitones: Float
    fun setSpeed(s: Float)
    fun setPitchSemitones(st: Float)

    fun push(input: FloatArray, frames: Int)
    val availableFrames: Int
    fun pull(out: FloatArray, maxFrames: Int): Int
    /** Flush the tail (the last windows) into the output. */
    fun endOfStream()
    /** Drop everything (seek / load). The latency does not change. */
    fun flush()

    /**
     * Delay between a frame entering [push] and leaving [pull], in OUTPUT frames: the algorithm's own
     * delay plus what is queued. Multiply by [speed] for the lag in source frames.
     */
    fun latencyFrames(): Int

    /** Frames dropped because the consumer fell behind (diagnostic). */
    val overflowFrames: Long

    /** Free native resources. Idempotent. */
    fun close() {}

    companion object {
        const val MIN_SPEED = 0.5f
        const val MAX_SPEED = 2.0f
    }
}

object TimeStretchers {
    /** Test seam: build every chain's stretcher with a controllable kernel (JVM has no libpdjdsp). */
    @Volatile internal var factoryOverride: ((sampleRate: Int, maxPush: Int) -> TimeStretcher)? = null

    /**
     * Native Signalsmith when [nativeAvailable] (libpdjdsp loaded), else the Sonic fallback.
     * [nativeAvailable] is a seam for tests.
     */
    fun create(
        sampleRate: Int,
        maxPushFrames: Int,
        nativeAvailable: Boolean = NativeDsp.available,
    ): TimeStretcher =
        factoryOverride?.invoke(sampleRate, maxPushFrames) ?: if (nativeAvailable) {
            try { NativeTimePitch(sampleRate, maxPushFrames) }
            catch (_: Throwable) { TimePitch(sampleRate, maxPushFrames) }
        } else {
            TimePitch(sampleRate, maxPushFrames)
        }
}
