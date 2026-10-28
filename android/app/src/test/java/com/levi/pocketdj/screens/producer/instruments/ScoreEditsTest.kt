package com.levi.pocketdj.screens.producer.instruments

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.score.ClefPlan
import com.levi.pocketdj.studio.score.NoteDuration
import com.levi.pocketdj.studio.score.ScoreLayout
import com.levi.pocketdj.studio.score.ScoreQuantizer
import com.levi.pocketdj.studio.score.StaffRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The score editor's pure logic: value-based selection, multi-step undo, cursor/bars, edits, Cancel semantics, live-save shaping. */
class ScoreEditsTest {
    private val edits = ScoreEdits(120.0, InstrumentKey.PIANO)     // 16th = 125 ms
    private fun ev(on: Int, off: Int, n: Int, acc: Accidental? = null) = StudioNoteEvent(on, off, n, 90, acc)
    private val a = ev(0, 250, 60)
    private val b = ev(500, 750, 64)
    private val c = ev(1000, 1500, 67)

    @Test fun selectionIsByValueAndSurvivesAHostReSort() {
        var st = ScoreEditState(mode = ScoreEditMode.EDIT, selection = setOf(b))
        val events = listOf(a, b, c)
        val reSorted = listOf(c, b, a)                                   // the live host re-sorts on commit
        assertEquals(listOf(b), edits.selected(reSorted, st))
        val r = edits.moveSemitone(reSorted, st, 1)!!
        assertEquals(listOf(c, b.copy(note = 65), a), r.events)          // the same note moved, wherever it sits now
        assertEquals(setOf(b.copy(note = 65)), r.state.selection)       // selection follows the NEW value
        st = r.state
        assertEquals(listOf(b.copy(note = 65)), edits.selected(r.events!!.sortedBy { it.onMs }, st))
        assertEquals(events.size, r.events!!.size)
    }

    @Test fun undoIsMultiStepAndClearsSelection() {
        var events = listOf(a)
        var st = ScoreEditState(selection = setOf(a))
        val r1 = edits.moveSemitone(events, st, 2)!!; events = r1.events!!; st = r1.state
        val r2 = edits.deleteSelected(events, st)!!; events = r2.events!!; st = r2.state
        assertTrue(events.isEmpty()); assertEquals(2, st.undo.size)
        val u1 = edits.undo(st)!!; events = u1.events!!; st = u1.state
        assertEquals(listOf(a.copy(note = 62)), events)
        assertTrue(st.selection.isEmpty())
        assertEquals(1, st.undo.size)
        val u2 = edits.undo(st)!!; events = u2.events!!; st = u2.state
        assertEquals(listOf(a), events)
        assertNull(edits.undo(st))
    }

    @Test fun moveSemitoneClampsAndDropsSpelling() {
        val e = ev(0, 100, 127, Accidental.FLAT)
        val r = edits.moveSemitone(listOf(e), ScoreEditState(selection = setOf(e)), 5)!!
        assertEquals(127, r.events!![0].note); assertNull(r.events!![0].accidental)
        assertNull(edits.moveSemitone(listOf(a), ScoreEditState(), 1))    // nothing selected
    }

    @Test fun moveStepMovesTheGroupTogetherNeverBeforeZero() {
        val st = ScoreEditState(selection = setOf(a, b))
        val back = edits.moveStep(listOf(a, b), st, -1)
        assertNull(back)                                                  // a is already at 0
        val fwd = edits.moveStep(listOf(a, b), st, 1)!!
        assertEquals(listOf(a.copy(onMs = 125, offMs = 375), b.copy(onMs = 625, offMs = 875)), fwd.events)
        val st2 = ScoreEditState(selection = setOf(b))
        assertEquals(375, edits.moveStep(listOf(a, b), st2, -1)!!.events!![1].onMs)
    }

    @Test fun duplicateCopiesAOneBarLaterAndSelectsTheCopies() {
        val r = edits.duplicate(listOf(a), ScoreEditState(selection = setOf(a)))!!
        assertEquals(listOf(a, a.copy(onMs = 2000, offMs = 2250)), r.events)
        assertEquals(setOf(a.copy(onMs = 2000, offMs = 2250)), r.state.selection)
    }

