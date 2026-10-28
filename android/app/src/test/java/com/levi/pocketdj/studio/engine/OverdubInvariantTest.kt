package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MS = 1_000_000L

class OverdubMathTest {
    @Test fun hasOverdubRoomRefusesUnderTheMinimumRegion() {
        assertTrue(OverdubMath.hasOverdubRoom(0, 250))
        assertFalse(OverdubMath.hasOverdubRoom(0, 249))
        assertFalse(OverdubMath.hasOverdubRoom(1000, 1100))
        assertTrue(OverdubMath.hasOverdubRoom(1000, 1250))
        assertFalse("cursor parked at a real score's end has no room", OverdubMath.hasOverdubRoom(5000, 5000))
        assertFalse("cursor past the end", OverdubMath.hasOverdubRoom(9000, 5000))
    }

    @Test fun emptyScoreIsAlwaysOverdubbable() {
        assertTrue(OverdubMath.hasOverdubRoom(0, 0))
        assertTrue(OverdubMath.hasOverdubRoom(12_345, 0))
    }

    @Test fun hasOverdubRoomClampsWildInput() {
        assertTrue(OverdubMath.hasOverdubRoom(Int.MIN_VALUE, 1000))
        assertFalse(OverdubMath.hasOverdubRoom(Int.MAX_VALUE, Int.MAX_VALUE))
    }

    @Test fun scoreEndIsTheLastNoteOffAcrossEveryStaff() {
        val a = listOf(StudioNoteEvent(0, 500, 60, 90), StudioNoteEvent(500, 1200, 62, 90))
        val b = listOf(StudioNoteEvent(100, 3000, 40, 90))
        assertEquals(3000, OverdubMath.scoreEndMs(listOf(a, b)))
        assertEquals(0, OverdubMath.scoreEndMs(emptyList()))
        assertEquals(0, OverdubMath.scoreEndMs(listOf(emptyList())))
        assertEquals(OverdubMath.MAX_REPLAY_MS, OverdubMath.scoreEndMs(listOf(listOf(StudioNoteEvent(0, Int.MAX_VALUE, 60, 90)))))
    }

    @Test fun wrapIntoLoopFoldsPastTheBoundaryAndIsIdentityOtherwise() {
        val r = 1000 to 3000
        assertEquals(500, OverdubMath.wrapIntoLoop(500, r))          // before the region
        assertEquals(2500, OverdubMath.wrapIntoLoop(2500, r))
        assertEquals(1000, OverdubMath.wrapIntoLoop(3000, r))        // exactly at the end -> start
        assertEquals(2500, OverdubMath.wrapIntoLoop(6500, r))        // (6500-1000) % 2000 = 1500 -> 1000+1500
        assertEquals(6500, OverdubMath.wrapIntoLoop(6500, null))
        assertEquals(6500, OverdubMath.wrapIntoLoop(6500, 3000 to 3000))   // degenerate region
    }

    @Test fun deadlineDeferredWhileTheBackingHasNotStarted() {
        assertTrue(OverdubMath.deadlineDeferred(isReplaying = false, backingReady = false, backingPreparing = true, capturedCount = 0))
        assertTrue(OverdubMath.deadlineDeferred(isReplaying = true, backingReady = false, capturedCount = 0))
        assertFalse(OverdubMath.deadlineDeferred(isReplaying = true, backingReady = true, capturedCount = 0))
        assertFalse(OverdubMath.deadlineDeferred(isReplaying = false, backingReady = false, capturedCount = 0))
        assertFalse("a capture with notes keeps running its deadline", OverdubMath.deadlineDeferred(isReplaying = true, backingReady = false, backingPreparing = true, capturedCount = 3))
    }
}

class OverdubLogTest {
    private fun log(base: Int = 1000, end: Int = 3000, loop: Boolean = false) = OverdubLog().also { it.arm(0, base, end, loop) }

    @Test fun capturesAtBasePlusElapsedAbsoluteOnTheScoreClock() {
        val l = log()
        l.on(60, 90, 200 * MS); l.off(60, 500 * MS)
        val out = l.disarmAndFinish(900 * MS)
        assertEquals(listOf(StudioNoteEvent(1200, 1500, 60, 90)), out)
    }

