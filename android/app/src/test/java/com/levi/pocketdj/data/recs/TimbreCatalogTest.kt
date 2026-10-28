package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.CatalogService
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TimbreCatalogTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var service: CatalogService
    private lateinit var catalog: TimbreCatalog
    private lateinit var url: String

    private val fixture: String by lazy {
        javaClass.getResourceAsStream("/recs/timbre-fixture.json")!!.bufferedReader().readText()
    }

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        url = server.url("/timbre.json").toString()
        service = CatalogService(tmp.newFolder("cache"), OkHttpClient())
        catalog = TimbreCatalog(service) { url }
    }

    @After fun tearDown() { server.shutdown() }

    @Test fun decodeAppliesEveryAdmissionRule() {
        val m = TimbreCatalog.decode(fixture.toByteArray())!!
        assertEquals(setOf("sng_a", "sng_b", "sng_sparse"), m.keys)
        // sng_b is a one-hop alias of sng_a; chain (alias of alias) and dangling alias resolve to nothing.
        assertEquals(m["sng_a"], m["sng_b"])
        assertFalse("sng_chain" in m)
        assertFalse("sng_dangling" in m)
        assertFalse("sng_nullaxis" in m)    // present-but-null known axis = failed capture
        assertFalse("sng_degenerate" in m)  // 7 zero axes
        assertFalse("sng_stale" in m)       // row stamp disagrees with doc
        assertFalse("sng_toofew" in m)      // < 8 axes
        assertEquals(3.0, m.getValue("sng_sparse").getValue("extra"), 0.0) // unknown keys pass through
        assertEquals(0.8, m.getValue("sng_a").getValue("m1"), 0.0)
    }

    @Test fun otherCalibrationDocumentDecodesEmptyAndGarbageIsNull() {
        assertEquals(emptyMap<String, Any>(), TimbreCatalog.decode("""{"timbreVersion":2,"songs":{}}""".toByteArray()))
        assertNull(TimbreCatalog.decode("<html>spa shell</html>".toByteArray()))
        assertNull(TimbreCatalog.decode("""{"v":1}""".toByteArray()))
        // absent timbreVersion defaults to 1
        assertEquals(setOf("sng_a"), TimbreCatalog.decode(
            """{"songs":{"sng_a":{"f":{"bright":0.1,"brightVar":0.2,"air":0.3,"width":0.4,"noisy":0.5,"fizz":0.6,"punch":0.7,"busy":0.8}}}}""".toByteArray(),
        )!!.keys)
    }

    @Test fun ok200DecodesAndCaches() = runTest {
        server.enqueue(MockResponse().setBody(fixture).setHeader("ETag", "\"e1\""))
        val m = catalog.vectors(nowMs = 1_000)
        assertEquals(3, m.size)
        assertTrue(service.cacheFile(url).isFile)
        assertEquals(1, server.requestCount)
    }

    @Test fun memoizedForSixHoursThenRevalidatesWith304() = runTest {
        server.enqueue(MockResponse().setBody(fixture).setHeader("ETag", "\"e1\"").setHeader("Last-Modified", "Mon, 26 Oct 2026 00:00:00 GMT"))
        catalog.vectors(nowMs = 1_000)
        // Within 6 h: no network.
        catalog.vectors(nowMs = 1_000 + TimbreCatalog.REFRESH_INTERVAL_MS - 1)
        assertEquals(1, server.requestCount)
        // After 6 h: conditional GET, 304 serves the cache.
        server.enqueue(MockResponse().setResponseCode(304))
        val m = catalog.vectors(nowMs = 1_000 + TimbreCatalog.REFRESH_INTERVAL_MS)
        assertEquals(2, server.requestCount)
        assertEquals(3, m.size)
        server.takeRequest()
        val second = server.takeRequest()
        assertEquals("\"e1\"", second.getHeader("If-None-Match"))
        assertEquals("Mon, 26 Oct 2026 00:00:00 GMT", second.getHeader("If-Modified-Since"))
    }

    @Test fun serverErrorServesLastGoodAndRetriesNextCall() = runTest {
        server.enqueue(MockResponse().setBody(fixture))
        catalog.vectors(nowMs = 0)
        server.enqueue(MockResponse().setResponseCode(500))
        val afterError = catalog.vectors(nowMs = TimbreCatalog.REFRESH_INTERVAL_MS + 1)
        assertEquals(3, afterError.size)
        // Failure did not stamp the memo: the very next call retries the network.
        server.enqueue(MockResponse().setResponseCode(500))
        catalog.vectors(nowMs = TimbreCatalog.REFRESH_INTERVAL_MS + 2)
        assertEquals(3, server.requestCount)
    }

    @Test fun coldProcessServesDiskCacheWhenOffline() = runTest {
        server.enqueue(MockResponse().setBody(fixture))
        catalog.vectors(nowMs = 0)
        // New process: empty memo, same cache dir, server now failing.
        val fresh = TimbreCatalog(service) { url }
        server.enqueue(MockResponse().setResponseCode(503))
        assertEquals(3, fresh.vectors(nowMs = 10).size)
    }

    @Test fun coldOfflineWithNoCacheIsEmpty() = runTest {
        val dead = server.url("/timbre.json").toString()
        server.shutdown()
        val c = TimbreCatalog(service) { dead }
        assertEquals(emptyMap<String, Any>(), c.vectors(nowMs = 0))
    }

    @Test fun undecodableBodyIsNeverCached() = runTest {
        server.enqueue(MockResponse().setBody("<html>SPA shell</html>"))
        assertTrue(catalog.vectors(nowMs = 0).isEmpty())
        assertFalse(service.cacheFile(url).exists())
        // and a later good response works
        server.enqueue(MockResponse().setBody(fixture))
        assertNotNull(catalog.vectors(nowMs = 1).takeIf { it.size == 3 })
    }
}
