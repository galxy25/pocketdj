package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerHarness
import com.levi.pocketdj.playback.sequencer.SequencerState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DjPlannerDriverTest {

    @Test fun albumLinkedChecksThePairAcrossTheWindowEdge() {
        // Row 3 runs into row 4; the window ends at hi = 4 (rows < 4), so row 3 must be linked.
        assertEquals(setOf(3), DjCandidates.albumLinked(0, 4, 10) { it == 3 })
        assertEquals(setOf(2, 3), DjCandidates.albumLinked(0, 5, 10) { it == 2 })
        assertEquals(emptySet<Int>(), DjCandidates.albumLinked(0, 4, 4) { it == 3 })
    }

    // ---- fixed-row matrix (pure) -------------------------------------------------------------------------------------

    private fun fixed(
        item: QueueItem = QueueItem("x"),
        next: Boolean = false,
        sig: DjCandidates.RowSignals = DjCandidates.RowSignals(),
        transitioning: Boolean = false,
        runway: Double? = 120.0,
    ) = DjCandidates.rowFixed(item, next, sig, transitioning, runway)

    @Test
    fun fixedRowMatrix_pickAgingAlbumRipLaneBuffer() {
        assertFalse(fixed())
        assertTrue("the pick at next", fixed(QueueItem("x", djUserNext = true), next = true))
        assertFalse("a mark anywhere but next is not held", fixed(QueueItem("x", djUserNext = true), next = false))
        assertTrue("aged out at 12", fixed(QueueItem("x", djDeferrals = 12)))
        assertFalse(fixed(QueueItem("x", djDeferrals = 11)))
        assertTrue(fixed(sig = DjCandidates.RowSignals(albumLinked = true)))
        assertTrue(fixed(sig = DjCandidates.RowSignals(ripInFlight = true)))
        assertTrue(fixed(sig = DjCandidates.RowSignals(laneFetching = true)))
        assertTrue(fixed(sig = DjCandidates.RowSignals(bufferStreaming = true)))
    }

    @Test
    fun fixedRowMatrix_nextRowRules() {
        assertFalse("next with runway and nothing local", fixed(next = true, runway = 30.0))
        assertTrue("next once local / buffering", fixed(next = true, sig = DjCandidates.RowSignals(willPlayLocally = true)))
        assertFalse("a LOCAL row further down is planner material", fixed(next = false, sig = DjCandidates.RowSignals(willPlayLocally = true)))
        assertTrue("next mid-transition", fixed(next = true, transitioning = true))
        assertFalse("not next, mid-transition", fixed(next = false, transitioning = true))
        assertTrue("next under 30 s of runway", fixed(next = true, runway = 29.9))
        assertTrue("next with unknown length", fixed(next = true, runway = null))
        assertFalse("unknown length only matters for the next row", fixed(next = false, runway = null))
    }

    @Test
    fun uuidOf_isStableAndAcceptsNonUuidUids() {
        val u = java.util.UUID.randomUUID().toString()
        assertEquals(u, DjCandidates.uuidOf(u).toString())
        assertEquals(DjCandidates.uuidOf("not-a-uuid"), DjCandidates.uuidOf("not-a-uuid"))
        assertNotEquals(DjCandidates.uuidOf("not-a-uuid"), DjCandidates.uuidOf("another"))
    }

    @Test
    fun candidate_foldsFactsMembershipAndAging() {
        val item = QueueItem("sng_0123456789ab_clean", djDeferrals = 3)
        val c = DjCandidates.candidate(
            item, DjCandidates.Facts(bpm = 60.0, camelot = "8a", genre = "Hip-Hop/Rap", year = 1999, artists = setOf("k")),
            mapOf("sng_0123456789ab" to setOf("pk1")), fixed = true, anchor = true,
        )
        assertEquals(3, c.deferrals)
        assertTrue(c.fixed && c.anchor)
        assertEquals(120.0, c.features.bpm!!, 0.0001) // 60 folds into [80,160)
        assertEquals("8A", c.features.camelot)
        assertEquals(setOf("pk1"), c.collections)       // membership keyed by the BASE id
        assertEquals(setOf("k"), c.artists)
    }

    // ---- sequencer applyDjOrder -------------------------------------------------------------------------------------

    private fun TestScope.harness(n: Int = 12) =
        SequencerHarness(this, backgroundScope, (0 until n).map { "s$it" }.toSet())

    private fun items(n: Int, block: (Int) -> QueueItem = { QueueItem("s$it", "s$it") }) = (0 until n).map(block)
    private fun SequencerHarness.q() = seq.state.value.queue

    @Test
    fun applyDjOrder_isUidVerified_keepsFixedSlots_countsDeferrals_andBumpsOneGeneration() = runTest {
        val h = harness()
        h.seq.play(items(8), "set_1"); h.settle()
        val q = h.q()
        val window = q.subList(1, 7).map { it.uid }
        val fixedMask = listOf(false, false, true, false, false, false)
        val gen0 = h.seq.queueGeneration
        // rotate the free rows; slot 2 stays
        val order = listOf(window[3], window[0], window[2], window[1], window[5], window[4])
        val gen = h.seq.applyDjOrder(1, window, order, fixedMask)
        assertEquals(gen0 + 1, gen)
        assertEquals(order, h.q().subList(1, 7).map { it.uid })
        // later than before = +1 deferral: window[0] 0->1, window[1] 1->3, window[4] 4->5
        val d = h.q().associate { it.uid to it.djDeferrals }
        assertEquals(1, d[window[0]]); assertEquals(1, d[window[1]]); assertEquals(1, d[window[4]])
        assertEquals(0, d[window[3]]); assertEquals(0, d[window[5]]); assertEquals(0, d[window[2]])
        // rows outside the window untouched
        assertEquals(q.first().uid, h.q().first().uid); assertEquals(q.last().uid, h.q().last().uid)
    }

    @Test
    fun applyDjOrder_refusesStaleDuplicateAndFixedMovingOrders() = runTest {
        val h = harness()
        h.seq.play(items(8), "set_1"); h.settle()
        val window = h.q().subList(1, 5).map { it.uid }
        val gen = h.seq.queueGeneration
        val none = listOf(false, false, false, false)
        // stale: the queue is not what the order was planned from
        assertNull(h.seq.applyDjOrder(1, window.reversed(), window, none))
        // duplicate uid in the order / expected
        assertNull(h.seq.applyDjOrder(1, window, listOf(window[0], window[0], window[2], window[3]), none))
        assertNull(h.seq.applyDjOrder(1, listOf(window[0], window[0], window[2], window[3]), window, none))
        // a fixed slot that moves
        assertNull(h.seq.applyDjOrder(1, window, window.reversed(), listOf(true, false, false, false)))
        // never the playing row / out of range
        assertNull(h.seq.applyDjOrder(0, h.q().subList(0, 3).map { it.uid }, h.q().subList(0, 3).map { it.uid }.reversed(), listOf(false, false, false)))
        assertNull(h.seq.applyDjOrder(6, h.q().subList(6, 8).map { it.uid } + "ghost", h.q().subList(6, 8).map { it.uid } + "ghost", listOf(false, false, false)))
        assertEquals("a refusal writes nothing", gen, h.seq.queueGeneration)
        assertEquals(window, h.q().subList(1, 5).map { it.uid })
    }

    @Test
    fun djDeferralsAndPickAreExcludedFromEquality() {
        val a = QueueItem("a", uid = "u")
        assertEquals(a, a.copy(djDeferrals = 5))
    }

    // ---- the driver over a real sequencer ---------------------------------------------------------------------------

    private class Rig(val h: SequencerHarness, scope: kotlinx.coroutines.CoroutineScope) : DjPlannerDriver.Host {
        override var enabled = true
        override var remoteActive = false
        val bpm = HashMap<String, Double>()
        val artist = HashMap<String, String>()
        val sig = HashMap<String, DjCandidates.RowSignals>()
        var linked: Set<Int> = emptySet()
        var runway: Double? = 120.0
        var membershipCalls = 0
        var membershipAnswer: Map<String, Set<String>> = emptyMap()
        var planner: DjPlannerState? = null
        val logs = mutableListOf<String>()
        override val djActive: Boolean get() = enabled && !remoteActive && h.seq.state.value.isRunning && !h.seq.state.value.isHeldForResume
        override fun state(): SequencerState = h.seq.state.value
        override fun settings() = DJModeSettings()
        override fun plannerState() = planner?.copy()
        override fun setPlannerState(st: DjPlannerState) { planner = st }
        override fun facts(item: QueueItem) = DjCandidates.Facts(
            bpm = bpm[item.id], artists = artist[item.id]?.let { setOf(it) }.orEmpty(),
        )
        override fun signals(item: QueueItem) = sig[item.id] ?: DjCandidates.RowSignals()
        override fun albumLinkedRows(hi: Int) = linked
        override val transitioning = false
        override fun runwaySeconds() = runway
        override suspend fun loadMembership(): Map<String, Set<String>> { membershipCalls++; return membershipAnswer }
        override fun applyOrder(lo: Int, expected: List<String>, order: List<String>, fixed: List<Boolean>, countDeferrals: Boolean) =
            h.seq.applyDjOrder(lo, expected, order, fixed, countDeferrals)
        override fun log(line: String) { logs += line }
        val driver = DjPlannerDriver(this, scope)
        init {
            h.seq.hooks.add(driver)
            h.seq.djModeEnabled = { enabled }
        }
    }

    /** A 14-row set alternating slow (~90) and fast (~150) songs: the selector has a lot to regroup. */
    private fun TestScope.rig(n: Int = 14): Rig {
        val h = SequencerHarness(this, backgroundScope, (0 until n).map { "s$it" }.toSet())
        val r = Rig(h, backgroundScope)
        for (i in 0 until n) r.bpm["s$i"] = if (i % 2 == 0) 90.0 + i else 140.0 + i
        return r
    }

    private fun Rig.start(n: Int = 14, block: (Int) -> QueueItem = { QueueItem("s$it", "s$it") }) {
        enabled = false
        h.seq.play((0 until n).map(block), "set_1"); h.settle()
        enabled = true
    }

    private fun Rig.q() = h.q()
    private fun TestScope.debounce() { advanceTimeBy(1_000); runCurrent() }

    @Test
    fun edit_replansOnceAfterOneSecond_andReordersTheWindow() = runTest {
        val r = rig(); r.start()
        val before = r.q().map { it.uid }
        val added = QueueItem("s5", "s5")
        r.h.seq.appendToQueue(listOf(added))
        runCurrent()
        assertTrue(r.driver.replanPending)
        advanceTimeBy(999); runCurrent()
        assertEquals("not before the 1 s quiet period", 0, r.driver.replanCount)
        advanceTimeBy(1); runCurrent()
        assertEquals(1, r.driver.replanCount)
        assertFalse(r.driver.replanPending)
        val after = r.q().map { it.uid }
        assertEquals("a pure re-order of the window plus the appended row", before.first(), after.first())
        assertEquals((before + added.uid).toSet(), after.toSet())
        assertTrue(r.logs.any { it.startsWith("replan reason=edit ") && " rows=14 moved=" in it })
    }

    @Test
    fun manyEditsWithinTheWindowDebounceToOneReplan() = runTest {
        val r = rig(); r.start()
        repeat(4) {
            r.h.seq.appendToQueue(listOf(QueueItem("s1", "s1")))
            advanceTimeBy(400); runCurrent()
        }
        assertEquals("each edit restarted the timer", 0, r.driver.replanCount)
        debounce(); advanceTimeBy(600); runCurrent()
        assertEquals(1, r.driver.replanCount)
    }

    @Test
    fun ourOwnReorderNeverRetriggers() = runTest {
        val r = rig(); r.start()
        r.driver.replan(DjPlannerDriver.Reason.ON)
        assertEquals(1, r.driver.replanCount)
        assertFalse(r.driver.replanPending)
        advanceTimeBy(10_000); runCurrent()
        assertEquals(1, r.driver.replanCount)
        assertEquals(1, r.logs.count { it.startsWith("replan reason=on") && " moved=0" !in it })
    }

    @Test
    fun noReplanWhileARemoteSessionIsAttached_orDjIsOff() = runTest {
        val r = rig(); r.start()
        r.remoteActive = true
        r.h.seq.appendToQueue(listOf(QueueItem("s1", "s1")))
        runCurrent()
        assertFalse(r.driver.replanPending)
        r.driver.replan(DjPlannerDriver.Reason.TRACK)
        assertEquals(0, r.driver.replanCount)
        r.remoteActive = false; r.enabled = false
        r.h.seq.appendToQueue(listOf(QueueItem("s1", "s1")))
        runCurrent()
        assertFalse(r.driver.replanPending)
    }

    @Test
    fun disarmCancelsAPendingReplan() = runTest {
        val r = rig(); r.start()
        r.h.seq.appendToQueue(listOf(QueueItem("s1", "s1")))
        runCurrent()
        assertTrue(r.driver.replanPending)
        r.driver.disarm()
        advanceTimeBy(5_000); runCurrent()
        assertEquals(0, r.driver.replanCount)
    }

    @Test
    fun trackStart_replansAtOnce_notDebounced() = runTest {
        val r = rig(); r.start()
        r.h.seq.skipNext(); r.h.settle()
        assertTrue("an advance re-plans what comes next without waiting", r.logs.any { it.startsWith("replan reason=track") })
    }

    @Test
    fun pickIsSacred_neverMoved_nothingAheadOfIt_oneAtATime() = runTest {
        val r = rig(); r.start()
        val far = r.q()[11]
        r.h.seq.moveUpcomingNext(far.uid)
        runCurrent()
        assertEquals(far.uid, r.q()[1].uid)
        val other = r.q()[9]
        r.h.seq.moveUpcomingNext(other.uid) // a new pick replaces the old one
        assertEquals(1, r.q().count { it.djUserNext })
        r.driver.replan(DjPlannerDriver.Reason.EDIT)
        assertEquals(other.uid, r.q()[1].uid)
        assertTrue(r.q()[1].djUserNext)
        assertTrue("the replan logged the pick", r.logs.any { "pick=${other.uid}" in it })
        assertFalse("the old pick is planner material again", r.q().first { it.uid == far.uid }.djUserNext)
    }

    @Test
    fun pickWhenItPlays_reanchorsTheWave() = runTest {
        val r = rig(); r.start()
        // establish the current band (s0 = 90 -> band 90) in the state
        r.driver.replan(DjPlannerDriver.Reason.ON)
        val pick = r.q().subList(1, r.q().size).first { (r.bpm[it.id] ?: 0.0) >= 140.0 }
        r.h.seq.moveUpcomingNext(pick.uid)
        r.h.seq.skipNext(); r.h.settle() // the pick plays; its hold is spent BEFORE the track-start re-plan
        assertTrue("the hold is spent", r.q().none { it.djUserNext })
        val st = r.planner!!
        assertEquals(DjCandidates.uuidOf(pick.uid), st.lastAccountedUid)
        // reanchor (not account) jumped the wave: a 2-band-or-more leap down from 90 into the 150s flips to DOWN
        assertEquals(DjDirection.DOWN, st.direction)
        assertEquals((r.bpm[pick.id]!!.toInt() / 10) * 10, st.band)
    }

    @Test
    fun fixedRowsKeepTheirSlot_whileTheRestIsReordered() = runTest {
        val r = rig(); r.start()
        val q = r.q()
        // rip in flight on slot 4, buffer streaming on slot 7, an album block on 9 and 10
        r.sig[q[4].id] = DjCandidates.RowSignals(ripInFlight = true)
        r.sig[q[7].id] = DjCandidates.RowSignals(bufferStreaming = true)
        r.linked = setOf(9, 10)
        val keep = mapOf(4 to q[4].uid, 7 to q[7].uid, 9 to q[9].uid, 10 to q[10].uid)
        r.driver.replan(DjPlannerDriver.Reason.ON)
        keep.forEach { (slot, uid) -> assertEquals("slot $slot", uid, r.q()[slot].uid) }
        assertNotEquals("something else did move", q.map { it.uid }, r.q().map { it.uid })
    }

    @Test
    fun nextRowIsFixedWhenLocalOrUnderThirtySeconds() = runTest {
        val r = rig(); r.start()
        val q0 = r.q().map { it.uid }
        r.runway = 29.0
        r.driver.replan(DjPlannerDriver.Reason.ON)
        assertEquals("under 30 s of runway: next stays", q0[1], r.q()[1].uid)
    }

    @Test
    fun aRowDeferredTwelveTimesHoldsItsPlace() = runTest {
        val r = rig(); r.start { QueueItem("s$it", "s$it", djDeferrals = if (it == 6) 12 else 0) }
        val uid = r.q()[6].uid
        r.driver.replan(DjPlannerDriver.Reason.ON)
        assertEquals(uid, r.q()[6].uid)
    }

    @Test
    fun analysisReplanDoesNotCountDeferrals_andOnlyFiresWhenAFactChanged() = runTest {
        val r = rig(); r.start()
        r.driver.replan(DjPlannerDriver.Reason.ON) // records the planned facts
        val deferralsAfterPlan = r.q().sumOf { it.djDeferrals }
        r.driver.onAnalysisLanded("s3")
        assertFalse("nothing changed for the window", r.driver.replanPending)
        r.bpm["s3"] = 200.0
        r.driver.onAnalysisLanded("s3")
        assertTrue(r.driver.replanPending)
        advanceTimeBy(1_000); runCurrent()
        assertEquals(1, r.driver.analysisReplanCount)
        assertEquals("an analysis re-plan never ages rows", deferralsAfterPlan, r.q().sumOf { it.djDeferrals })
    }

    @Test
    fun duplicateUidsBail() = runTest {
        val r = rig(); r.start(14) { QueueItem("s$it", "s$it", uid = if (it == 5 || it == 6) "dup" else java.util.UUID.randomUUID().toString()) }
        val before = r.q().map { it.uid }
        r.driver.replan(DjPlannerDriver.Reason.ON)
        assertEquals(before, r.q().map { it.uid })
        assertEquals(0, r.driver.replanCount)
        assertTrue(r.logs.any { "duplicate uids" in it })
    }

    @Test
    fun theWindowIsTheNextFortyRows() = runTest {
        val r = rig(60); r.start(60)
        val tail = r.q().subList(41, 60).map { it.uid }
        r.driver.replan(DjPlannerDriver.Reason.ON)
        assertTrue(r.logs.any { " rows=40 moved=" in it })
        assertEquals("rows beyond the window keep their order", tail, r.q().subList(41, 60).map { it.uid })
    }

    @Test
    fun artistSpacingHoldsOnAPocketRunQueue() = runTest {
        // 16 rows: 4 artists x 4 songs, appended by a pocket run (planner material, not pinned)
        val r = rig(17)
        val artists = listOf("A", "B", "C", "D")
        for (i in 1..16) { r.artist["s$i"] = artists[(i - 1) / 4]; r.bpm["s$i"] = 100.0 }
        r.start(1)
        r.h.seq.appendRunRows((1..16).map { QueueItem("s$it", "s$it") }, runTag = "pwr_run1")
        runCurrent()
        r.driver.replan(DjPlannerDriver.Reason.ON)
        val order = r.q().drop(1).map { r.artist[it.id]!! }
        assertEquals(16, order.size)
        // with 4 artists and spacing 4 the planner interleaves them: no artist twice inside any 4-window
        for (i in 0..order.size - 4) assertEquals("window $i of $order", 4, order.subList(i, i + 4).toSet().size)
        assertTrue("pocket-run rows are never pinned", r.q().drop(1).none { it.pinned })
    }

    @Test
    fun membership_loadsOncePerDjOn_andReplansOnLanding() = runTest {
        val r = rig(); r.start()
        r.membershipAnswer = mapOf("s2" to setOf("pk"), "s4" to setOf("pk"))
        r.driver.onApply()
        runCurrent()
        assertEquals(1, r.membershipCalls)
        assertTrue("membership landing re-plans", r.logs.any { it.startsWith("replan reason=membership") })
        r.h.seq.skipNext(); r.h.settle()
        r.h.seq.skipNext(); r.h.settle()
        assertEquals("track starts do not ask again", 1, r.membershipCalls)
        // DJ off then on again: a fresh load
        r.enabled = false; r.driver.onApply()
        r.enabled = true; r.driver.onApply(); runCurrent()
        assertEquals(2, r.membershipCalls)
    }

    @Test
    fun disarmWhileOff_forgetsMembership_soTheNextDjOnReloads() = runTest {
        val r = rig(); r.start()
        r.driver.onApply(); runCurrent()
        assertEquals(1, r.membershipCalls)
        r.enabled = false; r.driver.disarm()      // off via the engine hook only: no onApply / track start in between
        r.enabled = true; r.driver.onApply(); runCurrent()
        assertEquals(2, r.membershipCalls)
    }

    @Test
    fun anEmptyMembershipIsAnAnswer_noReplanAndNoRepeatAsk() = runTest {
        val r = rig(); r.start()
        r.driver.onApply(); runCurrent()
        r.h.seq.skipNext(); r.h.settle()
        assertEquals(1, r.membershipCalls)
        assertTrue(r.logs.none { it.startsWith("replan reason=membership") })
    }

    @Test
    fun shuffleIsSupersededWhileDjIsOn_andThePickSurvivesIt() = runTest {
        val r = rig(); r.start()
        r.h.seq.moveUpcomingNext(r.q()[8].uid)
        val pick = r.q()[1].uid
        val cur = r.q()[0]
        r.h.seq.setShuffle(true)
        runCurrent()
        advanceTimeBy(1_000); runCurrent()
        assertTrue("the shuffle's edit re-planned", r.logs.any { it.startsWith("replan reason=edit") })
        assertEquals(cur.uid, r.q()[0].uid)
        // whatever the shuffle did to the tail, a pick still sitting next is held, and at most one row is marked
        assertTrue(r.q().count { it.djUserNext } <= 1)
        if (r.q()[1].uid == pick) assertTrue(r.q()[1].djUserNext)
    }

    @Test
    fun plannerStateRidesTheHost_andDecodesIosShapedJson() = runTest {
        val r = rig(); r.start()
        // a state persisted by iOS (seed >= 2^63, optional fields absent) is what the driver plans from
        val ios = """{"seed":18446744073709551615,"playedInBand":2,"direction":1,"bandSteps":1,"waveIndex":1,"waveLength":2,"pocketCount":0,"pocketIndex":0,"pocketLength":3}"""
        r.planner = DjPlannerState.decode(ios)
        assertNotNull(r.planner)
        r.driver.replan(DjPlannerDriver.Reason.ON)
        val st = r.planner!!
        assertEquals(ULong.MAX_VALUE, st.seed)
        assertNotNull("the current row was accounted", st.lastAccountedUid)
        assertTrue(DjPlannerState.decode(st.encode())!!.seed == ULong.MAX_VALUE)
    }

    @Test
    fun stallHopMakesTheDeferredRowThePick_onlyWhileDjIsOn() = runTest {
        for (djOn in listOf(true, false)) {
            val r = rig(); r.start()
            r.enabled = djOn
            r.h.seq.rowOnDevice = { it.id == "s2" }
            val stalled = r.q()[0]
            r.h.seq.escalateStalledStart("test stall"); r.h.settle()
            // [s0, s1, s2, ..] -> [s2, s0, s1, ..]: the deferred (stalled) row sits right behind the hop target
            assertEquals("s2", r.q()[0].id)
            assertEquals(stalled.uid, r.q()[1].uid)
            if (djOn) assertTrue("the deferred row is the pick", r.q()[1].djUserNext)
            else assertTrue(r.q().none { it.djUserNext })
        }
    }

    @Test
    fun randomJukeboxInsertIsDrawnAfterAHeldPick() = runTest {
        val r = rig(); r.start()
        r.h.seq.moveUpcomingNext(r.q()[5].uid)
        val pick = r.q()[1].uid
        r.h.seq.insertRandomInQueue(listOf(QueueItem("s1", "s1")), slot = { it.first })
        assertEquals("the random row never lands ahead of the held pick", pick, r.q()[1].uid)
        assertTrue("the random row sits behind the pick", r.q().drop(2).count { it.id == "s1" } >= 2)
    }
}
