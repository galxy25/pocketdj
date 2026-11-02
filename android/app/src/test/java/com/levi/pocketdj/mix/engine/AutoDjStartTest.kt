package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Q103 (a gated first slot keeps the queue and retries) and Q111 (the first prepare runs off Main). */
class AutoDjStartTest {

    /** Captures [AutoDj.startRetryScheduler] posts so a test runs them by hand. */
    private class FakeScheduler {
        val tasks = ArrayList<Pair<Long, () -> Unit>>()
        fun install(dj: AutoDj) { dj.startRetryScheduler = { ms, block -> tasks += ms to block } }
        fun runNext() { tasks.removeAt(0).second() }
    }

    /** All [n] songs ripped-but-not-burned with the stream gate CLOSED (server down): not on disk, deferred. */
    private fun gatedRig(n: Int = 4): Pair<AutoRig, FakeScheduler> {
        val r = AutoRig(n = n)
        for (i in 0 until n) { r.h.removeSong("s$i"); r.seams.gated += "s$i" }
        val s = FakeScheduler().also { it.install(r.dj) }
        return r to s
    }

    /** The server came back: the songs load again (as if streamed). */
    private fun openGate(r: AutoRig, n: Int = 4) {
        for (i in 0 until n) r.h.addSong("s$i", r.seconds)
        r.seams.gated.clear()
    }

    // ---------------------------------------------------------------- Q103

    @Test fun q103GatedFirstSlotKeepsTheQueueAndRetriesAfterARest() {
        val (r, sched) = gatedRig()
        r.start()
        assertFalse("nothing could load yet", r.dj.isMixing)
        assertEquals("the queue is KEPT (was cleared before Q103)", 4, r.dj.queueSize)
        assertTrue(r.dj.startPending)
        assertEquals(listOf(AutoDj.START_RETRY_REST_MS), sched.tasks.map { it.first })
        assertTrue(r.advLines().any { it.contains("retry 1/${AutoDj.START_RETRY_ATTEMPTS}") })

        openGate(r)
        sched.runNext()
        assertTrue("the retry starts the mix", r.dj.isMixing)
        assertFalse(r.dj.startPending)
        assertEquals("s0", r.id(Deck.A)); assertEquals("s1", r.id(Deck.B))
        assertTrue(r.e.isPlaying(Deck.A))
        assertEquals(4, r.dj.queueSize)
        assertTrue("no further retry once started", sched.tasks.isEmpty())
    }

    @Test fun q103RetriesArmTheServerDownProbeOnlyAroundTheFirstSlot() {
        val (r, sched) = gatedRig()
        r.start()
        assertTrue("the first attempt is an ordinary start: no probe", r.seams.probeArms.isEmpty())
        sched.runNext()
        assertEquals("each retry arms the probe for slot 0, then disarms", listOf(true, false), r.seams.probeArms)
    }

    @Test fun q103GivesUpAfterTheRetryBudgetAndClearsTheQueue() {
        val (r, sched) = gatedRig()
        r.start()
        repeat(AutoDj.START_RETRY_ATTEMPTS) {
            assertEquals(1, sched.tasks.size)
            sched.runNext()
        }
        assertTrue("budget spent: no more retries", sched.tasks.isEmpty())
        assertFalse(r.dj.isMixing); assertFalse(r.dj.startPending)
        assertEquals(0, r.dj.queueSize)
        assertTrue(r.advLines().any { it.contains("giving up") })
    }

    @Test fun q103ANewStartSupersedesAPendingRetryWithAFreshBudget() {
        val (r, sched) = gatedRig()
        r.start(); sched.runNext(); sched.runNext()      // two retries used; the third is pending
        r.start()                                        // a NEW start: fresh budget
        assertEquals(2, sched.tasks.size)
        val fresh = sched.tasks[1]
        sched.runNext()                                  // the superseded start's retry no-ops
        assertEquals(listOf(fresh), sched.tasks)
        assertEquals(4, r.dj.queueSize)
        assertTrue(r.dj.startPending)
        assertEquals(2, r.advLines().count { it.contains("retry 1/${AutoDj.START_RETRY_ATTEMPTS} in") })
        openGate(r)
        sched.runNext()
        assertTrue(r.dj.isMixing)
    }

    @Test fun q103StopDuringTheRestCancelsTheRetry() {
        val (r, sched) = gatedRig()
        r.start()
        r.dj.stopAutoMix()
        assertFalse(r.dj.startPending)
        assertEquals(0, r.dj.queueSize)
        openGate(r)
        sched.runNext()
        assertFalse("a stopped start never comes back", r.dj.isMixing)
        assertNull(r.id(Deck.A))
    }

    @Test fun q103AutoOffDuringTheRestCancelsTheRetry() {
        val (r, sched) = gatedRig()
        r.start()
        r.dj.setAutoEnabled(false)
        openGate(r)
        sched.runNext()
        assertFalse(r.dj.isMixing)
    }

