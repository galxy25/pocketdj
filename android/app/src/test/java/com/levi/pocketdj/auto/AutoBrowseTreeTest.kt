package com.levi.pocketdj.auto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoBrowseTreeTest {
    private fun tree(d: FakeAutoData, max: Int = AutoBrowseTree.MAX_SONGS) = AutoBrowseTree(d, max)

    private fun libraryData() = FakeAutoData(
        playlists = listOf(
            AutoCollectionInfo(plRef("p2"), "zeta mix", 3),
            AutoCollectionInfo(plRef("p1"), "Alpha", 1),
        ),
        sources = listOf(AutoCollectionInfo(srcRef("s1", "Apple Music (Local)"), "Road Trip", 2, badge = "Apple Music (Local)")),
        pockets = listOf(
            AutoCollectionInfo(pkRef("k1"), "Warmup", 12),
            AutoCollectionInfo(pkRef("k0"), "Afterhours", 1),
        ),
    )

    @Test fun root_withoutHeldSession_isPlaylistsThenPockets() {
        val kids = tree(libraryData()).children(AutoId.Root.encoded)!!
        assertEquals(listOf("Playlists", "Pockets"), kids.map { it.title })
        assertTrue(kids.all { it.browsable && !it.playable })
    }

    @Test fun root_withHeldSession_putsContinueFirstAndPlayable() {
        val d = libraryData().apply { held = AutoHeld("Blue Monday", "New Order") }
        val kids = tree(d).children(AutoId.Root.encoded)!!
        assertEquals(listOf("Continue", "Playlists", "Pockets"), kids.map { it.title })
        assertTrue(kids[0].playable)
        assertEquals("Blue Monday – New Order", kids[0].subtitle)
        assertEquals(AutoId.Continue.encoded, kids[0].id)
    }

    @Test fun root_catalogNotReady_isSingleLoadingChild() {
        val d = libraryData().apply { catalogReady = false; held = AutoHeld("x", "y") }
        val kids = tree(d).children(AutoId.Root.encoded)!!
        assertEquals(listOf("Loading…"), kids.map { it.title })
        assertFalse(kids[0].playable || kids[0].browsable)
        // The tabs say the same, and nothing is read from the (possibly cold) catalog.
        assertEquals(listOf("Loading…"), tree(d).children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded)!!.map { it.title })
    }

    @Test fun playlistsTab_userPlaylistsThenSourceRowsWithBadgeSubtitle() {
        val kids = tree(libraryData()).children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded)!!
        assertEquals(listOf("Alpha", "zeta mix", "Road Trip"), kids.map { it.title })
        assertEquals("1 song", kids[0].subtitle)
        assertEquals("3 songs", kids[1].subtitle)
        assertEquals("Apple Music (Local) · 2 songs", kids[2].subtitle)
        val id = AutoId.decode(kids[2].id) as AutoId.Collection
        assertEquals(AutoCollectionKind.SOURCE, id.ref.kind)
        assertEquals("Apple Music (Local)", id.ref.sourceName)
    }

    @Test fun pocketsTab_listsWithCounts_alphabetical() {
        val kids = tree(libraryData()).children(AutoId.Tab(AutoId.Tab.Which.POCKETS).encoded)!!
        assertEquals(listOf("Afterhours", "Warmup"), kids.map { it.title })
        assertEquals(listOf("1 song", "12 songs"), kids.map { it.subtitle })
    }

    @Test fun emptyTab_showsPlaceholder() {
        val kids = tree(FakeAutoData()).children(AutoId.Tab(AutoId.Tab.Which.POCKETS).encoded)!!
        assertEquals(1, kids.size)
        assertEquals("No pockets yet", kids[0].title)
        assertFalse(kids[0].playable || kids[0].browsable)
    }

    @Test fun pocketSongs_arePlayAllShuffleAllThenSongsInGivenDagOrder() {
        val ref = pkRef("k1")
        val d = libraryData().apply {
            songs = listOf("c", "a", "b").associateWith { mkSong(it) }
            songIdsByRef = mapOf(ref to listOf("c", "a", "b")) // DAG order is the store's; the tree must not re-sort
        }
        val kids = tree(d).children(AutoId.Collection(ref).encoded)!!
        assertEquals(listOf("Play all", "Shuffle all", "Song c", "Song a", "Song b"), kids.map { it.title })
        assertEquals(AutoId.PlayAll(ref).encoded, kids[0].id)
        assertEquals(AutoId.ShuffleAll(ref).encoded, kids[1].id)
        assertEquals(AutoId.Song(ref, "c").encoded, kids[2].id)
        assertEquals("https://art/c.jpg", kids[2].artUrl)
        assertTrue(kids[2].addToAction)
        assertFalse(kids[0].addToAction)
    }

    @Test fun songWindow_isCapped() {
        val ref = plRef("p1")
        val ids = (1..500).map { "s$it" }
        val d = libraryData().apply {
            songs = ids.associateWith { mkSong(it) }
            songIdsByRef = mapOf(ref to ids)
        }
        val kids = tree(d, max = 200).children(AutoId.Collection(ref).encoded)!!
        assertEquals(2 + 200, kids.size)
        assertEquals("Song s200", kids.last().title)
    }

    @Test fun unplayableSong_isNonPlayableWithSubtitle() {
        val ref = plRef("p1")
        val d = libraryData().apply {
            songs = mapOf("ok" to mkSong("ok"), "am" to mkSong("am", playable = false, artist = "Someone"))
            songIdsByRef = mapOf(ref to listOf("ok", "am"))
        }
        val kids = tree(d).children(AutoId.Collection(ref).encoded)!!
        val am = kids.first { it.title == "Song am" }
        assertFalse(am.playable)
        assertFalse(am.browsable)
        assertEquals("Someone · Not available here", am.subtitle)
        assertTrue(kids.first { it.title == "Song ok" }.playable)
    }

    @Test fun emptyCollection_showsNoSongsPlaceholderAndNoPlayRows() {
        val ref = pkRef("k0")
        val kids = tree(libraryData()).children(AutoId.Collection(ref).encoded)!!
        assertEquals(listOf("No songs"), kids.map { it.title })
        assertFalse(kids[0].playable)
    }

    @Test fun collectionWhoseSongsAllFailToResolve_isAlsoNoSongs() {
        val ref = pkRef("k1")
        val d = libraryData().apply { songIdsByRef = mapOf(ref to listOf("ghost")) }
        assertEquals(listOf("No songs"), tree(d).children(AutoId.Collection(ref).encoded)!!.map { it.title })
    }

    @Test fun unknownParents_returnNull() {
        val t = tree(libraryData())
        assertNull(t.children("nonsense"))
        assertNull(t.children(AutoId.Collection(plRef("missing")).encoded))
    }

    @Test fun paging_windowsTheChildren() {
        val kids = tree(libraryData()).children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded, page = 1, pageSize = 2)!!
        assertEquals(listOf("Road Trip"), kids.map { it.title })
        assertTrue(tree(libraryData()).children(AutoId.Tab(AutoId.Tab.Which.PLAYLISTS).encoded, page = 9, pageSize = 2)!!.isEmpty())
    }

    @Test fun item_resolvesKnownIds() {
        val ref = plRef("p1")
        val d = libraryData().apply { songs = mapOf("a" to mkSong("a")); songIdsByRef = mapOf(ref to listOf("a")) }
        val t = tree(d)
        assertNotNull(t.item(AutoId.Root.encoded))
        assertEquals("Alpha", t.item(AutoId.Collection(ref).encoded)!!.title)
        assertEquals("Song a", t.item(AutoId.Song(ref, "a").encoded)!!.title)
        assertNull(t.item(AutoId.Collection(plRef("nope")).encoded))
        assertNull(t.item("garbage"))
    }

    @Test fun search_collectionsBeforeSongs() {
        val d = libraryData().apply { songs = mapOf("1" to mkSong("1").copy(title = "Warmup Jam")) }
        val res = tree(d).search("warmup")
        assertEquals(listOf("Warmup", "Warmup Jam"), res.map { it.title })
        assertTrue(res[0].browsable)
        assertEquals(AutoId.Solo("1").encoded, res[1].id)
    }

    @Test fun search_blankOrNotReady_isEmpty() {
        assertTrue(tree(libraryData()).search("  ").isEmpty())
        assertTrue(tree(libraryData().apply { catalogReady = false }).search("alpha").isEmpty())
    }
}
