package com.levi.pocketdj.mix.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CamelotTest {
    @Test fun keysListIs24InWheelOrder() {
        assertEquals(24, Camelot.keys.size)
        assertEquals("1A", Camelot.keys.first())
        assertEquals("12B", Camelot.keys.last())
        assertEquals(listOf("1A", "1B", "2A"), Camelot.keys.take(3))
    }

    @Test fun parseAcceptsTrimmedAnyCase() {
        assertEquals(CamelotKey(8, true), Camelot.parse(" 8b "))
        assertEquals(CamelotKey(12, false), Camelot.parse("12A"))
    }

    @Test fun parseRejectsGarbage() {
        for (bad in listOf(null, "", "A", "0A", "13B", "8C", "x8A", "8", "-1A")) {
            assertNull("'$bad'", Camelot.parse(bad))
        }
    }

    @Test fun rankIsContiguousWheelOrder() {
        val ranks = Camelot.keys.map { Camelot.rank(it)!! }
        assertEquals(ranks.sorted(), ranks)
        assertEquals(ranks.size, ranks.toSet().size)
        assertNull(Camelot.rank("zz"))
    }

    @Test fun signedStepsWrapShortestWayRound() {
        assertEquals(1, Camelot.signedSteps("8A", "9A"))
        assertEquals(-1, Camelot.signedSteps("9A", "8A"))
        assertEquals(1, Camelot.signedSteps("12A", "1A"))
        assertEquals(-1, Camelot.signedSteps("1A", "12A"))
    }

    @Test fun signedStepsSixBoundaryMatchesIos() {
        // iOS: d > 6 -> d-12 ; d < -6 -> d+12 ; exactly +/-6 stays as is.
        assertEquals(6, Camelot.signedSteps("1A", "7A"))
        assertEquals(-6, Camelot.signedSteps("7A", "1A"))
    }

    @Test fun signedStepsIgnoresModeAndNullOnUnknown() {
        assertEquals(0, Camelot.signedSteps("8A", "8B"))
        assertNull(Camelot.signedSteps(null, "8A"))
        assertNull(Camelot.signedSteps("8A", "nope"))
    }

    @Test fun hueAndLightness() {
        assertEquals(0.0, Camelot.hue("1A")!!, 1e-12)
        assertEquals(11.0 / 12.0, Camelot.hue("12B")!!, 1e-12)
        assertEquals(0.50, Camelot.lightness("3B")!!, 0.0)
        assertEquals(0.38, Camelot.lightness("3A")!!, 0.0)
        assertNull(Camelot.hue(null))
    }
}
