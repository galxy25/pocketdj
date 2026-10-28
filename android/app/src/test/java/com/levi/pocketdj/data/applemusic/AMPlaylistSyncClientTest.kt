package com.levi.pocketdj.data.applemusic

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
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

class AMPlaylistSyncClientTest {
    private lateinit var server: MockWebServer
    private val jobs = InMemoryAmJobStore()
    private var clock = 1_000_000L
    private val progress = mutableListOf<AmJobProgress>()

    @Before fun up() { server = MockWebServer().also { it.start() } }
    @After fun down() { server.shutdown() }

    private fun client(stall: Long = 10_000, interval: Long = 1_000, mut: String? = "MUT") = AMPlaylistSyncClient(
        http = OkHttpClient.Builder().retryOnConnectionFailure(false).build(),
        tokens = StaticAppleMusicTokens("dev", mut),
        jobs = jobs,
        baseProvider = { server.url("/").toString() },
        stallTimeoutMs = stall,
        pollIntervalMs = interval,
        clockMs = { clock },
        sleep = { clock += it }, // virtual time: sleeping advances the fake clock
    )

    private fun json(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setBody(body)
    private fun running(label: String, done: Int? = null, total: Int? = null): MockResponse {
        val p = listOfNotNull("\"label\":\"$label\"", done?.let { "\"done\":$it" }, total?.let { "\"total\":$it" })
        return json("{\"status\":\"running\",\"progress\":{" + p.joinToString(",") + "}}")
    }
    private val pushDone = json(
        """{"status":"done","result":{"playlists":[{"name":"Mix","id":"p.abc","created":true,"added":2,"total":2}],"errors":[{"name":"Bad","error":"nope"}]}}""",
    )
    private fun out() = listOf(
        AmOutgoingPlaylist(
            name = "Mix", trackCatalogIds = listOf("1", "2"),
            trackMeta = listOf(AmOutgoingPlaylist.TrackMeta("1", "A", "X"), AmOutgoingPlaylist.TrackMeta("2", "B", "Y")),
            localPlaylistIds = listOf("pl_1"),
        ),
    )
    private fun recorded() = generateSequence { server.takeRequest(50, TimeUnit.MILLISECONDS) }.toList()

    @Test fun submit202() = runBlocking {
        server.enqueue(json("""{"jobId":"j1"}""", 202))
        server.enqueue(running("Creating playlists", 1, 4))
        server.enqueue(pushDone)
        val res = client().push(out()) { progress += it }

        assertEquals("Mix", res.playlists.single().name)
        assertEquals("p.abc", res.playlists.single().id)
        assertTrue(res.playlists.single().created)
        assertEquals("nope", res.errors.single().error)
        assertEquals(listOf("Creating playlists (1/4)"), progress.map { it.display })

        val reqs = recorded()
        assertEquals("POST", reqs[0].method)
        assertEquals("/push", reqs[0].path)
        val body = Json.parseToJsonElement(reqs[0].body.readUtf8()).jsonObject
        assertEquals("MUT", body["musicUserToken"]!!.jsonPrimitive.content)
        val pl = body["playlists"]!!.jsonArray.single().jsonObject
        assertEquals("Mix", pl["name"]!!.jsonPrimitive.content)
        assertEquals(2, pl["trackCatalogIds"]!!.jsonArray.size)
        assertEquals("B", pl["trackMeta"]!!.jsonArray[1].jsonObject["n"]!!.jsonPrimitive.content)
        assertTrue(pl["localPlaylistIds"] == null) // round-trip handle never leaves the device
        assertEquals("/job/j1", reqs[1].path)
        assertNull("finished job must be cleared", jobs.load("push"))
    }

    @Test fun emptyPushMakesNoRequest() = runBlocking {
        val res = client().push(emptyList())
        assertTrue(res.playlists.isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test fun signedOutThrowsBeforeNetwork() = runBlocking {
        try { client(mut = null).pull(); fail() } catch (e: AmSyncException.NotSignedIn) { /* ok */ }
        assertEquals(0, server.requestCount)
    }

    @Test fun stallResetsOnProgress() = runBlocking {
        server.enqueue(json("""{"jobId":"j1"}""", 202))
        // 8 polls x 1 s sleep with a 3 s stall window: only survives because each poll advances progress.
        for (i in 1..8) server.enqueue(running("Appending", i, 8))
        server.enqueue(pushDone)
        val res = client(stall = 3_000).push(out())
        assertEquals(1, res.playlists.size)
    }

    @Test fun stallWithoutProgressTimesOutAndKeepsJobId() = runBlocking {
        server.enqueue(json("""{"jobId":"j9"}""", 202))
        repeat(20) { server.enqueue(running("Appending", 3, 8)) } // same progress every poll
        try {
            client(stall = 3_000).push(out())
            fail("expected stall")
        } catch (e: AmSyncException.Stalled) {
            assertTrue(e.message!!.contains("Appending (3/8)"))
        }
        assertEquals("a stall is NOT proof the job died: id must survive", "j9", jobs.load("push")?.jobId)
    }

    @Test fun transientAbsorbed() = runBlocking {
        server.enqueue(json("""{"jobId":"j1"}""", 202))
        server.enqueue(json("bad gateway", 502))
        server.enqueue(json("slow down", 429))
        server.enqueue(json("{not json"))
        server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(pushDone)
        val res = client().push(out())
        assertEquals(1, res.playlists.size)
        val reqs = recorded()
        assertEquals("exactly one submit - blips never resubmit", 1, reqs.count { it.method == "POST" })
        assertEquals(5, reqs.count { it.path == "/job/j1" })
    }

    @Test fun jobGoneTerminal() = runBlocking {
        server.enqueue(json("""{"jobId":"j1"}""", 202))
        server.enqueue(json("", 404))
        try { client().push(out()); fail() } catch (e: AmSyncException.JobGone) { /* ok */ }
        assertNull(jobs.load("push"))
    }

    @Test fun hard4xxAndWorkerErrorAreTerminalAndClear() = runBlocking {
        server.enqueue(json("""{"jobId":"j1"}""", 202))
        server.enqueue(json("forbidden", 403))
        try { client().push(out()); fail() } catch (e: AmSyncException.Http) { assertEquals(403, e.code) }
        assertNull(jobs.load("push"))

        server.enqueue(json("""{"jobId":"j2"}""", 202))
        server.enqueue(json("""{"status":"error","error":"MUT rejected"}"""))
        try { client().push(out()); fail() } catch (e: AmSyncException.Worker) { assertEquals("MUT rejected", e.msg) }
        assertNull(jobs.load("push"))
    }

    @Test fun submitFailureStoresNothing() = runBlocking {
        server.enqueue(json("boom", 500))
        try { client().push(out()); fail() } catch (e: AmSyncException.Http) { assertEquals(500, e.code) }
        assertNull(jobs.load("push"))
    }

    @Test fun reattachUsesStoredJob() = runBlocking {
        jobs.store("push", AmJobStore.StoredJob("old-job", clock - 60_000))
        server.enqueue(running("Appending", 5, 9))
        server.enqueue(pushDone)
        val res = client().push(out())
        assertEquals(1, res.playlists.size)
        val reqs = recorded()
        assertTrue("re-attach must not POST a second push", reqs.none { it.method == "POST" })
        assertTrue(reqs.all { it.path == "/job/old-job" })
        assertNull(jobs.load("push"))
    }

    @Test fun staleStoredJobIsIgnored() = runBlocking {
        jobs.store("push", AmJobStore.StoredJob("ancient", clock - 2 * 3_600_000L))
        server.enqueue(json("""{"jobId":"fresh"}""", 202))
        server.enqueue(pushDone)
        client().push(out())
        assertEquals("/job/fresh", recorded()[1].path)
    }

    @Test fun reattachToDeadJobFallsThroughToFreshSubmit() = runBlocking {
        jobs.store("push", AmJobStore.StoredJob("expired", clock - 1_000))
        server.enqueue(json("", 404))                                   // stored job is gone
        server.enqueue(json("""{"jobId":"fresh"}""", 202))
        server.enqueue(pushDone)
        client().push(out())
        val reqs = recorded()
        assertEquals(listOf("/job/expired", "/push", "/job/fresh"), reqs.map { it.path })
    }

    @Test fun reattachTransientFailureKeepsIdAndDoesNotResubmit() = runBlocking {
        jobs.store("push", AmJobStore.StoredJob("live", clock - 1_000))
        repeat(20) { server.enqueue(running("Appending", 1, 2)) }
        try { client(stall = 3_000).push(out()); fail() } catch (e: AmSyncException.Stalled) { /* ok */ }
        assertEquals("live", jobs.load("push")?.jobId)
        assertTrue(recorded().none { it.method == "POST" })
    }

    @Test fun pullDecodesPlaylists() = runBlocking {
        server.enqueue(json("""{"jobId":"p1"}""", 202))
        server.enqueue(
            json("""{"status":"done","result":{"storefront":"us","playlists":[{"id":"p.1","name":"Roadtrip","trackCatalogIds":["10","11"],"canEdit":true,"extra":1}]}}"""),
        )
        val list = client().pull()
        assertEquals(listOf("p.1"), list.map { it.id })
        assertEquals(listOf("10", "11"), list[0].trackCatalogIds)
        assertEquals("/pull", recorded()[0].path)
    }

    @Test fun progressDisplayFormats() {
        assertEquals("Reading", AmJobProgress("Reading").display)
        assertEquals("Reading (4)", AmJobProgress("Reading", 4).display)
        assertEquals("Reading (4/9)", AmJobProgress("Reading", 4, 9).display)
        assertEquals("Reading", AmJobProgress("Reading", 0, 0).display)
    }
}
