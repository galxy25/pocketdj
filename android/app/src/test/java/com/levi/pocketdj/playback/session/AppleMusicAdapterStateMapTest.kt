package com.levi.pocketdj.playback.session

import androidx.media3.common.C
import androidx.media3.common.Player
import com.levi.pocketdj.playback.am.AmSnapshot
import com.levi.pocketdj.playback.am.AmStatus
import com.levi.pocketdj.playback.am.AmTrack
import com.levi.pocketdj.playback.session.AppleMusicAdapterStateMap.SeekRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppleMusicAdapterStateMapTest {
    private val track = AmTrack("sng_1", "Title", "Artist", "Album", "https://art/1.jpg")
    private fun snap(s: AmStatus, pos: Long = 5_000, dur: Long? = 200_000) = AmSnapshot(s, pos, dur)

    @Test fun playbackState_mapping() {
        val m = AppleMusicAdapterStateMap
        assertEquals(Player.STATE_IDLE, m.playbackState(snap(AmStatus.PLAYING), hasTrack = false))
        assertEquals(Player.STATE_READY, m.playbackState(snap(AmStatus.PLAYING), true))
        assertEquals(Player.STATE_READY, m.playbackState(snap(AmStatus.PAUSED), true))
        assertEquals(Player.STATE_READY, m.playbackState(snap(AmStatus.STOPPED), true)) // interruption hold keeps the card
        assertEquals(Player.STATE_BUFFERING, m.playbackState(snap(AmStatus.BUFFERING), true))
    }

    @Test fun playWhenReady_onlyPlayingOrBuffering() {
        val m = AppleMusicAdapterStateMap
        assertTrue(m.playWhenReady(snap(AmStatus.PLAYING)))
        assertTrue(m.playWhenReady(snap(AmStatus.BUFFERING)))
        assertFalse(m.playWhenReady(snap(AmStatus.PAUSED)))
        assertFalse(m.playWhenReady(snap(AmStatus.STOPPED)))
    }

    @Test fun model_carriesPositionDurationAndTrack() {
        val md = AppleMusicAdapterStateMap.model(track, snap(AmStatus.PLAYING, pos = 42_000, dur = 180_000), canSkip = true)
        assertEquals(42_000L, md.positionMs)
        assertEquals(180_000L, md.durationMs)
        assertEquals(track, md.track)
        assertTrue(md.playWhenReady)
        assertEquals(Player.STATE_READY, md.playbackState)
    }

    @Test fun model_unknownDuration_isNotSeekable() {
        val md = AppleMusicAdapterStateMap.model(track, snap(AmStatus.PLAYING, dur = null), canSkip = true)
        assertNull(md.durationMs)
        assertFalse(md.commands.contains(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
    }

    @Test fun model_noTrack_isIdleWithNoCommands() {
        val md = AppleMusicAdapterStateMap.model(null, snap(AmStatus.PLAYING), canSkip = true)
        assertEquals(Player.STATE_IDLE, md.playbackState)
        assertFalse(md.playWhenReady)
        assertFalse(md.canSkip)
        assertFalse(md.commands.contains(Player.COMMAND_PLAY_PAUSE))
        assertFalse(md.commands.contains(Player.COMMAND_SEEK_TO_NEXT))
    }

    @Test fun availableCommands_withRun_offersTransportAndSkip() {
        val c = AppleMusicAdapterStateMap.availableCommands(hasTrack = true, canSkip = true, seekable = true)
        for (cmd in listOf(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP, Player.COMMAND_GET_METADATA,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        )) assertTrue("missing $cmd", c.contains(cmd))
    }

    @Test fun availableCommands_singleAmPlay_hasNoSkip() {
        val c = AppleMusicAdapterStateMap.availableCommands(hasTrack = true, canSkip = false, seekable = true)
        assertTrue(c.contains(Player.COMMAND_PLAY_PAUSE))
        assertFalse(c.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertFalse(c.contains(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM))
    }

    @Test fun currentIndex_isMiddleOfThreeWhenSkippable() {
        val skip = AppleMusicAdapterStateMap.model(track, snap(AmStatus.PLAYING), canSkip = true)
        val single = AppleMusicAdapterStateMap.model(track, snap(AmStatus.PLAYING), canSkip = false)
        assertEquals(1, AppleMusicAdapterStateMap.currentIndex(skip))
        assertEquals(0, AppleMusicAdapterStateMap.currentIndex(single))
    }

    @Test fun routeSeek_nextAndPreviousReachTheSequencer() {
        val r = { i: Int, p: Long, c: Int, cur: Int -> AppleMusicAdapterStateMap.routeSeek(i, p, c, cur) }
        assertEquals(SeekRoute.Next, r(2, C.TIME_UNSET, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, 1))
        assertEquals(SeekRoute.Next, r(1, C.TIME_UNSET, Player.COMMAND_SEEK_TO_NEXT, 1))
        assertEquals(SeekRoute.Previous, r(0, C.TIME_UNSET, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, 1))
        // ⏮ with progress restarts the current item through COMMAND_SEEK_TO_PREVIOUS: still the sequencer's call.
        assertEquals(SeekRoute.Previous, r(1, 0, Player.COMMAND_SEEK_TO_PREVIOUS, 1))
    }

    @Test fun routeSeek_withinCurrent_goesToTheSdk() {
        val r = AppleMusicAdapterStateMap.routeSeek(1, 33_000, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, 1)
        assertEquals(SeekRoute.Within(33_000), r)
        assertEquals(SeekRoute.Within(0), AppleMusicAdapterStateMap.routeSeek(0, C.TIME_UNSET, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, 0))
    }

    @Test fun routeSeek_byIndexAlone() {
        assertEquals(SeekRoute.Next, AppleMusicAdapterStateMap.routeSeek(2, 0, Player.COMMAND_SEEK_TO_MEDIA_ITEM, 1))
        assertEquals(SeekRoute.Previous, AppleMusicAdapterStateMap.routeSeek(0, 0, Player.COMMAND_SEEK_TO_MEDIA_ITEM, 1))
    }

    @Test fun mediaItem_carriesTitleArtistAlbumId() {
        val mi = AppleMusicAdapterStateMap.toMediaItem(track.copy(artworkUri = null))
        assertEquals("sng_1", mi.mediaId)
        assertEquals("Title", mi.mediaMetadata.title.toString())
        assertEquals("Artist", mi.mediaMetadata.artist.toString())
        assertEquals("Album", mi.mediaMetadata.albumTitle.toString())
    }
}
