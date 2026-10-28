package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.storage.StorageService.Category
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.TestEnv
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageServiceStudioTest {
    private val dir = Files.createTempDirectory("pdj-stu-storage").toFile()
    private val env = TestEnv(dir)
    private val store = env.store()

    private fun service(): StorageService {
        val f = java.io.File(dir, "fd").also { it.mkdirs() }
        return StorageService(
            catalogCacheDir = java.io.File(f, "c"), collectionsFile = java.io.File(f, "c.json"),
            playHistoryFile = java.io.File(f, "h.json"), activityFile = java.io.File(f, "a.json"),
            artwork = object : ArtworkCache { override fun diskSizeBytes() = 0L; override fun clear() {} },
            clearCatalogCache = {}, clearPlayHistory = {}, clearActivity = {},
            studioOps = object : StorageService.StudioStorageOps {
                override fun usageBytes(family: StudioFamily) = store.usageBytes(family)
                override fun deleteAll(family: StudioFamily) { store.deleteAll(family) }
                override fun recordCount(family: StudioFamily) = if (family == StudioFamily.SAMPLES) store.samples.size else 0
            },
        )
    }

    private fun seed() {
        store.addSample(StudioSample("smp_a", "A", env.write(StudioFamily.SAMPLES, "smp_a", bytes = 100)))
        store.addSample(StudioSample("smp_u", "U", env.write(StudioFamily.SAMPLES, "smp_u", user = true, bytes = 40), wasUserFolder = true))
        store.addLoop(StudioLoop("lp_a", "L", "smp_a", fileName = env.write(StudioFamily.LOOPS, "lp_a", bytes = 70)))
    }

    @Test fun studioCategoriesMapToFamiliesAndAreClearable() {
        assertEquals(StudioFamily.SAMPLES, Category.STUDIO_SAMPLES.studioFamily)
        assertEquals(StudioFamily.INSTRUMENTS, Category.STUDIO_INSTRUMENTS.studioFamily)
        assertNull(Category.BURNS.studioFamily)
        assertTrue(Category.entries.filter { it.studioFamily != null }.all { it.clearable })
    }

    @Test fun measureReportsPerFamilyBytes() = runTest {
        seed(); env.configured += StudioFamily.SAMPLES
        val s = service()
        assertEquals(140L, s.measure(Category.STUDIO_SAMPLES))
        assertEquals(70L, s.measure(Category.STUDIO_LOOPS))
        assertEquals(0L, s.measure(Category.STUDIO_TAKES))
    }

    @Test fun clearOneFamilyLeavesTheOthers() = runTest {
        seed()
        val s = service()
        s.clear(Category.STUDIO_SAMPLES)
        assertNull(store.sample("smp_a"))
        assertNotNull(store.loop("lp_a"))
        assertEquals(70L, s.measure(Category.STUDIO_LOOPS))
    }

    @Test fun deleteAllKeepsRecordsOnAnUnreachableRoot() = runTest {
        seed(); env.configured += StudioFamily.SAMPLES; env.unreachable += StudioFamily.SAMPLES
        service().clear(Category.STUDIO_SAMPLES)
        assertNull(store.sample("smp_a"))
        assertNotNull(store.sample("smp_u"))   // its root could not be checked: record kept
    }

    @Test fun deleteAllSkipsTheRecordersActiveTake() = runTest {
        val n = env.write(StudioFamily.TAKES, "tk_live", bytes = 30)
        store.addTake(com.levi.pocketdj.studio.model.StudioTake("tk_live", "Live", fileName = n))
        store.activeTakeFileName = { n }
        service().clear(Category.STUDIO_TAKES)
        assertTrue(env.appFile(StudioFamily.TAKES, n).isFile)
    }

    @Test fun unwiredServiceMeasuresZero() = runTest {
        val f = java.io.File(dir, "x")
        val s = StorageService(f, f, f, f, object : ArtworkCache { override fun diskSizeBytes() = 0L; override fun clear() {} }, {}, {}, {})
        assertEquals(0L, s.measure(Category.STUDIO_LOOPS))
        assertFalse(s.clear(Category.STUDIO_LOOPS) > 0)
    }

    @Test fun studioRecordCountReflectsRecordsEvenWhenBytesAreZero() {
        seed()
        assertTrue(service().studioRecordCount(StorageService.Category.STUDIO_SAMPLES) > 0)
        assertEquals(0, service().studioRecordCount(StorageService.Category.STUDIO_LOOPS))
        assertEquals(0, service().studioRecordCount(StorageService.Category.ACTIVITY))
    }
}
