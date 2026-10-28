package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.ui.dnd.SongDragSemantics
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SongTransferTest {
    private fun songs(n: Int) = (1..n).associate { "sng_$it" to IndexSong(id = "sng_$it", artist = "Art", name = "Name$it") }

    @Test
    fun clipDataRoundTrip() {
        val t = SongTransfer.make(listOf("sng_1", "sng_2"), songs(2))
        val texts = SongDragSemantics.clipTexts(t)!!
        assertEquals("Art — Name1\nArt — Name2", texts[0])
        val back = SongDragSemantics.decodeClip(SongTransfer.CLIP_LABEL, texts)
        assertEquals(t, back)
        // iOS JSON shape: songIds + text, decodable from a hand-written iOS payload.
        val ios = """{"songIds":["sng_9","amrec_x"],"text":"A — B"}"""
        assertEquals(listOf("sng_9", "amrec_x"), SongTransfer.decode(ios)!!.songIds)
        assertTrue(t.toJson().contains("\"songIds\""))
    }

    @Test
    fun foreignClipsDecodeToNull() {
        val t = SongTransfer(listOf("sng_1"))
        val json = t.toJson()
        assertNull(SongTransfer.fromClipTexts("some label", listOf("hello", json)))
        assertNull(SongTransfer.fromClipTexts(null, listOf("hello", json)))
        assertNull(SongTransfer.fromClipTexts(SongTransfer.CLIP_LABEL, listOf("just text")))
        assertNull(SongTransfer.fromClipTexts(SongTransfer.CLIP_LABEL, listOf("x", "not json")))
        assertNotNull(SongTransfer.fromClipTexts(SongTransfer.CLIP_LABEL, listOf("x", json)))
    }

    @Test
    fun textFallbackCap200Lines() {
        val ids = (1..250).map { "sng_$it" }
        val t = SongTransfer.make(ids, songs(250))
        val lines = t.text!!.split("\n")
        assertEquals(SongTransfer.TEXT_LINE_CAP + 1, lines.size)
        assertEquals("…and 50 more", lines.last())
        assertEquals(250, t.songIds.size) // ids are never capped, only the text
        // exactly at the cap: no "more" line
        assertEquals(200, SongTransfer.make(ids.take(200), songs(250)).text!!.split("\n").size)
        // nothing resolvable: no text, export falls back to raw ids
        val bare = SongTransfer.make(listOf("zzz"), emptyMap())
        assertNull(bare.text)
        assertEquals("zzz", bare.plainTextExport)
    }

    @Test
    fun acceptableIdsCapsAndResolves() {
        val ids = (1..SongDrop.MAX_IDS + 50).map { "s$it" }
        val out = SongDrop.acceptableIds(listOf(SongTransfer(ids))) { true }
        assertEquals(SongDrop.MAX_IDS, out.size)
        assertEquals("s1", out.first())
    }

    @Test
    fun oversizedPayloadRefused() {
        val big = "x".repeat(SongTransfer.MAX_PAYLOAD_BYTES + 1)
        assertNull(SongTransfer.decode("""{"songIds":["a"],"text":"$big"}"""))
        assertNull(SongTransfer.fromClipTexts(SongTransfer.CLIP_LABEL, listOf("t", """{"songIds":["a"],"text":"$big"}""")))
        assertNotNull(SongTransfer.decode("""{"songIds":["a"]}"""))
    }

    @Test
    fun chipLabelPluralizes() {
        assertEquals("1 song", SongDragSemantics.chipLabel(1))
        assertEquals("3 songs", SongDragSemantics.chipLabel(3))
    }
}
