package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowseEngineTest {

    // ---- Genre (ported table, specs/browse.md §5) --------------------------

    @Test
    fun genreCollapsesByFirstKeywordHit() {
        assertEquals("hip-hop", Genre.category("Hip-Hop/Rap"))
        assertEquals("hip-hop", Genre.category("East Coast Rap"))
        assertEquals("jazz", Genre.category("Cool Jazz"))
        assertEquals("r&b", Genre.category("Contemporary R&B"))
        assertEquals("electronic", Genre.category("Deep House"))
        assertEquals("Other", Genre.category(null))
        assertEquals("Other", Genre.category("   "))
        assertEquals("Other", Genre.category("Unclassifiable"))
    }

    @Test
    fun genrePriorityOrderIsStable() {
        // "hip hop soul" carries both hip-hop and soul keywords; hip-hop is
        // earlier in priority order and must win.
        assertEquals("hip-hop", Genre.category("Hip Hop Soul"))
        assertEquals(0, Genre.order("hip-hop"))
        assertEquals(Genre.categoryNames.size - 1, Genre.order("Other"))
    }

    // ---- Camelot (specs/browse.md §5) --------------------------------------

    @Test
    fun camelotParsesAndRanksWheelOrder() {
        assertEquals(2, Camelot.rank("1A"))
        assertEquals(3, Camelot.rank("1B"))
        assertEquals(25, Camelot.rank("12b"))
        assertNull(Camelot.rank("13A"))
        assertNull(Camelot.rank("A"))
        assertNull(Camelot.rank(null))
    }

    // ---- Search fold (specs/browse.md §4.1) --------------------------------

    @Test
    fun foldIsCaseAndDiacriticInsensitive() {
        assertEquals("beyonce", Fmt.fold("Beyoncé"))
        assertEquals("outkast", Fmt.fold("OutKast"))
    }

    // ---- Format ------------------------------------------------------------

    @Test
    fun durationAndBpmDisplayRules() {
        assertEquals("3:05", Fmt.duration(185_000))
        assertEquals("–", Fmt.duration(null))
        assertEquals("–", Fmt.duration(0))
        assertEquals("120", Fmt.bpm(120.4))
        assertEquals("–", Fmt.bpm(null))
    }

    // ---- Filters (specs/browse.md §6.2 semantics) --------------------------

    private fun catalog(): MergedCatalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "My Vinyl"),
                albums = listOf(
                    IndexAlbum(
                        id = "alb_1", artist = "A", name = "Rap Album",
                        genre = "Hip-Hop", trackList = listOf("sng_1", "sng_2"),
                    ),
                ),
                songs = listOf(
                    IndexSong(id = "sng_1", albumId = "alb_1", artist = "A", name = "Fast", bpm = 140.0, camelot = "8A"),
                    IndexSong(id = "sng_2", albumId = "alb_1", artist = "A", name = "NoBpm", bpm = null),
                ),
            ),
            IndexJson(
                manifest = IndexManifest(sourceName = "My Digital"),
                albums = listOf(
                    IndexAlbum(id = "alb_2", artist = "B", name = "Jazz Album", genre = "Jazz", trackList = listOf("sng_3")),
                ),
                songs = listOf(
                    IndexSong(id = "sng_3", albumId = "alb_2", artist = "B", name = "Smooth", bpm = 90.0, camelot = "3B"),
                ),
            ),
        ),
    )

    @Test
    fun bpmBetweenHidesMissingValuesAndIsInclusive() {
        val rows = BrowseRows(catalog())
        val hits = rows.filteredSongs("", BrowseFilters().withBpm(140.0, 150.0))
        assertEquals(listOf("sng_1"), hits.map { it.song.id })
        // Open-ended min only.
        val minOnly = rows.filteredSongs("", BrowseFilters().withBpm(100.0, null))
        assertEquals(listOf("sng_1"), minOnly.map { it.song.id })
    }

    @Test
    fun genreFilterAppliesCollapsedCategoryToBothKinds() {
        val rows = BrowseRows(catalog())
        val filters = BrowseFilters().withGenres(setOf("hip-hop"))
        assertEquals(listOf("alb_1"), rows.filteredAlbums("", filters).map { it.album.id })
        assertEquals(
            listOf("sng_1", "sng_2"),
            rows.filteredSongs("", filters).map { it.song.id },
        )
    }

    @Test
    fun sourceFilterUsesFirstCarryingSource() {
        val rows = BrowseRows(catalog())
        val filters = BrowseFilters().withSources(setOf("My Digital"))
        assertEquals(listOf("alb_2"), rows.filteredAlbums("", filters).map { it.album.id })
        assertEquals(listOf("sng_3"), rows.filteredSongs("", filters).map { it.song.id })
    }

    @Test
    fun camelotFilterNormalizesCase() {
        val rows = BrowseRows(catalog())
        val hits = rows.filteredSongs("", BrowseFilters().withCamelots(setOf("8A")))
        assertEquals(listOf("sng_1"), hits.map { it.song.id })
    }

    @Test
    fun bpmClausePassesAlbumRows() {
        // A clause whose field doesn't apply to the row's kind passes the row.
        val rows = BrowseRows(catalog())
        val albums = rows.filteredAlbums("", BrowseFilters().withBpm(100.0, null))
        assertEquals(2, albums.size)
    }

    @Test
    fun searchMatchesFoldedSubstringsAcrossFields() {
        val rows = BrowseRows(catalog())
        assertEquals(
            listOf("alb_2"),
            rows.filteredAlbums("jAzz alb", BrowseFilters()).map { it.album.id },
        )
        // Newlines are stripped from the query so it can't span field boundaries.
        assertTrue(rows.filteredSongs("fast\nsmooth", BrowseFilters()).isEmpty())
    }

    @Test
    fun optionListsAreOrderedAndDistinct() {
        val rows = BrowseRows(catalog())
        assertEquals(listOf("hip-hop", "jazz"), rows.genreOptions)
        assertEquals(listOf("3B", "8A"), rows.camelotOptions) // wheel-rank order
    }

    // ---- BRW-1: BrowseEngine.filterSort + resultsKey ------------------------

    private fun song(id: String, name: String, artist: String = "Art", bpm: Double? = null) = SongRow(
        song = IndexSong(id = id, artist = artist, name = name, bpm = bpm),
        albumName = null, source = "S", genreCategory = "Other",
        searchKey = Fmt.fold("$name\n$artist"),
    )

    @Test
    fun filterSort_stripsNewlinesFromQuery() {
        val rows = listOf(song("1", "Fast"), song("2", "Slow"))
        val keys = rows.map { it.searchKey }
        // "fa\nst" collapses to "fast" and matches; a query spanning the field
        // boundary ("fast\nart") must NOT match across name\nartist.
        assertEquals(listOf("1"), BrowseEngine.filterSort(rows, keys, "fa\nst", emptyList(), emptyList()).map { it.song.id })
        assertTrue(BrowseEngine.filterSort(rows, keys, "fast\nart", emptyList(), emptyList()).isEmpty())
    }

    @Test
    fun filterSort_mismatchedSearchKeys_honoursQueryOnRowFields() {
        val rows = listOf(song("1", "Fast"), song("2", "Béyoncé Slow"))
        val reports = mutableListOf<String>()
        val old = BrowseEngine.mismatchReporter
        BrowseEngine.mismatchReporter = { reports += it }
        val before = BrowseEngine.mismatchCount.get()
        try {
            val hits = BrowseEngine.filterSort(rows, emptyList(), "beyonce", emptyList(), emptyList())
            assertEquals(listOf("2"), hits.map { it.song.id }) // NOT the whole base
            assertEquals(1, reports.size)
            assertEquals(before + 1, BrowseEngine.mismatchCount.get())
            // Artist is matched too.
            assertEquals(2, BrowseEngine.filterSort(rows, emptyList(), "art", emptyList(), emptyList()).size)
        } finally {
            BrowseEngine.mismatchReporter = old
        }
    }

    @Test
    fun filterSort_appliesQueryThenClausesThenSort() {
        val rows = listOf(song("a", "Alpha", bpm = 100.0), song("b", "Beta", bpm = 140.0), song("c", "Gamma", bpm = 120.0))
        val out = BrowseEngine.filterSort(
            rows, rows.map { it.searchKey }, "a", // matches all three ("art" artist too -> all)
            listOf(Clause("bpm", FilterOp.BETWEEN, min = 110.0)),
            listOf(SortKey(SortField.BPM, ascending = false)),
        )
        assertEquals(listOf("b", "c"), out.map { it.song.id })
    }

    private fun key(
        clauses: List<Clause> = emptyList(),
        sort: List<SortKey> = emptyList(),
        q: String = "",
        rev: Int = 0,
        cat: Long = 7,
    ) = BrowseEngine.resultsKey(cat, BrowseKind.SONGS, q, clauses, sort, rev)

    @Test
    fun resultsKey_isDeterministic_andIgnoresClauseIds() {
        val a = Clause("genre", FilterOp.IN_LIST, values = setOf("jazz", "rock"))
        val b = Clause("genre", FilterOp.IN_LIST, values = setOf("rock", "jazz"))
        assertEquals(key(listOf(a)), key(listOf(a)))
        assertEquals(key(listOf(a)), key(listOf(b))) // different UUIDs + set order
    }

    @Test
    fun resultsKey_ignoresIncompleteClauses() {
        val incomplete = Clause("genre", FilterOp.IN_LIST)
        assertEquals(key(), key(listOf(incomplete)))
    }

    @Test
    fun resultsKey_commaAndPipeInValuesDoNotCollide() {
        val one = Clause("name", FilterOp.IN_LIST, values = setOf("a,b"))
        val two = Clause("name", FilterOp.IN_LIST, values = setOf("a", "b"))
        val pipe1 = Clause("name", FilterOp.EQ, value = "a|b")
        val pipe2 = Clause("name", FilterOp.IN_LIST, values = setOf("a|b"))
        assertTrue(key(listOf(one)) != key(listOf(two)))
        assertTrue(key(listOf(pipe1)) != key(listOf(pipe2)))
        assertTrue(key(q = "a,b") != key(q = "a|b"))
    }

    @Test
    fun resultsKey_playCountRevisionOnlyWhenUsed() {
        // Unused: revision bumps must NOT move the key.
        assertEquals(key(rev = 1), key(rev = 99))
        // Used by a sort key or a complete playCount clause: it must.
        val sort = listOf(SortKey(SortField.PLAY_COUNT, ascending = false))
        assertTrue(key(sort = sort, rev = 1) != key(sort = sort, rev = 2))
        val clause = listOf(Clause("playCount", FilterOp.BETWEEN, min = 1.0))
        assertTrue(key(clause, rev = 1) != key(clause, rev = 2))
        // An INCOMPLETE playCount clause is a no-op and must not fold the revision in.
        val incomplete = listOf(Clause("playCount", FilterOp.BETWEEN))
        assertEquals(key(incomplete, rev = 1), key(incomplete, rev = 2))
    }

    @Test
    fun resultsKey_movesWithCatalogSortAndKind() {
        assertTrue(key(cat = 1) != key(cat = 2))
        assertTrue(key(sort = listOf(SortKey(SortField.BPM, true))) != key(sort = listOf(SortKey(SortField.BPM, false))))
        assertTrue(key() != BrowseEngine.resultsKey(7, BrowseKind.ALBUMS, "", emptyList(), emptyList(), 0))
    }

    @Test
    fun filters_usesPlayCountsAndActiveCount() {
        val f = BrowseFilters(listOf(Clause("playCount", FilterOp.BETWEEN, min = 1.0), Clause("genre", FilterOp.IN_LIST)))
        assertEquals(1, f.activeCount) // the incomplete genre clause isn't counted
        assertTrue(f.usesPlayCounts(emptyList()))
        assertEquals(false, BrowseFilters().usesPlayCounts(listOf(SortKey(SortField.BPM))))
        assertTrue(BrowseFilters().usesPlayCounts(listOf(SortKey(SortField.PLAY_COUNT))))
    }

    @Test
    fun fieldsRegistry_orderMatchesIos() {
        assertEquals(
            listOf(
                "artist", "albumCount", "songCount", "name", "year", "playCount", "genre", "fileType",
                "source", "country", "trackCount", "trackNumber", "length", "bpm", "key", "camelot",
                "explicit", "sentiment", "dateAdded", "lastPlayedAt",
            ),
            Fields.all.map { it.id },
        )
        assertEquals(20, Fields.all.size)
        assertEquals(listOf(FilterOp.BETWEEN), Fields.byId.getValue("playCount").ops)
        assertTrue(Fields.byId.getValue("lastPlayedAt").historyOnly)
        assertEquals(false, Fields.byId.getValue("sentiment").sortable)
    }
}
