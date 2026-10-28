package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.rips.RipManifestEntry
import java.io.File
import java.io.IOException
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The real download path against MockWebServer: what must NEVER be finalized as audio. */
class HttpBurnRipsTest {
    private val server = MockWebServer().apply { start() }
    @After fun stop() = server.shutdown()

    private val entries = HashMap<String, RipManifestEntry>()
    private var configured = true
    private var presignCalls = 0
    private var presignFailures = 0

    private fun rips() = HttpBurnRips(
        http = OkHttpClient(),
        manifestEntry = { entries[it] },
        serverConfigured = { configured },
        presign = { id, ttl ->
            presignCalls++
            if (presignFailures-- > 0) throw IOException("cold ingress")
            server.url("/presigned/$id?ttl=$ttl").toString()
        },
        ripsBase = { server.url("/").toString().trimEnd('/') },
    )

    @Test fun streamsBodyToDestAndNeverAttachesAnAuthorizationHeader() = runTest {
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(10_000) { 1 })))
        val dest = File(tmpDir(), "a/b.mp3")
        assertEquals(10_000L, rips().download(server.url("/x.mp3").toString(), dest))
        assertEquals(10_000L, dest.length())
        assertNull(server.takeRequest().getHeader("Authorization"))
        assertFalse(File(dest.parentFile, "b.mp3.part").exists())
    }

    @Test fun non2xxIsRejectedAndLeavesNothingBehind() = runTest {
        server.enqueue(MockResponse().setResponseCode(400).setBody("<?xml version=\"1.0\"?><Error>InvalidArgument</Error>"))
        val dest = File(tmpDir(), "b.mp3")
        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { rips().download(server.url("/x").toString(), dest) } }
        assertFalse(dest.exists()); assertFalse(File(dest.parentFile, "b.mp3.part").exists())
    }

    @Test fun a200WithAnXmlErrorBodyIsNeverFinalizedAsAudio() = runTest {
        server.enqueue(MockResponse().setResponseCode(200).setBody("<?xml version=\"1.0\"?><Error><Code>AccessDenied</Code></Error>"))
        val dest = File(tmpDir(), "c.mp3").also { it.writeText("previous good file") }
        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { rips().download(server.url("/x").toString(), dest) } }
        assertEquals("previous good file", dest.readText()) // existing file survives a failed re-download
    }

    @Test fun presignRetriesOnceThenGivesUp() = runTest {
        entries["s"] = digital("s")
        presignFailures = 1
        val url = rips().durableUrl("s")!!
        assertTrue(url.contains("ttl=21600")); assertEquals(2, presignCalls)
        presignCalls = 0; presignFailures = 5
        assertNull(rips().durableUrl("s")); assertEquals(2, presignCalls)
        assertNull(rips().durableUrl("unknown"))
    }

    @Test fun serverlessUsesTheDirectKeyUrl() = runTest {
        entries["s"] = digital("s"); configured = false
        assertEquals(server.url("/rips/s.mp3").toString(), rips().durableUrl("s"))
        assertEquals(0, presignCalls)
    }

    @Test fun lastModifiedParsesTheHeadDateAndNullsOffline() = runTest {
        server.enqueue(MockResponse().setHeader("Last-Modified", "Tue, 21 Oct 2025 07:28:00 GMT"))
        assertEquals(1761031680000.0, rips().lastModifiedMs(server.url("/c").toString())!!, 0.0)
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(rips().lastModifiedMs(server.url("/c").toString()))
        server.shutdown()
        assertNull(rips().lastModifiedMs("http://127.0.0.1:1/c"))
    }

    @Test fun outOfSpaceDetectionWalksTheCauseChain() {
        assertTrue(isOutOfSpace(IOException("write failed: ENOSPC (No space left on device)")))
        assertTrue(isOutOfSpace(RuntimeException("x", OutOfSpaceException())))
        assertFalse(isOutOfSpace(IOException("HTTP 500")))
        assertFalse(isOutOfSpace(null))
    }
}
