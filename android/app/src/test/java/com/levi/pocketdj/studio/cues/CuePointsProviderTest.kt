package com.levi.pocketdj.studio.cues

import com.levi.pocketdj.studio.model.StudioCue
import com.levi.pocketdj.studio.store.TestEnv
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CuePointsProviderTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }

    @Test fun eighthSlotSucceedsAndNinthIsRefused() {
        val store = env.store()
        val p = StudioCuePointsProvider { store }
        repeat(8) { assertNotNull("slot $it", p.dropAtNextFree("sng_1", it * 1000)) }
        assertEquals((0..7).toList(), p.cues("sng_1").map { it.slot })
        assertNull(p.dropAtNextFree("sng_1", 9000))
        assertFalse(p.setCue("sng_1", 8, 9000))            // out of range refused by the store
        assertEquals(8, p.cues("sng_1").size)
    }

    @Test fun dropFillsTheLowestFreeSlotAfterADelete() {
        val store = env.store()
        val p = StudioCuePointsProvider { store }
        repeat(3) { p.dropAtNextFree("s", it) }
        store.removeCue("s", 1)
        assertEquals(1, p.dropAtNextFree("s", 500)!!.slot)
    }

    @Test fun deckAndEditorShareOneStoreAndChangesEmit() {
        val store = env.store()
        val p = StudioCuePointsProvider { store }
        assertTrue(p.setCue("s", 2, -10))                  // negative clamps like the store
        assertEquals(0, p.cues("s").single().positionMs)
        store.nudgeCue("s", 2, 100); store.renameCue("s", 2, "  Hook  ")
        val c = p.cues("s").single()
        assertEquals(100, c.positionMs); assertEquals("Hook", c.name)
        assertEquals(StudioCue.MAX_SLOTS, 8)
    }
}
