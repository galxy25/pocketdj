package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChordDetectorTest {
    private fun chromaOf(vararg pcs: Int): DoubleArray = DoubleArray(12).also { c -> pcs.forEach { c[it] = 1.0 } }

    /** Mono triad with 3 harmonics per note, [seconds] long, as a stereo-interleaved PcmBuffer. */
    private fun triad(freqs: List<Double>, seconds: Double, rate: Int = 44_100): PcmBuffer {
        val n = (seconds * rate).toInt()
        val s = FloatArray(n * 2)
        for (i in 0 until n) {
            var v = 0.0
            for (f in freqs) for (h in 1..3) v += sin(2 * PI * f * h * i / rate) / h
            val x = (v / (freqs.size * 1.5) * 0.5).toFloat()
            s[2 * i] = x; s[2 * i + 1] = x
        }
        return PcmBuffer(rate, 2, s)
    }

    @Test fun templatesAre24UnitVectorsWithRootAboveFifthAboveThird() {
        assertEquals(24, ChordDetector.templates.size)
        for (t in ChordDetector.templates) assertEquals(1.0, sqrt(t.sumOf { it * it }), 1e-9)
        val cMaj = ChordDetector.templates[0]
        assertTrue(cMaj[0] > cMaj[7] && cMaj[7] > cMaj[4] && cMaj[4] > 0)
        val aMin = ChordDetector.templates[12 + 9]
        assertTrue(aMin[9] > 0 && aMin[0] > 0 && aMin[4] > 0 && aMin[1] == 0.0)
    }

    @Test fun matchPicksTheRightTriadAndHonoursFloors() {
        assertEquals(0, ChordDetector.match(chromaOf(0, 4, 7), 0.1f).index)
        assertEquals(12 + 9, ChordDetector.match(chromaOf(9, 0, 4), 0.1f).index)
        assertEquals(7, ChordDetector.match(chromaOf(7, 11, 2), 0.1f).index)
        assertNull("silence has no chord", ChordDetector.match(chromaOf(0, 4, 7), 0.001f).index)
        assertNull("flat chroma is not tonal", ChordDetector.match(DoubleArray(12) { 1.0 }, 0.1f).index)
        assertNull(ChordDetector.match(DoubleArray(12), 0.1f).index)
    }

    @Test fun segmentsMergeRunsAndDropJitter() {
        val fm = 93.0
        val c = ChromaFrame(chromaOf(0, 4, 7), 0.1f)
        val g = ChromaFrame(chromaOf(7, 11, 2), 0.1f)
        val noise = ChromaFrame(DoubleArray(12) { 1.0 }, 0.1f)
        // 30 C, one noise blip, 30 C, 30 G: the blip is voted away, both C runs merge into one block.
        val frames = List(30) { c } + noise + List(30) { c } + List(30) { g }
        val seg = ChordDetector.segments(frames, fm)
        assertEquals(2, seg.size)
        assertEquals("C", seg[0].name); assertEquals(0, seg[0].startMs)
        assertEquals("G", seg[1].name)
        assertEquals(seg[0].endMs, seg[1].startMs)
        assertTrue(seg[0].confidence > 0.9)
    }

    @Test fun shortBlipsBelowMinSegmentAreDropped() {
        val c = ChromaFrame(chromaOf(0, 4, 7), 0.1f)
        val silent = ChromaFrame(chromaOf(0, 4, 7), 0f)
        // 3 frames of chord inside long silence: voted out (silence majority) -> no segments.
        val frames = List(20) { silent } + List(3) { c } + List(20) { silent }
        assertTrue(ChordDetector.segments(frames, 93.0).isEmpty())
        assertTrue(ChordDetector.segments(emptyList(), 93.0).isEmpty())
    }

    @Test fun syntheticCMajorTriadDetectsCForAtLeast90PercentOfFrames() {
        val pcm = triad(listOf(261.63, 329.63, 392.0), 6.0)
        val cg = Chromagram(pcm.sampleRate)
        val frames = ArrayList<ChromaFrame>()
        cg.push(Chromagram.toMono(pcm.samples, 2)) { frames.add(it) }
        val labels = frames.map { ChordDetector.match(it.chroma, it.rms).index }
        val hit = labels.count { it == 0 }
        assertTrue("C-major frames: $hit/${labels.size}", hit >= labels.size * 0.9)
        val seg = ChordDetector.detect(pcm)
        assertEquals(1, seg.size)
        assertEquals("C", seg[0].name)
    }

    @Test fun syntheticAMinorTriadDetectsAmForAtLeast90PercentOfFrames() {
        val pcm = triad(listOf(220.0, 261.63, 329.63), 6.0)
        val cg = Chromagram(pcm.sampleRate)
        val frames = ArrayList<ChromaFrame>()
        cg.push(Chromagram.toMono(pcm.samples, 2)) { frames.add(it) }
        val labels = frames.map { ChordDetector.match(it.chroma, it.rms).index }
        val hit = labels.count { it == 12 + 9 }
        assertTrue("A-minor frames: $hit/${labels.size}", hit >= labels.size * 0.9)
        assertEquals("Am", ChordDetector.detect(pcm).single().name)
    }

    @Test fun chordChangeProducesTwoSegmentsInOrder() {
        val a = triad(listOf(261.63, 329.63, 392.0), 4.0)
        val b = triad(listOf(196.0, 246.94, 293.66), 4.0)   // G major
        val pcm = PcmBuffer(44_100, 2, a.samples + b.samples)
        val seg = ChordDetector.detect(pcm)
        assertEquals(listOf("C", "G"), seg.map { it.name })
        assertTrue(seg[0].endMs <= seg[1].startMs + 200)
        assertTrue("change lands near 4 s", kotlin.math.abs(seg[1].startMs - 4000) < 600)
    }

    @Test fun silenceAndEmptyYieldNoChords() {
        assertTrue(ChordDetector.detect(PcmBuffer(44_100, 2, FloatArray(44_100 * 2 * 3))).isEmpty())
        assertTrue(ChordDetector.detect(PcmBuffer(44_100, 2, FloatArray(0))).isEmpty())
    }
}
