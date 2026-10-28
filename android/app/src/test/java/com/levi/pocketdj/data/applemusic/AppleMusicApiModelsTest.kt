package com.levi.pocketdj.data.applemusic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppleMusicApiModelsTest {
    @Test fun songDecodeFullAttributes() {
        val body = """{"results":{"songs":{"data":[{"id":"900","type":"songs","href":"/x","attributes":{
          "name":"Around the World","artistName":"Daft Punk","albumName":"Homework","durationInMillis":429000,
          "isrc":"FRZ039600011","contentRating":"explicit","unknownFuture":{"a":1},
          "previews":[{"url":"https://p/1.m4a"}],"artwork":{"url":"https://a/{w}x{h}.jpg"}}}]}}}"""
        val s = AppleMusicApiModels.parseCatalogSearch(body)!!.songs.items.single()
        assertEquals("900", s.id)
        assertEquals(429.0, s.durationSec!!, 0.001)
        assertEquals("https://p/1.m4a", s.previewUrl)
        assertEquals("https://a/300x300.jpg", s.artworkUrl)
        assertTrue(s.explicit)
    }

    @Test fun badRowDroppedNotWholePage() {
        val body = """{"results":{"songs":{"data":[42,{"attributes":{"name":"no id"}},{"id":"1"}]}}}"""
        val songs = AppleMusicApiModels.parseCatalogSearch(body)!!.songs.items
        assertEquals(listOf("1"), songs.map { it.id })
        assertEquals("", songs[0].title)
    }

    @Test fun unreadableEnvelopesAreNullNotEmpty() {
        assertNull(AppleMusicApiModels.parseCatalogSearch("<html>"))
        assertNull(AppleMusicApiModels.parseCatalogSearch("""{"errors":[]}"""))
        assertNull(AppleMusicApiModels.parseLibraryPlaylists("""{"data":"x"}"""))
        assertNull(AppleMusicApiModels.parseLovedIds("""{"errors":[{}]}"""))
        assertNull(AppleMusicApiModels.parseTrackPage("nope"))
        assertNull(AppleMusicApiModels.parseArtists("{}"))
    }

    @Test fun lovedIdsEmptyDataIsEmptySet() {
        assertEquals(emptySet<String>(), AppleMusicApiModels.parseLovedIds("""{"data":[]}"""))
    }

    @Test fun nextOffsetParsing() {
        assertEquals(25, AppleMusicApiModels.nextOffset("/v1/me/library/playlists?limit=25&offset=25"))
        assertNull(AppleMusicApiModels.nextOffset(null))
        assertNull(AppleMusicApiModels.nextOffset("/v1/x?limit=1"))
    }

    @Test fun canEditAbsentIsEditableExplicitFalseIsNot() {
        val p = AppleMusicApiModels.parseLibraryPlaylists(
            """{"data":[{"id":"a","attributes":{"name":"A"}},{"id":"b","attributes":{"canEdit":false}},{"attributes":{}}]}""",
        )!!
        assertEquals(2, p.items.size)
        assertTrue(p.items[0].canEdit)
        assertFalse(p.items[1].canEdit)
    }

    @Test fun trackPageFallsBackToPlayParamsIdAndDedups() {
        val p = AppleMusicApiModels.parseTrackPage(
            """{"data":[{"attributes":{"playParams":{"id":"x"}}},{"attributes":{"playParams":{"catalogId":"x"}}},{"attributes":{"playParams":{"catalogId":"y"}}}]}""",
        )!!
        assertEquals(listOf("x", "y"), p.catalogIds)
        assertEquals(3, p.rowCount)
        assertFalse(p.hasNext)
    }

    @Test fun albumsAndArtistsWithoutViews() {
        val a = AppleMusicApiModels.parseArtists("""{"data":[{"id":"1","attributes":{"name":"N"}}]}""")!!.single()
        assertNull(a.latestRelease)
        assertTrue(a.similarArtistIds.isEmpty())
        val al = AppleMusicApiModels.album(kotlinx.serialization.json.Json.parseToJsonElement(
            """{"id":"z","attributes":{"name":"T","trackCount":12,"releaseDate":"2026-01-01"}}"""))!!
        assertEquals(12, al.trackCount)
    }
}
