package com.levi.pocketdj.studio.audio

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class LocalAudioCacheTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var dir: File

    private class FakeBackend : LocalAudioCache.Backend {
        var local: LocalSource? = null
        var manifest = true
        var outcome = PrepareOutcome(ok = true)
        var onBurn: (() -> Unit)? = null
        var url: String? = null
        var burns = 0
        override fun local(songId: String) = local
        override fun inManifest(songId: String) = manifest
        override suspend fun burn(songId: String, title: String, artist: String): PrepareOutcome {
            burns++; onBurn?.invoke(); return outcome
        }
        override suspend fun durableUrl(songId: String) = url
        override fun startMs(songId: String) = 4000
    }

    @Before fun setUp() { server = MockWebServer(); server.start(); dir = File(tmp.root, "studio-src") }
    @After fun tearDown() { server.shutdown() }

    private fun cache(b: LocalAudioCache.Backend = FakeBackend()) =
        LocalAudioCache(dir, OkHttpClient(), b, Dispatchers.IO)

    @Test fun downloadIsAtomicAndLeavesNoPartial() = runBlocking {
        server.enqueue(MockResponse().setHeader("Content-Type", "audio/mpeg").setBody("ID3-audio-bytes"))
        val f = cache().fetch("sng_1", server.url("/rips/a.mp3").toString())
        assertEquals("sng_1.mp3", f.name)
        assertEquals("ID3-audio-bytes", f.readText())
        assertEquals(listOf("sng_1.mp3"), dir.list()!!.toList())
    }

    @Test fun partialDownloadIsNeverVisibleUnderTheFinalName() = runBlocking {
        // Body is cut short mid-stream: the final file must not exist and the .part must be cleaned up.
        server.enqueue(MockResponse().setHeader("Content-Type", "audio/mpeg").setBody(Buffer().writeUtf8("x".repeat(5000)))
            .setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
        val c = cache()
        var failed = false
        try { c.fetch("sng_2", server.url("/a.mp3").toString()) } catch (_: Exception) { failed = true }
        assertTrue(failed)
        assertFalse(File(dir, "sng_2.mp3").exists())
        assertEquals(emptyList<String>(), dir.list()?.toList() ?: emptyList<String>())
    }

    @Test fun duringDownloadOnlyPartExists() {
        val gate = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                gate.await(5, TimeUnit.SECONDS)
                return MockResponse().setHeader("Content-Type", "audio/mpeg").setBody("data")
            }
        }
        runBlocking {
            val c = cache()
            val job = async(Dispatchers.IO) { c.fetch("sng_3", server.url("/a.mp3").toString()) }
            val deadline = System.currentTimeMillis() + 3000
            while (!c.isInFlight("sng_3") && System.currentTimeMillis() < deadline) Thread.sleep(5)
            assertTrue(c.isInFlight("sng_3"))
            assertFalse(File(dir, "sng_3.mp3").exists())
            gate.countDown()
            assertEquals("data", job.await().readText())
            assertFalse(c.isInFlight("sng_3"))
        }
    }

    @Test fun concurrentFetchesOfTheSameKeyShareOneRequest() = runBlocking {
        val hits = AtomicInteger()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                hits.incrementAndGet(); Thread.sleep(150)
                return MockResponse().setHeader("Content-Type", "audio/mpeg").setBody("same")
            }
        }
        val c = cache()
        val url = server.url("/a.mp3").toString()
        val files = (1..5).map { async(Dispatchers.IO) { c.fetch("sng_4", url) } }.awaitAll()
        assertEquals(1, hits.get())
        assertTrue(files.all { it.readText() == "same" })
        // A finished file is reused without a new request.
        c.fetch("sng_4", url)
        assertEquals(1, hits.get())
    }

    @Test fun nonSuccessAndErrorDocumentsAreRejected() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(403).setBody("denied"))
        server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody("<html>oops</html>"))
        val c = cache()
        for (k in listOf("a", "b")) {
            var failed = false
            try { c.fetch(k, server.url("/x").toString()) } catch (_: Exception) { failed = true }
            assertTrue(failed)
            assertFalse(File(dir, "$k.mp3").exists())
        }
    }

    @Test fun sweepPartialsRemovesKilledDownloads() {
        dir.mkdirs()
        File(dir, "x.mp3.part").writeText("junk"); File(dir, "y.mp3").writeText("ok")
        assertEquals(1, cache().sweepPartials())
        assertEquals(listOf("y.mp3"), dir.list()!!.toList())
    }

    // ---- ladder -------------------------------------------------------------------------------

    @Test fun phaseLadder() {
        val b = FakeBackend(); val c = cache(b)
        assertEquals(SourcePhase.NeedsBurn, c.phaseFor("s"))
        b.manifest = false
        assertEquals(SourcePhase.RipFirst, c.phaseFor("s"))
        val src = LocalSource(File("x.mp3"), isCut = false, offsetMs = 0)
        b.local = src
        assertEquals(SourcePhase.Ready(src), c.phaseFor("s"))
    }

    @Test fun prepareRipFirstWhenNotInManifest() = runBlocking {
        val b = FakeBackend().apply { manifest = false }
        assertEquals(SourcePhase.RipFirst, cache(b).prepare("s", "t", "a"))
        assertEquals(0, b.burns)
    }

    @Test fun prepareBurnsThenReady() = runBlocking {
        val b = FakeBackend()
        val src = LocalSource(File("album.mp3"), isCut = false, offsetMs = 4000)
        b.onBurn = { b.local = src }
        assertEquals(SourcePhase.Ready(src), cache(b).prepare("s", "t", "a"))
        assertEquals(1, b.burns)
    }

    @Test fun prepareFailureCopy() = runBlocking {
        val b = FakeBackend()
        b.outcome = PrepareOutcome(ok = false, notRipped = true)
        assertEquals(SourcePhase.Failed(LocalAudioCache.NOT_RIPPED), cache(b).prepare("s", "t", "a"))
        b.outcome = PrepareOutcome(ok = false, outOfSpace = true)
        assertEquals(SourcePhase.Failed(LocalAudioCache.SPACE), cache(b).prepare("s", "t", "a"))
        b.outcome = PrepareOutcome(ok = false)
        assertEquals(SourcePhase.Failed(LocalAudioCache.GENERIC), cache(b).prepare("s", "t", "a"))
        b.outcome = PrepareOutcome(ok = false, folderUnavailable = true)
        assertEquals(SourcePhase.Failed(LocalAudioCache.FOLDER), cache(b).prepare("s", "t", "a"))   // no url to fall back to
    }

    @Test fun unreachableBurnFolderFallsBackToCacheDownload() = runBlocking {
        server.enqueue(MockResponse().setHeader("Content-Type", "audio/mpeg").setBody("album-bytes"))
        val b = FakeBackend().apply {
            outcome = PrepareOutcome(ok = false, folderUnavailable = true); url = server.url("/rips/a.mp3").toString()
        }
        val r = cache(b).prepare("sng_9", "t", "a") as SourcePhase.Ready
        assertEquals("album-bytes", r.source.file.readText())
        assertEquals(4000, r.source.offsetMs)           // analog: album offset still applies (not a cut)
        assertFalse(r.source.isCut)
    }

    @Test fun backendExceptionBecomesGenericFailure() = runBlocking {
        val b = object : LocalAudioCache.Backend {
            override fun local(songId: String): LocalSource? = null
            override fun inManifest(songId: String) = true
            override suspend fun burn(songId: String, title: String, artist: String): PrepareOutcome = throw IllegalStateException("boom")
            override suspend fun durableUrl(songId: String): String? = null
        }
        assertEquals(SourcePhase.Failed(LocalAudioCache.GENERIC), cache(b).prepare("s", "t", "a"))
    }

    @Test fun fileWindowHonoursAnalogOffsetContract() {
        val album = LocalSource(File("album.mp3"), isCut = false, offsetMs = 30_000)
        val cut = LocalSource(File("cut.mp3"), isCut = true, offsetMs = 30_000)
        assertEquals(31_000 to 33_000, LocalAudioCache.fileWindow(album, 1000, 3000))    // starts at entry.startMs + region
        assertEquals(1000 to 3000, LocalAudioCache.fileWindow(cut, 1000, 3000))           // a cut already starts at 0:00
    }
}
