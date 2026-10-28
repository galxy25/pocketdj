package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.history.PlayHistoryStore
import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/** The reloadFromDisk seams of the stores the sync engine pulls into, alone and under the engine. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReloadMergeTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun copyOver(from: File, to: File) { to.writeBytes(from.readBytes()) }

    // ---- activity: union by event id ---------------------------------------------------------

    @Test fun activityUnionsByIdKeepsInstallIdAndResavesSuperset() {
        val mine = File(tmp.root, "mine.json"); val peer = File(tmp.root, "peer.json")
        val a = CollectionActivityStore(mine); val b = CollectionActivityStore(peer)
        a.record(ActivityKind.ADD, "song-a", atMs = 1_000.0)
        b.record(ActivityKind.ADD, "song-b", atMs = 2_000.0)
        val myInstall = a.installId
        copyOver(peer, mine) // the pull
        val resaved = a.reloadFromDisk()
        assertTrue("we hold a row the pulled doc lacks, so the superset must be re-saved", resaved)
        assertEquals(listOf("song-a", "song-b"), a.events.map { it.itemId })
        assertEquals(myInstall, a.installId)
        // The file on disk is the superset (a fresh store reads both rows).
        assertEquals(2, CollectionActivityStore(mine).events.size)
    }

    @Test fun activityNoopMergeLeavesFileCleanSoPushLoopTerminates() {
        val mine = File(tmp.root, "mine.json"); val peer = File(tmp.root, "peer.json")
        val b = CollectionActivityStore(peer)
        b.record(ActivityKind.ADD, "x", atMs = 1.0)
        copyOver(peer, mine)
        val a = CollectionActivityStore(mine) // already equals the peer log
        val before = mine.readBytes()
        assertFalse(a.reloadFromDisk())
        assertTrue(before.contentEquals(mine.readBytes()))
    }

    @Test fun activityTakesPeerRowsWithoutResaveWhenWeHoldNothingExtra() {
        val mine = File(tmp.root, "mine.json"); val peer = File(tmp.root, "peer.json")
        val a = CollectionActivityStore(mine)
        val b = CollectionActivityStore(peer)
        b.record(ActivityKind.ADD, "p1", atMs = 5.0)
        copyOver(peer, mine)
        val rev = a.revision
        // a holds zero events of its own, so the pulled doc is already the superset.
        assertFalse(a.reloadFromDisk())
        assertEquals(listOf("p1"), a.events.map { it.itemId })
        assertTrue(a.revision > rev)
    }

    @Test fun activityMergeUnderEngineClearsWatermarkAndPublishesSuperset() = runTest {
        val mine = File(tmp.root, "act.json"); val peer = File(tmp.root, "peer.json")
        val a = CollectionActivityStore(mine); val b = CollectionActivityStore(peer)
        a.record(ActivityKind.ADD, "local", atMs = 1.0)
        b.record(ActivityKind.ADD, "remote", atMs = 2.0)
        mine.setLastModified(1_000_000_000_000L)
        val db = InMemoryCloudDocDatabase()
        db.put(CloudDoc("collection-activity", peer.readBytes(), 1_000_000_010_000.0, "iPhone"))
        val svc = CloudSyncService(db, { true }, File(tmp.root, "state.json"), backgroundScope)
        svc.register("collection-activity", mine, reload = { a.reloadFromDisk() })
        svc.syncNow()
        assertNull(svc.watermark("collection-activity")) // merge re-saved: watermark cleared
        assertEquals(listOf("local", "remote"), a.events.map { it.itemId }.sorted().reversed().sortedBy { if (it == "local") 0 else 1 })
        svc.syncNow()
        assertEquals(listOf("collection-activity"), db.saved) // superset published next pass
        assertEquals(2, CollectionActivityStore(File(tmp.root, "check.json").also { it.writeBytes(db.get("collection-activity")!!.payload) }).events.size)
    }

    // ---- history: union + monotone field merge -----------------------------------------------

    @Test fun historyUnionsAndMergesMonotoneFields() {
        val mine = File(tmp.root, "h-mine.json"); val peer = File(tmp.root, "h-peer.json")
        val a = PlayHistoryStore(mine); val b = PlayHistoryStore(peer)
        val shared = a.record("s1", title = "T", nowMs = 1_000_000)!!
        a.noteListened(shared.id, 0.2); a.flush()
        // The peer saw the SAME event id (it pulled our log earlier), then skipped it and heard more.
        copyOver(mine, peer)
        val b2 = PlayHistoryStore(peer)
        b2.noteListened(shared.id, 0.9)
        b2.markSkipped(shared.id); b2.flush()
        b2.record("s2", nowMs = 2_000_000)
        copyOver(peer, mine) // pull
        a.reloadFromDisk()
        val byId = a.events.associateBy { it.id }
        assertEquals(2, a.events.size)
        assertEquals(true, byId[shared.id]!!.wasSkipped)
        assertEquals(0.9, byId[shared.id]!!.listenedFraction)
        assertEquals(1, a.playCount("s2"))
        b.flush()
    }

    @Test fun historyKeepsOwnInstallIdAndOnlyResavesWhenItHoldsSomethingExtra() {
        val mine = File(tmp.root, "h-mine.json"); val peer = File(tmp.root, "h-peer.json")
        val a = PlayHistoryStore(mine); val b = PlayHistoryStore(peer)
        b.record("p", nowMs = 5_000_000)
        copyOver(peer, mine)
        val myId = a.installId
        val before = mine.readBytes()
        assertFalse("a holds nothing the pulled doc lacks: no re-save", a.reloadFromDisk())
        assertTrue(before.contentEquals(mine.readBytes()))
        assertEquals(myId, a.installId)
        assertEquals(1, a.events.size)
        // Now we play something new locally, then another pull of the (older) peer doc arrives.
        a.record("q", nowMs = 6_000_000)
        copyOver(peer, mine)
        assertTrue("local row missing from the pulled doc must be re-saved", a.reloadFromDisk())
        assertEquals(2, PlayHistoryStore(mine).events.size)
    }

    @Test fun historyResavesWhenOnlyAFlagIsMissingFromThePulledDoc() {
        val mine = File(tmp.root, "h-mine.json")
        val a = PlayHistoryStore(mine)
        val e = a.record("s", nowMs = 1_000_000)!!
        a.flush()
        val stale = mine.readBytes() // peer's copy: same row, no outcome fields
        a.noteListened(e.id, 0.8); a.flush()
        mine.writeBytes(stale)
        assertTrue(a.reloadFromDisk())
        assertEquals(0.8, PlayHistoryStore(mine).events.single().listenedFraction)
    }

    // ---- collections: whole-document replace -------------------------------------------------

    @Test fun collectionsReloadReplacesStateAndFiresOnChange() {
        val mine = File(tmp.root, "c-mine.json"); val peer = File(tmp.root, "c-peer.json")
        val a = CollectionsStore(mine); val b = CollectionsStore(peer)
        a.createPocket("Local Pocket")
        b.createPlaylist("Cloud Playlist")
        var changes = 0
        a.onChange = { changes++ }
        copyOver(peer, mine)
        val rev = a.state.value.revision
        assertTrue(a.reloadFromDisk())
        assertEquals(emptyList<String>(), a.pockets.map { it.name })
        assertEquals(listOf("Cloud Playlist"), a.playlists.map { it.name })
        assertTrue(a.state.value.revision > rev)
        assertEquals(1, changes)
    }

    @Test fun collectionsReloadOfUnreadableFileKeepsState() {
        val mine = File(tmp.root, "c-mine.json")
        val a = CollectionsStore(mine)
        a.createPocket("Keep")
        mine.writeText("{ not json")
        assertFalse(a.reloadFromDisk())
        assertEquals(listOf("Keep"), a.pockets.map { it.name })
    }

    @Test fun collectionsReloadInvalidatesQueuedStaleWrites() {
        val mine = File(tmp.root, "c-mine.json"); val peer = File(tmp.root, "c-peer.json")
        val queued = ArrayDeque<Runnable>()
        val a = CollectionsStore(mine, writer = com.levi.pocketdj.data.store.VersionedJsonWriter(mine) { queued.add(it) })
        val b = CollectionsStore(peer)
        a.createPocket("stale-edit") // write is QUEUED, not yet on disk
        b.createPlaylist("cloud")
        copyOver(peer, mine) // pull lands first
        a.reloadFromDisk()
        queued.forEach { it.run() } // the pre-pull write finally runs ...
        assertEquals(listOf("cloud"), CollectionsStore(mine).playlists.map { it.name }) // ... and must not clobber the pull
    }

    @Test fun performerNameIsMirroredState() {
        val a = CollectionsStore(File(tmp.root, "c.json"))
        assertEquals("", a.performerName)
        a.performerName = "DJ"
        assertEquals("DJ", a.performerName)
    }
}
