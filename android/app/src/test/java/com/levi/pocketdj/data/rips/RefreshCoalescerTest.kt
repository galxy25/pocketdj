package com.levi.pocketdj.data.rips

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RefreshCoalescerTest {
    @Test fun aBurstOfCallersCostsAtMostTwoPasses() = runTest {
        val c = RefreshCoalescer()
        var passes = 0
        var value = 0
        val gate = CompletableDeferred<Unit>()
        val calls = (1..33).map {
            async { c.run({ value }) { passes++; gate.await(); value = passes; value } }
        }
        runCurrent()
        gate.complete(Unit)
        val results = calls.awaitAll()
        assertTrue("passes=$passes", passes in 1..2)
        assertTrue(results.all { it >= 1 })
    }

    @Test fun aCallerArrivingAfterAPassCompletedRunsItsOwn() = runTest {
        val c = RefreshCoalescer()
        var passes = 0
        c.run({ -1 }) { ++passes }
        assertEquals(2, c.run({ -1 }) { ++passes })
        assertEquals(2, passes)
    }

    @Test fun aCallerThatArrivedDuringAPass_getsAPassStartedAfterIt() = runTest {
        val c = RefreshCoalescer()
        val events = mutableListOf<String>()
        val first = CompletableDeferred<Unit>()
        val a = async { c.run({ "cur" }) { events += "A"; first.await(); "A" } }
        runCurrent()
        val b = async { c.run({ "cur" }) { events += "B"; "B" } } // arrived mid-pass A: A may predate its event
        runCurrent()
        first.complete(Unit)
        assertEquals("A", a.await())
        assertEquals("B", b.await())
        assertEquals(listOf("A", "B"), events)
    }
}
