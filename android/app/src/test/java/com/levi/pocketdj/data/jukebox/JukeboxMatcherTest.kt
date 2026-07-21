package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Android P1 catalog-only matcher cut (specs/jukebox.md §4.4). */
class JukeboxMatcherTest {

    private fun song(id: String, name: String, artist: String) =
        IndexSong(id = id, artist = artist, name = name)

    private val catalog = listOf(
        song("sng_1", "Blue Monday", "New Order"),
        song("sng_2", "Bizarre Love Triangle", "New Order"),
        song("sng_3", "Blue Monday", "Orgy"),
        song("sng_4", "Café del Mar", "Energy 52"),
        song("sng_5", "Smells Like Teen Spirit", "Nirvana"),
    )

    @Test
    fun normalize_foldsCasePunctuationAndDiacritics() {
        assertEquals("cafe del mar", JukeboxMatcher.normalize("Café del Mar!!!"))
        assertEquals("dont stop", JukeboxMatcher.normalize("  Don't   STOP…  "))
    }

    @Test
    fun exactNormalizedMatch_withArtistDisambiguation() {
        assertEquals("sng_3", JukeboxMatcher.match("blue monday", "orgy", catalog)?.id)
        assertEquals("sng_1", JukeboxMatcher.match("Blue Monday!", "new order", catalog)?.id)
    }

    @Test
    fun titleOnlyRequest_matchesFirstExactTitle() {
        assertEquals("sng_1", JukeboxMatcher.match("BLUE MONDAY", "", catalog)?.id)
    }

    @Test
    fun foldedContains_findsPartialTitle() {
        assertEquals("sng_5", JukeboxMatcher.match("teen spirit", "", catalog)?.id)
        assertEquals("sng_2", JukeboxMatcher.match("bizarre love", "new order", catalog)?.id)
    }

    @Test
    fun noOverlap_returnsNull() {
        assertNull(JukeboxMatcher.match("Free Bird", "Lynyrd Skynyrd", catalog))
        assertNull(JukeboxMatcher.match("", "New Order", catalog))
    }
}
