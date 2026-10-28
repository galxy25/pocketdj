package com.levi.pocketdj.data.pockets

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ListeningPocketsModelsTest {
    private fun event(ctx: ListeningContextTag? = null, cid: String? = null, kind: String? = null) =
        ListeningPocketsUploadEvent(
            id = "e1", songId = "s1", atMs = 1_000L, ord = 0, tzOffsetMin = null, source = null,
            outcome = "unknown", fraction = null, originInstallId = null, artist = null, carPlay = null,
            ctx = ctx, contextId = cid, contextKind = kind,
        )

    @Test fun eventEncodingNulls() {
        val o = event().toJson()
        for (k in listOf("tzOffsetMin", "source", "fraction", "originInstallId", "artist", "carPlay", "ctx")) {
            assertTrue("$k present", o.containsKey(k))
            assertEquals("$k null", JsonNull, o[k])
        }
        assertEquals("unknown", (o["outcome"] as kotlinx.serialization.json.JsonPrimitive).content)
        val ctx = event(ctx = ListeningContextTag.trip("trp_1", "plc_a", null)).toJson()["ctx"] as JsonObject
        assertEquals(setOf("kind", "tripId", "origin"), ctx.keys)   // nil destination omitted, no placeId
        val place = event(ctx = ListeningContextTag.place("plc_x")).toJson()["ctx"] as JsonObject
        assertEquals(setOf("kind", "placeId"), place.keys)
    }

    @Test fun contextFieldsAbsentNotNull() {
        assertFalse(event().toJson().containsKey("contextId"))
        assertFalse(event().toJson().containsKey("contextKind"))
        // a half-known pair is not sent
        assertFalse(event(cid = "pkt_1").toJson().containsKey("contextId"))
        val o = event(cid = "pkt_1", kind = "pocket").toJson()
        assertEquals("pkt_1", (o["contextId"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("pocket", (o["contextKind"] as kotlinx.serialization.json.JsonPrimitive).content)
        // batch optionals are omitted (not null) when nil
        val b = ListeningPocketsUploadBatch(null, "inst", 5, listOf(event())).toJson()
        assertEquals(setOf("v", "installId", "sentAtMs", "events"), b.keys)
        val full = ListeningPocketsUploadBatch(
            "dev", "inst", 5, emptyList(),
            places = listOf(ListeningPocketsPlaceWire("plc_a", 1, "Location A", null)),
            trips = listOf(ListeningPocketsTripWire("trp_a", "plc_a", null, "Leaving A", null)),
            collections = listOf(ListeningPocketsCollectionWire("pkt_1", "pocket", listOf("s"), emptyList())),
            addEvents = listOf(ListeningPocketsAddEventWire("s", "pkt_1", 9, "add")),
        ).toJson()
        assertTrue(full.keys.containsAll(listOf("deviceId", "places", "trips", "collections", "addEvents")))
        val trip = ((full["trips"] as JsonArray)[0] as JsonObject)
        assertEquals(JsonNull, trip["destination"]); assertFalse(trip.containsKey("occurrences"))
        assertFalse(((full["places"] as JsonArray)[0] as JsonObject).containsKey("share"))
    }

    @Test fun atMsFlooredToMinute() {
        assertEquals(1_791_806_400_000L, ListeningPocketsUploadEvent.floorToMinute(1_791_806_459_999L))
        assertEquals(-60_000L, ListeningPocketsUploadEvent.floorToMinute(-1L))
    }

    @Test fun resultsLenient() {
        val r = ListeningPocketsResults.parse(
            """{"v":1,"generatedAtMs":5.0,"unknownKey":{"a":1},
               "pockets":[{"id":"p1","members":[{"songId":"s1"},{"bad":1}],"title":"T"},{"nope":true}],
               "patterns":"garbage","baseline":{"plays":3.0}}""",
        )
        assertNotNull(r)
        assertEquals(1, r!!.pockets.size)
        assertEquals(listOf("s1"), r.pockets[0].songIds)
        assertTrue(r.patterns.isEmpty())
        assertEquals(3, r.baseline?.plays)
        assertNull(r.roundLearning)
        val empty = ListeningPocketsResults.parse("{}")!!
        assertTrue(empty.pockets.isEmpty() && empty.patterns.isEmpty())
        assertNull(ListeningPocketsResults.parse("[1]"))
    }

    @Test fun uploadResponseLenient() {
        val r = ListeningPocketsUploadResponse.parse(kotlinx.serialization.json.Json.parseToJsonElement("""{"ok":true,"accepted":2.0,"x":1}"""))
        assertEquals(true, r.ok); assertEquals(2, r.accepted); assertNull(r.rejected)
        assertEquals(ListeningPocketsUploadResponse(), ListeningPocketsUploadResponse.parse(null))
    }
}
