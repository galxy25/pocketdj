package com.levi.pocketdj.data.config

import java.io.File
import java.nio.file.Files
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Remote endpoint config (docs/design/remote-endpoints.md): decode, allowlist rejection,
 * resolution order (cached last-good → compiled-in), persistence, fetch, and that call sites
 * ([Endpoints]) read the resolver live.
 */
class RemoteEndpointsTest {

    private val green = """
        {"v":1,"env":"green","endpoints":{
          "catalogBase":"https://dgreen123.cloudfront.net",
          "ripsBase":"https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
          "amPlaylistSyncBase":"https://abc123.execute-api.us-west-2.amazonaws.com",
          "recEngineBase":"https://def456.execute-api.us-west-2.amazonaws.com",
          "diagLogsBase":"https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com"}}
    """.trimIndent()

    private fun greenWith(key: String, value: String?): String {
        val needle = Regex("\"$key\":\"[^\"]*\",?")
        val stripped = green.replace(needle, "")
        return if (value == null) stripped.replace(",}", "}")
        else stripped.replace("\"endpoints\":{", "\"endpoints\":{\"$key\":$value,").replace(",}", "}")
    }

    private lateinit var dir: File

    @Before fun setUp() {
        RemoteEndpoints.resetForTests()
        dir = Files.createTempDirectory("endpoints").toFile()
    }

    @After fun tearDown() {
        RemoteEndpoints.resetForTests()
        dir.deleteRecursively()
    }

    private fun ok(text: String) =
        (EndpointConfig.decode(text) as EndpointConfig.Companion.Decoded.Ok).config


    @Test fun optionalKeysDeriveFromSameDoc() {
        val c = ok(green)
        assertEquals("green", c.env)
        assertEquals("https://def456.execute-api.us-west-2.amazonaws.com", c.url(EndpointKey.LISTENING_POCKETS_BASE))
        assertEquals("https://dgreen123.cloudfront.net", c.url(EndpointKey.CATALOG_BASE_DEV))
        assertEquals("https://dgreen123.cloudfront.net/search-config.json", c.url(EndpointKey.SEARCH_CONFIG_URL))
    }

    @Test fun hostAllowlist() {
        listOf("app.pocket-dj.com", "pocket-dj.com", "d2p4cubg6se03u.cloudfront.net",
            "n5ordrwfe9.execute-api.us-west-2.amazonaws.com",
            "pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
        ).forEach { assertTrue(it, EndpointConfig.isAllowedHost(it)) }
        listOf("evil.com", "pocket-dj.com.evil.com", "evilpocket-dj.com",
            "x.execute-api.us-east-1.amazonaws.com", "other-bucket.s3.us-west-2.amazonaws.com",
            "pocketdj-rips.s3.us-east-1.amazonaws.com", "cloudfront.net",
        ).forEach { assertFalse(it, EndpointConfig.isAllowedHost(it)) }
    }

    @Test fun rejectsInvalidDocuments() {
        val cases = mapOf(
            "html" to "<!doctype html><html></html>",
            "array" to "[1,2]",
            "version" to green.replace("\"v\":1", "\"v\":2"),
            "version-string" to green.replace("\"v\":1", "\"v\":\"1\""),
            "env" to green.replace("\"env\":\"green\"", "\"env\":\" \""),
            "missing required" to greenWith("ripsBase", null),
            "http" to greenWith("catalogBase", "\"http://dgreen123.cloudfront.net\""),
            "foreign host" to greenWith("recEngineBase", "\"https://api.evil.com\""),
            "foreign optional" to greenWith("searchConfigURL", "\"https://evil.com/x.json\""),
            "credentials" to greenWith("catalogBase", "\"https://u:p@dgreen123.cloudfront.net\""),
            "query" to greenWith("catalogBase", "\"https://dgreen123.cloudfront.net/?x=1\""),
            "port" to greenWith("catalogBase", "\"https://dgreen123.cloudfront.net:8443\""),
            "non-string" to greenWith("catalogBase", "42"),
        )
        for ((label, doc) in cases) {
            assertTrue(label, EndpointConfig.decode(doc) is EndpointConfig.Companion.Decoded.Rejected)
        }
    }

