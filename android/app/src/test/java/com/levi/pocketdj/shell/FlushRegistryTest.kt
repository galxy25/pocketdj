package com.levi.pocketdj.shell

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FlushRegistryTest {
    private val logs = mutableListOf<String>()
    private fun registry(timeout: Long = 2_000) = FlushRegistry(timeout) { logs += it }

    @Test fun runsInRegistrationOrder() = runBlocking {
        val order = mutableListOf<String>()
        val r = registry()
        r.register("a") { order += "a" }
        r.register("b") { order += "b" }
        r.register("c") { order += "c" }
        assertEquals(listOf("a", "b", "c"), r.flushAll())
        assertEquals(listOf("a", "b", "c"), order)
    }

    @Test fun throwingClosureDoesNotStopOthers() = runBlocking {
        val order = mutableListOf<String>()
        val r = registry()
        r.register("a") { order += "a" }
        r.register("boom") { error("nope") }
        r.register("c") { order += "c" }
        val done = r.flushAll(extra = listOf(Flushable { order += "m" }))
        assertEquals(listOf("a", "c", "module#0"), done)
        assertEquals(listOf("a", "c", "m"), order)
        assertTrue(logs.any { it.contains("boom failed") })
    }

    @Test fun unregisterRemoves() = runBlocking {
        val r = registry()
        val un = r.register("a") { }
        r.register("b") { }
        un()
        assertEquals(listOf("b"), r.names)
    }

    @Test fun sameNameReplaces() = runBlocking {
        val r = registry()
        var hit = ""
        r.register("a") { hit = "old" }
        r.register("a") { hit = "new" }
        r.flushAll()
        assertEquals("new", hit)
        assertEquals(1, r.names.size)
    }

    @Test fun runIsBoundedByTimeout() = runBlocking {
        val r = registry(timeout = 150)
        var after = false
        r.register("slow") { delay(10_000) }
        r.register("after") { after = true }
        val t0 = System.currentTimeMillis()
        val done = r.flushAll()
        assertTrue(System.currentTimeMillis() - t0 < 3_000)
        assertTrue(done.isEmpty())
        assertTrue(!after)
        assertTrue(logs.any { it.contains("TIMED OUT") })
    }
}
