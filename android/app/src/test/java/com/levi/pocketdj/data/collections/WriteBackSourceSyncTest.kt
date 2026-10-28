package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.applemusic.ForceSyncMessages
import com.levi.pocketdj.data.applemusic.PlaylistWriteBack
import com.levi.pocketdj.data.applemusic.PlaylistWriteBackTransport
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The store-side write-back seams, wired to a REAL [PlaylistWriteBack] (fake transport): per-add
 * pocket/playlist, the eligibility guards (each reason -> its [WriteBackAttempt]), the direction
 * gate, the snapshot-never-advances invariant, batch confirm, link carry-over and the source-row path.
 */
class WriteBackSourceSyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Fake : PlaylistWriteBackTransport {
        override val isSupported = true
        val adds = mutableListOf<Pair<String, String>>()
        override suspend fun canWrite() = true
        override suspend fun resolvePlaylistId(name: String, expectedAppleMusicIds: List<String>) = "mk-$name"
        override suspend fun addSong(appleMusicId: String, toPlaylistId: String) { adds += appleMusicId to toPlaylistId }
    }

    private val transport = Fake()
    private lateinit var wb: PlaylistWriteBack
    private lateinit var store: CollectionsStore
    private var supported = true

    private fun song(id: String, am: String? = "am-$id", name: String = "Song $id", artist: String = "Art") =
        IndexSong(id = id, artist = artist, name = name, appleMusicId = am, length = 200_000)

    private fun setup(vararg songs: IndexSong, capable: Boolean = true): CollectionsStore {
        val merged = MergedCatalog.merge(
            listOf(IndexJson(manifest = IndexManifest(sourceName = "Apple Music (Local)"), songs = songs.toList())),
        )
        store = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        store.catalogProvider = { merged }
        wb = PlaylistWriteBack(File(tmp.root, PlaylistWriteBack.FILE_NAME), if (capable) transport else null, now = { 5.0 })
        // The same wiring as CollectionsGraph.wireWriteBack, minus the lazy graph.
        store.enqueueSourceWriteBack = { i ->
            if (!wb.canWriteBack) false
            else wb.enqueue(i.indexPlaylistId, i.playlistName, i.songId, i.appleMusicId, i.title, i.artist, i.album, i.durationMs) != null
        }
        store.enqueueSourceWriteBackBatch = { items -> if (wb.canWriteBack) wb.enqueueMany(items) else 0 }
        store.canWriteBackUpstream = { wb.canWriteBack }
        store.cancelPendingWriteBacks = { id, ids -> wb.cancelPending(id, ids) }
        return store
    }

    private fun src(vararg ids: String, name: String = "AM Mix", sourceName: String = "Apple Music (Local)") =
        SourcePlaylist(IndexPlaylist(id = "pl_src", name = name, songIds = ids.toList()), sourceName)

    private fun pocketTarget(id: String) = AddTarget(AddTarget.Kind.POCKET, id)
    private fun playlistTarget(id: String) = AddTarget(AddTarget.Kind.PLAYLIST, id)

    // ---- per-add: pocket + playlist ----
    @Test fun addToConvertedPocket_enqueuesOneJobWithIdentity() {
        setup(song("s1"), song("s2"))
        val p = store.convertSourceToPocket(src("s1"))
        store.addSong("s2", pocketTarget(p.id))
        val job = wb.jobs.single()
        assertEquals("pl_src", job.indexPlaylistId); assertEquals("AM Mix", job.playlistName)
        assertEquals("s2", job.songId); assertEquals("am-s2", job.appleMusicId)
        assertEquals("Song s2", job.title); assertEquals(200_000, job.durationMs)
    }

    @Test fun addToDuplicatedPlaylist_enqueuesToo() {
        setup(song("s1"), song("s2"))
        val pl = store.duplicateForSource(src("s1"))
        store.addSong("s2", playlistTarget(pl.id))
        assertEquals(listOf("s2"), wb.jobs.map { it.songId })
    }

    @Test fun identityOnlySongIsStillEnqueued() {
        setup(song("s1"), song("s2", am = null))
        val p = store.convertSourceToPocket(src("s1"))
        store.addSong("s2", pocketTarget(p.id))
        assertEquals("", wb.jobs.single().appleMusicId)
        assertEquals("Song s2", wb.jobs.single().title)
    }

    // ---- the four guards + each reason ----
    @Test fun ineligibleReasons_mapToWriteBackAttempt() {
        setup(song("s1"), song("s2"), song("blank", am = null, name = "", artist = ""), song("pdj_x"))
        val p = store.convertSourceToPocket(src("s1"))
        // 1. already upstream (in the snapshot): a plain add queues nothing; only FORCE gets past it
        store.addSong("s1", pocketTarget(p.id))
        assertTrue(wb.jobs.isEmpty())
        // 2. not catalog (profile id, unknown id, studio-shaped id)
        assertEquals(WriteBackAttempt.NOT_CATALOG_SONG, store.forceWriteBackSong("pdj_x", AddTarget.Kind.POCKET, p.id))
        assertEquals(WriteBackAttempt.NOT_CATALOG_SONG, store.forceWriteBackSong("missing", AddTarget.Kind.POCKET, p.id))
        // 3. no identity
        assertEquals(WriteBackAttempt.NO_IDENTITY, store.forceWriteBackSong("blank", AddTarget.Kind.POCKET, p.id))
        // 4. not linked (plain pocket / unknown collection / non-AM source)
        val plain = store.createPocket("Plain")
        assertEquals(WriteBackAttempt.NOT_LINKED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, plain.id))
        assertEquals(WriteBackAttempt.NOT_LINKED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, "nope"))
        val vinyl = store.convertSourceToPocket(src("s1", sourceName = "My Vinyl"))
        assertEquals(WriteBackAttempt.NOT_LINKED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, vinyl.id))
    }

    @Test fun nonForcePathSkipsSongsAlreadyInSnapshot_andForceOverridesIt() {
        setup(song("s1"))
        val p = store.convertSourceToPocket(src("s1"))
        // Re-adding via the batch/per-add paths: s1 is in the snapshot, nothing queues.
        store.addSong("s1", pocketTarget(p.id))
        assertTrue(wb.jobs.isEmpty())
        // Force bypasses the snapshot guard; the transport's own pre-check is the backstop.
        assertEquals(WriteBackAttempt.QUEUED, store.forceWriteBackSong("s1", AddTarget.Kind.POCKET, p.id))
        assertEquals(WriteBackAttempt.DEDUPED, store.forceWriteBackSong("s1", AddTarget.Kind.POCKET, p.id))
    }

    @Test fun directionGate_getOnlyAndOffNeverWriteUpstream_sendOnlyAndTwoWayDo() {
        setup(song("s1"), song("s2"), song("s3"))
        val p = store.convertSourceToPocket(src("s1"))
        store.setAMSyncDirectionForPocket(CollectionSyncDirection.PULL, p.id)
        store.addSong("s2", pocketTarget(p.id))
        assertTrue(wb.jobs.isEmpty())
        assertEquals(WriteBackAttempt.PUSH_DISABLED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, p.id))
        store.setAMSyncDirectionForPocket(CollectionSyncDirection.OFF, p.id)
        assertEquals(WriteBackAttempt.PUSH_DISABLED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, p.id))
        store.setAMSyncDirectionForPocket(CollectionSyncDirection.PUSH, p.id)
        store.addSong("s2", pocketTarget(p.id))
        assertEquals(1, wb.jobs.size)
        store.setAMSyncDirectionForPocket(CollectionSyncDirection.BOTH, p.id)
        store.addSong("s3", pocketTarget(p.id))
        assertEquals(2, wb.jobs.size)
    }

    @Test fun nonCapableSessionQueuesNothing_andReportsDeduped() {
        setup(song("s1"), song("s2"), capable = false)
        val p = store.convertSourceToPocket(src("s1"))
        store.addSong("s2", pocketTarget(p.id))
        assertTrue(wb.jobs.isEmpty())
        assertEquals(WriteBackAttempt.DEDUPED, store.forceWriteBackSong("s2", AddTarget.Kind.POCKET, p.id))
    }

    // ---- THE safety invariant ----
    @Test fun sourceSongIdsIsNeverAdvancedByADelivery() = runTest {
        setup(song("s1"), song("s2"))
        val p = store.convertSourceToPocket(src("s1"))
        val before = store.pocket(p.id)!!.sourceSongIds
        store.addSong("s2", pocketTarget(p.id))
        wb.run()
        assertEquals(PlaylistWriteBack.JobState.DELIVERED, wb.jobs.single().state)
        assertEquals(listOf("am-s2" to "mk-AM Mix"), transport.adds)
        assertEquals(before, store.pocket(p.id)!!.sourceSongIds)
        // ...and a source refresh that has NOT yet seen s2 does not classify it as a removal.
        store.syncConvertedCollections(listOf(src("s1")))
        assertTrue("s2" in store.pocket(p.id)!!.songIds)
    }

    @Test fun sourceRowAdd_queuesUnlessAlreadyUpstream() {
        setup(song("s1"), song("s2"))
        val first = store.addSongToIndexPlaylist("s2", src("s1"))
        assertTrue(first.writeBackEligible); assertTrue(first.writeBackQueued); assertFalse(first.alreadyUpstream)
        assertEquals(1, wb.jobs.size)
        val upstream = store.addSongToIndexPlaylist("s1", src("s1"))
        assertTrue(upstream.alreadyUpstream); assertFalse(upstream.writeBackQueued)
        assertEquals(1, wb.jobs.size)
        // sourceSongIds untouched by the source-row add too.
        assertEquals(listOf("s1"), first.playlist.sourceSongIds)
        // Non-AM source: not eligible.
        val vinyl = store.addSongToIndexPlaylist("s2", src("s1", sourceName = "My Vinyl"))
        assertFalse(vinyl.writeBackEligible)
    }

    @Test fun sourceRowAdd_localCopyHoldsItButUpstreamDoesNot_stillQueues_thenDedups() {
        setup(song("s1"), song("s2"))
        // Pre-COL-8 state: the duplicate already holds s2 (no job was ever queued).
        store.convertSourceToPocket(src("s1")) // unrelated; ensure store alive
        val pre = store.addSongToIndexPlaylist("s2", src("s1", sourceName = "My Vinyl")) // creates dup path w/o queue
        assertFalse(pre.writeBackQueued)
        assertEquals(0, wb.jobs.size)
        val again = store.addSongToIndexPlaylist("s2", src("s1"))
        assertTrue(again.alreadyPresent || again.createdDuplicate)
        assertTrue(again.writeBackQueued)
        val dup = store.addSongToIndexPlaylist("s2", src("s1"))
        assertTrue(dup.alreadyPresent); assertFalse(dup.writeBackQueued); assertTrue(dup.writeBackDeduped)
        assertEquals(1, wb.jobs.size)
    }

    @Test fun sourceRowAdd_noIdentityIsFlagged() {
        setup(song("s1"), song("s2", am = null, name = "", artist = ""))
        val r = store.addSongToIndexPlaylist("s2", src("s1"))
        assertFalse(r.writeBackEligible); assertTrue(r.writeBackNoIdentity)
    }

    // ---- batch + confirm ----
    private fun bigCatalog(n: Int) = (1..n).map { song("b$it") }.toTypedArray()

    @Test fun batchUnderThreshold_enqueuesOnce_noDialog() {
        setup(song("s1"), *bigCatalog(50))
        val p = store.convertSourceToPocket(src("s1"))
        assertEquals(50, store.addSongs((1..50).map { "b$it" }, pocketTarget(p.id)))
        assertNull(store.pendingWriteBackBatch.value)
        assertEquals(50, wb.jobs.size)
    }

    @Test fun batchOverFiftyParksBehindConfirm_confirmEnqueuesOnce() {
        setup(song("s1"), *bigCatalog(60))
        val p = store.convertSourceToPocket(src("s1"))
        store.addSongs((1..60).map { "b$it" }, pocketTarget(p.id))
        val pending = store.pendingWriteBackBatch.value
        assertNotNull(pending)
        assertEquals(60, pending!!.count); assertEquals("AM Mix", pending.playlistName)
        assertTrue(wb.jobs.isEmpty()) // local add landed, upstream waits
        assertEquals(60, store.pocket(p.id)!!.songIds.size - 1)
        store.confirmPendingWriteBackBatch()
        assertEquals(60, wb.jobs.size)
        assertNull(store.pendingWriteBackBatch.value)
        store.confirmPendingWriteBackBatch() // second confirm is a no-op
        assertEquals(60, wb.jobs.size)
    }

    @Test fun discardLeavesLocalAddIntactAndQueuesNothing() {
        setup(song("s1"), *bigCatalog(60))
        val p = store.convertSourceToPocket(src("s1"))
        store.addSongs((1..60).map { "b$it" }, pocketTarget(p.id))
        store.discardPendingWriteBackBatch()
        assertNull(store.pendingWriteBackBatch.value)
        assertTrue(wb.jobs.isEmpty())
        assertEquals(61, store.pocket(p.id)!!.songIds.size)
    }

    @Test fun nonCapableSessionNeverShowsTheDialog() {
        setup(song("s1"), *bigCatalog(60), capable = false)
        val p = store.convertSourceToPocket(src("s1"))
        store.addSongs((1..60).map { "b$it" }, pocketTarget(p.id))
        assertNull(store.pendingWriteBackBatch.value)
        assertEquals(61, store.pocket(p.id)!!.songIds.size)
    }

    @Test fun batchSkipsSnapshotSongsAndUnlinkedTargets() {
        setup(song("s1"), song("s2"))
        val p = store.convertSourceToPocket(src("s1"))
        store.removeSongFromPocket("s1", p.id)
        store.addSongs(listOf("s1", "s2"), pocketTarget(p.id)) // s1 is in the snapshot -> skipped
        assertEquals(listOf("s2"), wb.jobs.map { it.songId })
        val plain = store.createPocket("Plain")
        store.addSongs(listOf("s2"), pocketTarget(plain.id))
        assertEquals(1, wb.jobs.size)
    }

    // ---- link carry-over ----
    @Test fun relinkingAwayCancelsUndeliveredWriteBacksForThatPocketsSongs() {
        setup(song("s1"), song("s2"))
        val p = store.convertSourceToPocket(src("s1"))
        store.addSong("s2", pocketTarget(p.id))
        assertEquals(1, wb.pending.size)
        val other = SourcePlaylist(IndexPlaylist(id = "pl_other", name = "Other", songIds = listOf("s1")), "Apple Music (Local)")
        store.linkPocketToSource(p.id, other)
        assertTrue(wb.jobs.isEmpty())
    }

    // ---- UX copy ----
    @Test fun forceSyncMessagesDisambiguateDedupedAgainstQueueState() {
        assertEquals("Sending it to the linked Apple Music playlist now.", ForceSyncMessages.line(WriteBackAttempt.QUEUED, true, false))
        assertTrue(ForceSyncMessages.line(WriteBackAttempt.DEDUPED, false, false).contains("can’t be edited from this device"))
        assertTrue(ForceSyncMessages.line(WriteBackAttempt.DEDUPED, true, true).contains("no confident match"))
        assertTrue(ForceSyncMessages.line(WriteBackAttempt.DEDUPED, true, false).contains("already on its way"))
        assertTrue(ForceSyncMessages.line(WriteBackAttempt.PUSH_DISABLED, true, false).contains("Get only / Off"))
    }
}
