package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.applemusic.PlaylistWriteBack
import com.levi.pocketdj.data.applemusic.WriteBackSettings
import com.levi.pocketdj.data.applemusic.WriteBackStatus
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** `backfillSourceWriteBacks`: window clamp, newest-first once per pair, peer skip, removed songs, idempotency. */
class WriteBackBackfillTest {
    @get:Rule val tmp = TemporaryFolder()

    private val now = 1_750_000_000_000.0
    private val day = 86_400_000.0
    private lateinit var wb: PlaylistWriteBack
    private lateinit var store: CollectionsStore
    private lateinit var pocketId: String

    private fun setup(capable: Boolean = true) {
        val songs = (1..6).map { IndexSong(id = "s$it", artist = "A", name = "Song $it", appleMusicId = "am$it") }
        val merged = MergedCatalog.merge(listOf(IndexJson(manifest = IndexManifest(sourceName = "Apple Music (Local)"), songs = songs)))
        store = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { now })
        store.catalogProvider = { merged }
        wb = PlaylistWriteBack(File(tmp.root, PlaylistWriteBack.FILE_NAME), null, now = { now })
        if (capable) {
            store.enqueueSourceWriteBack = { i ->
                wb.enqueue(i.indexPlaylistId, i.playlistName, i.songId, i.appleMusicId, i.title, i.artist, i.album, i.durationMs) != null
            }
        }
        val p = store.convertSourceToPocket(
            SourcePlaylist(IndexPlaylist(id = "pl_src", name = "AM Mix", songIds = listOf("s1")), "Apple Music (Local)"),
        )
        pocketId = p.id
        // The user added s2..s6 locally while "offline" (no per-add write-back) - raw primitive, no seam.
        listOf("s2", "s3", "s4", "s5", "s6").forEach { store.addSongToPocket(it, pocketId) }
    }

    private var evId = 0
    private fun add(item: String, ageDays: Double, origin: String? = null, cid: String? = pocketId, kind: String = "pocket") =
        ActivityEvent(
            id = "e${evId++}", at = now - ageDays * day, kind = ActivityKind.ADD, itemId = item,
            collectionId = cid, collectionKind = kind, originInstallId = origin,
        )

    @Test fun windowIsHonoured_andClampedTo1Through90() {
        setup()
        val events = listOf(add("s2", 0.5), add("s3", 1.5), add("s4", 40.0), add("s5", 200.0))
        // 1 day window: only s2.
        assertEquals(1, store.backfillSourceWriteBacks(events, days = 1, localInstallId = "me", nowMs = now))
        // days=0 clamps UP to 1 (nothing new), huge clamps DOWN to 90 (s3 + s4; s5 at 200d stays out).
        assertEquals(0, store.backfillSourceWriteBacks(events, days = 0, localInstallId = "me", nowMs = now))
        assertEquals(2, store.backfillSourceWriteBacks(events, days = 10_000, localInstallId = "me", nowMs = now))
        assertEquals(setOf("s2", "s3", "s4"), wb.jobs.map { it.songId }.toSet())
    }

    @Test fun clampHelperBounds() {
        assertEquals(1, WriteBackSettings.clampDays(-5))
        assertEquals(2, WriteBackSettings.clampDays(2))
        assertEquals(90, WriteBackSettings.clampDays(1000))
    }

    @Test fun idempotent_secondRunQueuesNothing() {
        setup()
        val events = listOf(add("s2", 0.1), add("s3", 0.2))
        assertEquals(2, store.backfillSourceWriteBacks(events, 2, "me", now))
        assertEquals(0, store.backfillSourceWriteBacks(events, 2, "me", now))
        assertEquals(2, wb.jobs.size)
    }

    @Test fun eachCollectionSongPairIsConsideredOnce() {
        setup()
        val events = listOf(add("s2", 1.0), add("s2", 0.5), add("s2", 0.1))
        assertEquals(1, store.backfillSourceWriteBacks(events, 2, "me", now))
    }

    @Test fun peerDeviceAddsAreSkipped_legacyAndLocalCount() {
        setup()
        val events = listOf(add("s2", 0.1, origin = "peer"), add("s3", 0.1, origin = "me"), add("s4", 0.1, origin = null))
        assertEquals(2, store.backfillSourceWriteBacks(events, 2, "me", now))
        assertEquals(setOf("s3", "s4"), wb.jobs.map { it.songId }.toSet())
    }

    @Test fun songsNoLongerMembersAreSkipped() {
        setup()
        store.removeSongFromPocket("s2", pocketId)
        val events = listOf(add("s2", 0.1), add("s3", 0.1))
        assertEquals(1, store.backfillSourceWriteBacks(events, 2, "me", now))
        assertEquals(listOf("s3"), wb.jobs.map { it.songId })
    }

    @Test fun songsAlreadyInTheSourceSnapshotAreSkipped() {
        setup()
        assertEquals(0, store.backfillSourceWriteBacks(listOf(add("s1", 0.1)), 2, "me", now))
    }

    @Test fun playlistCollectionsAreBackfilledViaMembershipCheck() {
        setup()
        val pl = store.duplicateForSource(
            SourcePlaylist(IndexPlaylist(id = "pl_src2", name = "Other", songIds = listOf("s1")), "Apple Music (Local)"),
        )
        store.addSongToPlaylist("s2", pl.id, pl.sequences.first().nodeId)
        val events = listOf(add("s2", 0.1, cid = pl.id, kind = "playlist"), add("s3", 0.1, cid = pl.id, kind = "playlist"))
        assertEquals(1, store.backfillSourceWriteBacks(events, 2, "me", now)) // s3 never became a member
        assertEquals("pl_src2", wb.jobs.single().indexPlaylistId)
    }

    @Test fun ignoresNonAddEventsAndEventsWithoutACollection() {
        setup()
        val remove = add("s2", 0.1).copy(kind = ActivityKind.REMOVE)
        val orphan = add("s3", 0.1, cid = null)
        assertEquals(0, store.backfillSourceWriteBacks(listOf(remove, orphan), 2, "me", now))
    }

    @Test fun unwiredSeamReturnsZero() {
        setup(capable = false)
        assertEquals(0, store.backfillSourceWriteBacks(listOf(add("s2", 0.1)), 2, "me", now))
        assertTrue(wb.jobs.isEmpty())
    }

    @Test fun statusLineCopy() {
        assertEquals("Adds: nothing new to send", WriteBackStatus.sendLine(true, 0))
        assertEquals("Adds: sending 1 song to Apple Music", WriteBackStatus.sendLine(true, 1))
        assertEquals("Adds: sending 3 songs to Apple Music", WriteBackStatus.sendLine(true, 3))
        assertEquals("1 day", WriteBackStatus.lookbackLabel(1))
        assertEquals("90 days", WriteBackStatus.lookbackLabel(90))
    }
}
