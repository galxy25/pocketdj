package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioGrid
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * On-device tempo/beat-phase detection (port of Support/BeatDetect.swift): spectral-flux onset
 * envelope -> autocorrelation with a log-normal prior at 120 BPM -> octave fold into [70,180] ->
 * onset-energy downbeat phase (4/4). The SEARCH range (55-210) is wider than the REPORT window so a
 * sub-70 fundamental is found and then folded. Output is a CONSTANT grid (empty beatsMs).
 */
object BeatDetect {
    const val BPM_LO = 70.0
    const val BPM_HI = 180.0
    const val SEARCH_BPM_LO = 55.0
    const val SEARCH_BPM_HI = 210.0
    private const val BEATS_PER_BAR = 4
    private const val HOP = 512
    private const val FFT_SIZE = 1024
    private const val MAX_ANALYSIS_SECONDS = 120.0
    private const val PRIOR_CENTER_BPM = 120.0
    private const val PRIOR_SPREAD = 1.0

    /** Halve/double until inside [lo, hi] (analyze-beatgrid.py octave_fold). */
    fun octaveFold(bpm: Double, lo: Double = BPM_LO, hi: Double = BPM_HI): Double {
        if (bpm <= 0) return bpm
        var b = bpm
        while (b < lo) b *= 2
        while (b > hi) b /= 2
        return b
    }

    /** Detect a constant grid from decoded PCM; null when too short (<2 s), quiet or aperiodic. */
    fun detectGrid(pcm: PcmBuffer): StudioGrid? {
        val sr = pcm.sampleRate.toDouble()
        if (sr <= 0) return null
        val mono = mono(pcm, MAX_ANALYSIS_SECONDS) ?: return null
        if (mono.size < (sr * 2).toInt()) return null
        val env = onsetEnvelope(mono)
        if (env.size < 16) return null
        val frameRate = sr / HOP
        val (period, bpmRaw) = estimateTempo(env, frameRate) ?: return null
        val bpm = octaveFold(bpmRaw)
        val (firstBeat, downPhase) = estimatePhase(env, period)
        val firstDownFrame = firstBeat + downPhase * period.toDouble()
        val ms = Math.round(firstDownFrame * HOP / sr * 1000).toInt()
        return StudioGrid(bpm = Math.round(bpm * 100) / 100.0, firstDownbeatMs = maxOf(0, ms))
    }

    internal fun mono(pcm: PcmBuffer, maxSeconds: Double): FloatArray? {
        val ch = pcm.channels
        val frames = pcm.frames
        if (frames <= 0 || ch <= 0) return null
        val cap = minOf(frames, (pcm.sampleRate * maxSeconds).toInt())
        if (cap <= 0) return null
        val out = FloatArray(cap)
        for (i in 0 until cap) {
            var s = 0f
            for (c in 0 until ch) s += pcm.samples[i * ch + c]
            out[i] = s / ch
        }
        return out
    }

    /** Half-wave rectified spectral flux per STFT frame (hop 512, Hann 1024). */
    internal fun onsetEnvelope(x: FloatArray): FloatArray {
        val n = x.size
        if (n < FFT_SIZE) return FloatArray(0)
        val half = FFT_SIZE / 2
        val window = DoubleArray(FFT_SIZE) { 0.5 - 0.5 * cos(2 * PI * it / FFT_SIZE) }
        val re = DoubleArray(FFT_SIZE); val im = DoubleArray(FFT_SIZE)
        var prev = DoubleArray(half); var mag = DoubleArray(half)
        val env = ArrayList<Float>((n - FFT_SIZE) / HOP + 1)
        var pos = 0; var havePrev = false
        while (pos + FFT_SIZE <= n) {
            for (i in 0 until FFT_SIZE) { re[i] = x[pos + i] * window[i]; im[i] = 0.0 }
            fft(re, im)
            for (k in 0 until half) mag[k] = sqrt(re[k] * re[k] + im[k] * im[k])
            if (havePrev) {
                var flux = 0.0
                for (k in 0 until half) { val d = mag[k] - prev[k]; if (d > 0) flux += d }
                env.add(flux.toFloat())
            }
            havePrev = true
            val t = prev; prev = mag; mag = t
            pos += HOP
        }
        return env.toFloatArray()
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

    /** Dominant beat period (envelope frames) + raw BPM via prior-weighted autocorrelation; null if aperiodic. */
    internal fun estimateTempo(env: FloatArray, frameRate: Double): Pair<Int, Double>? {
        val n = env.size
        val minLag = maxOf(1, Math.round(60.0 * frameRate / SEARCH_BPM_HI).toInt())
        val maxLag = Math.round(60.0 * frameRate / SEARCH_BPM_LO).toInt()
        if (maxLag <= minLag || n <= maxLag * 2) return null
        val mean = env.sum() / n
        val e = FloatArray(n) { env[it] - mean }
        val ac = DoubleArray(maxLag + 2)
        var bestLag = minLag
        var bestScore = -Double.MAX_VALUE
        for (lag in minLag..maxLag + 1) {
            var a = 0.0
            for (t in lag until n) a += e[t].toDouble() * e[t - lag]
            ac[lag] = a
        }
        // Smooth across neighbouring lags: a fractional beat period splits its autocorrelation spike over
        // two integer lags, which would otherwise lose to a ½-tempo whose period happens to be near-integer.
        val sm = DoubleArray(ac.size)
        for (lag in minLag..maxLag) sm[lag] = ac[maxOf(lag - 1, 0)] + ac[lag] + ac[lag + 1]
        for (lag in minLag..maxLag) {
            val bpm = 60.0 * frameRate / lag
            val z = ln(bpm / PRIOR_CENTER_BPM) / ln(2.0) / PRIOR_SPREAD
            val score = sm[lag] * exp(-0.5 * z * z)
            if (score > bestScore) { bestScore = score; bestLag = lag }
        }
        if (bestScore <= 0) return null
        // Centroid refinement over the 3-lag neighbourhood: integer lags are ~2 BPM apart at 150 BPM.
        var delta = 0.0
        if (bestLag > minLag) {
            val y0 = ac[bestLag - 1]; val y1 = ac[bestLag]; val y2 = ac[bestLag + 1]
            val den = y0 + y1 + y2
            if (den > 0) delta = ((y2 - y0) / den).coerceIn(-0.5, 0.5)
        }
        return bestLag to (60.0 * frameRate / (bestLag + delta))
    }

    /** Beat phase (frame offset of beat 1) + the bar phase (0..3) carrying the most onset energy. */
    internal fun estimatePhase(env: FloatArray, period: Int): Pair<Int, Int> {
        val n = env.size
        if (period <= 0 || n == 0) return 0 to 0
        var bestPhase = 0; var bestSum = -1f
        for (phase in 0 until period) {
            var s = 0f; var i = phase
            while (i < n) { s += env[i]; i += period }
            if (s > bestSum) { bestSum = s; bestPhase = phase }
        }
        val beats = ArrayList<Int>()
        var i = bestPhase
        while (i < n) { beats.add(i); i += period }
        var bestDown = 0; var bestScore = -1f
        for (p in 0 until BEATS_PER_BAR) {
            var sum = 0f; var cnt = 0; var k = p
            while (k < beats.size) { sum += env[beats[k]]; cnt++; k += BEATS_PER_BAR }
            val m = if (cnt > 0) sum / cnt else -1f
            if (m > bestScore) { bestScore = m; bestDown = p }
        }
        return bestPhase to bestDown
    }
}
