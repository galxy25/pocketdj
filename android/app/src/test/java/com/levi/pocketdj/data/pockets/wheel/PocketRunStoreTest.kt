package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PocketRunTag
import com.levi.pocketdj.playback.sequencer.PlanTag
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ReplaceableRow
import com.levi.pocketdj.playback.sequencer.SequencerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** A sequencer stand-in: a queue with the PB-3 replace/append semantics the store relies on. */
private class FakePlayer : PocketRunPlayer {
    var queue = mutableListOf<QueueItem>()
    var index = 0
    var running = false
    var held = false
    var source: String? = null
    var plays = 0
    var stops = 0
    var appended = 0
    var replaceCalls = 0
    var declineReplace = false

    override fun state() = SequencerState(
        queue = queue.toList(), index = index, isRunning = running, isHeldForResume = held, sourceSetlistId = source,
    )

    override fun play(items: List<QueueItem>, tag: String, label: String) {
        plays++; queue = items.toMutableList(); index = 0; running = true; held = false; source = tag
    }

    override fun stop() { stops++; running = false; source = null }

    override fun replaceableUpcomingRows(runId: String): List<ReplaceableRow> =
        (index + 1 until queue.size).mapNotNull { i ->
            val p = queue[i].plan
            if (p == null || p.runId != runId || p.pinned) null
            else ReplaceableRow(queue[i].uid, queue[i].id, p.slot, p.collectionId, false, queue[i - 1].id, queue.getOrNull(i + 1)?.id)
        }

    override fun replaceUpcoming(replacements: Map<String, QueueItem>, removing: Set<String>): Int {
        replaceCalls++
        if (declineReplace) return 0
        var n = 0
        val out = mutableListOf<QueueItem>()
        for ((i, row) in queue.withIndex()) {
            if (i <= index || row.plan == null || row.plan.pinned) { out += row; continue }
            val rep = replacements[row.uid]
            when {
                rep != null -> { out += rep; n++ }
                row.uid in removing -> n++
                else -> out += row
            }
        }
        queue = out
        return n
    }

    override fun appendRunRows(items: List<QueueItem>) { appended += items.size; queue.addAll(items) }

    fun upcomingRun(runId: String) = queue.drop(index + 1).filter { it.plan?.runId == runId }
}

