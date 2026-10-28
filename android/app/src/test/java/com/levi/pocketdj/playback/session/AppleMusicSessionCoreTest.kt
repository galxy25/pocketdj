package com.levi.pocketdj.playback.session

import com.levi.pocketdj.playback.am.AmSnapshot
import com.levi.pocketdj.playback.am.AmStatus
import com.levi.pocketdj.playback.am.AmTrack
import com.levi.pocketdj.playback.am.AppleMusicController
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppleMusicSessionCoreTest {
    private class FakeEngine : AppleMusicController {
        override var track: AmTrack? = AmTrack("a", "A", "x", null, null)
        var status = AmStatus.PLAYING
        val calls = mutableListOf<String>()
        override fun snapshot() = AmSnapshot(status, 1000, 200_000)
        override fun play() { calls += "play" }
        override fun pause() { calls += "pause" }
        override fun pauseQuiet() { calls += "pauseQuiet" }
        override fun seekTo(positionMs: Long) { calls += "seek" }
        override fun stop() { calls += "stop" }
        override fun setChangeListener(l: (() -> Unit)?) = Unit
    }

    private val engine = FakeEngine()
    private var stopRequests = 0
    private val core = AppleMusicSessionCore(engine) { stopRequests++ }

    // MAJOR 1: the claim must wait for the Exo teardown, then happen.
    @Test fun claimIsDeferredWhileHeld_thenGrantedOnRelease() {
        core.holdClaims()
        assertFalse(core.shouldClaim(alreadyActive = false)) // SDK hit PLAYING mid-play(): do not take the session yet
        assertTrue(core.releaseClaims()) // the teardown is done; a claim was owed
        assertTrue(core.shouldClaim(alreadyActive = false))
    }

    @Test fun releaseWithNoDeferredClaim_reportsNothingOwed() {
        core.holdClaims()
        assertFalse(core.releaseClaims())
    }

    @Test fun noClaimWhenNotSoundingOrAlreadyOwner() {
        engine.status = AmStatus.BUFFERING
        assertFalse(core.shouldClaim(false))
        engine.status = AmStatus.PLAYING
        assertFalse(core.shouldClaim(true))
        engine.track = null
        assertFalse(core.shouldClaim(false))
    }

    // MAJOR 2: handoff is quiet (never the listener-intent pause) and only when AM is sounding.
    @Test fun handoff_pausesQuietly_neverThroughListenerPause() {
        core.pauseForHandoff()
        assertEquals(listOf("pauseQuiet"), engine.calls)
    }

    @Test fun handoff_isANoOpWhenAmHoldsNoLiveRow() {
        engine.track = null
        core.pauseForHandoff()
        engine.track = AmTrack("a", null, null, null, null)
        engine.status = AmStatus.PAUSED
        core.pauseForHandoff()
        assertTrue(engine.calls.isEmpty())
    }

    @Test fun everyExoStart_doesNotTouchTheAmListenerPath() {
        val board = SessionSwitchboard { }
        val amOwner = object : TransportOwner {
            override val engine = "am"
            override val sessionPlayer: androidx.media3.common.Player get() = error("unused")
            override val hasSounded = true
            override fun pauseForHandoff() = core.pauseForHandoff()
        }
        val exo = object : TransportOwner {
            override val engine = "exo"
            override val sessionPlayer: androidx.media3.common.Player get() = error("unused")
            override val hasSounded = true
            override fun pauseForHandoff() = Unit
        }
        board.register(amOwner)
        engine.status = AmStatus.STOPPED // AM idle from an earlier row
        repeat(3) { board.setOwner(exo) }
        assertTrue(engine.calls.isEmpty())
    }

    // MAJOR 4: a session stop is the full set stop, never a bare engine stop.
    @Test fun sessionStop_routesToTheControllersFullStop_notTheEngine() {
        core.stop()
        assertEquals(1, stopRequests)
        assertFalse("stop" in engine.calls)
    }
}
