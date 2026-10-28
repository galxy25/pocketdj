package com.levi.pocketdj.playback.health

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PauseDiscriminatorTest {
    private fun d() = PauseDiscriminator().also { it.onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) }

    @Test
    fun userRequestPause_isAListenerPause_andClearsIntent() {
        val d = d()
        assertTrue(d.intentPlaying)
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        assertTrue(d.pausedByListener)
        assertFalse(d.intentPlaying)
        assertFalse(d.interruptionOpen)
    }

    @Test
    fun remoteAndBecomingNoisy_areListenerPauses() {
        for (reason in listOf(
            Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE,
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY,
        )) {
            val d = d()
            d.onPlayWhenReadyChanged(false, reason)
            assertTrue("reason $reason", d.pausedByListener)
            assertFalse(d.intentPlaying)
        }
    }

    @Test
    fun audioFocusLoss_isAnInterruption_notAListenerPause_andKeepsIntent() {
        val d = d()
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)
        assertTrue(d.interruptionOpen)
        assertFalse(d.pausedByListener)
        assertTrue("an interruption does not change what the listener wants", d.intentPlaying)
    }

    @Test
    fun transientSuppression_opensAndClosesTheInterruption() {
        val d = d()
        d.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS)
        assertTrue(d.interruptionOpen)
        d.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_NONE)
        assertFalse(d.interruptionOpen)
        assertFalse(d.pausedByListener)
    }

    @Test
    fun exoPlayersOwnFocusRegainResume_clearsTheInterruption_andIsNeverTreatedAsAPause() {
        val d = d()
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)
        d.onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)
        assertFalse(d.interruptionOpen)
        assertFalse(d.pausedByListener)
        assertTrue(d.intentPlaying)
    }

    @Test
    fun focusLossWhileTheListenerHadPaused_keepsTheListenerPause() {
        val d = d()
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        d.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS)
        d.onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_NONE)
        assertTrue("the call ending must not un-pause what the listener paused", d.pausedByListener)
        assertFalse(d.intentPlaying)
    }

    @Test
    fun listenerPlay_clearsEverything() {
        val d = d()
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        d.onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        assertFalse(d.pausedByListener)
        assertTrue(d.intentPlaying)
    }

    @Test
    fun endOfMediaItem_isNotAListenerPause() {
        val d = d()
        d.onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM)
        assertFalse(d.pausedByListener)
        assertTrue(d.intentPlaying)
    }

    @Test
    fun haltedCascade_isNotPlaying() {
        val d = d()
        d.noteListenerIntent(false)
        assertFalse(d.intentPlaying)
        d.noteListenerIntent(true)
        assertTrue(d.intentPlaying)
        assertFalse(d.pausedByListener)
    }
}
