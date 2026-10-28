package com.levi.pocketdj.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingOpenStoreTest {
    private val a = DeepLink.JukeboxJoin("aaaa", null)
    private val b = DeepLink.CollectionFile("content://x/1")

    @Test fun parkAndDrainPreserveOrder() {
        val s = PendingOpenStore()
        assertTrue(s.park(a)); assertTrue(s.park(b))
        assertEquals(listOf(a, b), s.drain())
        assertTrue(s.isEmpty())
    }

    @Test fun duplicatesParkOnce() {
        val s = PendingOpenStore()
        assertTrue(s.park(a))
        assertFalse(s.park(DeepLink.JukeboxJoin("aaaa", null)))
        assertEquals(1, s.size)
    }

    @Test fun drainIsOneShotAndNoneIsIgnored() {
        val s = PendingOpenStore()
        assertFalse(s.park(DeepLink.None))
        s.park(a)
        assertEquals(1, s.drain().size)
        assertEquals(emptyList<DeepLink>(), s.drain())
    }
}