    @Test fun q103AManualDeckLoadDuringTheRestAbandonsTheStart() {
        val (r, sched) = gatedRig()
        r.start()
        r.e.load(r.h.addSong("manual", 20.0), Deck.A)
        openGate(r)
        sched.runNext()
        assertFalse("the DJ took the decks: the retry yields", r.dj.isMixing)
        assertEquals("manual", r.id(Deck.A))
        assertEquals(0, r.dj.queueSize)
    }

    @Test fun q103WithoutASchedulerTheGatedStartEndsAsBefore() {
        val r = AutoRig(n = 2)
        for (i in 0 until 2) { r.h.removeSong("s$i"); r.seams.gated += "s$i" }
        r.start()
        assertFalse(r.dj.isMixing); assertFalse(r.dj.startPending)
        assertEquals(0, r.dj.queueSize)
    }

    @Test fun q103PermanentlyUnloadableSongsAreStillDroppedNotRetried() {
        val (r, sched) = gatedRig(n = 3)
        r.seams.gated -= "s0"                     // s0 vanished for good (not ripped): dropped, not deferred
        r.start()
        assertEquals(2, r.dj.queueSize)
        assertEquals(1, sched.tasks.size)
        r.seams.gated.clear()                     // the rest are unloadable now too: nothing to wait for
        sched.runNext()
        assertEquals(0, r.dj.queueSize)
        assertTrue(sched.tasks.isEmpty())
    }

    // ---------------------------------------------------------------- Q111

    @Test fun q111FirstPrepareRunsOffMainAndTheStartCompletesOnTheCommit() {
        var mainResolves = 0
        var offMain = false
        val songs = object : HashMap<String, ResolvedTrack>() {
            override fun get(key: String): ResolvedTrack? {
                if (!offMain) mainResolves++
                return super.get(key)
            }
        }
        val r = AutoRig(n = 4, songs = songs)
        val queued = ArrayList<() -> Unit>()
        // A real IO -> Main hop: the work runs later, "off Main", and its commit lands afterwards.
        r.e.loadOffload = { work, commit ->
            queued += {
                offMain = true
                val p = try { work() } finally { offMain = false }
                commit(p)
            }
        }
        mainResolves = 0
        r.start()
        assertEquals("startAutoMix itself touches no disk on Main", 0, mainResolves)
        assertFalse("the decks load on the commit", r.dj.isMixing)
        assertTrue(r.dj.startPending)
        assertNull(r.id(Deck.A))
        assertEquals("slot 0 and slot 1 are prepared in the hop", 2, queued.size)

        queued.removeAt(0)()
        assertFalse("waits for EVERY first-slot prepare", r.dj.isMixing)
        queued.removeAt(0)()
        assertTrue(r.dj.isMixing)
        assertEquals("s0", r.id(Deck.A)); assertEquals("s1", r.id(Deck.B))
        assertTrue(r.e.isPlaying(Deck.A))
        assertEquals("the deck loads were served by the off-Main prepares", 0, mainResolves)
    }

    @Test fun q111AStopDuringThePrepareHopDiscardsTheLateResult() {
        val r = AutoRig(n = 4)
        val queued = ArrayList<() -> Unit>()
        r.e.loadOffload = { work, commit -> queued += { commit(work()) } }
        r.start()
        r.dj.stopAutoMix()
        queued.toList().forEach { it() }
        assertFalse(r.dj.isMixing)
        assertNull(r.id(Deck.A)); assertNull(r.id(Deck.B))
        assertTrue("late decoders were closed, nothing installed", r.h.voices.isEmpty())
    }

    @Test fun q111ASecondStartDuringTheHopWinsAndTheFirstNeverLands() {
        val r = AutoRig(n = 4)
        val queued = ArrayList<() -> Unit>()
        r.e.loadOffload = { work, commit -> queued += { commit(work()) } }
        r.start()
        val firstHop = queued.toList(); queued.clear()
        r.dj.startAutoMix(r.items.reversed(), false, r.lead, r.fade, "other")
        firstHop.forEach { it() }
        assertFalse("the superseded hop never starts a mix", r.dj.isMixing)
        queued.toList().forEach { it() }
        assertTrue(r.dj.isMixing)
        assertEquals("s3", r.id(Deck.A)); assertEquals("s2", r.id(Deck.B))
    }

    @Test fun q111AManualPlayDuringTheHopAbandonsTheStart() {
        val r = AutoRig(n = 4)
        val queued = ArrayList<() -> Unit>()
        r.e.loadOffload = { work, commit -> queued += { commit(work()) } }
        r.start()
        r.e.loadFile(java.io.File("/fake/s3.mp3"), null, null, com.levi.pocketdj.mix.model.LoadedTrack(songId = "s3", title = "t", artist = "a"), Deck.B)
        r.e.play(Deck.B)
        queued.toList().forEach { it() }
        assertFalse(r.dj.isMixing)
        assertEquals("s3", r.id(Deck.B))
    }
}
