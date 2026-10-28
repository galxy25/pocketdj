package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.history.PlayHistoryStore
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageServiceLyricsTest {
    private class FakeArtwork : ArtworkCache {
        override fun diskSizeBytes(): Long = 0L
        override fun clear() = Unit
    }
    private fun tempDir(): File = Files.createTempDirectory("pdj-storage-lyrics").toFile()

    @Test
    fun lyricsCacheMeasuresAndClearsWithoutTouchingOtherCategories() = runTest {
        val filesDir = tempDir()
        val lyrics = File(filesDir, "lyrics-cache").apply { mkdirs() }
        File(lyrics, "sng_1.txt").writeText("x".repeat(300))
        val catalog = File(filesDir, "catalog-cache").apply { mkdirs() }
        File(catalog, "a.json").writeText("y".repeat(40))
        val svc = StorageService(
            catalogCacheDir = catalog,
            collectionsFile = File(filesDir, "pocketdj-collections.json"),
            playHistoryFile = File(filesDir, PlayHistoryStore.FILE_NAME),
            activityFile = File(filesDir, CollectionActivityStore.FILE_NAME),
            artwork = FakeArtwork(),
            clearCatalogCache = {},
            clearPlayHistory = {},
            clearActivity = {},
            lyricsCacheDir = lyrics,
        )
        assertEquals(300L, svc.measure(StorageService.Category.LYRICS))
        assertTrue(StorageService.Category.LYRICS in svc.clearableCategories)
        assertEquals(0L, svc.clear(StorageService.Category.LYRICS))
        assertEquals(40L, svc.measure(StorageService.Category.CATALOG_CACHE))
    }
}
