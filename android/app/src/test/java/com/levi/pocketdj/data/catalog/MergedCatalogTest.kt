package com.levi.pocketdj.data.catalog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Multi-source merge contract (specs/catalog.md §5). */
class MergedCatalogTest {

    private fun album(id: String, artist: String = "Artist", name: String = "Album", tracks: List<String> = emptyList()) =
        IndexAlbum(id = id, artist = artist, name = name, trackList = tracks)

    private fun song(id: String, artist: String = "Artist", name: String = "Song", albumId: String? = null) =
        IndexSong(id = id, artist = artist, name = name, albumId = albumId)

    private val vinylDoc = IndexJson(
        manifest = IndexManifest(sourceName = "My Vinyl"),
        albums = listOf(album("alb_1", artist = "beta Band", name = "Zed")),
        songs = listOf(song("sng_1"), song("sng_2", name = "Vinyl Take")),
        playlists = listOf(IndexPlaylist(id = "pl_1", name = "Spin", songIds = listOf("sng_1"))),
    )

    // No sourceName → display name falls back to "Collection".
    private val secondDoc = IndexJson(
        manifest = IndexManifest(),
        albums = listOf(
            album("alb_1", name = "Shadowed Twin"), // dup id — must lose
            album("alb_2", artist = "Alpha", name = "First"),
        ),
        songs = listOf(song("sng_2", name = "AM Take"), song("sng_3")),
        playlists = listOf(
            IndexPlaylist(id = "pl_1", name = "Dup"), // dup id — must lose
            IndexPlaylist(id = "pl_2", name = "Mirror"),
        ),
    )

    @Test
    fun firstOccurrenceWins_forAlbumsAndSongs() {
        val merged = MergedCatalog.merge(listOf(vinylDoc, secondDoc))
        assertEquals("Zed", merged.albumsById["alb_1"]?.name)
        assertEquals("Vinyl Take", merged.songsById["sng_2"]?.name)
        assertEquals(2, merged.albums.size)
        assertEquals(3, merged.songs.size)
    }

    @Test
    fun sourceTags_recordFirstCarryingSource_withCollectionFallback() {
        val merged = MergedCatalog.merge(listOf(vinylDoc, secondDoc))
        assertEquals("My Vinyl", merged.sourceOfAlbum["alb_1"])
        assertEquals("Collection", merged.sourceOfAlbum["alb_2"])
        assertEquals("My Vinyl", merged.sourceOfSong["sng_2"]) // dup: first source wins
        assertEquals("Collection", merged.sourceOfSong["sng_3"])
    }

    @Test
    fun availableSources_distinctFirstSeenOrder() {
        val merged = MergedCatalog.merge(listOf(vinylDoc, secondDoc))
        assertEquals(listOf("My Vinyl", "Collection"), merged.availableSources)
    }

    @Test
    fun fullyShadowedSource_contributesNoSourceName() {
        val shadowed = IndexJson(
            manifest = IndexManifest(sourceName = "Ghost"),
            albums = listOf(album("alb_1")),
            songs = listOf(song("sng_1")),
        )
        val merged = MergedCatalog.merge(listOf(vinylDoc, shadowed))
        assertFalse(merged.availableSources.contains("Ghost"))
    }

    @Test
    fun albums_sortedArtistThenName_caseInsensitive() {
        val merged = MergedCatalog.merge(listOf(vinylDoc, secondDoc))
        // "Alpha" sorts before "beta Band" case-insensitively.
        assertEquals(listOf("alb_2", "alb_1"), merged.albums.map { it.id })
    }

    @Test
    fun playlists_flattenedSourceTagged_dedupedById() {
        val merged = MergedCatalog.merge(listOf(vinylDoc, secondDoc))
        assertEquals(2, merged.playlists.size)
        val first = merged.playlists.first { it.playlist.id == "pl_1" }
        assertEquals("Spin", first.playlist.name) // first occurrence won
        assertEquals("My Vinyl", first.sourceName)
        val second = merged.playlists.first { it.playlist.id == "pl_2" }
        assertEquals("Collection", second.sourceName)
    }

    @Test
    fun tracks_resolveThroughSongsById_droppingUnknownIds() {
        val doc = IndexJson(
            manifest = IndexManifest(sourceName = "My Vinyl"),
            albums = listOf(album("alb_1", tracks = listOf("sng_1", "sng_missing", "sng_2"))),
            songs = listOf(song("sng_1"), song("sng_2")),
        )
        val merged = MergedCatalog.merge(listOf(doc))
        val tracks = merged.tracks(merged.albumsById.getValue("alb_1"))
        assertEquals(listOf("sng_1", "sng_2"), tracks.map { it.id })
    }
}
