package com.levi.pocketdj.studio.demux

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** One framewise chroma: 12 pitch-class magnitudes + the frame's RMS. */
class ChromaFrame(val chroma: DoubleArray, val rms: Float)

/**
 * STREAMING chromagram (the framing half of iOS ChordDetector): feed mono samples in any block size
 * with [push]; every [FFT_SIZE] samples (no overlap, ~93 ms at 44.1 kHz) one Hann-windowed FFT is folded
 * into 12 pitch classes over the chord band (E1 ~41 Hz up to ~1.3 kHz — above that it is mostly cymbals
 * and harmonics that smear the triad). Never holds more than one frame plus the carry, so a full-length
 * track is safe.
 */
class Chromagram(val sampleRate: Int) {
    private val window = DoubleArray(FFT_SIZE) { 0.5 - 0.5 * cos(2 * PI * it / FFT_SIZE) }
    /** FFT bin -> pitch class (-1 = outside the chord band) for THIS sample rate. */
    internal val binPc = IntArray(FFT_SIZE / 2).also { map ->
        map.fill(-1)
        for (k in 1 until FFT_SIZE / 2) {
            val freq = k.toDouble() * sampleRate / FFT_SIZE
            if (freq < BAND_LO || freq > BAND_HI) continue
            val midi = 69.0 + 12.0 * ln(freq / 440.0) / ln(2.0)
            map[k] = ((midi.roundToInt() % 12) + 12) % 12
        }
    }
    private val re = DoubleArray(FFT_SIZE)
    private val im = DoubleArray(FFT_SIZE)
    private val carry = FloatArray(FFT_SIZE)
    private var carryLen = 0

    /** Milliseconds one frame spans. */
    val frameMs: Double get() = FFT_SIZE.toDouble() / sampleRate * 1000.0

    /** Append [n] mono samples; every completed frame is handed to [emit]. */
    fun push(mono: FloatArray, n: Int = mono.size, emit: (ChromaFrame) -> Unit) {
        var i = 0
        while (i < n) {
            val take = minOf(FFT_SIZE - carryLen, n - i)
            System.arraycopy(mono, i, carry, carryLen, take)
            carryLen += take; i += take
            if (carryLen == FFT_SIZE) { emit(frame()); carryLen = 0 }
        }
    }

    private fun frame(): ChromaFrame {
        var sumSq = 0.0
        for (i in 0 until FFT_SIZE) {
            val s = carry[i].toDouble()
            sumSq += s * s
            re[i] = s * window[i]; im[i] = 0.0
        }
        BeatDetect.fft(re, im)
        val chroma = DoubleArray(12)
        for (k in 1 until FFT_SIZE / 2) {
            val pc = binPc[k]
            if (pc >= 0) chroma[pc] += sqrt(re[k] * re[k] + im[k] * im[k])
        }
        return ChromaFrame(chroma, sqrt(sumSq / FFT_SIZE).toFloat())
    }

    companion object {
        const val FFT_SIZE = 4096
        const val BAND_LO = 41.0
        const val BAND_HI = 1320.0

        /** Interleaved [channels] -> mono average of the first [frames] frames. */
        fun toMono(interleaved: FloatArray, channels: Int, frames: Int = interleaved.size / channels): FloatArray {
            if (channels == 1) return interleaved.copyOf(frames)
            val out = FloatArray(frames)
            val inv = 1f / channels
            for (f in 0 until frames) {
                var s = 0f
                for (c in 0 until channels) s += interleaved[f * channels + c]
                out[f] = s * inv
            }
            return out
        }
    }
}
