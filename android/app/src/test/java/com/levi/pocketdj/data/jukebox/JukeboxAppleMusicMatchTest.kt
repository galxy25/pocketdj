package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.applemusic.StaticAppleMusicTokens
import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class JukeboxAppleMusicMatchTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown() }

    private fun api() = AppleMusicApi(
        OkHttpClient(), StaticAppleMusicTokens("dev-1"),
        baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {},
    )

    private fun matcher(songs: List<IndexSong> = emptyList()) = JukeboxAppleMusicMatch(api(), { songs })

    private fun hit(id: String = "900", name: String = "Obscure Song", artist: String = "Nobody") = MockResponse().setBody(
        """{"results":{"songs":{"data":[{"id":"$id","attributes":{"name":"$name","artistName":"$artist","durationInMillis":201000,"contentRating":"explicit"}}]}}}""",
    )

    @Test fun searchTermIsTitleAloneOrTitleArtist() {
        assertEquals("Hey", JukeboxAppleMusicMatch.searchTerm(" Hey ", " "))
        assertEquals("Hey Pixies", JukeboxAppleMusicMatch.searchTerm("Hey", "Pixies"))
        assertNull(JukeboxAppleMusicMatch.searchTerm("  ", "Pixies"))
    }

    @Test fun notInLibraryBecomesAdHocAmRowAndHitsCatalogSearch() = runTest {
        server.enqueue(hit())
        val song = matcher().match("Obscure Song", "Nobody")!!
        assertEquals("amrec_900", song.id)
        assertEquals("900", song.appleMusicId)
        assertEquals(201_000L, song.length)
        assertEquals(true, song.explicit)
        assertTrue(JukeboxAppleMusicMatch.isAdHoc(song.id))
        val req = server.takeRequest()
        assertTrue(req.path!!.startsWith("/v1/catalog/us/search?"))
        assertTrue(req.path!!.contains("types=songs"))
        assertTrue(req.path!!.contains("term=Obscure%20Song%20Nobody"))
        assertEquals("Bearer dev-1", req.getHeader("Authorization"))
    }

    @Test fun hitThatIsInTheLibraryMapsBackToTheIndexedSong() = runTest {
        server.enqueue(hit(id = "123", name = "Café del Mar", artist = "Energy 52"))
        val indexed = IndexSong(id = "sng_1", artist = "Energy 52", name = "Cafe del Mar")
        val song = matcher(listOf(indexed)).match("cafe del mar", "energy 52")!!
        assertEquals("sng_1", song.id)
        assertFalse(JukeboxAppleMusicMatch.isAdHoc(song.id))
    }

    @Test fun mapBackByStampedAppleMusicId() = runTest {
        server.enqueue(hit(id = "77", name = "Different Title", artist = "X"))
        val indexed = IndexSong(id = "sng_9", artist = "Y", name = "Other", appleMusicId = "77")
        assertEquals("sng_9", matcher(listOf(indexed)).match("anything", "")!!.id)
    }

    @Test fun emptyResultsAndHttpFailureAreNull() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":{}}"""))
        assertNull(matcher().match("Nothing", "Nobody"))
        server.enqueue(MockResponse().setResponseCode(500))
        assertNull(matcher().match("Boom", ""))
    }

    @Test fun blankTitleNeverCallsTheNetwork() = runTest {
        assertNull(matcher().match("   ", "Someone"))
        assertEquals(0, server.requestCount)
    }

    /** Q113: the ladder streams an ad-hoc row through the SDK by the store id carried in its id. */
    @Test fun storeIdOfReadsOnlyAdHocSongIds() {
        assertEquals("1440", JukeboxAppleMusicMatch.storeIdOf("amrec_1440"))
        assertEquals("1440", JukeboxAppleMusicMatch.storeIdOf(JukeboxAppleMusicMatch.adHocSong("1440", "t", "a", null, false).id))
        assertNull("album ids are not songs", JukeboxAppleMusicMatch.storeIdOf("amrec_album_99"))
        assertNull(JukeboxAppleMusicMatch.storeIdOf("amrec_"))
        assertNull(JukeboxAppleMusicMatch.storeIdOf("sng_1"))
        assertFalse(JukeboxAppleMusicMatch.isAdHoc("sng_1"))
        assertTrue(JukeboxAppleMusicMatch.isAdHoc("amrec_1"))
    }
}
