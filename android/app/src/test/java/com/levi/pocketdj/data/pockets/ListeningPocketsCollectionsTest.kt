package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.collections.CollectionFlattener
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.history.PlaySource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ListeningPocketsCollectionsTest {
    private val now = 1_800_000_000_000.0
    private fun add(id: String, at: Double, item: String = "s1", cid: String = "pkt_a") =
        ActivityEvent(id = id, at = at, kind = ActivityKind.ADD, itemId = item, collectionId = cid, collectionName = "SECRET NAME")
    private fun input(activity: List<ActivityEvent>, songs: List<String> = listOf("s1", "s2")) = ListeningPocketsCollections.Input(
        CollectionFlattener.Source(pockets = listOf(Pocket(id = "pkt_a", name = "SECRET NAME", songIds = songs))), activity,
    )

    @Test fun hashStability() {
        val a = ListeningPocketsCollections.build(input(listOf(add("1", now - 1000))), now)
        val same = ListeningPocketsCollections.build(input(listOf(add("1", now - 1000))), now + 5_000)
        assertEquals(a.hash, same.hash)
        assertEquals(64, a.hash.length)
        assertNotEquals(a.hash, ListeningPocketsCollections.build(input(listOf(add("1", now - 2000))), now).hash)       // add time moved
        assertNotEquals(a.hash, ListeningPocketsCollections.build(input(listOf(add("1", now - 1000)), listOf("s1", "s2", "s3")), now).hash) // membership moved
        // collection order does not matter for the collection lines
        val c1 = ListeningPocketsCollectionWire("a", "pocket", listOf("x"), emptyList())
        val c2 = ListeningPocketsCollectionWire("b", "pocket", listOf("y"), emptyList())
        assertEquals(ListeningPocketsCollections.hash(listOf(c1, c2), emptyList()), ListeningPocketsCollections.hash(listOf(c2, c1), emptyList()))
        // collection names never appear in the encoded payload
        val json = ListeningPocketsUploadBatch(null, "i", 0, emptyList(), collections = a.collections, addEvents = a.addEvents).toJson().toString()
        assertFalse(json.contains("SECRET NAME"))
        assertEquals(1, a.collections[0].adds.size)   // s1 has an add time, s2 none
        assertEquals(now.toLong() - 1000, a.collections[0].adds[0].atMs)
    }

    @Test fun resendGate() {
        val day = ListeningPocketsCollections.RESEND_AFTER_MS
        assertTrue(ListeningPocketsCollections.isDue("h", null, null, now))
        assertTrue(ListeningPocketsCollections.isDue("h2", "h", now - 1, now))
        assertFalse(ListeningPocketsCollections.isDue("h", "h", now - day + 1, now))
        assertTrue(ListeningPocketsCollections.isDue("h", "h", now - day, now))
        assertTrue(ListeningPocketsCollections.isDue("h", "h", now + 10_000, now))   // clock went backwards
    }

    @Test fun nowPlayingContextDropped() {
        assertNull(ListeningPocketsCollections.context("set_now_playing", PlaySource.SETLIST))
        assertNull(ListeningPocketsCollections.context(null, PlaySource.POCKET))
        assertNull(ListeningPocketsCollections.context("", PlaySource.POCKET))
        assertEquals("pkt_1" to "pocket", ListeningPocketsCollections.context("pkt_1", PlaySource.BROWSER))
        assertEquals("pls_1" to "playlist", ListeningPocketsCollections.context("pls_1", PlaySource.PLAYLIST))
        assertEquals("set_9" to "setlist", ListeningPocketsCollections.context("set_9", PlaySource.GAME))
        assertEquals("pl.abc" to "source", ListeningPocketsCollections.context("pl.abc", PlaySource.PLAYLIST))
        assertEquals("xyz" to "pocket", ListeningPocketsCollections.context("xyz", PlaySource.POCKET))
        assertNull(ListeningPocketsCollections.context("itp_1", PlaySource.GAME))
        assertNull(ListeningPocketsCollections.context("alb", PlaySource.ALBUM))
    }

    @Test fun byteCap() {
        val big = (1..4000).map { "song-number-$it" }
        val cols = (1..200).map { ListeningPocketsCollectionWire("pkt_$it", "pocket", big, emptyList()) }
        val evs = (1..5000).map { ListeningPocketsAddEventWire("s$it", "pkt_1", it.toLong(), "add") }
        val p = ListeningPocketsCollections.enforceByteCap(
            ListeningPocketsCollections.Payload(cols, evs, ListeningPocketsCollections.hash(cols, evs)),
        )
        val size = ListeningPocketsUploadBatch(null, "", 0, emptyList(), collections = p.collections, addEvents = p.addEvents)
            .toJson().toString().toByteArray().size
        assertTrue("size $size", size <= ListeningPocketsCollections.BYTE_CAP)
        assertTrue(p.collections.size < cols.size)
        assertEquals(ListeningPocketsCollections.hash(p.collections, p.addEvents), p.hash)
        // an under-cap payload passes through untouched
        val small = ListeningPocketsCollections.build(input(listOf(add("1", now - 10))), now)
        assertEquals(small, ListeningPocketsCollections.enforceByteCap(small))
    }

    @Test fun oversizedSourcePlaylistLeftOutAndHistoryWindowed() {
        val huge = (1..5001).map { "h$it" }
        val src = CollectionFlattener.Source(
            pockets = listOf(Pocket(id = "pkt_a", name = "n", songIds = listOf("s1"))),
            sourcePlaylists = listOf(CollectionFlattener.SourcePlaylist("lib", "Library", huge), CollectionFlattener.SourcePlaylist("ok", "Ok", listOf("z"))),
        )
        assertEquals(listOf("pkt_a", "ok"), ListeningPocketsCollections.flattened(src).map { it.id })
        val old = add("old", now - 400 * 86_400_000.0)
        val floorEv = add("mid", now - 10_000.0)
        val p = ListeningPocketsCollections.build(ListeningPocketsCollections.Input(src, listOf(old, floorEv)), now)
        assertEquals(1, p.addEvents.size)
        val floored = ListeningPocketsCollections.build(ListeningPocketsCollections.Input(src, listOf(floorEv)), now, floorMs = now)
        assertTrue(floored.addEvents.isEmpty())
    }
}
