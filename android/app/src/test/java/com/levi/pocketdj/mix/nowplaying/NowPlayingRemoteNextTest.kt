package com.levi.pocketdj.mix.nowplaying

import androidx.media3.common.C
import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Test

/** P2-DJ-9 review: the DSP session's lock-screen / headset / Auto next is the 5 s sweep, not the in-app Skip fade. */
class NowPlayingRemoteNextTest {
    private class Port : NowPlayingDspPort {
        val calls = mutableListOf<String>()
        override fun card() = null
        override val isPlaying = false
        override val hasSounded = false
        override fun play() {}
        override fun pause() {}
        override fun skipNext() { calls += "skipNext" }
        override fun skipNextRemote() { calls += "skipNextRemote" }
        override fun skipPrevious() { calls += "skipPrevious" }
        override fun release() {}
    }

    @Test fun remoteNextRoutesToTheFastSkip() {
        val p = Port()
        routeSeek(p, C.INDEX_UNSET, C.TIME_UNSET, Player.COMMAND_SEEK_TO_NEXT)
        assertEquals(listOf("skipNextRemote"), p.calls)
    }

    @Test fun remotePreviousStillRoutesToPrevious() {
        val p = Port()
        routeSeek(p, C.INDEX_UNSET, C.TIME_UNSET, Player.COMMAND_SEEK_TO_PREVIOUS)
        assertEquals(listOf("skipPrevious"), p.calls)
    }

    @Test fun portDefaultRemoteNextFallsBackToSkipNext() {
        val p = object : NowPlayingDspPort by Port() {}
        // delegation forwards skipNextRemote; a bare implementer gets the default (= skipNext)
        val bare = object : NowPlayingDspPort {
            var n = 0
            override fun card() = null
            override val isPlaying = false
            override val hasSounded = false
            override fun play() {}
            override fun pause() {}
            override fun skipNext() { n++ }
            override fun skipPrevious() {}
            override fun release() {}
        }
        bare.skipNextRemote()
        assertEquals(1, bare.n)
        p.hashCode()
    }
}
