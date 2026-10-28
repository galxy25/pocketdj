package com.levi.pocketdj.studio.demux

import kotlin.math.PI
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MelodyTrackerTest {
    private fun tone(hz: Double, rate: Int, n: Int, amp: Double = 0.5) = FloatArray(n) { (amp * sin(2 * PI * hz * it / rate)).toFloat() }
    private fun midi(hz: Double) = (69 + 12 * ln(hz / 440.0) / ln(2.0)).roundToInt()

    @Test fun f0OfPureTonesMapsToTheRightMidiNote() {
        for (rate in listOf(16_000, 44_100)) {
            val size = if (rate == 16_000) MelodyTracker.FRAME_SIZE else 2048
            for ((hz, expected) in listOf(220.0 to 57, 440.0 to 69, 880.0 to 81, 110.0 to 45)) {
                val f = MelodyTracker.estimateF0(tone(hz, rate, size), rate.toDouble())
                assertEquals("$hz Hz @ $rate", expected, midi(f.f0))
                assertEquals(hz, f.f0, hz * 0.01)
                assertTrue("periodicity ${f.periodicity}", f.periodicity > 0.9f)
            }
        }
    }

    @Test fun noiseAndSilenceAreUnvoiced() {
        val rnd = java.util.Random(7)
        val noise = FloatArray(MelodyTracker.FRAME_SIZE) { (rnd.nextGaussian() * 0.3).toFloat() }
        assertTrue(MelodyTracker.estimateF0(noise, 16_000.0).periodicity < MelodyTracker.PERIODICITY_FLOOR)
        val silent = MelodyTracker.estimateF0(FloatArray(MelodyTracker.FRAME_SIZE), 16_000.0)
        assertEquals(0f, silent.rms, 0f)
        assertTrue(silent.periodicity < MelodyTracker.PERIODICITY_FLOOR)
        // Too-short frames are rejected outright.
        assertEquals(0.0, MelodyTracker.estimateF0(FloatArray(16), 16_000.0).f0, 0.0)
    }

    // ---- segmentation ----------------------------------------------------------------------------

    private fun voiced(m: Int, n: Int) = List(n) { MelodyTracker.F0Frame(440.0 * Math.pow(2.0, (m - 69) / 12.0), 0.95f, 0.5f) }
    private fun unvoiced(n: Int) = List(n) { MelodyTracker.F0Frame(0.0, 0.1f, 0.5f) }

    @Test fun blipsUnder80To100msAreDropped() {
        // 10 ms hop: 20 frames of C4 (200 ms), a 5-frame (50 ms) blip of E4, 20 frames of G4.
        val notes = MelodyTracker.buildNotes(voiced(60, 20) + unvoiced(3) + voiced(64, 5) + unvoiced(3) + voiced(67, 20), 10.0)
        assertEquals(listOf(60, 67), notes.map { it.midi })
        assertTrue(notes.all { it.endMs - it.startMs >= MelodyTracker.MIN_NOTE_MS })
    }

    @Test fun aBriefGapInsideAHeldNoteIsBridgedButADifferentNoteIsNot() {
        val held = MelodyTracker.buildNotes(voiced(60, 15) + unvoiced(5) + voiced(60, 15), 10.0)
        assertEquals(1, held.size)
        assertEquals(0, held[0].startMs); assertEquals(350, held[0].endMs)
        val two = MelodyTracker.buildNotes(voiced(60, 15) + unvoiced(5) + voiced(62, 15), 10.0)
        assertEquals(listOf(60, 62), two.map { it.midi })
        // A long gap splits even identical pitches.
        val split = MelodyTracker.buildNotes(voiced(60, 15) + unvoiced(15) + voiced(60, 15), 10.0)
        assertEquals(2, split.size)
    }

    @Test fun medianSmoothingRemovesSingleFrameOctaveAndSemitoneJitter() {
        val f = voiced(60, 10).toMutableList()
        f[5] = voiced(72, 1)[0]   // one-frame octave glitch
        f[7] = voiced(61, 1)[0]   // one-frame semitone glitch
        val notes = MelodyTracker.buildNotes(f, 10.0)
        assertEquals(listOf(60), notes.map { it.midi })
    }

    @Test fun quietFramesBelowTheRmsFloorAreUnvoiced() {
        val loud = voiced(60, 20)
        val quiet = voiced(64, 20).map { it.copy(rms = 0.01f) }   // < 10 % of the 0.5 max
        assertEquals(listOf(60), MelodyTracker.buildNotes(loud + quiet, 10.0).map { it.midi })
        assertTrue(MelodyTracker.buildNotes(emptyList(), 10.0).isEmpty())
        assertTrue(MelodyTracker.buildNotes(unvoiced(50), 10.0).isEmpty())
    }

    // ---- scale snap ------------------------------------------------------------------------------

    private fun n(m: Int, i: Int = 0) = DemuxMelodyNote(m, i * 500, i * 500 + 400)

    @Test fun scaleSnapKillsSemitoneJitter() {
        val cMajor = listOf(0, 2, 4, 5, 7, 9, 11)
        val snapped = MelodyTracker.snapToScale(listOf(n(60, 0), n(61, 1), n(63, 2), n(66, 3), n(68, 4), n(70, 5)), cMajor)
        // C# -> C (tie, lower degree), D# -> D, F# -> F, G# -> G, A# -> A
        assertEquals(listOf(60, 60, 62, 65, 67, 69), snapped.map { it.midi })
        assertTrue(snapped.all { (it.midi % 12) in cMajor })
        // Timing is untouched.
        assertEquals(listOf(0, 500, 1000, 1500, 2000, 2500), snapped.map { it.startMs })
    }

    @Test fun emptyScaleIsANoOpOnPitch() {
        val raw = listOf(n(60, 0), n(61, 1), n(63, 2))
        assertEquals(raw.map { it.midi }, MelodyTracker.snapToScale(raw, emptyList()).map { it.midi })
        assertTrue(MelodyTracker.snapToScale(emptyList(), listOf(0)).isEmpty())
    }

    @Test fun octaveCorrectionFoldsOnlyNearOctaveSlipsNotRealLeaps() {
        val none = emptyList<Int>()
        // 60 -> 72 (octave jump, 12 > 10) folds back to 60; a real major sixth (9) is left intact.
        assertEquals(listOf(60, 60), MelodyTracker.snapToScale(listOf(n(60, 0), n(72, 1)), none).map { it.midi })
        assertEquals(listOf(60, 69), MelodyTracker.snapToScale(listOf(n(60, 0), n(69, 1)), none).map { it.midi })
        assertEquals(listOf(72, 72), MelodyTracker.snapToScale(listOf(n(72, 0), n(60, 1)), none).map { it.midi })
        // minor 7th (10) is a genuine leap: kept.
        assertEquals(listOf(60, 70), MelodyTracker.snapToScale(listOf(n(60, 0), n(70, 1)), none).map { it.midi })
    }

    @Test fun scalePitchClassesComeFromTheDurationWeightedHistogram() {
        val notes = listOf(
            DemuxMelodyNote(57, 0, 2000), DemuxMelodyNote(60, 2000, 3000), DemuxMelodyNote(64, 3000, 4500), DemuxMelodyNote(57, 4500, 6000),
            DemuxMelodyNote(62, 6000, 6500), DemuxMelodyNote(65, 6500, 7000), DemuxMelodyNote(67, 7000, 7500),
        )
        assertEquals(setOf(9, 11, 0, 2, 4, 5, 7), MelodyTracker.scalePitchClasses(notes)!!.toSet())   // A minor / C major pcs
        assertEquals(null, MelodyTracker.scalePitchClasses(emptyList()))
    }

    // ---- end to end on synthetic audio ----------------------------------------------------------

    @Test fun aSyntheticMelodyTracksToTheSameNotesThroughTheWholePipeline() {
        val rate = MelodyTracker.SAMPLE_RATE
        val seg = listOf(440.0 to 0.5, 523.25 to 0.5, 0.0 to 0.2, 659.25 to 0.5)
        val audio = seg.flatMap { (hz, s) -> if (hz == 0.0) List((s * rate).toInt()) { 0f } else tone(hz, rate, (s * rate).toInt()).toList() }.toFloatArray()
        val frames = ArrayList<MelodyTracker.F0Frame>()
        val buf = FloatArray(MelodyTracker.FRAME_SIZE)
        var pos = 0
        while (pos + MelodyTracker.FRAME_SIZE <= audio.size) {
            System.arraycopy(audio, pos, buf, 0, MelodyTracker.FRAME_SIZE)
            frames.add(MelodyTracker.estimateF0(buf, rate.toDouble()))
            pos += MelodyTracker.HOP
        }
        val hopMs = MelodyTracker.HOP.toDouble() / rate * 1000
        val raw = MelodyTracker.buildNotes(frames, hopMs)
        assertEquals(listOf(69, 72, 76), raw.map { it.midi })
        val snapped = MelodyTracker.snapToScale(raw, MelodyTracker.scalePitchClasses(raw) ?: emptyList())
        assertEquals(listOf(69, 72, 76), snapped.map { it.midi })
        assertTrue(raw[1].startMs in 420..580)
    }
}