    @Test fun strikesAtOrPastTheRegionEndAreDroppedAndHeldNotesCloseAtTheBoundary() {
        val l = log()
        l.on(60, 90, 1500 * MS)                      // 2500: inside
        l.on(62, 90, 2000 * MS)                      // 3000 = end (exclusive): dropped
        l.on(64, 90, 2500 * MS)                      // beyond
        val out = l.disarmAndFinish(4000 * MS)       // 60 held past the end
        assertEquals(listOf(StudioNoteEvent(2500, 3000, 60, 90)), out)
    }

    @Test fun preAnchorStrikesAreNotCaptured() {
        val l = log()
        l.on(60, 90, -50 * MS)
        assertEquals(0, l.count)
        assertTrue(l.disarmAndFinish(100 * MS).isEmpty())
    }

    @Test fun emptyScoreIsUnbounded() {
        val l = OverdubLog().also { it.arm(0, 0, Int.MAX_VALUE, loop = true) }   // loop is ignored without a bound
        l.on(60, 90, 100_000 * MS); l.off(60, 100_500 * MS)
        assertEquals(listOf(StudioNoteEvent(100_000, 100_500, 60, 90)), l.disarmAndFinish(200_000 * MS))
        assertFalse(OverdubLog().also { it.arm(0, 0, Int.MAX_VALUE) }.regionExhausted(10_000_000 * MS))
    }

    @Test fun loopWrapsPositionsAndLayersEveryIterationIntoOneCapture() {
        val l = log(loop = true)                      // region [1000,3000), len 2000
        l.on(60, 90, 100 * MS); l.off(60, 300 * MS)               // iter 0 at 1100
        l.on(64, 90, 2100 * MS); l.off(64, 2400 * MS)             // iter 1 -> wraps to 1100
        val out = l.disarmAndFinish(5000 * MS)
        assertEquals(listOf(StudioNoteEvent(1100, 1300, 60, 90), StudioNoteEvent(1100, 1400, 64, 90)), out)
    }

    @Test fun noteHeldAcrossTheWrapClosesAtTheBoundaryNeverHangingIntoTheNextIteration() {
        val l = log(loop = true)
        l.on(60, 90, 1800 * MS)                                    // 2800
        l.off(60, 2300 * MS)                                       // next iteration -> closes AT 3000
        assertEquals(listOf(StudioNoteEvent(2800, 3000, 60, 90)), l.disarmAndFinish(9999 * MS))
    }

    @Test fun retriggerWithNoOffClosesThePriorSounding() {
        val l = log()
        l.on(60, 90, 100 * MS); l.on(60, 80, 400 * MS)
        val out = l.disarmAndFinish(600 * MS)
        assertEquals(listOf(StudioNoteEvent(1100, 1400, 60, 90), StudioNoteEvent(1400, 1600, 60, 80)), out)
    }

    @Test fun exhaustionOnlyForBoundedNonLoopingArmedPasses() {
        assertFalse(log().regionExhausted(1999 * MS))
        assertTrue(log().regionExhausted(2000 * MS))
        assertFalse(log(loop = true).regionExhausted(99_999 * MS))
        val l = log(); l.disarmAndFinish(0)
        assertFalse(l.regionExhausted(99_999 * MS))
    }

    @Test fun snapshotPublishesCompletedNotesOnlyAndIsCoalesced() {
        val l = log()
        l.on(60, 90, 100 * MS)
        assertNull("a held note appears on release", l.snapshotIfDirty())
        l.off(60, 200 * MS)
        assertEquals(1, l.snapshotIfDirty()!!.size)
        assertNull(l.snapshotIfDirty())
    }

    @Test fun notesWhileDisarmedAreIgnored() {
        val l = OverdubLog()
        l.on(60, 90, 0); l.off(60, 10 * MS)
        assertTrue(l.disarmAndFinish(20 * MS).isEmpty())
    }
}

class OverdubControllerTest {
    private var now = 0L
    private fun ctl() = OverdubController(nanoClock = { now })

    @Test fun refusesUnderMinRoomOnARealScoreButAllowsEmpty() {
        val c = ctl()
        assertFalse(c.start(fromMs = 4900, scoreEndMs = 5000))
        assertFalse(c.isActive)
        assertFalse("parked exactly at the end", c.start(fromMs = 5000, scoreEndMs = 5000))
        assertTrue(c.start(fromMs = 0, scoreEndMs = Int.MAX_VALUE))
        assertTrue(c.isActive)
    }

