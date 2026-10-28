package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import kotlin.math.max
import kotlin.math.min

/**
 * Identity of a pre-stretched pattern-step buffer: one TARGET tempo-fit to [span] steps at the pattern's
 * bpm (iOS `StudioStretchKey`). Prepare/bounce call sites dedupe stretch renders on this key - the same
 * sample fit to 4 steps on two rows stretches once.
 */
data class StudioStretchKey(val targetId: String, val span: Int)

/**
 * The pure step math the sequencer is built from (iOS `StudioEngine` nonisolated statics). ONE source of
 * truth for the highlight clock AND the scheduler: [mappedStep] / [loopWindow] are consulted by both, so what
 * lights up is always what sounds. No Android types - JVM-testable.
 */
object PatternMath {
    /** Sequencer voices (rows) a pattern may play; extra rows are dropped at load. */
    const val MAX_PATTERN_ROWS = 8

    /** Rolling arm horizon: four bars of 16ths ahead of the audible slot. */
    const val HORIZON_SLOTS = StudioPattern.DEFAULT_STEP_COUNT * 4

    private val CANONICAL = StudioAudio.CANONICAL_RATE.toDouble()

    /**
     * One 16th-note step in FRAMES (step = 60/bpm/4 s). Non-positive inputs fall back to the schema's 120 BPM /
     * canonical rate so a degraded document can't divide by 0. Rounds half away from zero like Swift
     * `.rounded()`: 120 BPM @ 44.1 k = 5512.5 -> 5513 (the bar length and the live schedule both multiply it).
     */
    fun stepFrames(bpm: Double, sampleRate: Double = CANONICAL): Long {
        val b = if (bpm > 0) bpm else 120.0
        val sr = if (sampleRate > 0) sampleRate else CANONICAL
        return Math.round(sr * 60.0 / b / 4.0)
    }

    /** Frame time of step [index], [index] steps after [anchor]: integer arithmetic, bit-exact however many passes elapsed. */
    fun stepTime(anchor: Long, index: Int, bpm: Double, sampleRate: Double = CANONICAL): Long =
        anchor + index.toLong() * stepFrames(bpm, sampleRate)

    data class LoopWindow(val start: Int, val len: Int)

    /**
     * Loop window for a [loopBars]-bar looper anchored at the playhead [startStep]: kept a full [loopBars] bars
     * wherever the pattern is long enough (near the tail it slides back, never shrinks) and collapsed to the
     * whole pattern when the pattern is shorter than the window.
     */
    fun loopWindow(startStep: Int, loopBars: Int, stepCount: Int): LoopWindow {
        val sc = max(1, stepCount)
        val full = max(1, min(max(1, loopBars) * StudioPattern.DEFAULT_STEP_COUNT, sc))
        val start = min(max(0, startStep), max(0, sc - full))
        return LoopWindow(start, full)
    }

    /**
     * Map a monotonic playback slot (0,1,2,... steps since the shared start) to the PATTERN step it triggers.
     * Loop OFF: the whole pattern cycles, beginning at [startStep]. Loop ON: only the loop window repeats.
     */
    fun mappedStep(slot: Int, startStep: Int, loopEnabled: Boolean, loopBars: Int, stepCount: Int): Int {
        val sc = max(1, stepCount)
        val s = max(0, slot)
        if (loopEnabled) {
            val w = loopWindow(startStep, loopBars, sc)
            return w.start + (s % w.len)
        }
        val begin = min(max(0, startStep), sc - 1)
        return (begin + s) % sc
    }

    /** The span (steps to tempo-fit) at [col] for an ON step, else 0. */
    fun spanAt(row: StudioPatternRow, col: Int): Int =
        if (row.steps.getOrNull(col) == true) row.stepSpans.getOrNull(col) ?: 0 else 0

    fun loopsAt(row: StudioPatternRow, col: Int): Boolean =
        row.steps.getOrNull(col) == true && row.loopSteps.getOrNull(col) == true

    /** Off-steps covered by a preceding stretched step's footprint (the faint wash in the grid). One pass, O(n). */
    fun spanCoverage(steps: List<Boolean>, spans: List<Int>): BooleanArray {
        val cov = BooleanArray(steps.size)
        for (col in steps.indices) {
            if (!steps[col]) continue
            val span = spans.getOrNull(col) ?: 0
            if (span <= 1) continue
            for (c in (col + 1) until min(col + span, steps.size)) cov[c] = true
        }
        return cov
    }

    /** Distinct (target, span) stretch renders a pattern's ON steps demand, deduped on [StudioStretchKey]. */
    fun stretchKeys(pattern: StudioPattern, onlyRows: Set<Int>? = null): Set<StudioStretchKey> {
        val out = LinkedHashSet<StudioStretchKey>()
        pattern.rows.take(MAX_PATTERN_ROWS).forEachIndexed { i, row ->
            if (onlyRows != null && i !in onlyRows) return@forEachIndexed
            if (row.isSilent) return@forEachIndexed
            for (col in row.steps.indices) {
                val span = spanAt(row, col)
                if (span > 0) out += StudioStretchKey(row.targetId, span)
            }
        }
        return out
    }

    /** Grid steps per rendered line: one bar (16) or half a bar (8) on compact, times the bars-per-line zoom. */
    fun stepsPerLine(compact: Boolean, barsPerLine: Int): Int = (if (compact) 8 else 16) * max(1, barsPerLine)

    fun lineCount(stepCount: Int, perLine: Int): Int = max(1, (stepCount + perLine - 1) / max(1, perLine))

    /** Beat groups of four within [from, to) (the wider-gap separators). */
    fun beatGroups(from: Int, to: Int): List<IntRange> =
        (from until to step 4).map { it until min(it + 4, to) }

    /** Pattern length in whole bars, the Length stepper's value. */
    fun barsOf(stepCount: Int): Int = max(1, (stepCount + 15) / 16)

    const val MAX_BARS = StudioPattern.MAX_STEP_COUNT / 16

    /** Step count after the Length stepper lands on [bars] bars (capped at the schema max). */
    fun stepCountForBars(bars: Int): Int = min(bars * 16, StudioPattern.MAX_STEP_COUNT)

    /** The "N bars - M steps" label. */
    fun lengthLabel(stepCount: Int): String {
        val bars = barsOf(stepCount)
        return "$bars bar${if (bars == 1) "" else "s"} · $stepCount steps"
    }

    /** Duplicate = same rows/BPM under a fresh id; the copy never inherits the bounce (two records must not share one file). */
    fun duplicate(p: StudioPattern, newId: String, nowMs: Double): StudioPattern = p.copy(
        id = newId, name = if (p.name.isEmpty()) "Pattern copy" else p.name + " copy",
        fileName = null, bounceDirty = true, wasUserFolder = false, createdAt = nowMs,
    )

    /** Library line under a pattern name. */
    fun listSubtitle(p: StudioPattern): String =
        "${Math.round(p.bpm)} BPM · ${p.rows.size} row${if (p.rows.size == 1) "" else "s"}" +
            (if (p.fileName != null && !p.bounceDirty) " · bounced" else "")

    /** Row gain chip label. */
    fun gainLabel(db: Double): String = if (db == 0.0) "0 dB" else "%+.1f dB".format(java.util.Locale.US, db)
}
