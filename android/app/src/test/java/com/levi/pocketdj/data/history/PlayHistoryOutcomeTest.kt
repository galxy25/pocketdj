package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.pockets.ListeningContextTag
import java.io.File
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlayHistoryOutcomeTest {
    @get:Rule val tmp = TemporaryFolder()
    private fun store() = PlayHistoryStore(File(tmp.root, "h.json"), PdjJson.lenient)
    private val t0 = 1_750_000_000_000L

    @Test fun fieldsAdditive() {
        // A doc written before the pockets fields decodes (all null) ...
        val old = """{"schemaVersion":1,"installId":"i","events":[{"id":"e1","songId":"s","playedAt":1.0,"source":"browser"}]}"""
        val d1 = PdjJson.lenient.decodeFromString(PlayHistoryDocument.serializer(), old)
        assertNull(d1.events[0].listeningContext); assertNull(d1.events[0].carPlay)
        // ... and one WITH them (iOS field names verbatim, unknown kind tolerated).
        val neu = """{"schemaVersion":1,"installId":"i","events":[{"id":"e1","songId":"s","playedAt":1.0,"source":"mix",
            "wasSkipped":true,"listenedFraction":0.25,"tzOffsetMin":-420,"carPlay":true,
            "listeningContext":{"kind":"trip","tripId":"trp_1","origin":"plc_1","destination":"plc_2"}}]}"""
        val e = PdjJson.lenient.decodeFromString(PlayHistoryDocument.serializer(), neu).events[0]
        assertEquals(true, e.carPlay); assertEquals(-420, e.tzOffsetMin)
        assertEquals(ListeningContextTag.trip("trp_1", "plc_1", "plc_2"), e.listeningContext)
        val future = """{"schemaVersion":1,"installId":"i","events":[{"id":"e1","songId":"s","playedAt":1.0,"listeningContext":{"kind":"warp"}}]}"""
        assertEquals("warp", PdjJson.lenient.decodeFromString(PlayHistoryDocument.serializer(), future).events[0].listeningContext!!.kind)
        // Round trip writes the exact iOS keys; null fields are omitted.
        val out = Json.parseToJsonElement(PdjJson.lenient.encodeToString(PlayEvent.serializer(), e)).jsonObject
        assertEquals("true", out["carPlay"]!!.jsonPrimitive.content)
        assertEquals("trip", out["listeningContext"]!!.jsonObject["kind"]!!.jsonPrimitive.content)
        assertEquals("plc_2", out["listeningContext"]!!.jsonObject["destination"]!!.jsonPrimitive.content)
        val bare = Json.parseToJsonElement(PdjJson.lenient.encodeToString(PlayEvent.serializer(), PlayEvent("x", "s", 1.0))).jsonObject
        assertTrue("carPlay" !in bare && "listeningContext" !in bare)
    }

    @Test fun fractionMaxMerge() {
        val s = store()
        val e = s.record("a", nowMs = t0)!!
        s.noteListened(e.id, 0.6)
        s.noteListened(e.id, 0.3)       // a later smaller report never lowers it
        assertEquals(0.6, s.events[0].listenedFraction!!, 1e-9)
        s.noteListened(e.id, 0.605)     // under one point: dropped
        assertEquals(0.6, s.events[0].listenedFraction!!, 1e-9)
        s.noteListened(e.id, 7.0)       // clamped
        assertEquals(1.0, s.events[0].listenedFraction!!, 1e-9)
        s.markSkipped(e.id); s.markSkipped(e.id)
        assertEquals(true, s.events[0].wasSkipped)
    }

    @Test fun outcomeDerivation() {
        fun o(skipped: Boolean?, f: Double?) = PlayEvent("i", "s", 1.0, wasSkipped = skipped, listenedFraction = f).outcome
        assertEquals(PlayOutcome.UNKNOWN, o(null, null))
        assertEquals(PlayOutcome.PARTIAL, o(null, 0.499))
        assertEquals(PlayOutcome.COMPLETED, o(null, 0.5))      // iOS: f >= 0.5
        assertEquals(PlayOutcome.SKIPPED, o(true, 0.99))        // skip flag wins over fraction
        assertEquals(PlayOutcome.SKIPPED, o(true, null))
        assertEquals(PlayOutcome.UNKNOWN, o(false, null))
    }

    @Test fun stampContextsIsWriteOnceAndLocalOnly() {
        val s = store()
        val mine = s.record("a", nowMs = t0)!!
        val peer = PlayEvent("peer", "p", t0.toDouble() + 1, originInstallId = "other-install")
        s.replaceAll(s.events + peer)
        val tag = ListeningContextTag.place("plc_1")
        assertEquals(1, s.stampContexts(mapOf(mine.id to tag, "peer" to tag)))
        assertNull(s.events.first { it.id == "peer" }.listeningContext)
        val rev = s.revision
        assertEquals(0, s.stampContexts(mapOf(mine.id to ListeningContextTag.place("plc_2"))))   // write-once
        assertEquals(rev, s.revision)
        assertEquals(tag, s.events.first { it.id == mine.id }.listeningContext)
        assertNotNull(s.events.first { it.id == mine.id })
    }
}