    @Test fun refusedMidTakeAndWhileAlreadyArmed() {
        val c = ctl()
        assertFalse(c.start(0, midTake = true))
        assertTrue(c.start(0))
        assertFalse(c.start(0))
    }

    @Test fun loopIsIgnoredForAnUnboundedPass() {
        val c = ctl()
        c.start(0, Int.MAX_VALUE, loop = true)
        assertFalse(c.state.value.loop)
        c.stop()
        c.start(0, 4000, loop = true)
        assertTrue(c.state.value.loop)
    }

    @Test fun stopReturnsAbsoluteSortedEventsAndResetsState() {
        val c = ctl()
        c.start(1000, 5000)
        c.capture.on(64, 90, 700 * MS); c.capture.off(64, 800 * MS)
        c.capture.on(60, 90, 100 * MS); c.capture.off(60, 200 * MS)
        now = 900 * MS
        val out = c.stop()
        assertEquals(listOf(60, 64), out.map { it.note })
        assertEquals(1100, out[0].onMs)
        assertFalse(c.isActive)
        assertFalse(c.state.value.active)
        assertEquals(Int.MAX_VALUE, c.state.value.regionEndMs)
        assertTrue(c.stop().isEmpty())
    }

    @Test fun regionEndRaisesReachedEndExactlyOnceAndNeverForLoops() {
        val c = ctl()
        c.start(0, 1000)
        now = 999 * MS; c.tick(isReplaying = true)
        assertFalse(c.state.value.reachedEnd)
        // backing started (ready) so the deadline runs
        c.setBackingReady(true)
        now = 1000 * MS; c.tick(isReplaying = true)
        assertTrue(c.state.value.reachedEnd)
        c.stop()
        now = 0; c.start(0, 1000, loop = true)
        now = 99_000 * MS; c.tick(isReplaying = true)
        assertFalse(c.state.value.reachedEnd)
    }

    @Test fun deadlineWaitsForTheBackingAndReanchorMovesAnEmptyCapture() {
        val c = ctl()
        c.start(0, 1000)
        c.setBackingPreparing(true)
        now = 5000 * MS; c.tick(isReplaying = false)           // a long render ate the clock
        assertFalse("deferred while the backing prepares", c.state.value.reachedEnd)
        assertTrue(c.reanchorIfEmpty())
        c.setBackingReady(true)
        now = 5500 * MS; c.tick(isReplaying = true)
        assertFalse("re-anchored: only 500 ms into the region", c.state.value.reachedEnd)
        c.capture.on(60, 90, now)
        assertFalse("a capture with notes keeps its anchor", c.reanchorIfEmpty())
    }

    @Test fun inProgressStaffIsPublishedByTheTick() {
        val c = ctl()
        c.start(0, 10_000)
        c.capture.on(60, 90, 100 * MS); c.capture.off(60, 200 * MS)
        now = 300 * MS; c.tick(isReplaying = true)
        assertEquals(1, c.state.value.events.size)
    }

    @Test fun staffsAreCappedAtFourWithThePrimaryAndEmptyCapturesMakeNoJunk() {
        val c = ctl()
        val ev = listOf(StudioNoteEvent(0, 100, 60, 90))
        assertNull(c.appendStaff(InstrumentKey.PIANO, emptyList()))
        var n = 0
        val id1 = c.appendStaff(InstrumentKey.PIANO, ev) { "s${++n}" }
        c.appendStaff(InstrumentKey.VIOLIN, ev) { "s${++n}" }
        c.appendStaff(InstrumentKey.HARP, ev) { "s${++n}" }
        assertEquals("s1", id1)
        assertNull("primary + 3 extras is the cap", c.appendStaff(InstrumentKey.PIANO, ev) { "s${++n}" })
        assertEquals(3, c.state.value.staffs.size)
        c.setStaffEvents("s2", listOf(StudioNoteEvent(5, 10, 61, 90)))
        c.setStaffInstrument("s2", InstrumentKey.TRUMPET)
        assertEquals(61, c.state.value.staffs[1].events[0].note)
        assertEquals(InstrumentKey.TRUMPET, c.state.value.staffs[1].instrument)
        c.deleteStaff("s1")
        assertEquals(listOf("s2", "s3"), c.state.value.staffs.map { it.id })
        c.clearStaffs()
        assertTrue(c.state.value.staffs.isEmpty())
        assertNotNull(c.appendStaff(InstrumentKey.PIANO, ev))
    }
}
