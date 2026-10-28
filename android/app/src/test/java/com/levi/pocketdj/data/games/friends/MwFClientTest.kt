package com.levi.pocketdj.data.games.friends

import kotlinx.coroutines.runBlocking
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

class MwFClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: MwFClient
    private val leader = MwFSessionEntry(id = "abcd2345", memberId = "m", memberKey = "MK", leaderKey = "LK")

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        client = MwFClient(OkHttpClient()) {
            MwFClient.Config(server.url("/").toString().trimEnd('/') + "/", "SRV", "install-1")
        }
    }

    @After fun tearDown() = server.shutdown()

    private fun ok(body: String = "{}") = server.enqueue(MockResponse().setBody(body))

    @Test fun createPostsToMwfWithServerTokenAndBody() = runBlocking {
        ok("""{"sessionId":"abcd2345","leaderKey":"L","memberId":"m","memberKey":"k","name":"N"}""")
        val r = client.create("N", "T", "Lee", "cid", "sec", MwFSettings(turnSeconds = 60))
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/mwf", req.path)
        assertEquals("Bearer SRV", req.getHeader("Authorization"))
        assertEquals("install-1", req.getHeader("X-PocketDJ-Device"))
        val body = req.body.readUtf8()
        assertTrue(body, body.contains("\"joinSecret\":\"sec\"") && body.contains("\"leaderName\":\"Lee\"") && body.contains("\"turnSeconds\":60"))
        assertFalse(body, body.contains("acceptOutsideTurn")) // null settings omitted
        assertEquals("abcd2345", r.sessionId)
    }

    @Test fun emptyTokenOmitsAuthorization() = runBlocking {
        val c = MwFClient(OkHttpClient()) { MwFClient.Config(server.url("/").toString(), "", "i") }
        ok("""{"ok":true,"version":3,"mwf":true}""")
        val h = c.health(null)
        assertEquals(3, h.version)
        val req = server.takeRequest()
        assertNull(req.getHeader("Authorization"))
        assertEquals("/health", req.path)
    }

    @Test fun joinUsesApiBaseSecretBodyAndOptionalMemberKey() = runBlocking {
        val other = MockWebServer().also { it.start() }
        try {
            other.enqueue(MockResponse().setBody("""{"memberId":"m","memberKey":"k"}"""))
            other.enqueue(MockResponse().setBody("""{"memberId":"m","memberKey":"k"}"""))
            val apiBase = other.url("/").toString().trimEnd('/') + "/"
            client.join(apiBase, "abcd2345", "Pat", "cid", "sec", memberKey = "MK")
            client.join(apiBase, "abcd2345", "Pat", "cid", "sec", memberKey = null)
            val a = other.takeRequest()
            val b = other.takeRequest()
            assertEquals("/mwf/abcd2345/join", a.path)
            assertEquals("Bearer MK", a.getHeader("Authorization"))
            assertNull(b.getHeader("Authorization"))
            assertTrue(a.body.readUtf8().contains("\"joinSecret\":\"sec\""))
            assertEquals(0, server.requestCount)
        } finally { other.shutdown() }
    }

    @Test fun routesBearersAndPaths() = runBlocking {
        repeat(8) { ok("""{"ok":true,"suggestionId":"s1","settings":{"turnSeconds":120}}""") }
        client.state(leader)
        client.suggest(leader, "T", "A")
        client.decide(leader, "s1", "accepted", MwFMatch(songId = "sng_1"))
        client.plusOne(leader, "s1")
        val conf = client.configure(leader, MwFSettings(turnSeconds = 120))
        client.registerDevice(leader, "android", "tok")
        client.unregisterDevice(leader)
        client.end(leader)
        val reqs = (1..8).map { server.takeRequest() }
        assertEquals(listOf("GET /mwf/abcd2345/state", "POST /mwf/abcd2345/suggest",
            "POST /mwf/abcd2345/suggestions/s1/decision", "POST /mwf/abcd2345/suggestions/s1/plusone",
            "POST /mwf/abcd2345/config", "POST /mwf/abcd2345/register-device",
            "DELETE /mwf/abcd2345/register-device", "POST /mwf/abcd2345/end"),
            reqs.map { "${it.method} ${it.path}" })
        // member-bearer routes vs leader-bearer routes
        assertEquals(listOf("MK", "MK", "LK", "MK", "LK", "MK", "MK", "LK"),
            reqs.map { it.getHeader("Authorization")!!.removePrefix("Bearer ") })
        assertTrue(reqs.all { it.getHeader("X-PocketDJ-Device") == "install-1" })
        assertTrue(reqs[2].body.readUtf8().contains("\"songId\":\"sng_1\""))
        assertEquals(120, conf.turnSeconds)
    }

    @Test fun rejectBodyOmitsMatchAndMemberCannotLeaderVerb() = runBlocking {
        ok()
        client.decide(leader, "s1", "rejected", null)
        assertFalse(server.takeRequest().body.readUtf8().contains("match"))
        try {
            client.end(leader.copy(leaderKey = null)); fail()
        } catch (e: MwFException) { assertEquals(401, e.code) }
        assertEquals(1, server.requestCount)
    }

    @Test fun non2xxCarriesCodeAndServerError() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(409).setBody("""{"error":"not your turn"}"""))
        try { client.suggest(leader, "T", "A"); fail() } catch (e: MwFException) {
            assertEquals(409, e.code); assertEquals("not your turn", e.message); assertFalse(e.decoding)
        }
        server.enqueue(MockResponse().setResponseCode(401))
        try { client.state(leader); fail() } catch (e: MwFException) { assertEquals(401, e.code) }
    }

    @Test fun undecodableIsDecodingError() = runBlocking {
        ok("not json")
        try { client.state(leader); fail() } catch (e: MwFException) {
            assertTrue(e.decoding); assertNull(e.code)
        }
    }

    @Test fun publicStateIsUnauthenticated() = runBlocking {
        ok("""{"sessionId":"abcd2345","apiBase":"https://x"}""")
        val st = client.publicState(server.url("/mwf/abcd2345/state.json").toString())
        val req = server.takeRequest()
        assertEquals("https://x", st.apiBase)
        assertNull(req.getHeader("Authorization"))
        assertEquals("install-1", req.getHeader("X-PocketDJ-Device"))
    }

    @Test fun unconfiguredBaseFailsLocally() = runBlocking {
        val c = MwFClient(OkHttpClient()) { MwFClient.Config("  ", "", "i") }
        try { c.state(leader); fail() } catch (e: MwFException) { assertNull(e.code) }
    }
}
