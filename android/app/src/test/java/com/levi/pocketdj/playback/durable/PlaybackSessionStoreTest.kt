package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlaybackSessionStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private var now = 1_000_000L
    private fun store(file: File = File(tmp.root, PLAYBACK_SESSION_FILE), writer: VersionedJsonWriter = VersionedJsonWriter(file)) =
        PlaybackSessionStore(file, writer, clock = { now })

    private fun snap(index: Int = 0, pos: Long = 0, playing: Boolean = false, sid: String = "pses_A") = SessionSnapshot(
        sessionId = sid,
        source = SessionSourceRef("playlist", "set_now_playing", "Mix"),
        queue = listOf(SessionRow("a", "A", "x"), SessionRow("b", "B", "y")),
        index = index, positionMs = pos, isPlaying = playing,
    )

    private fun fixture() = javaClass.getResource("/fixtures/ios-playback-session-v1.json")!!.readText()

    @Test
    fun fixture_decodesTheIosShape() {
        val s = SessionSnapshot.decode(fixture())!!
        assertEquals("pses_6F1D2C0A-3B7E-4C55-9A10-5E2B8D7F4A11", s.sessionId)
        assertEquals("set_now_playing", s.source.id)
        assertEquals("pls_9c2e", s.source.originId)
        assertEquals(3, s.queue.size)
        assertEquals(42_000L, s.positionMs)
        assertEquals("all", s.repeatMode)
        assertEquals(true, s.shuffleEnabled)
        assertEquals(listOf("bass"), s.stemLock!!.muted)
        val items = s.toQueueItems()
        assertEquals("clean", items[1].variant)
        assertTrue(items[1].editionLocked)
        assertEquals(2, items[1].repeatCount)
        assertEquals(3, items.map { it.uid }.toSet().size) // fresh uids
    }

    @Test
    fun resolveId_roundTripsAndIosFixtureStillDecodesWithout() {
        val s = snap().copy(
            queue = listOf(
                SessionRow("a", "A", "x", resolveId = "a_clean", variant = "clean"),
                SessionRow("b", "B", "y", resolveId = "b", cleanOnlySkip = true),
            ),
        )
        val back = SessionSnapshot.decode(SessionSnapshot.encode(s))!!
        assertEquals("a_clean", back.queue[0].resolveId)
        assertEquals(true, back.queue[1].cleanOnlySkip)
        val items = back.toQueueItems()
        assertEquals("a_clean", items[0].resolveId)
        assertTrue(items[1].cleanOnlySkip)
        // QueueItem -> row -> QueueItem keeps the resolved edition + skip stamp
        val q = items[0].copy(cleanOnlySkip = true)
        assertEquals(q.resolveId, SessionSnapshot.row(q).resolveId)
        assertEquals(true, SessionSnapshot.row(q).cleanOnlySkip)
        // the iOS fixture (no resolveId key) decodes; the locked row keeps the iOS id convention
        val ios = SessionSnapshot.decode(fixture())!!
        assertNull(ios.queue[0].resolveId)
        assertEquals("sng_2_clean", ios.toQueueItems()[1].resolveId)
        // iOS Codable ignores extra keys: the extra Android keys never appear for plain rows
        val enc = Json.parseToJsonElement(SessionSnapshot.encode(ios)).jsonObject
        assertFalse((enc["queue"] as kotlinx.serialization.json.JsonArray)[0].jsonObject.containsKey("resolveId"))
    }

    @Test
    fun fixture_roundTripKeepsTheFieldSet_andOmitsNulls() {
        val s = SessionSnapshot.decode(fixture())!!
        val out = Json.parseToJsonElement(SessionSnapshot.encode(s)).jsonObject
        val orig = Json.parseToJsonElement(fixture()).jsonObject
        assertEquals(orig.keys, out.keys)
        assertEquals(orig["source"]!!.jsonObject.keys, out["source"]!!.jsonObject.keys)
        val rows = out["queue"] as kotlinx.serialization.json.JsonArray
        // row 0 has no variant / editionLocked / repeatCount keys at all (nulls omitted)
        assertEquals(setOf("songId", "title", "artist", "lengthMs"), rows[0].jsonObject.keys)
        assertEquals(setOf("songId", "title", "artist"), rows[2].jsonObject.keys)
        assertEquals(orig["queue"], out["queue"])
        assertEquals(orig["stemLock"], out["stemLock"])
    }

    @Test
    fun load_unknownVersion_corruptOrEmpty_isNull() {
        val f = File(tmp.root, PLAYBACK_SESSION_FILE)
        val st = store(f)
        assertNull(st.load()) // no file
        f.writeText(fixture().replace("\"schemaVersion\":1", "\"schemaVersion\":2"))
        assertNull(st.load())
        f.writeText("{not json")
        assertNull(st.load())
        f.writeText(fixture().replace(Regex("\"queue\":\\[.*?\\],\"index\""), "\"queue\":[],\"index\""))
        assertNull(st.load())
        f.writeText(fixture())
        assertNotNull(st.load())
    }

    @Test
    fun save_writesImmediately_andLoadReadsItBack() {
        val st = store()
        st.save(snap(index = 1, pos = 0))
        val back = st.load()!!
        assertEquals(1, back.index)
        assertEquals(now.toDouble(), back.updatedAt, 0.0)
        val o = Json.parseToJsonElement(st.file.readText()).jsonObject
        assertEquals("1", o["schemaVersion"]!!.jsonPrimitive.content)
    }

    @Test
    fun position_whilePlayingIsThrottledToFiveSeconds() {
        val writer = VersionedJsonWriter(File(tmp.root, PLAYBACK_SESSION_FILE))
        val st = store(writer = writer)
        st.save(snap(playing = true))
        val base = writer.writeCount
        now += 1_000; st.updatePosition(1_000, true)
        now += 3_000; st.updatePosition(4_000, true)
        assertEquals(base, writer.writeCount)
        now += 1_000; st.updatePosition(5_000, true) // 5 s since the save
        assertEquals(base + 1, writer.writeCount)
        assertEquals(5_000L, st.load()!!.positionMs)
        now += 4_999; st.updatePosition(10_000, true)
        assertEquals(base + 1, writer.writeCount)
    }

    @Test
    fun pauseAndResumeTransitions_persistImmediately_steadyPausedWritesNothing() {
        val writer = VersionedJsonWriter(File(tmp.root, PLAYBACK_SESSION_FILE))
        val st = store(writer = writer)
        st.save(snap(playing = true))
        val base = writer.writeCount
        now += 100; st.updatePosition(7_000, false) // pause: immediate, with the PAUSED position
        assertEquals(base + 1, writer.writeCount)
        assertEquals(7_000L, st.load()!!.positionMs)
        assertFalse(st.load()!!.isPlaying)
        now += 60_000; st.updatePosition(7_000, false)
        assertEquals(base + 1, writer.writeCount)
        now += 10; st.updatePosition(7_000, true) // resume: immediate
        assertEquals(base + 2, writer.writeCount)
        assertTrue(st.load()!!.isPlaying)
    }

    @Test
    fun updatePosition_withoutALiveSession_isANoOp() {
        val writer = VersionedJsonWriter(File(tmp.root, PLAYBACK_SESSION_FILE))
        val st = store(writer = writer)
        st.updatePosition(9_000, true)
        st.flush()
        assertEquals(0, writer.writeCount)
        assertFalse(st.file.exists())
    }

    @Test
    fun clear_deletesTheFile_andForgetsTheSession() {
        val st = store()
        st.save(snap())
        assertTrue(st.file.exists())
        st.clear()
        assertFalse(st.file.exists())
        assertNull(st.currentSnapshot)
        st.updatePosition(1, true) // nothing to adopt
        assertFalse(st.file.exists())
    }

    @Test
    fun flush_landsLatestInMemoryPosition() {
        val st = store()
        st.save(snap(playing = true))
        now += 1_000; st.updatePosition(1_234, true) // throttled: not on disk
        assertEquals(0L, st.load()!!.positionMs)
        now += 10; st.flush()
        assertEquals(1_234L, st.load()!!.positionMs)
    }
}
