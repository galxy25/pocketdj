package com.levi.pocketdj.playback.session

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IdlePlayLadderTest {
    @Test fun heldWinsOverEverything() =
        assertEquals(IdlePlayVerdict.RESUME_HELD, IdlePlayLadder.decide(true, true, true))

    @Test fun startPendingIsIgnored() =
        assertEquals(IdlePlayVerdict.START_IN_FLIGHT, IdlePlayLadder.decide(true, false, true))

    @Test fun runningDeckWithNoItemStartsCurrent() =
        assertEquals(IdlePlayVerdict.START_CURRENT, IdlePlayLadder.decide(true, false, false))

    @Test fun onlyANonRunningDeckLatches() =
        assertEquals(IdlePlayVerdict.LATCHED, IdlePlayLadder.decide(false, false, false))

    @Test fun latchAgeWindow() {
        var now = 1_000L
        val l = RemotePlayLatch({ now })
        assertFalse(l.consume())
        l.arm(); now += 14_999
        assertTrue(l.consume())
        assertFalse(l.consume())
        l.arm(); now += 15_001
        assertFalse(l.consume())
        assertFalse(l.isArmed)
    }

    private fun idle(ctl: FakeControl, ps: FakePlayerState, latch: RemotePlayLatch = RemotePlayLatch()): SequencerForwardingPlayer {
        ps.state = Player.STATE_IDLE; ps.items = 0
        return SequencerForwardingPlayer(fakePlayer(ps), ctl, latch, log = { _, _, _ -> })
    }

    @Test fun idlePlayHeldResumes() {
        val c = FakeControl().apply { isRunning = true; isHeldForResume = true }
        idle(c, FakePlayerState()).play()
        assertEquals(listOf("resumeHeld"), c.calls)
    }

    @Test fun idlePlayStartInFlightDoesNothing() {
        val c = FakeControl().apply { isRunning = true; isStartPending = true }
        idle(c, FakePlayerState()).play()
        assertTrue(c.calls.isEmpty())
    }

    @Test fun idlePlayNeverSoundedStartsCurrent() {
        val c = FakeControl().apply { isRunning = true; currentNeverSounded = true }
        idle(c, FakePlayerState()).play()
        assertEquals(listOf("startCurrent"), c.calls)
    }

    @Test fun midSetCascadeHaltedDeckStartsCurrentNotLatched() {
        // a row already sounded (currentNeverSounded=false), the cascade halted, nothing loaded and
        // the sequencer no longer owns the player (gated isRunning=false) but the run still exists
        val c = FakeControl().apply { isRunning = false; hasRunOverride = true; currentNeverSounded = false }
        val latch = RemotePlayLatch()
        idle(c, FakePlayerState(), latch).play()
        assertEquals(listOf("startCurrent"), c.calls)
        assertFalse(latch.isArmed)
    }

    @Test fun unrelatedStateChangesDoNotConsumeTheLatch() {
        val latch = RemotePlayLatch()
        val c = FakeControl()
        val p = idle(c, FakePlayerState(), latch)
        p.play()
        assertTrue(latch.isArmed)
        c.isRunning = true
        p.syncGate(); p.syncGate() // sequencer state emissions
        assertTrue(latch.isArmed)
        c.isHeldForResume = true
        p.onHeldRestored()
        assertEquals(listOf("resumeHeld"), c.calls)
    }

    @Test fun idleLatchLogsRefusedIdle() {
        val logs = mutableListOf<String>()
        val ps = FakePlayerState().apply { state = Player.STATE_IDLE; items = 0 }
        SequencerForwardingPlayer(fakePlayer(ps), FakeControl(), log = { c, e, v -> logs += TransportLog.format(c, e, v) }).play()
        assertEquals(listOf("rc cmd=play engine=exo verdict=refused-idle"), logs)
    }

    @Test fun idlePlayWithNothingLatchesThenRestoreConsumes() {
        var now = 0L
        val latch = RemotePlayLatch({ now })
        val c = FakeControl()
        val p = idle(c, FakePlayerState(), latch)
        p.play()
        assertTrue(latch.isArmed)
        assertTrue(c.calls.isEmpty())
        // restore lands within the window
        c.isRunning = true; c.isHeldForResume = true; now = 5_000
        p.onHeldRestored()
        assertEquals(listOf("resumeHeld"), c.calls)
    }

    @Test fun staleLatchIsNotConsumedByRestore() {
        var now = 0L
        val latch = RemotePlayLatch({ now })
        val c = FakeControl()
        val p = idle(c, FakePlayerState(), latch)
        p.play()
        c.isRunning = true; c.isHeldForResume = true; now = 20_000
        p.onHeldRestored()
        assertTrue(c.calls.isEmpty())
    }
}
