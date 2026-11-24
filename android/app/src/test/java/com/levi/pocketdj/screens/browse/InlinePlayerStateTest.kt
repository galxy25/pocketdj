package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.screens.browse.InlinePlayerState.Body
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InlinePlayerStateTest {
    @Test fun analogCropIsTheSongsSliceOfTheSide() {
        val c = InlinePlayerState.analogCrop(600_000, 780_000, 1_200_000)!!
        assertEquals(0.5f, c.from, 1e-6f); assertEquals(0.65f, c.to, 1e-6f); assertEquals(0.15f, c.span, 1e-6f)
    }

    @Test fun analogCropClampsAndRejectsUnusableWindows() {
        val past = InlinePlayerState.analogCrop(-5, 5_000_000, 1_000_000)!!
        assertEquals(0f, past.from, 0f); assertEquals(1f, past.to, 0f)
        assertNull(InlinePlayerState.analogCrop(null, 10, 100))      // digital: draw whole
        assertNull(InlinePlayerState.analogCrop(0, null, 100))
        assertNull(InlinePlayerState.analogCrop(0, 10, 0))
        assertNull(InlinePlayerState.analogCrop(500, 500, 1000))     // empty window
        assertNull(InlinePlayerState.analogCrop(2_000, 3_000, 1_000)) // starts past the file end
    }

    @Test fun bodyMapping() {
        assertEquals(Body.LIVE, InlinePlayerState.body(true, true, true))
        assertEquals(Body.APPLE_MUSIC, InlinePlayerState.body(false, true, true))
        assertEquals(Body.WAVEFORM, InlinePlayerState.body(false, false, true))
        assertEquals(Body.SCRUBBER, InlinePlayerState.body(false, false, false))
    }

    @Test fun viaLabelOnlyForAppleMusic() {
        assertEquals("via Apple Music", InlinePlayerState.viaLabel(true))
        assertNull(InlinePlayerState.viaLabel(false))
    }

    @Test fun panelIsKeyedOnSequencerCurrentThenAudible() {
        assertTrue(InlinePlayerState.matches("a", "a", "b"))
        assertFalse(InlinePlayerState.matches("b", "a", "b"))      // sequencer wins over audible
        assertTrue(InlinePlayerState.matches("b", null, "b"))      // a Browse single: audible
        assertFalse(InlinePlayerState.matches("a", null, null))
        assertTrue(InlinePlayerState.matches("sng_0123456789ab", "sng_0123456789ab_clean", null)) // variant maps to base
    }

    @Test fun seekFractionMapsToSongTimeAndRefusesWhenLive() {
        assertEquals(90_000L, InlinePlayerState.seekMs(50f, 100f, 180_000, false))
        assertEquals(0L, InlinePlayerState.seekMs(-20f, 100f, 180_000, false))
        assertEquals(180_000L, InlinePlayerState.seekMs(500f, 100f, 180_000, false))
        assertNull(InlinePlayerState.seekMs(50f, 100f, 180_000, true))
        assertNull(InlinePlayerState.seekMs(50f, 100f, null, false))
        assertNull(InlinePlayerState.seekMs(50f, 0f, 180_000, false))
    }

    @Test fun scrubberDurationFallsBackAndNeverZero() {
        assertEquals(200_000L, InlinePlayerState.scrubberDurationMs(null, 200_000))
        assertEquals(210_000L, InlinePlayerState.scrubberDurationMs(210_000, 200_000))
        assertEquals(10L, InlinePlayerState.scrubberDurationMs(null, null))
    }

    @Test fun clockFormat() {
        assertEquals("0:00", InlinePlayerState.clock(-5))
        assertEquals("3:05", InlinePlayerState.clock(185_999))
        assertEquals("12:00", InlinePlayerState.clock(720_000))
    }

    @Test fun stripSeekerReadsLatestDurationNotTheFirstComposition() {
        // First composition: engine duration unknown, catalog 200 s. Later the engine reports the clipped 187 s.
        var cur: Pair<Long?, Boolean> = 200_000L to false
        val seek = InlinePlayerState.stripSeeker { cur }
        assertEquals(100_000L, seek(50f, 100f))
        cur = 187_000L to false
        assertEquals(93_500L, seek(50f, 100f))
        cur = 187_000L to true // went live: no seeking
        assertNull(seek(50f, 100f))
    }

    @Test fun previewCapsTheScrubberRange() {
        assertEquals(30_000L, InlinePlayerState.scrubberDurationMs(null, 200_000, isPreview = true))
        assertEquals(30_000L, InlinePlayerState.scrubberDurationMs(30_000, 200_000, isPreview = true))
        assertEquals(200_000L, InlinePlayerState.scrubberDurationMs(null, 200_000))
        assertEquals(10_000L, InlinePlayerState.scrubberDurationMs(null, null, isPreview = true).coerceAtLeast(10_000L))
    }
}
