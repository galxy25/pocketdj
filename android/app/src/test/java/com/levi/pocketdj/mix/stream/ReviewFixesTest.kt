package com.levi.pocketdj.mix.stream

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class ReviewFixesTest {
    @Test fun seededFlagIsCorrectOnFirstReadAndThrottlesRefresh() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val reads = AtomicInteger()
        val now = AtomicLong(0)
        val flag = SeededFlag({ reads.incrementAndGet(); true }, scope, initial = true, clock = { now.get() })
        repeat(50) { assertTrue(flag.get()) } // seeded: first read already true, no refresh launched
        assertEquals(0, reads.get())
        now.set(6_000)
        repeat(50) { flag.get() }
        val deadline = System.currentTimeMillis() + 3_000
        while (reads.get() < 1 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        Thread.sleep(100)
        assertEquals("one refresh for 50 reads", 1, reads.get())
        scope.cancel()
    }

    @Test fun trackerStartsOfflineWhenNoDefaultNetwork() {
        val t = DefaultNetworkTracker<String>(null, false)
        assertFalse(t.available)
        t.onCapabilities("wifi", true)
        assertTrue(t.available)
    }

    @Test fun trackerSwitchAndStaleLostDoNotPinOnline() {
        val t = DefaultNetworkTracker("wifi", true)
        t.onCapabilities("cell", true) // default switched; no onLost for wifi delivered
        t.onLost("wifi")               // late/stale: must not clear the new default
        assertTrue(t.available)
        t.onLost("cell")
        assertFalse(t.available)
    }
}
