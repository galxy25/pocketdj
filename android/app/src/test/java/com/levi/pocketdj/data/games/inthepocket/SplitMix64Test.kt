package com.levi.pocketdj.data.games.inthepocket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SplitMix64Test {
    @Test fun referenceValueForSeedOneMatchesSwift() {
        val g = SplitMix64(1uL)
        assertEquals(0x910A2DEC89025CC1uL, g.next())
        val u = g.nextUnit()
        assertTrue(u >= 0.0 && u < 1.0)
    }

    @Test fun sameSeedSameStreamDifferentSeedDiffers() {
        val a = SplitMix64(42uL); val b = SplitMix64(42uL); val c = SplitMix64(43uL)
        val sa = List(8) { a.next() }
        assertEquals(sa, List(8) { b.next() })
        assertNotEquals(sa, List(8) { c.next() })
    }

    @Test fun zeroSeedFirstValueIsTheCanonicalSplitMix() {
        // Canonical SplitMix64(0) first output.
        assertEquals(0xE220A8397B1DCDAFuL, SplitMix64(0uL).next())
    }

    @Test fun nextUnitStaysInHalfOpenUnitInterval() {
        val g = SplitMix64(ULong.MAX_VALUE)
        repeat(5000) { val u = g.nextUnit(); assertTrue(u >= 0.0 && u < 1.0) }
    }

    @Test fun seedStringsCarryTheFull64Bits() {
        assertEquals(ULong.MAX_VALUE, SplitMix64.parseSeed("18446744073709551615"))
        assertNull(SplitMix64.parseSeed("-1"))
        assertNull(SplitMix64.parseSeed("abc"))
    }
}
