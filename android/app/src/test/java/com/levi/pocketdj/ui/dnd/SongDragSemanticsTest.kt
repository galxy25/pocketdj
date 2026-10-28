package com.levi.pocketdj.ui.dnd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SongDragSemanticsTest {
    @Test fun springLoadSwitchesOnlyUnselectedTabs() {
        // The drag must be able to reach Collections from Browse: hovering an unselected tab springs.
        assertTrue(SongDragSemantics.shouldSpringLoad(alreadySelected = false))
        assertFalse(SongDragSemantics.shouldSpringLoad(alreadySelected = true))
        assertTrue(SongDragSemantics.SPRING_LOAD_MS in 200L..1500L)
    }

    @Test fun stationaryLongPressDoesNotStartTransfer() {
        assertFalse(SongDragSemantics.movedPastSlop(0f, 0f, 8f))
        assertFalse(SongDragSemantics.movedPastSlop(3f, 3f, 8f))
        assertTrue(SongDragSemantics.movedPastSlop(8f, 8f, 8f))
        assertTrue(SongDragSemantics.movedPastSlop(0f, -20f, 8f))
    }

    @Test fun pasteMessagesSeparateOutcomes() {
        assertEquals("Nothing to paste", SongDragSemantics.pasteMessage(hadPayload = false, added = false))
        assertEquals("Already in this collection", SongDragSemantics.pasteMessage(hadPayload = true, added = false))
        assertEquals("Pasted songs", SongDragSemantics.pasteMessage(hadPayload = true, added = true))
    }
}
