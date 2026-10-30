package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeUnit

class RecEngineClientTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer().apply { start() } }
    @After fun tearDown() { server.shutdown() }

    private fun client(secret: String = "SECRET", http: OkHttpClient = OkHttpClient()) =
        RecEngineClient(http, base = { server.url("/").toString() }, enrollSecret = { secret }, deviceId = { "dev-1" })

    private fun batch() = RecUploadBatch(deviceId = "dev-1", sentAtMs = 5.0, plays = listOf(RecPlayEventWire("p1", "s1", 1.0, "browser")))

    @Test fun postEvents_headers_carryBearerProfileDeviceAndEnroll() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"ok":true,"totals":{"plays":7}}"""))
        val resp = client().postEvents(batch(), key = "K", profileId = "scoped")
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/events", r.path)
        assertEquals("Bearer K", r.getHeader("Authorization"))
        assertEquals("scoped", r.getHeader("X-PocketDJ-Profile"))
        assertEquals("dev-1", r.getHeader("X-PocketDJ-Device"))
        assertEquals("SECRET", r.getHeader("X-PocketDJ-Enroll"))
        assertTrue(r.getHeader("Content-Type")!!.startsWith("application/json"))
        assertEquals(true, resp.ok)
        assertEquals(7, resp.totalPlays)
    }

    @Test fun postEvents_bodyIsAdditiveOptional_nullStreamsOmitted() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        client().postEvents(batch(), "K", "p")
        val body = PdjJson.lenient.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals(1, (body["v"] as kotlinx.serialization.json.JsonPrimitive).content.toInt())
        assertEquals("dev-1", (body["deviceId"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertTrue(body["plays"] is JsonArray)
        for (k in listOf("favorites", "activity", "puzzle", "feedback", "collectionsSnapshot", "playCounts", "audioQueue")) {
            assertFalse("$k should be absent", body.containsKey(k))
        }
    }

    @Test fun readRoutes_carryNoEnrollHeader() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setBody("""{"songs":[],"suggestions":[]}""")) }
        val c = client()
        c.forYou(200, "K", "p")
        c.collectionSuggestions("song 1", "K", "p")
        c.similarToCollections(listOf("a", "b"), 50, "K", "p")
        val a = server.takeRequest(); val b = server.takeRequest(); val s = server.takeRequest()
        assertEquals("/recs/songs?limit=200", a.path)
        assertEquals("/recs/collections?songId=song%201", b.path)
        assertEquals("/recs/similar?collectionIds=a%2Cb&limit=50", s.path)
        for (r in listOf(a, b, s)) {
            assertNull(r.getHeader("X-PocketDJ-Enroll"))
            assertEquals("Bearer K", r.getHeader("Authorization"))
            assertEquals("GET", r.method)
        }
    }

    @Test fun deleteState_carriesEnroll() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"deleted":true}"""))
        client().deleteState("K", "p")
        val r = server.takeRequest()
        assertEquals("DELETE", r.method)
        assertEquals("/state", r.path)
        assertEquals("SECRET", r.getHeader("X-PocketDJ-Enroll"))
    }

    @Test fun blankEnrollSecret_omitsHeader() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        client(secret = "").postEvents(batch(), "K", "p")
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Enroll"))
    }

    @Test fun blankProfile_omitsProfileHeader() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        client().postEvents(batch(), "K", "")
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Profile"))
    }

    @Test fun forbidden_enrollmentRequired_vs_keyMismatch_areDistinct() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"enrollment-required"}"""))
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"key-mismatch"}"""))
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"profile-cap-reached"}"""))
        server.enqueue(MockResponse().setResponseCode(403).setBody("<html>nope</html>"))
        val c = client()
        val results = (1..4).map {
            try { c.postEvents(batch(), "K", "p"); null } catch (e: RecEngineClient.ClientError) { e }
        }
        assertEquals(RecEngineClient.ClientError.EnrollmentRequired, results[0])
        assertEquals(RecEngineClient.ClientError.KeyMismatch, results[1])
        assertEquals(RecEngineClient.ClientError.KeyMismatch, results[2])
        assertEquals(RecEngineClient.ClientError.KeyMismatch, results[3])
    }

    @Test fun nonSuccess_mapsToHttpCode_and_malformedBodyToBadResponse() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setResponseCode(413))
        server.enqueue(MockResponse().setBody("not json"))
        val c = client()
        val outcomes = (1..3).map {
            try { c.forYou(1, "K", "p"); null } catch (e: RecEngineClient.ClientError) { e }
        }
        assertEquals(RecEngineClient.ClientError.Http(503), outcomes[0])
        assertEquals(RecEngineClient.ClientError.Http(413), outcomes[1])
        assertEquals(RecEngineClient.ClientError.BadResponse, outcomes[2])
    }

    @Test fun blankBase_isBadResponse_withoutAnyRequest() = runBlocking {
        val c = RecEngineClient(OkHttpClient(), base = { "  " }, deviceId = { "d" })
        try { c.forYou(1, "K", "p"); fail() } catch (e: RecEngineClient.ClientError) {
            assertEquals(RecEngineClient.ClientError.BadResponse, e)
        }
        assertEquals(0, server.requestCount)
    }

    @Test fun slowServer_surfacesAsIoException_notAClientError() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val http = OkHttpClient.Builder().readTimeout(300, TimeUnit.MILLISECONDS).build()
        try {
            client(http = http).forYou(1, "K", "p")
            fail("expected timeout")
        } catch (e: IOException) {
            // transport failure stays distinct from the 403/HTTP mapping so the service retries next cycle
        }
    }

    @Test fun health_trueOnlyForOkTrue() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        server.enqueue(MockResponse().setBody("""{"ok":false}"""))
        server.enqueue(MockResponse().setResponseCode(500))
        val c = client()
        assertTrue(c.health()); assertFalse(c.health()); assertFalse(c.health())
        val first = server.takeRequest()
        assertEquals("/health", first.path)
        assertNull(first.getHeader("Authorization"))
    }

    // ---- lenient wire decoding ---------------------------------------------------------------

    @Test fun songsResponse_dropsMalformedRows_keepsPartialFields() {
        val el = PdjJson.lenient.parseToJsonElement(
            """{"songs":[{"songId":"a","name":"A","score":0.5,"reasons":["x","y"]},{"name":"no id"},{"songId":""},{"songId":"b","reasons":"bad","artist":3},7]}""",
        )
        val songs = RecWire.songsResponse(el).songs
        assertEquals(listOf("a", "b"), songs.map { it.songId })
        assertEquals(listOf("x", "y"), songs[0].reasons)
        assertNull(songs[1].reasons)
        assertNull(songs[1].artist)
    }

    @Test fun collectionsResponse_andUploadResponse_lenient() {
        val c = RecWire.collectionsResponse(PdjJson.lenient.parseToJsonElement(
            """{"songId":"s","suggestions":[{"id":"pkt_1","kind":"pocket","name":"N","reasons":["r"]},{"kind":"playlist"}]}""",
        ))
        assertEquals("s", c.songId)
        assertEquals(listOf("pkt_1"), c.suggestions.map { it.id })
        assertEquals(RecUploadResponse(null, null), RecWire.uploadResponse(PdjJson.lenient.parseToJsonElement("[1]")))
        assertEquals(3, RecWire.uploadResponse(PdjJson.lenient.parseToJsonElement("""{"ok":true,"totals":{"plays":3}}""")).totalPlays)
    }

    @Test fun batchWire_keysMatchIosShape() {
        val text = PdjJson.lenient.encodeToString(
            RecUploadBatch(
                deviceId = "d", sentAtMs = 1.0,
                feedback = listOf(RecFeedbackWire("f", 2.0, "s", "rejected", "tile", "zone")),
                playCounts = RecPlayCountsWire(3.0, mapOf("s" to 4), mapOf("s" to 20000)),
                audioQueue = RecAudioQueueWire(4.0, listOf("s")),
            ),
        )
        val o = PdjJson.lenient.parseToJsonElement(text).jsonObject
        assertEquals(setOf("v", "deviceId", "sentAtMs", "feedback", "playCounts", "audioQueue"), o.keys)
        val pc = o["playCounts"]!!.jsonObject
        assertEquals(setOf("atMs", "counts", "lastPlayedDays"), pc.keys)
        assertEquals(setOf("id", "atMs", "songId", "verdict", "surface", "context"), (o["feedback"] as JsonArray)[0].jsonObject.keys)
    }

    // ---- suggestion -> AddTarget --------------------------------------------------------------

    @Test fun resolveTargets_dropsUnresolved_dedupesAgainstRecent_caps() {
        val pockets = listOf(Pocket(id = "pkt_1", name = "P1"), Pocket(id = "pkt_2", name = "P2"))
        val playlists = listOf(Playlist(id = "pls_1", name = "L1", sequences = emptyList()), Playlist(id = "pls_2", name = "L2", sequences = emptyList()))
        val sugg = listOf(
            RecCollectionSuggestionWire("pkt_gone", "pocket"),
            RecCollectionSuggestionWire("pkt_1", "pocket"),
            RecCollectionSuggestionWire("pls_1", "playlist"),
            RecCollectionSuggestionWire("pls_2", "playlist"),
            RecCollectionSuggestionWire("pkt_2", "pocket"),
            RecCollectionSuggestionWire("x", "source"),
        )
        val recent = listOf(AddTarget(AddTarget.Kind.PLAYLIST, "pls_1", sequenceId = "seq"))
        val out = RecSuggestionFilter.resolveTargets(sugg, pockets, playlists, recent, limit = 2)
        assertEquals(listOf("pkt_1" to AddTarget.Kind.POCKET, "pls_2" to AddTarget.Kind.PLAYLIST), out.map { it.id to it.kind })
    }

    @Test fun defaultEnrollProvider_followsRotatedDocAtRequestTime() = runBlocking {
        com.levi.pocketdj.data.config.RemoteEndpoints.resetForTests()
        try {
            val c = RecEngineClient(OkHttpClient(), base = { server.url("/").toString() }, deviceId = { "dev-1" })
            server.enqueue(MockResponse().setBody("{}")); server.enqueue(MockResponse().setBody("{}"))
            c.postEvents(batch(), "K", "p")
            assertEquals(com.levi.pocketdj.data.config.REC_ENGINE_ENROLL_SECRET, server.takeRequest().getHeader("X-PocketDJ-Enroll"))
            val doc = """{"v":1,"env":"green","endpoints":{
              "catalogBase":"https://dgreen123.cloudfront.net",
              "ripsBase":"https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
              "amPlaylistSyncBase":"https://abc123.execute-api.us-west-2.amazonaws.com",
              "recEngineBase":"https://def456.execute-api.us-west-2.amazonaws.com",
              "diagLogsBase":"https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com"},
              "capabilities":{"recEngineEnroll":"rotated-secret-0123456789abcdef"}}"""
            assertTrue(com.levi.pocketdj.data.config.RemoteEndpoints.apply(doc))
            c.postEvents(batch(), "K", "p")
            assertEquals("rotated-secret-0123456789abcdef", server.takeRequest().getHeader("X-PocketDJ-Enroll"))
            assertEquals("rotated-secret-0123456789abcdef", RecCredentials("k", "p").enrollSecret)
        } finally {
            com.levi.pocketdj.data.config.RemoteEndpoints.resetForTests()
        }
    }
}
