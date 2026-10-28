package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PatternBouncerTest {
    @get:Rule val tmp = TemporaryFolder()

    private val stepF = PatternMath.stepFrames(120.0).toInt()
    private val bar = stepF * 16

    private fun ramp(frames: Int, base: Float = 0.1f) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { base + (it / 2) * 1e-5f })
    private fun const(frames: Int, v: Float) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { v })

    private fun row(target: String, vararg cols: Int, loops: Set<Int> = emptySet(), spans: Map<Int, Int> = emptyMap(), gainDb: Double = 0.0) =
        StudioPatternRow.of(target, steps = List(16) { it in cols }, loopSteps = List(16) { it in loops }, stepSpans = List(16) { spans[it] ?: 0 }, gainDb = gainDb)

    private fun pattern(vararg rows: StudioPatternRow) = StudioPattern.of("ptn_b", "b", bpm = 120.0, rows = rows.toList())

    /** Run the LIVE scheduler for [passes] bars and return pass [pass] (0-based). */
    private fun live(p: StudioPattern, buffers: Map<Int, PcmBuffer>, spans: Map<Int, Map<Int, PcmBuffer>> = emptyMap(), pass: Int): FloatArray {
        val s = PatternScheduler()
        s.load(p, buffers, spans)
        s.restartFromTop()
        val out = FloatArray(bar * 2)
        val blk = FloatArray(1024 * 2)
        var pos = 0
        while (pos < (pass + 1) * bar) {
            val n = minOf(1024, (pass + 1) * bar - pos)
            java.util.Arrays.fill(blk, 0f)
            s.pull(blk, n)
            for (i in 0 until n) if (pos + i >= pass * bar) { val o = pos + i - pass * bar; out[o * 2] = blk[i * 2]; out[o * 2 + 1] = blk[i * 2 + 1] }
            pos += n
        }
        return out
    }

    private fun assertSame(expected: FloatArray, actual: PcmBuffer, frames: Int = bar) {
        assertTrue(actual.frames >= frames)
        for (i in 0 until frames * 2) assertEquals("sample $i (frame ${i / 2})", expected[i], actual.samples[i], 1e-6f)
    }

    // ---- bounce == live ----

    @Test fun oneShotsBounceEqualsLivePassOne() {
        val p = pattern(row("a", 0, 5, 9), row("b", 3, 12, gainDb = -6.0))
        val bufs = mapOf("a" to ramp(2000), "b" to ramp(3000, 0.2f))
        val bounce = PatternBouncer.render(p, bufs)
        assertSame(live(p, mapOf(0 to bufs.getValue("a"), 1 to bufs.getValue("b")), pass = 0), bounce)
    }

    @Test fun chokeCutsTheRingingHitInBounceAndLiveAlike() {
        val p = pattern(row("a", 0, 1))      // buffer is 3x a step: col 1 cuts col 0 mid-ring
        val bufs = mapOf("a" to ramp(stepF * 3))
        val bounce = PatternBouncer.render(p, bufs)
        assertSame(live(p, mapOf(0 to bufs.getValue("a")), pass = 0), bounce)
        // first hit contributes exactly one step, then the retrigger restarts from the buffer head
        assertEquals(bufs.getValue("a").samples[0], bounce.samples[stepF * 2], 1e-6f)
    }

    @Test fun loopWrapHeadFillMakesBounceEqualLiveSteadyState() {
        // loop trigger at col 12, first trigger at col 4: live pass 2's head [0, col4) carries the loop's continuing phase.
        val p = pattern(row("a", 4, 12, loops = setOf(12)))
        val loopBuf = ramp(3777)               // deliberately not a divisor of the bar
        val bufs = mapOf("a" to loopBuf)
        val bounce = PatternBouncer.render(p, bufs)
        assertSame(live(p, mapOf(0 to loopBuf), pass = 1), bounce)
    }

    @Test fun loopStepsAreFiniteChainedRepeatsTrimmedToTheNextTrigger() {
        val p = pattern(row("a", 0, 8, loops = setOf(0)))
        val ev = PatternBouncer.plan(p, mapOf("a" to ramp(3000)))
        val first = ev.filter { it.start < 8L * stepF && it.start >= 0 }
        assertEquals(0L, first.first().start)
        // repeats are back-to-back and the chain ends EXACTLY at col 8 (never past it, never endless)
        first.zipWithNext().forEach { (a, b) -> assertEquals(a.start + a.length, b.start) }
        assertEquals(8L * stepF, first.last().start + first.last().length)
        assertTrue(first.all { it.length <= 3000 })
        // the last loop (col 8 is a one-shot here) rings as a one-shot; nothing is infinite
        assertTrue(ev.all { it.start + it.length <= bar + 3000 })
    }

    @Test fun lastLoopStopsAtTheBarEnd() {
        val ev = PatternBouncer.plan(pattern(row("a", 14, loops = setOf(14))), mapOf("a" to ramp(2000)))
        assertEquals(bar.toLong(), ev.maxOf { it.start + it.length })
    }

    @Test fun spanStepUsesStretchBufferAndIsTheSameEventsAsLive() {
        val p = pattern(row("a", 0, 8, spans = mapOf(0 to 4)))
        val natural = const(400, 0.1f)
        val stretched = const(stepF * 4, 0.9f)
        val bounce = PatternBouncer.render(p, mapOf("a" to natural), mapOf(StudioStretchKey("a", 4) to stretched))
        assertSame(live(p, mapOf(0 to natural), mapOf(0 to mapOf(4 to stretched)), pass = 0), bounce)
        assertEquals(0.9f, bounce.samples[0], 1e-6f)
        assertEquals(0.1f, bounce.samples[8 * stepF * 2], 1e-6f)
    }

    // ---- refusals / skips ----

    @Test fun emptyPatternIsRefused() {
        try { PatternBouncer.render(pattern(row("a")), mapOf("a" to const(10, 1f))); fail() }
        catch (e: PatternBounceException) { assertEquals(PatternBounceException.Reason.EMPTY_PATTERN, e.reason) }
    }

    @Test fun missingTargetRowsAreSkippedButAllMissingIsRefused() {
        val p = pattern(row("a", 0), row("gone", 0))
        val ok = PatternBouncer.render(p, mapOf("a" to const(20, 0.5f)))
        assertEquals(0.5f, ok.samples[0], 1e-6f)
        try { PatternBouncer.render(p, emptyMap()); fail() } catch (e: PatternBounceException) { assertEquals(PatternBounceException.Reason.EMPTY_PATTERN, e.reason) }
    }

    @Test fun soundingRowsDropsSilentMissingEmptyAndNonCanonical() {
        val p = pattern(row("a", 0), row("b"), row("c", 0), row("d", 0), row("e", 0))
        val bufs = mapOf(
            "a" to const(10, 1f), "b" to const(10, 1f), "d" to PcmBuffer(44_100, 2, FloatArray(0)), "e" to PcmBuffer(48_000, 2, FloatArray(20)),
        )
        assertEquals(listOf(0), PatternBouncer.soundingRows(p, bufs))
    }

    // ---- mix / tail ----

    @Test fun rowGainAndPeakNormalizationAreApplied() {
        val half = PatternBouncer.render(pattern(row("a", 0, gainDb = -6.0)), mapOf("a" to const(10, 1f)))
        assertEquals(0.5012f, half.samples[0], 1e-3f)
        val hot = PatternBouncer.render(pattern(row("a", 0), row("b", 0)), mapOf("a" to const(10, 1f), "b" to const(10, 1f)))
        assertEquals(1f, hot.samples[0], 1e-6f)          // 2.0 summed -> scaled by 1/peak, never clipped
    }

    @Test fun ringingTailPastTheBarIsKeptThenDrainedAtTheFloor() {
        // a one-shot at the last step that outlasts the bar by 1.5 bars worth of signal then silence
        val tail = PcmBuffer(44_100, 2, FloatArray(40_000 * 2) { if (it / 2 < 20_000) 0.3f else 0f })
        val out = PatternBouncer.render(pattern(row("a", 15)), mapOf("a" to tail))
        assertTrue(out.frames > bar)
        assertTrue(out.frames <= bar + 44_100 * 3)
        // content in the kept tail is audible, and the drain ended at the first silent 512-window
        assertEquals(0.3f, out.samples[(bar + 100) * 2], 1e-6f)
        assertTrue(out.frames < 15 * stepF + 40_000)
    }

    @Test fun veryLongTailIsCappedAtThreeSeconds() {
        val long = const(44_100 * 10, 0.2f)
        val out = PatternBouncer.render(pattern(row("a", 15)), mapOf("a" to long))
        assertEquals(bar + 44_100 * 3, out.frames)
    }

    @Test fun shortPatternBouncesExactlyTheBar() {
        val out = PatternBouncer.render(pattern(row("a", 0)), mapOf("a" to const(100, 0.2f)))
        assertEquals(bar, out.frames)
    }

    // ---- stretch dedup ----

    @Test fun stretchKeysDedupeAcrossRowsAndFailuresFallBackToAbsent() = runBlocking {
        val p = pattern(
            row("a", 0, 4, spans = mapOf(0 to 4, 4 to 2)),
            row("a", 8, spans = mapOf(8 to 4)),
            row("b", 0, spans = mapOf(0 to 3)),
        )
        val calls = ArrayList<Pair<Int, Long>>()
        val natural = mapOf("a" to const(100, 0.1f), "b" to const(200, 0.1f))
        val out = PatternBouncer.stretchSpanBuffers(p, natural) { buf, frames ->
            calls += buf.frames to frames
            if (buf.frames == 200) throw IllegalStateException("stretch failed")
            const(frames.toInt(), 0.5f)
        }
        // (a,4) stretched ONCE for two rows, (a,2) once, (b,3) attempted and failed -> absent
        assertEquals(3, calls.size)
        assertEquals(setOf(StudioStretchKey("a", 4), StudioStretchKey("a", 2)), out.keys)
        assertEquals(stepF * 4, out.getValue(StudioStretchKey("a", 4)).frames)
        assertEquals(stepF * 2, out.getValue(StudioStretchKey("a", 2)).frames)
    }

    @Test fun stretchSkipsTargetsWithoutANaturalBuffer() = runBlocking {
        val p = pattern(row("a", 0, spans = mapOf(0 to 4)))
        var n = 0
        val out = PatternBouncer.stretchSpanBuffers(p, emptyMap()) { b, _ -> n++; b }
        assertTrue(out.isEmpty()); assertEquals(0, n)
    }

    // ---- file write ----

    @Test fun bounceWritesAtomicallyAndReportsLength() = runBlocking {
        val dest = File(tmp.root, "seq/pattern-ptn_b.m4a")
        var wrote: PcmBuffer? = null
        val res = PatternBouncer.bounce(pattern(row("a", 0)), mapOf("a" to const(100, 0.2f)), emptyMap(), dest) { pcm, f -> wrote = pcm; f.writeText("x") }
        assertTrue(dest.isFile)
        assertEquals(bar.toLong(), res.frames)
        assertEquals(Math.round(bar / 44.1).toInt(), res.lengthMs)
        // the bounce is one pattern loop: its recorded length matches the document's own lengthMs within a frame of rounding
        assertEquals(StudioPattern.of("p", "p").lengthMs.toDouble(), res.lengthMs.toDouble(), 1.0)
        assertEquals(bar, wrote!!.frames)
        assertEquals(listOf("pattern-ptn_b.m4a"), dest.parentFile!!.list()!!.toList())     // no temp sibling left behind
    }

    @Test fun aFailingWriterLeavesNoPartialFile() = runBlocking {
        val dest = File(tmp.root, "seq/pattern-ptn_b.m4a")
        try {
            PatternBouncer.bounce(pattern(row("a", 0)), mapOf("a" to const(100, 0.2f)), emptyMap(), dest) { _, f -> f.writeText("partial"); throw java.io.IOException("encoder died") }
            fail()
        } catch (e: java.io.IOException) { /* expected */ }
        assertFalse(dest.exists())
        assertTrue(dest.parentFile!!.list()!!.isEmpty())
    }
}
