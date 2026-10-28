package com.levi.pocketdj.studio.demux

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DrumPatternDetectorTest {
    private val sr = 44_100

    private fun add(out: FloatArray, atMs: Int, lenMs: Int, tauMs: Double, partials: List<Pair<Double, Double>>) {
        val start = atMs * sr / 1000
        val n = lenMs * sr / 1000
        for (i in 0 until n) {
            val t = i.toDouble() / sr
            val env = exp(-t * 1000.0 / tauMs)
            var v = 0.0
            for ((f, a) in partials) v += a * sin(2 * PI * f * t)
            if (start + i < out.size) out[start + i] += (v * env).toFloat()
        }
    }

    /** 120 BPM: kick on beats 1/3, snare on 2/4, hat on the "and"s. Returns audio + (ms, kind) truth. */
    private fun clickTrack(bars: Int, leadMs: Int = 0): Pair<FloatArray, List<Pair<Int, DemuxDrumKind>>> {
        val beatMs = 500
        val out = FloatArray((leadMs + bars * 4 * beatMs) * sr / 1000 + sr)
        val truth = ArrayList<Pair<Int, DemuxDrumKind>>()
        for (b in 0 until bars * 4) {
            val t = leadMs + b * beatMs
            if (b % 2 == 0) {
                add(out, t, 200, 70.0, listOf(75.0 to 0.8, 150.0 to 0.2)); truth.add(t to DemuxDrumKind.KICK)
            } else {
                add(out, t, 200, 55.0, listOf(250.0 to 0.3, 420.0 to 0.3, 800.0 to 0.25, 1500.0 to 0.2)); truth.add(t to DemuxDrumKind.SNARE)
            }
            add(out, t + 250, 60, 12.0, listOf(9_000.0 to 0.2, 11_500.0 to 0.2, 14_000.0 to 0.2)); truth.add(t + 250 to DemuxDrumKind.PERCUSSIVE)
        }
        return out to truth
    }

    private fun detect(audio: FloatArray): List<DemuxDrumHit> {
        val stream = DrumPatternDetector.FluxStream(sr, null)
        var i = 0
        while (i < audio.size) { // arbitrary block sizes: overlap must be carried across them
            val n = minOf(7_000, audio.size - i)
            stream.push(audio.copyOfRange(i, i + n)); i += n
        }
        return DrumPatternDetector.pickHits(stream.frames, stream.frameMs, null)
    }

    @Test fun syntheticClickTrackClassifiesAtLeast90Percent() {
        val (audio, truth) = clickTrack(4)
        val hits = detect(audio)
        var correct = 0
        for ((ms, kind) in truth) {
            val h = hits.minByOrNull { Math.abs(it.ms - ms) }
            if (h != null && Math.abs(h.ms - ms) <= 40 && h.kind == kind) correct++
        }
        assertTrue("classified $correct/${truth.size} (hits=${hits.map { it.ms to it.kind }})", correct >= truth.size * 0.9)
        // No wild double-triggering: at most a few extras over the truth.
        assertTrue("${hits.size} hits for ${truth.size} truth", hits.size <= truth.size + 4)
    }

    @Test fun silenceAndTooFewFramesYieldNoHits() {
        assertTrue(DrumPatternDetector.pickHits(emptyList(), 11.6, null).isEmpty())
        val flat = List(50) { DrumPatternDetector.FluxFrame(0f, 0f, 0f, 0f) }
        assertTrue(DrumPatternDetector.pickHits(flat, 11.6, null).isEmpty())
        val silent = detect(FloatArray(sr) { 0f })
        assertTrue(silent.isEmpty())
    }

    @Test fun classifyUsesBandRatios() {
        fun f(l: Float, m: Float, h: Float) = listOf(DrumPatternDetector.FluxFrame(1f, l, m, h))
        assertEquals(DemuxDrumKind.KICK, DrumPatternDetector.classify(f(5f, 3f, 2f), 0))
        assertEquals(DemuxDrumKind.PERCUSSIVE, DrumPatternDetector.classify(f(1f, 2f, 7f), 0))
        assertEquals(DemuxDrumKind.SNARE, DrumPatternDetector.classify(f(2f, 5f, 3f), 0))
        assertEquals(DemuxDrumKind.OTHER, DrumPatternDetector.classify(f(0f, 0f, 0f), 0))
        // mid < 0.30, high between 0.40 and 0.60, low < 0.40
        assertEquals(DemuxDrumKind.PERCUSSIVE, DrumPatternDetector.classify(f(3.5f, 1.5f, 5f), 0))
    }

    @Test fun peakPickingHonoursMinGapAndStrengthNormalizesToLoudest() {
        // Two spikes 2 frames apart (~23 ms): the second is inside the 45 ms gap guard.
        val frames = MutableList(60) { DrumPatternDetector.FluxFrame(0.01f, 1f, 1f, 1f) }
        frames[20] = DrumPatternDetector.FluxFrame(10f, 9f, 1f, 1f)
        frames[22] = DrumPatternDetector.FluxFrame(9f, 9f, 1f, 1f)
        frames[40] = DrumPatternDetector.FluxFrame(5f, 9f, 1f, 1f)
        val hits = DrumPatternDetector.pickHits(frames, 11.6, DemuxDrumKind.BASS)
        assertEquals(listOf((20 * 11.6).toInt(), (40 * 11.6).toInt()), hits.map { it.ms })
        assertTrue(hits.all { it.kind == DemuxDrumKind.BASS })
        assertEquals(1.0, hits[0].strength, 1e-6)
        assertEquals(0.5, hits[1].strength, 1e-6)
    }

    // ---- bars ----------------------------------------------------------------------------------

    @Test fun barsFromMeasuredDownbeatsExtendAtTheMedianLength() {
        val bars = DrumPatternDetector.bars(listOf(0, 2000, 4000, 6100), null, null, durationMs = 11_000)
        assertEquals(listOf(0 to 2000, 2000 to 4000, 4000 to 6100), bars.take(3).map { it.startMs to it.endMs })
        assertEquals(6100, bars[3].startMs)
        assertEquals(8100, bars[3].endMs)  // median of [2000, 2000, 2100] = 2000 -> 6100 + 2000
        assertTrue(bars.last().startMs + 1000 < 11_000)
        assertEquals(bars.indices.toList(), bars.map { it.index })
    }

    @Test fun barsFromBpmPullALateFirstDownbeatBackToTheIntro() {
        val bars = DrumPatternDetector.bars(emptyList(), 120.0, 3_200, durationMs = 8_000)
        assertEquals(0 + 1200, bars[0].startMs)   // 3200 - 2000 = 1200 (still >= barLen? 1200 < 2000 so stop)
        assertEquals(2000, bars[0].endMs - bars[0].startMs)
        assertNull(DrumPatternDetector.barIndex(500, bars))
        assertEquals(0, DrumPatternDetector.barIndex(1200, bars))
        assertTrue(DrumPatternDetector.bars(emptyList(), null, null, 8_000).isEmpty())
        assertTrue(DrumPatternDetector.bars(emptyList(), 0.0, 0, 8_000).isEmpty())
    }

    @Test fun barsAreCappedAt512() {
        val bars = DrumPatternDetector.bars(emptyList(), 300.0, 0, durationMs = 10_000_000)
        assertEquals(DrumPatternDetector.MAX_BARS, bars.size)
    }

    @Test fun barIndexBinarySearchIsHalfOpen() {
        val bars = DrumPatternDetector.bars(emptyList(), 120.0, 0, 10_000)
        assertEquals(0, DrumPatternDetector.barIndex(0, bars))
        assertEquals(0, DrumPatternDetector.barIndex(1_999, bars))
        assertEquals(1, DrumPatternDetector.barIndex(2_000, bars))
        assertNull(DrumPatternDetector.barIndex(bars.last().endMs, bars))
    }

    // ---- step grid -----------------------------------------------------------------------------

    @Test fun stepGridRoundsToTheNearest16thAndPushesFarEdgeHitsIntoTheNextBar() {
        val bars = DrumPatternDetector.bars(emptyList(), 120.0, 0, 6_000)   // 2000 ms bars, 125 ms per step
        val hits = listOf(
            DemuxDrumHit(0, DemuxDrumKind.KICK, 1.0),
            DemuxDrumHit(500, DemuxDrumKind.SNARE, 1.0),       // step 4
            DemuxDrumHit(1_950, DemuxDrumKind.KICK, 1.0),      // rounds to 16 -> next bar's step 0
            DemuxDrumHit(2_130, DemuxDrumKind.PERCUSSIVE, 1.0),// step 1 of bar 2
        )
        val grid = DrumPatternDetector.stepGrid(hits, bars)
        assertEquals(true, grid[0][DemuxDrumKind.KICK]!![0])
        assertEquals(true, grid[0][DemuxDrumKind.SNARE]!![4])
        assertEquals(true, grid[1][DemuxDrumKind.KICK]!![0])
        assertEquals(true, grid[1][DemuxDrumKind.PERCUSSIVE]!![1])
        assertEquals(16, grid[0][DemuxDrumKind.KICK]!!.size)
        assertEquals(1, grid[0][DemuxDrumKind.KICK]!!.count { it })
    }

    @Test fun stepGridDropsAFarEdgeHitOnTheLastBarAndHandlesNoBars() {
        val bars = DrumPatternDetector.bars(emptyList(), 120.0, 0, 2_000)
        val g = DrumPatternDetector.stepGrid(listOf(DemuxDrumHit(1_990, DemuxDrumKind.KICK, 1.0)), bars)
        assertTrue(g[0].isEmpty())
        assertTrue(DrumPatternDetector.stepGrid(listOf(DemuxDrumHit(0, DemuxDrumKind.KICK, 1.0)), emptyList()).isEmpty())
    }

    @Test fun detectedClickTrackLandsOnTheExpectedSteps() {
        val (audio, _) = clickTrack(2, leadMs = 100)   // a hit at 0 ms has no previous frame to flux against
        val hits = detect(audio)
        val bars = DrumPatternDetector.bars(emptyList(), 120.0, 100, 4_100)
        val grid = DrumPatternDetector.stepGrid(hits, bars)
        // Bar 2's downbeat kick is detected a few ms EARLY (window leading edge): it must be pushed into bar 2's step 0.
        val kick = grid[1][DemuxDrumKind.KICK]!!
        assertTrue("kick on 1 and 9, got $kick", kick[0] && kick[8])
        assertEquals(2, kick.count { it })
        for (bar in 0..1) {
            val snare = grid[bar][DemuxDrumKind.SNARE]!!
            assertTrue("snare on 5 and 13 in bar $bar, got $snare", snare[4] && snare[12])
        }
    }
}
