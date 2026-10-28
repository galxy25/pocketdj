package com.levi.pocketdj.screens.producer.instruments

import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.TestEnv
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ScoreCursorTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun stoppedTakeIgnoresTheEnginesStaleGlobalPark() {
        // After a Stop the engine keeps parkedMs=4000; a tap-to-seek sets parked=1000 -> the cursor must follow the tap.
        assertEquals(1000, ScoreCursor.clock(ours = false, enginePos = 4000, parked = 1000))
        assertNull(ScoreCursor.clock(ours = false, enginePos = 4000, parked = null))   // another take's park never leaks in
    }

    @Test fun activeReplayFollowsTheEngine() {
        assertEquals(2500, ScoreCursor.clock(ours = true, enginePos = 2500, parked = 1000))
        assertEquals(1000, ScoreCursor.clock(ours = true, enginePos = null, parked = 1000))
    }

    @Test fun resumeUsesOnlyTheScreensParkAndWrapsAtTheEnd() {
        assertEquals(1000, ScoreCursor.resume(1000, 5000))
        assertEquals(0, ScoreCursor.resume(null, 5000))
        assertEquals(0, ScoreCursor.resume(5000, 5000))
    }

    @Test fun seekIsClamped() {
        assertEquals(0, ScoreCursor.clampSeek(-50, 5000))
        assertEquals(5000, ScoreCursor.clampSeek(9000, 5000))
        assertEquals(0, ScoreCursor.clampSeek(100, -1))
    }

    @Test fun cancelRevertPathLeavesStoreWithNullEditedEvents() {
        val store = TestEnv(tmp.newFolder("studio")).store()
        val ev = StudioNoteEvent(onMs = 0, offMs = 500, note = 60, velocity = 90)
        store.addTake(StudioTake("tk_c", "T", fileName = "take-tk_c.m4a", events = listOf(ev), durationMs = 500))
        val snapshot = store.take("tk_c")!!.editedEvents           // null: derive-from-raw
        store.setTakeEvents("tk_c", listOf(ev.copy(note = 62)))      // an edit
        assertEquals(listOf(ev.copy(note = 62)), store.take("tk_c")!!.editedEvents)
        when (val a = CancelAction.forSnapshot(snapshot)) { is CancelAction.Set -> store.setTakeEvents("tk_c", a.events); CancelAction.Revert -> store.revertTakeEdits("tk_c") }
        assertNull(store.take("tk_c")!!.editedEvents)
    }
}
