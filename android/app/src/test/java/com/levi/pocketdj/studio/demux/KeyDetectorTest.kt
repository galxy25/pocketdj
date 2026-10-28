package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyDetectorTest {
    private fun chroma(vararg weights: Pair<Int, Double>) = DoubleArray(12).also { c -> weights.forEach { (pc, w) -> c[pc] = w } }

    // Krumhansl-like histograms: tonic heaviest, then fifth, third...
    private val cMajor = chroma(0 to 6.0, 2 to 2.0, 4 to 4.0, 5 to 3.5, 7 to 5.0, 9 to 3.0, 11 to 2.0)
    private val aMinor = chroma(9 to 6.0, 11 to 2.0, 0 to 4.5, 2 to 3.5, 4 to 5.0, 5 to 3.0, 7 to 2.0)

    @Test fun chromaMapsToTheCamelotCode() {
        assertEquals("8B", KeyDetector.detect(cMajor)!!.camelot)
        assertEquals("8A", KeyDetector.detect(aMinor)!!.camelot)
    }

    @Test fun everyTonicRotatesToItsCamelotCode() {
        val major = listOf("8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B")
        val minor = listOf("5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A")
        for (t in 0 until 12) {
            val maj = DoubleArray(12) { cMajor[((it - t) % 12 + 12) % 12] }
            assertEquals("major tonic $t", major[t], KeyDetector.detect(maj)!!.camelot)
            val min = DoubleArray(12) { aMinor[((it - t) % 12 + 12) % 12] }
            assertEquals("minor tonic ${(t + 9) % 12}", minor[(t + 9) % 12], KeyDetector.detect(min)!!.camelot)
        }
    }

    @Test fun emptyAndWrongSizedProfilesAreNull() {
        assertNull(KeyDetector.detect(DoubleArray(12)))
        assertNull(KeyDetector.detect(DoubleArray(7) { 1.0 }))
        assertNull(KeyDetector.keyPc(DoubleArray(12)))
        assertNull(KeyDetector.detect(emptyList<StudioNoteEvent>()))
    }

    @Test fun strengthIsRemappedIntoZeroToOne() {
        val s = KeyDetector.detect(cMajor)!!.strength
        assertTrue(s in 0.5..1.0)
    }

    @Test fun scaleHasTheSevenDiatonicPitchClasses() {
        assertEquals(listOf(0, 2, 4, 5, 7, 9, 11), KeyDetector.scalePitchClasses(0, true))
        assertEquals(listOf(9, 11, 0, 2, 4, 5, 7), KeyDetector.scalePitchClasses(9, false))
        assertEquals(KeyDetector.scalePitchClasses(2, true), KeyDetector.scalePitchClasses(14, true))
        assertEquals(listOf(0, 2, 4, 5, 7, 9, 11), KeyDetector.scale(cMajor)!!.sorted())
    }

    @Test fun noteEventsAreWeightedByDuration() {
        // A passing C# for 50 ms must not outweigh the long A-minor tones.
        val ev = listOf(
            StudioNoteEvent(0, 2_000, 57, 90), StudioNoteEvent(2_000, 3_000, 60, 90), StudioNoteEvent(3_000, 4_500, 64, 90),
            StudioNoteEvent(4_500, 4_550, 61, 90), StudioNoteEvent(4_550, 6_000, 57, 90),
        )
        assertEquals("8A", KeyDetector.detect(ev)!!.camelot)
    }

    @Test fun chromagramPutsATonesEnergyOnItsPitchClass() {
        val rate = 44_100
        val n = rate * 2
        val s = FloatArray(n) { (0.5 * sin(2 * PI * 440.0 * it / rate)).toFloat() }
        val cg = KeyDetector.chromagram(PcmBuffer(rate, 1, s))
        assertNotNull(cg)
        val peak = cg!!.indices.maxByOrNull { cg[it] }!!
        assertEquals(9, peak)   // A
        // Too short / silent audio is not tonal.
        assertNull(KeyDetector.chromagram(PcmBuffer(rate, 1, FloatArray(100) { 0.1f })))
        assertNull(KeyDetector.chromagram(PcmBuffer(rate, 1, FloatArray(rate))))
    }

    @Test fun audioKeyOfAnAMinorArpeggioIsAMinorOrItsRelative() {
        val rate = 22_050
        val notes = listOf(220.0 to 1.0, 261.63 to 0.7, 329.63 to 0.8)
        val s = FloatArray(rate * 3) { i -> notes.sumOf { (f, a) -> a * sin(2 * PI * f * i / rate) }.toFloat() * 0.2f }
        val k = KeyDetector.detect(PcmBuffer(rate, 1, s))
        assertNotNull(k)
        assertTrue("got ${k!!.camelot}", k.camelot == "8A" || k.camelot == "8B")
    }
}
