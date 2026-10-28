package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionFlattenerTest {
    private fun pocket(id: String, songs: List<String> = emptyList(), albums: List<String> = emptyList(), kids: List<String> = emptyList()) =
        Pocket(id = id, name = "n-$id", songIds = songs, albumIds = albums, childPocketIds = kids)

    private fun ev(id: String, at: Double, kind: ActivityKind, item: String, cid: String?) =
        ActivityEvent(id = id, at = at, kind = kind, itemId = item, collectionId = cid)

    @Test fun dagCycleGuard() {
        val a = pocket("a", listOf("s1"), kids = listOf("b"))
        val b = pocket("b", listOf("s2", "s1"), kids = listOf("a"))   // cycle back to a
        val flat = CollectionFlattener.flatten(CollectionFlattener.Source(pockets = listOf(a, b)))
        assertEquals(listOf("s1", "s2"), flat[0].songIds)
        assertEquals(listOf("s2", "s1"), flat[1].songIds)   // first-seen order, no repeat
        assertEquals(listOf("pocket", "pocket"), flat.map { it.kind })
    }

    @Test fun albumExpansion() {
        val tracks = mapOf("alb" to listOf("t1", "t2"))
        val p = pocket("p", listOf("t2"), albums = listOf("alb", "missing"))
        val seq = PlaylistNode(nodeId = "n0", kind = PlaylistNode.Kind.SEQUENCE, children = listOf(
            PlaylistNode(nodeId = "n1", kind = PlaylistNode.Kind.SONG, songId = "x"),
            PlaylistNode(nodeId = "n2", kind = PlaylistNode.Kind.ALBUM, albumId = "alb"),
            PlaylistNode(nodeId = "n3", kind = PlaylistNode.Kind.POCKET, pocketId = "p"),
            PlaylistNode(nodeId = "n4", kind = PlaylistNode.Kind.TEXT, text = "note"),
        ))
        val pl = Playlist(id = "pls_1", name = "P", sequences = listOf(seq))
        val src = CollectionFlattener.Source(
            pockets = listOf(p), playlists = listOf(pl),
            sourcePlaylists = listOf(CollectionFlattener.SourcePlaylist("src", "S", listOf("a", "b", "a"))),
            albumTracks = tracks,
        )
        val flat = CollectionFlattener.flatten(src)
        assertEquals(listOf("t2", "t1"), flat[0].songIds)
        assertEquals(listOf("x", "t1", "t2"), flat[1].songIds)
        assertEquals(listOf("a", "b"), flat[2].songIds)
        assertEquals("source", flat[2].kind)
        assertEquals(listOf("t1", "t2"), CollectionFlattener.expand("alb", mapOf(), tracks))
        assertEquals(listOf("solo"), CollectionFlattener.expand("solo", mapOf(), tracks))
    }

    @Test fun addTimesLatest() {
        val p = pocket("p", listOf("s1", "s2"))
        val flat = CollectionFlattener.flatten(CollectionFlattener.Source(pockets = listOf(p)))
        val log = listOf(
            ev("1", 100.0, ActivityKind.ADD, "s1", "p"),
            ev("2", 200.0, ActivityKind.REMOVE, "s1", "p"),
            ev("3", 300.0, ActivityKind.ADD, "s1", "p"),   // re-added: the LATEST add stands
            ev("4", 150.0, ActivityKind.ADD, "s2", "p"),
            ev("5", 400.0, ActivityKind.ADD, "gone", "p"), // not a current member
            ev("6", 500.0, ActivityKind.HEART, "s2", null),
        )
        val t = CollectionFlattener.addTimes(flat, log, listOf(p), emptyMap())
        assertEquals(mapOf("s1" to 300.0, "s2" to 150.0), t["p"])
    }

    @Test fun addTimesChildPocketTakesLaterOfBoth() {
        val child = pocket("c", listOf("s1"))
        val parent = pocket("par", kids = listOf("c"))
        val flat = CollectionFlattener.flatten(CollectionFlattener.Source(pockets = listOf(child, parent)))
        val log = listOf(
            ev("1", 100.0, ActivityKind.ADD, "s1", "c"),
            ev("2", 500.0, ActivityKind.ADD, "c", "par"),
        )
        val t = CollectionFlattener.addTimes(flat, log, listOf(child, parent), emptyMap())
        assertEquals(500.0, t["par"]!!["s1"]!!, 0.0)
        assertEquals(100.0, t["c"]!!["s1"]!!, 0.0)
    }

    @Test fun addEventsNewestFirstExpandedAndWindowed() {
        val tracks = mapOf("alb" to listOf("t1", "t2"))
        val log = listOf(
            ev("a", 10.0, ActivityKind.ADD, "old", "p"),
            ev("b", 300.0, ActivityKind.ADD, "alb", "p"),
            ev("c", 200.0, ActivityKind.REMOVE, "s", "p"),
            ev("d", 250.0, ActivityKind.HEART, "s", "p"),
            ev("e", 260.0, ActivityKind.ADD, "s", null),
        )
        val out = CollectionFlattener.addEvents(log, emptyList(), tracks, sinceMs = 100.0)
        assertEquals(listOf("t1", "t2", "s"), out.map { it.songId })
        assertEquals(listOf(300.0, 300.0, 200.0), out.map { it.atMs })
        assertEquals("remove", out.last().kind)
        assertEquals(2, CollectionFlattener.addEvents(log, emptyList(), tracks, 100.0, cap = 2).size)
    }

    @Test fun caps() {
        fun col(id: String, n: Int) = CollectionFlattener.Collection(id, "pocket", id, (1..n).map { "$id$it" })
        val cols = listOf(col("a", 10), col("b", 10), col("c", 10), col("d", 10))
        // per-collection 6, total 15: a=6, b=6, c=3, d=0 (budget exhausted but kept, empty)
        val out = CollectionFlattener.capped(cols, collectionCap = 3, songCap = 6, totalCap = 15)
        assertEquals(listOf(6, 6, 3), out.map { it.songIds.size })
        assertEquals(listOf("a1", "a2", "a3", "a4", "a5", "a6"), out[0].songIds)
        assertTrue(CollectionFlattener.capped(cols, 10, 10, 0).all { it.songIds.isEmpty() })
    }
}
