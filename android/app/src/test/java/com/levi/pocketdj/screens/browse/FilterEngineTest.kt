package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.artists.Artist
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One test per (field kind x op) plus the hard-won edge semantics (specs/browse.md §6.2). */
class FilterEngineTest {

    private fun song(
        id: String = "s",
        name: String = "Song",
        artist: String = "Artist",
        year: Int? = null,
        bpm: Double? = null,
        key: String? = null,
        camelot: String? = null,
        explicit: Boolean? = null,
        sentiment: List<String>? = null,
        genre: String = "Other",
        source: String? = "Src",
        dateAdded: Double? = null,
        playedAt: Double? = null,
    ) = SongRow(
        song = IndexSong(
            id = id, artist = artist, name = name, year = year, bpm = bpm, key = key,
            camelot = camelot, explicit = explicit, sentimentKeywords = sentiment,
        ),
        albumName = null, source = source, genreCategory = genre, searchKey = "",
        dateAdded = dateAdded, playedAt = playedAt,
    )

    private fun album(year: Int? = null, genre: String = "jazz", country: String? = null, tracks: Int = 0) = AlbumRow(
        album = IndexAlbum(
            id = "a", artist = "Art", name = "Alb", year = year, country = country,
            trackList = List(tracks) { "t$it" },
        ),
        source = "Src", genreCategory = genre, searchKey = "",
    )

    private fun artist(albums: Int, songs: Int) = ArtistRow(Artist("Art", albums, songs, null, "art"))

    private fun m(row: BrowseRow, c: Clause, counts: Map<String, Int> = emptyMap()) =
        FilterEngine.matches(row, c, counts)

    // ---- number ------------------------------------------------------------

    @Test fun number_eq() {
        val c = Clause("year", FilterOp.EQ, value = "1990")
        assertTrue(m(song(year = 1990), c))
        assertFalse(m(song(year = 1991), c))
        assertFalse(m(song(year = null), c))
    }

    @Test fun number_neq_keepsMissing() {
        val c = Clause("year", FilterOp.NEQ, value = "1990")
        assertFalse(m(song(year = 1990), c))
        assertTrue(m(song(year = 1991), c))
        assertTrue(m(song(year = null), c))
    }

    @Test fun number_inList() {
        val c = Clause("year", FilterOp.IN_LIST, values = setOf("1990", "1992"))
        assertTrue(m(song(year = 1992), c))
        assertFalse(m(song(year = 1991), c))
        assertFalse(m(song(year = null), c))
    }

    @Test fun number_notInList_keepsMissing() {
        val c = Clause("year", FilterOp.NOT_IN_LIST, values = setOf("1990"))
        assertFalse(m(song(year = 1990), c))
        assertTrue(m(song(year = 1991), c))
        assertTrue(m(song(year = null), c))
    }

    @Test fun number_between_inclusiveBothEnds() {
        val c = Clause("year", FilterOp.BETWEEN, min = 1988.0, max = 1994.0)
        assertTrue(m(song(year = 1988), c))
        assertTrue(m(song(year = 1994), c))
        assertFalse(m(song(year = 1987), c))
        assertFalse(m(song(year = 1995), c))
    }

    @Test fun number_between_openEnds() {
        assertTrue(m(song(bpm = 500.0), Clause("bpm", FilterOp.BETWEEN, min = 100.0)))
        assertFalse(m(song(bpm = 99.0), Clause("bpm", FilterOp.BETWEEN, min = 100.0)))
        assertTrue(m(song(bpm = 1.0), Clause("bpm", FilterOp.BETWEEN, max = 100.0)))
        assertFalse(m(song(bpm = 101.0), Clause("bpm", FilterOp.BETWEEN, max = 100.0)))
    }

    @Test fun number_between_missingFails() {
        assertFalse(m(song(bpm = null), Clause("bpm", FilterOp.BETWEEN, min = 0.0)))
    }

    @Test fun number_eq_unparseableValueMatchesNothing() {
        assertFalse(m(song(year = 1990), Clause("year", FilterOp.EQ, value = "abc")))
    }

