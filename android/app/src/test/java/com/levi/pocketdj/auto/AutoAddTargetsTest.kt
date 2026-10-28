package com.levi.pocketdj.auto

import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoAddTargetsTest {
    private class Sink(
        val pk: List<AutoTarget>,
        val pl: List<AutoTarget>,
        val added: MutableList<Triple<String, AutoTargetKind, String>> = mutableListOf(),
    ) : AutoAddSink {
        override fun pockets() = pk
        override fun playlists() = pl
        override fun add(songId: String, kind: AutoTargetKind, targetId: String): Boolean {
            added += Triple(songId, kind, targetId); return true
        }
    }

    private fun sink() = Sink(
        pk = listOf(
            AutoTarget(AutoTargetKind.POCKET, "k2", "zebra"),
            AutoTarget(AutoTargetKind.POCKET, "k1", "Alpha"),
            AutoTarget(AutoTargetKind.POCKET, NOW_PLAYING_SETLIST_ID, "Now Playing"),
        ),
        pl = listOf(
            AutoTarget(AutoTargetKind.PLAYLIST, NOW_PLAYING_PLAYLIST_ID, "Now Playing"),
            AutoTarget(AutoTargetKind.PLAYLIST, "p1", "Gym"),
        ),
    )

    @Test fun order_isPocketsThenPlaylists_alphabetical_withoutReserved() {
        val t = AutoAddTargets(sink()).targets()
        assertEquals(listOf("Alpha", "zebra", "Gym"), t.map { it.name })
        assertTrue(t.none { it.id == NOW_PLAYING_SETLIST_ID || it.id == NOW_PLAYING_PLAYLIST_ID })
    }

    @Test fun add_returnsDisplayNameAndWrites() {
        val s = sink()
        assertEquals("Gym", AutoAddTargets(s).add("song1", AutoTargetKind.PLAYLIST, "p1"))
        assertEquals(listOf(Triple("song1", AutoTargetKind.PLAYLIST, "p1")), s.added)
    }

    @Test fun add_unknownOrReservedTarget_isNullAndWritesNothing() {
        val s = sink()
        val a = AutoAddTargets(s)
        assertNull(a.add("song1", AutoTargetKind.POCKET, "missing"))
        assertNull(a.add("song1", AutoTargetKind.POCKET, NOW_PLAYING_SETLIST_ID))
        assertNull(a.add("song1", AutoTargetKind.PLAYLIST, "k1")) // right id, wrong kind
        assertTrue(s.added.isEmpty())
    }

    @Test fun nodes_areOnePerTargetWithDecodableIds_andPlaceholderWhenNone() {
        val nodes = AutoAddTargets(sink()).nodes("s:1")
        assertEquals(3, nodes.size)
        assertEquals(AutoId.AddTarget("s:1", AutoTargetKind.POCKET, "k1"), AutoId.decode(nodes[0].id))
        assertEquals("Pocket", nodes[0].subtitle)
        val none = AutoAddTargets(Sink(emptyList(), emptyList())).nodes("s")
        assertEquals(listOf("No pockets or playlists"), none.map { it.title })
    }

    @Test fun defaultTarget_prefersMostRecentStillValid_elseFirst() {
        val a = AutoAddTargets(sink())
        assertEquals("p1", a.defaultTarget(listOf(AutoTargetKind.POCKET to "gone", AutoTargetKind.PLAYLIST to "p1"))!!.id)
        assertEquals("k1", a.defaultTarget(emptyList())!!.id)
        assertNull(AutoAddTargets(Sink(emptyList(), emptyList())).defaultTarget(emptyList()))
    }
}
