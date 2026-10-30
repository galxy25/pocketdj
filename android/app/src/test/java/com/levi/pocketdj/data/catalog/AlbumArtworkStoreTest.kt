package com.levi.pocketdj.data.catalog

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class AlbumArtworkStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val body = """
        {"resultCount":2,"results":[
          {"wrapperType":"collection","collectionId":111,"artworkUrl100":"https://is1.mzstatic.com/a/Cover.jpg/100x100bb.jpg"},
          {"wrapperType":"track","trackId":901,"collectionId":222,"artworkUrl100":"https://is1.mzstatic.com/b/x.jpg/100x100bb.jpg"}
        ]}
    """.trimIndent()

    private fun album(id: String, amId: String?, tracks: List<String> = emptyList(), cover: String? = null) =
        IndexAlbum(id = id, artist = "A", name = id, appleMusicId = amId, trackList = tracks, coverArt = cover)

    @Test fun parseLookupKeysCollectionsAndTracksAndUpsizes() {
        val m = AlbumArtworkStore.parseLookup(body)!!
        assertEquals("https://is1.mzstatic.com/a/Cover.jpg/600x600bb.jpg", m["111"])
        assertEquals("https://is1.mzstatic.com/b/x.jpg/600x600bb.jpg", m["901"])
        assertEquals("https://is1.mzstatic.com/b/x.jpg/600x600bb.jpg", m["222"])
        assertNull(AlbumArtworkStore.parseLookup("not json"))
    }

    @Test fun requestsInOneWindowShareOneLookupAndFallBackToTrackIds() = runTest {
        val urls = mutableListOf<String>()
        val store = AlbumArtworkStore(
            scope = backgroundScope,
            fetch = { urls += it; body },
            songAppleMusicId = { mapOf("s1" to "901")[it] },
            cacheFile = tmp.newFile("art.json"),
            now = { testScheduler.currentTime },
        )
        store.request(album("A1", "111"))
        store.request(album("A2", "999", tracks = listOf("s1"))) // album id misses, track id hits
        store.request(album("A3", "555"))                         // full miss
        store.request(album("B", null, cover = "/art/b.jpg"))      // bundled art: never looked up
        advanceTimeBy(1_000); advanceUntilIdle()
        assertEquals(1, urls.size)
        assertTrue(urls[0].endsWith("?id=111,999,901,555"))
        assertEquals("https://is1.mzstatic.com/a/Cover.jpg/600x600bb.jpg", store.resolved.value["A1"])
        assertEquals("https://is1.mzstatic.com/b/x.jpg/600x600bb.jpg", store.resolved.value["A2"])
        assertNull(store.resolved.value["A3"])
        // A recent miss is not re-asked.
        store.request(album("A3", "555")); advanceTimeBy(1_000); advanceUntilIdle()
        assertEquals(1, urls.size)
    }

    @Test fun failedLookupBacksOffAndRetries() = runTest {
        var calls = 0
        val store = AlbumArtworkStore(
            scope = backgroundScope,
            fetch = { calls++; if (calls == 1) null else body },
            songAppleMusicId = { null },
            cacheFile = null,
            backoffMs = 5_000,
            now = { testScheduler.currentTime },
        )
        store.request(album("A1", "111"))
        advanceTimeBy(1_000)
        assertEquals(1, calls)
        assertNull(store.resolved.value["A1"])
        advanceTimeBy(10_000); advanceUntilIdle()
        assertEquals(2, calls)
        assertEquals("https://is1.mzstatic.com/a/Cover.jpg/600x600bb.jpg", store.resolved.value["A1"])
    }

    @Test fun hitsPersistAcrossInstances() = runTest {
        val f = tmp.newFile("art.json")
        val a = AlbumArtworkStore(backgroundScope, { body }, { null }, f, now = { testScheduler.currentTime })
        a.request(album("A1", "111")); advanceTimeBy(1_000); advanceUntilIdle()
        // persist() writes on Dispatchers.IO; wait for it.
        val deadline = System.currentTimeMillis() + 5_000
        while (!f.readText().contains("A1") && System.currentTimeMillis() < deadline) Thread.sleep(10)
        val b = AlbumArtworkStore(backgroundScope, { error("no network") }, { null }, f)
        assertEquals("https://is1.mzstatic.com/a/Cover.jpg/600x600bb.jpg", b.cached("A1"))
    }
}
