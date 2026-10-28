package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RecentlyAddedTest {
    private fun song(id: String, at: Double? = null) =
        IndexSong(id = id, artist = "a", name = id, dateAdded = at)

    private fun catalog(vararg songs: IndexSong) = MergedCatalog.EMPTY.copy(
        songs = songs.toList(),
        songsById = songs.associateBy { it.id },
    )

    private fun add(id: String, at: Double) =
        ActivityEvent(id = "e-$id-$at", at = at, kind = ActivityKind.CATALOG_ADD, itemId = id)

    @Test
    fun excludesUndated() {
        val c = catalog(song("a", 10.0), song("b"), song("c", 0.0))
        val b = RecentlyAddedBuilder()
        assertEquals(listOf("a"), b.songIds(c, emptyList(), 100))
    }

    @Test
    fun newestFirstStable() {
        val c = catalog(song("a", 5.0), song("b", 9.0), song("c", 5.0), song("d", 7.0))
        // ties (a, c at 5.0) break on id descending
        assertEquals(listOf("b", "d", "c", "a"), RecentlyAddedBuilder().songIds(c, emptyList(), 10))
        // limit trims the oldest
        assertEquals(listOf("b", "d"), RecentlyAddedBuilder().songIds(c, emptyList(), 2))
    }

    @Test
    fun largeInputMatchesFullSort() {
        val songs = (0 until 500).map { song("s$it", (it % 37).toDouble() + 1) }
        val c = catalog(*songs.toTypedArray())
        val expected = songs.sortedWith(compareByDescending<IndexSong> { it.dateAdded }.thenByDescending { it.id })
            .take(40).map { it.id }
        assertEquals(expected, RecentlyAddedBuilder().songIds(c, emptyList(), 40))
    }

    @Test
    fun memoHitNoRecompute() {
        val c = catalog(song("a", 1.0), song("b", 2.0))
        val b = RecentlyAddedBuilder()
        val first = b.songIds(c, emptyList(), 10)
        val second = b.songIds(c, emptyList(), 10)
        assertSame(first, second)
        assertEquals(1, b.computeCount)
        b.songIds(c, emptyList(), 5)
        assertEquals(2, b.computeCount)
        b.songIds(c.copy(), emptyList(), 5) // new snapshot = new revision
        assertEquals(3, b.computeCount)
    }

    @Test
    fun limitClamp() {
        val c = catalog(song("a", 1.0), song("b", 2.0))
        val b = RecentlyAddedBuilder()
        // 0 / negative clamp up to 1; huge clamps down (still returns everything)
        assertEquals(listOf("b"), b.songIds(c, emptyList(), 0))
        assertEquals(listOf("b"), b.songIds(c, emptyList(), -5))
        assertEquals(listOf("b", "a"), b.songIds(c, emptyList(), 10_000_000))
    }

    @Test
    fun unionWithCatalogAddEvents() {
        val c = catalog(song("a", 100.0), song("b", 50.0), song("x"))
        val events = listOf(
            add("x", 200.0), // in-app add of an undated song
            add("b", 300.0), // newer in-app add wins over catalog date
            add("gone", 999.0), // not in catalog: dropped
            ActivityEvent(id = "h", at = 1000.0, kind = ActivityKind.HEART, itemId = "a"), // not an add
        )
        assertEquals(listOf("b", "x", "a"), RecentlyAddedBuilder().songIds(c, events, 10))
        // a new event invalidates the memo
        val b = RecentlyAddedBuilder()
        b.songIds(c, events, 10)
        b.songIds(c, events + add("a", 400.0), 10)
        assertEquals(2, b.computeCount)
    }

    @Test
    fun hasItemsGateDoesNotBuild() {
        val b = RecentlyAddedBuilder()
        assertFalse(b.hasItems(catalog(song("a")), emptyList(), 10))
        assertTrue(b.hasItems(catalog(song("a", 3.0)), emptyList(), 10))
        assertTrue(b.hasItems(catalog(song("a")), listOf(add("a", 5.0)), 10))
        assertFalse(b.hasItems(catalog(song("a")), listOf(add("zzz", 5.0)), 10))
        assertEquals(0, b.computeCount)
    }

    @Test
    fun playlistShapeAndEmpty() {
        val b = RecentlyAddedBuilder()
        assertNull(b.playlist(catalog(song("a")), emptyList(), 10))
        val sp = b.playlist(catalog(song("a", 1.0)), emptyList(), 10)!!
        assertEquals("__pdj_recently_added__", sp.playlist.id)
        assertEquals("Recently added", sp.sourceName)
        assertEquals(listOf("a"), sp.playlist.songIds)
    }

    private fun remove(id: String, at: Double) =
        ActivityEvent(id = "r-$id-$at", at = at, kind = ActivityKind.CATALOG_REMOVE, itemId = id)

    @Test
    fun newerRemoveCancelsAdd() {
        val c = catalog(song("a"), song("b", 1.0))
        val b = RecentlyAddedBuilder()
        assertEquals(listOf("a", "b"), b.songIds(c, listOf(add("a", 50.0)), 10))
        assertEquals(listOf("b"), b.songIds(c, listOf(add("a", 50.0), remove("a", 60.0)), 10))
        // a re-add after the remove brings it back
        assertEquals(listOf("a", "b"), b.songIds(c, listOf(add("a", 50.0), remove("a", 60.0), add("a", 70.0)), 10))
    }

    @Test
    fun ownLibraryScopeFiltersCatalogDates() {
        val c = catalog(song("mine", 5.0), song("curator", 9.0))
        val own = { s: com.levi.pocketdj.data.catalog.IndexSong -> s.id == "mine" }
        val b = RecentlyAddedBuilder()
        assertEquals(listOf("curator", "mine"), b.songIds(c, emptyList(), 10))
        assertEquals(listOf("mine"), b.songIds(c, emptyList(), 10, filterToOwnLibrary = true, isOwnLibrary = own))
        assertTrue(b.hasItems(c, emptyList(), 10, filterToOwnLibrary = true, isOwnLibrary = own))
        assertFalse(RecentlyAddedBuilder().hasItems(c, emptyList(), 10, filterToOwnLibrary = true, isOwnLibrary = { false }))
    }

    @Test
    fun memoDoesNotPinOldCatalog() {
        var c: MergedCatalog? = catalog(song("a", 1.0))
        val b = RecentlyAddedBuilder()
        b.songIds(c!!, emptyList(), 10)
        val ref = java.lang.ref.WeakReference(c)
        c = null
        repeat(20) { System.gc(); if (ref.get() == null) return@repeat }
        assertNull(ref.get())
    }
}
