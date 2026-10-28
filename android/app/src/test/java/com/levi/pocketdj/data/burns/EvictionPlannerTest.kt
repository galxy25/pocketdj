package com.levi.pocketdj.data.burns

import org.junit.Assert.assertEquals
import org.junit.Test

class EvictionPlannerTest {
    private fun it(
        id: String, audio: String, sidecar: String, source: String = "digital", cut: String? = null,
        state: BurnState = BurnState.READY, app: Boolean? = true,
    ) = BurnItem(
        songId = id, title = id, artist = "A", audioFileName = audio, sidecarFileName = sidecar, source = source,
        bytes = 0, state = state, wasAppStorage = app, cutFileName = cut,
    )

    private val own: (String, Boolean) -> Boolean = { n, user -> BurnFileNames.auxFileSongId(n) != null && !user }

    // d1: digital 1000 + sidecar 10 + stems 4x100 + grid 5. a1,a2: analog sharing 5000 album + 10 sidecars (+cut on a1).
    private val items = mapOf(
        "d1" to it("d1", "D-d1.mp3", "D-d1.txt"),
        "a1" to it("a1", "Alb-alb1.mp3", "A-a1.txt", "analog", cut = "A-a1.mp3"),
        "a2" to it("a2", "Alb-alb1.mp3", "A-a2.txt", "analog"),
    )
    private val files = buildMap<String, Long> {
        put("D-d1.mp3", 1000); put("D-d1.txt", 10)
        put("Alb-alb1.mp3", 5000); put("A-a1.txt", 10); put("A-a2.txt", 10); put("A-a1.mp3", 300)
        BurnFileNames.STEM_NAMES.forEach { put(BurnFileNames.stemFileName("d1", it), 100) }
        put(BurnFileNames.beatgridFileName("d1"), 5)
        put("unrelated.mp3", 99_999) // never counted
        put(BurnFileNames.stemFileName("ghost", "bass"), 50) // orphan aux still owned in the app root
    }
    private val roots = listOf(RootSnapshot(false, files))

    @Test fun usageCountsOnlyOwnedFiles() {
        assertEquals(1000 + 10 + 5000 + 10 + 10 + 300 + 400 + 5 + 50, EvictionPlanner.usageBytes(items.values, roots, own).toInt())
    }

    @Test fun sharedAnalogAudioCreditedOnceWithLastReferencingSong() {
        val usage = 6_785L
        val plan = EvictionPlanner.plan(items, roots, order = listOf("a1", "a2"), capBytes = 0, capSongs = 99, ownsAux = own)
        assertEquals(usage, plan.usageBytes)
        // a1 frees sidecar 10 + cut 300 (audio still referenced by a2); a2 frees sidecar 10 + audio 5000
        assertEquals(usage - 10 - 300 - 10 - 5000, plan.projectedBytes)
        assertEquals(listOf("a1", "a2"), plan.evict)
    }

    @Test fun auxFilesCreditedFromEverySongEvictionAndStopsWhenCapFits() {
        val plan = EvictionPlanner.plan(items, roots, order = listOf("d1", "a1", "a2"), capBytes = 6_785 - 1_515, capSongs = 99, ownsAux = own)
        // d1 frees 1000 + 10 + 400 stems + 5 grid = 1415 (not enough: need 1515) -> a1 frees 310 -> fits
        assertEquals(listOf("d1", "a1"), plan.evict)
        assertEquals(6_785L - 1_415 - 310, plan.projectedBytes)
    }

    @Test fun songCapAloneEvictsAndUnknownOrUnreachableIdsAreSkipped() {
        val withUser = items + ("u1" to it("u1", "U.mp3", "U.txt", app = false))
        val plan = EvictionPlanner.plan(withUser, roots, order = listOf("nope", "u1", "d1"), capBytes = Long.MAX_VALUE, capSongs = 3, ownsAux = own)
        assertEquals(listOf("d1"), plan.evict) // u1's root is unreachable -> kept; 4 ready -> 3 after d1
    }

    @Test fun errorItemsDoNotCountAgainstSongCap() {
        val m = items + ("e1" to it("e1", "", "", state = BurnState.ERROR))
        val plan = EvictionPlanner.plan(m, roots, order = listOf("e1", "d1"), capBytes = Long.MAX_VALUE, capSongs = 2, ownsAux = own)
        assertEquals(listOf("e1", "d1"), plan.evict.also { /* e1 evicted without lowering the ready count */ })
    }
}