    // ---- string ------------------------------------------------------------

    @Test fun string_eq_trimmedCaseInsensitive() {
        val c = Clause("name", FilterOp.EQ, value = "  FAST ")
        assertTrue(m(song(name = "fast"), c))
        assertFalse(m(song(name = "slow"), c))
    }

    @Test fun string_neq() {
        val c = Clause("name", FilterOp.NEQ, value = "fast")
        assertFalse(m(song(name = "Fast"), c))
        assertTrue(m(song(name = "Slow"), c))
    }

    @Test fun string_inList() {
        val c = Clause("genre", FilterOp.IN_LIST, values = setOf("Jazz", "rock"))
        assertTrue(m(song(genre = "jazz"), c))
        assertFalse(m(song(genre = "pop"), c))
    }

    @Test fun string_notInList_keepsEmpty() {
        val c = Clause("fileType", FilterOp.NOT_IN_LIST, values = setOf("mp3"))
        assertFalse(m(song().copy(song = song().song.copy(fileType = "MP3")), c))
        assertTrue(m(song().copy(song = song().song.copy(fileType = "flac")), c))
        // No value at all (empty) is kept — symmetric with NEQ.
        assertTrue(m(song(), c))
    }

    @Test fun string_source_missingIsEmpty() {
        val c = Clause("source", FilterOp.IN_LIST, values = setOf("Src"))
        assertTrue(m(song(source = "src"), c))
        assertFalse(m(song(source = null), c))
        assertTrue(m(song(source = null), Clause("source", FilterOp.NEQ, value = "Src")))
    }

    // ---- bool --------------------------------------------------------------

    @Test fun bool_eq_trueAndFalseStrings() {
        val yes = Clause("explicit", FilterOp.EQ, value = "true")
        val no = Clause("explicit", FilterOp.EQ, value = "false")
        assertTrue(m(song(explicit = true), yes))
        assertFalse(m(song(explicit = false), yes))
        assertTrue(m(song(explicit = false), no))
    }

    @Test fun bool_explicitMissingReadsFalse() {
        assertFalse(m(song(explicit = null), Clause("explicit", FilterOp.EQ, value = "true")))
        assertTrue(m(song(explicit = null), Clause("explicit", FilterOp.EQ, value = "false")))
    }

    // ---- stringArray (sentiment) --------------------------------------------

    @Test fun sentiment_inList_isAnyOf() {
        val c = Clause("sentiment", FilterOp.IN_LIST, values = setOf("Happy", "dark"))
        assertTrue(m(song(sentiment = listOf("chill", "happy")), c))
        assertFalse(m(song(sentiment = listOf("chill")), c))
        assertFalse(m(song(sentiment = null), c))
    }

    @Test fun sentiment_eqAndNeq() {
        val eq = Clause("sentiment", FilterOp.EQ, value = " Chill ")
        val neq = Clause("sentiment", FilterOp.NEQ, value = "chill")
        assertTrue(m(song(sentiment = listOf("CHILL")), eq))
        assertFalse(m(song(sentiment = listOf("CHILL")), neq))
        assertTrue(m(song(sentiment = null), neq))
    }

    // ---- applicability / incomplete / unknown -------------------------------

    @Test fun clauseForNonApplicableKind_passesRow() {
        assertTrue(m(album(), Clause("bpm", FilterOp.BETWEEN, min = 500.0)))
        assertTrue(m(artist(1, 1), Clause("year", FilterOp.EQ, value = "1990")))
        // ...and a song-only clause doesn't gate albums even when it would fail songs.
        assertFalse(m(song(bpm = 10.0), Clause("bpm", FilterOp.BETWEEN, min = 500.0)))
    }

    @Test fun incompleteClause_isNoOp() {
        assertTrue(Clause("genre", FilterOp.IN_LIST).isIncomplete)
        assertTrue(Clause("year", FilterOp.EQ).isIncomplete)
        assertTrue(Clause("bpm", FilterOp.BETWEEN).isIncomplete)
        assertTrue(m(song(genre = "jazz"), Clause("genre", FilterOp.IN_LIST)))
        assertEquals(1, FilterEngine.apply(listOf(song()), listOf(Clause("bpm", FilterOp.BETWEEN))).size)
    }