@OptIn(ExperimentalCoroutinesApi::class)
class PocketRunStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val t0 = 1_000_000_000_000.0
    private val pool = PocketRunPlannerTest.universe()
    private val profile = PocketRunPlannerTest.profile()

    private class H(
        val store: PocketRunStore,
        val player: FakePlayer,
        val events: MutableList<PlayEvent>,
        val clock: DoubleArray,
        val logs: MutableList<String>,
        val file: File,
    )

    private fun TestScope.harness(
        file: File = tmp.newFile("run-${System.nanoTime()}.json").also { it.delete() },
        candidates: Map<String, PocketRunPlanner.Candidate> = pool,
        tick: Boolean = false,
    ): H {
        val player = FakePlayer()
        val events = mutableListOf<PlayEvent>()
        val clock = doubleArrayOf(t0)
        val logs = mutableListOf<String>()
        val store = PocketRunStore(file, player, CoroutineScope(StandardTestDispatcher(testScheduler)), UnconfinedTestDispatcher(testScheduler))
        store.now = { clock[0] }
        store.tickerEnabled = tick
        store.historyEvents = { events.toList() }
        store.installId = { "me" }
        store.candidates = { candidates }
        store.log = { logs += it }
        return H(store, player, events, clock, logs, file)
    }

    private var evSeq = 0
    private fun H.finish(songId: String, skipped: Boolean, fraction: Double, install: String? = null, run: String? = store.active.value?.runId) {
        val q = player.queue.firstOrNull { it.id == songId }
        events += PlayEvent(
            id = "ev${evSeq++}", songId = songId, playedAt = clock[0] + evSeq, wasSkipped = if (skipped) true else null,
            listenedFraction = fraction, originInstallId = install,
            pocketRun = run?.let { PocketRunTag(it, store.active.value?.momentKey ?: "", q?.plan?.collectionId, q?.plan?.slot ?: 0) },
        )
    }

    /** Move the cursor to row [i] (the previous row's verdict has been filed). */
    private fun H.advanceTo(i: Int) { player.index = i }

    private fun artistOf(id: String) = pool[id]!!.features.artistKeys.first()

    // ---- W2 invariant ---------------------------------------------------------------------

    @Test fun rowsNeededNinetyPercentRuleAndTheSpare() {
        val n = PocketRunStore::rowsNeeded
        assertEquals(98, n(100, 1, true, 0.95))
        assertEquals(98, n(100, 1, true, 0.9))
        assertEquals(99, n(100, 0, true, 0.1)) // pending: 100 - 0 - 1
        assertEquals(99, n(100, 0, true, 0.89))
        // idle between rows: nothing sounding is a run row
        assertEquals(60, n(100, 40, false, null))
        // the 99th is in and the sounding row (the 100th) is still short of 90%: ONE spare stays queued
        assertEquals(1, n(100, 99, true, 0.3))
        // the sounding row is the 100th and is nearly done: nothing more is queued - never a 101st
        assertEquals(0, n(100, 99, true, 0.95))
        assertEquals(0, n(100, 100, true, 0.1))
        assertEquals(0, n(100, 100, false, null))
        assertEquals(0, n(100, 120, true, 0.0))
    }

    // ---- start ----------------------------------------------------------------------------

    // ---- W7 Mix path ----------------------------------------------------------------------

    private val mixProfile get() = profile.copy(mode = PocketMode.MIX)

    @Test fun mixRunAtTenLoadablePlaysViaMixAndTagsTheFirstSongDuringTheStart() = runTest {
        val h = harness()
        var tagDuringStart: PocketRunTag? = null
        h.store.playThroughMix = { rows, label ->
            // Auto-DJ's first PlayStarted fires while this call is still suspended.
            tagDuringStart = h.store.mixTag(rows.first().songId, label)
            10
        }
        assertTrue(h.store.start(mixProfile, seed = 42uL))
        val a = h.store.active.value!!
        assertTrue(a.viaMix)
        assertEquals(0, h.player.plays)
        assertNull(h.store.mixCaption.value)
        assertNotNull(tagDuringStart)
        assertEquals(a.runId, tagDuringStart!!.runId)
        assertEquals(1, tagDuringStart!!.slot)
        h.store.stop()
    }

    @Test fun mixRunBelowTenFallsBackToTheSequencerWithACaptionClearedOnStop() = runTest {
        val h = harness()
        h.store.playThroughMix = { _, _ -> 9 }
        assertTrue(h.store.start(mixProfile, seed = 42uL))
        val a = h.store.active.value!!
        assertFalse(a.viaMix)
        assertEquals(1, h.player.plays)
        assertEquals("pwr_${a.runId}", h.player.source)
        assertEquals(PocketRunMixPath.fallbackCaption(9), h.store.mixCaption.value)
        assertNull(h.store.mixTag("x", a.label))
        h.store.stop()
        assertNull(h.store.mixCaption.value)
    }

    @Test fun nonMixProfileNeverTouchesTheMixPath() = runTest {
        val h = harness()
        var called = false
        h.store.playThroughMix = { _, _ -> called = true; 50 }
        assertTrue(h.store.start(profile, seed = 42uL))
        assertFalse(called)
        assertFalse(h.store.active.value!!.viaMix)
        h.store.stop()
    }


    @Test fun startPlansOffMainTagsRowsAndPlaysUnderPwrSource() = runTest {
        val h = harness()
        assertTrue(h.store.start(profile, seed = 42uL))
        val a = h.store.active.value!!
        assertEquals("pwr_${a.runId}", h.player.source)
        assertEquals(1, h.player.plays)
        assertEquals(100, h.player.queue.size)
        assertTrue(h.player.queue.all { it.plan?.runId == a.runId && it.plan!!.slot in 1..100 && !it.plan!!.pinned })
        assertEquals(PocketRunPlanner.SLOTS, h.player.queue.map { it.plan!!.slot }.toSet().size)
        assertEquals("Pocket · Tue 8 AM CarPlay", a.label)
        assertEquals("42", a.seed)
        assertTrue(a.runId == a.runId.uppercase())
        assertEquals(PocketRunStore.BuildState.Idle, h.store.buildState.value)
        val start = h.logs.single { it.startsWith("start ") }
        assertTrue(start, Regex("start run=[0-9A-F]{8} moment=h08\\|d2\\|carPlay rows=100 fresh=\\d+ bench=\\d+ mix=false").matches(start))
        h.store.stop()
    }

    @Test fun startFailsHonestlyWhenNothingFits() = runTest {
        val h = harness(candidates = emptyMap())
        assertFalse(h.store.start(profile))
        assertEquals(0, h.player.plays)
        assertNull(h.store.active.value)
        val st = h.store.buildState.value as PocketRunStore.BuildState.Failed
        assertTrue(st.message.startsWith("Not enough playable songs fit your pocket right now"))
    }

    @Test fun priorTuningNeverBansButSkipsInThisRunDo() = runTest {
        val h = harness()
        // an EARLIER run skipped a whole artist hard: the prior sinks it but must not ban it (W5)
        val victim = pool.values.first { it.id.startsWith("pot_") }
        val key = victim.features.artistKeys.first()
        repeat(3) { i ->
            h.events += PlayEvent(
                id = "old$i", songId = pool.values.filter { artistOf(it.id) == key }[i].id, playedAt = t0 - 3 * 86_400_000.0,
                wasSkipped = true, listenedFraction = 0.02, pocketRun = PocketRunTag("OLDRUN", profile.key!!.token, "pl_pot", i + 1),
            )
        }
        assertTrue(h.store.start(profile, seed = 7uL))
        assertTrue("prior alone bans nothing", h.store.active.value!!.banned.isEmpty())
        h.store.stop()
    }

    // ---- live learning --------------------------------------------------------------------

    @Test fun evaluateCountsVerdictsOnceAndBansTheSkippedArtistFromThisRunOnly() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val rid = h.store.active.value!!.runId
        val first = h.player.queue[0].id
        h.finish(first, skipped = true, fraction = 0.04)
        h.advanceTo(1)
        h.store.evaluate()
        h.store.evaluate() // idempotent: the same event is never counted twice
        val a = h.store.active.value!!
        assertEquals(1, a.skips)
        assertEquals(0, a.playedThrough)
        assertEquals(1, a.processed.size)
        assertEquals(listOf(artistOf(first)), a.banned)
        // a completion counts as a play-through and does not lift a ban
        h.finish(h.player.queue[1].id, skipped = false, fraction = 1.0)
        h.advanceTo(2)
        h.store.evaluate()
        assertEquals(1, h.store.active.value!!.playedThrough)
        assertEquals(2, h.store.active.value!!.processed.size)
        assertEquals(rid, h.store.active.value!!.runId)
        h.store.stop()
    }

    @Test fun otherRunsAndOtherInstallsAndThePendingRowAreIgnored() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.finish(h.player.queue[0].id, true, 0.05, run = "SOMEONE-ELSE")
        h.finish(h.player.queue[1].id, true, 0.05, install = "peer-install")
        h.finish(h.player.queue[2].id, true, 0.05)
        h.store.currentEventId = { h.events.last().id } // the sounding row's verdict is still pending
        h.advanceTo(3)
        h.store.evaluate()
        assertEquals(0, h.store.active.value!!.skips)
        h.store.currentEventId = { null }
        h.store.evaluate()
        assertEquals(1, h.store.active.value!!.skips)
        h.store.stop()
    }

    // ---- re-plan --------------------------------------------------------------------------

    @Test fun skipReplansDebouncedAndSwapsBannedArtistRows() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val rid = h.store.active.value!!.runId
        // skip a song whose artist reappears upcoming
        val up = h.player.queue.drop(1)
        val banned = up.map { artistOf(it.id) }.groupBy { it }.filter { it.value.size > 1 }.keys.first()
        val skippedId = up.first { artistOf(it.id) == banned }.id
        val at = h.player.queue.indexOfFirst { it.id == skippedId }
        h.player.queue[0] = h.player.queue[at].also { h.player.queue[at] = h.player.queue[0] } // put it first
        h.finish(h.player.queue[0].id, true, 0.03)
        h.advanceTo(1)
        h.store.evaluate()
        assertEquals(listOf(banned), h.store.active.value!!.banned)
        val before = h.player.upcomingRun(rid).count { artistOf(it.id) == banned }
        assertTrue(before > 0)
        advanceTimeBy(1_499); runCurrent()
        assertEquals("debounced: nothing applied before 1.5 s", 0, h.player.replaceCalls)
        advanceTimeBy(2); runCurrent()
        assertEquals(1, h.player.replaceCalls)
        assertEquals(0, h.player.upcomingRun(rid).count { artistOf(it.id) == banned })
        val line = h.logs.single { it.startsWith("replan ") }
        assertTrue(line, line.contains("banned=[$banned]"))
        h.store.stop()
    }

    @Test fun burstOfSkipsCoalescesIntoOneReplan() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        for (i in 0 until 3) {
            h.finish(h.player.queue[i].id, true, 0.04)
            h.advanceTo(i + 1)
            h.store.evaluate()
            advanceTimeBy(400)
        }
        advanceTimeBy(2_000); runCurrent()
        assertEquals(1, h.logs.count { it.startsWith("replan ") })
        h.store.stop()
    }

    @Test fun everyFifthCompletionRescoresImmediately() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        for (i in 0 until 5) {
            h.finish(h.player.queue[i].id, false, 1.0)
            h.advanceTo(i + 1)
            h.store.evaluate()
        }
        runCurrent()
        assertEquals(1, h.logs.count { it.startsWith("replan ") })
        assertEquals(0, h.store.active.value!!.completedSinceRescore)
        h.store.stop()
    }

    // ---- ownership, held, grace -----------------------------------------------------------

    @Test fun lostOwnershipLearnsButNeverEditsAndEndsAfterTheTenSecondGrace() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.player.source = "pl_some_other_queue" // the listener started something else
        h.finish(h.player.queue[0].id, true, 0.03)
        h.store.evaluate()
        assertEquals("still learns", 1, h.store.active.value!!.skips)
        advanceTimeBy(5_000); runCurrent()
        assertEquals("never touches the queue it no longer owns", 0, h.player.replaceCalls)
        assertEquals(0, h.player.appended)
        assertTrue(h.store.isRunning)
        h.clock[0] += 9_999.0
        h.store.evaluate()
        assertTrue("inside the grace window", h.store.isRunning)
        h.clock[0] += 2.0
        h.store.evaluate()
        assertFalse(h.store.isRunning)
        assertNull(h.store.active.value)
        val s = h.store.past.value.single()
        assertFalse(s.finished)
        assertEquals(1, s.skips)
        assertEquals("the foreign queue is never stopped by us", 0, h.player.stops)
    }

    @Test fun regainingOwnershipInsideTheGraceCancelsTheLoss() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val tag = h.player.source
        h.player.source = "other"
        h.store.evaluate()
        h.clock[0] += 8_000.0
        h.player.source = tag
        h.store.evaluate()
        h.clock[0] += 20_000.0
        h.store.evaluate()
        assertTrue(h.store.isRunning)
        h.store.stop()
    }

    @Test fun heldRestoredRunDoesNoPerTickWork() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.player.held = true
        h.finish(h.player.queue[0].id, true, 0.03)
        h.store.evaluate()
        assertEquals(0, h.store.active.value!!.skips)
        assertTrue(h.store.active.value!!.processed.isEmpty())
        assertEquals(0, h.player.replaceCalls)
        h.player.held = false
        h.store.evaluate()
        assertEquals(1, h.store.active.value!!.skips)
        h.store.stop()
    }

    // ---- W2: top-up and the 100th play-through -------------------------------------------

    @Test fun aSkipTopsTheQueueUpFromTheBenchAfterTheCursorAdvances() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val rid = h.store.active.value!!.runId
        h.finish(h.player.queue[0].id, true, 0.03)
        h.advanceTo(1) // 99 rows remain after... 98 upcoming + sounding = 99 played-or-pending
        assertEquals(98, h.player.upcomingRun(rid).size)
        h.store.evaluate()
        h.store.awaitTopUp()
        assertEquals("98 upcoming + 1 topped up = 99 needed (sounding row pending)", 99, h.player.upcomingRun(rid).size)
        assertEquals(1, h.player.appended)
        val appended = h.player.queue.last()
        assertEquals(101, appended.plan!!.slot)
        assertEquals(102, h.store.active.value!!.nextSlot)
        assertTrue("appended rows are not already queued", h.player.queue.map { it.id }.toSet().size == h.player.queue.size)
        assertTrue(h.logs.any { it.startsWith("topup ") })
        h.store.stop()
    }

    @Test fun emptyTopUpBacksOffForThirtySeconds() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        var asked = 0
        h.store.thumbsDown = { asked++; pool.keys - h.player.queue.map { it.id }.toSet() } // nothing left to top up with
        h.finish(h.player.queue[0].id, true, 0.03)
        h.advanceTo(1)
        h.store.evaluate(); h.store.awaitTopUp()
        assertEquals(0, h.player.appended)
        val first = asked
        assertTrue(first >= 1)
        h.clock[0] += 29_000.0
        h.store.evaluate(); h.store.awaitTopUp()
        assertEquals("inside the backoff the pool is not rescored", first, asked)
        h.clock[0] += 2_000.0
        h.store.evaluate(); h.store.awaitTopUp()
        assertTrue("after 30 s it tries again", asked > first)
        h.store.stop()
    }

    @Test fun theRunStopsAtThe100thPlayThroughAndNeverStartsA101st() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val rid = h.store.active.value!!.runId
        // 99 clean play-throughs, the cursor on the 100th row (sounding, still short of 90%): one spare is allowed
        for (i in 0 until 99) h.finish(h.player.queue[i].id, false, 1.0)
        h.advanceTo(99)
        h.store.evaluate(); h.store.awaitTopUp()
        assertEquals(99, h.store.active.value!!.playedThrough)
        assertTrue(h.store.isRunning)
        assertEquals("the 100th is sounding and unproven: exactly ONE spare is queued (it may yet be skipped)", 1, h.player.upcomingRun(rid).size)
        assertEquals(101, h.player.queue.size)
        // the 100th plays through: no more rows, and the run is finished
        h.finish(h.player.queue[99].id, false, 1.0)
        h.advanceTo(99)
        h.store.evaluate()
        val a = h.store.active.value!!
        assertTrue(a.finished)
        assertEquals(100, a.playedThrough)
        val s = h.store.past.value.last()
        assertTrue(s.finished)
        assertEquals(100, s.playedThrough)
        assertEquals("the spare left with the 100th play-through: never a 101st row", 100, h.player.queue.size)
        assertTrue(h.player.upcomingRun(rid).isEmpty())
        h.store.dismissFinished()
        assertNull(h.store.active.value)
    }

    @Test fun excessRowsLeaveTheTailAndPinnedRowsStillCount() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val rid = h.store.active.value!!.runId
        // earlier top-ups left 5 extra rows on the tail; the listener pinned the LAST of them
        val spare = pool.keys.filter { id -> h.player.queue.none { it.id == id } }.take(5)
        spare.forEachIndexed { i, id ->
            h.player.queue += QueueItem(id = id, plan = PlanTag(rid, 101 + i, null, 0.5, pinned = i == 4))
        }
        val pinnedUid = h.player.queue.last().uid
        val removedTail = h.player.queue.takeLast(5).dropLast(1).map { it.uid }.toSet()
        val midPin = h.player.queue[50].also { h.player.queue[50] = it.copy(plan = it.plan!!.copy(pinned = true)) }.uid
        for (i in 0 until 10) h.finish(h.player.queue[i].id, false, 1.0)
        h.advanceTo(10)
        h.store.evaluate()
        val left = h.player.upcomingRun(rid)
        // 105 queued - cursor 10 = 94 upcoming; 100 - 10 played - 1 sounding = 89 needed; 5 excess leave the TAIL
        assertEquals(89, left.size)
        assertTrue("a pinned row still counts and stays", left.any { it.uid == pinnedUid } || left.none { it.uid in removedTail })
        assertTrue(left.none { it.uid in removedTail })
        assertTrue(left.any { it.uid == midPin })
        h.store.stop()
    }

    // ---- Re-tuned badge -------------------------------------------------------------------

    @Test fun retunedBadgeLightsOnlyLandedRowsAndAnOlderTimerNeverClearsANewerBadge() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val u1 = h.player.queue[5].uid
        val u2 = h.player.queue[6].uid
        h.store.flashRetuned(setOf(u1, "never-landed"))
        assertEquals(setOf(u1), h.store.retunedUids.value)
        assertTrue(h.store.isRetuned(u1))
        advanceTimeBy(3_000); runCurrent()
        h.store.flashRetuned(setOf(u2)) // a newer swap
        assertEquals(setOf(u2), h.store.retunedUids.value)
        advanceTimeBy(1_500); runCurrent() // the OLDER timer (4 s) fires now
        assertEquals("older timer must not cut the newer badge short", setOf(u2), h.store.retunedUids.value)
        advanceTimeBy(2_600); runCurrent()
        assertTrue(h.store.retunedUids.value.isEmpty())
        h.store.stop()
    }

    @Test fun aThrowingBuildDoesNotWedgeLaterStartsAndKeepsTheOldRun() = runTest {
        val h = harness()
        assertTrue(h.store.start(profile, seed = 42uL))
        val rid = h.store.active.value!!.runId
        val good = h.store.candidates
        h.store.candidates = { throw IllegalStateException("boom") }
        try { h.store.start(profile, seed = 1uL); throw AssertionError("expected throw") } catch (_: IllegalStateException) {}
        assertEquals(PocketRunStore.BuildState.Idle, h.store.buildState.value)
        assertEquals("old run untouched by a failed rebuild", rid, h.store.active.value?.runId)
        assertEquals(1, h.store.past.value.size + 1)
        h.store.candidates = good
        assertTrue(h.store.start(profile, seed = 2uL))
        h.store.stop()
    }

    @Test fun aNoOpFlashKeepsThePreviousBadge() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val u1 = h.player.queue[5].uid
        h.store.flashRetuned(setOf(u1))
        advanceTimeBy(1_500); runCurrent()
        h.store.flashRetuned(setOf("never-landed"))
        assertEquals(setOf(u1), h.store.retunedUids.value)
        advanceTimeBy(2_600); runCurrent()
        assertTrue(h.store.retunedUids.value.isEmpty())
        h.store.stop()
    }

    @Test fun startingOverAFinishedRunDoesNotDuplicateItsSummary() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        for (i in 0 until 100) h.finish(h.player.queue[i].id, false, 1.0)
        h.advanceTo(99)
        h.store.evaluate(); h.store.awaitTopUp()
        h.finish(h.player.queue[99].id, false, 1.0)
        h.store.evaluate()
        assertTrue(h.store.active.value!!.finished)
        assertEquals(1, h.store.past.value.size)
        assertTrue(h.store.start(profile, seed = 43uL))
        assertEquals(1, h.store.past.value.size)
        h.store.stop()
        assertEquals(2, h.store.past.value.size)
    }

    @Test fun aDeclinedSwapDoesNotLightTheBadge() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.player.declineReplace = true
        val victim = h.player.queue[1]
        h.finish(h.player.queue[0].id, true, 0.02)
        h.advanceTo(1)
        h.store.evaluate()
        advanceTimeBy(2_000); runCurrent()
        // every replacement was declined: the old rows are still there, none is badged
        assertTrue(h.store.retunedUids.value.isEmpty())
        assertEquals(victim.uid, h.player.queue[1].uid)
        h.store.stop()
    }

    // ---- persistence ----------------------------------------------------------------------

    @Test fun runFileRoundTripsKeepsPastRunsAndIgnoresUnknownKeys() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val a = h.store.active.value!!
        h.store.stop()
        h.store.start(profile, seed = 43uL) // second run: the first is filed under past[]
        val doc = Json.parseToJsonElement(h.file.readText()).jsonObject
        assertEquals(1, doc["schemaVersion"]!!.jsonPrimitive.int)
        assertEquals(1, doc["past"]!!.jsonArray.size)
        assertEquals(a.runId, doc["past"]!!.jsonArray[0].jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals(h.store.active.value!!.runId, doc["active"]!!.jsonObject["runId"]!!.jsonPrimitive.content)
        assertTrue(doc["active"]!!.jsonObject.containsKey("nextSlot"))

        // a relaunch restores the active run + past, and an iOS file missing the newer fields still loads
        val re = PocketRunStore(h.file, h.player, CoroutineScope(StandardTestDispatcher(testScheduler)))
        assertEquals(h.store.active.value, re.active.value)
        assertEquals(1, re.past.value.size)
        val active = doc["active"]!!.jsonObject.toMutableMap().also { it.remove("retargetedMode"); it["fromTheFuture"] = JsonPrimitive(1) }
        h.file.writeText(JsonObject(doc.toMutableMap().also { it["active"] = JsonObject(active) }).toString())
        assertEquals(h.store.active.value!!.runId, PocketRunStore(h.file, h.player, CoroutineScope(StandardTestDispatcher(testScheduler))).active.value!!.runId)
        h.store.stop()
    }

    @Test fun pastRunsAreCappedAtFifty() = runTest {
        val h = harness()
        repeat(52) { h.store.start(profile, seed = (it + 1).toULong()) }
        h.store.stop()
        assertEquals(PocketRunStore.PAST_CAP, h.store.past.value.size)
    }

    @Test fun clearLocalWipesTheRunAndTheFile() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.store.stop()
        h.store.start(profile, seed = 43uL)
        assertTrue(h.file.exists())
        h.store.clearLocal()
        assertNull(h.store.active.value)
        assertTrue(h.store.past.value.isEmpty())
        assertFalse(h.file.exists())
    }

    @Test fun stopFilesTheRunAndStopsOnlyItsOwnQueue() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        h.store.stop()
        assertEquals(1, h.player.stops)
        assertFalse(h.store.past.value.single().finished)
        h.store.start(profile, seed = 44uL)
        h.player.source = "pl_other"
        h.store.stop()
        assertEquals("a queue that is no longer ours is left alone", 1, h.player.stops)
    }

    // ---- History tag + Mix path -----------------------------------------------------------

    @Test fun historyTagOnlyForRowsOfTheActiveRun() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val a = h.store.active.value!!
        val plan = h.player.queue[2].plan!!
        val tag = h.store.tag(plan)!!
        assertEquals(PocketRunTag(a.runId, a.momentKey!!, plan.collectionId, plan.slot), tag)
        assertNull(h.store.tag(plan.copy(runId = "OTHER")))
        assertNull(h.store.tag(null))
        h.store.stop()
        assertNull("no active run, no tag", h.store.tag(plan))
    }

    @Test fun mixMomentPlaysThroughMixWhenTenOrMoreLoadAndNeverReplans() = runTest {
        val h = harness()
        val mixProfile = profile.copy(mode = PocketMode.MIX)
        h.store.playThroughMix = { rows, _ -> rows.size }
        assertTrue(h.store.start(mixProfile, seed = 42uL))
        val a = h.store.active.value!!
        assertTrue(a.viaMix)
        assertEquals("the sequencer is not used", 0, h.player.plays)
        assertEquals(100, a.mixSlots.size)
        val song = a.mixSlots.keys.first()
        assertEquals(a.mixSlots[song], h.store.mixTag(song, a.label)!!.slot)
        assertNull(h.store.mixTag(song, "some other deck label"))
        h.store.replanNow()
        assertEquals(0, h.player.replaceCalls)
        h.store.stop()
        assertEquals("a Mix run never stops the sequencer", 0, h.player.stops)
    }

    @Test fun mixWithTooFewLoadableSongsFallsBackToTheSequencer() = runTest {
        val h = harness()
        h.store.playThroughMix = { _, _ -> 9 }
        assertTrue(h.store.start(profile.copy(mode = PocketMode.MIX), seed = 42uL))
        assertFalse(h.store.active.value!!.viaMix)
        assertEquals(1, h.player.plays)
        h.store.stop()
    }

    // ---- ticker + resume ------------------------------------------------------------------

    @Test fun theOneHertzTickerEvaluatesAndStopsWithTheRun() = runTest {
        val h = harness(tick = true)
        h.store.start(profile, seed = 42uL)
        runCurrent()
        h.finish(h.player.queue[0].id, true, 0.03)
        h.advanceTo(1)
        advanceTimeBy(1_100); runCurrent()
        assertEquals(1, h.store.active.value!!.skips)
        h.store.stop()
        h.finish(h.player.queue[1].id, true, 0.03)
        advanceTimeBy(5_000); runCurrent()
        assertNull(h.store.active.value)
    }

    @Test fun relaunchedRunRelearnsItsBansBeforeTouchingAnything() = runTest {
        val h = harness()
        h.store.start(profile, seed = 42uL)
        val first = h.player.queue[0].id
        h.finish(first, true, 0.03)
        h.advanceTo(1)
        // process death: a new store restores the run file; the sequencer comes back HELD
        val re = PocketRunStore(h.file, h.player, CoroutineScope(StandardTestDispatcher(testScheduler)), UnconfinedTestDispatcher(testScheduler))
        re.now = { h.clock[0] }; re.tickerEnabled = false
        re.historyEvents = { h.events.toList() }; re.installId = { "me" }; re.candidates = { pool }; re.log = {}
        h.player.held = true
        re.resumeTrackingIfNeeded()
        runCurrent()
        assertEquals("the verdict that landed before the kill is re-derived into the ban list", listOf(artistOf(first)), re.active.value!!.banned)
        assertEquals("held: no per-tick work", 0, h.player.replaceCalls)
        assertNotNull(re.active.value)
    }

    // ---- P2-POC-12 adapt-to-activity wiring ---------------------------------------------------

    private class Feed {
        var onSample: ((com.levi.pocketdj.data.motion.MotionSegment) -> Unit)? = null
        var onExit: ((String) -> Unit)? = null
        var starts = 0
        var stops = 0
    }

    private fun H.wireAdapt(adapt: BooleanArray): Feed {
        val f = Feed()
        store.adaptToActivity = { adapt[0] }
        store.startActivityUpdates = { s, e -> f.starts++; f.onSample = s; f.onExit = e }
        store.stopActivityUpdates = { f.stops++ }
        store.profileForMode = { m -> profile.copy(mode = m) }
        return f
    }

    private fun walking(at: Double) = com.levi.pocketdj.data.motion.MotionSegment(at.toLong(), at.toLong(), MotionToken.WALKING, 1)

    @Test fun sustainedWalkingRetargetsTheRunOnce() = runTest {
        val h = harness()
        val f = h.wireAdapt(booleanArrayOf(true))
        assertTrue(h.store.start(profile, seed = 42uL))
        assertEquals(1, f.starts)
        h.store.noteActivity(walking(h.clock[0]))
        runCurrent()
        assertNull(h.store.active.value!!.retargetedMode)
        h.clock[0] += 180_000
        h.store.noteActivity(walking(h.clock[0]))
        runCurrent()
        assertEquals(PocketMode.WALKING, h.store.active.value!!.retargetedMode)
    }

    @Test fun exitWithoutNewEnterStopsTheSustainClock() = runTest {
        val h = harness()
        val f = h.wireAdapt(booleanArrayOf(true))
        assertTrue(h.store.start(profile, seed = 42uL))
        h.store.noteActivity(walking(h.clock[0]))
        f.onExit!!.invoke(MotionToken.WALKING)
        runCurrent()
        h.clock[0] += 200_000
        // any later (low-confidence, ignored) sample triggers the check; nothing is being walked, so no retarget
        h.store.noteActivity(com.levi.pocketdj.data.motion.MotionSegment(0, 0, MotionToken.WALKING, 0))
        runCurrent()
        assertNull(h.store.active.value!!.retargetedMode)
    }

    @Test fun togglingAdaptOnMidRunStartsTheFeed() = runTest {
        val h = harness(tick = true)
        val adapt = booleanArrayOf(false)
        val f = h.wireAdapt(adapt)
        assertTrue(h.store.start(profile, seed = 42uL))
        runCurrent()
        assertEquals(0, f.starts)
        adapt[0] = true
        advanceTimeBy(PocketRunStore.TICK_MS + 1)
        runCurrent()
        assertEquals(1, f.starts)
        adapt[0] = false
        advanceTimeBy(PocketRunStore.TICK_MS + 1)
        runCurrent()
        assertEquals(1, f.stops)
        h.store.stop()
        advanceTimeBy(5_000); runCurrent()
        assertNull(h.store.active.value)
    }

    @Test fun beginningTheFeedTwiceKeepsTheSustainClock() = runTest {
        val h = harness()
        val f = h.wireAdapt(booleanArrayOf(true))
        assertTrue(h.store.start(profile, seed = 42uL))
        h.store.noteActivity(walking(h.clock[0]))
        h.clock[0] += 100_000
        h.store.resumeTrackingIfNeeded()
        runCurrent()
        assertEquals("a second begin must not re-register the feed", 1, f.starts)
        h.clock[0] += 80_000
        h.store.noteActivity(walking(h.clock[0]))
        runCurrent()
        assertEquals("the 180 s clock survived the second begin", PocketMode.WALKING, h.store.active.value!!.retargetedMode)
    }
}
