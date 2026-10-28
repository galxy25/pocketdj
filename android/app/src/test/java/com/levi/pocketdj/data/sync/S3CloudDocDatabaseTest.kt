package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import okio.GzipSource
import okio.buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.IOException

class S3CloudDocDatabaseTest {
    private lateinit var server: MockWebServer
    private lateinit var secrets: ProfileSecretStore
    private val id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    private val secret = "cd".repeat(32)

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        secrets = ProfileSecretStore(InMemorySecretStore())
        secrets.adopt(id, secret)
    }
    @After fun tearDown() { server.shutdown() }

    private fun db(base: String? = server.url("/").toString().trimEnd('/'), enrollment: Enrollment? = null) =
        S3CloudDocDatabase(
            baseUrl = { base }, profileId = { id }, secrets = secrets, http = OkHttpClient(),
            enrollment = enrollment, deviceName = { "Pixel" },
        )

    @Test fun noBase_meansUnavailable_andNoNetworkEver() = runTest {
        val d = db(base = null)
        assertFalse(d.accountAvailable())
        assertEquals(0, server.requestCount)
    }

    @Test fun accountAvailable_trueWithBaseAndSecret_noNetworkWhenAlreadyEnrolled() = runTest {
        val e = Enrollment(secrets, { server.url("/").toString() }, { "t" }, OkHttpClient(), backoff = {})
        assertTrue(db(enrollment = e).accountAvailable())
        assertEquals(0, server.requestCount)
    }

    @Test fun accountAvailable_falseWhenRefused() = runTest {
        secrets.clear(); secrets.secretOrMint()
        server.enqueue(MockResponse().setResponseCode(401))
        val e = Enrollment(secrets, { server.url("/").toString() }, { "t" }, OkHttpClient(), backoff = {})
        assertFalse(db(enrollment = e).accountAvailable())
    }

    @Test fun fetchMeta_parsesMap_sendsAuthHeaders_andKeysQuery() = runTest {
        server.enqueue(MockResponse().setBody("""{"collections":1700000000123,"profile":1.7E12}"""))
        val m = db().fetchMeta(listOf("collections", "profile", "play-stats"))
        assertEquals(mapOf("collections" to 1700000000123.0, "profile" to 1.7e12), m)
        val r = server.takeRequest()
        assertEquals("GET", r.method)
        assertEquals("/meta?keys=collections,profile,play-stats", r.path)
        assertEquals(id.lowercase(), r.getHeader("X-PocketDJ-Profile"))
        assertEquals("Bearer $secret", r.getHeader("Authorization"))
    }

    @Test fun fetchMeta_emptyKeys_makesNoRequest() = runTest {
        assertTrue(db().fetchMeta(emptyList()).isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test fun fetch_returnsPayloadAndMetadataHeaders() = runTest {
        server.enqueue(MockResponse().setBody("""{"a":1}""").setHeader("X-PocketDJ-Modified-At", "1700000000123").setHeader("X-PocketDJ-Device", "iPhone"))
        val doc = db().fetch("collections")!!
        assertEquals("collections", doc.key)
        assertEquals("""{"a":1}""", String(doc.payload))
        assertEquals(1700000000123.0, doc.modifiedAtMs, 0.0)
        assertEquals("iPhone", doc.deviceName)
        val r = server.takeRequest()
        assertEquals("/doc/collections", r.path)
        assertEquals("gzip", r.getHeader("Accept-Encoding"))
    }

    @Test fun fetch_inflatesGzipResponse() = runTest {
        val gz = Buffer().also { b -> okio.GzipSink(b).buffer().use { it.writeUtf8("""{"big":true}""") } }
        server.enqueue(MockResponse().setBody(gz).setHeader("Content-Encoding", "gzip").setHeader("X-PocketDJ-Modified-At", "5"))
        assertEquals("""{"big":true}""", String(db().fetch("profile")!!.payload))
    }

    @Test fun fetch_404_isNull() = runTest {
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(db().fetch("play-stats"))
    }

    @Test fun save_putsGzippedBodyWithMetadataHeaders() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        val payload = """{"hello":"world"}""".repeat(100).toByteArray()
        db().save(CloudDoc("collections", payload, 1700000000123.0, "Pixel 9 é"))
        val r = server.takeRequest()
        assertEquals("PUT", r.method)
        assertEquals("/doc/collections", r.path)
        assertEquals("gzip", r.getHeader("Content-Encoding"))
        assertEquals("1700000000123", r.getHeader("X-PocketDJ-Modified-At"))
        assertEquals("Pixel 9", r.getHeader("X-PocketDJ-Device"))
        assertEquals("Bearer $secret", r.getHeader("Authorization"))
        val inflated = GzipSource(r.body).buffer().readByteArray()
        assertArrayEquals(payload, inflated)
    }

    @Test fun save_formatsFractionalAndLargeTimestampsWithoutExponent() {
        assertEquals("1700000000123", S3CloudDocDatabase.formatMs(1.700000000123E12))
        assertEquals("1700000000124", S3CloudDocDatabase.formatMs(1700000000123.6))
    }

    @Test fun save_emptyDeviceFallsBackToDeviceName() = runTest {
        server.enqueue(MockResponse().setBody("{}"))
        db().save(CloudDoc("profile", "{}".toByteArray(), 1.0, ""))
        assertEquals("Pixel", server.takeRequest().getHeader("X-PocketDJ-Device"))
    }

    @Test fun save_serverError_throws() = runTest {
        server.enqueue(MockResponse().setResponseCode(413))
        try { db().save(CloudDoc("profile", "{}".toByteArray(), 1.0, "d")); fail() } catch (e: IOException) { assertTrue(e.message!!.contains("413")) }
    }

    @Test fun delete_isIdempotent_okAnd404() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        server.enqueue(MockResponse().setResponseCode(404))
        val d = db()
        d.delete("collections")
        d.delete("collections")
        val r = server.takeRequest()
        assertEquals("DELETE", r.method)
        assertEquals("/doc/collections", r.path)
        assertEquals(2, server.requestCount)
    }

    @Test fun deleteAll_deletesEachKey() = runTest {
        repeat(3) { server.enqueue(MockResponse().setBody("{}")) }
        db().deleteAll(listOf("a", "b", "c"))
        assertEquals(listOf("/doc/a", "/doc/b", "/doc/c"), List(3) { server.takeRequest().path })
    }

    @Test fun deleteProfile_hitsProfileRoute() = runTest {
        server.enqueue(MockResponse().setBody("{}"))
        db().deleteProfile()
        val r = server.takeRequest()
        assertEquals("DELETE", r.method); assertEquals("/profile", r.path)
    }

    @Test fun http401_flipsUnavailable_untilCleared() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        val d = db()
        assertTrue(d.accountAvailable())
        try { d.fetchMeta(listOf("profile")); fail() } catch (e: IOException) { assertTrue(e.message!!.contains("401")) }
        assertTrue(d.unauthorized.value)
        assertFalse(d.accountAvailable())
        d.clearUnauthorized()
        assertTrue(d.accountAvailable())
    }

    @Test fun stale401FromAReplacedIdentity_isIgnored() = runTest {
        var current = id
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                current = "11111111-2222-3333-4444-555555555555" // identity swapped while the request is in flight
                return MockResponse().setResponseCode(401)
            }
        }
        val d = S3CloudDocDatabase({ server.url("/").toString().trimEnd('/') }, { current }, secrets, OkHttpClient())
        try { d.fetchMeta(listOf("profile")); fail() } catch (e: IOException) { assertTrue(e.message!!.contains("401")) }
        assertFalse(d.unauthorized.value)
        assertFalse(secrets.unauthorizedFor(current))
    }

    @Test fun unauthorized_survivesProcessRestart_untilRelink() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        val d = db()
        try { d.fetchMeta(listOf("profile")); fail() } catch (_: IOException) {}
        assertTrue(db().unauthorized.value) // a "new process" over the same SecretStore
        assertFalse(db().accountAvailable())
        secrets.adopt(id, secret) // relink
        assertFalse(db().unauthorized.value)
    }

    @Test fun enroll409_flipsUnauthorized() = runTest {
        secrets.clear(); secrets.secretOrMint()
        server.enqueue(MockResponse().setResponseCode(409))
        val e = Enrollment(secrets, { server.url("/").toString() }, { "t" }, OkHttpClient(), backoff = {})
        val d = db(enrollment = e)
        assertFalse(d.accountAvailable())
        assertTrue(d.unauthorized.value)
    }

    @Test fun badKeysAreRejectedBeforeTheNetwork() = runTest {
        try { db().fetch("../etc"); fail() } catch (_: IllegalArgumentException) {}
        try { db().fetchMeta(listOf("Bad_Key")); fail() } catch (_: IllegalArgumentException) {}
        assertEquals(0, server.requestCount)
    }

    @Test fun otherServerErrors_throw_withoutFlippingUnauthorized() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        val d = db()
        try { d.fetch("profile"); fail() } catch (_: IOException) {}
        assertFalse(d.unauthorized.value)
    }

    @Test fun secretNeverAppearsInErrorMessagesOrToString() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        try { db().fetch("profile") } catch (e: IOException) { assertFalse(e.message!!.contains(secret)) }
        assertFalse(secrets.toString().contains(secret))
    }
}
