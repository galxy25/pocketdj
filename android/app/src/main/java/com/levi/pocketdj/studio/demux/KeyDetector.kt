package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * On-device musical KEY detection -> Camelot code (port of Studio/KeyDetector.swift). Two front doors feed one
 * back end: MIDI note events (an exact duration-weighted pitch-class histogram) and decoded audio (a chromagram
 * folded from FFT magnitudes). Both correlate against the Krumhansl-Kessler major/minor profiles across all 24
 * keys. Pure + blocking: run off the main thread.
 */
object KeyDetector {
    private val MAJOR_PROFILE = doubleArrayOf(6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
    private val MINOR_PROFILE = doubleArrayOf(6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)

    /** Camelot code per tonic pitch class (0 = C ... 11 = B). */
    private val MAJOR_CAMELOT = listOf("8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B")
    private val MINOR_CAMELOT = listOf("5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A")

    data class Camelot(val camelot: String, val strength: Double)
    data class KeyPc(val tonic: Int, val major: Boolean, val strength: Double)

    /** Detect from a 12-bin pitch-class profile (index 0 = C). Null when empty. */
    fun detect(chroma: DoubleArray): Camelot? {
        val k = keyPc(chroma) ?: return null
        return Camelot(if (k.major) MAJOR_CAMELOT[k.tonic] else MINOR_CAMELOT[k.tonic], k.strength)
    }

    /** Best-fitting key: tonic pc, major/minor, 0..1 confidence. Null when the profile is empty. */
    fun keyPc(chroma: DoubleArray): KeyPc? {
        if (chroma.size != 12 || chroma.sum() <= 0.0) return null
        var bestPc = 0
        var bestMajor = true
        var bestScore = -Double.MAX_VALUE
        for (tonic in 0 until 12) {
            val rotated = DoubleArray(12) { chroma[(it + tonic) % 12] }
            val cMaj = correlation(rotated, MAJOR_PROFILE)
            val cMin = correlation(rotated, MINOR_PROFILE)
            if (cMaj > bestScore) { bestScore = cMaj; bestPc = tonic; bestMajor = true }
            if (cMin > bestScore) { bestScore = cMin; bestPc = tonic; bestMajor = false }
        }
        return KeyPc(bestPc, bestMajor, ((bestScore + 1) / 2).coerceIn(0.0, 1.0))
    }

    /** Diatonic scale pcs (semitones from the tonic): major, else natural minor. */
    fun scalePitchClasses(tonic: Int, major: Boolean): List<Int> {
        val steps = if (major) listOf(0, 2, 4, 5, 7, 9, 11) else listOf(0, 2, 3, 5, 7, 8, 10)
        val t = ((tonic % 12) + 12) % 12
        return steps.map { (it + t) % 12 }
    }

    /** The 7 scale pitch classes of the best-fitting key (the MelodyTracker snap target). Null when empty. */
    fun scale(chroma: DoubleArray): List<Int>? = keyPc(chroma)?.let { scalePitchClasses(it.tonic, it.major) }

    /** Instrumental key: duration-weighted pitch-class histogram from note events. */
    fun detect(noteEvents: List<StudioNoteEvent>): Camelot? {
        if (noteEvents.isEmpty()) return null
        val chroma = DoubleArray(12)
        for (e in noteEvents) chroma[((e.note % 12) + 12) % 12] += maxOf(1, e.offMs - e.onMs).toDouble()
        return detect(chroma)
    }

    /** Audio key from a decoded buffer (first 30 s). Null when too short/quiet to be tonal. */
    fun detect(pcm: PcmBuffer): Camelot? = chromagram(pcm)?.let { detect(it) }

    private const val FFT_SIZE = 4096
    private const val HOP = 2048
    private const val MAX_SECONDS = 30.0

    /** Fold the FFT magnitude spectrum of [pcm] into 12 pitch-class bins (A1 ... ~D8). Null when unreadable/silent. */
    fun chromagram(pcm: PcmBuffer): DoubleArray? {
        val sr = pcm.sampleRate
        if (sr <= 0 || pcm.frames <= 0) return null
        val cap = minOf(pcm.frames, (sr * MAX_SECONDS).toInt())
        val mono = Chromagram.toMono(pcm.samples, pcm.channels, cap)
        if (mono.size < FFT_SIZE) return null
        val window = DoubleArray(FFT_SIZE) { 0.5 - 0.5 * cos(2 * PI * it / FFT_SIZE) }
        val binPc = IntArray(FFT_SIZE / 2) { -1 }
        for (k in 1 until FFT_SIZE / 2) {
            val freq = k.toDouble() * sr / FFT_SIZE
            if (freq < 55 || freq > 5000) continue
            val midi = 69.0 + 12.0 * ln(freq / 440.0) / ln(2.0)
            binPc[k] = ((midi.roundToInt() % 12) + 12) % 12
        }
        val re = DoubleArray(FFT_SIZE)
        val im = DoubleArray(FFT_SIZE)
        val chroma = DoubleArray(12)
        var pos = 0
        while (pos + FFT_SIZE <= mono.size) {
            for (i in 0 until FFT_SIZE) { re[i] = mono[pos + i] * window[i]; im[i] = 0.0 }
            BeatDetect.fft(re, im)
            for (k in 1 until FFT_SIZE / 2) if (binPc[k] >= 0) chroma[binPc[k]] += sqrt(re[k] * re[k] + im[k] * im[k])
            pos += HOP
        }
        return if (chroma.sum() > 0.0) chroma else null
    }

    /** Pearson correlation (0 when either vector is constant). */
    private fun correlation(a: DoubleArray, b: DoubleArray): Double {
        val n = a.size.toDouble()
        val ma = a.sum() / n
        val mb = b.sum() / n
        var num = 0.0; var da = 0.0; var db = 0.0
        for (i in a.indices) {
            val x = a[i] - ma; val y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        val den = sqrt(da * db)
        return if (den > 0) num / den else 0.0
    }
}
