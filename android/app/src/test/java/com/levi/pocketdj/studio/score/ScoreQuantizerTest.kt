package com.levi.pocketdj.studio.score

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS ScoreQuantizerTests: fixed events at 120 BPM (one 16th = 125 ms) unless stated. */
class ScoreQuantizerTest {
    private fun ev(on: Int, off: Int, note: Int, vel: Int = 100) = StudioNoteEvent(on, off, note, vel)
    private fun q(vararg e: StudioNoteEvent, bpm: Double = 120.0, inst: InstrumentKey = InstrumentKey.PIANO, min: Int = 0) =
        ScoreQuantizer.quantize(e.toList(), bpm, inst, min)
    private fun notes(vararg n: Int) = ScoreKind.Notes(n.toList())

    @Test fun onsetSnapsToNearestSixteenth() {
        val items = q(ev(130, 380, 60), inst = InstrumentKey.VIOLIN).measures[0].items
        assertEquals(ScoreItem(0, ScoreKind.Rest, NoteDuration.SIXTEENTH), items[0])
        assertEquals(ScoreItem(1, notes(60), NoteDuration.EIGHTH), items[1])
    }

    @Test fun earlyHitClampsToBeatOne() {
        assertEquals(0, q(ev(-30, 220, 60), inst = InstrumentKey.VIOLIN).measures[0].items.first().onset16ths)
    }

    @Test fun sameQuantizedOnsetBecomesOneSortedChord() {
        assertEquals(notes(60, 64, 67), q(ev(0, 250, 67), ev(5, 250, 60), ev(2, 255, 64)).measures[0].items.first().kind)
    }

    @Test fun chordDurationIsLongestMember() {
        assertEquals(NoteDuration.QUARTER, q(ev(0, 125, 60), ev(0, 500, 64)).measures[0].items.first().duration)
    }

    @Test fun restsFillLeadingAndTrailingGaps() {
        assertEquals(
            listOf(
                ScoreItem(0, ScoreKind.Rest, NoteDuration.QUARTER),
                ScoreItem(4, notes(62), NoteDuration.EIGHTH),
                ScoreItem(6, ScoreKind.Rest, NoteDuration.HALF),
                ScoreItem(14, ScoreKind.Rest, NoteDuration.EIGHTH),
            ),
            q(ev(500, 750, 62), inst = InstrumentKey.VIOLIN).measures[0].items,
        )
    }

    @Test fun emptyLeadingMeasureIsAWholeRest() {
        val doc = q(ev(2000, 2250, 60), inst = InstrumentKey.VIOLIN)
        assertEquals(2, doc.measures.size)
        assertEquals(listOf(ScoreItem(0, ScoreKind.Rest, NoteDuration.WHOLE)), doc.measures[0].items)
        assertEquals(notes(60), doc.measures[1].items.first().kind)
    }

    @Test fun everyMeasureSumsToSixteen() {
        val doc = q(ev(0, 900, 60), ev(300, 700, 64), ev(1900, 2600, 67), ev(3100, 3400, 71))
        for (m in doc.measures) assertEquals("measure ${m.index}", 16, m.items.sumOf { it.duration.sixteenths })
    }

    @Test fun dottedDurationsSnap() {
        assertEquals(NoteDuration.DOTTED_EIGHTH, q(ev(0, 375, 60)).measures[0].items.first().duration)
        assertEquals(NoteDuration.DOTTED_QUARTER, q(ev(0, 750, 60)).measures[0].items.first().duration)
        assertEquals(NoteDuration.DOTTED_HALF, q(ev(0, 1500, 60)).measures[0].items.first().duration)
    }

    @Test fun snapTiesRoundDown() {
        assertEquals(NoteDuration.QUARTER, NoteDuration.snapped(5))
        assertEquals(NoteDuration.DOTTED_QUARTER, NoteDuration.snapped(7))
        assertEquals(NoteDuration.HALF, NoteDuration.snapped(10))
        assertEquals(NoteDuration.DOTTED_HALF, NoteDuration.snapped(14))
        assertEquals(NoteDuration.DOTTED_HALF, NoteDuration.snapped(13))
        assertEquals(NoteDuration.WHOLE, NoteDuration.snapped(15))
        assertEquals(NoteDuration.SIXTEENTH, NoteDuration.snapped(0))
        assertEquals(NoteDuration.WHOLE, NoteDuration.snapped(40))
    }

    @Test fun greedyFillIsExactForEveryGap() {
        for (n in 1..16) assertEquals("gap $n", n, NoteDuration.fill(n).sumOf { it.sixteenths })
    }

    @Test fun tapShorterThanASixteenthStillNotates() {
        assertEquals(NoteDuration.SIXTEENTH, q(ev(0, 10, 60)).measures[0].items.first().duration)
    }

    @Test fun overlappingNoteTruncatesAtNextOnset() {
        val items = q(ev(0, 1000, 60), ev(250, 500, 64)).measures[0].items
        assertEquals(ScoreItem(0, notes(60), NoteDuration.EIGHTH), items[0])
        assertEquals(ScoreItem(2, notes(64), NoteDuration.EIGHTH), items[1])
    }

