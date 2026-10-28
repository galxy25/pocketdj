package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioGrid
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * On-device DRUM-PATTERN extraction (port of Studio/Demux/DrumPatternDetector.swift): the drums stem (+ optionally the
 * bass stem) -> classified, timestamped hits. Hop-512 STFT spectral flux with adaptive peak picking; each hit is
 * classed kick / snare / percussive / other from its attack's band-energy ratios; the bass stem runs a low-band-only
 * pass whose hits are all BASS. The file STREAMS in ranged 30 s decodes (never a whole song in one buffer).
 * [pickHits] / [classify] / [bars] / [stepGrid] are pure and unit-tested.
 */
object DrumPatternDetector {
    const val FFT_SIZE = 1024
    const val HOP = 512
    private const val LOW_HI = 160.0
    private const val MID_HI = 2_000.0
    private const val HIGH_LO = 4_000.0
    private const val BASS_BAND_HI = 400.0
    private const val PEAK_RADIUS = 3
    private const val MEAN_WINDOW = 8
    private const val MEAN_FACTOR = 1.4f
    private const val FLOOR_FACTOR = 0.03f
    private const val MIN_GAP_MS = 45.0
    private const val ATTACK_FRAMES = 3
    private const val MAX_SECONDS = 20.0 * 60.0
    private const val WINDOW_SECONDS = 30.0

    /** Hard cap on rendered bars (a 2-hour file at 170 BPM would otherwise mint thousands). */
    const val MAX_BARS = 512

    /** One STFT frame's onset features. */
    class FluxFrame(val flux: Float, val low: Float, val mid: Float, val high: Float)

    /** One bar of the song's timeline (ms bounds on the stem/song clock). */
    data class Bar(val index: Int, val startMs: Int, val endMs: Int)

    // ---- entry -------------------------------------------------------------------------------

    /** Classified hit list: drums-stem onsets by spectrum plus (when given) bass-stem onsets as BASS. Sorted by time. */
    fun detect(drumsPath: String, bassPath: String?, cancelled: () -> Boolean = { false }): List<DemuxDrumHit> {
        val hits = ArrayList<DemuxDrumHit>(onsets(drumsPath, null, null, cancelled))
        if (bassPath != null && !cancelled()) hits += onsets(bassPath, BASS_BAND_HI, DemuxDrumKind.BASS, cancelled)
        return hits.sortedBy { it.ms }
    }

    fun onsets(path: String, fluxBandHi: Double?, kindOverride: DemuxDrumKind?, cancelled: () -> Boolean = { false }): List<DemuxDrumHit> {
        val stream = FluxStream(PcmBuffer.CANONICAL_RATE, fluxBandHi)
        var start = 0.0
        while (start < MAX_SECONDS && !cancelled()) {
            val win = runCatching { AudioDecoder.decode(path, PcmBuffer.CANONICAL_RATE, WINDOW_SECONDS, start) }.getOrNull()
            if (win == null || win.frames <= 0) break
            stream.push(Chromagram.toMono(win.samples, win.channels, win.frames))
            if (win.seconds < WINDOW_SECONDS - 0.05) break
            start += WINDOW_SECONDS
        }
        if (cancelled()) return emptyList()
        return pickHits(stream.frames, stream.frameMs, kindOverride)
    }

    // ---- streamed STFT -----------------------------------------------------------------------

    /** Hop-by-hop STFT emitting flux + band energies per frame; blocks of any size, overlap carried across them. */
    class FluxStream(private val sampleRate: Int, fluxBandHi: Double?) {
        val frames = ArrayList<FluxFrame>()
        val frameMs: Double = HOP.toDouble() / sampleRate * 1000.0
        private val half = FFT_SIZE / 2
        private val window = DoubleArray(FFT_SIZE) { 0.5 - 0.5 * cos(2 * PI * it / FFT_SIZE) }
        private val re = DoubleArray(FFT_SIZE)
        private val im = DoubleArray(FFT_SIZE)
        private var prevMag = FloatArray(half)
        private var mag = FloatArray(half)
        private var havePrev = false
        private var buf = FloatArray(0)
        private val binHz = sampleRate.toDouble() / FFT_SIZE
        private val lowEnd = (LOW_HI / binHz).toInt().coerceIn(1, half)
        private val midEnd = (MID_HI / binHz).toInt().coerceIn(lowEnd, half)
        private val highStart = (HIGH_LO / binHz).toInt().coerceIn(midEnd, half)
        private val fluxEnd = fluxBandHi?.let { (it / binHz).toInt().coerceIn(2, half) } ?: half

