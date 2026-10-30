package com.levi.pocketdj.studio.engine

import androidx.media3.common.Player
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner
import com.levi.pocketdj.playback.session.fakePlayer
import com.levi.pocketdj.playback.session.FakePlayerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class StudioSessionPlayerTest {
    private class Port : StudioTransportPort {
        var card: StudioCard? = null
        var plays = 0; var stops = 0; var handoffs = 0
        override fun card() = card
        override fun remotePlay() { plays++ }
        override fun remoteStop() { stops++ }
        override fun handoff() { handoffs++ }
    }

    private class Owner(override val engine: String) : TransportOwner {
        override val sessionPlayer: Player = fakePlayer(FakePlayerState())
        override val hasSounded = true
        var paused = 0
        override fun pauseForHandoff() { paused++ }
    }

    @Test fun noCardMeansIdleAndNoCommands() {
        assertEquals(Player.STATE_IDLE, StudioPlayerStateMap.playbackState(false))
        assertTrue(StudioPlayerStateMap.commands(false).size() == 0)
    }

    @Test fun cardMeansReadyWithStopAndPlayPauseButNoSkipOrSeek() {
        assertEquals(Player.STATE_READY, StudioPlayerStateMap.playbackState(true))
        val c = StudioPlayerStateMap.commands(true)
        assertTrue(c.contains(Player.COMMAND_STOP))
        assertTrue(c.contains(Player.COMMAND_PLAY_PAUSE))
        assertFalse(c.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertFalse(c.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
        assertFalse(c.contains(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
    }

    @Test fun mediaItemCarriesTitleSubtitleAndStudioId() {
        val m = StudioPlayerStateMap.toMediaItem(StudioCard("lp_1", "Kick loop", "Pocket DJ Studio"))
        assertEquals("studio:lp_1", m.mediaId)
        assertEquals("Kick loop", m.mediaMetadata.title.toString())
        assertEquals("Pocket DJ Studio", m.mediaMetadata.artist.toString())
    }

    @Test fun cardPlayRestartsAndPauseEnds() {
        val p = Port()
        StudioPlayerStateMap.route(p, true); StudioPlayerStateMap.route(p, false)
        assertEquals(1, p.plays); assertEquals(1, p.stops)
    }

    @Test fun studioClaimsPausesOthersAndResignsOnStop() {
        val board = SessionSwitchboard(log = {})
        val exo = Owner("exo"); val studio = Owner("studio")
        board.setOwner(exo)
        board.setOwner(studio)
        assertSame(studio, board.current)
        assertEquals(1, exo.paused)
        board.resign(studio)
        assertNull(board.current)
    }

    @Test fun yieldMixToExoNowCoversStudio() {
        val board = SessionSwitchboard(log = {})
        val studio = Owner("studio")
        board.setOwner(studio)
        assertTrue(board.yieldMixToExo())
        assertEquals(1, studio.paused)
        assertNull(board.current)
    }

    @Test fun yieldMixToExoStillIgnoresAppleMusic() {
        val board = SessionSwitchboard(log = {})
        val am = Owner("am")
        board.setOwner(am)
        assertFalse(board.yieldMixToExo())
        assertEquals(0, am.paused)
    }
}
