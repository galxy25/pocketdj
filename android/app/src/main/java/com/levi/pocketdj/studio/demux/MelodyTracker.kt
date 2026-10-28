package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.AudioDecoder
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * On-device MONOPHONIC MELODY extraction (port of Studio/Demux/MelodyTracker.swift): a melodic stem (vocals, else
 * `other`) -> a single-voice note line. YIN f0 per hop over ~80 Hz-1 kHz -> voiced gate (periodicity + RMS floor)
 * -> median-smooth -> MIDI -> merge same-MIDI runs into notes (drop sub-100 ms blips, bridge brief gaps) -> snap to the
 * KeyDetector scale + octave-correct.
 *
 * The audio is decoded at [SAMPLE_RATE] (16 kHz is plenty for a 1 kHz ceiling and keeps the O(frame x lag) YIN loop
 * cheap on a phone), so the geometry is [FRAME_SIZE]=1024 / [HOP]=160 (10 ms). Everything but [detect] is pure.
 */
object MelodyTracker {
    const val SAMPLE_RATE = 16_000
    const val FRAME_SIZE = 1024
    const val HOP = 160
    const val MIN_HZ = 80.0
    const val MAX_HZ = 1_000.0
    /** YIN absolute threshold on the cumulative-mean-normalized difference. */
    const val YIN_THRESHOLD = 0.15f
    const val PERIODICITY_FLOOR = 0.55f
    const val RMS_FLOOR_FRACTION = 0.10f
    /** Median-smoothing window (frames, odd). */
    const val SMOOTH_WINDOW = 5
    /** A same-MIDI run shorter than this is a blip (dropped); a gap shorter than [GAP_COALESCE_MS] between SAME-MIDI notes is bridged. */
    const val MIN_NOTE_MS = 100.0
    const val GAP_COALESCE_MS = 90.0
    const val MAX_SECONDS = 12.0 * 60.0
    private const val WINDOW_SECONDS = 30.0

    /** One frame's pitch estimate. */
    data class F0Frame(val f0: Double, val periodicity: Float, val rms: Float)

    /** Track the melody of a stem file. Empty when nothing pitched was found (the caller maps that to FAILED). */
    fun detect(path: String, cancelled: () -> Boolean = { false }): List<DemuxMelodyNote> {
        val frames = f0Frames(path, cancelled)
        if (frames.isEmpty() || cancelled()) return emptyList()
        val hopMs = HOP.toDouble() / SAMPLE_RATE * 1000.0
        val raw = buildNotes(frames, hopMs)
        if (raw.isEmpty()) return emptyList()
        val scale = scalePitchClasses(raw) ?: emptyList()
        return snapToScale(raw, scale)
    }

    // ---- per-frame f0 (YIN) ------------------------------------------------------------------

    /** Estimate f0 for ONE frame via YIN. f0 = 0 with low periodicity when there is no clear period in-band. */
    fun estimateF0(frame: FloatArray, sampleRate: Double): F0Frame {
        val n = frame.size
        if (n < 64 || sampleRate <= 0) return F0Frame(0.0, 0f, 0f)
        var sumSq = 0.0
        for (v in frame) sumSq += v.toDouble() * v
        val rms = sqrt(sumSq / n).toFloat()

        val minTau = maxOf(2, (sampleRate / MAX_HZ).roundToInt())
        val maxTau = minOf(n - 1, (sampleRate / MIN_HZ).roundToInt())
        if (maxTau <= minTau + 2) return F0Frame(0.0, 0f, rms)
        // Integration window: the tail still fully overlapped at the LONGEST lag, so every lag sums the same term count.
        val w = n - maxTau
        if (w < 32) return F0Frame(0.0, 0f, rms)

        val ps = DoubleArray(n + 1)
        for (i in 0 until n) ps[i + 1] = ps[i] + frame[i].toDouble() * frame[i]
        val e0 = ps[w] - ps[0]

        // d(tau) = E0 + E(tau) - 2 * sum x[j] x[j+tau]
        val d = DoubleArray(maxTau + 1)
        for (tau in 1..maxTau) {
            var cross = 0.0
            for (j in 0 until w) cross += frame[j].toDouble() * frame[j + tau]
            d[tau] = e0 + (ps[tau + w] - ps[tau]) - 2 * cross
        }
        val cmnd = DoubleArray(maxTau + 1) { 1.0 }
        var running = 0.0
        for (tau in 1..maxTau) {
            running += d[tau]
            cmnd[tau] = if (running > 0) d[tau] * tau / running else 1.0
        }

        // FIRST in-band lag under the threshold, descended to the bottom of its dip; else the in-band global minimum.
        var tau = -1
        var t = minTau
        while (t <= maxTau) {
            if (cmnd[t] < YIN_THRESHOLD) {
                while (t + 1 <= maxTau && cmnd[t + 1] < cmnd[t]) t++
                tau = t
                break
            }
            t++
        }
        if (tau < 0) {
            var best = minTau
            for (k in minTau..maxTau) if (cmnd[k] < cmnd[best]) best = k
            tau = best
        }

        var refined = tau.toDouble()
        if (tau > minTau && tau < maxTau) {
            val a = cmnd[tau - 1]; val b = cmnd[tau]; val c = cmnd[tau + 1]
            val denom = a + c - 2 * b
            if (abs(denom) > 1e-9) refined = tau + (a - c) / (2 * denom)
        }
        val f0 = if (refined > 0) sampleRate / refined else 0.0
        val periodicity = maxOf(0.0, 1.0 - cmnd[tau]).toFloat()
        return F0Frame(f0, periodicity, rms)
    }

