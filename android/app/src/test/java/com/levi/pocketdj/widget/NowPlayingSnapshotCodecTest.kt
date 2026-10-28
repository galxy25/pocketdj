package com.levi.pocketdj.widget

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class NowPlayingSnapshotCodecTest {
    @Test fun roundTrip() {
        val s = NowPlayingSnapshot(
            isPlaying = true, hasContent = true, title = "T", artist = "A", songId = "sng_1", coverVersion = 3,
            upNext = listOf(NowPlayingSnapshot.Track("u1", "sng_2", "N", "B")), isFavorite = true,
            appleMusicId = "123", repeatMode = "all", shuffleEnabled = true,
        )
        assertEquals(s, NowPlayingSnapshotCodec.decode(NowPlayingSnapshotCodec.encode(s)))
    }

    @Test fun encodesExactlyTheIosKeys() {
        val enc = NowPlayingSnapshotCodec.encode(NowPlayingSnapshot(songId = "x", appleMusicId = "1"))
        val keys = kotlinx.serialization.json.Json.parseToJsonElement(enc).let {
            (it as kotlinx.serialization.json.JsonObject).keys
        }
        val ios = setOf(
            "isPlaying", "hasContent", "title", "artist", "songId", "coverVersion", "upNext", "isFavorite",
            "appleMusicId", "repeatMode", "shuffleEnabled", "recVerdict", "recScope",
        )
        assertTrue("missing ${ios - keys}", keys.containsAll(ios))
        assertEquals(setOf("favoriteAvailable"), keys - ios)
    }

    @Test fun decodesIosProducedSample() {
        val ios = """{"isPlaying":true,"hasContent":true,"title":"Song","artist":"Artist","songId":"sng_9",
            "coverVersion":7,"upNext":[{"id":"uid-1","songId":"sng_10","title":"Next","artist":"Z"}],
            "isFavorite":true,"appleMusicId":"999","repeatMode":"one","shuffleEnabled":true,
            "recVerdict":"accepted","recScope":"zone"}"""
        val s = NowPlayingSnapshotCodec.decode(ios)
        assertEquals("sng_9", s.songId)
        assertEquals(7, s.coverVersion)
        assertEquals("sng_10", s.upNext.single().songId)
        assertEquals("one", s.repeatMode)
        assertEquals("accepted", s.recVerdict)
        assertEquals("zone", s.recScope)
        assertTrue(s.favoriteAvailable)
    }

    @Test fun missingOptionalFieldsDefault() {
        val old = """{"isPlaying":false,"hasContent":true,"title":"t","artist":"a","coverVersion":1,"upNext":[]}"""
        val s = NowPlayingSnapshotCodec.decode(old)
        assertNull(s.songId); assertNull(s.appleMusicId)
        assertFalse(s.isFavorite); assertFalse(s.shuffleEnabled)
        assertEquals("off", s.repeatMode); assertEquals("", s.recVerdict); assertEquals("", s.recScope)
        assertTrue(s.hasContent)
    }

    @Test fun corruptOrBlankIsEmpty() {
        assertEquals(NowPlayingSnapshot.EMPTY, NowPlayingSnapshotCodec.decode("{nope"))
        assertEquals(NowPlayingSnapshot.EMPTY, NowPlayingSnapshotCodec.decode(null))
        assertEquals(NowPlayingSnapshot.EMPTY, NowPlayingSnapshotCodec.decode("  "))
    }
}
