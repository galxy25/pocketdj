package com.levi.pocketdj.mix.service

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MixAudioFocusTest {
    private class FakeSystem : FocusSystem {
        var requests = 0; var abandons = 0; var grant = true
        override fun request(): Boolean { requests++; return grant }
        override fun abandon() { abandons++ }
    }

    private class FakeTransport : FocusTransport {
        override var isRunning = false
        val calls = mutableListOf<String>()
        override fun remotePause() { calls += "remotePause"; isRunning = false }
        override fun remotePlay() { calls += "remotePlay"; isRunning = true }
        override fun pauseBoth() { calls += "pauseBoth"; isRunning = false }
    }

    private val sys = FakeSystem()
    private val tr = FakeTransport()
    private val m = MixFocusMachine(sys, tr, log = {})

    private fun startPlaying() { tr.isRunning = true; m.onAudioStarted() }

    @Test fun startRequestsGainOnce() {
        startPlaying(); m.onAudioStarted()
        assertEquals(1, sys.requests)
        assertTrue(m.held)
    }

    @Test fun transientLossParksAndRegainResumesOnlyWhatWasParked() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertTrue(m.interruptionParked)
        assertEquals(listOf("remotePause"), tr.calls)
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(m.interruptionParked)
        assertEquals(listOf("remotePause", "remotePlay"), tr.calls)
    }

    @Test fun transientLossWhileIdleParksNothingSoRegainDoesNotStartMusic() {
        m.onAudioStarted()   // focus held but the user already paused
        tr.isRunning = false
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(tr.calls.isEmpty())
        assertFalse(m.interruptionParked)
    }

    @Test fun duplicateTransientLossKeepsTheLatch() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertEquals(1, tr.calls.size)
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals("remotePlay", tr.calls.last())
    }

    @Test fun deckHandStartedDuringParkClearsLatchAndRegainDoesNotDoubleResume() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        tr.isRunning = true          // user taps a deck during the call
        m.onAudioStarted()
        assertFalse(m.interruptionParked)
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(listOf("remotePause"), tr.calls)
        assertTrue(tr.isRunning)
    }

    @Test fun regainWithDeckAlreadyRunningDoesNotRemotePlay() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        tr.isRunning = true          // something resumed it without going through onAudioStarted
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(listOf("remotePause"), tr.calls)
    }

    @Test fun permanentLossPausesBothAbandonsAndDropsLatch() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        assertEquals(listOf("pauseBoth"), tr.calls)
        assertEquals(1, sys.abandons)
        assertFalse(m.held); assertFalse(m.interruptionParked)
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)   // a late gain must not resume anything
        assertEquals(listOf("pauseBoth"), tr.calls)
    }

    @Test fun duckIsLeftToTheSystem() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        assertTrue(tr.calls.isEmpty()); assertTrue(tr.isRunning)
    }

    @Test fun becomingNoisyPausesOnlyWhenRunningAndLatchesNothing() {
        startPlaying()
        m.onBecomingNoisy()
        assertEquals(listOf("remotePause"), tr.calls)
        assertFalse(m.interruptionParked)
        m.onBecomingNoisy()
        assertEquals(1, tr.calls.size)
    }

    @Test fun idleAbandonsFocusExceptWhileParked() {
        startPlaying()
        m.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        m.onTransportIdle()
        assertEquals(0, sys.abandons)   // waiting for the regain
        m.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        tr.isRunning = false
        m.onTransportIdle()
        assertEquals(1, sys.abandons)
        assertFalse(m.held)
    }

    @Test fun deniedGrantIsRetriedOnNextStart() {
        sys.grant = false
        startPlaying()
        assertFalse(m.held)
        sys.grant = true
        m.onAudioStarted()
        assertEquals(2, sys.requests)
        assertTrue(m.held)
    }
}
