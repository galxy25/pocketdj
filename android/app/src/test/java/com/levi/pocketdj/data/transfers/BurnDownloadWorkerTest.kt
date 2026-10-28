package com.levi.pocketdj.data.transfers

import java.io.File
import java.io.IOException
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnDownloadWorkerTest {
    private val server = MockWebServer().apply { start() }
    private val http = OkHttpClient()
    private val dir = File(tmpTransferDir(), "burns")

    @After fun tearDown() = server.shutdown()

    private fun url(path: String = "/a.mp3") = server.url(path).toString()

    private fun outcome(r: TransferRecord, resp: MockResponse, onBytes: (Long) -> Unit = {}): DownloadOutcome {
        server.enqueue(resp)
        val response = http.newCall(okhttp3.Request.Builder().url(url()).build()).execute()
        return DownloadOutcome.from(response, r, dir, onBytes)
    }

    private val xmlError = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>InvalidArgument</Code>" +
        "<Message>Unsupported Authorization Type</Message>" + "x".repeat(380) + "</Error>"

    @Test fun http400WithXmlBodyFailsAndLeavesNoAudio() {
        assertTrue(xmlError.length in 400..600)
        val o = outcome(rec("s1"), MockResponse().setResponseCode(400).setBody(xmlError))
        assertEquals(DownloadOutcome.Failed("download failed (HTTP 400)", 400), o)
        assertFalse(File(dir, "s1.mp3").exists())
        assertFalse(File(dir, "s1.mp3.part").exists())
        assertFalse(File(dir, "s1.txt").exists())
    }

    @Test fun http500NeverFinalized() {
        val o = outcome(rec("s1"), MockResponse().setResponseCode(503).setBody("busy"))
        assertTrue(o is DownloadOutcome.Failed)
        assertTrue(dir.list().orEmpty().isEmpty())
    }

    @Test fun http200ErrorDocumentIsRejectedAsPoisoned() {
        val o = outcome(rec("s1"), MockResponse().setBody(xmlError))
        assertEquals(DownloadOutcome.Failed("server returned an error document"), o)
        assertFalse(File(dir, "s1.mp3").exists())
        assertFalse(File(dir, "s1.mp3.part").exists())
    }

    @Test fun successWritesAudioAtomicallyAndSidecarFromRecord() {
        val body = ByteArray(10_000) { 7 }
        var seen = 0L
        val o = outcome(rec("s1"), MockResponse().setBody(Buffer().write(body)), onBytes = { seen += it })
        assertEquals(DownloadOutcome.Done(10_000), o)
        assertEquals(10_000L, seen)
        assertEquals(10_000L, File(dir, "s1.mp3").length())
        assertEquals("BPM: 120\n", File(dir, "s1.txt").readText())
        assertTrue(dir.list()!!.none { it.endsWith(".part") })
    }

    @Test fun replacesExistingDigitalFile() {
        dir.mkdirs(); File(dir, "s1.mp3").writeBytes(ByteArray(5_000) { 1 })
        val o = outcome(rec("s1"), MockResponse().setBody(Buffer().write(ByteArray(8_000) { 2 })))
        assertEquals(DownloadOutcome.Done(8_000), o)
    }

    @Test fun analogSharedAlbumFileIsNotClobberedButSidecarIsWritten() {
        dir.mkdirs(); File(dir, "album.mp3").writeBytes(ByteArray(6_000) { 9 })
        val r = rec("s2", audio = "album.mp3", sidecar = "s2.txt", source = "analog")
        val o = outcome(r, MockResponse().setBody(Buffer().write(ByteArray(100) { 1 })))
        assertEquals(DownloadOutcome.Done(6_000), o)
        assertTrue(File(dir, "album.mp3").readBytes().all { it == 9.toByte() })
        assertTrue(File(dir, "s2.txt").isFile)
    }

    @Test fun emptySidecarNameWritesNoSidecar() {
        val o = outcome(rec("s1", sidecar = ""), MockResponse().setBody(Buffer().write(ByteArray(5_000))))
        assertTrue(o is DownloadOutcome.Done)
        assertEquals(listOf("s1.mp3"), dir.list()!!.toList())
    }

    @Test fun truncatedTransportIsRetryableAndLeavesNoPart() {
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(50_000))).setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
        val response = http.newCall(okhttp3.Request.Builder().url(url()).build()).execute()
        val o = DownloadOutcome.from(response, rec("s1"), dir)
        assertTrue(o is DownloadOutcome.Retry)
        assertFalse(File(dir, "s1.mp3").exists())
        assertFalse(File(dir, "s1.mp3.part").exists())
    }

    // ---- runner (the worker body) -------------------------------------------------------------

    private fun runner(c: TransferCoordinator, attempts: Int = 3) =
        BurnDownloadRunner(c, http, { dir }, maxAttempts = attempts)

    private suspend fun coordinatorWith(vararg ids: String, token: String = ""): TransferCoordinator {
        val c = TransferCoordinator(File(tmpTransferDir(), "t.json"), FakeTransferWork(), tokenProvider = { token })
        ids.forEach { c.enqueue(url(), rec(it)) }
        return c
    }

    @Test fun runnerFinalizesAndDropsRecord() = runTest {
        val c = coordinatorWith("s1")
        var fin: Long? = null
        c.onBurnFinalized = { _, b -> fin = b }
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(9_000))))
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner(c).run("s1", url(), false, 0))
        assertEquals(9_000L, fin)
        assertTrue(c.records.isEmpty())
        assertEquals(1, c.counters().finished)
    }

    @Test fun runner400FailsRecordWithNoAudioFile() = runTest {
        val c = coordinatorWith("s1")
        var msg: String? = null
        c.onBurnFailed = { _, m -> msg = m }
        server.enqueue(MockResponse().setResponseCode(400).setBody(xmlError))
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner(c).run("s1", url(), false, 0))
        assertEquals("download failed (HTTP 400)", msg)
        assertTrue(c.records.isEmpty())
        assertNull(dir.list()?.firstOrNull { it.endsWith(".mp3") })
    }

    @Test fun runnerRetriesTransientThenFailsAtMaxAttempts() = runTest {
        val c = coordinatorWith("s1")
        var msg: String? = null
        c.onBurnFailed = { _, m -> msg = m }
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        assertEquals(BurnDownloadRunner.Result.RETRY, runner(c, 3).run("s1", url(), false, 0))
        assertEquals(1, c.records.size) // still pending
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner(c, 3).run("s1", url(), false, 2))
        assertTrue(msg != null)
        assertTrue(c.records.isEmpty())
    }

    @Test fun runnerWithoutRecordDoesNothing() = runTest {
        val c = coordinatorWith()
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner(c).run("ghost", url(), false, 0))
        assertEquals(0, server.requestCount)
    }

    @Test fun runnerAttachesBearerOnlyWhenFlagged() = runTest {
        val c = coordinatorWith("s1", "s2", token = "secret")
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(5_000))))
        runner(c).run("s1", url(), true, 0)
        assertEquals("Bearer secret", server.takeRequest().getHeader("Authorization"))
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(5_000))))
        runner(c).run("s2", url(), false, 0)
        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test fun runnerDoesNotResurrectCancelledRecord() = runTest {
        val c = coordinatorWith("s1")
        var finalized = false
        c.onBurnFinalized = { _, _ -> finalized = true }
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(5_000))))
        c.cancel(listOf("s1"))
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner(c).run("s1", url(), false, 0))
        assertFalse(finalized)
    }

    @Test fun siblingAnalogRecordsDownloadAlbumOnceAndNeverCorrupt() = runTest {
        val dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest) =
                MockResponse().setBody(Buffer().write(ByteArray(20_000) { 5 })).throttleBody(10_000, 50, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
        server.dispatcher = dispatcher
        val c = TransferCoordinator(java.io.File(tmpTransferDir(), "t.json"), FakeTransferWork())
        val recs = listOf("a", "b", "c").map { rec(it, audio = "album.mp3", sidecar = "$it.txt", source = "analog") }
        for (r in recs) c.enqueue(url(), r)
        val runner = BurnDownloadRunner(c, http, { dir })
        val results = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            kotlinx.coroutines.coroutineScope {
                recs.map { r -> async { runner.run(r.songId, url(), false, 0) } }.map { it.await() }
            }
        }
        assertTrue(results.all { it == BurnDownloadRunner.Result.SUCCESS })
        assertEquals(1, server.requestCount)
        assertTrue(File(dir, "album.mp3").readBytes().let { it.size == 20_000 && it.all { b -> b == 5.toByte() } })
        assertTrue(listOf("a", "b", "c").all { File(dir, "$it.txt").isFile })
        assertTrue(dir.list()!!.none { it.endsWith(".part") })
        assertTrue(c.records.isEmpty())
    }

    @Test fun expiredPresignRetriesOnceWithFreshUrl() = runTest {
        server.enqueue(MockResponse().setResponseCode(403).setBody("expired"))
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(6_000) { 1 })))
        val c = TransferCoordinator(java.io.File(tmpTransferDir(), "t.json"), FakeTransferWork())
        c.enqueue(url("/old"), rec("s1"))
        val runner = BurnDownloadRunner(c, http, { dir }, refreshUrl = { url("/fresh") })
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner.run("s1", url("/old"), false, 0))
        assertEquals(6_000L, File(dir, "s1.mp3").length())
        server.takeRequest()
        assertEquals("/fresh", server.takeRequest().path)
    }
}
