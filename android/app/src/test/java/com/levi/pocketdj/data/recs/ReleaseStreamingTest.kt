package com.levi.pocketdj.data.recs

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseStreamingTest {
    private fun t(id: String, title: String = "T$id", artist: String = "A", len: Long? = 1000) =
        ReleaseStreamTrack(id, title, artist, len)

    @Test fun itemsNamespaceDropBlankAndCollapseDuplicates() {
        val items = ReleaseStreaming.items(
            listOf(t("1"), t(" "), t(""), t("2"), t("1", title = "dup single"), t(" 3 ")),
        )
        assertEquals(listOf("am:1", "am:2", "am:3"), items.map { it.id })
        assertEquals("T1", items[0].title)
        assertEquals(1000L, items[0].lengthMs)
    }

    @Test fun ownedTrackPlaysUnderItsOwnCatalogSongId() {
        val items = ReleaseStreaming.items(listOf(t("1"), t("2"))) { if (it == "2") "sng_owned" else null }
        assertEquals(listOf("am:1", "sng_owned"), items.map { it.id })
        // two store ids mapping to ONE owned song collapse
        val dup = ReleaseStreaming.items(listOf(t("2"), t("22"))) { "sng_owned" }
        assertEquals(listOf("sng_owned"), dup.map { it.id })
    }

    @Test fun releasesAreCappedAtTwentyFiveAndOrderIsPreserved() = runBlocking {
        val asked = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val rows = ReleaseStreaming.tracks((1..40).map { "r$it" }) { id ->
            asked += id
            // Later releases answer FIRST: completion order must not leak into the queue.
            delay(((41 - id.drop(1).toInt()) * 2).toLong())
            listOf(t(id))
        }
        assertEquals(25, asked.size)
        assertEquals((1..25).map { "r$it" }, rows.map { it.storeId })
    }

    @Test fun expansionConcurrencyIsFour() = runBlocking {
        val inFlight = AtomicInteger(0)
        var peak = 0
        val lock = Any()
        ReleaseStreaming.tracks((1..12).map { "r$it" }) { id ->
            val n = inFlight.incrementAndGet()
            synchronized(lock) { if (n > peak) peak = n }
            delay(15)
            inFlight.decrementAndGet()
            listOf(t(id))
        }
        assertEquals(ReleaseStreaming.CONCURRENCY, peak)
    }

    @Test fun failedExpansionDropsThatReleaseOnly() = runBlocking {
        val rows = ReleaseStreaming.tracks(listOf("a", "b", "c")) { id ->
            when (id) {
                "b" -> throw IllegalStateException("boom")
                else -> listOf(t(id))
            }
        }
        assertEquals(listOf("a", "c"), rows.map { it.storeId })
    }

    @Test fun allEmptyExpansionsYieldNoQueueAndTheOneMessage() = runBlocking {
        val rows = ReleaseStreaming.tracks(listOf("a", "b")) { emptyList() }
        assertTrue(ReleaseStreaming.items(rows).isEmpty())
        assertTrue(ReleaseStreaming.EMPTY_EXPANSION_MESSAGE.startsWith("Apple Music didn’t return a track list"))
        assertTrue(ReleaseStreaming.tracks(emptyList()) { listOf(t("x")) }.isEmpty())
    }

    @Test fun onlyOutNowReleasesWithAStoreIdArePlayable() {
        fun item(id: Int, release: String?, status: ReleaseStatus) =
            ReleaseFeedItem(ArtistReleaseEntry(id, "A", 0.0, release), status)
        val ids = ReleaseStreaming.playableReleaseIds(
            listOf(
                item(1, "r1", ReleaseStatus.OUT_NOW),
                item(2, "r2", ReleaseStatus.COMING_SOON),
                item(3, null, ReleaseStatus.OUT_NOW),
                item(4, " ", ReleaseStatus.OUT_NOW),
            ),
        )
        assertEquals(listOf("r1"), ids)
    }

    @Test fun runTagIsNotAPuzzleTag() {
        assertEquals("foryou_new", ReleaseStreaming.RUN_TAG)
        assertTrue(!ReleaseStreaming.RUN_TAG.startsWith("puzzle_"))
    }
}
