package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The multi-key browse sort engine (specs/browse.md §6.4): stable, nulls-last
 * regardless of direction, numeric BPM (not lexicographic), camelot by wheel
 * rank, genre alphabetical, bool false < true.
 */
class SortEngineTest {

    private fun song(
        id: String,
        name: String = "x",
        artist: String = "A",
        bpm: Double? = null,
        camelot: String? = null,
        year: Int? = null,
        explicit: Boolean? = null,
        key: String? = null,
        genre: String = "Other",
        source: String? = "S",
    ): SongRow = SongRow(
        song = IndexSong(
            id = id, artist = artist, name = name, bpm = bpm, camelot = camelot,
            year = year, explicit = explicit, key = key,
        ),
        albumName = null,
        source = source,
        genreCategory = genre,
        searchKey = "",
    )

    private fun album(
        id: String,
        name: String = "x",
        artist: String = "A",
        year: Int? = null,
        trackList: List<String> = emptyList(),
        genre: String = "Other",
    ): AlbumRow = AlbumRow(
        album = IndexAlbum(id = id, artist = artist, name = name, year = year, trackList = trackList),
        source = "S",
        genreCategory = genre,
        searchKey = "",
    )

    @JvmName("songIds")
    private fun List<SongRow>.ids() = map { it.song.id }

    @JvmName("albumIds")
    private fun List<AlbumRow>.ids() = map { it.album.id }

    @Test
    fun noKeys_returnsInputOrderUnchanged() {
        val rows = listOf(song("c"), song("a"), song("b"))
        assertEquals(listOf("c", "a", "b"), BrowseSort.songs(rows, emptyList()).ids())
    }

    @Test
    fun bpm_ascending_isNumericNotLexicographic() {
        // Lexicographically "100" < "25" < "9"; numerically 9 < 25 < 100.
        val rows = listOf(song("s9", bpm = 9.0), song("s100", bpm = 100.0), song("s25", bpm = 25.0))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.BPM, ascending = true)))
        assertEquals(listOf("s9", "s25", "s100"), sorted.ids())
    }

    @Test
    fun bpm_descending_reversesNumericOrder() {
        val rows = listOf(song("s9", bpm = 9.0), song("s100", bpm = 100.0), song("s25", bpm = 25.0))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.BPM, ascending = false)))
        assertEquals(listOf("s100", "s25", "s9"), sorted.ids())
    }

    @Test
    fun missingValues_sortLast_regardlessOfDirection() {
        val rows = listOf(song("null1", bpm = null), song("b100", bpm = 100.0), song("b25", bpm = 25.0))
        val asc = BrowseSort.songs(rows, listOf(SortKey(SortField.BPM, ascending = true)))
        assertEquals(listOf("b25", "b100", "null1"), asc.ids())
        val desc = BrowseSort.songs(rows, listOf(SortKey(SortField.BPM, ascending = false)))
        assertEquals(listOf("b100", "b25", "null1"), desc.ids()) // null still LAST
    }

    @Test
    fun camelot_sortsByWheelRankNotString() {
        // String sort → "12A","1A","2B"; wheel rank (2,5,24) → 1A,2B,12A.
        val rows = listOf(song("s12a", camelot = "12A"), song("s2b", camelot = "2B"), song("s1a", camelot = "1A"))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.CAMELOT, ascending = true)))
        assertEquals(listOf("s1a", "s2b", "s12a"), sorted.ids())
    }

    @Test
    fun camelot_unparseable_sortsLast() {
        val rows = listOf(song("bad", camelot = "ZZ"), song("s1a", camelot = "1A"))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.CAMELOT, ascending = true)))
        assertEquals(listOf("s1a", "bad"), sorted.ids())
    }

    @Test
    fun multiKey_primaryThenSecondaryWithMixedDirections() {
        // Artist asc, then BPM desc within an artist.
        val rows = listOf(
            song("b-slow", artist = "B", bpm = 80.0),
            song("a-fast", artist = "A", bpm = 140.0),
            song("a-slow", artist = "A", bpm = 90.0),
            song("b-fast", artist = "B", bpm = 120.0),
        )
        val keys = listOf(
            SortKey(SortField.ARTIST, ascending = true),
            SortKey(SortField.BPM, ascending = false),
        )
        assertEquals(listOf("a-fast", "a-slow", "b-fast", "b-slow"), BrowseSort.songs(rows, keys).ids())
    }

    @Test
    fun stableTiebreak_preservesInputOrderWhenAllKeysTie() {
        val rows = listOf(song("first", artist = "A"), song("second", artist = "A"), song("third", artist = "A"))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.ARTIST, ascending = true)))
        assertEquals(listOf("first", "second", "third"), sorted.ids())
    }

    @Test
    fun explicit_falseBeforeTrue_missingReadsAsFalse() {
        val rows = listOf(song("e1", explicit = true), song("clean", explicit = false), song("unknown", explicit = null))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.EXPLICIT, ascending = true)))
        // false and missing (=false) tie → input order among them, then true last.
        assertEquals(listOf("clean", "unknown", "e1"), sorted.ids())
    }

    @Test
    fun genre_sortsAlphabeticallyCaseInsensitive() {
        val rows = listOf(song("r", genre = "rock"), song("b", genre = "blues"), song("j", genre = "jazz"))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.GENRE, ascending = true)))
        assertEquals(listOf("b", "j", "r"), sorted.ids())
    }

    @Test
    fun stringName_comparesCaseInsensitively() {
        val rows = listOf(song("z", name = "Zoo"), song("a", name = "apple"), song("m", name = "Mango"))
        val sorted = BrowseSort.songs(rows, listOf(SortKey(SortField.NAME, ascending = true)))
        assertEquals(listOf("a", "m", "z"), sorted.ids())
    }

    @Test
    fun albums_multiKey_yearThenName_missingYearLast() {
        val rows = listOf(
            album("a1", name = "Beta", year = 1999),
            album("a2", name = "Alpha", year = 1999),
            album("a3", name = "Older", year = 1980),
            album("a4", name = "NoYear", year = null),
        )
        val keys = listOf(
            SortKey(SortField.YEAR, ascending = true),
            SortKey(SortField.NAME, ascending = true),
        )
        assertEquals(listOf("a3", "a2", "a1", "a4"), BrowseSort.albums(rows, keys).ids())
    }

    @Test
    fun albums_trackCount_sortsNumerically() {
        val rows = listOf(
            album("many", trackList = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12")),
            album("few", trackList = listOf("1", "2")),
        )
        val sorted = BrowseSort.albums(rows, listOf(SortKey(SortField.TRACK_COUNT, ascending = true)))
        assertEquals(listOf("few", "many"), sorted.ids())
    }

    @Test
    fun forKind_exposesRegistrySubset() {
        val albumFields = SortField.forKind(BrowseKind.ALBUMS).map { it.id }
        val songFields = SortField.forKind(BrowseKind.SONGS).map { it.id }
        // Album-only + shared, no song-only (bpm/camelot); registry order preserved.
        assertEquals(
            listOf("artist", "name", "year", "genre", "fileType", "source", "country", "trackCount"),
            albumFields,
        )
        assertEquals(
            listOf(
                "artist", "name", "year", "genre", "fileType", "source",
                "trackNumber", "length", "bpm", "key", "camelot", "explicit",
            ),
            songFields,
        )
    }
}