    @Test fun noCacheIsCompiledIn() {
        RemoteEndpoints.install(File(dir, "pocketdj-endpoints.json"))
        assertEquals(EndpointSource.COMPILED_IN, RemoteEndpoints.source)
        assertEquals(EndpointConfig.COMPILED_IN, RemoteEndpoints.current)
    }

    @Test fun acceptedDocPersistsAndWinsOnNextLaunch() {
        val file = File(dir, "pocketdj-endpoints.json")
        RemoteEndpoints.install(file)
        assertTrue(RemoteEndpoints.apply(green))
        assertEquals(EndpointSource.REMOTE, RemoteEndpoints.source)
        RemoteEndpoints.resetForTests()          // simulated relaunch
        RemoteEndpoints.install(file)
        assertEquals(EndpointSource.CACHED, RemoteEndpoints.source)
        assertEquals(ok(green), RemoteEndpoints.current)
    }

    @Test fun rejectedDocKeepsLastGood() {
        val file = File(dir, "pocketdj-endpoints.json")
        RemoteEndpoints.install(file)
        RemoteEndpoints.apply(green)
        assertFalse(RemoteEndpoints.apply(greenWith("ripsBase", "\"https://evil.com\"")))
        assertEquals("green", RemoteEndpoints.current.env)
        RemoteEndpoints.resetForTests()
        RemoteEndpoints.install(file)
        assertEquals("green", RemoteEndpoints.current.env)
    }

    @Test fun corruptCacheFallsBackToCompiledIn() {
        val file = File(dir, "pocketdj-endpoints.json")
        file.writeText("not json")
        RemoteEndpoints.install(file)
        assertEquals(EndpointSource.COMPILED_IN, RemoteEndpoints.source)
    }

