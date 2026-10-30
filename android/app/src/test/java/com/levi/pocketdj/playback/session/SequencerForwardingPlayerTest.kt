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

    @Test fun playerBuiltAfterTheSetStartedMasksSkipUntilTheServiceSeedsTheGate() {
        // Regression (emulator, PB-2): the MediaSessionService is created by the first play, AFTER the
        // sequencer already runs, so no state event reaches it. Without the seed `syncGate()` the first
        // row has no next/prev/repeat/shuffle and a media-session `next` is dropped.
        ctl.isRunning = true
        val late = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> })
        assertFalse(late.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
        late.syncGate() // PlaybackService.onCreate now seeds this once the session is built
        assertTrue(late.availableCommands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertTrue(late.availableCommands.contains(Player.COMMAND_SET_REPEAT_MODE))
        assertTrue(late.availableCommands.contains(Player.COMMAND_SET_SHUFFLE_MODE))
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

    @Test fun playOnCascadeHaltedDeckWithLoadedItemRetriesTheRow() {
        ctl.isRunning = true; ctl.isPausedByCascade = true
        ps.state = Player.STATE_BUFFERING; ps.items = 1; ps.playWhenReady = false
        p.play()
        assertEquals(listOf("startCurrent"), ctl.calls)
        assertFalse(ps.calls.contains("play"))
        assertFalse(ps.calls.contains("seekTo"))
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

    @Test fun micCaptureRefusesRemotePlayBeforeTheBasePlayer() {
        p.micGate = { false }
        p.play()
        assertTrue(ps.calls.none { it == "play" || it == "prepare" })
        assertTrue(ctl.calls.isEmpty())
        assertEquals("rc cmd=play engine=exo verdict=refused-mic-capture", logs.single())
    }

    private fun held(vararg ids: String) = com.levi.pocketdj.playback.durable.HeldQueue.from(
        com.levi.pocketdj.playback.durable.SessionSnapshot(
            sessionId = "s", source = com.levi.pocketdj.playback.durable.SessionSourceRef("playlist", "x", "X"),
            queue = ids.map { com.levi.pocketdj.playback.durable.SessionRow(it, it.uppercase()) },
            index = 0, positionMs = 9_000,
        ),
    )!!

    @Test fun resumptionSetRestoresThenResumesFromHold_neverReachesTheBasePlayer() {
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, restoreForResumption = { restored += it.snapshot.sessionId })
        val h = held("a", "b")
        rp.armResumption(h)
        ctl.isHeldForResume = true
        rp.setMediaItems(h.toMediaItems().toMutableList(), h.index, h.positionMs)
        assertEquals(listOf("s"), restored)
        assertEquals(listOf("resumeHeld"), ctl.calls)
        assertFalse(ps.calls.any { it.startsWith("setMediaItems") })
    }

    @Test fun resumptionNeverClearsAnAlreadyLiveRun() {
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, restoreForResumption = { })
        val h = held("a")
        rp.armResumption(h)
        ctl.isRunning = true // a run is live: restore is a no-op upstream, nothing is held
        rp.setMediaItems(h.toMediaItems().toMutableList())
        assertTrue(ctl.calls.isEmpty())
        assertFalse(ps.calls.any { it.startsWith("setMediaItems") })
    }

    @Test fun aForeignSetIsPassedThroughAndClearsTheArm() {
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, restoreForResumption = { restored += "x" })
        val h = held("a")
        rp.armResumption(h)
        rp.setMediaItems(held("z").toMediaItems().toMutableList(), 0, 0L)
        assertTrue(ps.calls.contains("setMediaItems"))
        assertTrue(restored.isEmpty())
        assertFalse(rp.resumptionPending())
        // the arm is gone: a later set with the held ids is a normal load, not a resumption
        ps.calls.clear()
        ctl.isHeldForResume = true
        rp.setMediaItems(h.toMediaItems().toMutableList(), true)
        assertTrue(ps.calls.contains("setMediaItems"))
        assertTrue(restored.isEmpty())
        assertTrue(ctl.calls.isEmpty())
    }

    @Test fun aStaleArmNeverSwallowsALaterMatchingLoad() {
        // System UI's boot-time recent query arms but never sets items; the user's own load of that
        // same single song 10 s later must reach the base player.
        var now = 1_000L
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, restoreForResumption = { restored += "x" }, clockMs = { now })
        val h = held("a")
        rp.armResumption(h)
        assertTrue(rp.resumptionPending())
        now += SequencerForwardingPlayer.ARM_TTL_MS + 1
        assertFalse(rp.resumptionPending())
        rp.setMediaItems(h.toMediaItems().toMutableList())
        assertTrue(ps.calls.contains("setMediaItems"))
        assertTrue(restored.isEmpty())
        assertTrue(ctl.calls.isEmpty())
    }

    @Test fun anInAppControllerSetNeverConsumesTheArm() {
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, restoreForResumption = { restored += "x" })
        val h = held("a")
        rp.armResumption(h)
        rp.callerInternal = true // PlaybackController's own MediaController load
        rp.setMediaItems(h.toMediaItems().toMutableList(), 0, 0L)
        assertTrue(ps.calls.contains("setMediaItems"))
        assertTrue(restored.isEmpty())
        assertFalse(rp.resumptionPending())
    }

    @Test fun resumptionHonoursTheMicCaptureGate() {
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { c, e, v -> logs += TransportLog.format(c, e, v) }, restoreForResumption = { restored += "x" })
        rp.micGate = { false }
        val h = held("a", "b")
        rp.armResumption(h)
        ctl.isHeldForResume = true
        rp.setMediaItems(h.toMediaItems().toMutableList(), h.index, h.positionMs)
        assertTrue(restored.isEmpty())
        assertTrue(ctl.calls.isEmpty())
        assertFalse(ps.calls.any { it.startsWith("setMediaItems") }) // swallowed, not passed on
        assertEquals(listOf("rc cmd=play engine=exo verdict=refused-mic-capture"), logs)
        assertFalse(rp.resumptionPending())
    }

    @Test fun resumptionHonoursTheSwitchboardArbiter() {
        val board = SessionSwitchboard(log = {})
        val am = object : TransportOwner {
            override val engine = "am"; override val sessionPlayer = fakePlayer(FakePlayerState())
            override var hasSounded = true
            override fun pauseForHandoff() {}
        }
        board.setOwner(am)
        val restored = mutableListOf<String>()
        val rp = SequencerForwardingPlayer(fakePlayer(ps), ctl, log = { _, _, _ -> }, board = board, restoreForResumption = { restored += "x" })
        val h = held("a")
        rp.armResumption(h)
        ctl.isHeldForResume = true
        rp.setMediaItems(h.toMediaItems().toMutableList())
        assertTrue(restored.isEmpty())
        assertTrue(ctl.calls.isEmpty())
        assertFalse(ps.calls.any { it.startsWith("setMediaItems") })
    }
}
