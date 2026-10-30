package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.rows
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ResumptionSnapshotTest {
    @get:Rule val tmp = TemporaryFolder()

    private val snap = SessionSnapshot(
        sessionId = "pses_X",
        source = SessionSourceRef("playlist", "set_now_playing", "Mix"),
        queue = listOf(SessionRow("a", "A", "x"), SessionRow("b", "B", "y", 1000), SessionRow("c", "C", "z")),
        index = 1, positionMs = 30_000,
    )

    @Test
    fun snapshot_projectsTheCurrentRow() {
        val r = ResumptionSnapshot.from(snap)!!
        assertEquals("b", r.songId)
        assertEquals("B", r.title)
        assertEquals("y", r.artist)
        assertEquals(1, r.index)
        assertEquals(3, r.queueSize)
        assertEquals(30_000L, r.positionMs)
    }

    @Test
    fun snapshot_clampsAWildIndex_andRejectsAnEmptyQueue() {
        assertEquals("c", ResumptionSnapshot.from(snap.copy(index = 50))!!.songId)
        assertNull(ResumptionSnapshot.from(snap.copy(queue = emptyList())))
    }

    @Test
    fun onPlaybackResumption_restoresHeld_neverPlays_neverWrites() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c")
        d.file.writeText(SessionSnapshot.encode(snap))
        d.file.setLastModified(1_400_000_000_000L)
        d.observe()
        val provider = ResumptionProvider(SessionRestorer(d.store, d.seq, disabled = { false }), d.store)
        val r = provider.onPlaybackResumption()
        d.h.settle()
        assertNotNull(r)
        assertEquals("b", r!!.songId)
        assertTrue(d.seq.isHeldForResume)
        assertTrue(d.h.port.loads.isEmpty())
        assertEquals(1_400_000_000_000L, d.file.lastModified()) // mtime moves only on a real play / edit
        // a second request while already held is idempotent
        provider.onPlaybackResumption()
        assertEquals(listOf("a", "b", "c"), d.seq.state.value.queue.map { it.id })
        assertEquals(1_400_000_000_000L, d.file.lastModified())
    }

    @Test
    fun onPlaybackResumption_withNothingPersisted_isNull() = runTest {
        val d = DurableHarness(this, tmp.root, "a")
        val provider = ResumptionProvider(SessionRestorer(d.store, d.seq, disabled = { false }), d.store)
        assertNull(provider.onPlaybackResumption())
        assertFalse(d.seq.isRunning)
    }

    @Test
    fun realEditAfterRestore_changesTheFile_butTheRestoreAloneDoesNot() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c")
        d.file.writeText(SessionSnapshot.encode(snap))
        d.file.setLastModified(1_400_000_000_000L)
        d.observe()
        SessionRestorer(d.store, d.seq, disabled = { false }).restoreIfIdle()
        assertEquals(1_400_000_000_000L, d.file.lastModified())
        d.seq.setRepeatMode(RepeatMode.ALL) // a held deck edit is still not a play: no write until resumed
        d.h.settle()
        assertEquals(1_400_000_000_000L, d.file.lastModified())
        d.seq.resumeFromHold(); d.h.settle()
        assertTrue(d.file.lastModified() > 1_400_000_000_000L)
        assertEquals("all", d.snapshotOnDisk()!!.repeatMode)
    }

    @Test
    fun materializeNowPlayingSetlist_buildsFromTheLiveQueue() {
        val store = CollectionsStore(File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        val q = listOf(
            CollectionsStore.QueueRowSnapshot("a", "A", "x", 100_000, 3),
            CollectionsStore.QueueRowSnapshot("b", "B", "y"),
        )
        assertNull(store.materializeNowPlayingSetlistIfMissing("Mix", emptyList()))
        val set = store.materializeNowPlayingSetlistIfMissing("Friday", q)!!
        assertEquals(NOW_PLAYING_SETLIST_ID, set.id)
        assertEquals(NOW_PLAYING_PLAYLIST_ID, set.playlistId)
        assertEquals("now-playing", set.seed)
        assertEquals("Friday", set.name)
        assertEquals(listOf("a", "b"), set.tracks.map { it.songId })
        assertEquals(listOf("A", "B"), set.tracks.map { it.name })
        assertEquals(100_000L, set.tracks[0].lengthMs)
        assertEquals(3, set.tracks[0].repeatCount)
        assertEquals(set.tracks.sumOf { it.shownMs }, set.totalMs)
        // an existing Now Playing setlist is returned as is (never rebuilt)
        val again = store.materializeNowPlayingSetlistIfMissing("Other", q.take(1))!!
        assertEquals(2, again.tracks.size)
        assertEquals(1, store.setlists.count { it.id == NOW_PLAYING_SETLIST_ID })
        assertTrue(rows("z").isNotEmpty())
    }

    @Test
    fun onPlaybackResumption_decodesTheFileOnce() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c")
        d.file.writeText(SessionSnapshot.encode(snap))
        val provider = ResumptionProvider(SessionRestorer(d.store, d.seq, disabled = { false }), d.store)
        val held = provider.loadHeld()!!
        provider.restore(held)
        assertEquals(1, held.index)
        assertEquals(listOf("a", "b", "c"), d.seq.state.value.queue.map { it.id })
        assertTrue(d.seq.isHeldForResume)
        assertEquals(1, d.store.loadCount) // loadHeld()+restore(): exactly one decode
        assertTrue(d.h.port.loads.isEmpty()) // restore is HELD: nothing reached the port
    }
}