    @Test fun refreshAppliesValidDocIgnoresSpaHtmlAndErrorsAndThrottles() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("<!doctype html>"))
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setBody(green))
        server.start()
        try {
            val http = OkHttpClient()
            val url = server.url("/config/endpoints.json").toString()
            assertFalse(RemoteEndpoints.refresh(http, force = true, nowMs = 0, url = url))
            assertEquals(EndpointSource.COMPILED_IN, RemoteEndpoints.source)
            assertFalse(RemoteEndpoints.refresh(http, force = true, nowMs = 0, url = url))
            assertEquals("http 503", RemoteEndpoints.lastOutcome)
            assertTrue(RemoteEndpoints.refresh(http, force = true, nowMs = 1_000, url = url))
            assertEquals("green", RemoteEndpoints.current.env)
            // Throttled: no request is made inside the window.
            assertFalse(RemoteEndpoints.refresh(http, nowMs = 2_000, url = url))
            assertEquals(3, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test fun remoteUrlIsTheStableOwnDomainUrl() {
        assertEquals("https://app.pocket-dj.com/config/endpoints.json", RemoteEndpoints.REMOTE_URL)
    }

    @Test fun callSitesReadTheResolverLive() {
        assertEquals("https://d1j6qufkowz1xq.cloudfront.net/current-index.json", Endpoints.VINYL_INDEX_URL)
        RemoteEndpoints.setForTests(ok(green))
        assertEquals("https://dgreen123.cloudfront.net/current-index.json", Endpoints.VINYL_INDEX_URL)
        assertEquals("https://dgreen123.cloudfront.net/art/a.jpg", Endpoints.artUrl("/art/a.jpg"))
        assertEquals("https://dgreen123.cloudfront.net/lyrics/s.txt", Endpoints.lyricsUrl("s"))
        assertEquals("https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com/rips/manifest.json",
            Endpoints.RIPS_MANIFEST_URL)
        assertEquals("https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com/rips/x.mp3",
            Endpoints.ripAudioUrl("rips/x.mp3"))
        assertEquals("https://dgreen123.cloudfront.net/search-config.json", Endpoints.SEARCH_CONFIG_URL)
    }

    @Test fun persistedBuiltInSourcesRebaseCustomOnesDoNot() {
        RemoteEndpoints.setForTests(ok(green))
        assertEquals("https://dgreen123.cloudfront.net/current-index.json",
            RemoteEndpoints.rebaseCatalogUrl("https://d2p4cubg6se03u.cloudfront.net/current-index.json"))
        assertEquals("https://dgreen123.cloudfront.net/digital-index.json",
            RemoteEndpoints.rebaseCatalogUrl("https://djictbz9w796r.cloudfront.net/digital-index.json"))
        assertEquals("https://example.org/x.json", RemoteEndpoints.rebaseCatalogUrl("https://example.org/x.json"))
    }

    @Test fun sourceSavedWhileGreenRebasesAfterFlippingBack() {
        val file = File(dir, "pocketdj-endpoints.json")
        RemoteEndpoints.install(file)
        RemoteEndpoints.apply(green)
        val blue = File("../../config/endpoints.blue.json").takeIf { it.exists() }?.readText()
            ?: File("../config/endpoints.blue.json").readText()
        RemoteEndpoints.apply(blue)
        RemoteEndpoints.resetForTests()
        RemoteEndpoints.install(file)   // seen-host history persisted
        assertEquals("https://d2p4cubg6se03u.cloudfront.net/current-index.json",
            RemoteEndpoints.rebaseCatalogUrl("https://dgreen123.cloudfront.net/current-index.json"))
    }

    @Test fun docAliasesRebaseAllowlistedHostsOnly() {
        val doc = green.replace("}}", "},\"aliases\":{\"catalogBase\":[\"old123.cloudfront.net\",\"evil.com\"]}}")
        RemoteEndpoints.setForTests(ok(doc))
        assertEquals("https://dgreen123.cloudfront.net/a.json", RemoteEndpoints.rebaseCatalogUrl("https://old123.cloudfront.net/a.json"))
        assertEquals("https://evil.com/a.json", RemoteEndpoints.rebaseCatalogUrl("https://evil.com/a.json"))
    }

    // ---- ANS-BRW-2: capabilities.recEngineEnroll ------------------------------------------

    private fun greenWithEnroll(value: String) =
        green.dropLast(1) + ""","capabilities":{"recEngineEnroll":$value}}"""

    @Test fun enrollCapabilityParsedAndFallsBackToCompiledConstant() {
        assertEquals(REC_ENGINE_ENROLL_SECRET, RemoteEndpoints.recEngineEnroll())      // compiled-in
        assertEquals(null, ok(green).recEngineEnroll)                                  // absent => null
        RemoteEndpoints.apply(green)
        assertEquals(REC_ENGINE_ENROLL_SECRET, RemoteEndpoints.recEngineEnroll())      // doc w/o capability
        val rotated = "rotated-secret-0123456789abcdef"
        assertTrue(RemoteEndpoints.apply(greenWithEnroll("\"$rotated\"")))
        assertEquals(rotated, RemoteEndpoints.recEngineEnroll())
    }

    @Test fun malformedEnrollCapabilityIsIgnoredNotFatal() {
        for (bad in listOf("\"short\"", "\"has space in it 0123456789\"", "42", "null", "\"\"")) {
            val cfg = ok(greenWithEnroll(bad))
            assertEquals(bad, null, cfg.recEngineEnroll)
            assertEquals("doc still accepted for $bad", "green", cfg.env)
        }
    }

    @Test fun enrollCapabilityPersistsWithLastGoodDoc() {
        val file = File(dir, "pocketdj-endpoints.json")
        RemoteEndpoints.install(file)
        val rotated = "rotated-secret-0123456789abcdef"
        RemoteEndpoints.apply(greenWithEnroll("\"$rotated\""))
        RemoteEndpoints.resetForTests()
        assertEquals(REC_ENGINE_ENROLL_SECRET, RemoteEndpoints.recEngineEnroll())
        RemoteEndpoints.install(file)                                                  // relaunch
        assertEquals(rotated, RemoteEndpoints.recEngineEnroll())
        // A later rejected doc keeps the last-good secret.
        RemoteEndpoints.apply("<html>spa fallback</html>")
        assertEquals(rotated, RemoteEndpoints.recEngineEnroll())
    }

    @Test fun enrollCapabilityChangesConfigEquality() {
        assertTrue(ok(green) != ok(greenWithEnroll("\"rotated-secret-0123456789abcdef\"")))
    }
}
