package com.levi.pocketdj.screens.producer.demux

import com.levi.pocketdj.studio.demux.DemuxChordSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChordDetailMathTest {
    private val clefs = ChordStaffMath.Clef.entries

    @Test fun fuzzAll24ChordsAcrossFiveOctavesNeverOverflowsOrThrows() {
        var heads = 0
        for (minor in listOf(false, true)) for (root in 0 until 12) {
            val seg = DemuxChordSegment(root, minor, 0, 1000)
            for (base in listOf(24, 36, 48, 60, 72, 84, 96)) for (clef in clefs) {
                val laid = ChordStaffMath.layout(clef, seg.midiNotes(base))
                assertEquals(3, laid.size)
                for (h in laid) {
                    assertTrue("stepsUp sane for ${seg.name}@$base", h.stepsUp in -60..60)
                    // even ledger steps only, never inside the staff
                    assertTrue(h.ledgerSteps.all { it % 2 == 0 && (it < 0 || it > 8) })
                    heads++
                }
            }
        }
        assertEquals(2 * 12 * 7 * 2 * 3, heads)
    }

    @Test fun firstNoteAtOrAboveTheBottomLineDoesNotOverflow() {
        // The iOS crash: a sentinel of Int.MIN_VALUE minus a positive stepsUp. Treble bottom line = E4 (64).
        val laid = ChordStaffMath.layout(ChordStaffMath.Clef.TREBLE, listOf(64, 67, 71))
        assertEquals(listOf(0, 2, 4), laid.map { it.stepsUp })
        assertTrue(laid.none { it.nudged })
        val high = ChordStaffMath.layout(ChordStaffMath.Clef.TREBLE, listOf(96, 100, 103))
        assertTrue(high.all { it.stepsUp > 8 })
    }

    @Test fun secondIntervalNudgesTheUpperHeadAndLedgersFillCorrectSteps() {
        val laid = ChordStaffMath.layout(ChordStaffMath.Clef.TREBLE, listOf(60, 62))   // C4, D4 adjacent steps
        assertEquals(listOf(-2, -1), laid.map { it.stepsUp })
        assertFalse(laid[0].nudged); assertTrue(laid[1].nudged)
        assertEquals(listOf(-2), laid[0].ledgerSteps)       // C4: one ledger line below the staff
        assertTrue("D4 sits in the space under the staff: no ledger", laid[1].ledgerSteps.isEmpty())
        val bass = ChordStaffMath.layout(ChordStaffMath.Clef.BASS, listOf(43))          // G2 = bottom line
        assertEquals(0, bass[0].stepsUp); assertTrue(bass[0].ledgerSteps.isEmpty())
        val above = ChordStaffMath.layout(ChordStaffMath.Clef.TREBLE, listOf(81))       // A5: first ledger above
        assertEquals(10, above[0].stepsUp)
        assertEquals(listOf(10), above[0].ledgerSteps)
        assertEquals(listOf(10, 12), ChordStaffMath.layout(ChordStaffMath.Clef.TREBLE, listOf(84))[0].ledgerSteps)
    }

    @Test fun pitchSpellsBlackKeysAsSharpsAndNegativeMidiIsSafe() {
        assertEquals(true, ChordStaffMath.pitch(61).second)     // C#
        assertEquals(false, ChordStaffMath.pitch(60).second)
        assertEquals(ChordStaffMath.pitch(60).first, ChordStaffMath.pitch(61).first)   // same letter
        assertEquals(ChordStaffMath.pitch(60).first + 7, ChordStaffMath.pitch(72).first)
        ChordStaffMath.pitch(-5); ChordStaffMath.layout(ChordStaffMath.Clef.BASS, listOf(-5, 0, 3))
    }

    @Test fun guitarBoxWindowAndRows() {
        val e = DemuxChordSegment(4, false, 0, 1)                // E major open shape
        assertEquals(listOf(0, 2, 2, 1, 0, 0), e.guitarFrets)
        assertEquals(1, ChordStaffMath.boxBase(e.guitarFrets))
        assertEquals(1, ChordStaffMath.boxRow(2, 1))
        assertNull(ChordStaffMath.boxRow(0, 1))
        val f = DemuxChordSegment(5, false, 0, 1)                // F barre at fret 1
        assertEquals("1-3-3-2-1-1", f.tabText)
        val b = DemuxChordSegment(11, true, 0, 1)                // Bm barre at 7
        assertEquals(7, ChordStaffMath.boxBase(b.guitarFrets))
        assertEquals(0, ChordStaffMath.boxRow(7, 7)); assertEquals(1, ChordStaffMath.boxRow(9, 7))
        assertNull(ChordStaffMath.boxRow(14, 7))                 // outside the 5-fret window -> not drawn
    }

    @Test fun everyChordHasAGuitarVoicingWithinSixStrings() {
        for (minor in listOf(false, true)) for (root in -3..15) {
            val seg = DemuxChordSegment(root, minor, 0, 1)
            assertEquals(6, seg.guitarFrets.size)
            assertTrue(seg.guitarFrets.filterNotNull().all { it in 0..13 })
            assertEquals(3, seg.pitchClasses.size)
            assertTrue(seg.name.isNotEmpty())
        }
    }
}
