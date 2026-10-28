package com.levi.pocketdj.playback.session

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionSwitchboardTest {
    private class Owner(override val engine: String, override var hasSounded: Boolean = true) : TransportOwner {
        override val sessionPlayer: Player = fakePlayer(FakePlayerState())
        var paused = 0
        override fun pauseForHandoff() { paused++ }
    }

    private val board = SessionSwitchboard(log = {})

    @Test fun lastStartedOwnsAndPausesTheOther() {
        val exo = Owner("exo"); val mix = Owner("mix")
        board.setOwner(exo)
        board.setOwner(mix)
        assertSame(mix, board.current)
        assertTrue(board.isActive(mix)); assertFalse(board.isActive(exo))
        assertEquals(1, exo.paused)
        assertEquals(0, mix.paused)
    }

    @Test fun onChangeFiresOnlyOnOwnershipChange() {
        val seen = mutableListOf<String?>()
        board.onChange = { seen += it?.engine }
        val a = Owner("exo"); val b = Owner("am")
        board.setOwner(a); board.setOwner(a); board.setOwner(b)
        assertEquals(listOf("exo", "am"), seen)
        board.resign(b)
        assertEquals(listOf("exo", "am", null), seen)
        board.resign(b)
        assertEquals(3, seen.size)
    }

    @Test fun restoredNeverSoundedIsNotARemoteTarget() {
        val am = Owner("am", hasSounded = false)
        board.setOwner(am)
        assertNull(board.remoteTarget())
        assertNull(board.routeRemotePlay())
        am.hasSounded = true
        assertSame(am, board.remoteTarget())
    }

    @Test fun preferAfterRestoreMakesEngineAnswerWhileOwnerNil() {
        val am = Owner("am", hasSounded = false)
        assertFalse(board.isActive(am))
        board.prefer(am)
        assertTrue(board.isActive(am))
        assertSame(am, board.remoteTarget())
    }

    @Test fun resignHandsBackToFallbackPlayer() {
        val exo = Owner("exo"); val mix = Owner("mix")
        board.setOwner(exo); board.setOwner(mix)
        val fallback = fakePlayer(FakePlayerState())
        assertSame(mix.sessionPlayer, board.sessionPlayer(fallback))
        board.resign(mix)
        assertNull(board.current)
        assertSame(fallback, board.sessionPlayer(fallback))
        board.setOwner(exo)
        assertTrue(board.isActive(exo))
    }

    @Test fun resignOfNonOwnerDoesNotDisturbOwner() {
        val a = Owner("exo"); val b = Owner("mix")
        board.setOwner(a); board.register(b)
        board.resign(b)
        assertSame(a, board.current)
    }
}
