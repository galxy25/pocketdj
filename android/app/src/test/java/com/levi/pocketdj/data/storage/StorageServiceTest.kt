package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.history.PlayHistoryStore
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Measurement + the clear contract (specs/storage.md §2, §3, §7). */
class StorageServiceTest {

    private class FakeArtwork(var bytes: Long = 0L) : ArtworkCache {
        var cleared = false
        override fun diskSizeBytes(): Long = bytes
        override fun clear() { cleared = true; bytes = 0L }
    }

    private fun tempDir(): File = Files.createTempDirectory("pdj-storage").toFile()

    private fun service(
        filesDir: File,
        artwork: ArtworkCache = FakeArtwork(),
        history: PlayHistoryStore? = null,
        activity: CollectionActivityStore? = null,
    ): StorageService {
        val catalogCacheDir = File(filesDir, "catalog-cache")
        return StorageService(
            catalogCacheDir = catalogCacheDir,
            collectionsFile = File(filesDir, "pocketdj-collections.json"),
            playHistoryFile = File(filesDir, PlayHistoryStore.FILE_NAME),
            activityFile = File(filesDir, CollectionActivityStore.FILE_NAME),
            artwork = artwork,
            clearCatalogCache = { catalogCacheDir.listFiles()?.forEach { it.delete() } },
            clearPlayHistory = { history?.clear() },
            clearActivity = { activity?.clear() },
        )
    }

    @Test
    fun measuringEmptyFilesDirYieldsZeroNotCrash() = runTest {
        val filesDir = tempDir()
        val sizes = service(filesDir).measureAll()
        assertEquals(0L, sizes[StorageService.Category.CATALOG_CACHE])
        assertEquals(0L, sizes[StorageService.Category.COLLECTIONS])
        assertEquals(0L, sizes[StorageService.Category.PLAY_HISTORY])
        assertEquals(0L, sizes[StorageService.Category.ACTIVITY])
        assertEquals(0L, sizes[StorageService.Category.ARTWORK])
    }

    @Test
    fun catalogCacheMeasuresRecursivelyAndClearsToZero() = runTest {
        val filesDir = tempDir()
        val cacheDir = File(filesDir, "catalog-cache").apply { mkdirs() }
        File(cacheDir, "a.json").writeText("x".repeat(500))
        File(cacheDir, "b.meta.json").writeText("y".repeat(100))
        val svc = service(filesDir)

        assertEquals(600L, svc.measure(StorageService.Category.CATALOG_CACHE))
        val after = svc.clear(StorageService.Category.CATALOG_CACHE)
        assertEquals(0L, after)
        assertEquals(0L, svc.measure(StorageService.Category.CATALOG_CACHE))
    }

    @Test
    fun artworkMeasuresCoilSizeAndClearsBothCaches() = runTest {
        val filesDir = tempDir()
        val artwork = FakeArtwork(bytes = 4096L)
        val svc = service(filesDir, artwork = artwork)

        assertEquals(4096L, svc.measure(StorageService.Category.ARTWORK))
        assertEquals(0L, svc.clear(StorageService.Category.ARTWORK))
        assertTrue(artwork.cleared)
    }

    @Test
    fun historyClearEmptiesEventsButKeepsInstallId() = runTest {
        val filesDir = tempDir()
        val historyFile = File(filesDir, PlayHistoryStore.FILE_NAME)
        val history = PlayHistoryStore(historyFile)
        history.record(songId = "s1", title = "t", artist = "a")
        history.record(songId = "s2", title = "t", artist = "a")
        val installBefore = history.installId
        assertTrue(installBefore.isNotBlank())

        val svc = service(filesDir, history = history)
        assertTrue(svc.measure(StorageService.Category.PLAY_HISTORY) > 0L)

        svc.clear(StorageService.Category.PLAY_HISTORY)
        assertTrue(history.events.isEmpty())
        assertEquals(installBefore, history.installId) // identity preserved (§3 rule 2)
    }

    @Test
    fun activityClearDeletesFileAndKeepsInstallId() = runTest {
        val filesDir = tempDir()
        val activityFile = File(filesDir, CollectionActivityStore.FILE_NAME)
        val activity = CollectionActivityStore(activityFile)
        activity.record(kind = ActivityKind.ADD, itemId = "s1", itemTitle = "T")
        val installBefore = activity.installId
        assertTrue(activityFile.isFile)

        val svc = service(filesDir, activity = activity)
        assertTrue(svc.measure(StorageService.Category.ACTIVITY) > 0L)

        val after = svc.clear(StorageService.Category.ACTIVITY)
        assertEquals(0L, after)          // file deleted → 0
        assertFalse(activityFile.exists())
        assertEquals(installBefore, activity.installId)
    }

