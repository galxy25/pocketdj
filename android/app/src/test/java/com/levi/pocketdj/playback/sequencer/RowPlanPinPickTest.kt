package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.durable.SessionSnapshot
import com.levi.pocketdj.playback.durable.SessionSourceRef
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RowPlanPinPickTest {
    private fun TestScope.harness() = SequencerHarness(this, backgroundScope, setOf("a", "b", "c", "d", "e", "f"))

    private fun plan(slot: Int, pinned: Boolean = false) = PlanTag("run1", slot, "col", 0.25, pinned)
    private fun run(vararg ids: String) = ids.mapIndexed { i, id -> QueueItem(id = id, title = id, plan = plan(i)) }

    private class Landed : SequencerListener {
        val uids = mutableListOf<String>()
        override fun onRowLandedNext(uid: String) { uids += uid }
    }

    private fun SequencerHarness.q() = seq.state.value.queue

    @Test
    fun equality_ignoresPlanAndPick_asOnIos() {
        val a = QueueItem(id = "a", title = "a", uid = "u")
        assertEquals(a, a.copy(plan = plan(3), djUserNext = true))
        assertEquals(a.hashCode(), a.copy(plan = plan(3), djUserNext = true).hashCode())
        assertTrue(a != a.copy(title = "z"))
    }

    @Test
    fun moveUpcoming_pinsMovedPlanRows_andLeavesPlanlessRowsPlanless() = runTest {
        val h = harness()
        h.seq.play(listOf(QueueItem("a", "a")) + run("b", "c", "d") + QueueItem("e", "e"), "pwr_run1"); h.settle()
        // drag "d" (tail offset 2) to the end; drag the listener's own "e" up
        h.seq.moveUpcoming(listOf(2), 4)
        h.seq.moveUpcoming(listOf(3), 1)
        val byId = h.q().associateBy { it.id }
        assertTrue(byId.getValue("d").pinned)
        assertNull("a hand-added row never gets a plan", byId.getValue("e").plan)
        assertFalse(byId.getValue("b").pinned)
        assertFalse(byId.getValue("c").pinned)
    }

    @Test
    fun moveNextAndToEnd_pin() = runTest {
        val h = harness()
        h.seq.play(listOf(QueueItem("a", "a")) + run("b", "c", "d"), "pwr_run1"); h.settle()
        val uidC = h.q()[2].uid
        val uidB = h.q()[1].uid
        h.seq.moveUpcomingNext(uidC)
        assertEquals(listOf("a", "c", "b", "d"), h.seq.state.value.queue.map { it.id })
        assertTrue(h.q()[1].pinned)
        h.seq.moveUpcomingToEnd(uidB)
        assertEquals(listOf("a", "c", "d", "b"), h.q().map { it.id })
        assertTrue(h.q().last().pinned)
        assertFalse("untouched row stays unpinned", h.q()[2].pinned)
    }

    @Test
    fun insertedRowsWithAPlanArePinned() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b"), "set_1"); h.settle()
        h.seq.insertNextInQueue(run("c"))
        h.seq.insertInQueue(run("d"), h.q().last().uid)
        h.seq.appendToQueue(run("e"))
        assertTrue(h.q().filter { it.id in setOf("c", "d", "e") }.all { it.pinned })
    }

    @Test
    fun landedNext_firesForEveryEditThatLandsARowAtIndexPlusOne() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c", "d", "e"), "set_1"); h.settle()
        val l = Landed().also { h.seq.hooks.add(it) }

        h.seq.insertNextInQueue(rows("f"))                         // insertNext
        assertEquals(h.q()[1].uid, l.uids.last()); assertEquals(1, l.uids.size)

        h.seq.moveUpcomingNext(h.q()[4].uid)                       // move-to-next
        assertEquals(h.q()[1].uid, l.uids.last()); assertEquals(2, l.uids.size)

        h.seq.moveUpcoming(listOf(3), 0)                           // drag to the top
        assertEquals(h.q()[1].uid, l.uids.last()); assertEquals(3, l.uids.size)

        h.seq.insertInQueue(rows("f"), h.q()[1].uid)               // drop before next
        assertEquals(h.q()[1].uid, l.uids.last()); assertEquals(4, l.uids.size)

        h.seq.insertRandomInQueue(rows("f"), slot = { it.first }) // jukebox surprise slot landing next
        assertEquals(h.q()[1].uid, l.uids.last()); assertEquals(5, l.uids.size)
    }

    @Test
    fun landedNext_doesNotFireForEditsElsewhere() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c", "d", "e"), "set_1"); h.settle()
        val l = Landed().also { h.seq.hooks.add(it) }
        h.seq.appendToQueue(rows("f"))
        h.seq.moveUpcomingToEnd(h.q()[2].uid)
        h.seq.moveUpcoming(listOf(2), 4)
        h.seq.insertInQueue(rows("f"), h.q()[3].uid)
        h.seq.insertRandomInQueue(rows("f"), slot = { it.last })
        h.seq.removeUpcoming(setOf(h.q()[3].uid))
        assertTrue(l.uids.isEmpty())
    }

    @Test
    fun djUserNext_isOnlyEverOnTheNextRow_movesWithThePick_andIsSpentWhenItPlays() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c", "d"), "set_1"); h.settle()
        h.seq.moveUpcomingNext(h.q()[3].uid)                     // d is the pick
        assertEquals(listOf(false, true, false, false), h.q().map { it.djUserNext })
        h.seq.moveUpcomingToEnd(h.q()[2].uid)                    // an edit elsewhere keeps the pick
        assertEquals(listOf(false, true, false, false), h.q().map { it.djUserNext })
        h.seq.moveUpcomingNext(h.q()[3].uid)                     // a new pick replaces it
        assertEquals(1, h.q().count { it.djUserNext })
        assertTrue(h.q()[1].djUserNext)
        h.seq.removeUpcoming(setOf(h.q()[1].uid))               // the pick is removed: the row that slid in was not chosen
        assertTrue(h.q().none { it.djUserNext })
        h.seq.moveUpcomingNext(h.q()[2].uid)
        h.seq.skipNext(); h.settle()                             // it plays: the hold is spent at the start
        assertTrue(h.q().none { it.djUserNext })
    }

    @Test
    fun djPick_dragAwayFromTheTop_clearsIt() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c", "d"), "set_1"); h.settle()
        h.seq.moveUpcomingNext(h.q()[2].uid)
        assertTrue(h.q()[1].djUserNext)
        h.seq.moveUpcoming(listOf(0), 2)                         // drag the pick down into the middle
        assertTrue(h.q().none { it.djUserNext })
    }

    @Test
    fun djModeHeldPick_keepsASurpriseSlotBehindIt() = runTest {
        val h = harness()
        h.seq.djModeEnabled = { true }
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        h.seq.moveUpcomingNext(h.q()[2].uid)
        val pick = h.q()[1].uid
        h.seq.insertRandomInQueue(rows("d"), slot = { it.first })
        assertEquals("the pick stays next", pick, h.q()[1].uid)
        assertEquals("d", h.q()[2].id)
    }

    // ---- durable snapshot shape ----------------------------------------------------------------------

    private fun snap(rows: List<QueueItem>, index: Int = 0) = SessionSnapshot(
        sessionId = "pses_1", source = SessionSourceRef("setlist", "set_1"),
        queue = rows.map { SessionSnapshot.row(it) }, index = index,
    )

    @Test
    fun planAndPickRoundTripThroughTheSnapshot() {
        val rows = listOf(
            QueueItem("a", "a", plan = plan(0, pinned = true)),
            QueueItem("b", "b", djUserNext = true, plan = plan(1)),
            QueueItem("c", "c"),
        )
        val decoded = SessionSnapshot.decode(SessionSnapshot.encode(snap(rows)))!!
        val back = decoded.toQueueItems()
        assertEquals(PlanTag("run1", 0, "col", 0.25, true), back[0].plan)
        assertEquals(PlanTag("run1", 1, "col", 0.25, false), back[1].plan)
        assertNull(back[2].plan)
        assertEquals(listOf(false, true, false), back.map { it.djUserNext })
    }

    @Test
    fun restoreMapsThePickOnlyOntoTheRowAfterCurrent_andLegacyDjPlacedToo() {
        val json = """{"schemaVersion":1,"sessionId":"s","source":{"kind":"setlist","id":"x"},"index":1,"queue":[
            {"songId":"a","title":"a","djUserNext":true},
            {"songId":"b","title":"b"},
            {"songId":"c","title":"c","djPlaced":true},
            {"songId":"d","title":"d","djUserNext":true}]}"""
        val s = SessionSnapshot.decode(json)!!
        // index 1: only the row at 2 can be the pick; djPlaced maps there, a stray flag on another row does not
        assertEquals(listOf(false, false, true, false), s.toQueueItems().map { it.djUserNext })
    }

    @Test
    fun iosShapedJsonWithoutTheNewFields_roundTripsWithoutGainingKeys() {
        val rows = listOf(QueueItem("a", "a"), QueueItem("b", "b"))
        val text = SessionSnapshot.encode(snap(rows))
        assertFalse(text.contains("\"plan\""))
        assertFalse(text.contains("djUserNext"))
        val again = SessionSnapshot.encode(SessionSnapshot.decode(text)!!.let { d -> d.copy(queue = d.toQueueItems().map { SessionSnapshot.row(it) }) })
        assertEquals("byte-stable", text, again)
    }

    @Test
    fun aSpentPickIsNotRevivedByTheOverlay() {
        val before = snap(listOf(QueueItem("a", "a"), QueueItem("b", "b", djUserNext = true)))
        val extras = com.levi.pocketdj.playback.durable.SnapshotExtras.of(before)
        val after = snap(listOf(QueueItem("a", "a"), QueueItem("b", "b")))
        assertNull(extras.overlay(after).queue[1].djUserNext)
        assertNotNull(extras.overlay(before).queue[1].djUserNext)
    }
}
