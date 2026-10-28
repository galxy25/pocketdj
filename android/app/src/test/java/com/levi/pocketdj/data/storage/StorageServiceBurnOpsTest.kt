package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.ArtistUsage
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** SVC-6 extensions of the clear contract: targeted burn/stem deletes touch media only. */
class StorageServiceBurnOpsTest {
    private class FakeOps : StorageService.BurnStorageOps {
        val burnDeletes = mutableListOf<List<String>>()
        val stemDeletes = mutableListOf<List<String>>()
        override fun usageByArtist() = listOf(ArtistUsage("Daft", listOf("s1", "s2"), 300))
        override fun stemUsageByArtist() = listOf(ArtistUsage("Daft", listOf("s1"), 90))
        override fun approximateBytes(ids: List<String>) = ids.size * 100L
        override fun removeBurns(songIds: List<String>) { burnDeletes += songIds }
        override fun removeStems(songIds: List<String>) { stemDeletes += songIds }
    }

    private fun svc(dir: File, ops: FakeOps, settings: File = File(dir, "pocketdj-settings.preferences_pb")): StorageService {
        val artwork = object : ArtworkCache { override fun diskSizeBytes() = 0L; override fun clear() {} }
        return StorageService(
            catalogCacheDir = File(dir, "catalog-cache"), collectionsFile = File(dir, "pocketdj-collections.json"),
            playHistoryFile = File(dir, "h.json"), activityFile = File(dir, "a.json"), artwork = artwork,
            clearCatalogCache = {}, clearPlayHistory = {}, clearActivity = {},
            burnsUsageBytes = { 1_000L }, stemsUsageBytes = { 90L }, burnOps = ops,
        )
    }

    @Test fun byArtistListsAndDeletesRouteToTheBurnStoreOnly() = runTest {
        val dir = Files.createTempDirectory("pdj-ops").toFile()
        val keep = listOf("pocketdj-collections.json", "pocketdj-settings.preferences_pb", "install-id").map {
            File(dir, it).apply { writeText("keep") }
        }
        val ops = FakeOps(); val s = svc(dir, ops)
        assertEquals("Daft", s.burnUsageByArtist().single().artist)
        assertEquals(90L, s.stemUsageByArtist().single().bytes)
        assertEquals(200L, s.approximateBurnBytes(listOf("a", "b")))
        assertEquals(1_000L, s.deleteBurns(listOf("s1", "s2")))
        s.deleteStems(listOf("s1"))
        assertEquals(listOf(listOf("s1", "s2")), ops.burnDeletes)
        assertEquals(listOf(listOf("s1")), ops.stemDeletes)
        assertTrue(keep.all { it.readText() == "keep" })           // collections/settings/installId untouched
    }

    @Test fun withoutBurnOpsEverythingIsAHarmlessNoOp() = runTest {
        val dir = Files.createTempDirectory("pdj-ops2").toFile()
        val artwork = object : ArtworkCache { override fun diskSizeBytes() = 0L; override fun clear() {} }
        val s = StorageService(File(dir, "c"), File(dir, "x"), File(dir, "h"), File(dir, "a"), artwork, {}, {}, {})
        assertTrue(s.burnUsageByArtist().isEmpty())
        assertEquals(0L, s.deleteBurns(listOf("s1")))
    }
}
