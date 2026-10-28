package com.levi.pocketdj.screens.playlists

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionSortDoc
import com.levi.pocketdj.data.collections.CollectionSortSettings
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.FilterOp
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionSortFilterTest {

    private fun song(id: String, bpm: Double? = null, added: Double? = null, name: String = id) =
        IndexSong(id = id, artist = "Art", name = name, bpm = bpm, dateAdded = added)

    private fun catalog(vararg songs: IndexSong) = MergedCatalog(
        albums = emptyList(),
        songs = songs.toList(),
        playlists = emptyList(),
        albumsById = emptyMap(),
        songsById = songs.associateBy { it.id },
        sourceOfAlbum = emptyMap(),
        sourceOfSong = songs.associate { it.id to "S" },
        availableSources = listOf("S"),
    )

    private val cat = catalog(
        song("a", bpm = 120.0, added = 300.0),
        song("b", bpm = 90.0, added = 100.0),
        song("c", bpm = 150.0),
        song("d", bpm = 100.0, added = 200.0),
    )
    private val stored = listOf("a", "b", "c", "d")

    private fun sortBy(field: SortField, asc: Boolean = true) =
        CollectionBrowseInputs(sortKeys = listOf(SortKey(field, asc)))

    @Test
    fun defaultOrderPreservesStored() {
        val inputs = CollectionBrowseInputs()
        assertTrue(inputs.isDefaultOrder)
        assertEquals(stored, CollectionSortFilter.resolveSongIds(stored, cat, inputs))
        // The stored list itself is never touched by a sorted resolve.
        val copy = stored.toList()
        assertEquals(listOf("b", "d", "a", "c"), CollectionSortFilter.resolveSongIds(stored, cat, sortBy(SortField.BPM)))
        assertEquals(copy, stored)
        // An incomplete clause is a no-op, so it is still the default order.
        val incomplete = CollectionBrowseInputs(clauses = listOf(Clause("bpm", FilterOp.BETWEEN)))
        assertTrue(incomplete.isDefaultOrder)
        assertFalse(sortBy(SortField.BPM).isDefaultOrder)
    }

    @Test
    fun dateAddedNullsLast() {
        assertEquals(
            listOf("b", "d", "a", "c"),
            CollectionSortFilter.resolveSongIds(stored, cat, sortBy(SortField.DATE_ADDED, asc = true)),
        )
        // Nulls stay last even when descending.
        assertEquals(
            listOf("a", "d", "b", "c"),
            CollectionSortFilter.resolveSongIds(stored, cat, sortBy(SortField.DATE_ADDED, asc = false)),
        )
        assertTrue(SortField.DATE_ADDED in SortField.forKind(com.levi.pocketdj.screens.browse.BrowseKind.SONGS, includeDateAdded = true))
        // Browse/History sort sheets keep it hidden.
        assertFalse(SortField.DATE_ADDED in SortField.forKind(com.levi.pocketdj.screens.browse.BrowseKind.SONGS))
    }

    private fun songNode(nodeId: String, songId: String) =
        PlaylistNode(nodeId = nodeId, kind = PlaylistNode.Kind.SONG, songId = songId)

    @Test
    fun playlistNonSongNodesLast() {
        val children = listOf(
            PlaylistNode(nodeId = "t1", kind = PlaylistNode.Kind.TEXT, text = "note"),
            songNode("n-a", "a"),
            PlaylistNode(nodeId = "al", kind = PlaylistNode.Kind.ALBUM, albumId = "alb"),
            songNode("n-b", "b"),
            songNode("n-a2", "a"), // duplicate song consumes its own slot
            songNode("n-studio", "studio:x"),
        )
        val sorted = CollectionSortFilter.resolveChapterChildren(
            children, cat, sortBy(SortField.BPM), isStudio = { it.startsWith("studio:") },
        ).map { it.nodeId }
        // b(90), a(120), a(120) in BPM order, then every non-song node in stored relative order.
        assertEquals(listOf("n-b", "n-a", "n-a2", "t1", "al", "n-studio"), sorted)

        // Default order returns the stored children untouched.
        assertEquals(children, CollectionSortFilter.resolveChapterChildren(children, cat, CollectionBrowseInputs()))

        // An active FILTER hides the non-song tail (they carry no song fields).
        val filtered = CollectionBrowseInputs(
            clauses = listOf(Clause("bpm", FilterOp.BETWEEN, min = 100.0, max = 130.0)),
        )
        val kept = CollectionSortFilter.resolveChapterChildren(
            children, cat, filtered, isStudio = { it.startsWith("studio:") },
        ).map { it.nodeId }
        assertEquals(listOf("n-a", "n-a2"), kept)
    }

    @Test
    fun pocketStudioItemsPinnedLastAndHiddenByFilter() {
        val ids = listOf("studio:1", "a", "b")
        val isStudio = { id: String -> id.startsWith("studio:") }
        assertEquals(
            listOf("b", "a", "studio:1"),
            CollectionSortFilter.resolvePocketSongs(ids, cat, sortBy(SortField.BPM), isStudio = isStudio),
        )
        val filtered = CollectionBrowseInputs(clauses = listOf(Clause("bpm", FilterOp.BETWEEN, min = 100.0, max = 130.0)))
        assertEquals(listOf("a"), CollectionSortFilter.resolvePocketSongs(ids, cat, filtered, isStudio = isStudio))
    }

    @Test
    fun persistenceKeyPerCollection() {
        assertEquals("pdj.collection.p1", CollectionSortSettings.key("p1"))
        val bpmDoc = CollectionBrowseInputs(
            clauses = listOf(Clause("bpm", FilterOp.BETWEEN, min = 100.0, max = 130.0)),
            sortKeys = listOf(SortKey(SortField.BPM, ascending = false)),
        ).toDoc()
        var raw = CollectionSortSettings.withEntry("", "p1", bpmDoc)
        raw = CollectionSortSettings.withEntry(raw, "p2", CollectionBrowseInputs(sortKeys = listOf(SortKey(SortField.NAME))).toDoc())

        val map = CollectionSortSettings.decode(raw)
        assertEquals(setOf("pdj.collection.p1", "pdj.collection.p2"), map.keys)
        val back = CollectionBrowseInputs.fromDoc(CollectionSortSettings.docFor(raw, "p1"))
        assertEquals(listOf(SortKey(SortField.BPM, false)), back.sortKeys)
        assertEquals(1, back.activeFilterCount)
        assertEquals(listOf(SortKey(SortField.NAME, true)), CollectionBrowseInputs.fromDoc(CollectionSortSettings.docFor(raw, "p2")).sortKeys)
        // Independent: an unknown collection has the default, p2's sort never leaks into it.
        assertTrue(CollectionBrowseInputs.fromDoc(CollectionSortSettings.docFor(raw, "p3")).isDefaultOrder)

        // Resetting to default order drops ONLY that collection's entry.
        val cleared = CollectionSortSettings.withEntry(raw, "p1", CollectionSortDoc())
        assertEquals(setOf("pdj.collection.p2"), CollectionSortSettings.decode(cleared).keys)
        assertNotEquals(raw, cleared)
    }

    @Test
    fun corruptOrUnknownDocsDecodeToDefaults() {
        assertTrue(CollectionSortSettings.decode("{not json").isEmpty())
        assertTrue(CollectionSortSettings.decode(null).isEmpty())
        // Unknown sort field / filter field ids are dropped, never crash; extra keys ignored.
        val raw = """{"pdj.collection.x":{"sortKeys":[{"field":"futureField"},{"field":"bpm","ascending":false}],
            "clauses":[{"field":"nope","op":"eq","value":"1"}],"extra":1}}"""
        val inputs = CollectionBrowseInputs.fromDoc(CollectionSortSettings.docFor(raw, "x"))
        assertEquals(listOf(SortKey(SortField.BPM, false)), inputs.sortKeys)
        assertTrue(inputs.clauses.isEmpty())
    }

    private val bpmFilter = CollectionBrowseInputs(
        clauses = listOf(Clause("bpm", FilterOp.BETWEEN, min = 100.0, max = 130.0)),
    )

    @Test
    fun selectionActsOnDisplayedRowsNotStored() {
        // Stored a,b,c,d; filter keeps a,d only.
        val resolved = CollectionSortFilter.resolveSongIds(stored, cat, bpmFilter)
        assertEquals(listOf("a", "d"), resolved)
        // Active filter: select-all universe is the 2 visible rows, in resolved order.
        assertEquals(listOf("a", "d"), CollectionSortFilter.selectableSongIds(stored, resolved, false, cat))
        // Sorted by BPM: display order drives the payload order.
        val sorted = CollectionSortFilter.resolveSongIds(stored, cat, sortBy(SortField.BPM))
        assertEquals(sorted, CollectionSortFilter.selectableSongIds(stored, sorted, false, cat))
        // Resolve not landed yet: nothing selectable (never the hidden stored list).
        assertEquals(emptyList<String>(), CollectionSortFilter.selectableSongIds(stored, null, false, cat))
        // Default order: stored.
        assertEquals(stored, CollectionSortFilter.selectableSongIds(stored, null, true, cat))
    }

    @Test
    fun playlistSelectionActsOnResolvedChapterNodes() {
        val ch = PlaylistNode(
            nodeId = "ch", kind = PlaylistNode.Kind.SEQUENCE,
            children = listOf(songNode("n-a", "a"), songNode("n-b", "b"), songNode("n-d", "d")),
        )
        val resolved = mapOf("ch" to CollectionSortFilter.resolveChapterChildren(ch.children!!, cat, bpmFilter))
        assertEquals(
            listOf("n-a", "n-d"),
            CollectionSortFilter.selectableSongNodes(listOf(ch), resolved, false, cat).map { it.nodeId },
        )
        assertEquals(
            listOf("n-a", "n-b", "n-d"),
            CollectionSortFilter.selectableSongNodes(listOf(ch), null, true, cat).map { it.nodeId },
        )
    }

    @Test
    fun favoriteAndMembershipFiltersApply() {
        val fav = CollectionBrowseInputs(favorite = com.levi.pocketdj.data.favorites.FavoriteFilter.FAVORITE)
        val rt = CollectionReadTime(favoriteIds = setOf("b", "c"))
        assertFalse(fav.isDefaultOrder)
        assertEquals(listOf("b", "c"), CollectionSortFilter.resolveSongIds(stored, cat, fav, readTime = rt))
        val mem = CollectionBrowseInputs(
            membership = com.levi.pocketdj.screens.browse.MembershipFilter(excludeIds = setOf("pkt_1")),
        )
        val rt2 = CollectionReadTime(members = mapOf("pkt_1" to setOf("a")))
        assertEquals(listOf("b", "c", "d"), CollectionSortFilter.resolveSongIds(stored, cat, mem, readTime = rt2))
        // Transient: never persisted.
        assertTrue(fav.toDoc().isEmpty)
    }

    @Test
    fun hydrateDoesNotOverwriteEarlyEditAndCorruptBlobIsKept() {
        val st = CollectionSortState("p1")
        st.setSortKeys(listOf(SortKey(SortField.NAME)))
        st.restore(CollectionBrowseInputs(sortKeys = listOf(SortKey(SortField.BPM))).toDoc())
        assertEquals(listOf(SortKey(SortField.NAME)), st.inputs.sortKeys)
        assertTrue(st.loaded)
        val fresh = CollectionSortState("p2")
        fresh.restore(CollectionBrowseInputs(sortKeys = listOf(SortKey(SortField.BPM))).toDoc())
        assertEquals(listOf(SortKey(SortField.BPM)), fresh.inputs.sortKeys)

        val corrupt = "{not json"
        assertEquals(corrupt, CollectionSortSettings.withEntry(corrupt, "p1", CollectionBrowseInputs(sortKeys = listOf(SortKey(SortField.BPM))).toDoc()))
    }
}
