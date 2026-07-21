package com.levi.pocketdj.data.rips

import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Rip-server protocol details that are easy to get wrong (specs/playback.md §4):
 * the Authorization header is OMITTED entirely for an empty token (a tokened
 * server 401s a bare "Bearer "), X-PocketDJ-Device always rides, and studio ids
 * never reach the network.
 */
class RipServerClientTest {

    private lateinit var server: MockWebServer
    private var token: String = ""

    private fun client(): RipServerClient = RipServerClient(
        http = OkHttpClient(),
        configProvider = {
            RipServerClient.Config(
                baseUrl = server.url("/").toString(),
                token = token,
                installId = "device-uuid-1234",
            )
        },
    )

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        token = ""
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun emptyToken_omitsAuthorizationHeaderEntirely() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true,"version":2}"""))
        client().health()
        val request = server.takeRequest()
        assertNull(request.getHeader("Authorization"))
        assertEquals("device-uuid-1234", request.getHeader("X-PocketDJ-Device"))
        // No profiles on Android P1 — the profile header must be absent too.
        assertNull(request.getHeader("X-PocketDJ-Profile"))
    }

    @Test
    fun nonEmptyToken_sendsBearer() = runTest {
        token = "sekrit"
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        client().health()
        assertEquals("Bearer sekrit", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun requestRip_postsSongId_andDecodesJobView() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"jobId":"job_1","songId":"sng_x","phase":"queued","message":null,"unknown":1}""",
            ),
        )
        val job = client().requestRip("sng_x")
        assertEquals("job_1", job.jobId)
        assertEquals("queued", job.phase)
        val request = server.takeRequest()
        assertEquals("/rip", request.path)
        assertTrue(request.body.readUtf8().contains("\"songId\":\"sng_x\""))
    }

    @Test
    fun studioIds_neverReachTheNetwork() = runTest {
        val result = runCatching { client().requestRip("smp_localSample") }
        assertTrue(result.exceptionOrNull() is IllegalArgumentException)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun unauthorized_pointsAtSettingsToken() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        val error = runCatching { client().health() }.exceptionOrNull() as RipServerClient.RipServerException
        assertEquals(401, error.code)
        assertTrue(error.message!!.contains("Settings"))
    }

    @Test
    fun unconfiguredServer_failsFast_withIosErrorShape() = runTest {
        val bare = RipServerClient(
            http = OkHttpClient(),
            configProvider = { RipServerClient.Config(baseUrl = "  ", token = "", installId = "x") },
        )
        val error = runCatching { bare.health() }.exceptionOrNull() as RipServerClient.RipServerException
        assertTrue(error.message!!.contains("No import server configured"))
    }
}
