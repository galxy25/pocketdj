package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.data.recs.RecFeedbackStore.Surface
import com.levi.pocketdj.data.recs.RecFeedbackStore.Verdict
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NowPlayingFeedbackTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val tmp = kotlin.io.path.createTempDirectory("npfb").toFile()
    private val fb = RecFeedbackStore(File(tmp, "fb.json"), scope, File(tmp, "id"), saveDebounceMs = 1)

    @After fun cleanup() { tmp.deleteRecursively() }

    private fun seq(vararg ids: String, index: Int = 0, running: Boolean = true, held: Boolean = false) =
        SequencerState(queue = ids.map { QueueItem(it) }, index = index, isRunning = running, isHeldForResume = held)

    private class Rig(val np: NowPlayingFeedback, val adds: MutableList<Pair<String, String>>, var state: SequencerState, var mix: Boolean)

    private fun rig(initial: SequencerState, addResult: Boolean = true): Rig {
        val adds = mutableListOf<Pair<String, String>>()
        lateinit var r: Rig
        val np = NowPlayingFeedback(
            feedback = fb, sequencer = { r.state }, mixSessionActive = { r.mix }, catalog = { null },
            addAccepted = { s, sc -> adds += s to sc; addResult },
        )
        r = Rig(np, adds, initial, false)
        return r
    }

    @Test fun targetIsCurrentRowPlusScope() {
        fb.beginPlayback("col1", listOf("a", "b", "c"))
        val r = rig(seq("a", "b", "c", index = 1))
        assertEquals(NowPlayingFeedback.Target("b", "col1"), r.np.currentTarget())
        r.state = seq("a", "b", "c", index = 2)
        assertEquals("c", r.np.currentTarget()?.songId)
    }

    @Test fun noTargetWhenNotOwnedOrNotInScope() {
        fb.beginPlayback("col1", listOf("a", "b"))
        val r = rig(seq("a", "b"))
        r.mix = true; assertNull(r.np.currentTarget())              // Mix owns the deck
        r.mix = false
        r.state = seq("a", "b", running = false); assertNull(r.np.currentTarget())
        r.state = seq("a", "b", held = true); assertNull(r.np.currentTarget()) // held: no audio
        r.state = seq("x", "y"); assertNull(r.np.currentTarget())    // a normal playlist, not in the stamped list
        r.state = seq("a", "b", index = 5); assertNull(r.np.currentTarget())
        assertNull(r.np.record(Verdict.ACCEPTED, Surface.NOW_PLAYING)) // nothing recorded on null
        assertEquals(0, fb.decisionsSince(0.0).size)
    }

    @Test fun noScopeStampedMeansNoTarget() {
        assertNull(rig(seq("a")).np.currentTarget())
    }

    @Test fun secondTapClearsAndUndoNeverAdds() {
        fb.beginPlayback("col1", listOf("a"))
        val r = rig(seq("a"))
        assertEquals(Verdict.ACCEPTED, r.np.record(Verdict.ACCEPTED, Surface.NOW_PLAYING))
        assertEquals(Verdict.ACCEPTED, r.np.currentVerdict())
        assertEquals(listOf("a" to "col1"), r.adds)
        assertNull(r.np.record(Verdict.ACCEPTED, Surface.NOW_PLAYING)) // the undo tap
        assertNull(r.np.currentVerdict())
        assertEquals(1, r.adds.size) // undo never adds again (and never un-adds)
        val last = fb.decisionsSince(0.0).maxBy { it.seq }
        assertEquals("cleared", last.verdict)
        assertEquals("nowPlaying", last.surface)
    }

    @Test fun rejectNeverAddsAndSticks() {
        fb.beginPlayback("col1", listOf("a"))
        val r = rig(seq("a"))
        assertEquals(Verdict.REJECTED, r.np.record(Verdict.REJECTED, Surface.NOW_PLAYING))
        assertTrue(r.adds.isEmpty())
        assertEquals(Verdict.REJECTED, r.np.currentVerdict())
        // flipping 👎 -> 👍 lands accepted and adds
        assertEquals(Verdict.ACCEPTED, r.np.record(Verdict.ACCEPTED, Surface.NOW_PLAYING))
        assertEquals(1, r.adds.size)
    }

    @Test fun addOnAcceptGoesThroughRealStoreAndReservedScopesStayPure() {
        val f = File(tmp, CollectionsStore.FILE_NAME)
        val store = CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = VersionedJsonWriter(f))
        val pocket = store.createPocket("Crate", listOf("z"))
        assertTrue(store.addAcceptedSong("a", pocket.id))
        assertTrue("a" in store.pocket(pocket.id)!!.songIds)
        assertFalse(store.addAcceptedSong("a", "zone"))
        assertFalse(store.addAcceptedSong("a", "new"))
        assertFalse(store.addAcceptedSong("a", "dead-id"))
    }

    @Test fun repeatAcceptNeverDuplicatesMembership() {
        val f = File(tmp, CollectionsStore.FILE_NAME)
        val store = CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = VersionedJsonWriter(f))
        val pl = store.createPlaylist("PL")
        assertTrue(store.addAcceptedSong("a", pl.id))
        assertFalse(store.addAcceptedSong("a", pl.id))
        fun cnt(ns: List<com.levi.pocketdj.data.collections.PlaylistNode>): Int =
            ns.sumOf { (if (it.songId == "a") 1 else 0) + cnt(it.children ?: emptyList()) }
        assertEquals(1, cnt(store.playlist(pl.id)!!.sequences))
        val pocket = store.createPocket("Crate", listOf("z"))
        assertTrue(store.addAcceptedSong("a", pocket.id))
        assertFalse(store.addAcceptedSong("a", pocket.id))
        assertEquals(1, store.pocket(pocket.id)!!.songIds.count { it == "a" })
        assertFalse(store.addAcceptedSong("z", pocket.id)) // pre-existing member
    }

    @Test fun zoneScopeRecordsFeedbackButAddsNothingInStore() {
        val f = File(tmp, CollectionsStore.FILE_NAME)
        val store = CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = VersionedJsonWriter(f))
        fb.beginPlayback("zone", listOf("a"))
        var state = seq("a")
        val np = NowPlayingFeedback(fb, { state }, { false }, { null }, store::addAcceptedSong)
        assertEquals(Verdict.ACCEPTED, np.record(Verdict.ACCEPTED, Surface.NOW_PLAYING))
        assertEquals(Verdict.ACCEPTED, fb.verdict("a", "zone"))
        assertTrue(store.state.value.pockets.isEmpty() && store.state.value.playlists.isEmpty())
    }

    private fun rows(vararg ids: String) = ids.map { com.levi.pocketdj.data.collections.SetlistTrack(songId = it, name = it) }

    @Test fun playbackReplacedRetiresScopeThenTileRestampsAfter() {
        val f = File(tmp, CollectionsStore.FILE_NAME)
        val store = CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = VersionedJsonWriter(f))
        store.onPlaybackReplaced = { fb.endPlaybackScope() }
        fb.beginPlayback("col1", listOf("a", "b"))
        // a normal play replaces the queue -> the scope dies with it
        store.playNowRows(rows("a", "b"), "Mix")
        assertNull(fb.scopeForPlaying("a"))
        // a tile play: playNow FIRST (retires), beginPlayback AFTER (iOS order) -> scope survives
        store.playNowRows(rows("a", "b"), "Tile")
        fb.beginPlayback("col1", listOf("a", "b"))
        assertEquals("col1", fb.scopeForPlaying("a"))
        // the wrong (pre-fix) order would have lost it
        store.playNowRows(rows("a"), "Other")
        assertNull(fb.scopeForPlaying("a"))
    }
}
