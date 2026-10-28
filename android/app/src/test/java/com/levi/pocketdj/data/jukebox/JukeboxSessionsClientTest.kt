package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class JukeboxSessionsClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: JukeboxClient

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        val base = server.url("/").toString().removeSuffix("/")
        client = JukeboxClient(
            http = OkHttpClient(),
            json = PdjJson.lenient,
            configProvider = { JukeboxClient.Config(base, "srv-token", "install-1") },
        )
    }

    @After fun tearDown() = server.shutdown()

    @Test fun listSessions_decodesRows_noHostKey() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"sessions":[{"jukeboxId":"jb1","name":"Party","url":"https://g/jb1","timeless":false,"expiresAt":1.7e12,"extra":1},
                   {"jukeboxId":"jb2"}]}""",
            ),
        )
        val rows = client.listSessions()
        assertEquals(listOf("jb1", "jb2"), rows.map { it.jukeboxId })
        assertEquals("Party", rows[0].name)
        assertEquals("", rows[1].url)
        assertNull(rows[1].timeless)
        val req = server.takeRequest()
        assertEquals("/sessions", req.path)
        assertEquals("Bearer srv-token", req.getHeader("Authorization"))
        assertEquals("install-1", req.getHeader("X-PocketDJ-Device"))
    }

    @Test fun listSessions_401_throwsJukeboxException401() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"no"}"""))
        try {
            client.listSessions()
            fail("expected exception")
        } catch (e: JukeboxClient.JukeboxException) {
            assertEquals(401, e.code)
        }
    }

    @Test fun sessionInfo_carriesHostKey() = runTest {
        server.enqueue(
            MockResponse().setBody("""{"jukeboxId":"jb1","hostKey":"hk-secret","name":"P","url":"https://g/jb1"}"""),
        )
        val info = client.sessionInfo("jb1")
        assertEquals("hk-secret", info.hostKey)
        assertEquals("/sessions/jb1", server.takeRequest().path)
    }

    @Test fun sessionInfo_404_isEndedException() = runTest {
        server.enqueue(MockResponse().setResponseCode(404))
        try {
            client.sessionInfo("gone")
            fail("expected exception")
        } catch (e: JukeboxClient.JukeboxException) {
            assertEquals(404, e.code)
        }
    }

    @Test fun adoptGuard_matrix() {
        assertEquals(JukeboxAdoptDecision.NO_OP, JukeboxAdoptGuard.decide("a", false, "a"))
        assertEquals(JukeboxAdoptDecision.REFUSE, JukeboxAdoptGuard.decide("a", false, "b"))
        assertEquals(JukeboxAdoptDecision.REFUSE, JukeboxAdoptGuard.decide(null, true, "b"))
        assertEquals(JukeboxAdoptDecision.PROCEED, JukeboxAdoptGuard.decide(null, false, "b"))
    }

    @Test fun defaultSessionName_usesPocketDjName() {
        assertEquals("Levi's Jukebox", JukeboxSettings.defaultSessionName("  Levi "))
        assertEquals("PocketDJ Jukebox", JukeboxSettings.defaultSessionName(""))
        assertTrue(!JukeboxSettings.REQUIRE_TOKEN_CAPTION.contains("gated by"))
    }
}
