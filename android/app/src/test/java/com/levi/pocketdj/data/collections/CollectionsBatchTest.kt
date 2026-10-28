package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CollectionsBatchTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store(writer: VersionedJsonWriter? = null): CollectionsStore {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        return CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = writer ?: VersionedJsonWriter(f))
    }

    private fun ids(vararg n: Int) = n.map { "sng_$it" }

    @Test
    fun pocketBatchDedupes() {
        val s = store()
        val p = s.createPocket("P")
        s.addSongToPocket("sng_2", p.id)
        val t = AddTarget(AddTarget.Kind.POCKET, p.id)
        assertEquals(2, s.addSongs(ids(1, 2, 3, 1), t)) // existing + in-batch dupes dropped
        assertEquals(ids(2, 1, 3), s.pocket(p.id)!!.songIds)
    }

    @Test
    fun playlistWholeCollectionDedupe() {
        val s = store()
        val pl = s.createPlaylist("PL")
        s.addSequence("Two", pl.id)
        val seq2 = s.playlist(pl.id)!!.sequences[1].nodeId
        s.addSongToPlaylist("sng_1", pl.id, seq2)
        val first = s.playlist(pl.id)!!.sequences[0].nodeId
        val n = s.addSongs(ids(1, 2), AddTarget(AddTarget.Kind.PLAYLIST, pl.id, first), CollectionsStore.BatchDedupe.WHOLE_COLLECTION)
        assertEquals(1, n)
        assertEquals(listOf("sng_2"), s.playlist(pl.id)!!.sequences[0].children!!.map { it.songId })
    }

    @Test
    fun playlistTargetChapterDedupe() {
        val s = store()
        val pl = s.createPlaylist("PL")
        s.addSequence("Two", pl.id)
        val seqs = s.playlist(pl.id)!!.sequences
        s.addSongToPlaylist("sng_1", pl.id, seqs[1].nodeId)
        val n = s.addSongs(ids(1, 2), AddTarget(AddTarget.Kind.PLAYLIST, pl.id, seqs[0].nodeId), CollectionsStore.BatchDedupe.TARGET_CHAPTER)
        assertEquals(2, n)
    }

    @Test
    fun emptySequencesSelfHeal() {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        val doc = CollectionsDocument(
            playlists = listOf(Playlist(id = "pl_x", name = "Bare", sequences = emptyList(), createdAt = 1.0, updatedAt = 1.0)),
        )
        f.writeText(CollectionsCodec.encode(com.levi.pocketdj.data.PdjJson.lenient, doc))
        val s = CollectionsStore(f)
        assertTrue(s.playlist("pl_x")!!.sequences.isEmpty())
        assertEquals(2, s.addSongs(ids(1, 2), AddTarget(AddTarget.Kind.PLAYLIST, "pl_x")))
        val seqs = s.playlist("pl_x")!!.sequences
        assertEquals(1, seqs.size)
        assertEquals(2, seqs[0].children!!.size)
    }

    @Test
    fun zeroAddedNoSideEffects() {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        val w = VersionedJsonWriter(f)
        val s = store(w)
        val p = s.createPocket("P")
        s.addSongToPocket("sng_1", p.id)
        val before = w.writeCount
        var hooks = 0
        s.onActivityBatch = { hooks++ }
        s.onActivity = { hooks++ }
        assertEquals(0, s.addSongs(ids(1), AddTarget(AddTarget.Kind.POCKET, p.id)))
        assertEquals(before, w.writeCount)
        assertEquals(0, hooks)
        assertNull(s.lastAddTarget)
        assertTrue(s.recentAddTargets.isEmpty())
    }

    @Test
    fun oneActivityBatchPerGesture() {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        val w = VersionedJsonWriter(f)
        val s = store(w)
        val p = s.createPocket("P")
        val before = w.writeCount
        val batches = mutableListOf<List<CollectionsStore.ActivityHook>>()
        var singles = 0
        s.onActivityBatch = { batches += it }
        s.onActivity = { singles++ }
        assertEquals(500, s.addSongs((1..500).map { "sng_$it" }, AddTarget(AddTarget.Kind.POCKET, p.id)))
        assertEquals(1, batches.size)
        assertEquals(500, batches[0].size)
        assertEquals(0, singles)
        assertEquals(before + 1, w.writeCount) // ONE document write
        assertEquals(500, CollectionsStore(f).pocket(p.id)!!.songIds.size)
        // Fallback: batch seam unwired -> N singles.
        s.onActivityBatch = null
        s.addSongs(listOf("a", "b", "c"), AddTarget(AddTarget.Kind.POCKET, p.id))
        assertEquals(3, singles)
    }

    @Test
    fun removeSongsPrunesNestedAcrossChaptersInOneMutate() {
        val s = store()
        val pl = s.createPlaylist("PL")
        s.addSequence("Two", pl.id)
        val seqs = s.playlist(pl.id)!!.sequences
        s.addSongToPlaylist("sng_1", pl.id, seqs[0].nodeId)
        s.addSongToPlaylist("sng_1", pl.id, seqs[1].nodeId)
        s.addSongToPlaylist("sng_2", pl.id, seqs[1].nodeId)
        s.addSongToPlaylist("sng_3", pl.id, seqs[1].nodeId)
        val batches = mutableListOf<List<CollectionsStore.ActivityHook>>()
        s.onActivityBatch = { batches += it }
        assertEquals(2, s.removeSongsFromPlaylist(listOf("sng_1", "sng_2", "nope"), pl.id))
        val left = s.playlist(pl.id)!!.sequences.flatMap { it.children.orEmpty() }.mapNotNull { it.songId }
        assertEquals(listOf("sng_3"), left)
        assertEquals(1, batches.size)
        assertEquals(CollectionsStore.ActivityHook.Kind.REMOVE, batches[0][0].kind)
    }

    @Test
    fun activityRecordAllIsOneWrite() {
        val f = File(tmp.root, "act.json")
        val w = VersionedJsonWriter(f)
        val a = CollectionActivityStore(f, writer = w)
        val before = w.writeCount
        val n = a.recordAll(ActivityKind.ADD, listOf(
            CollectionActivityStore.Entry("a"), CollectionActivityStore.Entry("b"), CollectionActivityStore.Entry(""),
        ))
        assertEquals(2, n)
        assertEquals(before + 1, w.writeCount)
        assertEquals(2, a.events.size)
    }

    @Test
    fun flushNowPersistsLatestWithBackgroundBacklog() {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        val pending = ArrayDeque<Runnable>()
        val w = VersionedJsonWriter(f) { pending.addLast(it) }
        val s = CollectionsStore(f, writer = w)
        val p = s.createPocket("P")
        s.addSongs(ids(1, 2, 3), AddTarget(AddTarget.Kind.POCKET, p.id))
        s.flushNow()
        pending.forEach { it.run() } // stragglers all dropped
        assertEquals(3, CollectionsStore(f).pocket(p.id)!!.songIds.size)
    }
}
