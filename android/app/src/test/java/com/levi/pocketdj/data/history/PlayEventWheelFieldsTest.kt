package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PlayEventWheelFieldsTest {
    @get:Rule val tmp = TemporaryFolder()
    private val json = PdjJson.lenient
    private val RUN = "9F1C2B3A-0000-4ABC-8DEF-1234567890AB"
    private val t0 = 1_750_000_000_000L

    private fun store(file: File = File(tmp.root, "h.json")) =
        PlayHistoryStore(file = file, json = json, maxEvents = 1000)

    private val iosDoc = """{"schemaVersion":1,"installId":"ios","events":[{"id":"e1","songId":"s","playedAt":1.0,"source":"pocket","originInstallId":"ios","motion":"running","pocketRun":{"runId":"$RUN","momentKey":"mk","rowCollectionId":"pl_1","slot":3}}]}"""

    @Test fun iosDocDecodesAndReencodesWheelKeysByteStable() {
        val e = json.decodeFromString<PlayHistoryDocument>(iosDoc).events.single()
        assertEquals("running", e.motion)
        assertEquals(PocketRunTag(RUN, "mk", "pl_1", 3), e.pocketRun)
        val out = json.encodeToString(PlayEvent.serializer(), e)
        assertTrue(out.contains("\"motion\":\"running\""))
        assertTrue(out.contains("\"pocketRun\":{\"runId\":\"$RUN\",\"momentKey\":\"mk\",\"rowCollectionId\":\"pl_1\",\"slot\":3}"))
    }

    @Test fun docWithoutNewFieldsRoundTripsWithoutThem() {
        val old = """{"id":"a","songId":"s","playedAt":1.0,"source":"pocket"}"""
        val e = json.decodeFromString(PlayEvent.serializer(), old)
        assertNull(e.motion); assertNull(e.pocketRun)
        val out = json.encodeToString(PlayEvent.serializer(), e)
        assertFalse(out.contains("motion")); assertFalse(out.contains("pocketRun"))
    }

    @Test fun lenientTagDecoding() {
        fun ev(tag: String) = json.decodeFromString(PlayEvent.serializer(), """{"id":"a","songId":"s","playedAt":1,"pocketRun":$tag}""")
        assertNull(ev("""{"momentKey":"x"}""").pocketRun)
        assertNull(ev("""{"runId":5}""").pocketRun)
        assertNull(ev(""""junk"""").pocketRun)
        assertNull(ev("null").pocketRun)
        assertEquals(PocketRunTag(RUN, "", null, 0), ev("""{"runId":"$RUN","slot":"x","momentKey":7}""").pocketRun)
        assertEquals(PocketRunTag(RUN, "", null, 0), ev("""{"runId":"$RUN"}""").pocketRun)
    }

    @Test fun recordCopiesPlayContextPocketRunAndKeepsPocketSource() {
        val s = store()
        val tag = PocketRunTag(RUN, "mk", null, 1)
        val e = s.record("s1", context = PlayContext.pocket("sl", "P").copy(pocketRun = tag), nowMs = t0)!!
        assertEquals(tag, e.pocketRun)
        assertEquals(PlaySource.POCKET, e.source)
        assertNull(s.record("s2", nowMs = t0 + 100_000)!!.pocketRun)
    }

    @Test fun stampMotionIsWriteOnceOwnOnlyAndIgnoresBlank() {
        val s = store()
        val mine = s.record("s1", nowMs = t0)!!
        assertEquals(1, s.stampMotion(mapOf(mine.id to "walking")))
        assertEquals(0, s.stampMotion(mapOf(mine.id to "running")))
        assertEquals("walking", s.events.single().motion)
        val s2 = store(File(tmp.root, "h2.json"))
        val b = s2.record("s2", nowMs = t0)!!
        assertEquals(0, s2.stampMotion(mapOf(b.id to "")))
        assertNull(s2.events.single().motion)
        // peer event is never tagged
        val file = File(tmp.root, "h3.json"); file.writeText(iosDoc.replace(",\"motion\":\"running\"", ""))
        val s3 = store(file)
        assertEquals(0, s3.stampMotion(mapOf("e1" to "walking")))
        assertNull(s3.events.single().motion)
    }

    @Test fun mergeFirstNonNullWinsAndRepublishWhenWeHoldFlags() {
        val file = File(tmp.root, "h4.json")
        val s = store(file)
        val e = s.record("s1", context = PlayContext.pocket("sl", "P").copy(pocketRun = PocketRunTag(RUN, "mk", null, 2)), nowMs = t0)!!
        s.stampMotion(mapOf(e.id to "walking"))
        s.flush()
        // doc (peer copy) lacks both fields
        val bare = """{"schemaVersion":1,"installId":"ios","events":[{"id":"${e.id}","songId":"s1","playedAt":${t0.toDouble()},"source":"pocket"}]}"""
        file.writeText(bare)
        assertTrue("we hold flags the doc lacks -> republish", s.reloadFromDisk())
        assertEquals("walking", s.events.single().motion)
        assertTrue(file.readText().contains("\"pocketRun\""))
        // doc has different values: ours (non-null) wins; doc with only theirs fills ours
        val s2 = store(File(tmp.root, "h5.json"))
        val m = s2.record("s2", nowMs = t0)!!
        s2.flush()
        File(tmp.root, "h5.json").writeText(
            """{"schemaVersion":1,"installId":"x","events":[{"id":"${m.id}","songId":"s2","playedAt":${t0.toDouble()},"motion":"running","pocketRun":{"runId":"$RUN","momentKey":"","slot":1}}]}""",
        )
        s2.reloadFromDisk()
        assertEquals("running", s2.events.single().motion)
        assertNotNull(s2.events.single().pocketRun)
        File(tmp.root, "h5.json").writeText(
            """{"schemaVersion":1,"installId":"x","events":[{"id":"${m.id}","songId":"s2","playedAt":${t0.toDouble()},"motion":"walking"}]}""",
        )
        s2.reloadFromDisk()
        assertEquals("running", s2.events.single().motion)
    }
}
