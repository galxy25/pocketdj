package com.levi.pocketdj.data.jukebox

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class JukeboxGuestClientTest {
    private lateinit var server: MockWebServer
    private var configured = ""

    @Before fun up() { server = MockWebServer().also { it.start() } }
    @After fun down() { server.shutdown() }

    private fun client() = JukeboxGuestClient(
        http = OkHttpClient(),
        installId = { "install-1" },
        configuredBase = { configured },
        clock = { 1_234L },
    )

    private fun statePath() = server.url("/exmkrd5a/state.json").toString()

    private fun failure(block: suspend () -> Unit): JukeboxGuestException {
        try { runBlocking { block() } } catch (e: JukeboxGuestException) { return e }
        fail("expected JukeboxGuestException"); throw AssertionError()
    }

    @Test fun guestStateIsCacheBustedAndDecodes() {
        server.enqueue(MockResponse().setBody("""{"name":"Fri","upNext":[{"title":"a"}]}"""))
        val s = runBlocking { client().guestStateAt(statePath()) }
        assertEquals("Fri", s.name); assertEquals(1, s.upNext.size)
        val req = server.takeRequest()
        assertEquals("1234", req.requestUrl!!.queryParameter("_"))
        assertEquals("/exmkrd5a/state.json", req.requestUrl!!.encodedPath)
        assertEquals("no-cache", req.getHeader("Cache-Control"))
        assertNull(req.getHeader("Authorization"))
    }

    @Test fun cacheBustedUrlKeepsExistingQuery() {
        val u = JukeboxGuestClient.cacheBustedUrl("https://h.test/a/state.json?x=1", 9)!!
        assertEquals("1", u.queryParameter("x")); assertEquals("9", u.queryParameter("_"))
    }

    @Test fun http404And410AreEnded() {
        for (code in listOf(404, 410)) {
            server.enqueue(MockResponse().setResponseCode(code).setBody("""{"error":"jukebox ended"}"""))
            val e = failure { client().guestStateAt(statePath()) }
            assertEquals(JukeboxGuestException.Kind.Ended, e.kind)
            assertEquals("This jukebox has ended.", e.message)
        }
    }

    @Test fun otherHttpErrorsAreNotEnded() {
        server.enqueue(MockResponse().setResponseCode(500))
        val e = failure { client().guestStateAt(statePath()) }
        assertEquals(JukeboxGuestException.Kind.Http, e.kind); assertEquals(500, e.code)
    }

    @Test fun submitPostsExactBodyToApiBase() {
        server.enqueue(MockResponse().setBody("""{"requestId":"rq_9","status":"pending"}"""))
        val id = runBlocking {
            client().submitRequest("exmkrd5a", server.url("/").toString().trimEnd('/') + "/", "Song", "Band")
        }
        assertEquals("rq_9", id)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/jukebox/exmkrd5a/request", req.path)
        assertEquals("install-1", req.getHeader("X-PocketDJ-Device"))
        val body = com.levi.pocketdj.data.PdjJson.lenient.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals(setOf("title", "artist", "clientId"), body.keys)
        assertEquals("Song", body["title"]!!.jsonPrimitive.content)
        assertEquals("Band", body["artist"]!!.jsonPrimitive.content)
        assertEquals("install-1", body["clientId"]!!.jsonPrimitive.content)
    }

    @Test fun submitFallsBackToConfiguredBroker() {
        configured = server.url("/").toString().trimEnd('/')
        server.enqueue(MockResponse().setBody("""{"requestId":"rq_1"}"""))
        runBlocking { client().submitRequest("exmkrd5a", "  ", "T", "") }
        assertEquals("/jukebox/exmkrd5a/request", server.takeRequest().path)
    }

    @Test fun submitWithNoBaseAtAllIsNotAccepting() {
        val e = failure { client().submitRequest("exmkrd5a", null, "T", "A") }
        assertEquals(JukeboxGuestException.Kind.NotAcceptingRequests, e.kind)
        assertEquals("This jukebox isn't taking requests", e.message)
        assertEquals(0, server.requestCount)
    }

    @Test fun submit429IsRateLimitWithServerOrDefaultMessage() {
        server.enqueue(MockResponse().setResponseCode(429).setBody("""{"error":"too many requests — wait a moment"}"""))
        val a = failure { client().submitRequest("exmkrd5a", server.url("/").toString(), "T", "A") }
        assertEquals(JukeboxGuestException.Kind.RateLimited, a.kind)
        assertEquals("too many requests — wait a moment", a.message)
        server.enqueue(MockResponse().setResponseCode(429).setBody("oops"))
        val b = failure { client().submitRequest("exmkrd5a", server.url("/").toString(), "T", "A") }
        assertEquals(JukeboxGuestClient.RATE_LIMIT_MESSAGE, b.message)
    }

    @Test fun submitOnEndedSession() {
        server.enqueue(MockResponse().setResponseCode(410))
        val e = failure { client().submitRequest("exmkrd5a", server.url("/").toString(), "T", "A") }
        assertTrue(e.isEnded)
    }

    @Test fun resolveApiBasePrecedence() {
        assertEquals("https://a.test", JukeboxGuestClient.resolveApiBase(" https://a.test/ ", "https://cfg"))
        assertEquals("https://cfg", JukeboxGuestClient.resolveApiBase(null, "https://cfg/"))
        assertEquals("https://cfg", JukeboxGuestClient.resolveApiBase("", " https://cfg "))
        assertNull(JukeboxGuestClient.resolveApiBase(null, "  "))
    }

    @Test fun requestUrlShape() {
        assertEquals(
            "https://api.test/mount/jukebox/exmkrd5a/request",
            JukeboxGuestClient.requestUrl("https://api.test/mount/", "exmkrd5a").toString(),
        )
        assertNotNull(JukeboxGuestClient.requestUrl("http://h:8788", "abcd"))
        assertNull(JukeboxGuestClient.requestUrl("not a url", "abcd"))
    }
}
