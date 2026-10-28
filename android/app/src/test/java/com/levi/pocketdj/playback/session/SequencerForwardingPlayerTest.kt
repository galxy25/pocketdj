package com.levi.pocketdj.playback.session

import androidx.media3.common.Player
import com.levi.pocketdj.playback.sequencer.RepeatMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SequencerForwardingPlayerTest {
    private val ps = FakePlayerState()
    private val ctl = FakeControl()
    private val logs = mutableListOf<String>()
    private val p = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { c, e, v -> logs += TransportLog.format(c, e, v) })

    @Test fun nextAndPrevRouteToSequencerAllVariants() {
        ctl.isRunning = true
        p.seekToNext(); p.seekToNextMediaItem(); p.seekToPrevious(); p.seekToPreviousMediaItem()
        assertEquals(listOf("next", "next", "prev", "prev"), ctl.calls)
        assertFalse(ps.calls.any { it.startsWith("seekTo") })
        assertEquals("rc cmd=next engine=exo verdict=handled", logs.first())
    }

    @Test fun nextWhenNotRunningIsLoggedAndNotForwarded() {
        p.seekToNext()
        assertTrue(ctl.calls.isEmpty())
        assertEquals("rc cmd=next engine=exo verdict=not-running", logs.single())
    }

    @Test fun repeatAndShuffleMirrorSequencerState() {
        ctl.isRunning = true
        p.setRepeatMode(Player.REPEAT_MODE_ONE)
        p.setShuffleModeEnabled(true)
        assertEquals(RepeatMode.ONE, ctl.repeatMode)
        assertTrue(ctl.shuffleEnabled)
        assertEquals(Player.REPEAT_MODE_ONE, p.repeatMode)
        assertTrue(p.shuffleModeEnabled)
        ctl.repeatMode = RepeatMode.ALL
        assertEquals(Player.REPEAT_MODE_ALL, p.repeatMode)
        assertEquals(RepeatMode.OFF, SequencerForwardingPlayer.fromExo(99))
    }

    @Test fun availableCommandsFollowRunningState() {
        assertFalse(p.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertFalse(p.isCommandAvailable(Player.COMMAND_SET_REPEAT_MODE))
        ctl.isRunning = true
        p.syncGate()
        assertTrue(p.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertTrue(p.isCommandAvailable(Player.COMMAND_SET_SHUFFLE_MODE))
        assertTrue(p.hasNextMediaItem())
        assertTrue(p.availableCommands.contains(Player.COMMAND_PLAY_PAUSE))
    }

    @Test fun bufferingPlayRekicksInsteadOfToggling() {
        ps.state = Player.STATE_BUFFERING; ps.playWhenReady = true
        p.play()
        assertTrue(ps.calls.containsAll(listOf("prepare", "play")))
        assertEquals("rc cmd=play engine=exo verdict=rekick-buffering", logs.single())
    }

    @Test fun readyPlayJustPlays() {
        p.play()
        assertEquals(listOf("play"), ps.calls.filter { it == "play" || it == "prepare" })
    }

    @Test fun commandLogFormat() {
        assertEquals("rc cmd=favorite engine=am verdict=refused-idle",
            TransportLog.format(TransportLog.Cmd.FAVORITE, "am", TransportLog.Verdict.REFUSED_IDLE))
    }
}
