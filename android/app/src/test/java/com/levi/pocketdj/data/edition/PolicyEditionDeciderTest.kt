package com.levi.pocketdj.data.edition

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PolicyEditionDeciderTest {
    private val base = "sng_0123456789ab"
    private val explicitSong = IndexSong(id = base, artist = "A", name = "N", explicit = true, appleMusicId = "100", appleMusicIdClean = "200")

    private fun decider(pref: Boolean? = null, stored: Set<String> = emptySet(), songs: Map<String, IndexSong> = mapOf(base to explicitSong)) =
        PolicyEditionDecider({ pref }, { songs[it] }, { it in stored })

    @Test fun cleanOnlyCollectionSwapsInTheCleanEditionAndRipsItOnDemand() {
        val out = decider().decide(QueueItem(base), cleanOnly = true)
        assertEquals("clean", out.variant); assertEquals("${base}_clean", out.resolveId); assertEquals(base, out.id)
    }

    @Test fun storedCleanCopyIsUsed() {
        val out = decider(stored = setOf("${base}_clean")).decide(QueueItem(base), true)
        assertEquals("${base}_clean", out.resolveId)
    }

    @Test fun noPreferenceAndNotCleanOnlyLeavesTheRowAlone() {
        val item = QueueItem(base)
        assertEquals(item, decider().decide(item, false))
    }

    @Test fun skipFlagMatrix() {
        val noClean = IndexSong(id = base, artist = "A", name = "N", explicit = true, appleMusicId = "100")
        val clean = IndexSong(id = base, artist = "A", name = "N", explicit = false, appleMusicId = "100")
        val unknownExplicit = explicitSong
        val d = { s: IndexSong? -> decider(songs = if (s == null) emptyMap() else mapOf(base to s)) }
        // explicit + no clean cut: skipped only under clean-only
        assertEquals(true, d(noClean).decide(QueueItem(base), true).cleanOnlySkip)
        assertEquals(false, d(noClean).decide(QueueItem(base), false).cleanOnlySkip)
        // explicit with a clean cut: substituted, never skipped
        assertEquals(false, d(unknownExplicit).decide(QueueItem(base), true).cleanOnlySkip)
        // non-explicit and unknown songs never skipped
        assertEquals(false, d(clean).decide(QueueItem(base), true).cleanOnlySkip)
        assertEquals(false, d(null).decide(QueueItem(base), true).cleanOnlySkip)
        // a skipped row keeps its identity (no variant, resolveId == id)
        val out = d(noClean).decide(QueueItem(base), true)
        assertNull(out.variant); assertEquals(base, out.resolveId)
        // the variant-id form of a row resolves to its base song
        assertEquals(true, d(noClean).decide(QueueItem("${base}_explicit"), true).cleanOnlySkip)
        assertEquals(true, EditionPolicy.isSkipped(noClean)); assertEquals(false, EditionPolicy.isSkipped(null))
    }

    @Test fun globalPreferenceDegradesOntoStoredPrimary() {
        val d = decider(pref = false, stored = setOf(base))
        val out = d.decide(QueueItem(base), false)
        assertEquals(base, out.resolveId); assertNull(out.variant)
    }
}
