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
        val hits = rows.filteredSongs("", BrowseFilters(bpmMin = 140.0, bpmMax = 150.0))
        assertEquals(listOf("sng_1"), hits.map { it.song.id })
        // Open-ended min only.
        val minOnly = rows.filteredSongs("", BrowseFilters(bpmMin = 100.0))
        assertEquals(listOf("sng_1"), minOnly.map { it.song.id })
    }

    @Test
    fun genreFilterAppliesCollapsedCategoryToBothKinds() {
        val rows = BrowseRows(catalog())
        val filters = BrowseFilters(genres = setOf("hip-hop"))
        assertEquals(listOf("alb_1"), rows.filteredAlbums("", filters).map { it.album.id })
        assertEquals(
            listOf("sng_1", "sng_2"),
            rows.filteredSongs("", filters).map { it.song.id },
        )
    }

    @Test
    fun sourceFilterUsesFirstCarryingSource() {
        val rows = BrowseRows(catalog())
        val filters = BrowseFilters(sources = setOf("My Digital"))
        assertEquals(listOf("alb_2"), rows.filteredAlbums("", filters).map { it.album.id })
        assertEquals(listOf("sng_3"), rows.filteredSongs("", filters).map { it.song.id })
    }

    @Test
    fun camelotFilterNormalizesCase() {
        val rows = BrowseRows(catalog())
        val hits = rows.filteredSongs("", BrowseFilters(camelots = setOf("8A")))
        assertEquals(listOf("sng_1"), hits.map { it.song.id })
    }

    @Test
    fun bpmClausePassesAlbumRows() {
        // A clause whose field doesn't apply to the row's kind passes the row.
        val rows = BrowseRows(catalog())
        val albums = rows.filteredAlbums("", BrowseFilters(bpmMin = 100.0))
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
}
