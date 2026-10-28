package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.pockets.PocketsCredentials
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

/** Port of InThePocketUploadTests: acks on 2xx only, 404/5xx leave rounds queued, re-send on a moved fingerprint. */
class RoundsClientTest {
    private val nowMs = 1_791_806_400_000L
    private lateinit var server: MockWebServer
    private lateinit var dir: File
    private val creds = PocketsCredentials("key", "ab".repeat(32), enrollSecret = "enroll")

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        dir = java.nio.file.Files.createTempDirectory("itp-client").toFile()
    }

    @After fun tearDown() { server.shutdown(); dir.deleteRecursively() }

    private fun client(file: File = File(dir, "sync.json")) = InThePocketRoundsClient(
        http = OkHttpClient(), baseUrl = { server.url("/").toString() }, syncFile = file,
        clock = { nowMs }, deviceId = { "DEVICE-1" },
    )

    private fun finished(feedback: String? = "loved it", startedMinutesAgo: Double = 60.0): InThePocketRound {
        val base = TestRounds.round(listOf("sng_00000000000a", "sng_00000000000b", "sng_00000000000c"), InThePocketOutcome.Pocket)
        return base.copy(
            startedAtMs = nowMs - startedMinutesAgo * 60_000 + 12_345,
            endedAtMs = nowMs - 30 * 60_000.0, updatedAtMs = nowMs - 30 * 60_000.0,
            feedback = feedback, rating = 5,
            songs = base.songs.map { it.copy(state = InThePocketSongState.COMPLETED, fraction = 0.97) },
        )
    }

    private fun wire(r: InThePocketRound = finished()) = r.wire("INSTALL-1")!!

    @Test fun ackOn2xxOnlyAndFingerprintMoveResends() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        val c = client()
        val round = finished()
        val w = wire(round)
        assertTrue(c.flush(creds, listOf(w), "INSTALL-1"))
        assertEquals(w.fingerprint, c.acknowledged[w.id])

        // Nothing moved -> nothing re-sent.
        assertFalse(c.flush(creds, listOf(w), "INSTALL-1"))
        assertEquals(1, server.requestCount)

        // Feedback edited (updatedAtMs moves) -> re-sent with the new text.
        server.enqueue(MockResponse().setBody("{}"))
        val edited = round.copy(feedback = "actually too slow", updatedAtMs = round.updatedAtMs + 1000)
        assertTrue(c.flush(creds, listOf(wire(edited)), "INSTALL-1"))
        assertEquals(2, server.requestCount)
        server.takeRequest()
        val second = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("actually too slow", second["rounds"]!!.jsonArray[0].jsonObject["feedback"]!!.jsonPrimitive.content)
    }

    @Test fun queuedOn404ThenRetriedWhenTheRouteShips() = runBlocking {
        val c = client()
        val w = wire()
        server.enqueue(MockResponse().setResponseCode(404))
        assertFalse(c.flush(creds, listOf(w), "I"))
        assertTrue("a 404 acknowledges nothing", c.acknowledged.isEmpty())
        assertFalse(c.roundsServiceAvailable.value)

        server.enqueue(MockResponse().setResponseCode(404))
        assertFalse(c.flush(creds, listOf(w), "I"))
        assertEquals("still asked again", 2, server.requestCount)

        server.enqueue(MockResponse().setBody("{}"))
        assertTrue(c.flush(creds, listOf(w), "I"))
        assertEquals(1, c.acknowledged.size)
        assertTrue(c.roundsServiceAvailable.value)
    }

    @Test fun serverErrorsKeepRoundsQueuedToo() = runBlocking {
        val c = client()
        val w = wire()
        server.enqueue(MockResponse().setResponseCode(503))
        assertFalse(c.flush(creds, listOf(w), "I"))
        assertTrue(c.acknowledged.isEmpty())
        assertTrue("a 503 does not read as 'route missing'", c.roundsServiceAvailable.value)
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"key-mismatch"}"""))
        assertFalse(c.flush(creds, listOf(w), "I"))
        assertTrue(c.acknowledged.isEmpty())
        server.enqueue(MockResponse().setBody("{}"))
        assertTrue(c.flush(creds, listOf(w), "I"))
        assertEquals(1, c.acknowledged.size)
    }

    @Test fun transportFailureKeepsRoundsQueued() = runBlocking {
        val c = InThePocketRoundsClient(
            OkHttpClient(), { "http://127.0.0.1:1/" }, File(dir, "sync.json"), { nowMs },
        )
        assertFalse(c.flush(creds, listOf(wire()), "I"))
        assertTrue(c.acknowledged.isEmpty())
    }

    @Test fun batchCapIsFifty() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setBody("{}")) }
        val c = client()
        val wires = (0 until 120).map { wire() }
        assertTrue(c.flush(creds, wires, "I"))
        val sizes = (0 until 3).map {
            Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject["rounds"]!!.jsonArray.size
        }
        assertEquals(listOf(50, 50, 20), sizes)
        assertEquals(120, c.acknowledged.size)
    }

    @Test fun partialFailureAcksOnlyTheSentBatches() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        server.enqueue(MockResponse().setResponseCode(500))
        val c = client()
        val wires = (0 until 80).map { wire() }
        assertTrue(c.flush(creds, wires, "I"))
        assertEquals(50, c.acknowledged.size)
    }

    @Test fun headersPathAndBodyShape() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        val c = client()
        val w = wire()
        c.flush(creds, listOf(w), "INSTALL-1")
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/pockets/rounds", req.path)
        assertEquals("Bearer key", req.getHeader("Authorization"))
        assertEquals("DEVICE-1", req.getHeader("X-PocketDJ-Device"))
        assertEquals("ab".repeat(32), req.getHeader("X-PocketDJ-Profile"))
        assertEquals("enroll", req.getHeader("X-PocketDJ-Enroll"))
        assertTrue(req.getHeader("Content-Type")!!.startsWith("application/json"))
        val doc = Json.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals("1", doc["v"]!!.jsonPrimitive.content)
        assertEquals("INSTALL-1", doc["installId"]!!.jsonPrimitive.content)
        assertEquals("DEVICE-1", doc["deviceId"]!!.jsonPrimitive.content)
        assertEquals(nowMs.toString(), doc["sentAtMs"]!!.jsonPrimitive.content)
        val r = doc["rounds"]!!.jsonArray[0].jsonObject
        assertEquals(w.id, r["id"]!!.jsonPrimitive.content)
        assertEquals("pocket", r["outcome"]!!.jsonPrimitive.content)
        assertEquals("loved it", r["feedback"]!!.jsonPrimitive.content)
        assertEquals("nullable fields are explicit nulls", JsonNull, r["brokeAt"])
        assertEquals(0L, r["startedAtMs"]!!.jsonPrimitive.content.toLong() % 60_000)
        assertNull("display labels never upload", r["contextLabel"])
    }

    @Test fun enrollHeaderOmittedWhenSecretEmpty() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        client().flush(creds.copy(enrollSecret = ""), listOf(wire()), "I")
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Enroll"))
    }

    @Test fun roundsBeforeTheDeleteFloorNeverUpload() = runBlocking {
        val c = client()
        c.setUploadFloor(nowMs - 30 * 60_000.0)
        assertFalse(c.flush(creds, listOf(wire(finished(startedMinutesAgo = 60.0))), "I"))
        assertEquals(0, server.requestCount)
    }

    @Test fun roundsOlderThanNinetyDaysNeverUpload() = runBlocking {
        val old = wire(finished(startedMinutesAgo = 91 * 24 * 60.0))
        assertFalse(client().flush(creds, listOf(old), "I"))
        assertEquals(0, server.requestCount)
    }

    @Test fun acknowledgementsPersistAcrossRestartAndPruneForgottenRounds() = runBlocking {
        val file = File(dir, "sync.json")
        server.enqueue(MockResponse().setBody("{}"))
        val w = wire()
        client(file).flush(creds, listOf(w), "I")
        val reborn = client(file)
        assertEquals(mapOf(w.id to w.fingerprint), reborn.acknowledged)
        assertFalse("already acknowledged survives a restart", reborn.flush(creds, listOf(w), "I"))
        assertEquals(1, server.requestCount)
        // The round left the store -> its ack is pruned on the next flush.
        reborn.flush(creds, emptyList(), "I")
        assertTrue(reborn.acknowledged.isEmpty())
        assertTrue(client(file).acknowledged.isEmpty())
    }

    @Test fun corruptSyncFileStartsEmpty() = runBlocking {
        val file = File(dir, "sync.json").also { it.writeText("{{{") }
        assertTrue(client(file).acknowledged.isEmpty())
    }

    @Test fun floorMovedMidFlightRecordsNoAcks() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        lateinit var c: InThePocketRoundsClient
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            c.setUploadFloor(nowMs.toDouble() + 1) // "Delete cloud data" lands while the POST is in flight
            chain.proceed(chain.request())
        }.build()
        c = InThePocketRoundsClient(http, { server.url("/").toString() }, File(dir, "sync.json"), { nowMs })
        assertFalse(c.flush(creds, listOf(wire()), "I"))
        assertTrue(c.acknowledged.isEmpty())
    }
}
