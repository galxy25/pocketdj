package com.levi.pocketdj.studio

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * On-device musical KEY detection -> Camelot (iOS `KeyDetector`). Notes (instrumentals) give an EXACT
 * duration-weighted pitch-class histogram; audio (samples / loops / sequences) a chromagram folded from an
 * FFT. Both correlate against the Krumhansl-Kessler profiles over all 24 keys.
 */
object KeyDetector {
    private val MAJOR = doubleArrayOf(6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
    private val MINOR = doubleArrayOf(6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)
    private val MAJOR_CAMELOT = listOf("8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B")
    private val MINOR_CAMELOT = listOf("5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A")

    private const val FFT_SIZE = 4096
    private const val HOP = 2048
    private const val MAX_SECONDS = 30.0

    data class Result(val camelot: String, val strength: Double)
    data class KeyPc(val tonic: Int, val major: Boolean, val strength: Double)

    /** Best-fitting key of a 12-bin pitch-class profile (index 0 = C); null when empty. */
    fun keyPc(chroma: DoubleArray): KeyPc? {
        if (chroma.size != 12 || chroma.sum() <= 0.0) return null
        var bestPc = 0; var bestMajor = true; var best = -Double.MAX_VALUE
        for (tonic in 0 until 12) {
            val rotated = DoubleArray(12) { chroma[(it + tonic) % 12] }
            val cMaj = correlation(rotated, MAJOR)
            val cMin = correlation(rotated, MINOR)
            if (cMaj > best) { best = cMaj; bestPc = tonic; bestMajor = true }
            if (cMin > best) { best = cMin; bestPc = tonic; bestMajor = false }
        }
        return KeyPc(bestPc, bestMajor, max(0.0, min(1.0, (best + 1) / 2)))
    }

    fun detect(chroma: DoubleArray): Result? = keyPc(chroma)?.let {
        Result(if (it.major) MAJOR_CAMELOT[it.tonic] else MINOR_CAMELOT[it.tonic], it.strength)
    }

    /** Instrumental key from its exact notes, weighted by sounding duration. */
    fun detect(noteEvents: List<StudioNoteEvent>): Result? {
        if (noteEvents.isEmpty()) return null
        val chroma = DoubleArray(12)
        for (e in noteEvents) chroma[((e.note % 12) + 12) % 12] += max(1, e.offMs - e.onMs).toDouble()
        return detect(chroma)
    }

    fun detect(audio: PcmBuffer): Result? = chromagram(audio)?.let(::detect)

    /** FFT magnitude folded into 12 pitch classes over A1..~D8, Hann-windowed hops; null when silent/too short. */
    fun chromagram(buffer: PcmBuffer): DoubleArray? {
        val sr = buffer.sampleRate
        if (sr <= 0 || buffer.frames <= 0) return null
        val cap = min(buffer.frames, (sr * MAX_SECONDS).toInt())
        if (cap < FFT_SIZE) return null
        val mono = FloatArray(cap)
        val ch = buffer.channels
        for (i in 0 until cap) {
            var acc = 0f
            for (c in 0 until ch) acc += buffer.samples[i * ch + c]
            mono[i] = acc / ch
        }
        val half = FFT_SIZE / 2
        val window = DoubleArray(FFT_SIZE) { 0.5 * (1 - cos(2 * PI * it / (FFT_SIZE - 1))) }
        val binPc = IntArray(half) { -1 }
        for (k in 1 until half) {
            val freq = k.toDouble() * sr / FFT_SIZE
            if (freq < 55 || freq > 5000) continue
            val midi = 69.0 + 12.0 * ln(freq / 440.0) / ln(2.0)
            binPc[k] = ((midi.roundToInt() % 12) + 12) % 12
        }
        val re = DoubleArray(FFT_SIZE); val im = DoubleArray(FFT_SIZE)
        val chroma = DoubleArray(12)
        var pos = 0
        while (pos + FFT_SIZE <= cap) {
            for (i in 0 until FFT_SIZE) { re[i] = mono[pos + i] * window[i]; im[i] = 0.0 }
            fft(re, im)
            for (k in 1 until half) if (binPc[k] >= 0) chroma[binPc[k]] += sqrt(re[k] * re[k] + im[k] * im[k])
            pos += HOP
        }
        return if (chroma.sum() > 0.0) chroma else null
    }

    /** In-place iterative radix-2 FFT (size must be a power of two). */
    internal fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) { val tr = re[i]; re[i] = re[j]; re[j] = tr; val ti = im[i]; im[i] = im[j]; im[j] = ti }
        }
        var len = 2
        while (len <= n) {
            val ang = -2 * PI / len
            val wr = cos(ang); val wi = kotlin.math.sin(ang)
            var i = 0
            while (i < n) {
                var cr = 1.0; var ci = 0.0
                for (k in 0 until len / 2) {
                    val a = i + k; val b = a + len / 2
                    val xr = re[b] * cr - im[b] * ci
                    val xi = re[b] * ci + im[b] * cr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                    val ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr; cr = ncr
                }
                i += len
            }
            len = len shl 1
        }
    }

    private fun correlation(a: DoubleArray, b: DoubleArray): Double {
        val n = a.size.toDouble()
        val ma = a.sum() / n; val mb = b.sum() / n
        var num = 0.0; var da = 0.0; var db = 0.0
        for (i in a.indices) { val x = a[i] - ma; val y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        val den = sqrt(da * db)
        return if (den > 0) num / den else 0.0
    }
}

/**
 * Runs on-device analysis on a performance item when it enters a collection (iOS `StudioAnalyzer`): make it
 * offline-playable (bounce a sequence, render an edited sample / take) then detect + store its key so Mix can
 * glide it harmonically. Idempotent: a no-op once a key is stored.
 */
class StudioAnalyzer(
    private val store: StudioStore,
    private val playback: StudioPlayback,
    /** Decode a local file for the chromagram (off the main thread); null when unreadable. */
    private val decode: suspend (path: String) -> PcmBuffer?,
    /** Leases SAF-stored media as a local file; null = app-private files only. */
    private val materializer: com.levi.pocketdj.studio.store.StudioMaterializer? = null,
) {
    /** Fire-and-forget from an "Add to..." action. Never throws except cancellation. */
    suspend fun prepare(studioId: String) {
        try {
            playback.prepare(studioId)
            ensureKey(studioId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }

    suspend fun ensureKey(id: String) {
        if (store.camelot(id) != null) return
        if (id.startsWith("tk_")) {
            // Instrumental: EXACT key from the played notes, no decode.
            val take = store.take(id) ?: return
            KeyDetector.detect(take.scoreEvents)?.let { store.setCamelot(it.camelot, id) }
            return
        }
        val ref = store.localUrlForPlayback(id)?.ref ?: return
        val lease = (materializer ?: com.levi.pocketdj.studio.store.StudioMaterializer.FILES_ONLY).lease(ref) ?: return
        val camelot = try {
            withContext(Dispatchers.Default) { decode(lease.file.path)?.let { KeyDetector.detect(it)?.camelot } }
        } finally { lease.release() }
        if (camelot != null) store.setCamelot(camelot, id)
    }
}
