package com.levi.pocketdj.studio.score

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS ScoreLayoutTests: geometry INVARIANTS (reading order, inverses, playhead/tap agreement), not pixels. */
class ScoreLayoutTest {
    private fun note(onset: Int, midi: Int, d: NoteDuration = NoteDuration.QUARTER) = ScoreItem(onset, ScoreKind.Notes(listOf(midi)), d)
    private fun doc(measures: List<ScoreMeasure>, plan: ClefPlan = ClefPlan.TREBLE) = ScoreDocument(measures, 120.0, plan)
    private fun empties(n: Int) = (0 until n).map { ScoreMeasure(it, emptyList()) }.toMutableList()
    private fun pages(d: ScoreDocument, inst: InstrumentKey = InstrumentKey.VIOLIN) = ScoreLayout.paginate(d, "T", inst)
    private fun headXs(p: ScorePage) = p.glyphs.filterIsInstance<ScoreGlyph.NoteHead>().map { it.center.x }
    private fun set(ms: MutableList<ScoreMeasure>, i: Int, vararg items: ScoreItem) { ms[i] = ScoreMeasure(i, items.toList()) }

    @Test fun xPositionStrictlyMonotonic() {
        val xs = (0..15).map { ScoreLayout.xPosition(it, 100f, 120f) }
        for (i in 1 until xs.size) assertTrue(xs[i - 1] < xs[i])
        assertTrue(xs.first() > 100f); assertTrue(xs.last() < 220f)
    }

    @Test fun headsIncreaseAcrossAMeasure() {
        val xs = headXs(pages(doc(listOf(ScoreMeasure(0, listOf(note(0, 64), note(4, 67), note(8, 71), note(12, 72))))))[0])
        assertEquals(4, xs.size)
        for (i in 1 until xs.size) assertTrue(xs[i - 1] < xs[i])
    }

    @Test fun staffPositionReferenceNotes() {
        assertEquals(0, ScoreLayout.staffPosition(64, StaffRole.TREBLE).position)
        assertEquals(-2, ScoreLayout.staffPosition(60, StaffRole.TREBLE).position)
        assertEquals(8, ScoreLayout.staffPosition(77, StaffRole.TREBLE).position)
        assertEquals(0, ScoreLayout.staffPosition(43, StaffRole.BASS).position)
        assertEquals(10, ScoreLayout.staffPosition(60, StaffRole.BASS).position)
    }

    @Test fun blackKeysSpellAsSharps() {
        val cs = ScoreLayout.staffPosition(61, StaffRole.TREBLE)
        assertEquals(-2, cs.position); assertTrue(cs.sharp)
        assertTrue(!ScoreLayout.staffPosition(60, StaffRole.TREBLE).sharp)
    }

    @Test fun spelledPositionHonoursOverrides() {
        val t = StaffRole.TREBLE
        assertEquals(ScoreLayout.SpelledPos(0, ScoreLayout.RenderedAccidental.NATURAL), ScoreLayout.spelledPosition(64, t, null))
        assertEquals(ScoreLayout.SpelledPos(-2, ScoreLayout.RenderedAccidental.SHARP), ScoreLayout.spelledPosition(61, t, null))
        assertEquals(ScoreLayout.SpelledPos(0, ScoreLayout.RenderedAccidental.FLAT), ScoreLayout.spelledPosition(63, t, Accidental.FLAT))
        assertEquals(ScoreLayout.SpelledPos(-2, ScoreLayout.RenderedAccidental.SHARP), ScoreLayout.spelledPosition(61, t, Accidental.SHARP))
        assertEquals(ScoreLayout.RenderedAccidental.NATURAL, ScoreLayout.spelledPosition(60, t, Accidental.NATURAL).accidental)
        assertEquals(ScoreLayout.RenderedAccidental.SHARP, ScoreLayout.spelledPosition(61, t, Accidental.NATURAL).accidental)
    }

    @Test fun locateRoundTripsNotePointTreble() {
        val pg = pages(doc(listOf(ScoreMeasure(0, listOf(note(4, 64))))))
        val np = ScoreLayout.notePoint(64, null, 4, ClefPlan.TREBLE, pg)!!
        val loc = ScoreLayout.locate(np.point, pg[np.page])!!
        assertEquals(0, loc.measureIndex); assertEquals(4, loc.onset16ths); assertEquals(StaffRole.TREBLE, loc.staff); assertEquals(0, loc.position)
        assertEquals(64, ScoreLayout.naturalMidi(loc.position, loc.staff))
    }

