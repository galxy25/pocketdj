package com.levi.pocketdj.mix.service

import androidx.media3.common.Player
import com.levi.pocketdj.mix.engine.NowPlayingRule
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner
import com.levi.pocketdj.playback.session.FakePlayerState
import com.levi.pocketdj.playback.session.fakePlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class MixSessionPlayerTest {
    private fun card(pos: Long = 30_000, rate: Float = 1.04f, dur: Long? = 240_000) =
        MixCard("s1", "Title", "Artist", null, dur, pos, rate)

    private class FakeOwner(override val engine: String, override val hasSounded: Boolean = false) : TransportOwner {
        override val sessionPlayer: Player = fakePlayer(FakePlayerState())
        override fun pauseForHandoff() {}
    }

    @Test fun parkedMixBecomesTheRemoteTargetWhenNothingElseOwnsTheSession() {
        val board = SessionSwitchboard { }
        val mix = FakeOwner("mix"); board.register(mix)
        var service = 0
        assertNull("never sounded + not preferred = no remote target", board.remoteTarget())
        assertTrue(ParkedMixSession.offer(board, mix, hasParked = true) { service++ })
        assertSame(mix, board.remoteTarget())
        assertTrue(board.isActive(mix))
        assertFalse("the media service (lock-screen card) was started", service == 0)
        ParkedMixSession.withdrawIfGone(board, mix, hasParked = false, hasLoadedDeck = false)
        assertNull(board.remoteTarget())
    }

    @Test fun parkedMixDoesNotStealFromASoundingOwnerOrWithdrawWhileDecksAreLoaded() {
        val board = SessionSwitchboard { }
        val exo = FakeOwner("exo", hasSounded = true); board.setOwner(exo)
        val mix = FakeOwner("mix")
        assertFalse(ParkedMixSession.offer(board, mix, hasParked = true) { error("no service") })
        assertSame(exo, board.remoteTarget())
        val board2 = SessionSwitchboard { }
        ParkedMixSession.offer(board2, mix, hasParked = true) {}
        ParkedMixSession.withdrawIfGone(board2, mix, hasParked = false, hasLoadedDeck = true)   // materialized: stays preferred
        assertSame(mix, board2.remoteTarget())
        assertFalse(ParkedMixSession.offer(SessionSwitchboard { }, mix, hasParked = false) {})
    }

    @Test fun stateMapsTrackRateAndPosition() {
        val m = MixPlayerStateMap.model(card(), running = true, canSkip = false)
        assertTrue(m.hasTrack)
        assertEquals(Player.STATE_READY, m.playbackState)
        assertTrue(m.playWhenReady)
        assertEquals(30_000L, m.positionMs)
        assertEquals(240_000L, m.durationMs)
        assertEquals(1.04f, m.rate, 0.0001f)
        assertEquals(0, MixPlayerStateMap.currentIndex(m))
    }

    @Test fun noDeckLoadedIsIdleWithNoCommands() {
        val m = MixPlayerStateMap.model(null, running = true, canSkip = true)
        assertEquals(Player.STATE_IDLE, m.playbackState)
        assertFalse(m.playWhenReady)
        assertFalse(m.canSkip)
        assertFalse(m.commands.contains(Player.COMMAND_PLAY_PAUSE))
    }

    @Test fun carBrowsePicksStayReachableWhileAMixPlays() {
        // Android Auto delivers Mix rows as setMediaItem(mix:...); without SET_MEDIA_ITEM Media3 drops them.
        val m = MixPlayerStateMap.model(card(), running = true, canSkip = true)
        assertTrue(m.commands.contains(Player.COMMAND_SET_MEDIA_ITEM))
        assertTrue(m.commands.contains(Player.COMMAND_PREPARE))
    }

    @Test fun pausedDeckKeepsTheCardButNotPlayWhenReady() {
        val m = MixPlayerStateMap.model(card(), running = false, canSkip = false)
        assertEquals(Player.STATE_READY, m.playbackState)
        assertFalse(m.playWhenReady)
    }

    @Test fun nextPreviousOnlyOfferedForALiveAutoDjAndNeverSeek() {
        val off = MixPlayerStateMap.model(card(), true, canSkip = false)
        assertFalse(off.commands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertFalse(off.commands.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
        val on = MixPlayerStateMap.model(card(), true, canSkip = true)
        assertTrue(on.commands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertTrue(on.commands.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
        assertFalse(on.commands.contains(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
        assertEquals(1, MixPlayerStateMap.currentIndex(on))
    }

    @Test fun unusableRatesAreClampedAndZeroDurationDropped() {
        assertEquals(0.25f, MixPlayerStateMap.model(card(rate = 0f), true, false).rate, 0f)
        assertNull(MixPlayerStateMap.model(card(dur = 0), true, false).durationMs)
        assertEquals(0L, MixPlayerStateMap.model(card(pos = -5), true, false).positionMs)
    }

    @Test fun seekRoutingMapsToNextAndPrevious() {
        val ix = 1
        assertEquals(MixPlayerStateMap.Route.Next, MixPlayerStateMap.route(0, Player.COMMAND_SEEK_TO_NEXT, ix))
        assertEquals(MixPlayerStateMap.Route.Previous, MixPlayerStateMap.route(0, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, ix))
        assertEquals(MixPlayerStateMap.Route.Next, MixPlayerStateMap.route(2, Player.COMMAND_SEEK_TO_MEDIA_ITEM, ix))
        assertEquals(MixPlayerStateMap.Route.Previous, MixPlayerStateMap.route(0, Player.COMMAND_SEEK_TO_MEDIA_ITEM, ix))
        assertEquals(MixPlayerStateMap.Route.None, MixPlayerStateMap.route(1, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, ix))
    }

    @Test fun nowPlayingDeckRulePicksThePlayingDeckThenStaysSticky() {
        assertEquals(Deck.B, NowPlayingRule.pick(true, true, false, true, Deck.A))
        assertEquals(Deck.A, NowPlayingRule.pick(true, true, true, true, Deck.A))   // blend: stay
        assertEquals(Deck.B, NowPlayingRule.pick(false, true, false, false, null))
        assertNull(NowPlayingRule.pick(false, false, false, false, null))
    }

    // ---- arbiter ownership: the Mix as a TransportOwner against another engine

    private class Owner(override val engine: String, private val onPause: () -> Unit = {}) : TransportOwner {
        override val sessionPlayer: Player = fakePlayer(FakePlayerState())
        override var hasSounded = true
        var paused = 0
        override fun pauseForHandoff() { paused++; onPause() }
    }

    @Test fun mixStartPausesSetlistAndBrowseSongPausesMix() {
        val board = SessionSwitchboard(log = {})
        var mixRunning = false
        val mixPauseBoth = { mixRunning = false }
        val exo = Owner("exo")
        val mix = Owner("mix", mixPauseBoth)
        board.setOwner(exo)
        mixRunning = true; board.setOwner(mix)           // a deck starts
        assertSame(mix, board.current)
        assertEquals(1, exo.paused)
        board.setOwner(exo)                              // a Browse song plays
        assertSame(exo, board.current)
        assertEquals(1, mix.paused)
        assertFalse(mixRunning)                          // pauseForHandoff == engine.pauseBoth
    }

    @Test fun repeatedDeckStartsKeepOwnershipAndKeepPausingTheOther() {
        val board = SessionSwitchboard(log = {})
        var changes = 0
        board.onChange = { changes++ }
        val exo = Owner("exo"); val mix = Owner("mix")
        board.setOwner(exo); changes = 0
        board.setOwner(mix); board.setOwner(mix)
        assertEquals(1, changes)
        assertEquals(2, exo.paused)
    }

    @Test fun mixRestoredNeverSoundedIsNoRemoteTargetUnlessPreferred() {
        val board = SessionSwitchboard(log = {})
        val mix = Owner("mix").also { it.hasSounded = false }
        board.setOwner(mix)
        assertNull(board.remoteTarget())
        board.prefer(mix)
        assertSame(mix, board.remoteTarget())
    }

    // ---- MixTransportRouter: the exact command mapping MixSessionPlayer runs

    private class FakePort(var card: MixCard? = card0(), override var canSkip: Boolean = true) : MixTransportPort {
        val calls = mutableListOf<String>()
        override fun card() = card
        override var isRunning = true
        override var mixWantsAudio = true
        override val skipFadeSeconds = 2.5
        override val hasSounded = true
        override fun remotePlay() { calls += "play" }
        override fun remotePause() { calls += "pause" }
        override fun remoteSkip(fadeSeconds: Double) { calls += "skip$fadeSeconds" }
        override fun pauseBoth() { calls += "pauseBoth" }
    }

    @Test fun routerMapsPlayPauseStopAndHandoff() {
        val port = FakePort(); var handoffs = 0
        val r = MixTransportRouter(port) { handoffs++ }
        r.setPlayWhenReady(true); r.setPlayWhenReady(false); r.stop(); r.handoff()
        assertEquals(listOf("play", "pause", "pause", "pauseBoth"), port.calls)
        assertEquals(1, handoffs)
    }

    @Test fun routerMapsNextPreviousThroughTheThreeItemPlaylist() {
        val port = FakePort(); val r = MixTransportRouter(port)
        r.seek(2, Player.COMMAND_SEEK_TO_NEXT)
        r.seek(0, Player.COMMAND_SEEK_TO_PREVIOUS)
        r.seek(1, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        assertEquals(listOf("skip5.0", "skip2.5"), port.calls)
    }

    @Test fun cardIsBufferingAndFrozenWhileStreamHeld() {
        val held = MixPlayerStateMap.model(card0().copy(held = true), running = true, canSkip = false)
        assertEquals(Player.STATE_BUFFERING, held.playbackState)
        assertTrue(held.held)
        assertEquals(Player.STATE_READY, MixPlayerStateMap.model(card0(), true, false).playbackState)
    }

    @Test fun mixOwnershipViaBoardPausesOtherAndHandsOffBack() {
        val board = SessionSwitchboard(log = {})
        val port = FakePort(); var handoffs = 0
        val router = MixTransportRouter(port) { handoffs++ }
        val exo = Owner("exo")
        val mix = Owner("mix") { router.handoff() }
        board.setOwner(mix); board.setOwner(exo)
        assertEquals(listOf("pauseBoth"), port.calls); assertEquals(1, handoffs)
    }
}

private fun card0() = MixCard("s1", "Title", "Artist", null, 240_000, 30_000, 1.0f)
