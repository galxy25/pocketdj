package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lenient-decode contract for the jukebox wire types (specs/jukebox.md §3):
 * unknown keys never break a decode, absent fields land on defaults, and the
 * persisted session survives a later field addition (ADDITIVE-OPTIONAL law).
 */
class JukeboxModelsDecodeTest {

    private val json = PdjJson.lenient

    /** Shape mirrors jukebox-server.mjs:305-310, plus keys from next week. */
    private val requestsPageFixture = """
        {
          "requests": [
            {
              "id": "rq_1a2b3c",
              "seq": 7,
              "title": "Blue Monday",
              "artist": "New Order",
              "clientId": "guest-phone-77",
              "createdAt": 1753142400000,
              "status": "pending"
            },
            {
              "id": "rq_4d5e6f",
              "seq": 9,
              "title": "Instrumental Thing",
              "artist": "",
              "createdAt": 1753142460000,
              "status": "queued",
              "matchedTitle": "Instrumental Thing (Club Mix)"
            },
            {
              "id": "rq_777777",
              "seq": 10,
              "title": "Future Song",
              "artist": "Someone",
              "createdAt": 1753142470000,
              "status": "played"
            }
          ],
          "seq": 10,
          "someFieldFromNextWeek": { "nested": true }
        }
    """.trimIndent()

    @Test
    fun requestsPage_decodesFixture_ignoringClientIdAndUnknownKeys() {
        val page = json.decodeFromString<JukeboxRequestsPage>(requestsPageFixture)
        assertEquals(10L, page.seq)
        assertEquals(3, page.requests.size)

        val first = page.requests[0]
        assertEquals("rq_1a2b3c", first.id)
        assertEquals(7L, first.seq)
        assertEquals("Blue Monday", first.title)
        assertEquals("New Order", first.artist)
        assertEquals(1_753_142_400_000.0, first.createdAt, 0.0)
        assertEquals(JukeboxRequest.STATUS_PENDING, first.status)

        // Artist may legitimately be "".
        assertEquals("", page.requests[1].artist)
        assertEquals("queued", page.requests[1].status)
    }

    @Test
    fun requestStatus_toleratesUnknownValues() {
        // "played" is documented but never set by broker v2 — must decode fine.
        val page = json.decodeFromString<JukeboxRequestsPage>(requestsPageFixture)
        assertEquals("played", page.requests[2].status)
    }

    @Test
    fun emptyRequestsPage_decodesToDefaults() {
        val page = json.decodeFromString<JukeboxRequestsPage>("""{"requests":[],"seq":0}""")
        assertTrue(page.requests.isEmpty())
        assertEquals(0L, page.seq)
    }

    @Test
    fun createResponse_decodes_withServerShape() {
        // jukebox-server.mjs:247 — requiresToken is NOT echoed back.
        val session = json.decodeFromString<JukeboxSessionInfo>(
            """
            {
              "jukeboxId": "ab2cd3ef",
              "hostKey": "0123456789abcdef0123456789abcdef",
              "name": "Levi's Jukebox",
              "url": "https://d2p4cubg6se03u.cloudfront.net/jukebox/ab2cd3ef/",
              "timeless": false,
              "expiresAt": 1753228800000
            }
            """.trimIndent(),
        )
        assertEquals("ab2cd3ef", session.jukeboxId)
        assertEquals("https://d2p4cubg6se03u.cloudfront.net/jukebox/ab2cd3ef/", session.url)
        assertNull(session.requiresToken)
        assertEquals(false, session.timeless)
        assertEquals(1_753_228_800_000.0, session.expiresAt!!, 0.0)
    }

    @Test
    fun timelessSession_nullExpiresAt_decodes() {
        val session = json.decodeFromString<JukeboxSessionInfo>(
            """{"jukeboxId":"x2y3z4a5","hostKey":"k","name":"n","url":"u",
                "timeless":true,"expiresAt":null}""",
        )
        assertNull(session.expiresAt)
        assertEquals(true, session.timeless)
    }

    @Test
    fun persistedSession_survivesLaterFieldAddition() {
        // The additive-optional iron law: a doc saved by a future version (with
        // fields this build doesn't know) must still decode, not wipe.
        val session = json.decodeFromString<JukeboxSessionInfo>(
            """{"jukeboxId":"ab2cd3ef","hostKey":"k","name":"n","url":"u",
                "requiresToken":true,"guestToken":"tok_future","theme":"neon"}""",
        )
        assertEquals("ab2cd3ef", session.jukeboxId)
        assertEquals(true, session.requiresToken)
    }

    @Test
    fun statePayload_encodesOmittingNullStreamUrl() {
        val payload = JukeboxStatePayload(
            hear = false,
            nowPlaying = JukeboxStatePayload.NowPlaying(
                title = "Blue Monday",
                artist = "New Order",
                lengthMs = 447_000,
                positionMs = 12_345,
                streamUrl = null,
            ),
            upNext = listOf(JukeboxStatePayload.Track("Next Up", "Someone")),
        )
        val encoded = json.encodeToString(JukeboxStatePayload.serializer(), payload)
        assertTrue(encoded.contains("\"hear\":false"))
        assertTrue(encoded.contains("\"positionMs\":12345"))
        // explicitNulls=false: a view-only snapshot never carries a streamUrl key.
        assertFalse(encoded.contains("streamUrl"))
    }

    @Test
    fun statePayload_idle_encodesEmptyAndDecodesBack() {
        val idle = JukeboxStatePayload(hear = true)
        val roundTrip = json.decodeFromString<JukeboxStatePayload>(
            json.encodeToString(JukeboxStatePayload.serializer(), idle),
        )
        assertTrue(roundTrip.hear)
        assertNull(roundTrip.nowPlaying)
        assertTrue(roundTrip.upNext.isEmpty())
    }

    @Test
    fun health_decodesJustTheThreeFields() {
        val health = json.decodeFromString<JukeboxHealth>(
            """{"ok":true,"service":"jukebox","version":2,"host":"imac",
                "bucket":"b","sessions":3,"auth":true}""",
        )
        assertEquals(true, health.ok)
        assertEquals("jukebox", health.service)
        assertEquals(2, health.version)
    }

    @Test
    fun decisionActions_carryTheExactWireStrings() {
        assertEquals("denied", JukeboxDecisionAction.DENIED.wire)
        assertEquals("next", JukeboxDecisionAction.NEXT.wire)
        assertEquals("end", JukeboxDecisionAction.END.wire)
        assertEquals("random", JukeboxDecisionAction.RANDOM.wire)
        assertFalse(JukeboxDecisionAction.DENIED.isPlacement)
        assertTrue(JukeboxDecisionAction.RANDOM.isPlacement)
    }
}
