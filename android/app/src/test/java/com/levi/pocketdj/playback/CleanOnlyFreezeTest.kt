package com.levi.pocketdj.playback

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.SetlistTrack
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** iOS CollectionsStore.swift:2200 parity: a clean-only realize freezes the decision into the setlist. */
class CleanOnlyFreezeTest {
    @get:Rule val tmp = TemporaryFolder()
    private val store get() = CollectionsStore(File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })

    private fun song(id: String, explicit: Boolean?, clean: String?) =
        IndexSong(id = id, artist = "A", name = id, explicit = explicit, appleMusicId = "1", appleMusicIdClean = clean)

    private val songs = mapOf(
        "plain" to song("plain", false, null),
        "dirty" to song("dirty", true, "9"),
        "nocut" to song("nocut", true, null),
    )
    private fun setlist() = Setlist(
        tracks = listOf(
            SetlistTrack(songId = "plain", lengthMs = 1000),
            SetlistTrack(songId = "nocut", lengthMs = 2000),
            SetlistTrack(songId = "", name = "cue", isText = true),
            SetlistTrack(songId = "dirty", lengthMs = 4000),
            SetlistTrack(songId = "ghost", lengthMs = 8000),
        ),
    )

    @Test
    fun cleanOnly_dropsSkipped_stampsClean_andRecomputesTotal() {
        val out = store.freezeCleanOnly(setlist(), true, songs)
        assertEquals(listOf("plain", "", "dirty", "ghost"), out.tracks.map { it.songId })
        assertEquals(listOf(null, null, "clean", null), out.tracks.map { it.variant })
        assertEquals(out.tracks.sumOf { it.shownMs }, out.totalMs)
    }

    @Test
    fun notCleanOnly_isIdentity() {
        val s = setlist()
        assertEquals(s, store.freezeCleanOnly(s, false, songs))
    }

    @Test
    fun frozenVariantReachesTheQueueLocked() {
        val out = store.freezeCleanOnly(setlist(), true, songs)
        val items = QueuePlan.items(QueuePlan.entriesForSetlist(out))
        val dirty = items.single { it.id == "dirty" }
        assertEquals("dirty_clean", dirty.resolveId)
        assertTrue(dirty.editionLocked)
        assertEquals("plain", items.first().resolveId)
    }
}
