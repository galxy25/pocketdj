package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.shell.ShellRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueueReorderTest {
    private val uids = listOf("u0", "u1", "u2", "u3", "u4")

    @Test fun windowCapsAt200AndKeepsOrder() {
        val rows = (0 until 350).map { QueueItem(id = "s$it") }
        val w = QueueReorder.window(rows)
        assertEquals(200, w.size)
        assertEquals(rows.take(200), w)
        assertEquals("Up next (350)", QueueReorder.countHeader(rows.size))
    }

    @Test fun dragDownUsesPreMoveDestination() {
        // u1 dragged 2 rows down lands at final index 3 -> onMove destination 4.
        assertEquals(QueueReorder.Move(1, 4), QueueReorder.resolveMove(uids, "u1", 2))
    }

    @Test fun dragUpUsesFinalIndexAsDestination() {
        assertEquals(QueueReorder.Move(3, 1), QueueReorder.resolveMove(uids, "u3", -2))
    }

    @Test fun dragIsClampedToLiveTail() {
        assertEquals(QueueReorder.Move(1, 5), QueueReorder.resolveMove(uids, "u1", 99))
        assertEquals(QueueReorder.Move(2, 0), QueueReorder.resolveMove(uids, "u2", -99))
    }

    @Test fun staleOrNoopDragsResolveToNull() {
        assertNull(QueueReorder.resolveMove(uids, "gone", 1))
        assertNull(QueueReorder.resolveMove(uids, "u2", 0))
        assertNull(QueueReorder.resolveMove(uids, "u4", 5)) // already last: clamps to itself
        assertNull(QueueReorder.resolveMove(emptyList(), "u0", 1))
    }

    @Test fun moveUsesLiveIndexNotRenderIndex() {
        // Rendered with u1 at offset 1; the queue then advanced one row (u0 left). Same uid, new offset 0.
        val live = uids.drop(1)
        assertEquals(QueueReorder.Move(0, 3), QueueReorder.resolveMove(live, "u1", 2))
    }

    @Test fun rowsForDragRoundsToNearest() {
        assertEquals(2, QueueReorder.rowsForDrag(110f, 56f))
        assertEquals(-1, QueueReorder.rowsForDrag(-30f, 56f))
        assertEquals(0, QueueReorder.rowsForDrag(20f, 56f))
        assertEquals(0, QueueReorder.rowsForDrag(500f, 0f))
    }

    @Test fun expandedLayoutAtWideOrLandscape() {
        assertTrue(QueueReorder.useExpandedLayout(600, false))
        assertTrue(QueueReorder.useExpandedLayout(411, true))
        assertFalse(QueueReorder.useExpandedLayout(411, false))
    }

    @Test fun originRoutes() {
        assertEquals(ShellRoute.Playlist("p"), QueueReorder.originRoute("playlist" to "p"))
        assertEquals(ShellRoute.Pocket("k"), QueueReorder.originRoute("pocket" to "k"))
        assertEquals(ShellRoute.Album("a"), QueueReorder.originRoute("album" to "a"))
        assertEquals(ShellRoute.Artist("Bee"), QueueReorder.originRoute("artist" to "Bee"))
        assertNull(QueueReorder.originRoute("browser" to "x"))
        assertNull(QueueReorder.originRoute(null))
    }

    @Test fun openSetListMaterializesOnlyWhenSourceMissing() {
        assertFalse(QueueReorder.needsMaterialize("set_1") { it == "set_1" })
        assertTrue(QueueReorder.needsMaterialize("set_1") { false })
        assertTrue(QueueReorder.needsMaterialize(null) { true })
    }
}
