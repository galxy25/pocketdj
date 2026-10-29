package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.burns.ArtistUsage
import com.levi.pocketdj.screens.settings.storage.StorageLists
import com.levi.pocketdj.screens.settings.storage.UsageRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageListsTest {
    @Test fun fromArtists_labelsCountAndMegabytes() {
        val rows = StorageLists.fromArtists(listOf(ArtistUsage("Daft Punk", listOf("a", "b"), 12_500_000)))
        assertEquals(listOf(UsageRow("Daft Punk", "2 songs, 12 MB", listOf("a", "b"))), rows)
    }

    @Test fun fromCollections_sortsAZ_dropsUnburned_sizesReadyOnly() = runBlocking {
        val ready = setOf("s1", "s2", "s3")
        val rows = StorageLists.fromCollections(
            named = listOf(
                "zeta" to listOf("s1"),
                "Alpha" to listOf("s2", "x9", "s3"),
                "Empty" to listOf("x1"),
            ),
            readyOf = { ids -> ids.filter { it in ready } },
            bytesOf = { ids -> ids.size * 2_000_000L },
        )
        assertEquals(listOf("Alpha", "zeta"), rows.map { it.label })
        assertEquals("2 downloaded songs, 4 MB", rows[0].detail)
        assertEquals(listOf("s2", "s3"), rows[0].songIds)
    }

    @Test fun allSongIds_dedupesAcrossRows_forDeleteAll() {
        val rows = listOf(
            UsageRow("A", "", listOf("s1", "s2")),
            UsageRow("B", "", listOf("s2", "s3")),
        )
        assertEquals(listOf("s1", "s2", "s3"), StorageLists.allSongIds(rows))
        assertTrue(StorageLists.allSongIds(emptyList()).isEmpty())
    }

    @Test fun deleteAllCopy_namesCount() {
        assertEquals("Delete all burnt music", StorageLists.DELETE_ALL_LABEL)
        assertTrue(StorageLists.deleteAllBody(7).contains("7 downloaded songs"))
    }
}
