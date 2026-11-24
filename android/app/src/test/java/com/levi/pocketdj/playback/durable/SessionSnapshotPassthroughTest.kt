package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionSnapshotPassthroughTest {
    private val fixture: String =
        javaClass.classLoader!!.getResourceAsStream("parity2/ios-playback-session-1.0.6.json")!!
            .readBytes().toString(Charsets.UTF_8)

    private fun root(text: String) = PdjJson.lenient.parseToJsonElement(text).jsonObject

    @Test fun decodesEveryIosField() {
        val s = SessionSnapshot.decode(fixture)!!
        assertEquals(true, s.npMixMode?.enabled)
        assertEquals(true, s.fxLock?.enabled)
        assertEquals(0.65, s.fxLock!!.effects.getValue("reverb").strength, 0.0)
        assertEquals(true, s.djMode?.enabled)
        val plan = s.queue[0].plan!!
        assertEquals("col_9", plan.collectionId)
        assertEquals(0.8125, plan.score, 0.0)
        assertEquals("1440857781", s.queue[1].appleMusicId)
        assertEquals(true, s.queue[1].djUserNext)
        assertEquals(true, s.queue[1].djPlaced)
        assertEquals(setOf("futureTopLevel"), s.unknownKeys.keys)
        assertEquals(setOf("futureRowKey"), s.queue[0].unknownKeys.keys)
    }

    @Test fun reencodeKeepsEveryIosKeyWithIdenticalValues() {
        val out = root(SessionSnapshot.encode(SessionSnapshot.decode(fixture)!!))
        val inp = root(fixture)
        assertEquals(inp.keys, out.keys)
        for (k in inp.keys) assertEquals("top-level $k", inp[k], out[k])
        assertEquals(inp, out)
    }

    @Test fun futureKeysSurvive() {
        val out = root(SessionSnapshot.encode(SessionSnapshot.decode(fixture)!!))
        assertEquals(root(fixture)["futureTopLevel"], out["futureTopLevel"])
        val row0 = out["queue"]!!.jsonArray[0].jsonObject
        assertEquals(1, row0["futureRowKey"]!!.jsonObject["a"]!!.jsonPrimitive.content.toInt())
        // unknown key inside plan, and an unknown effect + an unknown field of an effect
        assertEquals("[1,2]", row0["plan"]!!.jsonObject["futureTagKey"].toString().replace(" ", ""))
        val effects = out["fxLock"]!!.jsonObject["effects"]!!.jsonObject
        assertEquals("log", effects["futureEffect"]!!.jsonObject["curve"]!!.jsonPrimitive.content)
    }

    @Test fun unsigned64BitSeedRoundTrips() {
        val text = SessionSnapshot.encode(SessionSnapshot.decode(fixture)!!)
        assertTrue(text, text.contains("\"seed\":18446744073709551615"))
        val planner = SessionSnapshot.decode(text)!!.djMode!!.planner!!
        assertEquals("18446744073709551615", planner["seed"]!!.jsonPrimitive.content)
    }

    @Test fun legacyDocumentEncodesByteIdenticallyToThePreviousShape() {
        val legacy = SessionSnapshot(
            sessionId = "s1",
            source = SessionSourceRef("setlist", "set_1", "Mix"),
            queue = listOf(SessionRow("sng_a", "A", "Art", 1000), SessionRow("sng_b", "B")),
            index = 1, positionMs = 5, repeatMode = "off", updatedAt = 12.0,
        )
        val text = SessionSnapshot.encode(legacy)
        // the exact pre-change output: typed fields only, none of the new keys
        assertEquals(
            """{"schemaVersion":1,"sessionId":"s1","source":{"kind":"setlist","id":"set_1","name":"Mix"},""" +
                """"queue":[{"songId":"sng_a","title":"A","artist":"Art","lengthMs":1000},{"songId":"sng_b","title":"B","artist":""}],""" +
                """"index":1,"positionMs":5,"isPlaying":false,"repeatMode":"off","updatedAt":12.0}""",
            text,
        )
        // and a decode -> encode of that text is a fixed point
        assertEquals(text, SessionSnapshot.encode(SessionSnapshot.decode(text)!!))
    }

    @Test fun absentFieldsStayAbsentNotNull() {
        val text = SessionSnapshot.encode(SessionSnapshot.decode(fixture)!!.copy(npMixMode = null, fxLock = null, djMode = null))
        val o = root(text)
        assertTrue("npMixMode" !in o && "fxLock" !in o && "djMode" !in o)
        // the fixture's own futureTopLevel holds a JSON null; no OTHER value anywhere is null
        fun nulls(e: kotlinx.serialization.json.JsonElement, path: String): List<String> = when (e) {
            is JsonObject -> e.flatMap { (k, v) -> nulls(v, "$path/$k") }
            is kotlinx.serialization.json.JsonArray -> e.flatMapIndexed { i, v -> nulls(v, "$path[$i]") }
            is kotlinx.serialization.json.JsonNull -> listOf(path)
            else -> emptyList()
        }
        assertEquals(listOf("/futureTopLevel/x[1]"), nulls(o, ""))
    }

    @Test fun storeCarriesIosFieldsAcrossAnAndroidWriteOfARebuiltSnapshot() {
        val dir = kotlin.io.path.createTempDirectory("pdjsnap").toFile()
        try {
            val f = File(dir, PLAYBACK_SESSION_FILE).also { it.writeText(fixture) }
            val store = PlaybackSessionStore(f, clock = { 5L })
            val loaded = store.load()!!
            assertEquals(true, store.extras.djMode?.enabled)
            // Android rebuilds a snapshot from its own state: none of the iOS-only fields
            val rebuilt = loaded.copy(npMixMode = null, fxLock = null, djMode = null, unknownKeys = JsonObject(emptyMap()), positionMs = 9)
            store.save(rebuilt)
            store.awaitWrites()
            val out = root(f.readText())
            val inp = root(fixture)
            for (k in listOf("npMixMode", "fxLock", "djMode", "futureTopLevel")) assertEquals(k, inp[k], out[k])
            assertEquals(9L, out["positionMs"]!!.jsonPrimitive.content.toLong())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun updateExtrasCanClearAField() {
        val dir = kotlin.io.path.createTempDirectory("pdjsnap").toFile()
        try {
            val f = File(dir, PLAYBACK_SESSION_FILE).also { it.writeText(fixture) }
            val store = PlaybackSessionStore(f, clock = { 5L })
            store.save(store.load()!!)
            store.updateExtras { it.copy(npMixMode = null) }
            store.awaitWrites()
            val out = root(f.readText())
            assertNull(out["npMixMode"])
            assertNotNull(out["djMode"])
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun extrasNeverOverrideTypedValues() {
        val ex = SnapshotExtras(unknownKeys = buildJsonObject { put("sessionId", JsonPrimitive("evil")); put("k", JsonPrimitive(1)) })
        val snap = SessionSnapshot(sessionId = "real", source = SessionSourceRef("x"), queue = listOf(SessionRow("a", "A")), index = 0)
        val o = root(SessionSnapshot.encode(ex.overlay(snap)))
        assertEquals("real", o["sessionId"]!!.jsonPrimitive.content)
        assertEquals("1", o["k"]!!.jsonPrimitive.content)
    }

    private fun tmpStore(block: (PlaybackSessionStore, File) -> Unit) {
        val dir = kotlin.io.path.createTempDirectory("pdjsnap").toFile()
        try {
            val f = File(dir, PLAYBACK_SESSION_FILE).also { it.writeText(fixture) }
            block(PlaybackSessionStore(f, clock = { 5L }), f)
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun freshSnapshot(id: String = "new-session") = SessionSnapshot(
        sessionId = id, source = SessionSourceRef("album", "alb_1"),
        queue = listOf(SessionRow("sng_x", "X")), index = 0,
    )

    @Test fun clearThenNewSessionDoesNotLeakOldExtras() {
        tmpStore { store, f ->
            store.save(store.load()!!)
            store.clear()
            store.save(freshSnapshot())
            store.awaitWrites()
            val out = root(f.readText())
            for (k in listOf("djMode", "fxLock", "npMixMode", "futureTopLevel")) assertNull(k, out[k])
            assertEquals(null, out["source"]!!.jsonObject["futureSourceKey"])
        }
    }

    @Test fun differentSessionIdWithoutClearDoesNotLeakEither() {
        tmpStore { store, f ->
            store.save(store.load()!!)
            store.save(freshSnapshot())
            store.awaitWrites()
            val out = root(f.readText())
            for (k in listOf("djMode", "fxLock", "npMixMode", "futureTopLevel")) assertNull(k, out[k])
        }
    }

    @Test fun rowExtrasSurviveAStructuralSaveBuiltThroughQueueItems() {
        tmpStore { store, f ->
            val loaded = store.load()!!
            val rebuilt = loaded.copy(
                queue = loaded.toQueueItems().map { SessionSnapshot.row(it) },
                npMixMode = null, fxLock = null, djMode = null, positionMs = 3,
            )
            assertNull(rebuilt.queue[0].plan)
            store.save(rebuilt)
            store.awaitWrites()
            val out = root(f.readText())
            val inRows = root(fixture)["queue"]!!.jsonArray
            val outRows = out["queue"]!!.jsonArray
            assertEquals(inRows[0].jsonObject["plan"], outRows[0].jsonObject["plan"])
            assertEquals(inRows[0].jsonObject["futureRowKey"], outRows[0].jsonObject["futureRowKey"])
            assertEquals(inRows[0].jsonObject["djUserNext"], outRows[0].jsonObject["djUserNext"])
            for (k in listOf("appleMusicId", "djPlaced", "djUserNext")) assertEquals(k, inRows[1].jsonObject[k], outRows[1].jsonObject[k])
        }
    }

    @Test fun reorderedRowsKeepTheirOwnExtras() {
        tmpStore { store, f ->
            val loaded = store.load()!!
            val reordered = loaded.copy(queue = loaded.queue.reversed().map { SessionSnapshot.row(it.let { r -> com.levi.pocketdj.playback.sequencer.QueueItem(id = r.songId, title = r.title) }) })
            store.save(reordered)
            store.awaitWrites()
            val rows = root(f.readText())["queue"]!!.jsonArray
            assertEquals("sng_b", rows[1].jsonObject["songId"]!!.jsonPrimitive.content)
            assertEquals("1440857781", rows[1].jsonObject["appleMusicId"]!!.jsonPrimitive.content)
            assertNull(rows[0].jsonObject["appleMusicId"])
            assertEquals("sng_a", rows[2].jsonObject["songId"]!!.jsonPrimitive.content)
            assertNotNull(rows[2].jsonObject["futureRowKey"])
        }
    }

    @Test fun sourceAndStemLockUnknownKeysSurvive() {
        val out = root(SessionSnapshot.encode(SessionSnapshot.decode(fixture)!!))
        assertEquals("s", out["source"]!!.jsonObject["futureSourceKey"]!!.jsonPrimitive.content)
        assertEquals("7", out["stemLock"]!!.jsonObject["futureStemKey"]!!.jsonPrimitive.content)
    }
}