    @Test fun locateRoundTripsGrandStaffBassInLaterMeasure() {
        val ms = empties(6); set(ms, 5, note(8, 48))
        val pg = pages(doc(ms, ClefPlan.GRAND_STAFF), InstrumentKey.PIANO)
        val np = ScoreLayout.notePoint(48, null, 5 * 16 + 8, ClefPlan.GRAND_STAFF, pg)!!
        val loc = ScoreLayout.locate(np.point, pg[np.page])!!
        assertEquals(5, loc.measureIndex); assertEquals(8, loc.onset16ths); assertEquals(StaffRole.BASS, loc.staff)
        assertEquals(48, ScoreLayout.naturalMidi(loc.position, StaffRole.BASS))
    }

    @Test fun naturalMidiInvertsStaffPositionIncludingLowLedgerNotes() {
        for ((midi, clef) in listOf(64 to StaffRole.TREBLE, 60 to StaffRole.TREBLE, 77 to StaffRole.TREBLE, 43 to StaffRole.BASS, 48 to StaffRole.BASS, 24 to StaffRole.BASS, 12 to StaffRole.TREBLE)) {
            assertEquals(midi, ScoreLayout.naturalMidi(ScoreLayout.staffPosition(midi, clef).position, clef))
        }
    }

    @Test fun onsetFromXInvertsXPosition() {
        for (o in 0..15) assertEquals(o, ScoreLayout.onsetFromX(ScoreLayout.xPosition(o, 100f, 240f), 100f, 240f))
    }

    @Test fun locateNeverProducesAWildPosition() {
        val pg = pages(doc(listOf(ScoreMeasure(0, listOf(note(4, 64))))))
        val sys = pg[0].systems[0]
        val x = sys.measures[0].x + 40f
        val top = sys.strips[0].top - 3 * sys.spacing
        // far above/below the band is a miss, inside the band positions stay small and sane
        assertNull(ScoreLayout.locate(Pt(x, -1e30f), pg[0]))
        assertNull(ScoreLayout.locate(Pt(Float.NaN, top), pg[0]))
        val loc = ScoreLayout.locate(Pt(x, top + 0.5f), pg[0])!!
        assertTrue(loc.position in -400..400)
        assertTrue(loc.position != Int.MIN_VALUE)
    }

    @Test fun playheadXMatchesNoteHeadX() {
        val ms = empties(6); set(ms, 0, note(4, 64)); set(ms, 5, note(8, 67))
        val pg = pages(doc(ms))
        for ((abs16, midi) in listOf(4 to 64, 5 * 16 + 8 to 67)) {
            val np = ScoreLayout.notePoint(midi, null, abs16, ClefPlan.TREBLE, pg)!!
            val ph = ScoreLayout.playhead(abs16.toDouble(), pg)!!
            assertEquals(np.page, ph.page)
            assertEquals(np.point.x, ph.x, 1e-3f)
            assertTrue(ph.top < np.point.y); assertTrue(ph.bottom > np.point.y)
        }
    }

    @Test fun playheadMonotonicParksAndRejectsNonFinite() {
        val pg = pages(doc(listOf(ScoreMeasure(0, listOf(note(0, 64))))))
        val xs = generateSequence(0.0) { it + 0.5 }.takeWhile { it <= 15.0 }.map { ScoreLayout.playhead(it, pg)!!.x }.toList()
        assertEquals(31, xs.size)
        for (i in 1 until xs.size) assertTrue(xs[i - 1] < xs[i])
        assertTrue(ScoreLayout.playhead(999.0, pg)!!.x > ScoreLayout.playhead(15.9, pg)!!.x)
        assertNull(ScoreLayout.playhead(Double.POSITIVE_INFINITY, pg))
        assertNull(ScoreLayout.playhead(Double.NaN, pg))
        assertNotNull(ScoreLayout.playhead(-5.0, pg))
        assertNull(ScoreLayout.playhead(0.0, pages(doc(emptyList()))))
    }

    @Test fun playedMarksMatchNotePointForEveryNote() {
        val events = listOf(StudioNoteEvent(0, 500, 48, 90), StudioNoteEvent(0, 500, 64, 90), StudioNoteEvent(1000, 1500, 72, 90))
        val score = ScoreQuantizer.quantize(events, 120.0, InstrumentKey.PIANO)
        val pg = ScoreLayout.paginate(score, "T", InstrumentKey.PIANO)
        val marks = ScoreLayout.playedMarks(events, 120.0, ClefPlan.GRAND_STAFF, pg)
        assertEquals(listOf(0, 0, 8), marks.map { it.onset16ths })
        for ((e, abs16) in events.zip(listOf(0, 0, 8))) {
            val np = ScoreLayout.notePoint(e.note, null, abs16, ClefPlan.GRAND_STAFF, pg)!!
            assertTrue(marks.any { it.onset16ths == abs16 && it.page == np.page && Math.abs(it.point.x - np.point.x) < 1e-3f && Math.abs(it.point.y - np.point.y) < 1e-3f })
        }
        assertTrue(ScoreLayout.playedMarks(emptyList(), 120.0, ClefPlan.TREBLE, pg).isEmpty())
        assertTrue(ScoreLayout.playedMarks(events, 120.0, ClefPlan.TREBLE, emptyList()).isEmpty())
    }

