package com.levi.pocketdj.shell

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull

class SyncEntryHookTest {
    @Test fun defaultHasNoPullHook() {
        assertNull(SyncEntry("k", "f.json").onPulled)
    }

    @Test fun pullHookIsInvoked() {
        var n = 0
        SyncEntry("game-scores", "f.json", onPulled = { n++ }).onPulled!!.invoke()
        assertEquals(1, n)
    }
}
