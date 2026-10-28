package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.recs.ForYouCollections
import com.levi.pocketdj.data.recs.ForYouFeedSnapshot
import com.levi.pocketdj.data.recs.ForYouGrid
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ForYouTileRoute
import com.levi.pocketdj.data.recs.RecFeedbackStore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouSongListStateTest {
    private val now = 1_800_000_000_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val tmp = kotlin.io.path.createTempDirectory("fylist").toFile()
    @After fun cleanup() { tmp.deleteRecursively() }

    private fun feedback() = RecFeedbackStore(File(tmp, "fb.json"), scope, saveDebounceMs = 1)

    private class Cols(val members: Map<String, Set<String>> = emptyMap(), val ids: Set<String> = emptySet()) : ForYouCollections {
        override fun exists(id: String) = id in ids
        override fun recommendationsEnabled(id: String) = true
        override fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String) =
            suggestionIds.filter { it !in (members[id] ?: emptySet()) }
    }

    private val zoneRoute = ForYouTileRoute(ForYouTileKind.ZONE, title = "In Da Zone")
    private val colRoute = ForYouTileRoute(ForYouTileKind.COLLECTION, "pl1", "Road trip")

    private fun reject(fb: RecFeedbackStore, id: String, scope: String) {
        fb.record(id, scope, RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = now - 1000)
    }

    @Test fun visibleIdsAreLiveThenSunkInOrder() {
        val fb = feedback()
        reject(fb, "b", "zone")
        val part = fb.partition(listOf("a", "b", "c"), "zone", now)
        assertEquals(listOf("a", "c"), part.live)
        assertEquals(listOf("a", "c", "b"), ForYouSongListState.visibleIds(part))
    }

    @Test fun blendSummaryNamesBuriedOnlyForTheZoneAndOnlyLiveOnes() {
        val fb = feedback()
        reject(fb, "z2", "zone") // a buried row that is sunk must not be counted
        val part = fb.partition(listOf("z1", "z2", "z3", "z4"), "zone", now)
        val buried = setOf("z2", "z3", "z4")
        assertEquals("3 songs · 2 buried", ForYouSongListState.blendSummary(ForYouTileKind.ZONE, part, buried))
        assertEquals("3 songs", ForYouSongListState.blendSummary(ForYouTileKind.COLLECTION, part, buried))
        assertEquals("3 songs", ForYouSongListState.blendSummary(ForYouTileKind.ZONE, part, emptySet()))
    }

    @Test fun acceptChoosesCrateForACollectionAndSheetForZoneOrDeadId() {
        val target = AddTarget(AddTarget.Kind.PLAYLIST, "pl1")
        assertEquals(ForYouAcceptPlan.AddToCrate(target), ForYouSongListState.acceptPlan(ForYouTileKind.COLLECTION, target))
        assertEquals(ForYouAcceptPlan.OpenSheet, ForYouSongListState.acceptPlan(ForYouTileKind.COLLECTION, null))
        assertEquals(ForYouAcceptPlan.OpenSheet, ForYouSongListState.acceptPlan(ForYouTileKind.ZONE, target))
    }

    @Test fun frozenCollectionIdsDropMembersAndTheZoneDropsAcceptedRows() {
        val fb = feedback()
        val cols = Cols(members = mapOf("pl1" to setOf("s2")))
        assertEquals(listOf("s1", "s3"), ForYouSongListState.frozenIds(colRoute, listOf("s1", "s2", "s3"), cols, fb))

        fb.record("z2", "zone", RecFeedbackStore.Verdict.ACCEPTED, RecFeedbackStore.Surface.TILE, atMs = now - 1000)
        assertEquals(listOf("z1", "z3"), ForYouSongListState.frozenIds(zoneRoute, listOf("z1", "z2", "z3"), cols, fb))
    }

    @Test fun tapPlaysOnlyInTheZoneFromTheTappedRowThroughTheVisibleList() {
        assertTrue(ForYouSongListState.tapPlays(ForYouTileKind.ZONE))
        assertEquals(false, ForYouSongListState.tapPlays(ForYouTileKind.COLLECTION))
        assertEquals(listOf("c", "d", "sunk"), ForYouSongListState.queueFrom(listOf("a", "b", "c", "d", "sunk"), 2))
        assertEquals(emptyList<String>(), ForYouSongListState.queueFrom(listOf("a"), 5))
    }

    @Test fun tileCardCountEqualsListHeaderCountForZoneAndCollection() {
        val fb = feedback()
        val cols = Cols(members = mapOf("pl1" to setOf("s1")), ids = setOf("pl1"))
        val snap = ForYouFeedSnapshot(
            refreshedAtMs = now,
            zoneIds = listOf("z1", "z2", "z3", "z4"),
            zoneBuriedIds = listOf("z3"),
            crates = listOf(ForYouFeedSnapshot.Crate("pl1", "playlist", "Road trip", listOf("s1", "s2", "s3", "s4"))),
        )
        reject(fb, "z1", "zone")
        reject(fb, "s4", "pl1")
        fb.record("z2", "zone", RecFeedbackStore.Verdict.ACCEPTED, RecFeedbackStore.Surface.TILE, atMs = now - 1000)

        val tiles = ForYouGrid.tiles(snap, cols, fb, null, now)
        for (tile in tiles.filter { it.route.kind != ForYouTileKind.NEW }) {
            val frozen = snap.songIds(tile.route.tileId)!!
            val ids = ForYouSongListState.frozenIds(tile.route, frozen, cols, fb)
            val part = fb.partition(ids, tile.route.feedbackContext, now)
            val header = ForYouSongListState.blendSummary(tile.route.kind, part, snap.zoneBuriedIds.toSet())
            assertTrue("${tile.id}: '$header' should start with ${tile.count}", header.startsWith("${tile.count} songs"))
        }
    }
}