    @Test fun fractional16thsInvertsXPosition() {
        for (t in listOf(0.0, 0.25, 1.0, 3.5, 4.0, 8.0, 12.75, 15.0, 15.9, 16.0))
            assertEquals(t, ScoreLayout.fractional16ths(ScoreLayout.xPosition(t, 100f, 240f), 100f, 240f), 1e-5)
        assertEquals(0.0, ScoreLayout.fractional16ths(-500f, 100f, 240f), 0.0)
        assertEquals(16.0, ScoreLayout.fractional16ths(5000f, 100f, 240f), 0.0)
        assertEquals(0.0, ScoreLayout.fractional16ths(150f, 100f, 4f), 0.0)
        assertEquals(0.0, ScoreLayout.fractional16ths(Float.NaN, 100f, 240f), 0.0)
    }

    @Test fun time16thsInvertsThePlayheadOnALaidScore() {
        val ms = empties(40); set(ms, 0, note(0, 64)); set(ms, 5, note(8, 67)); set(ms, 39, note(12, 72))
        val pg = pages(doc(ms))
        assertTrue("fixture must paginate", pg.size > 1)
        for (t in listOf(0.0, 4.0, 4.5, 16.0, 63.9, 64.0, 5.0 * 16 + 8, 39.0 * 16 + 12, 39.0 * 16 + 15.5)) {
            val ph = ScoreLayout.playhead(t, pg)!!
            val back = ScoreLayout.time16ths(Pt(ph.x, (ph.top + ph.bottom) / 2), pg[ph.page])!!
            assertEquals("at $t", t, back, 1e-3)
        }
    }

    @Test fun time16thsPastTheEndResolvesToTheScoreEnd() {
        val pg = pages(doc(listOf(ScoreMeasure(0, listOf(note(0, 64))))))
        val ph = ScoreLayout.playhead(999.0, pg)!!
        val y = (ph.top + ph.bottom) / 2
        assertEquals(16.0, ScoreLayout.time16ths(Pt(ph.x, y), pg[ph.page])!!, 1e-3)
        assertEquals(16.0, ScoreLayout.time16ths(Pt(100_000f, y), pg[ph.page])!!, 1e-3)
    }

    @Test fun tapsOffTheStaffSeekTheNearestSystemButNeverEnterNotes() {
        val ms = empties(8); set(ms, 0, note(0, 64))
        val page = pages(doc(ms))[0]
        val s0 = page.systems[0]; val s1 = page.systems[1]
        val x = s0.measures[0].x + s0.measures[0].width / 2
        val gap0 = s0.strips.last().top + 4 * s0.spacing + 3 * s0.spacing
        val gap1 = s1.strips.first().top - 3 * s1.spacing
        assertTrue(ScoreLayout.time16ths(Pt(x, gap0 + 1), page)!! < 64)
        assertTrue(ScoreLayout.time16ths(Pt(x, gap1 - 1), page)!! >= 64)
        val head = Pt(s0.measures[0].x + 1, 4f)
        assertEquals(0.0, ScoreLayout.time16ths(head, page)!!, 1e-3)
        assertNotNull(ScoreLayout.time16ths(Pt(x, 10_000f), page))
        assertNull(ScoreLayout.locate(Pt(x, gap0 + 1), page))
        assertNull(ScoreLayout.locate(head, page))
        assertNull(ScoreLayout.time16ths(Pt(200f, Float.NaN), page))
        assertNull(ScoreLayout.time16ths(Pt(Float.POSITIVE_INFINITY, 20f), page))
        val empty = pages(doc(emptyList()))[0]
        assertTrue(empty.systems.isEmpty())
        assertNull(ScoreLayout.time16ths(Pt(200f, 200f), empty))
    }

