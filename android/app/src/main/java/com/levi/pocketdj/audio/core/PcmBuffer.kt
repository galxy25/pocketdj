package com.levi.pocketdj.audio.core

import kotlin.math.floor

/** Interleaved float PCM held in memory (Studio decode result, WAV/AAC encode input). */
class PcmBuffer(val sampleRate: Int, val channels: Int, val samples: FloatArray) {
    val frames: Int get() = samples.size / channels
    val seconds: Double get() = frames.toDouble() / sampleRate

    /** Canonical form: 2 channels (mono duplicated, extra channels dropped) at [rate] (linear). */
    fun toCanonical(rate: Int = CANONICAL_RATE): PcmBuffer = toStereo().resampled(rate)

    fun toStereo(): PcmBuffer {
        if (channels == 2) return this
        val n = frames
        val out = FloatArray(n * 2)
        if (channels == 1) {
            for (i in 0 until n) { out[2 * i] = samples[i]; out[2 * i + 1] = samples[i] }
        } else {
            for (i in 0 until n) { out[2 * i] = samples[i * channels]; out[2 * i + 1] = samples[i * channels + 1] }
        }
        return PcmBuffer(sampleRate, 2, out)
    }

    fun resampled(rate: Int): PcmBuffer {
        if (rate == sampleRate || frames == 0) return PcmBuffer(rate, channels, samples)
        val ratio = sampleRate.toDouble() / rate
        val outFrames = floor(frames / ratio).toInt()
        val out = FloatArray(outFrames * channels)
        for (i in 0 until outFrames) {
            val pos = i * ratio
            val i0 = pos.toInt()
            val f = (pos - i0).toFloat()
            val i1 = minOf(i0 + 1, frames - 1)
            for (c in 0 until channels) {
                val a = samples[i0 * channels + c]
                out[i * channels + c] = a + (samples[i1 * channels + c] - a) * f
            }
        }
        return PcmBuffer(rate, channels, out)
    }

    companion object {
        const val CANONICAL_RATE = 44_100

        /** Little-endian 16-bit PCM bytes -> floats in [-1,1). */
        fun fromPcm16(bytes: ByteArray, length: Int, dst: FloatArray, dstOff: Int): Int {
            val n = length / 2
            for (i in 0 until n) {
                val lo = bytes[2 * i].toInt() and 0xFF
                val hi = bytes[2 * i + 1].toInt()
                dst[dstOff + i] = ((hi shl 8) or lo).toShort() / 32768f
            }
            return n
        }
    }
}
