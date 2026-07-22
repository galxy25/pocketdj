package com.levi.pocketdj.playback

import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.SetlistTrack
import com.levi.pocketdj.data.rips.PlayAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The queue-planning contract of specs/realize-play.md §6.2–§6.3:
 * skip-unplayable at build time, per-item repeat expansion by consecutive
 * duplication, clip-window carry-through, and the setlist row filter.
 */
class QueuePlanTest {

    private fun stream(id: String) = PlayAction.Stream(url = "https://rips/$id.mp3")

    private fun resolver(playable: Map<String, PlayAction.Stream>): (String) -> PlayAction =
        { id -> playable[id] ?: PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED) }

    @Test
    fun build_keepsStreamHits_skipsMetadataOnlyAndRipRequired() {
        val plan = QueuePlan.build(
            listOf(
                QueuePlan.QueueEntry("sng_1"),
                QueuePlan.QueueEntry("sng_am_only"),
                QueuePlan.QueueEntry("sng_2"),
            ),
        ) { id ->
            when (id) {
                "sng_1" -> stream("sng_1")
                "sng_2" -> PlayAction.RipRequired("sng_2") // P2 cut: no rip inside a queue run
                else -> PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED)
            }
        }
        assertEquals(listOf("sng_1"), plan.items.map { it.songId })
        assertEquals(1, plan.playableEntryCount)
        assertEquals(2, plan.skippedEntryCount)
        assertEquals(3, plan.requestedEntryCount)
        assertEquals("Playing 1 of 3 — 2 not playable on Android", plan.skippedSummary)
    }

    @Test
    fun build_expandsRepeatsIntoConsecutiveItems_sharingTheEntryIndex() {
        val plan = QueuePlan.build(
            listOf(
                QueuePlan.QueueEntry("sng_1", repeatCount = 3),
                QueuePlan.QueueEntry("sng_2", repeatCount = null),
                QueuePlan.QueueEntry("sng_3", repeatCount = 500), // clamps to 99
            ),
            resolver(mapOf("sng_1" to stream("sng_1"), "sng_2" to stream("sng_2"), "sng_3" to stream("sng_3"))),
        )
        assertEquals(
            listOf("sng_1", "sng_1", "sng_1", "sng_2"),
            plan.items.take(4).map { it.songId },
        )
        assertEquals(listOf(0, 0, 0, 1), plan.items.take(4).map { it.entryIndex })
        assertEquals(99, plan.items.count { it.songId == "sng_3" })
        assertEquals(3, plan.playableEntryCount)
        assertEquals(0, plan.skippedEntryCount)
        assertNull(plan.skippedSummary)
    }

    @Test
    fun build_emptySongId_skips_allSkippedIsEmptyPlan() {
        val plan = QueuePlan.build(
            listOf(QueuePlan.QueueEntry(""), QueuePlan.QueueEntry("sng_x")),
            resolver(emptyMap()),
        )
        assertTrue(plan.isEmpty)
        assertEquals(2, plan.skippedEntryCount)
    }

    @Test
    fun build_carriesAnalogClipWindows_unboundedRowsKept() {
        val bounded = PlayAction.Stream(url = "u", clipStartMs = 1_000, clipEndMs = 61_000)
        val unbounded = PlayAction.Stream(url = "u", clipStartMs = 90_000, clipEndMs = null)
        val plan = QueuePlan.build(
            listOf(QueuePlan.QueueEntry("sng_a"), QueuePlan.QueueEntry("sng_b")),
            resolver(mapOf("sng_a" to bounded, "sng_b" to unbounded)),
        )
        // NO truncation after the unbounded row (setlists ≠ album up-next).
        assertEquals(2, plan.items.size)
        assertEquals(bounded, plan.items[0].action)
        assertTrue(plan.items[1].action.isUnboundedAnalog)
    }

    @Test
    fun entriesForSetlist_filtersTextCuesAndEmptyIds_carriesRepeats() {
        val setlist = Setlist(
            id = "set_1",
            playlistId = "pls_1",
            seed = "s",
            tracks = listOf(
                SetlistTrack(songId = "sng_1", artist = "A", name = "One", repeatCount = 2),
                SetlistTrack(name = "mic break", isText = true),
                SetlistTrack(songId = "", artist = "", name = "blank"),
                SetlistTrack(songId = "sng_2", artist = "B", name = "Two"),
            ),
        )
        val entries = QueuePlan.entriesForSetlist(setlist)
        assertEquals(
            listOf(QueuePlan.QueueEntry("sng_1", 2), QueuePlan.QueueEntry("sng_2", null)),
            entries,
        )
    }
}
