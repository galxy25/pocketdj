package com.levi.pocketdj.playback.health

import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The stall timers on virtual time: start watchdog, resolve-stall timer + hop choice, live backstop. */
@OptIn(ExperimentalCoroutinesApi::class)
class StartWatchdogTest {
    // ---- start watchdog ---------------------------------------------------------------------------

    @Test
    fun rekickAt8s_escalateAt20s() = runTest {
        val w = StartWatchdog(backgroundScope)
        val events = mutableListOf<String>()
        w.arm(stillOwed = { true }, onRekick = { events += "rekick@$it" }, onEscalate = { events += "escalate@$it" })
        advanceTimeBy(7_900); runCurrent()
        assertTrue(events.isEmpty())
        advanceTimeBy(200)
        assertEquals(listOf("rekick@8"), events)
        advanceTimeBy(11_800)
        assertEquals(listOf("rekick@8"), events)
        advanceTimeBy(200)
        assertEquals(listOf("rekick@8", "escalate@20"), events)
    }

    @Test
    fun noRekick_whenFirstAudioArrivedAlready_orListenerPaused() = runTest {
        val w = StartWatchdog(backgroundScope)
        var owed = true
        val events = mutableListOf<String>()
        w.arm({ owed }, { events += "rekick" }, { events += "escalate" })
        owed = false // audio / a listener pause landed
        advanceTimeBy(30_000)
        assertTrue(events.isEmpty())
    }

    @Test
    fun owedStopsAfterTheRekick_skipsTheEscalation() = runTest {
        val w = StartWatchdog(backgroundScope)
        var owed = true
        val events = mutableListOf<String>()
        w.arm({ owed }, { events += "rekick"; owed = false }, { events += "escalate" })
        advanceTimeBy(30_000)
        assertEquals(listOf("rekick"), events)
    }

    @Test
    fun cancel_andRearm_supersede() = runTest {
        val w = StartWatchdog(backgroundScope)
        val events = mutableListOf<String>()
        w.arm({ true }, { events += "old" }, { events += "old-esc" })
        advanceTimeBy(5_000)
        w.arm({ true }, { events += "new" }, { events += "new-esc" }) // a superseding start re-arms
        advanceTimeBy(5_000) // 10 s after the first arm: the old rekick (8 s) must NOT fire
        assertTrue(events.isEmpty())
        advanceTimeBy(3_100)
        assertEquals(listOf("new"), events)
        w.cancel()
        assertFalse(w.isArmed)
        advanceTimeBy(60_000)
        assertEquals(listOf("new"), events)
    }

    @Test
    fun customThresholds_andEscalateNeverBeforeRekick() = runTest {
        val w = StartWatchdog(backgroundScope, rekickAfterMs = 5_000, escalateAfterMs = 1_000)
        val events = mutableListOf<String>()
        w.arm({ true }, { events += "rekick@$it" }, { events += "escalate@$it" })
        advanceTimeBy(5_100)
        assertEquals(listOf("rekick@5", "escalate@5"), events)
    }

    // ---- resolve stall ------------------------------------------------------------------------------

    private fun q(vararg ids: String) = ids.map { QueueItem(id = it) }

    @Test
    fun stallTimer_firesAt6s_onlyIfStillStalled() = runTest {
        val t = ResolveStallTimer(backgroundScope)
        var stalled = true
        val fired = mutableListOf<Int>()
        t.arm({ stalled }, { fired += it })
        advanceTimeBy(5_900); runCurrent()
        assertTrue(fired.isEmpty())
        advanceTimeBy(200)
        assertEquals(listOf(6), fired)

        t.arm({ stalled }, { fired += it })
        stalled = false
        advanceTimeBy(10_000)
        assertEquals(listOf(6), fired)
    }

    @Test
    fun stallTimer_cancelledBySupersedingStart() = runTest {
        val t = ResolveStallTimer(backgroundScope)
        val fired = mutableListOf<Int>()
        t.arm({ true }, { fired += it })
        t.cancel()
        advanceTimeBy(10_000)
        assertTrue(fired.isEmpty())
        assertFalse(t.isArmed)
    }

