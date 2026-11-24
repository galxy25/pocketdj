package com.levi.pocketdj.remote

import androidx.media3.common.Player
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.TransportRedirect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteGateSurfacesTest {
    private fun controllerGate(sent: MutableList<RemoteRedirect>) = RemoteControllerGate().apply {
        isController = { true }
        forwarder = { sent.add(it) }
    }

    @Test fun everySurfaceEntryPoint_forwardsExactlyOneRedirect() {
        val sent = mutableListOf<RemoteRedirect>()
        val g = controllerGate(sent)
        val a = QueueItem("a")
        val cases = listOf(
            TransportRedirect.PlayPause to RemoteRedirect.PlayPause,
            TransportRedirect.SetPlaying(true) to RemoteRedirect.Play,
            TransportRedirect.SetPlaying(false) to RemoteRedirect.Pause,
            TransportRedirect.SkipNext to RemoteRedirect.Next,
            TransportRedirect.SkipPrevious to RemoteRedirect.Previous,
            TransportRedirect.Play(listOf(a), 0) to RemoteRedirect.PlayItems(listOf(a), 0),
            TransportRedirect.PlayNow(a) to RemoteRedirect.PlayNow(a),
            TransportRedirect.Jump("u") to RemoteRedirect.Jump("u"),
        )
        for ((req, want) in cases) {
            sent.clear()
            assertTrue(g.intercept(req))
            assertEquals(listOf(want), sent)
        }
        sent.clear()
        assertTrue(g.forward(RemoteRedirect.Seek(1234)))
        assertTrue(g.forward(RemoteRedirect.PlayPause))
        assertEquals(listOf(RemoteRedirect.Seek(1234), RemoteRedirect.PlayPause), sent)
    }

    @Test fun localStart_isRefusedAndNeverForwarded() {
        val sent = mutableListOf<RemoteRedirect>()
        val g = controllerGate(sent)
        assertTrue(g.intercept(TransportRedirect.LocalStart))
        assertTrue(sent.isEmpty())
    }

    @Test fun noGate_isPassthrough() {
        val sent = mutableListOf<RemoteRedirect>()
        val g = RemoteControllerGate().apply { forwarder = { sent.add(it) } } // not a controller
        assertFalse(g.intercept(TransportRedirect.SkipNext))
        assertFalse(g.intercept(TransportRedirect.LocalStart))
        assertFalse(g.forward(RemoteRedirect.Play))
        assertTrue(sent.isEmpty())
    }

    @Test fun fakeController_forwardsAndLogs() {
        val logs = mutableListOf<String>()
        val g = RemoteControllerGate { logs.add(it) }
        g.fakeController = true
        assertTrue(g.forward(RemoteRedirect.PlayPause))
        assertEquals(listOf("remote redirect playPause"), logs)
        g.fakeController = false
        assertFalse(g.forward(RemoteRedirect.PlayPause))
    }

    @Test fun silencers_allRun_failingOneDoesNotBlockRest() {
        val g = RemoteControllerGate()
        val ran = mutableListOf<Int>()
        g.addSilencer { ran.add(1) }
        g.addSilencer { error("boom") }
        val third = { ran.add(3); Unit }
        g.addSilencer(third)
        g.silenceAll(); g.silenceAll()
        assertEquals(listOf(1, 3, 1, 3), ran)
        g.removeSilencer(third)
        assertEquals(2, g.silencerCount)
    }

    @Test fun systemPause_noisyAndPermanentLoss() {
        val c = SystemPauseClassifier { 0L }
        c.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY)
        assertTrue(c.isSystemPaused)
        c.onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        assertFalse(c.isSystemPaused)
        c.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)
        assertTrue(c.isSystemPaused)
    }

    @Test fun listenerPause_isNotSystemPause() {
        val c = SystemPauseClassifier { 0L }
        c.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        assertFalse(c.isSystemPaused)
        c.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE)
        assertFalse(c.isSystemPaused)
    }

    @Test fun transientLoss_onlySystemPausedIfItDidNotResume() {
        var now = 0L
        val c = SystemPauseClassifier { now }
        c.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS)
        now = SystemPauseClassifier.TRANSIENT_GRACE_MS - 1
        assertFalse(c.isSystemPaused)
        now = SystemPauseClassifier.TRANSIENT_GRACE_MS
        assertTrue(c.isSystemPaused)
        c.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_NONE) // resumed on focus gain
        assertFalse(c.isSystemPaused)
    }
}
