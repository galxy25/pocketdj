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

    @Test fun nextWhenNotRunningSingleItemIsLoggedAndNotForwarded() {
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

    @Test fun bufferingPlayRekicksWithARealSeek() {
        ps.state = Player.STATE_BUFFERING; ps.playWhenReady = true
        p.play()
        assertTrue(ps.calls.contains("seekTo"))
        assertFalse(ps.calls.contains("pause"))
        assertEquals("rc cmd=play engine=exo verdict=rekick-buffering", logs.single())
    }

    @Test fun mediaButtonToggleWhileBufferingKicksInsteadOfPausing() {
        ps.state = Player.STATE_BUFFERING; ps.playWhenReady = true
        assertTrue(p.onMediaButtonPlayToggle())
        assertTrue(ps.calls.contains("seekTo"))
        assertFalse(ps.calls.contains("pause"))
    }

    @Test fun mediaButtonAfterListenerPauseIsNotARekick() {
        ps.state = Player.STATE_BUFFERING; ps.playWhenReady = true
        p.pause()
        assertFalse(p.onMediaButtonPlayToggle())
        ps.state = Player.STATE_READY
        assertFalse(p.onMediaButtonPlayToggle())
    }

    @Test fun multiItemQueueNotRunningDelegatesNextPrevAndKeepsCommands() {
        ps.items = 3
        p.seekToNextMediaItem(); p.seekToPrevious(); p.seekToNext(); p.seekToPreviousMediaItem()
        assertTrue(ctl.calls.isEmpty())
        assertEquals(listOf("seekToNextMediaItem", "seekToPrevious", "seekToNext", "seekToPreviousMediaItem"),
            ps.calls.filter { it.startsWith("seekTo") })
        assertEquals("rc cmd=next engine=exo verdict=handled", logs.first())
        // base commands pass through for an album; single items stay masked
        assertTrue(p.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertTrue(p.isCommandAvailable(Player.COMMAND_SET_REPEAT_MODE))
        ps.items = 1
        assertFalse(p.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
    }

    @Test fun repeatShuffleNotRunningGoToBasePlayer() {
        ps.items = 3
        p.setRepeatMode(Player.REPEAT_MODE_ALL); p.setShuffleModeEnabled(true)
        assertTrue(ps.calls.containsAll(listOf("setRepeatMode", "setShuffleModeEnabled")))
        assertEquals(RepeatMode.OFF, ctl.repeatMode)
    }

    @Test fun repeatShuffleChangesPushEventsOnce() {
        val repeats = mutableListOf<Int>(); val shuffles = mutableListOf<Boolean>()
        p.addListener(object : Player.Listener {
            override fun onRepeatModeChanged(repeatMode: Int) { repeats += repeatMode }
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) { shuffles += shuffleModeEnabled }
        })
        ctl.isRunning = true
        p.syncGate()
        assertTrue(repeats.isEmpty() && shuffles.isEmpty())
        ctl.repeatMode = RepeatMode.ONE; ctl.shuffleEnabled = true // changed from the deck
        p.syncGate(); p.syncGate()
        assertEquals(listOf(Player.REPEAT_MODE_ONE), repeats)
        assertEquals(listOf(true), shuffles)
        p.setRepeatMode(Player.REPEAT_MODE_ALL) // remote controller
        assertEquals(listOf(Player.REPEAT_MODE_ONE, Player.REPEAT_MODE_ALL), repeats)
    }

    @Test fun instantMetadataClearOnlyIfStillShowing() {
        val a = androidx.media3.common.MediaMetadata.Builder().setTitle("a").build()
        val b = androidx.media3.common.MediaMetadata.Builder().setTitle("b").build()
        p.showInstantMetadata(b)
        p.clearInstantMetadata(a)
        assertEquals("b", p.mediaMetadata.title)
        p.clearInstantMetadata(b)
        assertEquals(androidx.media3.common.MediaMetadata.EMPTY, p.mediaMetadata)
    }

    @Test fun remoteRefusedByArbiterWhenAnotherEngineOwns() {
        val board = SessionSwitchboard(log = {})
        val am = object : TransportOwner {
            override val engine = "am"; override val sessionPlayer = fakePlayer(FakePlayerState())
            override var hasSounded = true
            override fun pauseForHandoff() {}
        }
        board.setOwner(am)
        val q = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { c, e, v -> logs += TransportLog.format(c, e, v) }, board = board)
        ctl.isRunning = true
        q.seekToNext(); q.play()
        assertTrue(ctl.calls.isEmpty())
        assertEquals(listOf("rc cmd=next engine=exo verdict=not-owner", "rc cmd=play engine=exo verdict=not-owner"), logs)
    }

    @Test fun internalCallsDoNotLogAsRemote() {
        p.callerInternal = true
        p.pause()
        assertTrue(logs.isEmpty())
        p.callerInternal = false
        p.silently { p.pause() }
        assertTrue(logs.isEmpty())
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
