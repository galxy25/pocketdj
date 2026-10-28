package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PuzzleRecEventBridgeTest {
    private fun d(id: String, at: Double, action: String, collectionId: String? = null, songId: String = "sng_$id") =
        PuzzleDecisionStore.Decision(id = id, roundId = "R", at = at, songId = songId, action = action, collectionId = collectionId)

    @Test fun exportsOnlyAssignedRowsWithACollectionId() {
        val ev = PuzzleRecEventBridge.events(
            listOf(
                d("1", 10.0, "assigned", "pkt_x"),
                d("2", 11.0, "skipped"),
                d("3", 12.0, "expired"),
                d("4", 13.0, "assigned", collectionId = null), // assigned with nowhere to go
                d("5", 14.0, "assigned", "pls_y"),
            ),
            sinceMs = 0.0,
        )
        assertEquals(listOf("1", "5"), ev.map { it.id })
    }

    @Test fun negativeSignalsNeverRide() {
        val ev = PuzzleRecEventBridge.events(listOf(d("1", 1.0, "skipped", "pkt_x"), d("2", 2.0, "expired", "pkt_x")), 0.0)
        assertTrue("skipped/expired must never upload as positive taste", ev.isEmpty())
    }

    @Test fun oldestFirstActionAddedPointsOneGameId() {
        val ev = PuzzleRecEventBridge.events(
            listOf(d("late", 300.0, "assigned", "pkt_x"), d("early", 100.0, "assigned", "pkt_x"), d("mid", 200.0, "assigned", "pls_y")),
            0.0,
        )
        assertEquals(listOf("early", "mid", "late"), ev.map { it.id })
        assertTrue(ev.all { it.action == "added" && it.points == 1 && it.gameId == "collectorsPuzzle" })
        assertEquals("pkt_x", ev[0].collectionId)
        assertEquals(100.0, ev[0].atMs, 0.0)
        assertEquals("sng_early", ev[0].songId)
    }

    @Test fun sinceMsIsInclusiveAndTheProjectionIsIdempotent() {
        val rows = listOf(d("a", 100.0, "assigned", "pkt_x"), d("b", 200.0, "assigned", "pkt_x"))
        val first = PuzzleRecEventBridge.events(rows, 200.0)
        assertEquals(listOf("b"), first.map { it.id })
        assertEquals(first, PuzzleRecEventBridge.events(rows, 200.0))
        assertEquals(2, PuzzleRecEventBridge.events(rows, 100.0).size)
        assertTrue(PuzzleRecEventBridge.events(rows, 201.0).isEmpty())
    }

    @Test fun wireShapeIsTheRecEngineContract() {
        val ev = PuzzleRecEventBridge.events(listOf(d("1", 5.0, "assigned", "pkt_x")), 0.0).single()
        val o = PdjJson.lenient.parseToJsonElement(PdjJson.lenient.encodeToString(RecPuzzleEventWire.serializer(), ev)) as JsonObject
        assertEquals(setOf("id", "atMs", "gameId", "songId", "collectionId", "action", "points"), o.keys)
        assertEquals("added", (o["action"] as JsonPrimitive).content)
        assertFalse(o.containsKey("verdict"))
    }
}
