package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.jukebox.JukeboxDecisionAction
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.store.ManualScheduler
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.TestClock
import com.levi.pocketdj.mix.store.tempFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoQueueSeamsTest {
    private fun rig(n: Int = 8, store: MixDeckSessionStore? = null) = AutoRig(n = n, store = store)
    private fun extra(r: AutoRig, id: String) = AutoMixItem(r.h.addSong(id, 30.0), 30_000, "jukebox")
    private fun ids(r: AutoRig) = r.dj.queueSongIds

    // ---------------------------------------------------------------- reads

    @Test fun onAirIsTheLiveDeckWhileMixingElseTheAudiblyPlayingDeck() {
        val r = rig()
        assertEquals(null, r.dj.onAirTrack)
        r.e.load(r.h.addSong("hand", 20.0), Deck.B); r.e.play(Deck.B)
        assertEquals("hand", r.dj.onAirTrack!!.songId)
        r.start()
        assertEquals("s0", r.dj.onAirTrack!!.songId)
        r.run(25.0)
        assertEquals("s1", r.dj.onAirTrack!!.songId)
    }

    @Test fun onAirBufferingCoversTheLiveDeckAndTheIncomingDeckMidFade() {
        val r = rig()
        r.start(); r.run(3.0)
        assertFalse(r.dj.onAirBuffering)
        r.held += Deck.A
        assertTrue(r.dj.onAirBuffering)
        r.held.clear()
        r.run(18.0)                                     // fade under way into B
        assertTrue(r.dj.autoTransitioning)
        r.held += Deck.B
        assertTrue("incoming waiting with play intent", r.dj.onAirBuffering)
        r.held.clear(); r.run(5.0)
        assertFalse(r.dj.onAirBuffering)
    }

    @Test fun upcomingPlayedAndLockedCountTrackTheCursor() {
        val r = rig(n = 6)
        assertEquals("not mixing: empty", emptyList<String>(), r.dj.autoUpcoming.map { it.songId })
        assertEquals(0, r.dj.autoUpcomingLockedCount)
        r.start()
        assertEquals(listOf("s1", "s2", "s3", "s4", "s5"), r.dj.autoUpcoming.map { it.songId })
        assertTrue(r.dj.autoPlayed.isEmpty())
        assertEquals("s1 is on deck B", 1, r.dj.autoUpcomingLockedCount)
        assertEquals("jukebox/crate provenance rides along", "crate", r.dj.autoUpcomingDetailed.first().second)
        r.run(25.0)                                     // A -> B, s2 preloaded onto A
        assertEquals(listOf("s2", "s3", "s4", "s5"), r.dj.autoUpcoming.map { it.songId })
        assertEquals(listOf("s0"), r.dj.autoPlayed.map { it.songId })
        assertEquals("s2 committed on deck A", 1, r.dj.autoUpcomingLockedCount)
        r.run(20.0)
        assertEquals("newest first", listOf("s1", "s0"), r.dj.autoPlayed.map { it.songId })
        assertEquals(listOf("s1", "s0"), r.dj.autoPlayedDetailed.map { it.first.songId })
    }

    // ---------------------------------------------------------------- insert

    @Test fun insertNextLandsAtNextToLoadNeverBeforeTheCommittedDecks() {
        val r = rig(); r.start()
        r.dj.autoQueueInsert(extra(r, "req1"), JukeboxDecisionAction.NEXT)
        assertEquals("after s0 (live) and s1 (on deck B)", listOf("s0", "s1", "req1", "s2"), ids(r).take(4))
        r.run(25.0)                                      // advances; s2 is now the committed on-deck row
        r.dj.autoQueueInsert(extra(r, "req2"), JukeboxDecisionAction.NEXT)
        val q = ids(r)
        assertEquals("req1 was committed onto A", "req1", r.id(Deck.A))
        assertTrue("req2 sits behind everything a deck holds", q.indexOf("req2") >= r.dj.nextToLoad)
    }

    @Test fun insertEndAppends() {
        val r = rig(n = 3); r.start()
        r.dj.autoQueueInsert(extra(r, "req"), JukeboxDecisionAction.END)
        assertEquals(listOf("s0", "s1", "s2", "req"), ids(r))
    }

    @Test fun insertRandomUsesTheSlotRangeFromTheCommittedBoundToTheEnd() {
        val r = rig(n = 6); r.start()
        var seen: IntRange? = null
        r.dj.autoQueueInsert(extra(r, "req"), JukeboxDecisionAction.RANDOM) { seen = it; 4 }
        assertEquals(2..6, seen)
        assertEquals(4, ids(r).indexOf("req"))
        // an out-of-range pick can never displace a committed row
        r.dj.autoQueueInsert(extra(r, "low"), JukeboxDecisionAction.RANDOM) { -5 }
        assertEquals(2, ids(r).indexOf("low"))
        r.dj.autoQueueInsert(extra(r, "high"), JukeboxDecisionAction.RANDOM) { 999 }
        assertEquals("high", ids(r).last())
    }

    @Test fun deniedAndNotMixingAreNoOps() {
        val r = rig(n = 3)
        r.dj.autoQueueInsert(extra(r, "x"), JukeboxDecisionAction.END)
        assertEquals(0, r.dj.queueSize)
        r.start()
        r.dj.autoQueueInsert(extra(r, "y"), JukeboxDecisionAction.DENIED)
        assertEquals(listOf("s0", "s1", "s2"), ids(r))
    }

    @Test fun insertRefreshesTheCounterReadout() {
        val r = rig(n = 3); r.start()
        assertEquals("1 / 3 · Deck A", r.dj.autoStatus)
        r.dj.autoQueueInsert(extra(r, "req"), JukeboxDecisionAction.END)
        assertEquals("1 / 4 · Deck A", r.dj.autoStatus)
    }

    // ---------------------------------------------------------------- shuffle / remove / move

    @Test fun shuffleOnlyTouchesUncommittedRows() {
        val r = rig(n = 14); r.start()
        val before = ids(r)
        r.dj.autoQueueShuffleUpcoming()
        val after = ids(r)
        assertEquals("live + deck-B rows are committed", before.take(2), after.take(2))
        assertEquals(before.toSet(), after.toSet())
        assertEquals(before.size, after.size)
        assertNotEquals("the tail was actually permuted", before.drop(2), after.drop(2))
    }

    @Test fun shuffleWithOneOrZeroUncommittedRowsIsANoOp() {
        val r = rig(n = 3); r.start()
        val before = ids(r)
        r.dj.autoQueueShuffleUpcoming()                  // only s2 is uncommitted
        assertEquals(before, ids(r))
        val idle = rig(); idle.dj.autoQueueShuffleUpcoming()
        assertEquals(0, idle.dj.queueSize)
    }

    @Test fun removeIsANoOpOnCommittedAndOutOfRangeRows() {
        val r = rig(n = 6); r.start()
        r.dj.autoQueueRemoveUpcoming(0)                  // s1 is on deck B
        assertEquals(6, r.dj.queueSize)
        r.dj.autoQueueRemoveUpcoming(-1)
        r.dj.autoQueueRemoveUpcoming(99)
        assertEquals(6, r.dj.queueSize)
        r.dj.autoQueueRemoveUpcoming(1)                  // s2: first uncommitted
        assertEquals(listOf("s0", "s1", "s3", "s4", "s5"), ids(r))
    }

    @Test fun moveToNextAndToEndHonourTheCommittedBound() {
        val r = rig(n = 6); r.start()
        r.dj.autoQueueMoveUpcoming(0, toEnd = true)      // committed: no-op
        assertEquals(listOf("s0", "s1", "s2", "s3", "s4", "s5"), ids(r))
        r.dj.autoQueueMoveUpcoming(3, toEnd = false)     // s4 -> next uncommitted slot
        assertEquals(listOf("s0", "s1", "s4", "s2", "s3", "s5"), ids(r))
        r.dj.autoQueueMoveUpcoming(1, toEnd = true)      // s4 -> end
        assertEquals(listOf("s0", "s1", "s2", "s3", "s5", "s4"), ids(r))
        r.dj.autoQueueMoveUpcoming(99, toEnd = true)
        assertEquals(6, r.dj.queueSize)
    }

    @Test fun aDeckLoadedRowCanNeverBeDisplacedByAnyOfTheOperations() {
        val r = rig(n = 8); r.start()
        r.dj.autoQueueInsert(extra(r, "a"), JukeboxDecisionAction.NEXT)
        r.dj.autoQueueShuffleUpcoming()
        r.dj.autoQueueRemoveUpcoming(0)
        r.dj.autoQueueMoveUpcoming(0, toEnd = true)
        assertEquals("s1", ids(r)[1])
        assertEquals("s1", r.id(Deck.B))
    }

    // ---------------------------------------------------------------- persistence

    @Test fun everyStructuralChangePersistsTheQueue() {
        val clock = TestClock()
        val file = tempFile("decks.json")
        val store = MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, ManualScheduler(clock))
        val r = rig(n = 6, store = store)
        r.start()
        fun persisted() = store.load()!!.auto!!.queue.map { it.track.songId }
        assertEquals(ids(r), persisted())
        r.dj.autoQueueInsert(extra(r, "req"), JukeboxDecisionAction.NEXT)
        assertEquals(ids(r), persisted()); assertTrue("req" in persisted())
        r.dj.autoQueueRemoveUpcoming(1)
        assertEquals(ids(r), persisted()); assertFalse("req" in persisted())
        r.dj.autoQueueMoveUpcoming(1, toEnd = true)
        assertEquals(ids(r), persisted())
        r.dj.autoQueueShuffleUpcoming()
        assertEquals(ids(r), persisted())
        r.run(25.0)
        val snap = store.load()!!.auto!!
        assertEquals("the advanced cursor persists", 1, snap.livePos)
        assertEquals("B", snap.liveDeck)
    }
}
