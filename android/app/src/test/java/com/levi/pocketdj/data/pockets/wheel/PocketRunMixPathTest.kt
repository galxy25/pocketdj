package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.mix.model.MixLoadable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PocketRunMixPathTest {
    private fun row(i: Int, c: String? = null) = PocketRunPlanner.Row("s$i", i + 1, c, 1.0)
    private fun load(i: Int, len: Int? = 200_000) = MixLoadable("s$i", "t$i", "a$i", null, null, null, null, len)

    @Test fun thresholdIsTenInclusive() {
        assertFalse(PocketRunMixPath.shouldPlayViaMix(9))
        assertTrue(PocketRunMixPath.shouldPlayViaMix(10))
        assertTrue(PocketRunMixPath.shouldPlayViaMix(40))
        assertFalse(PocketRunMixPath.shouldPlayViaMix(0))
    }

    @Test fun slotsAndCollectionsKeyBySongAndSkipMissingCollections() {
        val rows = listOf(row(0, "p1"), row(1), row(2, "p2"))
        assertEquals(mapOf("s0" to 1, "s1" to 2, "s2" to 3), PocketRunMixPath.slots(rows))
        assertEquals(mapOf("s0" to "p1", "s2" to "p2"), PocketRunMixPath.collections(rows))
    }

    @Test fun duplicateSongKeepsFirstSlot() {
        val rows = listOf(row(0, "p1"), PocketRunPlanner.Row("s0", 9, "p2", 1.0))
        assertEquals(mapOf("s0" to 1), PocketRunMixPath.slots(rows))
        assertEquals(mapOf("s0" to "p1"), PocketRunMixPath.collections(rows))
    }

    @Test fun itemsFollowRunOrderLabelAndOriginAndDropUnloadable() {
        val ids = (0..11).map { "s$it" }
        val loadables = (0..11).filter { it != 3 }.reversed().map { load(it) } // scrambled, s3 missing
        val items = PocketRunMixPath.items(ids, "Pocket · Mon", mapOf("s0" to "pk"), loadables)
        assertEquals(11, items.size)
        assertEquals(ids - "s3", items.map { it.loadable.songId })
        assertTrue(items.all { it.sourceLabel == "Pocket · Mon" })
        assertEquals("pk", items[0].originCollectionId)
        assertNull(items[1].originCollectionId)
    }

    @Test fun unknownLengthFallsBackToThreeMinutes() {
        val items = PocketRunMixPath.items(listOf("s0", "s1"), "L", emptyMap(), listOf(load(0, null), load(1, 90_000)))
        assertEquals(180_000, items[0].durationMs)
        assertEquals(90_000, items[1].durationMs)
    }

    @Test fun captionNamesCountAndThreshold() {
        val c = PocketRunMixPath.fallbackCaption(7)
        assertTrue("7" in c && "10" in c)
    }

    @Test fun bridgeStampsPocketRunTagOnMixPlay() {
        val tag = com.levi.pocketdj.data.history.PocketRunTag("run1", "mk", "pk", 4)
        val emitted = mutableListOf<com.levi.pocketdj.playback.PlayStarted>()
        val bridge = com.levi.pocketdj.mix.engine.MixPlayOutcomeBridge(
            emit = { emitted += it }, findEvent = { _, _, _ -> null },
            noteListened = { _, _ -> }, markSkipped = {}, wasSkipped = { false },
            contextLabel = { "Pocket · Mon" },
            pocketRunTag = { id, label -> if (id == "s3" && label == "Pocket · Mon") tag else null },
        )
        bridge.onSongPlayed("s3", com.levi.pocketdj.mix.model.Deck.A)
        bridge.onSongPlayed("s4", com.levi.pocketdj.mix.model.Deck.B)
        assertEquals(tag, emitted[0].context.pocketRun)
        assertNull(emitted[1].context.pocketRun)
        assertEquals("Pocket · Mon", emitted[0].context.contextName)
    }
}