    @Test fun setLengthSnapsToGridAndSetsThePen() {
        val r = edits.setLength(listOf(a), ScoreEditState(selection = setOf(a)), NoteDuration.HALF)!!
        assertEquals(1000, r.events!![0].offMs)
        assertEquals(NoteDuration.HALF, r.state.penLength)
        val none = edits.setLength(listOf(a), ScoreEditState(), NoteDuration.WHOLE)!!      // no selection: pen only
        assertNull(none.events); assertEquals(NoteDuration.WHOLE, none.state.penLength)
    }

    @Test fun setAccidentalRespellsOnTheSameStaffLine() {
        val st = ScoreEditState(selection = setOf(a))              // C4
        val sharp = edits.setAccidental(listOf(a), st, Accidental.SHARP)!!.events!![0]
        assertEquals(61, sharp.note); assertEquals(Accidental.SHARP, sharp.accidental)
        val flat = edits.setAccidental(listOf(ev(0, 250, 63)), ScoreEditState(selection = setOf(ev(0, 250, 63))), Accidental.FLAT)!!.events!![0]
        assertEquals(61, flat.note)                                // D#4 sits on the D line; re-spelled flat on that line = Db (61)
        assertEquals(Accidental.FLAT, flat.accidental)
        val nat = edits.setAccidental(listOf(sharp), ScoreEditState(selection = setOf(sharp)), Accidental.NATURAL)!!.events!![0]
        assertEquals(60, nat.note); assertNull(nat.accidental)
    }

    @Test fun enterPlacesWithThePenAndReselectsAnExistingNote() {
        val loc = ScoreLayout.Located(measureIndex = 1, onset16ths = 4, staff = StaffRole.TREBLE, position = 0)   // E4 at bar 1 beat 2
        val st = ScoreEditState(penLength = NoteDuration.HALF, penAccidental = Accidental.SHARP)
        val r = edits.place(emptyList(), st, loc)
        val n = r.events!!.single()
        assertEquals(65, n.note); assertEquals(Accidental.SHARP, n.accidental)
        assertEquals(2500, n.onMs); assertEquals(3500, n.offMs); assertEquals(96, n.velocity)
        assertEquals(setOf(n), r.state.selection); assertEquals(1, r.state.undo.size)
        // Same time + pitch again: SELECT, never stack an invisible duplicate.
        val first = edits.place(emptyList(), st, loc)
        val again = edits.place(first.events!!, first.state, loc)
        assertNull(again.events)
        assertEquals(first.events!!.toSet(), again.state.selection)
    }

    @Test fun tapNoteTogglesAndEmptySpaceClearsOnlyInSelect() {
        val st = ScoreEditState(mode = ScoreEditMode.SELECT)
        val on = edits.tapNote(st, a)
        assertEquals(setOf(a), on.selection)
        assertTrue(edits.tapNote(on, a).selection.isEmpty())
        assertTrue(edits.tapNote(on, null).selection.isEmpty())
        val move = on.copy(mode = ScoreEditMode.MOVE)
        assertEquals(setOf(a), edits.tapNote(move, null).selection)
    }

    @Test fun toggleBarSelectsAndDeselectsAWholeBar() {
        val events = listOf(a, b, ev(2000, 2250, 62))
        val on = edits.toggleBar(events, ScoreEditState(), 0)
        assertEquals(setOf(a, b), on.selection)
        assertTrue(edits.toggleBar(events, on, 0).selection.isEmpty())
        assertEquals(on, edits.toggleBar(events, on, 5))                  // empty bar: no-op
    }

    @Test fun cursorWalksNotesThenGrowsAnEmptyBar() {
        val events = listOf(a, b, c)
        var st = edits.enterSelectMode(events, ScoreEditState(mode = ScoreEditMode.SELECT))
        assertEquals(setOf(c), st.selection); assertEquals(8, st.cursor)    // the LAST note
        st = edits.moveCursor(events, st, -1); assertEquals(setOf(b), st.selection); assertEquals(4, st.cursor)
        st = edits.moveCursor(events, st, -1); assertEquals(setOf(a), st.selection)
        st = edits.moveCursor(events, st, -1); assertEquals(setOf(a), st.selection)       // at the start: stays
        st = edits.moveCursor(events, st, 1).let { edits.moveCursor(events, it, 1) }; assertEquals(setOf(c), st.selection)
        val grown = edits.moveCursor(events, st, 1)
        assertTrue(grown.selection.isEmpty())
        assertEquals(2, grown.minBars); assertEquals(16, grown.cursor)       // content is 1 bar -> a 2nd, empty bar
    }

