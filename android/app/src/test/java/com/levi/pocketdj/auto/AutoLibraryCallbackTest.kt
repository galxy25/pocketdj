package com.levi.pocketdj.auto

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AutoLibraryCallbackTest {
    private class RecordingPlayer(var failWith: Exception? = null) : AutoPlayer {
        val calls = mutableListOf<String>()
        private fun rec(s: String) { calls += s; failWith?.let { throw it } }
        override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) = rec("col:${ref.id}:shuffle=$shuffle")
        override suspend fun playSong(ref: AutoCollectionRef, songId: String) = rec("song:${ref.id}:$songId")
        override suspend fun playSolo(songId: String) = rec("solo:$songId")
        override suspend fun resumeHeld() = rec("resume")
    }

    private class AddSink : AutoAddSink {
        val added = mutableListOf<String>()
        override fun pockets() = listOf(AutoTarget(AutoTargetKind.POCKET, "k1", "Warmup"))
        override fun playlists() = listOf(AutoTarget(AutoTargetKind.PLAYLIST, "p1", "Gym"))
        override fun add(songId: String, kind: AutoTargetKind, targetId: String): Boolean { added += "$songId->$kind:$targetId"; return true }
    }

    private class Rig(val data: FakeAutoData = FakeAutoData(), val player: RecordingPlayer = RecordingPlayer()) {
        val sink = AddSink()
        val toasts = mutableListOf<String>()
        val notified = mutableListOf<String>()
        val notifiedCounts = mutableListOf<Int>()
        val carErrors = mutableListOf<String>()
        var warmUps = 0
        var recents: List<Pair<AutoTargetKind, String>> = emptyList()
        val cb = AutoLibraryCallback(
            tree = AutoBrowseTree(data),
            addTargets = AutoAddTargets(sink),
            player = player,
            scope = CoroutineScope(Dispatchers.Unconfined),
            toast = { toasts += it },
            notifyChildrenChanged = { p, n -> notified += p; notifiedCounts += n },
            carError = { carErrors += it },
            recentTargets = { recents },
            warmUp = { warmUps++ },
            catalogReady = { data.catalogReady },
        )
    }

    private fun rig(): Rig {
        val ref = pkRef("k1")
        return Rig(
            FakeAutoData(
                pockets = listOf(AutoCollectionInfo(ref, "Warmup", 2)),
                songs = mapOf("a" to mkSong("a"), "am" to mkSong("am", playable = false)),
                songIdsByRef = mapOf(ref to listOf("a", "am")),
            ),
        )
    }

    private fun Job?.await() { val j: Job = this ?: error("no job"); runBlocking { j.join() } }

    @Test fun connect_coldCatalog_warmsOnceAndNeverTouchesPlayerOrCollections() {
        val r = rig().also { it.data.catalogReady = false }
        r.cb.onConnect(); r.cb.onConnect()
        assertEquals(1, r.warmUps)
        assertTrue(r.player.calls.isEmpty())
        assertEquals(listOf("Loading…"), r.cb.getChildren(AutoId.Root.encoded, 0, 50)!!.map { it.title })
        assertEquals(0, r.data.heldReads) // not even the held-session read while cold
    }

    @Test fun connect_warmCatalog_doesNotWarmUp() {
        val r = rig(); r.cb.onConnect()
        assertEquals(0, r.warmUps)
        assertTrue(r.player.calls.isEmpty()) // no auto-play on connect
    }

    @Test fun catalogReady_notifiesRootAndTabsOnce() {
        val r = rig()
        r.cb.onCatalogReady(); r.cb.onCatalogReady()
        assertEquals(listOf("root", "tab:playlists", "tab:pockets"), r.notified)
    }

    @Test fun selectingSong_playsCollectionQueueAtThatSong() {
        val r = rig()
        r.cb.select(AutoId.Song(pkRef("k1"), "a").encoded).await()
        assertEquals(listOf("song:k1:a"), r.player.calls)
    }

    @Test fun playAllAndShuffleAll_dispatchToCollection() {
        val r = rig()
        r.cb.select(AutoId.PlayAll(pkRef("k1")).encoded).await()
        r.cb.select(AutoId.ShuffleAll(pkRef("k1")).encoded).await()
        assertEquals(listOf("col:k1:shuffle=false", "col:k1:shuffle=true"), r.player.calls)
    }

    @Test fun continueRow_resumesHeldOnTapOnly() {
        val r = rig().also { it.data.held = AutoHeld("t", "a") }
        assertTrue(r.cb.getChildren("root", 0, 10)!!.any { it.title == "Continue" })
        assertTrue(r.player.calls.isEmpty())
        r.cb.select(AutoId.Continue.encoded).await()
        assertEquals(listOf("resume"), r.player.calls)
    }

    @Test fun unplayableSong_neverAttemptsPlaybackAndToasts() {
        val r = rig()
        r.cb.select(AutoId.Song(pkRef("k1"), "am").encoded).await()
        assertTrue(r.player.calls.isEmpty())
        assertEquals(listOf(AutoBrowseTree.UNAVAILABLE), r.toasts)
    }

    @Test fun playerFailure_isToastedNotThrown() {
        val r = rig(); r.player.failWith = AutoPlayException("Warmup has no playable songs yet.")
        r.cb.select(AutoId.PlayAll(pkRef("k1")).encoded).await()
        assertEquals(listOf("Warmup has no playable songs yet."), r.toasts)
        r.player.failWith = IllegalStateException("boom")
        r.cb.select(AutoId.PlayAll(pkRef("k1")).encoded).await()
        assertEquals("Couldn't do that", r.toasts.last())
    }

    @Test fun nonActionRows_areConsumedWithoutPlaying_andForeignIdsAreNotOurs() {
        val r = rig()
        r.cb.select(AutoId.Loading.encoded).await()
        r.cb.select(AutoId.Tab(AutoId.Tab.Which.POCKETS).encoded).await()
        assertTrue(r.player.calls.isEmpty())
        assertNull(r.cb.select("someone-elses-id"))
        assertFalse(r.cb.isOurs("x"))
    }

    @Test fun addToChooser_listsTargetsAndTapAddsWithToast() {
        val r = rig()
        val rows = r.cb.getChildren(AutoId.AddTo("a").encoded, 0, 10)!!
        assertEquals(listOf("Warmup", "Gym"), rows.map { it.title })
        r.cb.select(rows[1].id).await()
        assertEquals(listOf("a->PLAYLIST:p1"), r.sink.added)
        assertEquals(listOf("Added to Gym"), r.toasts)
    }

    @Test fun addToAction_opensTheChooser_withoutAddingBlind_andRejectsNonSongs() {
        val r = rig()
        val node = r.cb.addToChooserNode(AutoId.Song(pkRef("k1"), "a").encoded)
        assertEquals(AutoId.AddTo("a").encoded, node)
        assertEquals(AutoId.AddTo("a").encoded, r.cb.addToChooserNode(AutoId.Solo("a").encoded))
        assertTrue(r.sink.added.isEmpty()) // nothing added until a target row is tapped
        // The returned node is reachable and lists targets (pockets then playlists); the tap is the add.
        val kids = r.cb.getChildren(node!!, 0, Int.MAX_VALUE)!!
        assertEquals(listOf("Warmup", "Gym"), kids.map { it.title })
        r.cb.select(kids[1].id)
        assertEquals(listOf("a->PLAYLIST:p1"), r.sink.added)
        assertNull(r.cb.addToChooserNode(AutoId.Root.encoded))
    }

    @Test fun carVisibleFailures_reachTheSessionNotJustThePhoneToast() {
        val r = rig()
        r.cb.select(AutoId.Solo("am").encoded)
        assertEquals(listOf(AutoBrowseTree.UNAVAILABLE), r.carErrors)
        r.player.failWith = AutoPlayException("Pocket has no playable songs yet.")
        r.cb.select(AutoId.PlayAll(pkRef("k1")).encoded)
        assertEquals(AutoBrowseTree.UNAVAILABLE, r.carErrors[0])
        assertEquals("Pocket has no playable songs yet.", r.carErrors[1])
        assertEquals(r.carErrors, r.toasts.takeLast(2)) // phone toast kept as the secondary signal
    }

    @Test fun libraryChanged_notifiesWithRealItemCounts_andOnlyAfterReady() {
        val r = rig()
        r.cb.notifyLibraryChanged()
        assertTrue(r.notified.isEmpty()) // nothing to refresh before the tree was ever served
        r.cb.onCatalogReady()
        r.notified.clear(); r.notifiedCounts.clear()
        r.cb.notifyLibraryChanged(AutoId.Collection(pkRef("k1")).encoded)
        assertEquals(listOf("root", "tab:playlists", "tab:pockets", AutoId.Collection(pkRef("k1")).encoded), r.notified)
        assertTrue(r.notifiedCounts.all { it > 0 })
    }

    @Test fun search_returnsCollectionsThenSongs() {
        val r = rig()
        r.data.songs = mapOf("w" to mkSong("w").copy(title = "Warmup song"))
        assertEquals(listOf("Warmup", "Warmup song"), r.cb.search("warmup").map { it.title })
    }
}
