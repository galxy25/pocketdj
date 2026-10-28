package com.levi.pocketdj.data.lyrics

import com.levi.pocketdj.data.catalog.IndexSong
import java.io.File
import java.nio.file.Files
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

class LyricsStoreTest {
    private lateinit var server: MockWebServer
    private lateinit var dir: File

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        dir = Files.createTempDirectory("pdj-lyrics").toFile()
    }

    @After fun tearDown() { server.shutdown() }

    private fun store() = LyricsStore(
        cacheDir = dir,
        baseUrl = { server.url("/").toString().trimEnd('/') },
        fetch = LyricsStore.httpFetcher(OkHttpClient()),
    )

    private fun song(id: String = "sng_1", status: String? = "found") =
        IndexSong(id = id, artist = "A", name = "N", lyricsStatus = status)

    @Test fun nonFoundStatusNeverRequests() = runTest {
        val s = store()
        for (st in listOf(null, "notfound", "error", "")) assertNull(s.lyrics(song(status = st)))
        assertEquals(0, server.requestCount)
    }

    @Test fun fetchesOnceThenServesFromMemoryAndDisk() = runTest {
        server.enqueue(MockResponse().setBody("la la la"))
        val s = store()
        assertEquals("la la la", s.lyrics(song()))
        assertEquals("/lyrics/sng_1.txt", server.takeRequest().path)
        assertTrue(File(dir, "sng_1.txt").isFile)
        assertEquals("la la la", s.lyrics(song())) // memory
        assertEquals("la la la", store().lyrics(song())) // fresh instance = disk only (offline)
        assertEquals(1, server.requestCount)
    }

    @Test fun notFoundIsNotCached() = runTest {
        server.enqueue(MockResponse().setResponseCode(404).setBody("<Error>AccessDenied</Error>"))
        assertNull(store().lyrics(song()))
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test fun blankBodyIsNotCached() = runTest {
        server.enqueue(MockResponse().setBody("  \n "))
        assertNull(store().lyrics(song()))
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test fun pathUnsafeIdsAreFlattened() = runTest {
        server.enqueue(MockResponse().setBody("x"))
        assertEquals("x", store().lyrics(song(id = "am:1/2")))
        assertEquals(listOf("am_1_2.txt"), dir.listFiles()!!.map { it.name })
        assertEquals("a_b_c", LyricsStore.safeName("a:b/c"))
    }

    @Test fun clearDiskRemovesFilesAndMemory() = runTest {
        server.enqueue(MockResponse().setBody("one"))
        server.enqueue(MockResponse().setBody("two"))
        val s = store()
        assertEquals("one", s.lyrics(song()))
        s.clearDisk()
        assertFalse(File(dir, "sng_1.txt").exists())
        assertEquals("two", s.lyrics(song()))
    }
}
