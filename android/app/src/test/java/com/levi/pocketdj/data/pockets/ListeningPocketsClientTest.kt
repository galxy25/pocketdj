package com.levi.pocketdj.data.pockets

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class ListeningPocketsClientTest {
    private lateinit var server: MockWebServer
    private val creds = PocketsCredentials("KEY", " scoped ", "ENR")

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown() }

    private fun client() = ListeningPocketsClient(OkHttpClient(), { server.url("/").toString() }, { "DEV" })
    private fun batch() = ListeningPocketsUploadBatch("DEV", "inst", 1, emptyList())

    @Test fun headers() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"ok":true,"accepted":0}"""))
        val resp = client().postEvents(batch(), creds)
        assertEquals(true, resp.ok)
        val r = server.takeRequest()
        assertEquals("/pockets/events", r.path)
        assertEquals("POST", r.method)
        assertEquals("Bearer KEY", r.getHeader("Authorization"))
        assertEquals("scoped", r.getHeader("X-PocketDJ-Profile"))
        assertEquals("ENR", r.getHeader("X-PocketDJ-Enroll"))
        assertEquals("DEV", r.getHeader("X-PocketDJ-Device"))
        assertEquals(0, Json.parseToJsonElement(r.body.readUtf8()).jsonObject["events"]!!.jsonArray.size)

        // GET results carries no enroll secret; empty secret omits the header on events too.
        server.enqueue(MockResponse().setBody("""{"v":1}"""))
        client().results(creds)
        val g = server.takeRequest()
        assertEquals("GET", g.method); assertNull(g.getHeader("X-PocketDJ-Enroll"))
        server.enqueue(MockResponse().setBody("{}"))
        client().postEvents(batch(), creds.copy(enrollSecret = ""))
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Enroll"))
        server.enqueue(MockResponse().setBody("{}"))
        client().deleteState(creds)
        val d = server.takeRequest()
        assertEquals("DELETE", d.method); assertEquals("/pockets/state", d.path); assertEquals("ENR", d.getHeader("X-PocketDJ-Enroll"))
    }

    private suspend fun errorOf(code: Int, body: String = ""): Throwable {
        server.enqueue(MockResponse().setResponseCode(code).setBody(body))
        return try { client().results(creds); fail("expected error"); error("unreachable") } catch (e: ListeningPocketsClient.ClientError) { e }
    }

    @Test fun `404SetsUnavailable`() = runBlocking {
        assertEquals(ListeningPocketsClient.ClientError.NotFound, errorOf(404, "{\"message\":\"Not Found\"}"))
        assertEquals(ListeningPocketsClient.ClientError.Http(500), errorOf(500))
    }

    @Test fun errorBodyMessage() = runBlocking {
        assertEquals(ListeningPocketsClient.ClientError.EnrollmentRequired, errorOf(403, """{"error":"enrollment-required"}"""))
        assertEquals(ListeningPocketsClient.ClientError.ProfileCapReached, errorOf(403, """{"error":"profile-cap-reached"}"""))
        assertEquals(ListeningPocketsClient.ClientError.KeyMismatch, errorOf(403, """{"error":"other"}"""))
        assertEquals(ListeningPocketsClient.ClientError.KeyMismatch, errorOf(403, "not json"))
        server.enqueue(MockResponse().setBody("[1,2]"))   // 200 but not a results object
        try { client().results(creds); fail() } catch (e: ListeningPocketsClient.ClientError) {
            assertEquals(ListeningPocketsClient.ClientError.BadResponse, e)
        }
    }

    @Test fun healthProbe() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"ok":true,"service":"pockets"}"""))
        assertTrue(client().health())
        assertNull(server.takeRequest().getHeader("Authorization"))
        server.enqueue(MockResponse().setBody("""{"ok":false}"""))
        assertFalse(client().health())
        server.enqueue(MockResponse().setResponseCode(404))
        assertFalse(client().health())
    }
}
