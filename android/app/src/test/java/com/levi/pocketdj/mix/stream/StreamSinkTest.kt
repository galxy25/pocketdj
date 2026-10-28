package com.levi.pocketdj.mix.stream

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class StreamSinkTest {
    private val origin = Origin()
    private val server = MockWebServer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val events = CopyOnWriteArrayList<StreamSink.Event>()
    private lateinit var dir: File
    private lateinit var sink: StreamSink

    @Before fun setUp() {
        server.dispatcher = origin
        server.start()
        dir = Files.createTempDirectory("sink").toFile()
        sink = StreamSink(OkHttpClient(), scope) { events += it }
    }

    @After fun tearDown() {
        scope.cancel()
        runCatching { server.shutdown() }
        dir.deleteRecursively()
    }

    private fun url(p: String) = server.url(p).toString()
    private fun finished() = events.filterIsInstance<StreamSink.Event.Finished>()

    @Test fun fullBodyEmitsResponseThenBytesThenFinishedInOrder() {
        val body = bytesOf(600_000)
        origin.bodies["/a"] = body
        val f = File(dir, "a.mp3").apply { createNewFile() }
        sink.start(1, url("/a"), f, 0)
        waitUntil(what = "finish") { finished().isNotEmpty() }
        val kinds = events.map { it::class.simpleName }
        assertEquals("Response", kinds.first())
        assertEquals("Finished", kinds.last())
        assertTrue(kinds.drop(1).dropLast(1).all { it == "Bytes" })
        val resp = events.first() as StreamSink.Event.Response
        assertEquals(200, resp.status)
        assertEquals(600_000L, resp.expected)
        val fin = finished().single()
        assertNull(fin.error)
        assertEquals(600_000L, fin.total)
        // deltas add up to the whole body and totals never go backwards
        val bytes = events.filterIsInstance<StreamSink.Event.Bytes>()
        assertEquals(600_000L, bytes.sumOf { it.delta })
        assertEquals(bytes.map { it.total }, bytes.map { it.total }.sorted())
        assertArrayEquals(body, f.readBytes())
    }

    @Test fun rangeResumeAppendsAndReportsContentRangeTotal() {
        val body = bytesOf(10_000)
        origin.bodies["/r"] = body
        val f = File(dir, "r.mp3").apply { writeBytes(body.copyOf(4_000)) }
        sink.start(2, url("/r"), f, 4_000)
        waitUntil(what = "finish") { finished().isNotEmpty() }
        assertEquals(listOf("bytes=4000-"), origin.ranges("/r"))
        val resp = events.first() as StreamSink.Event.Response
        assertEquals(206, resp.status)
        assertEquals(10_000L, resp.contentRangeTotal)
        assertEquals(10_000L, finished().single().total)
        assertArrayEquals(body, f.readBytes())
    }

    @Test fun serverIgnoringRangeRestartsTheFileAtZero() {
        val body = bytesOf(5_000)
        origin.bodies["/w"] = body
        origin.ignoreRange += "/w"
        val f = File(dir, "w.mp3").apply { writeBytes(ByteArray(2_000) { 9 }) }
        sink.start(3, url("/w"), f, 2_000)
        waitUntil(what = "finish") { finished().isNotEmpty() }
        assertEquals(200, (events.first() as StreamSink.Event.Response).status)
        assertEquals(5_000L, finished().single().total) // total restarted, not 7000
        assertArrayEquals(body, f.readBytes())
    }

    @Test fun non2xxEmitsOnlyTheResponse() {
        origin.status["/x"] = 403
        val f = File(dir, "x.mp3").apply { createNewFile() }
        sink.start(4, url("/x"), f, 0)
        waitUntil(what = "response") { events.isNotEmpty() }
        Thread.sleep(150)
        assertEquals(1, events.size)
        assertEquals(403, (events.single() as StreamSink.Event.Response).status)
        assertEquals(0L, f.length())
        assertFalse(sink.isActive(4))
    }

    @Test fun droppedConnectionFinishesWithErrorAndPartialTotal() {
        origin.bodies["/d"] = bytesOf(200_000)
        origin.alwaysDrop += "/d"
        val f = File(dir, "d.mp3").apply { createNewFile() }
        sink.start(5, url("/d"), f, 0)
        waitUntil(what = "finish") { finished().isNotEmpty() }
        val fin = finished().single()
        assertNotNull(fin.error)
        assertTrue(fin.total in 1 until 200_000)
        assertEquals(fin.total, f.length()) // what arrived is on disk: the resume offset
    }

    @Test fun cancelSilencesTheTransfer() {
        origin.bodies["/c"] = bytesOf(100_000)
        origin.throttle["/c"] = 1_000
        val f = File(dir, "c.mp3").apply { createNewFile() }
        sink.start(6, url("/c"), f, 0)
        waitUntil(what = "response") { events.isNotEmpty() }
        sink.cancel(6)
        val n = events.size
        Thread.sleep(500)
        assertEquals(n, events.size)
        assertTrue(finished().isEmpty())
        assertFalse(sink.isActive(6))
    }
}
