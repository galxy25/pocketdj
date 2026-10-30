package com.levi.pocketdj.playback.durable

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HeldQueueTest {
    @get:Rule val tmp = TemporaryFolder()

    private val snap = SessionSnapshot(
        sessionId = "pses_H",
        source = SessionSourceRef("playlist", "set_now_playing", "Mix"),
        queue = listOf(SessionRow("a", "A", "x"), SessionRow("b", "B", "y", 180_000), SessionRow("c", "C", "")),
        index = 1, positionMs = 42_000,
    )

    @Test fun projectsEveryRowWithIdTitleArtistClip() {
        val items = HeldQueue.from(snap)!!.toMediaItems()
        assertEquals(listOf("a", "b", "c"), items.map { it.mediaId })
        assertEquals("B", items[1].mediaMetadata.title.toString())
        assertEquals("y", items[1].mediaMetadata.artist.toString())
        assertEquals(180_000L, items[1].mediaMetadata.durationMs)
        assertNull(items[2].mediaMetadata.artist) // empty artist stays absent
        assertNull(items[0].mediaMetadata.durationMs)
    }

    @Test fun startPositionIsTheHeldIndexAndOffset() {
        val r = HeldQueue.from(snap)!!.toMediaItemsWithStartPosition()
        assertEquals(1, r.startIndex)
        assertEquals(42_000L, r.startPositionMs)
        assertEquals(3, r.mediaItems.size)
    }

    @Test fun wildIndexAndNegativeOffsetAreClamped() {
        val h = HeldQueue.from(snap.copy(index = 99, positionMs = -5))!!
        assertEquals(2, h.index)
        assertEquals(0L, h.positionMs)
        assertEquals("c", h.currentItem().mediaId)
        assertEquals(0, HeldQueue.from(snap.copy(index = -3))!!.index)
    }

    @Test fun emptyQueueHasNothingToResume() {
        assertNull(HeldQueue.from(snap.copy(queue = emptyList())))
    }

    @Test fun matchesOnlyTheExactResumptionSet() {
        val h = HeldQueue.from(snap)!!
        val items = h.toMediaItems()
        assertTrue(h.matches(items))
        assertFalse(h.matches(items.dropLast(1)))
        assertFalse(h.matches(items.reversed()))
        assertFalse(h.matches(emptyList()))
    }

    @Test fun loadReadsTheSnapshotFileAndToleratesGarbage() {
        val f = File(tmp.root, PLAYBACK_SESSION_FILE)
        assertNull(HeldQueue.load(f)) // missing
        f.writeText("{ not json")
        assertNull(HeldQueue.load(f))
        f.writeText(SessionSnapshot.encode(snap))
        val h = HeldQueue.load(f)!!
        assertEquals(listOf("a", "b", "c"), h.songIds)
        assertEquals("pses_H", h.snapshot.sessionId)
    }
}
