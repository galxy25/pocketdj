package com.levi.pocketdj.data.catalog

import java.io.File
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The offline-first load algorithm (specs/catalog.md §6): conditional GET,
 * 304-serves-cache, decode-before-cache, last-good fallback.
 */
class CatalogServiceTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var service: CatalogService
    private lateinit var cacheDir: File

    private val goodBody = """
        {
          "manifest": { "sourceName": "My Vinyl", "unknownKey": 1 },
          "albums": [ { "id": "alb_1", "artist": "A", "name": "N", "trackList": ["sng_1"] } ],
          "songs": [ { "id": "sng_1", "artist": "A", "name": "S", "bpm": null } ]
        }
    """.trimIndent()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        cacheDir = tmp.newFolder("catalog-cache")
        service = CatalogService(cacheDir, OkHttpClient())
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun url() = server.url("/current-index.json").toString()

    @Test
    fun freshLoad_decodes_cachesBytes_andStoresValidators() = runTest {
        server.enqueue(
            MockResponse()
                .setBody(goodBody)
                .setHeader("ETag", "\"v1\"")
                .setHeader("Last-Modified", "Wed, 01 Jul 2026 00:00:00 GMT"),
        )
        val loaded = service.load(url())
        assertFalse(loaded.fromCache)
        assertEquals("My Vinyl", loaded.index.manifest.sourceName)
        assertTrue(service.cacheFile(url()).isFile)

        // Second load: server answers 304; cache must be served and the request
        // must carry the stored validators.
        server.enqueue(MockResponse().setResponseCode(304))
        val second = service.load(url())
        assertTrue(second.fromCache)
        assertEquals(1, second.index.albums.size)

        server.takeRequest() // first
        val conditional = server.takeRequest()
        assertEquals("\"v1\"", conditional.getHeader("If-None-Match"))
        assertEquals("Wed, 01 Jul 2026 00:00:00 GMT", conditional.getHeader("If-Modified-Since"))
    }

    @Test
    fun serverError_servesLastGoodCache() = runTest {
        server.enqueue(MockResponse().setBody(goodBody))
        service.load(url())

        server.enqueue(MockResponse().setResponseCode(500))
        val fallback = service.load(url())
        assertTrue(fallback.fromCache)
        assertEquals("sng_1", fallback.index.songs.first().id)
    }

    @Test
    fun decodeFailure_servesLastGoodCache_andNeverCachesGarbage() = runTest {
        server.enqueue(MockResponse().setBody(goodBody))
        service.load(url())
        val cachedBytes = service.cacheFile(url()).readText()

        server.enqueue(MockResponse().setBody("""{"albums": "this is not an array"}"""))
        val fallback = service.load(url())
        assertTrue(fallback.fromCache)
        // The garbage body must not have replaced the cached bytes.
        assertEquals(cachedBytes, service.cacheFile(url()).readText())
    }

    @Test
    fun failureWithNoCache_throws_andCachesNothing() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        val result = runCatching { service.load(url()) }
        assertTrue(result.isFailure)
        assertFalse(service.cacheFile(url()).exists())
        assertNull(service.cachedIndexOrNull(url()))
    }

    @Test
    fun cacheFileNames_useStableSha256_neverHashCode() {
        assertEquals(
            // Precomputed SHA-256 of "abc" — pins the algorithm forever.
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            CatalogService.sha256Hex("abc"),
        )
    }
}