    @Test fun barGranularityCursorSelectsBarsAndGrows() {
        val events = listOf(a, ev(2000, 2250, 62))
        var st = ScoreEditState(mode = ScoreEditMode.SELECT, granularity = ScoreGranularity.BAR)
        st = edits.moveCursor(events, st, 1)
        assertEquals(16, st.cursor); assertEquals(setOf(events[1]), st.selection)
        st = edits.moveCursor(events, st, 1)
        assertEquals(3, st.minBars); assertTrue(st.selection.isEmpty())       // grew to include bar 2
    }

    @Test fun addAndRemoveBarNeverDeleteNotes() {
        val events = listOf(a)
        var st = ScoreEditState()
        assertEquals(1, edits.barCount(events, st))
        assertEquals(st, edits.removeBar(events, st))                          // last bar has a note: refuse
        st = edits.addBar(events, st); assertEquals(2, edits.barCount(events, st)); assertTrue(edits.lastBarEmpty(events, st))
        st = edits.removeBar(events, st); assertEquals(1, edits.barCount(events, st))
        // and the padded bars really render as whole rests
        val padded = ScoreQuantizer.quantize(events, 120.0, InstrumentKey.PIANO, edits.barCount(events, edits.addBar(events, ScoreEditState())))
        assertEquals(2, padded.measures.size)
    }

    @Test fun nearestNoteSnapsOnlyWhenReasonablyClose() {
        val events = listOf(a, b)
        val doc = ScoreQuantizer.quantize(events, 120.0, InstrumentKey.PIANO)
        val pages = ScoreLayout.paginate(doc, "T", InstrumentKey.PIANO)
        val np = ScoreLayout.notePoint(64, null, 4, ClefPlan.GRAND_STAFF, pages)!!
        assertEquals(b, edits.nearestNote(events, pages, np.page, np.point.let { com.levi.pocketdj.studio.score.Pt(it.x + 3f, it.y + 2f) }))
        assertNull(edits.nearestNote(events, pages, np.page, com.levi.pocketdj.studio.score.Pt(5f, 800f)))
        assertNull(edits.nearestNote(events, pages, 9, np.point))
    }

    @Test fun syncPenFollowsTheTouchedNote() {
        val st = edits.syncPen(ScoreEditState(), ev(0, 1000, 61, Accidental.SHARP))
        assertEquals(NoteDuration.HALF, st.penLength); assertEquals(Accidental.SHARP, st.penAccidental)
        assertNotNull(edits.hint(st))
    }

    // ---- Cancel + live save
    @Test fun cancelRestoresSnapshotOrRevertsDeriveFromRaw() {
        assertEquals(CancelAction.Revert, CancelAction.forSnapshot(null))        // editedEvents was nil -> must go back to nil, not be pinned
        assertEquals(CancelAction.Set(listOf(a)), CancelAction.forSnapshot(listOf(a)))
        assertEquals(CancelAction.Set(emptyList()), CancelAction.forSnapshot(emptyList()))   // an explicitly-empty edit is still an edit
    }

    @Test fun liveSaveShapesATake() {
        assertNull(LiveStaffSave.result(emptyList(), InstrumentKey.PIANO))
        val r = LiveStaffSave.result(listOf(a, c), InstrumentKey.HARP) { "tk_x" }!!
        assertEquals("tk_x", r.takeId); assertEquals(120.0, r.bpm, 0.0); assertEquals(InstrumentKey.HARP, r.instrument)
        assertEquals(1500, r.durationMs); assertTrue(r.fileName.contains("tk_x"))
        assertEquals(500, LiveStaffSave.result(listOf(ev(0, 10, 60)), InstrumentKey.PIANO)!!.durationMs)   // floor
    }

    @Test fun exportNamesAreFilesystemSafe() {
        fun take(n: String) = StudioTake(id = "t", name = n, fileName = "f")
        assertEquals("a-b-c", ScoreExport.baseName(take("a/b:c")))
        assertEquals("Untitled instrumental", ScoreExport.baseName(take("")))
        assertEquals("Instrumental", ScoreExport.baseName(take("   ")))
        assertEquals("Song", ScoreExport.primaryStaffTitle(take("Song")))
    }
}
