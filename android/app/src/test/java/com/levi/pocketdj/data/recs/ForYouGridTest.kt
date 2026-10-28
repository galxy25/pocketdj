package com.levi.pocketdj.data.recs

import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouGridTest {
    private val now = 1_800_000_000_000.0
    private val day = 86_400_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val tmp = kotlin.io.path.createTempDirectory("fygrid").toFile()

    @After fun cleanup() { tmp.deleteRecursively() }

    private fun feedback() = RecFeedbackStore(File(tmp, "fb.json"), scope, saveDebounceMs = 1)

    private class FakeCollections(
        val live: Set<String>,
        val off: Set<String> = emptySet(),
        val members: Map<String, Set<String>> = emptyMap(),
    ) : ForYouCollections {
        override fun exists(id: String) = id in live
        override fun recommendationsEnabled(id: String) = id !in off
        override fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String) =
            suggestionIds.filter { it !in (members[id] ?: emptySet()) }
    }

    private fun crate(id: String, name: String, n: Int, kind: String = "playlist") =
        ForYouFeedSnapshot.Crate(id, kind, name, (1..n).map { "$id-s$it" })

    private fun snap(vararg crates: ForYouFeedSnapshot.Crate, zone: List<String> = listOf("z1", "z2", "z3")) =
        ForYouFeedSnapshot(refreshedAtMs = now, zoneIds = zone, crates = crates.toList())

    @Test fun newThenZoneAreAlwaysFirstEvenWhenEmpty() {
        val tiles = ForYouGrid.tiles(ForYouFeedSnapshot(), FakeCollections(emptySet()), null, null, now)
        assertEquals(listOf("new", "zone"), tiles.map { it.id })
        assertTrue(tiles.all { it.isPinned })
        assertEquals("No releases in the last 30 days", tiles[0].subtitle)
        assertEquals("Play a few songs to build your zone", tiles[1].subtitle)
    }

    @Test fun collectionsSortByCountDescThenNameAndDropEmptyOnes() {
        val s = snap(crate("a", "Zeta", 2), crate("b", "Alpha", 2), crate("c", "Big", 5), crate("d", "Empty", 0))
        val tiles = ForYouGrid.tiles(s, FakeCollections(setOf("a", "b", "c", "d")), null, null, now)
        assertEquals(listOf("new", "zone", "col-c", "col-b", "col-a"), tiles.map { it.id })
        assertEquals("Suggested for this playlist", tiles[2].subtitle)
        assertFalse(tiles[2].isPinned)
    }

    @Test fun deletedAndRecsOffCratesAreDroppedAtDeriveTime() {
        val s = snap(crate("a", "A", 3), crate("gone", "Gone", 3), crate("off", "Off", 3))
        val tiles = ForYouGrid.tiles(s, FakeCollections(setOf("a", "off"), off = setOf("off")), null, null, now)
        assertEquals(listOf("new", "zone", "col-a"), tiles.map { it.id })
    }

    @Test fun pocketKindGetsItsOwnIconAndSubtitle() {
        val s = snap(crate("p", "Pocket", 2, kind = "pocket"))
        val tile = ForYouGrid.tiles(s, FakeCollections(setOf("p")), null, null, now)[2]
        assertEquals("square.stack", tile.symbol)
        assertEquals("Suggested for this pocket", tile.subtitle)
    }

    @Test fun tombstonedAndAcceptedRowsDoNotCountButMembersAreExcluded() {
        val fb = feedback()
        val s = snap(crate("a", "A", 5), zone = listOf("z1", "z2", "z3", "z4"))
        fb.record("z1", "zone", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = now - day)
        fb.record("z2", "zone", RecFeedbackStore.Verdict.ACCEPTED, RecFeedbackStore.Surface.TILE, atMs = now - day)
        fb.record("a-s1", "a", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = now - day)
        val cols = FakeCollections(setOf("a"), members = mapOf("a" to setOf("a-s2")))
        val tiles = ForYouGrid.tiles(s, cols, fb, null, now)
        assertEquals(2, tiles.first { it.id == "zone" }.count) // z3, z4
        assertEquals(3, tiles.first { it.id == "col-a" }.count) // 5 - rejected s1 - member s2
        val zoneIds = ForYouGrid.songIds(tiles[1], s, cols, fb, now)
        assertEquals(listOf("z3", "z4"), zoneIds)
        assertEquals(listOf("a-s3", "a-s4", "a-s5"), ForYouGrid.songIds(tiles[2], s, cols, fb, now))
        assertEquals(emptyList<String>(), ForYouGrid.songIds(tiles[0], s, cols, fb, now))
    }

    @Test fun expiredTombstoneCountsAgain() {
        val fb = feedback()
        val s = snap(zone = listOf("z1", "z2"))
        fb.record("z1", "zone", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = now - 8 * day)
        assertEquals(2, ForYouGrid.tiles(s, FakeCollections(emptySet()), fb, null, now)[1].count)
    }

    private class FakeReleases(val rows: List<ForYouRelease>, val note: String? = null) : ForYouReleaseSource {
        override fun feed(nowMs: Double) = rows
        override fun emptyTileNote() = note
    }

    @Test fun newTileCountsReleasesWithComingSoonSubtitleAndFeedback() {
        val fb = feedback()
        val rel = FakeReleases(listOf(ForYouRelease("r1", false), ForYouRelease("r2", false), ForYouRelease("r3", true)))
        fb.record("r1", "new", RecFeedbackStore.Verdict.REJECTED, RecFeedbackStore.Surface.TILE, atMs = now - day)
        val t = ForYouGrid.tiles(ForYouFeedSnapshot(), FakeCollections(emptySet()), fb, rel, now)[0]
        assertEquals(2, t.count)
        assertEquals("From artists you play · last 30 days + upcoming", t.subtitle)
    }

    @Test fun emptyNewTileUsesTheFeedsNoteOnlyWhenNothingIsLive() {
        val note = FakeReleases(emptyList(), "Follow some artists to see releases")
        assertEquals("Follow some artists to see releases",
            ForYouGrid.tiles(ForYouFeedSnapshot(), FakeCollections(emptySet()), null, note, now)[0].subtitle)
        val some = FakeReleases(listOf(ForYouRelease("r", false)), "ignored")
        assertEquals("From artists you play · last 30 days",
            ForYouGrid.tiles(ForYouFeedSnapshot(), FakeCollections(emptySet()), null, some, now)[0].subtitle)
    }

    @Test fun zoneSubtitleFollowsSource() {
        val cloud = ForYouFeedSnapshot(refreshedAtMs = now, zoneIds = listOf("a"), zoneSourceRaw = "cloud")
        assertEquals("Top picks · recommendation engine", ForYouGrid.tiles(cloud, FakeCollections(emptySet()), null, null, now)[1].subtitle)
        val dev = cloud.copy(zoneSourceRaw = "onDevice")
        assertEquals("Top picks from your recent activity", ForYouGrid.tiles(dev, FakeCollections(emptySet()), null, null, now)[1].subtitle)
    }

    @Test fun routesAndTileIds() {
        val r = ForYouTileRoute(ForYouTileKind.COLLECTION, "abc", "T")
        assertEquals("abc", r.feedbackContext)
        assertEquals("col-abc", r.tileId)
        assertEquals("zone", ForYouTileRoute(ForYouTileKind.ZONE, title = "Z").feedbackContext)
        assertEquals("new", ForYouTileRoute(ForYouTileKind.NEW, title = "N").tileId)
    }
}