    @Test fun tapInMeasuresRightPadIsTheNextBarsDownbeat() {
        val ms = empties(8); set(ms, 1, note(0, 64))
        val pg = pages(doc(ms)); val page = pg[0]; val sys = page.systems[0]
        val m0 = sys.measures[0]; val m1 = sys.measures[1]
        val y = sys.strips[0].top + 2 * sys.spacing
        val t = ScoreLayout.time16ths(Pt(m0.x + m0.width - 2, y), page)!!
        assertEquals(16.0, t, 1e-6)
        assertEquals(ScoreLayout.xPosition(0.0, m1.x, m1.width), ScoreLayout.playhead(t, pg)!!.x, 1e-3f)
        assertEquals(16.0, ScoreLayout.time16ths(Pt(m1.x + 1, y), page)!!, 1e-6)
        var prev = -1.0
        var x = m0.x + 1
        while (x < m1.x + m1.width - 1) { val v = ScoreLayout.time16ths(Pt(x, y), page) ?: -1.0; assertTrue(v >= prev); prev = v; x += 3f }
    }

    @Test fun locateAndTime16thsAgreeOnTheTappedMeasure() {
        val ms = empties(12); set(ms, 7, note(4, 64))
        val pg = pages(doc(ms))
        val np = ScoreLayout.notePoint(64, null, 7 * 16 + 4, ClefPlan.TREBLE, pg)!!
        val loc = ScoreLayout.locate(np.point, pg[np.page])!!
        val t = ScoreLayout.time16ths(np.point, pg[np.page])!!
        assertEquals(7, loc.measureIndex)
        assertEquals(7, t.toInt() / 16)
        assertEquals(loc.onset16ths, Math.round(t).toInt() % 16)
    }

    @Test fun seekingToANoteHeadYieldsTheStateOfPlayingThere() {
        val events = listOf(StudioNoteEvent(0, 250, 64, 90), StudioNoteEvent(500, 900, 67, 90), StudioNoteEvent(2500, 2900, 72, 90))
        val score = ScoreQuantizer.quantize(events, 120.0, InstrumentKey.VIOLIN)
        val pg = ScoreLayout.paginate(score, "T", InstrumentKey.VIOLIN)
        val slots = ScorePlayhead.timeline(events, 120.0)
        val head = ScoreLayout.notePoint(67, null, 4, ClefPlan.TREBLE, pg)!!
        val t = ScoreLayout.time16ths(head.point, pg[head.page])!!
        val ms = ScorePlayhead.ms(t, 120.0)
        assertEquals(500, ms)
        val seeked = ScorePlayhead.state(ms, slots, 120.0)
        assertEquals(ScorePlayhead.state(500, slots, 120.0), seeked)
        assertEquals(4, seeked.currentOnset16ths); assertTrue(seeked.isSounding)
        assertTrue(seeked.isPlayed(0)); assertTrue(!seeked.isPlayed(20))
    }

    @Test fun grandStaffDrawsBothClefsAndSplitsAChord() {
        val chord = ScoreMeasure(0, listOf(ScoreItem(0, ScoreKind.Notes(listOf(48, 64)), NoteDuration.QUARTER)))
        val page = pages(doc(listOf(chord), ClefPlan.GRAND_STAFF), InstrumentKey.PIANO)[0]
        assertEquals(listOf(StaffRole.TREBLE, StaffRole.BASS), page.glyphs.filterIsInstance<ScoreGlyph.Clef>().map { it.role })
        val ys = page.glyphs.filterIsInstance<ScoreGlyph.NoteHead>().map { it.center.y }
        assertEquals(2, ys.size)
        assertTrue(Math.abs(ys[0] - ys[1]) > ScoreLayout.Metrics.A4.grandStaffGap)
    }

    @Test fun emptyScoreIsOneHeaderOnlyPageAndManyMeasuresPaginate() {
        val empty = pages(doc(emptyList()))
        assertEquals(1, empty.size)
        assertTrue(empty[0].glyphs.any { it is ScoreGlyph.Text })
        val many = pages(doc(empties(60).also { for (i in it.indices) it[i] = ScoreMeasure(i, listOf(ScoreItem(0, ScoreKind.Rest, NoteDuration.WHOLE))) }))
        assertTrue(many.size >= 2)
        // measures are laid in order across pages
        val idx = many.flatMap { p -> p.systems.flatMap { s -> s.measures.map { it.measureIndex } } }
        assertEquals((0 until 60).toList(), idx)
    }

    @Test fun systemsGivesOnePagePerSystemWithoutAHeader() {
        val sys = ScoreLayout.systems(doc(empties(9)), InstrumentKey.VIOLIN)
        assertEquals(3, sys.size)
        assertTrue(sys.all { it.systems.size == 1 && it.glyphs.none { g -> g is ScoreGlyph.Text } })
    }
}
