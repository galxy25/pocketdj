package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class RecognitionActionReducerTest {
    private val album = AppleMusicAlbumRef("a1", "Album", "Artist", url = "https://music.apple.com/a1")
    private fun res(inLib: Boolean, album: AppleMusicAlbumRef? = this.album, url: String? = "https://music.apple.com/s") =
        AppleMusicResolution("s1", "Song", "Artist", inLib, album, url)

    private fun act(
        available: Boolean = true, canContribute: Boolean = true, canAdd: Boolean = true,
        resolving: Boolean = false, resolution: AppleMusicResolution? = null, idx: String? = null,
    ) = AppleMusicRecognition.action(available, canContribute, canAdd, resolving, resolution, idx)

    @Test fun unavailableBeatsEverything() =
        assertEquals(AppleMusicRecognitionAction.Unavailable, act(available = false, canContribute = false, resolving = true))

    @Test fun connectWhenNotLinked() =
        assertEquals(AppleMusicRecognitionAction.Connect, act(canContribute = false, resolving = true))

    @Test fun checkingWhileResolving() =
        assertEquals(AppleMusicRecognitionAction.Checking, act(resolving = true, resolution = res(true)))

    @Test fun notFoundWithoutResolution() =
        assertEquals(AppleMusicRecognitionAction.NotFound, act(resolution = null))

    @Test fun inLibraryPrefersIndexAlbumThenRecognizedThenPlain() {
        assertEquals(AppleMusicRecognitionAction.OpenIndexAlbum("alb9"), act(resolution = res(true), idx = "alb9"))
        assertEquals(AppleMusicRecognitionAction.OpenRecognizedAlbum(album), act(resolution = res(true)))
        assertEquals(AppleMusicRecognitionAction.InLibrary, act(resolution = res(true, album = null)))
    }

    @Test fun notInLibraryAddsWhenAllowed() =
        assertEquals(AppleMusicRecognitionAction.AddToLibrary("s1", "Song", "Artist"), act(resolution = res(false)))

    @Test fun notInLibraryWithoutAddOpensMusicOrNotFound() {
        assertEquals(AppleMusicRecognitionAction.OpenInMusicApp("https://music.apple.com/s"), act(canAdd = false, resolution = res(false)))
        assertEquals(AppleMusicRecognitionAction.NotFound, act(canAdd = false, resolution = res(false, url = null)))
    }

    @Test fun burnSongIdPrefersCatalogElseAmrec() {
        assertEquals("cat_1", AppleMusicRecognition.burnSongId("cat_1", "999"))
        assertEquals("amrec_999", AppleMusicRecognition.burnSongId(null, "999"))
        assertEquals("amrec_999", AppleMusicRecognition.burnSongId("", "999"))
    }

    @Test fun indexAlbumMatchesNormalizedTitleAndCompatibleArtist() {
        val albums = listOf(
            IndexAlbum(id = "x", artist = "Other", name = "Cafe"),
            IndexAlbum(id = "y", artist = "Artist feat. Guest", name = "Café (Deluxe)"),
        )
        val ref = AppleMusicAlbumRef("1", "Cafe", "Artist")
        assertEquals("y", AppleMusicRecognition.indexAlbum(ref, albums)?.id)
        assertNull(AppleMusicRecognition.indexAlbum(AppleMusicAlbumRef("1", "Nope", "Artist"), albums))
        assertNull(AppleMusicRecognition.indexAlbum(AppleMusicAlbumRef("1", "(x)", "Artist"), albums))
        assertEquals("x", AppleMusicRecognition.indexAlbum(AppleMusicAlbumRef("1", "Cafe", ""), albums)?.id)
    }

    @Test fun indexSongByNamespacedIdStampedIdThenTitleArtist() {
        val songs = listOf(
            IndexSong(id = "am:42", artist = "A", name = "One"),
            IndexSong(id = "r1", artist = "B", name = "Two", appleMusicId = "77"),
            IndexSong(id = "r2", artist = "C feat. D", name = "Three (Remastered)"),
        )
        assertEquals("am:42", AppleMusicRecognition.indexSong("42", null, null, songs)?.id)
        assertEquals("r1", AppleMusicRecognition.indexSong("77", null, null, songs)?.id)
        assertEquals("r2", AppleMusicRecognition.indexSong("0", "Three", "C", songs)?.id)
        assertNull(AppleMusicRecognition.indexSong("0", "Three", "Zed", songs))
        assertNull(AppleMusicRecognition.indexSong("0", null, "C", songs))
    }

    @Test fun parsesCatalogSongWithAlbum() {
        val body = """{"data":[{"id":"s1","attributes":{"name":"Song","artistName":"Artist","url":"https://m/s"},
            "relationships":{"albums":{"data":[{"id":"a1","attributes":{"name":"Alb","artistName":"Artist","releaseDate":"2011-03-01","url":"https://m/a"}}]}}}]}"""
        val r = AppleMusicRecognitionParsing.parseCatalogSong(body)!!
        assertEquals("s1", r.songStoreId)
        assertEquals("a1", r.album?.storeId)
        assertEquals(2011, r.album?.year)
        assertFalse(r.inLibrary)
        assertNull(AppleMusicRecognitionParsing.parseCatalogSong("not json"))
    }

    @Test fun parsesSearchTopSongAndLibraryProbe() {
        val search = """{"results":{"songs":{"data":[{"id":"s2","attributes":{"name":"S","artistName":"A"}}]}}}"""
        assertEquals("s2", AppleMusicRecognitionParsing.parseSearchTopSong(search)?.songStoreId)
        val lib = """{"results":{"library-songs":{"data":[{"id":"l.1","attributes":{"name":"Café (Remastered)","artistName":"Artist feat. X"}}]}}}"""
        assertTrue(AppleMusicRecognitionParsing.libraryContains(lib, "Cafe", "Artist"))
        assertFalse(AppleMusicRecognitionParsing.libraryContains(lib, "Cafe", "Someone"))
        assertFalse(AppleMusicRecognitionParsing.libraryContains("""{"results":{}}""", "Cafe", "Artist"))
    }
}