    @Test fun unknownField_isNoOp() {
        assertTrue(m(song(), Clause("nonsense", FilterOp.EQ, value = "x")))
    }

    // ---- new fields ---------------------------------------------------------

    @Test fun playCount_between_usesSnapshot_missingFails() {
        val c = Clause("playCount", FilterOp.BETWEEN, min = 2.0)
        val counts = mapOf("a" to 3, "b" to 1)
        assertTrue(m(song(id = "a"), c, counts))
        assertFalse(m(song(id = "b"), c, counts))
        assertFalse(m(song(id = "c"), c, counts)) // never played = missing
    }

    @Test fun dateAdded_andLastPlayedAt_dateRange() {
        val added = Clause("dateAdded", FilterOp.BETWEEN, min = 100.0, max = 200.0)
        assertTrue(m(song(dateAdded = 150.0), added))
        assertFalse(m(song(dateAdded = 250.0), added))
        assertFalse(m(song(dateAdded = null), added))
        val played = Clause("lastPlayedAt", FilterOp.BETWEEN, min = 10.0)
        assertTrue(m(song(playedAt = 11.0), played))
        assertFalse(m(song(playedAt = null), played))
    }

    @Test fun artistCounts_filter() {
        val c = Clause("albumCount", FilterOp.BETWEEN, min = 2.0, max = 4.0)
        assertTrue(m(artist(3, 10), c))
        assertFalse(m(artist(1, 10), c))
        assertTrue(m(artist(5, 10), Clause("songCount", FilterOp.NEQ, value = "9")))
        assertTrue(m(artist(5, 10), Clause("artist", FilterOp.EQ, value = "art")))
    }

    @Test fun albumFields_trackCountCountryYear() {
        assertTrue(m(album(tracks = 12), Clause("trackCount", FilterOp.BETWEEN, min = 10.0, max = 14.0)))
        assertTrue(m(album(country = "US"), Clause("country", FilterOp.IN_LIST, values = setOf("us"))))
        assertFalse(m(album(year = null), Clause("year", FilterOp.EQ, value = "1990")))
    }

    @Test fun apply_andComposesClauses() {
        val rows = listOf(song(id = "1", year = 1990, genre = "jazz"), song(id = "2", year = 1990, genre = "pop"), song(id = "3", year = 2000, genre = "jazz"))
        val out = FilterEngine.apply(
            rows,
            listOf(
                Clause("year", FilterOp.BETWEEN, min = 1988.0, max = 1994.0),
                Clause("genre", FilterOp.NOT_IN_LIST, values = setOf("pop")),
            ),
        )
        assertEquals(listOf("1"), out.map { it.song.id })
    }

    // ---- options ------------------------------------------------------------

    @Test fun options_camelotByWheelRank_genreByPriority_otherCaseInsensitive() {
        val rows = listOf(
            song(camelot = "10A", genre = "jazz", key = "b minor"),
            song(camelot = "2B", genre = "hip-hop", key = "A major"),
            song(camelot = "2A", genre = "Other", key = "a minor"),
        )
        assertEquals(listOf("2A", "2B", "10A"), FieldOptions.of("camelot", rows, emptyList()))
        assertEquals(listOf("hip-hop", "jazz", "Other"), FieldOptions.of("genre", rows, emptyList()))
        assertEquals(listOf("A major", "a minor", "b minor"), FieldOptions.of("key", rows, emptyList()))
    }

    @Test fun options_sourceComesFromAvailableSources_sentimentFlattens() {
        val rows = listOf(song(sentiment = listOf("happy", "")), song(sentiment = listOf("dark", "happy")))
        assertEquals(listOf("B", "A"), FieldOptions.of("source", rows, listOf("B", "A")))
        assertEquals(listOf("dark", "happy"), FieldOptions.of("sentiment", rows, emptyList()))
    }
}
