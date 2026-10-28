package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.rips.RipServerClient
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class StemClientTest {
    private lateinit var server: MockWebServer
    private lateinit var file: File
    private var slept = 0

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        file = Files.createTempFile("dmx", ".m4a").toFile().also { it.writeBytes(ByteArray(2048) { i -> i.toByte() }) }
    }
    @After fun tearDown() { server.shutdown(); file.delete() }

    private fun client(token: String = "", base: String = server.url("/").toString(), now: () -> Long = System::currentTimeMillis, max: Long = 60_000) =
        DemuxStemClient(
            OkHttpClient(), { RipServerClient.Config(base, token, "install-1") }, { "https://rips.example/" },
            pollMs = 1, maxWaitMs = max, nowMs = now, sleep = { slept++ },
        )

    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    @Test fun customIdRegexAcceptsStudioPrefixesAndRejectsCatalogAndJunk() {
        for (id in listOf("dmx_ab12cd34", "smp_5f3a-11", "lp_x", "ptn_1", "tk_9", "slc_a-b")) assertTrue(id, DemuxSource.isCustomStemId(id))
        for (id in listOf("sng_123", "slc_a_b", "pdj_9", "dmx_", "dmx_a/b", "dmx_a b", "../dmx_a", "dmx_" + "a".repeat(81), "")) assertFalse(id, DemuxSource.isCustomStemId(id))
    }

    @Test fun uploadThenPollToReadyReturnsAbsoluteStemUrls() = runBlocking {
        server.enqueue(json("""{"phase":"queued","jobId":"job-7"}"""))
        server.enqueue(json("""{"phase":"stemming","jobId":"job-7"}"""))
        server.enqueue(json("""{"phase":"ready","jobId":"job-7","stems":{"vocals":"rips/stems/dmx_a1/vocals.mp3","drums":"rips/stems/dmx_a1/drums.mp3","bass":"rips/stems/dmx_a1/bass.mp3","other":"rips/stems/dmx_a1/other.mp3"}}"""))
        val out = client(token = "tok").stemifyCustom("dmx_a1", file)!!
        assertEquals(listOf("vocals", "drums", "bass", "other").toSet(), out.keys)
        assertEquals("https://rips.example/rips/stems/dmx_a1/vocals.mp3", out["vocals"])
        val up = server.takeRequest()
        assertEquals("POST", up.method)
        assertEquals("/stemify-custom?id=dmx_a1&ext=m4a", up.path)
        assertEquals("application/octet-stream", up.getHeader("Content-Type"))
        assertEquals(2048L, up.bodySize)
        assertEquals("Bearer tok", up.getHeader("Authorization"))
        assertEquals("install-1", up.getHeader("X-PocketDJ-Device"))
        assertEquals("/jobs/job-7", server.takeRequest().path)
        assertEquals("/jobs/job-7", server.takeRequest().path)
        assertEquals(3, server.requestCount)
        assertEquals("slept between polls", 2, slept)
    }

    @Test fun readyOnUploadSkipsPollingAndTokenlessServerSendsNoAuthHeader() = runBlocking {
        server.enqueue(json("""{"phase":"ready","stems":{"vocals":"a.mp3","drums":"b.mp3","bass":"c.mp3","other":"d.mp3"}}"""))
        val out = client().stemifyCustom("smp_9", file)!!
        assertEquals("https://rips.example/a.mp3", out["vocals"])
        assertNull(server.takeRequest().getHeader("Authorization"))
        assertEquals(1, server.requestCount)
    }

    @Test fun pollSurfacesErrorAndIneligibleAsFailure() = runBlocking {
        server.enqueue(json("""{"phase":"queued","jobId":"j"}"""))
        server.enqueue(json("""{"phase":"error","jobId":"j","error":"demucs crashed"}"""))
        assertNull(client().stemifyCustom("dmx_e", file))
        server.enqueue(json("""{"phase":"ineligible"}"""))
        assertNull(client().stemifyCustom("dmx_f", file))
    }

    @Test fun rejectedUploadUnreachableServerAndNoServerAllFailQuietly() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"nope"}"""))
        assertNull(client().stemifyCustom("dmx_g", file))
        assertNull(client(base = "http://127.0.0.1:1/").stemifyCustom("dmx_h", file))
        assertNull(client(base = "").stemifyCustom("dmx_i", file))
    }

    @Test fun catalogIdsAndMissingFilesNeverReachTheNetwork() = runBlocking {
        assertNull(client().stemifyCustom("sng_1", file))
        assertNull(client().stemifyCustom("dmx_ok", File("/no/such/file.m4a")))
        assertEquals(0, server.requestCount)
    }

    @Test fun readyWithoutStemsIsAFailureAndASingleDroppedPollIsRetried() = runBlocking {
        server.enqueue(json("""{"phase":"ready"}"""))
        assertNull(client().stemifyCustom("dmx_j", file))
        server.enqueue(json("""{"phase":"queued","jobId":"j2"}"""))
        server.enqueue(MockResponse().setResponseCode(500))
        server.enqueue(json("""{"phase":"ready","stems":{"vocals":"v","drums":"d","bass":"b","other":"o"}}"""))
        assertEquals("https://rips.example/v", client().stemifyCustom("dmx_k", file)!!["vocals"])
    }

    @Test fun pollGivesUpAtTheDeadline() = runBlocking {
        server.enqueue(json("""{"phase":"queued","jobId":"j3"}"""))
        for (i in 1..50) server.enqueue(json("""{"phase":"stemming","jobId":"j3"}"""))
        var t = 0L
        val c = client(now = { t += 1_000; t }, max = 5_000)
        assertNull(c.stemifyCustom("dmx_l", file))
        assertTrue(server.requestCount in 2..8)
    }
}