        fun push(mono: FloatArray) {
            val all = if (buf.isEmpty()) mono else buf + mono
            var pos = 0
            while (pos + FFT_SIZE <= all.size) {
                for (i in 0 until FFT_SIZE) { re[i] = all[pos + i] * window[i]; im[i] = 0.0 }
                BeatDetect.fft(re, im)
                for (k in 0 until half) mag[k] = sqrt(re[k] * re[k] + im[k] * im[k]).toFloat()
                var flux = 0f
                if (havePrev) for (k in 1 until fluxEnd) { val d = mag[k] - prevMag[k]; if (d > 0) flux += d }
                var low = 0f; var mid = 0f; var high = 0f
                for (k in 1 until lowEnd) low += mag[k] * mag[k]
                for (k in lowEnd until midEnd) mid += mag[k] * mag[k]
                for (k in highStart until half) high += mag[k] * mag[k]
                frames.add(FluxFrame(flux, low, mid, high))
                val t = prevMag; prevMag = mag; mag = t
                havePrev = true
                pos += HOP
            }
            buf = all.copyOfRange(pos, all.size)
        }
    }

    // ---- peak picking + classification (pure) ------------------------------------------------

    /** Adaptive-threshold peak picking over the flux envelope; strengths normalized to the loudest onset. */
    fun pickHits(frames: List<FluxFrame>, frameMs: Double, kindOverride: DemuxDrumKind?): List<DemuxDrumHit> {
        if (frames.size <= 2 || frameMs <= 0) return emptyList()
        val flux = FloatArray(frames.size) { frames[it].flux }
        val maxFlux = flux.max()
        if (maxFlux <= 0f) return emptyList()
        val floor = maxFlux * FLOOR_FACTOR
        val minGapFrames = maxOf(1, (MIN_GAP_MS / frameMs).toInt())

        val hits = ArrayList<DemuxDrumHit>()
        var lastOnset = -minGapFrames
        for (i in flux.indices) {
            val f = flux[i]
            if (f <= floor) continue
            var isPeak = true
            for (j in maxOf(0, i - PEAK_RADIUS)..minOf(flux.size - 1, i + PEAK_RADIUS)) {
                if (j == i) continue
                if (flux[j] > f || (flux[j] == f && j < i)) { isPeak = false; break }
            }
            if (!isPeak) continue
            var sum = 0f; var n = 0
            for (j in maxOf(0, i - MEAN_WINDOW)..minOf(flux.size - 1, i + MEAN_WINDOW)) { sum += flux[j]; n++ }
            if (n == 0 || f <= (sum / n) * MEAN_FACTOR) continue
            if (i - lastOnset < minGapFrames) continue
            lastOnset = i
            val kind = kindOverride ?: classify(frames, i)
            hits.add(DemuxDrumHit((i * frameMs).toInt(), kind, (f / maxFlux).toDouble()))
        }
        return hits
    }

    /** Low-dominant -> kick; clearly top-heavy -> percussive; broadband mid -> snare; the rest -> other. */
    fun classify(frames: List<FluxFrame>, onset: Int): DemuxDrumKind {
        var low = 0f; var mid = 0f; var high = 0f
        for (j in onset..minOf(frames.size - 1, onset + ATTACK_FRAMES)) {
            low += frames[j].low; mid += frames[j].mid; high += frames[j].high
        }
        val total = low + mid + high
        if (total <= 0f) return DemuxDrumKind.OTHER
        val rLow = low / total; val rMid = mid / total; val rHigh = high / total
        if (rLow >= 0.40f) return DemuxDrumKind.KICK
        if (rHigh >= 0.60f) return DemuxDrumKind.PERCUSSIVE
        if (rMid >= 0.30f) return DemuxDrumKind.SNARE
        if (rHigh >= 0.40f) return DemuxDrumKind.PERCUSSIVE
        return DemuxDrumKind.OTHER
    }