    @Test
    fun hop_prefersTheFirstOnDeviceRow_overAnEarlierInstantRow() {
        val queue = q("stalled", "instant1", "device1", "device2")
        val choice = ResolveStallHop.choose(queue, 0, onDevice = { it.id.startsWith("device") }, instant = { it.id.startsWith("instant") })!!
        assertEquals(ResolveStallHop.Kind.ON_DEVICE, choice.kind)
        assertEquals(2, choice.queueIndex)
    }

    @Test
    fun hop_fallsBackToTheFirstInstantRow() {
        val queue = q("stalled", "slow", "instant1", "instant2")
        val choice = ResolveStallHop.choose(queue, 0, onDevice = { false }, instant = { it.id.startsWith("instant") })!!
        assertEquals(ResolveStallHop.Kind.INSTANT, choice.kind)
        assertEquals(2, choice.queueIndex)
    }

    @Test
    fun hop_none_keepsWaiting() {
        assertNull(ResolveStallHop.choose(q("stalled", "a", "b"), 0, { false }, { false }))
        assertNull(ResolveStallHop.choose(q("only"), 0, { true }, { true }))
        assertNull(ResolveStallHop.choose(q("a", "b"), 5, { true }, { true }))
    }

    @Test
    fun hop_lookaheadIs50Rows() {
        val ids = listOf("stalled") + (1..60).map { "r$it" }
        val queue = q(*ids.toTypedArray())
        assertEquals(50, ResolveStallHop.choose(queue, 0, { it.id == "r50" }, { false })!!.queueIndex)
        assertNull("row 51 is past the lookahead", ResolveStallHop.choose(queue, 0, { it.id == "r51" }, { false }))
    }

    @Test
    fun hop_apply_movesTheChosenRowToTheCursor_andDefersTheStalledOne_neverDropsIt() {
        val queue = q("done", "stalled", "x", "device", "y").toMutableList()
        val choice = ResolveStallHop.choose(queue, 1, { it.id == "device" }, { false })!!
        val row = ResolveStallHop.apply(queue, 1, choice)
        assertEquals("device", row.id)
        assertEquals(listOf("done", "device", "stalled", "x", "y"), queue.map { it.id })
    }

    // ---- live backstop --------------------------------------------------------------------------------

    @Test
    fun liveBackstop_expiresAtLengthPlus45s() = runTest {
        val b = LiveBackstop(backgroundScope)
        var expired = 0
        b.arm(lengthMs = 100_000, isPausedByListener = { false }, stillWaiting = { true }, onExpire = { expired++ })
        advanceTimeBy(144_000); runCurrent()
        assertEquals(0, expired)
        advanceTimeBy(2_000)
        assertEquals(1, expired)
    }

    @Test
    fun liveBackstop_excludesTimeTheListenerHadItPaused() = runTest {
        val b = LiveBackstop(backgroundScope)
        var paused = false
        var expired = 0
        b.arm(lengthMs = 10_000, isPausedByListener = { paused }, stillWaiting = { true }, onExpire = { expired++ })
        advanceTimeBy(20_000)
        paused = true
        advanceTimeBy(120_000) // two minutes paused: not counted
        assertEquals(0, expired)
        paused = false
        advanceTimeBy(40_000) // 20 + 25.. budget is 55 s of un-paused play: 20 s so far + 35 s more
        assertEquals(1, expired)
    }

    @Test
    fun liveBackstop_unknownLength_hasNoBackstop() = runTest {
        val b = LiveBackstop(backgroundScope)
        var expired = 0
        b.arm(lengthMs = null, isPausedByListener = { false }, stillWaiting = { true }, onExpire = { expired++ })
        assertFalse(b.isArmed)
        b.arm(lengthMs = 0, isPausedByListener = { false }, stillWaiting = { true }, onExpire = { expired++ })
        advanceTimeBy(600_000)
        assertEquals(0, expired)
    }

    @Test
    fun liveBackstop_standsDownWhenNoLongerWaiting_orCancelled() = runTest {
        val b = LiveBackstop(backgroundScope)
        var waiting = true
        var expired = 0
        b.arm(5_000, { false }, { waiting }, { expired++ })
        advanceTimeBy(10_000)
        waiting = false // the capture ended / the row advanced
        advanceTimeBy(100_000)
        assertEquals(0, expired)

        b.arm(5_000, { false }, { true }, { expired++ })
        b.cancel()
        advanceTimeBy(100_000)
        assertEquals(0, expired)
    }
}
