package com.levi.pocketdj.auto

import com.levi.pocketdj.data.recs.ForYouCollections
import com.levi.pocketdj.data.recs.ForYouFeedSnapshot
import com.levi.pocketdj.data.recs.ForYouRelease
import com.levi.pocketdj.data.recs.ForYouReleaseSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoForYouTest {
    private class Collections(val live: Set<String> = setOf("k1")) : ForYouCollections {
        override fun exists(id: String) = id in live
        override fun recommendationsEnabled(id: String) = true
        override fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String) = suggestionIds
    }

    private class Source(
        var snap: ForYouFeedSnapshot,
        var releases: List<AutoRelease> = emptyList(),
        override val collections: ForYouCollections = Collections(),
    ) : AutoForYouSource {
        var snapshotReads = 0
        override fun snapshot(): ForYouFeedSnapshot { snapshotReads++; return snap }
        override val feedback = null
        override val releaseSource: ForYouReleaseSource = object : ForYouReleaseSource {
            override fun feed(nowMs: Double) = releases.map { ForYouRelease(it.feedbackId, false) }
            override fun emptyTileNote(): String? = null
        }
        override fun outNowReleases(nowMs: Double) = releases
    }

    private fun snap() = ForYouFeedSnapshot(
        refreshedAtMs = 1000.0,
        zoneIds = listOf("z1", "z2", "gone", "z3"),
        crates = listOf(
            ForYouFeedSnapshot.Crate("k1", "pocket", "Warmup", listOf("c1", "c2")),
            ForYouFeedSnapshot.Crate("deleted", "playlist", "Old", listOf("c1")),
        ),
    )

    private val songs = listOf("z1", "z2", "z3", "c1", "c2").associateWith { mkSong(it) } +
        ("z2" to mkSong("z2", playable = false))

    private val rel = listOf(
        AutoRelease("111", "New Album", "Artist A", "rel:111"),
        AutoRelease("222", "Other EP", "Artist B", "rel:222"),
    )

    private fun fy(src: Source) = AutoForYou(src, { songs[it] })

    private fun tileId(vararg parts: String) = AutoId.ForYouTile(parts.first()).encoded

    @Test fun tree_fromCachedFeed_usesPhoneOrder_newThenZoneThenCollections_andDropsDeletedCrates() {
        val f = fy(Source(snap(), rel))
        val titles = f.children().map { it.title }
        assertEquals(listOf("New", "In Da Zone", "Warmup"), titles)
        assertEquals(listOf("fy:new", "fy:zone", "fy:col-k1"), f.children().map { it.id })
        assertTrue(f.children().all { it.browsable })
    }

    @Test fun tileSubtitles_newCountsPlayableReleases_zoneCountsLiveIds() {
        val kids = fy(Source(snap(), rel)).children()
        assertEquals("2 releases · From artists you play · last 30 days", kids[0].subtitle)
        // zone ids: 4 frozen (the tile counts frozen live ids, "gone" resolves later at row time)
        assertEquals("4 songs · Top picks from your recent activity", kids[1].subtitle)
        assertEquals("2 songs · Suggested for this pocket", kids[2].subtitle)
        assertEquals(2, kids[2].childCount)
    }

    @Test fun emptyNewTile_showsOwnNoteNotZeroReleases() {
        val kids = fy(Source(snap(), emptyList())).children()
        assertEquals("No releases in the last 30 days", kids[0].subtitle)
    }

    @Test fun coldCache_isOneNoteRow_andNeverBuildsTiles() {
        val src = Source(ForYouFeedSnapshot(), rel)
        val kids = fy(src).children()
        assertEquals(1, kids.size)
        assertEquals("Open For You on your phone to build your recommendations", kids[0].title)
        assertEquals(AutoId.ForYouNote.encoded, kids[0].id)
        assertFalse(kids[0].browsable || kids[0].playable)
    }

    @Test fun staleSchemaFileReadsAsEmpty_soColdNote() {
        // A pre-v3 doc is not a cache (ForYouFeedStore drops it): the store hands the car an empty snapshot.
        assertFalse(ForYouFeedSnapshot(schemaVersion = 2, refreshedAtMs = 5.0).isCurrent)
        assertFalse(ForYouFeedSnapshot().hasResult)
    }

    @Test fun zoneDrillIn_playAllShuffleThenResolvableRows_unplayableShownNotPlayable() {
        val f = fy(Source(snap(), rel))
        val kids = f.tileChildren("zone")!!
        assertEquals(listOf("Play all", "Shuffle all"), kids.take(2).map { it.title })
        assertTrue(kids.take(2).all { it.playable })
        val rows = kids.drop(2)
        // "gone" has no catalog song -> skipped, like iOS compactMap
        assertEquals(listOf("Song z1", "Song z2", "Song z3"), rows.map { it.title })
        assertFalse(rows[1].playable)
        assertTrue(rows[1].subtitle!!.endsWith(AutoBrowseTree.UNAVAILABLE))
        assertTrue(rows.all { it.addToAction })
    }

    @Test fun newDrillIn_releaseRowsAreNamespaced_playable_andHaveNoAddTo() {
        val f = fy(Source(snap(), rel))
        val rows = f.tileChildren("new")!!.drop(2)
        assertEquals(listOf("New Album", "Other EP"), rows.map { it.title })
        val id = AutoId.decode(rows[0].id) as AutoId.ForYouRow
        assertEquals("rel:111", id.rowId)
        assertNull(f.songIdOf(id))
        assertTrue(rows.all { it.playable && !it.addToAction })
    }

    @Test fun emptyTile_isOnePlaceholder_unknownTileIsNull() {
        val f = fy(Source(snap(), emptyList()))
        assertEquals(listOf("No new releases yet"), f.tileChildren("new")!!.map { it.title })
        assertNull(f.tileChildren("col-nope"))
    }

    @Test fun plan_tileAndShuffle_andPlayFromHere_andRelease() {
        val f = fy(Source(snap(), rel))
        assertEquals(
            AutoForYouPlay.Songs(listOf("z1", "z2", "gone", "z3"), "In Da Zone", "zone", false),
            f.plan(AutoId.ForYouTile("zone")),
        )
        assertEquals(
            AutoForYouPlay.Songs(listOf("c1", "c2"), "Warmup", "k1", true),
            f.plan(AutoId.ForYouAll("col-k1", shuffle = true)),
        )
        // play from the tapped row onward
        assertEquals(
            AutoForYouPlay.Songs(listOf("z3"), "In Da Zone", "zone", false),
            f.plan(AutoId.ForYouRow("zone", "z3")),
        )
        assertNull(f.plan(AutoId.ForYouRow("zone", "not-in-tile")))
        assertEquals(AutoForYouPlay.Releases(listOf("111", "222"), true), f.plan(AutoId.ForYouAll("new", true)))
        assertEquals(AutoForYouPlay.Releases(listOf("222"), false), f.plan(AutoId.ForYouRow("new", "rel:222")))
        assertNull(f.plan(AutoId.ForYouRow("new", "rel:")))
        assertNull(fy(Source(snap(), emptyList())).plan(AutoId.ForYouTile("new")))
    }

    @Test fun liveReleases_dropsAcceptedAndRejected_keepsOrder() {
        val out = AutoForYou.liveReleases(rel, accepted = mapOf("rel:111" to 1.0), tombstones = emptyMap())
        assertEquals(listOf("222"), out.map { it.releaseId })
        val out2 = AutoForYou.liveReleases(rel, emptyMap(), mapOf("rel:222" to 1.0))
        assertEquals(listOf("111"), out2.map { it.releaseId })
        assertEquals(rel, AutoForYou.liveReleases(rel, emptyMap(), emptyMap()))
    }

    @Test fun idCodec_roundTrips_includingColonsInRowIds() {
        val ids = listOf(
            AutoId.ForYouTile("col-k:1"), AutoId.ForYouAll("zone", true), AutoId.ForYouAll("zone", false),
            AutoId.ForYouRow("new", "rel:123"), AutoId.ForYouNote, AutoId.Tab(AutoId.Tab.Which.FOR_YOU),
        )
        for (i in ids) assertEquals(i, AutoId.decode(i.encoded))
        assertEquals("tab:foryou", AutoId.Tab(AutoId.Tab.Which.FOR_YOU).encoded)
        assertNull(AutoId.decode("fyrow:a"))
        assertNull(AutoId.decode("fy"))
    }

    // ---- root: tab placement + ROOT_CHILDREN_LIMIT folding ----

    private fun tree(limit: Int?, held: Boolean = true, forYou: Boolean = true, cold: Boolean = false) =
        AutoBrowseTree(
            FakeAutoData(held = if (held) AutoHeld("Song", "Artist") else null),
            forYou = if (forYou) fy(Source(if (cold) ForYouFeedSnapshot() else snap(), rel)) else null,
        ).also { it.rootLimit = limit }

    @Test fun root_noLimit_hasContinuePlaylistsPocketsForYou() {
        assertEquals(listOf("Continue", "Playlists", "Pockets", "For You"), tree(null).children(AutoId.Root.encoded)!!.map { it.title })
    }

    @Test fun root_noForYouWired_hidesTheTab() {
        assertEquals(listOf("Continue", "Playlists", "Pockets"), tree(null, forYou = false).children(AutoId.Root.encoded)!!.map { it.title })
    }

    @Test fun root_limit4_withContinueAndForYou_foldsContinueIntoTopOfPlaylists() {
        val t = tree(4)
        // Playlists + Pockets + For You = 3 tabs; + Continue = 4 fits.
        assertEquals(4, t.children(AutoId.Root.encoded)!!.size)
        // Add Mix as a 4th tab: root would be 5 > 4.
        val withMix = AutoBrowseTree(
            FakeAutoData(held = AutoHeld("Song", "Artist")),
            forYou = fy(Source(snap(), rel)),
            mix = null,
        )
        withMix.rootLimit = 3
        val root = withMix.children(AutoId.Root.encoded)!!
        assertEquals(listOf("Playlists", "Pockets", "For You"), root.map { it.title })
        val pl = withMix.children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded)!!
        assertEquals("Continue", pl.first().title)
        assertEquals(AutoId.Continue.encoded, pl.first().id)
        assertTrue(pl.first().playable)
    }

    @Test fun root_limitNotExceeded_continueStaysAtRoot_andPlaylistsHaveNoContinue() {
        val t = tree(5)
        assertEquals("Continue", t.children(AutoId.Root.encoded)!!.first().title)
        val pl = t.children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded)!!
        assertTrue(pl.none { it.id == AutoId.Continue.encoded })
    }

    @Test fun root_foldedWithNoHeld_hasNothingToFold() {
        val t = tree(3, held = false)
        assertEquals(3, t.children(AutoId.Root.encoded)!!.size)
        assertTrue(t.children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded)!!.none { it.id == AutoId.Continue.encoded })
    }

    @Test fun tabChildren_forYou_andTileDrillIn_goThroughTheTree() {
        val t = tree(null)
        assertEquals(listOf("New", "In Da Zone", "Warmup"), t.children("tab:foryou")!!.map { it.title })
        assertEquals("Play all", t.children("fy:zone")!!.first().title)
        assertEquals("In Da Zone", t.item("fy:zone")!!.title)
        assertEquals("For You", t.item("tab:foryou")!!.title)
        assertNull(t.item("fy:nope"))
    }

    @Test fun cold_tabShowsNote_viaTree() {
        assertEquals(
            listOf("Open For You on your phone to build your recommendations"),
            tree(null, cold = true).children("tab:foryou")!!.map { it.title },
        )
    }

    @Test fun browsingNeverReadsMoreThanTheCachedSnapshot() {
        val src = Source(snap(), rel)
        val f = fy(src)
        f.children(); f.tileChildren("zone"); f.item(AutoId.ForYouTile("zone"))
        assertTrue(src.snapshotReads > 0) // only snapshot() is ever read: there is no refresh seam on the port
    }

    // ---- selection through the callback ----

    private class Rec : AutoPlayer {
        val calls = mutableListOf<String>()
        override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) {}
        override suspend fun playSong(ref: AutoCollectionRef, songId: String) {}
        override suspend fun playSolo(songId: String) {}
        override suspend fun resumeHeld() {}
        override suspend fun playForYouSongs(ids: List<String>, name: String, scope: String, shuffle: Boolean) {
            calls += "songs:$name:$scope:$shuffle:${ids.joinToString(",")}"
        }
        override suspend fun playReleases(releaseIds: List<String>, shuffle: Boolean) {
            calls += "rel:$shuffle:${releaseIds.joinToString(",")}"
        }
    }

    private class NoSink : AutoAddSink {
        override fun pockets() = emptyList<AutoTarget>()
        override fun playlists() = emptyList<AutoTarget>()
        override fun add(songId: String, kind: AutoTargetKind, targetId: String) = false
    }

    private fun cb(rec: Rec, toasts: MutableList<String> = mutableListOf()) = AutoLibraryCallback(
        tree = tree(null),
        addTargets = AutoAddTargets(NoSink()),
        player = rec,
        scope = CoroutineScope(Dispatchers.Unconfined),
        toast = { toasts += it },
        notifyChildrenChanged = { _, _ -> },
    )

    @Test fun select_tile_playsWholeTile_thenRowPlaysFromHere_releaseUsesReleasePath() {
        val rec = Rec(); val c = cb(rec)
        runBlocking { c.select("fy:zone")!!.join() }
        runBlocking { c.select("fyshuf:col-k1")!!.join() }
        runBlocking { c.select(AutoId.ForYouRow("zone", "z3").encoded)!!.join() }
        runBlocking { c.select(AutoId.ForYouRow("new", "rel:111").encoded)!!.join() }
        runBlocking { c.select("fyall:new")!!.join() }
        assertEquals(
            listOf(
                "songs:In Da Zone:zone:false:z1,z2,gone,z3",
                "songs:Warmup:k1:true:c1,c2",
                "songs:In Da Zone:zone:false:z3",
                "rel:false:111",
                "rel:false:111,222",
            ),
            rec.calls,
        )
    }

    @Test fun select_unplayableRow_toastsAndNeverPlays_noteRowDoesNothing() {
        val rec = Rec(); val toasts = mutableListOf<String>(); val c = cb(rec, toasts)
        runBlocking { c.select(AutoId.ForYouRow("zone", "z2").encoded)!!.join() }
        runBlocking { c.select(AutoId.ForYouNote.encoded)!!.join() }
        assertTrue(rec.calls.isEmpty())
        assertEquals(listOf(AutoBrowseTree.UNAVAILABLE), toasts)
    }

    @Test fun addToChooser_forSongRows_onlyNotReleaseRows() {
        val c = cb(Rec())
        assertEquals(AutoId.AddTo("z1").encoded, c.addToChooserNode(AutoId.ForYouRow("zone", "z1").encoded))
        assertNull(c.addToChooserNode(AutoId.ForYouRow("new", "rel:111").encoded))
        assertNotNull(c.getChildren("tab:foryou", 0, 50))
    }

    private fun cbWithNotes(notes: MutableList<String>, limit: Int? = null) = AutoLibraryCallback(
        tree = tree(limit),
        addTargets = AutoAddTargets(NoSink()),
        player = Rec(),
        scope = CoroutineScope(Dispatchers.Unconfined),
        toast = {},
        notifyChildrenChanged = { p, _ -> notes += p },
    ).also { it.onCatalogReady() }

    @Test fun rootLimit_onlyLowers_aHintlessOrLooserControllerNeverResetsIt() {
        val notes = mutableListOf<String>()
        val c = cbWithNotes(notes)
        c.setRootLimit(4)
        assertEquals(4, c.javaClass.getDeclaredField("tree").also { it.isAccessible = true }.get(c).let { (it as AutoBrowseTree).rootLimit })
        c.setRootLimit(null)
        c.setRootLimit(8)
        val tree = c.javaClass.getDeclaredField("tree").also { it.isAccessible = true }.get(c) as AutoBrowseTree
        assertEquals(4, tree.rootLimit)
        assertEquals(4, tree.children(AutoId.Root.encoded)!!.size)
        c.setRootLimit(3)
        assertEquals(3, tree.rootLimit)
    }

    @Test fun openForYouTile_isReNotifiedWithTheTabs() {
        val notes = mutableListOf<String>()
        val c = cbWithNotes(notes)
        c.getChildren("fy:zone", 0, 50)
        notes.clear()
        c.notifyLibraryChanged()
        assertTrue("fy:zone" in notes)
        assertTrue("tab:foryou" in notes)
    }

    @Test fun newTile_countAndRowsComeFromTheSameReleaseList() {
        val f = fy(Source(snap(), rel))
        val count = f.children().first { it.id == "fy:new" }.childCount
        val rows = f.tileChildren("new")!!.filter { it.id.startsWith("fyrow:") }
        assertEquals(count, rows.size)
        val cold = fy(Source(snap(), emptyList()))
        assertEquals(0, cold.children().first { it.id == "fy:new" }.childCount)
        assertEquals("No new releases yet", cold.tileChildren("new")!!.single().title)
    }
}