    // ---- bars + quantization (pure) ----------------------------------------------------------

    /**
     * The song's bar list. Measured DOWNBEATS when the sidecar has >= 2 (real bar lines, drift included; the tail
     * extends at the median bar length), else constant bars from the scalar [bpm] anchored at [firstDownbeatMs].
     * Empty without any tempo.
     */
    fun bars(downbeatsMs: List<Int>, bpm: Double?, firstDownbeatMs: Int?, durationMs: Int): List<Bar> {
        val out = ArrayList<Bar>()
        val downs = downbeatsMs.filter { it in 0 until durationMs }.sorted()
        if (downs.size >= 2) {
            for (i in 0 until downs.size - 1) {
                if (out.size >= MAX_BARS) break
                out.add(Bar(out.size, downs[i], downs[i + 1]))
            }
            val lengths = downs.zipWithNext { a, b -> b - a }.sorted()
            val median = lengths[lengths.size / 2]
            var start = downs.last()
            while (median > 0 && start + median / 2 < durationMs && out.size < MAX_BARS) {
                out.add(Bar(out.size, start, start + median))
                start += median
            }
            return out
        }
        if (bpm == null || bpm <= 0) return emptyList()
        val barLen = Math.round(240_000.0 / bpm).toInt()
        if (barLen <= 0) return emptyList()
        var start = maxOf(0, firstDownbeatMs ?: 0)
        // A late first downbeat pulls whole bars back to (near) 0 so the intro isn't dropped.
        while (start - barLen >= 0) start -= barLen
        while (start + barLen / 2 < durationMs && out.size < MAX_BARS) {
            out.add(Bar(out.size, start, start + barLen))
            start += barLen
        }
        return out
    }

    /**
     * Quantize hits onto per-bar 16-step lanes. A hit rounds to its NEAREST 16th; one landing on a bar's far edge
     * belongs to the NEXT bar's step 0, so the grid is global, not per bar.
     */
    fun stepGrid(hits: List<DemuxDrumHit>, bars: List<Bar>): List<Map<DemuxDrumKind, List<Boolean>>> {
        val grid = List(bars.size) { HashMap<DemuxDrumKind, BooleanArray>() }
        if (bars.isEmpty()) return grid.map { emptyMap() }
        for (hit in hits) {
            val bi = barIndex(hit.ms, bars) ?: continue
            val bar = bars[bi]
            val len = maxOf(1, bar.endMs - bar.startMs)
            var slot = Math.round((hit.ms - bar.startMs).toDouble() / len * 16).toInt()
            var target = bi
            if (slot >= 16) {
                target = bi + 1
                slot = 0
                if (target >= bars.size) continue
            }
            if (slot < 0) slot = 0
            grid[target].getOrPut(hit.kind) { BooleanArray(16) }[slot] = true
        }
        return grid.map { m -> m.mapValues { it.value.toList() } }
    }

    /** The bar containing [ms] (bars are sorted + contiguous; binary search). */
    fun barIndex(ms: Int, bars: List<Bar>): Int? {
        var lo = 0
        var hi = bars.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) / 2
            if (ms < bars[mid].startMs) hi = mid - 1
            else if (ms >= bars[mid].endMs) lo = mid + 1
            else return mid
        }
        return null
    }

    // ---- grid fallback -----------------------------------------------------------------------

    /** Estimate a constant grid from the first [capSeconds] of a file (BeatDetect over a bounded decode). */
    fun gridEstimate(path: String, capSeconds: Double = 90.0): StudioGrid? {
        val pcm = runCatching { AudioDecoder.decode(path, PcmBuffer.CANONICAL_RATE, capSeconds, 0.0) }.getOrNull() ?: return null
        if (pcm.frames <= 0) return null
        return BeatDetect.detectGrid(pcm)
    }
}