    @Test
    fun collectionsIsDisplayOnlyAndClearIsRejected() = runTest {
        val filesDir = tempDir()
        File(filesDir, "pocketdj-collections.json").writeText("{}".repeat(50))
        val svc = service(filesDir)

        assertTrue(svc.measure(StorageService.Category.COLLECTIONS) > 0L)
        assertFalse(StorageService.Category.COLLECTIONS in svc.clearableCategories)
        assertThrows(IllegalArgumentException::class.java) {
            kotlinx.coroutines.runBlocking { svc.clear(StorageService.Category.COLLECTIONS) }
        }
    }

    @Test
    fun clearingEveryCategoryLeavesTheSettingsDataStoreUntouched() = runTest {
        val filesDir = tempDir()
        // The settings DataStore file — a clear must NEVER touch it (§3 rule 1).
        val settingsFile = File(filesDir, "pocketdj-settings.preferences_pb")
        val settingsBytes = byteArrayOf(1, 2, 3, 4, 5)
        settingsFile.writeBytes(settingsBytes)
        File(filesDir, "catalog-cache").apply { mkdirs() }.let { File(it, "a.json").writeText("x") }
        val history = PlayHistoryStore(File(filesDir, PlayHistoryStore.FILE_NAME)).apply { record("s1") }
        val activity = CollectionActivityStore(File(filesDir, CollectionActivityStore.FILE_NAME))
            .apply { record(ActivityKind.ADD, "s1") }
        val svc = service(filesDir, history = history, activity = activity)

        svc.clearableCategories.forEach { svc.clear(it) }

        assertTrue(settingsFile.exists())
        assertTrue(settingsBytes.contentEquals(settingsFile.readBytes()))
    }
}

/** SVC-2: BURNS / STEMS categories measure the burn store and clear only what they own. */
class StorageServiceBurnsTest {
    private val filesDir = Files.createTempDirectory("pdj-storage-burns").toFile()

    private class NoArt : ArtworkCache {
        override fun diskSizeBytes() = 0L
        override fun clear() = Unit
    }

    private fun service(burns: Long = 0, stems: Long = 0, onBurns: () -> Unit = {}, onStems: () -> Unit = {}) = StorageService(
        catalogCacheDir = File(filesDir, "catalog-cache"),
        collectionsFile = File(filesDir, "c.json"),
        playHistoryFile = File(filesDir, "h.json"),
        activityFile = File(filesDir, "a.json"),
        artwork = NoArt(),
        clearCatalogCache = {}, clearPlayHistory = {}, clearActivity = {},
        burnsUsageBytes = { burns }, stemsUsageBytes = { stems },
        clearBurns = onBurns, clearStems = onStems,
    )

    @Test
    fun burnsAndStemsAreMeasuredAndClearable() = runTest {
        val s = service(burns = 900, stems = 40)
        val sizes = s.measureAll()
        assertEquals(900L, sizes[StorageService.Category.BURNS])
        assertEquals(40L, sizes[StorageService.Category.STEMS])
        assertTrue(StorageService.Category.BURNS in s.clearableCategories)
        assertTrue(StorageService.Category.STEMS in s.clearableCategories)
    }

    @Test
    fun deleteAllBurns_routesToTheWholeStoreClear_notAReadyOnlyIdList() = runTest {
        var burnsCleared = 0; var stemsCleared = 0
        val s = service(onBurns = { burnsCleared++ }, onStems = { stemsCleared++ })
        s.deleteAllBurns()
        assertEquals(1, burnsCleared); assertEquals(0, stemsCleared)
    }

    @Test
    fun clearingStemsDoesNotClearBurnsAndViceVersa() = runTest {
        var burnsCleared = 0; var stemsCleared = 0
        val s = service(onBurns = { burnsCleared++ }, onStems = { stemsCleared++ })
        s.clear(StorageService.Category.STEMS)
        assertEquals(0, burnsCleared); assertEquals(1, stemsCleared)
        s.clear(StorageService.Category.BURNS)
        assertEquals(1, burnsCleared)
    }

    @Test
    fun unwiredBurnsMeasureZeroAndClearIsANoOp() = runTest {
        val s = StorageService(File(filesDir, "x"), File(filesDir, "c"), File(filesDir, "h"), File(filesDir, "a"), NoArt(), {}, {}, {})
        assertEquals(0L, s.measure(StorageService.Category.BURNS))
        assertEquals(0L, s.clear(StorageService.Category.STEMS))
    }
}