    @Test fun durationTruncatesAtBarline() {
        val doc = q(ev(1750, 2500, 60), inst = InstrumentKey.VIOLIN)
        assertEquals(1, doc.measures.size)
        assertEquals(ScoreItem(14, notes(60), NoteDuration.EIGHTH), doc.measures[0].items.last())
    }

    @Test fun clefPlansPerInstrument() {
        assertEquals(ClefPlan.GRAND_STAFF, ClefPlan.plan(InstrumentKey.PIANO))
        assertEquals(ClefPlan.GRAND_STAFF, ClefPlan.plan(InstrumentKey.HARP))
        assertEquals(ClefPlan.BASS, ClefPlan.plan(InstrumentKey.BASS_GUITAR))
        for (k in listOf(InstrumentKey.VIOLIN, InstrumentKey.TRUMPET, InstrumentKey.CLARINET, InstrumentKey.ACOUSTIC_GUITAR)) assertEquals(ClefPlan.TREBLE, ClefPlan.plan(k))
    }

    @Test fun grandStaffSplitsAtMiddleC() {
        assertEquals(StaffRole.TREBLE, ClefPlan.GRAND_STAFF.staff(60))
        assertEquals(StaffRole.BASS, ClefPlan.GRAND_STAFF.staff(59))
        assertEquals(StaffRole.BASS, ClefPlan.BASS.staff(100))
        assertEquals(StaffRole.TREBLE, ClefPlan.TREBLE.staff(10))
    }

    @Test fun emptyEventsAndOutOfRangeNotes() {
        assertTrue(q().measures.isEmpty())
        assertTrue(q(ev(0, 250, 128), ev(0, 250, -1)).measures.isEmpty())
    }

    @Test fun zeroBpmGuardsToDefault() {
        val doc = q(ev(0, 500, 60), bpm = 0.0)
        assertEquals(120.0, doc.bpm, 0.0)
        assertEquals(NoteDuration.QUARTER, doc.measures[0].items.first().duration)
    }

    @Test fun minMeasuresPadsEmptyTrailingBars() {
        val doc = q(ev(0, 250, 60), min = 4)
        assertEquals(4, doc.measures.size)
        for (i in 1..3) assertEquals(listOf(ScoreItem(0, ScoreKind.Rest, NoteDuration.WHOLE)), doc.measures[i].items)
        assertEquals(1, q(ev(0, 250, 60), min = 0).measures.size)
        assertEquals(1, q(ev(0, 250, 60), min = 1).measures.size)       // below content is a no-op
        assertEquals(3, q(min = 3).measures.size)                          // empty score still pads
    }

    @Test fun eventAccidentalRidesIntoSpellings() {
        val doc = q(StudioNoteEvent(0, 500, 63, 90, Accidental.FLAT))
        assertEquals(mapOf(63 to Accidental.FLAT), doc.measures[0].items.first().spellings)
    }

    // ---- playhead
    private val slots = ScorePlayhead.timeline(listOf(ev(0, 250, 60), ev(500, 1000, 62)), 120.0)

    @Test fun timelineIsOnsetOrderedWithRawEnds() {
        assertEquals(listOf(ScorePlayhead.Slot(0, 2), ScorePlayhead.Slot(4, 8)), slots)
    }

    @Test fun timelineCollapsesChordAndGivesMinimumLength() {
        val s = ScorePlayhead.timeline(listOf(ev(0, 500, 60), ev(0, 250, 64), ev(1000, 1000, 67)), 120.0)
        assertEquals(listOf(ScorePlayhead.Slot(0, 4), ScorePlayhead.Slot(8, 9)), s)
    }

    @Test fun stateIdleBeforeAndDuringNotes() {
        assertEquals(ScorePlaybackState.IDLE, ScorePlayhead.state(null, slots, 120.0))
        val pre = ScorePlayhead.state(-5, emptyList(), 120.0)
        assertNull(pre.currentOnset16ths)
        val s = ScorePlayhead.state(600, slots, 120.0)     // 4.8 sixteenths: inside slot 4..8
        assertEquals(4, s.currentOnset16ths); assertTrue(s.isSounding)
        assertTrue(s.isPlayed(0)); assertTrue(!s.isPlayed(4)); assertTrue(s.isCurrent(4))
    }

    @Test fun stateInARestHoldsLastNote() {
        val s = ScorePlayhead.state(300, slots, 120.0)      // 2.4: after slot 0..2, before slot 4
        assertEquals(0, s.currentOnset16ths); assertTrue(!s.isSounding)
        val end = ScorePlayhead.state(60_000, slots, 120.0)
        assertEquals(4, end.currentOnset16ths); assertTrue(!end.isSounding)
    }

    @Test fun cursorClampsAndNeverTraps() {
        assertEquals(0.0, ScorePlayhead.cursor16ths(-100, 120.0), 0.0)
        assertEquals(8.0, ScorePlayhead.cursor16ths(1000, 120.0), 1e-9)
        assertEquals(0, ScorePlayhead.ms(Double.NaN, 120.0))
        assertEquals(ScorePlayhead.MAX_CURSOR_MS.toInt(), ScorePlayhead.ms(1e300, 120.0))
        assertEquals(1000, ScorePlayhead.ms(8.0, 120.0))
        for (ms in listOf(0, 125, 1000, 33333)) assertEquals(ms, ScorePlayhead.ms(ScorePlayhead.cursor16ths(ms, 120.0), 120.0))
    }
}
