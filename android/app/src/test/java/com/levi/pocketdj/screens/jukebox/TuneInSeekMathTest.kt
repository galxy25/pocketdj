package com.levi.pocketdj.screens.jukebox

import com.levi.pocketdj.data.jukebox.JukeboxGuestState
import com.levi.pocketdj.data.jukebox.TuneInSeekMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TuneInSeekMathTest {
    @Test fun addsElapsedSinceSnapshot() =
        assertEquals(13_000L, TuneInSeekMath.seekMs(10_000, 1_000_000.0, 1_003_000))

    @Test fun missingPositionStartsAtZero() =
        assertEquals(0L, TuneInSeekMath.seekMs(null, 100_000.0, 102_000))

    @Test fun elapsedIsCappedForHeartbeatStaleness() =
        assertEquals(15_000L, TuneInSeekMath.seekMs(10_000, 100_000.0, 115_000))

    @Test fun missingUpdatedAtUsesPositionOnly() {
        assertEquals(7_000L, TuneInSeekMath.seekMs(7_000, null, 999_999))
        assertEquals(7_000L, TuneInSeekMath.seekMs(7_000, 0.0, 999_999))
    }

    @Test fun clockSkewNeverSeeksBackwards() =
        assertEquals(5_000L, TuneInSeekMath.seekMs(5_000, 2_000_000.0, 1_000_000))

    @Test fun clampedToLength() =
        assertEquals(60_000L, TuneInSeekMath.seekMs(59_000, 0.0 + 1_000, 400_000, lengthMs = 60_000))

    @Test fun negativePositionTreatedAsZero() = assertEquals(0L, TuneInSeekMath.seekMs(-5, null, 1))

    @Test fun onlyHttpsStreamsPlay() {
        assertTrue(TuneInSeekMath.isPlayableStream("https://bucket/a.mp3"))
        assertTrue(TuneInSeekMath.isPlayableStream("HTTPS://bucket/a.mp3"))
        assertFalse(TuneInSeekMath.isPlayableStream("http://bucket/a.mp3"))
        assertFalse(TuneInSeekMath.isPlayableStream("https://"))
        assertFalse(TuneInSeekMath.isPlayableStream(null))
        assertFalse(TuneInSeekMath.isPlayableStream(""))
    }

    @Test fun trackKeyChangesWithTrackOrStream() {
        val a = JukeboxGuestState.NowPlaying("T", "A", streamUrl = "https://x/1.mp3")
        val same = a.copy(positionMs = 9_999)
        assertEquals(TuneInSeekMath.trackKey(a), TuneInSeekMath.trackKey(same)) // position alone never re-tunes
        assertNotEquals(TuneInSeekMath.trackKey(a), TuneInSeekMath.trackKey(a.copy(title = "U")))
        assertNotEquals(TuneInSeekMath.trackKey(a), TuneInSeekMath.trackKey(a.copy(streamUrl = "https://x/2.mp3")))
        assertEquals("", TuneInSeekMath.trackKey(null))
    }

    @Test fun requestToneBuckets() {
        assertEquals(RequestTone.Accepted, requestTone("queued"))
        assertEquals(RequestTone.Accepted, requestTone("played"))
        assertEquals(RequestTone.Denied, requestTone("denied"))
        assertEquals(RequestTone.Pending, requestTone("pending"))
        assertEquals(RequestTone.Pending, requestTone(null))
    }
}
