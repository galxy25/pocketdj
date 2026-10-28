package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.core.PcmBuffer
import kotlin.math.sqrt

/**
 * On-device DOMINANT-CHORD detection (port of Studio/Demux/ChordDetector.swift): the whole file -> a
 * timeline of maj/min triad segments. Chroma per frame ([Chromagram]) -> cosine match against the 24
 * triad templates -> majority-vote smoothing -> merged, min-length segments. A verse in Am reads as
 * one long "Am" block, not 400 jittery frames.
 *
 * File analysis STREAMS in [WINDOW_SECONDS] ranged decodes (never a whole-song float buffer).
 * Everything is blocking + pure: run it off the main thread.
 */
object ChordDetector {
    /** Majority-vote window (frames): ~0.8 s flattens beat-level jitter, keeps 1-bar changes. */
    const val SMOOTH_WINDOW = 9
    /** Segments shorter than this merge away (a chord you can't hear isn't one). */
    const val MIN_SEGMENT_MS = 500
    /** A frame whose best template score is below this is "no chord". */
    const val MIN_SCORE = 0.55
    /** RMS floor below which a frame is silence. */
    const val MIN_RMS = 0.005f
    /** Bounds worst-case CPU on an accidental 2-hour file. */
    const val MAX_SECONDS = 20.0 * 60.0
    const val WINDOW_SECONDS = 30.0

    /**
     * The 24 triad templates, L2-normalized: index 0..11 major roots, 12..23 minor roots. Root weighs
     * above fifth above third (the third is quietest in real voicings but separates maj/min).
     */
    val templates: List<DoubleArray> = buildList {
        for (minor in listOf(false, true)) for (root in 0 until 12) {
            val v = DoubleArray(12)
            v[root] = 1.0
            v[(root + if (minor) 3 else 4) % 12] = 0.8
            v[(root + 7) % 12] = 0.9
            val norm = sqrt(v.sumOf { it * it })
            add(DoubleArray(12) { v[it] / norm })
        }
    }

    class FrameLabel(val index: Int?, val score: Double)

    /** Best triad for one chroma frame (cosine similarity), or an index-less label under the floors. */
    fun match(chroma: DoubleArray, rms: Float): FrameLabel {
        if (rms < MIN_RMS) return FrameLabel(null, 0.0)
        val norm = sqrt(chroma.sumOf { it * it })
        if (norm <= 0.0) return FrameLabel(null, 0.0)
        var best = -1.0
        var bestIdx = 0
        for (i in templates.indices) {
            val t = templates[i]
            var dot = 0.0
            for (j in 0 until 12) dot += chroma[j] / norm * t[j]
            if (dot > best) { best = dot; bestIdx = i }
        }
        return if (best >= MIN_SCORE) FrameLabel(bestIdx, best) else FrameLabel(null, best)
    }

    /** Frame labels -> majority-vote smoothing -> merged, min-length segments. */
    fun segments(frames: List<ChromaFrame>, frameMs: Double): List<DemuxChordSegment> {
        if (frames.isEmpty() || frameMs <= 0) return emptyList()
        val raw = frames.map { match(it.chroma, it.rms) }
        val half = SMOOTH_WINDOW / 2
        val voted = arrayOfNulls<Int>(raw.size)
        val counts = IntArray(24)
        for (i in raw.indices) {
            counts.fill(0)
            var nils = 0
            for (j in maxOf(0, i - half)..minOf(raw.size - 1, i + half)) {
                val idx = raw[j].index
                if (idx != null) counts[idx]++ else nils++
            }
            var winner = -1; var n = 0
            for (k in 0 until 24) if (counts[k] > n) { n = counts[k]; winner = k }
            if (winner >= 0 && n >= nils) voted[i] = winner
        }
        class Run(val index: Int, val start: Int, var end: Int, var scoreSum: Double, var n: Int)
        val runs = ArrayList<Run>()
        for (i in voted.indices) {
            val idx = voted[i] ?: continue
            val last = runs.lastOrNull()
            if (last != null && last.index == idx && last.end == i) { last.end = i + 1; last.scoreSum += raw[i].score; last.n++ }
            else runs.add(Run(idx, i, i + 1, raw[i].score, 1))
        }
        val minFrames = maxOf(1, (MIN_SEGMENT_MS / frameMs).toInt())
        return runs.filter { it.end - it.start >= minFrames }.map {
            DemuxChordSegment(
                rootPC = it.index % 12, minor = it.index >= 12,
                startMs = (it.start * frameMs).toInt(), endMs = (it.end * frameMs).toInt(),
                confidence = if (it.n > 0) it.scoreSum / it.n else 0.0,
            )
        }
    }

    /** Segments of an in-memory buffer (tests, short studio items). */
    fun detect(pcm: PcmBuffer): List<DemuxChordSegment> {
        if (pcm.frames <= 0) return emptyList()
        val cg = Chromagram(pcm.sampleRate)
        val out = ArrayList<ChromaFrame>()
        cg.push(Chromagram.toMono(pcm.samples, pcm.channels, pcm.frames)) { out.add(it) }
        return segments(out, cg.frameMs)
    }

    /**
     * Detect the chord timeline of an audio file by ranged streaming decode. Empty when unreadable or
     * nothing is tonal. [cancelled] is polled between windows.
     */
    fun detect(path: String, cancelled: () -> Boolean = { false }): List<DemuxChordSegment> {
        val cg = Chromagram(PcmBuffer.CANONICAL_RATE)
        val frames = ArrayList<ChromaFrame>()
        var start = 0.0
        while (start < MAX_SECONDS && !cancelled()) {
            val win = runCatching { AudioDecoder.decode(path, PcmBuffer.CANONICAL_RATE, WINDOW_SECONDS, start) }.getOrNull()
            if (win == null || win.frames <= 0) break
            cg.push(Chromagram.toMono(win.samples, win.channels, win.frames)) { frames.add(it) }
            if (win.seconds < WINDOW_SECONDS - 0.05) break   // short window = end of file
            start += WINDOW_SECONDS
        }
        return if (cancelled()) emptyList() else segments(frames, cg.frameMs)
    }
}
