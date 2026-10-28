package com.levi.pocketdj.screens.producer.instruments

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.model.StudioTakeStaff
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TakesCopyTest {
    private fun ev(on: Int, off: Int) = StudioNoteEvent(on, off, 60, 90)

    @Test fun subtitleSummarisesInstrumentTempoLengthAndNotes() {
        val t = StudioTake("tk_1", "T", InstrumentKey.BASS_GUITAR, "f", bpm = 96.0, events = listOf(ev(0, 10), ev(20, 30)), durationMs = 65_000)
        assertEquals("Bass Guitar  ·  96 BPM  ·  1:05  ·  2 notes", TakesCopy.subtitle(t))
    }

    @Test fun editedEventsAndExtraStaffsCountTowardsTheSubtitle() {
        val t = StudioTake(
            "tk_1", "T", InstrumentKey.PIANO, "f", bpm = 120.5, events = listOf(ev(0, 10)), editedEvents = listOf(ev(0, 10), ev(5, 9), ev(7, 12)),
            durationMs = 5_000, extraStaffs = listOf(StudioTakeStaff("stf_1", InstrumentKey.VIOLIN, listOf(ev(0, 5)))),
        )
        assertEquals("Piano  ·  120.5 BPM  ·  0:05  ·  4 notes  ·  2 staffs", TakesCopy.subtitle(t))
    }

    @Test fun parseBpmAcceptsDecimalsAndRejectsJunk() {
        assertEquals(97.5, TakesCopy.parseBpm(" 97.5 ")!!, 0.0)
        assertNull(TakesCopy.parseBpm("")); assertNull(TakesCopy.parseBpm("fast")); assertNull(TakesCopy.parseBpm("-4")); assertNull(TakesCopy.parseBpm("NaN"))
    }
}