    /** Stream the file in ranged 30 s decodes, one [F0Frame] per hop (overlap carried across windows). */
    private fun f0Frames(path: String, cancelled: () -> Boolean): List<F0Frame> {
        val out = ArrayList<F0Frame>()
        var carry = FloatArray(0)
        val frame = FloatArray(FRAME_SIZE)
        var start = 0.0
        while (start < MAX_SECONDS && !cancelled()) {
            val win = runCatching { AudioDecoder.decode(path, SAMPLE_RATE, WINDOW_SECONDS, start) }.getOrNull()
            if (win == null || win.frames <= 0) break
            val mono = Chromagram.toMono(win.samples, win.channels, win.frames)
            val all = if (carry.isEmpty()) mono else carry + mono
            var pos = 0
            while (pos + FRAME_SIZE <= all.size) {
                System.arraycopy(all, pos, frame, 0, FRAME_SIZE)
                out.add(estimateF0(frame, SAMPLE_RATE.toDouble()))
                pos += HOP
            }
            carry = all.copyOfRange(pos, all.size)
            if (win.seconds < WINDOW_SECONDS - 0.05) break
            start += WINDOW_SECONDS
        }
        return out
    }

    // ---- segmentation (pure) -----------------------------------------------------------------

    private class Seg(val midi: Int, val startF: Int, var endF: Int)

    /** Per-hop f0 track -> UN-SNAPPED notes: gate -> median-smooth -> merge -> coalesce gaps -> drop blips. */
    fun buildNotes(frames: List<F0Frame>, hopMs: Double): List<DemuxMelodyNote> {
        if (frames.isEmpty() || hopMs <= 0) return emptyList()
        val maxRms = frames.maxOf { it.rms }
        val rmsFloor = maxRms * RMS_FLOOR_FRACTION

        val midi = arrayOfNulls<Int>(frames.size)
        for (i in frames.indices) {
            val f = frames[i]
            if (f.periodicity < PERIODICITY_FLOOR || f.rms < rmsFloor || f.f0 <= 0) continue
            val m = 69.0 + 12.0 * ln(f.f0 / 440.0) / ln(2.0)
            if (m.isFinite()) midi[i] = Math.round(m).toInt()
        }

        // Median-smooth the voiced values (unvoiced frames neither contribute nor receive).
        val radius = SMOOTH_WINDOW / 2
        val smoothed = midi.copyOf()
        for (i in midi.indices) {
            if (midi[i] == null) continue
            val win = ArrayList<Int>()
            for (j in maxOf(0, i - radius)..minOf(midi.size - 1, i + radius)) midi[j]?.let { win.add(it) }
            if (win.isNotEmpty()) { win.sort(); smoothed[i] = win[win.size / 2] }
        }

        val segs = ArrayList<Seg>()
        for (i in smoothed.indices) {
            val m = smoothed[i] ?: continue
            val last = segs.lastOrNull()
            if (last != null && last.midi == m && last.endF == i - 1) last.endF = i else segs.add(Seg(m, i, i))
        }
        if (segs.isEmpty()) return emptyList()

        val coalesced = arrayListOf(segs[0])
        for (s in segs.drop(1)) {
            val prev = coalesced.last()
            val gapMs = (s.startF - prev.endF - 1) * hopMs
            if (prev.midi == s.midi && gapMs <= GAP_COALESCE_MS) prev.endF = s.endF else coalesced.add(s)
        }

        val notes = ArrayList<DemuxMelodyNote>()
        for (s in coalesced) {
            val startMs = Math.round(s.startF * hopMs).toInt()
            val endMs = Math.round((s.endF + 1) * hopMs).toInt()
            if ((endMs - startMs).toDouble() < MIN_NOTE_MS) continue
            notes.add(DemuxMelodyNote(s.midi, startMs, endMs))
        }
        return notes
    }

    // ---- scale snap + octave correction (pure) -----------------------------------------------

    /** The 7 scale pitch classes of the note line's best-fitting key. Null when empty/atonal. */
    fun scalePitchClasses(notes: List<DemuxMelodyNote>): List<Int>? {
        if (notes.isEmpty()) return null
        val chroma = DoubleArray(12)
        for (n in notes) chroma[((n.midi % 12) + 12) % 12] += maxOf(1, n.endMs - n.startMs).toDouble()
        return KeyDetector.scale(chroma)
    }

    /**
     * Snap each note's pitch class to the nearest scale degree (kills semitone jitter; a no-op when [scalePcs] is
     * empty; two-sided ties resolve toward the LOWER degree), then fold ONLY a near-octave slip (> 10 st from the
     * previous corrected note) by +-12 so genuine sixths/sevenths stay intact.
     */
    fun snapToScale(notes: List<DemuxMelodyNote>, scalePcs: List<Int>): List<DemuxMelodyNote> {
        if (notes.isEmpty()) return emptyList()
        val scale = scalePcs.map { ((it % 12) + 12) % 12 }.toSortedSet().toList()
        val out = ArrayList<DemuxMelodyNote>(notes.size)
        var prev: Int? = null
        for (note in notes) {
            var m = note.midi
            if (scale.isNotEmpty()) {
                val pc = ((m % 12) + 12) % 12
                if (pc !in scale) {
                    var bestDelta = 12
                    for (s in scale) {
                        var delta = s - pc
                        if (delta > 6) delta -= 12
                        if (delta < -6) delta += 12
                        if (abs(delta) < abs(bestDelta)) bestDelta = delta
                    }
                    if (abs(bestDelta) <= 6) m += bestDelta
                }
            }
            prev?.let { p ->
                while (m - p > 10) m -= 12
                while (p - m > 10) m += 12
            }
            out.add(DemuxMelodyNote(m, note.startMs, note.endMs))
            prev = m
        }
        return out
    }
}
