package com.levi.pocketdj.data.rips

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PresignCacheTest {

    private val hour = 3_600_000L

    @Test
    fun cachesFor5Hours_thenDropsAndReMints() = runTest {
        var now = 0L
        var calls = 0
        val ttls = mutableListOf<Int>()
        val cache = PresignCache(
            scope = backgroundScope,
            isConfigured = { true },
            presigner = { id, ttl -> calls++; ttls += ttl; "https://s3/$id?n=$calls" },
            clock = { now },
        )
        assertEquals("https://s3/a?n=1", cache.urlFor("a"))
        now = 5 * hour - 1
        assertEquals("https://s3/a?n=1", cache.urlFor("a"))
        assertEquals(1, calls)
        now = 5 * hour
        assertNull(cache.cached("a"))
        assertEquals("https://s3/a?n=2", cache.urlFor("a"))
        assertEquals(listOf(21_600, 21_600), ttls)
    }

    @Test
    fun concurrentRequestsAndPrefetchForSameId_issueOneNetworkCall() = runTest {
        var calls = 0
        val gate = CompletableDeferred<Unit>()
        val cache = PresignCache(
            scope = backgroundScope,
            isConfigured = { true },
            presigner = { id, _ -> calls++; gate.await(); "u-$id" },
        )
        cache.prefetch(listOf("a", "a"))
        runCurrent()
        cache.prefetch(listOf("a"))
        val waiter = async { cache.urlFor("a") }
        runCurrent()
        gate.complete(Unit)
        assertEquals("u-a", waiter.await())
        runCurrent()
        assertEquals(1, calls)
    }

    @Test
    fun serverless_returnsNull_andNeverCallsPresigner() = runTest {
        var calls = 0
        val cache = PresignCache(
            scope = backgroundScope,
            isConfigured = { false },
            presigner = { _, _ -> calls++; "x" },
        )
        assertNull(cache.urlFor("a"))
        cache.prefetch(listOf("a"))
        runCurrent()
        assertEquals(0, calls)
    }

    @Test
    fun presignFailure_returnsNull_andIsNotCached_soNextCallRetries() = runTest {
        var calls = 0
        val cache = PresignCache(
            scope = backgroundScope,
            isConfigured = { true },
            presigner = { _, _ -> calls++; if (calls == 1) error("net") else "ok" },
        )
        assertNull(cache.urlFor("a"))
        assertEquals("ok", cache.urlFor("a"))
    }
}
