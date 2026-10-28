package com.levi.pocketdj.data.discover

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** BRW-16 review fixes: ledger row, persisted album settle state, persisted album remap. */
class BrwReviewFixesTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun e(id: String, album: String? = null) =
        DiscoverAddsStore.Entry(songId = id, appleMusicId = id.removePrefix("amrec_"), title = id, artist = "A", albumId = album, addedAtMs = 1.0)

    private fun album(tracks: List<String>) =
        DiscoverAddsStore.AlbumEntry(albumId = "amrec_album_1", appleMusicId = "1", title = "Al", artist = "A", trackIds = tracks, preparedCopies = true)

    @Test fun architectureLedgerRowForBrw16IsNoLongerPlanned() {
        val f = File("../docs/ARCHITECTURE-ANDROID.md").takeIf { it.exists() } ?: File("docs/ARCHITECTURE-ANDROID.md")
        if (!f.exists()) return
        val row = f.readLines().first { it.startsWith("| BRW-16 ") }
        assertFalse(row, row.contains("| Planned |"))
    }

    @Test fun failedTracksPersistAcrossRestartAndSettleToPartial() {
        val file = File(tmp.root, "d.json")
        val s = DiscoverAddsStore(file)
        s.addAlbumBatch(album(listOf("amrec_1", "amrec_2")), listOf(e("amrec_1", "amrec_album_1"), e("amrec_2", "amrec_album_1")))
        s.recordFailedTracks(setOf("amrec_2"))
        val reloaded = DiscoverAddsStore(file) // process restart: tracker memory is gone
        val state = DiscoverAddState.of(reloaded.albums.single(), readyIds = setOf("amrec_1"), erroredIds = emptySet())
        assertEquals(DiscoverAddState.Partial(1, 2), state)
    }

    @Test fun userRemoveDropsTrackFromAlbumSoItCanSettle() {
        val s = DiscoverAddsStore(File(tmp.root, "d.json"))
        s.addAlbumBatch(album(listOf("amrec_1", "amrec_2")), listOf(e("amrec_1", "amrec_album_1"), e("amrec_2", "amrec_album_1")))
        s.userRemove("amrec_2")
        assertEquals(listOf("amrec_1"), s.albums.single().trackIds)
        assertEquals(DiscoverAddState.Added, DiscoverAddState.of(s.albums.single(), setOf("amrec_1"), emptySet()))
    }

    @Test fun supersedeAlbumsPersistsRemappedAlbumIdOnSurvivors() {
        val file = File(tmp.root, "d.json")
        val s = DiscoverAddsStore(file)
        s.addAlbumBatch(album(listOf("amrec_1", "amrec_2")), listOf(e("amrec_1", "amrec_album_1"), e("amrec_2", "amrec_album_1")))
        s.supersedeAlbums(listOf("amrec_album_1" to "real_album"))
        val reloaded = DiscoverAddsStore(file)
        assertTrue(reloaded.albums.isEmpty())
        assertEquals(setOf("real_album"), reloaded.entries.map { it.albumId }.toSet())
    }
}
