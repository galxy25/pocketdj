package com.levi.pocketdj.screens.producer.instruments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PianoLayoutTest {
    // C4..C5: 8 white keys (C D E F G A B C), 5 black; width 800 => 100 px per white key.
    private val first = 60; private val last = 72
    private val w = 800f; private val h = 200f

    @Test fun namesFollowScientificPitchWithMiddleCAtSixty() {
        assertEquals("C4", PianoLayout.name(60)); assertEquals("A4", PianoLayout.name(69)); assertEquals("C#3", PianoLayout.name(49)); assertEquals("C-1", PianoLayout.name(0))
        assertTrue(PianoLayout.isBlack(61)); assertFalse(PianoLayout.isBlack(64)); assertTrue(PianoLayout.isBlack(70))
    }

    @Test fun whiteKeysAndWidth() {
        assertEquals(listOf(60, 62, 64, 65, 67, 69, 71, 72), PianoLayout.whiteKeys(first, last))
        assertEquals(100f, PianoLayout.whiteWidth(w, first, last), 0f)
    }

    @Test fun lowerHalfHitsWhiteKeys() {
        assertEquals(60, PianoLayout.keyAt(10f, 190f, w, h, first, last))
        assertEquals(62, PianoLayout.keyAt(150f, 190f, w, h, first, last))
        assertEquals(72, PianoLayout.keyAt(799f, 190f, w, h, first, last))
        assertEquals(60, PianoLayout.keyAt(55f, 190f, w, h, first, last))        // under the C# overhang
    }

    @Test fun blackKeysOverlayTheTopOfTheBoundaryBetweenWhites() {
        assertEquals(61, PianoLayout.keyAt(100f, 20f, w, h, first, last))        // C# on the C|D boundary
        assertEquals(61, PianoLayout.keyAt(75f, 20f, w, h, first, last))         // left half of the black key
        assertEquals(60, PianoLayout.keyAt(60f, 20f, w, h, first, last))         // clear of it => the white C
        assertEquals(63, PianoLayout.keyAt(200f, 20f, w, h, first, last))        // D#
        assertEquals(64, PianoLayout.keyAt(250f, 20f, w, h, first, last))        // mid-E: E has no black key
        assertEquals(66, PianoLayout.keyAt(400f, 20f, w, h, first, last))        // F#
        assertEquals(70, PianoLayout.keyAt(600f, 20f, w, h, first, last))        // A#
    }

    @Test fun belowTheBlackKeyHeightTheWhiteKeyWinsEvenOnTheBoundary() {
        assertEquals(62, PianoLayout.keyAt(100f, h * PianoLayout.BLACK_HEIGHT_FRACTION + 1, w, h, first, last))
    }

    @Test fun outsideTheBoardIsNull() {
        assertNull(PianoLayout.keyAt(-1f, 10f, w, h, first, last)); assertNull(PianoLayout.keyAt(800f, 10f, w, h, first, last))
        assertNull(PianoLayout.keyAt(10f, 200f, w, h, first, last)); assertNull(PianoLayout.keyAt(10f, 10f, 0f, 0f, first, last))
    }

    @Test fun everyNoteInTheRangeIsReachable() {
        val reachable = HashSet<Int>()
        var y = 5f
        while (y < h) { var x = 0.5f; while (x < w) { PianoLayout.keyAt(x, y, w, h, first, last)?.let { reachable.add(it) }; x += 2f }; y += 10f }
        assertEquals((first..last).toSet(), reachable)
    }

    @Test fun velocityRisesDownTheKeyAndIsAlwaysAValidMidiVelocity() {
        assertEquals(48, PianoLayout.velocity(0f, 100f)); assertEquals(127, PianoLayout.velocity(100f, 100f))
        assertTrue(PianoLayout.velocity(30f, 100f) < PianoLayout.velocity(70f, 100f))
        assertEquals(127, PianoLayout.velocity(500f, 100f)); assertEquals(96, PianoLayout.velocity(10f, 0f))
    }

    @Test fun clampRangeKeepsMidiDomainAndEndsOnAWhiteKey() {
        assertEquals(0 to 24, PianoLayout.clampRange(-5, 24))
        assertEquals(60 to 69, PianoLayout.clampRange(60, 70))                   // 70 is A#: trimmed to A
        assertEquals(120 to 127, PianoLayout.clampRange(200, 300))
    }
}
