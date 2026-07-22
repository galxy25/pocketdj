package com.levi.pocketdj.data.artists

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Grouping/counts/search/discography for the Artists browse kind (specs/artists.md §3, §6, §10). */
class ArtistCatalogTest {

    private fun album(id: String, artist: String, name: String, tracks: List<String>) =
        IndexAlbum(id = id, artist = artist, name = name, trackList = tracks)

    private fun song(id: String, artist: String, name: String) =
        IndexSong(id = id, artist = artist, name = name, albumId = null)

    private fun catalog(albums: List<IndexAlbum>, songs: List<IndexSong>) =
        MergedCatalog.merge(
            listOf(IndexJson(manifest = IndexManifest(sourceName = "Test"), albums = albums, songs = songs)),
        )

    @Test
    fun groupsCaseInsensitivelyWithFirstCasingCountsAndArt() {
        // "OutKast"/"Outkast" must FUSE into one row (case-insensitive grouping),
        // else a duplicate LazyColumn key crashes (§12 trap 1). Jay-Z is separate.
        val albums = listOf(
            album("a1", "OutKast", "Aquemini", listOf("s1", "s2", "s3")),
            album("a2", "Outkast", "Stankonia", listOf("s4", "s5")),
            album("a3", "Jay-Z", "The Blueprint", listOf("s6")),
        )
        val songs = (1..6).map { song("s$it", "x", "n$it") }
        val artistCatalog = ArtistCatalog.of(catalog(albums, songs))

        assertEquals(2, artistCatalog.artists.size)
        val outkast = artistCatalog.artists.first { it.name.equals("outkast", ignoreCase = true) }
        assertEquals("OutKast", outkast.name)          // FIRST album's casing (§3.2)
        assertEquals(2, outkast.albumCount)
        assertEquals(5, outkast.songCount)             // 3 + 2 (Σ trackList.size)
        assertEquals("a1", outkast.artworkAlbumId)     // first grouped album id
        assertEquals(ArtistCatalog.fold("OutKast"), outkast.searchKey)

        val jay = artistCatalog.artists.first { it.name == "Jay-Z" }
        assertEquals(1, jay.albumCount)
        assertEquals(1, jay.songCount)
    }

    @Test
    fun songCountCountsTrackListNotResolvedTracks() {
        // trackList holds a MISSING id ("missing") and a DUPLICATE ("s1") — both
        // count (§3.2), unlike MergedCatalog.tracks which would drop them.
        val albums = listOf(album("a1", "Solo", "Only", listOf("s1", "s1", "missing")))
        val songs = listOf(song("s1", "Solo", "Track"))
        val artistCatalog = ArtistCatalog.of(catalog(albums, songs))

        val artist = artistCatalog.artists.single()
        assertEquals(3, artist.songCount)              // counts dup + missing
        assertEquals(1, artist.albumCount)
    }

    @Test
    fun searchFoldsDiacriticsAndIsNameScoped() {
        val albums = listOf(
            album("a1", "Beyoncé", "Lemonade", listOf("s1")),
            album("a2", "Jay-Z", "4:44", listOf("s2")),
        )
        val songs = listOf(song("s1", "Beyoncé", "Sorry"), song("s2", "Jay-Z", "Kill Jay Z"))
        val artistCatalog = ArtistCatalog.of(catalog(albums, songs))

        assertEquals(1, artistCatalog.filtered("beyonce").size)          // diacritic fold
        assertEquals("Beyoncé", artistCatalog.filtered("beyonce").first().name)
        assertEquals(2, artistCatalog.filtered("").size)                 // empty → all
        assertTrue(artistCatalog.filtered("beyonce\njay").isEmpty())     // \n can't cross rows
    }

    @Test
    fun discographyMatchesCaseInsensitivelyAndConcatenatesTrackLists() {
        val albums = listOf(
            album("a1", "OutKast", "Aquemini", listOf("s1", "s2")),
            album("a2", "Outkast", "Stankonia", listOf("s3")),
        )
        val songs = (1..3).map { song("s$it", "x", "n$it") }
        val artistCatalog = ArtistCatalog.of(catalog(albums, songs))

        // Query with a THIRD casing — still gathers both albums (§6.1).
        assertEquals(2, artistCatalog.albumsOf("OUTKAST").size)
        assertEquals(listOf("s1", "s2", "s3"), artistCatalog.songIdsOf("OUTKAST"))
        // songIds size equals the row's songCount for the same name (§12 trap 2).
        val row = artistCatalog.artists.single()
        assertEquals(row.songCount, artistCatalog.songIdsOf(row.name).size)
    }

    @Test
    fun emptyCatalogYieldsNoArtists() {
        val artistCatalog = ArtistCatalog.of(catalog(emptyList(), emptyList()))
        assertTrue(artistCatalog.artists.isEmpty())
        assertTrue(artistCatalog.filtered("anything").isEmpty())
        assertNull(artistCatalog.artists.firstOrNull())
    }
}
