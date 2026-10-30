package com.levi.pocketdj.auto

import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AutoAsyncRootTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Test fun staticRootMatchesTheTreeRootSoItNeverNeedsTheGraph() {
        assertEquals(AutoBrowseTree(FakeAutoData()).root(), AutoAsync.STATIC_ROOT)
        assertTrue(AutoAsync.STATIC_ROOT.browsable)
    }

    @Test fun computeRunsOffTheCallingThread() {
        val caller = Thread.currentThread()
        val f = AutoAsync.compute(scope, Dispatchers.Default) { Thread.currentThread() }
        assertNotEquals(caller, f.get(5, TimeUnit.SECONDS))
    }

    @Test fun computeDeliversTheValue() {
        assertEquals(listOf("a"), AutoAsync.compute(scope, Dispatchers.Default) { listOf("a") }.get(5, TimeUnit.SECONDS))
    }

    @Test fun computeFailureSurfacesAsAFailedFuture() {
        val f = AutoAsync.compute<String>(scope, Dispatchers.Default) { throw IllegalStateException("boom") }
        try { f.get(5, TimeUnit.SECONDS); fail("expected failure") } catch (e: ExecutionException) {
            assertEquals("boom", e.cause?.message)
        }
    }
}
