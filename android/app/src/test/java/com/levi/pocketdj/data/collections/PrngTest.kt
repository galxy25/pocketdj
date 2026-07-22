package com.levi.pocketdj.data.collections

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Bit-for-bit PRNG parity with the PWA/iOS (specs/realize-play.md §4.1).
 * Reference vectors generated from the JS implementation
 * (`Math.imul` fnv1a + mulberry32) — the same seed must yield the same
 * setlist on every device + runtime.
 */
class PrngTest {

    @Test
    fun fnv1a_matchesReferenceVectors() {
        assertEquals(57_871_657L, Prng.fnv1a("pocketdj").toUInt().toLong())
        assertEquals(3_638_103_021L, Prng.fnv1a("test-seed").toUInt().toLong())
        assertEquals(1_470_105_651L, Prng.fnv1a("pls_abc123").toUInt().toLong())
        assertEquals(2_166_136_261L, Prng.fnv1a("").toUInt().toLong())
        // Non-BMP-free unicode goes through UTF-16 code units (charCodeAt parity).
        assertEquals(3_579_979_393L, Prng.fnv1a("☃ unicode").toUInt().toLong())
    }

    @Test
    fun mulberry32_matchesReferenceSequence() {
        val rng = Prng.seededRng("test-seed")
        val expected = doubleArrayOf(
            0.35841897572390735,
            0.52694102283567190,
            0.12075472134165466,
            0.45667799538932741,
            0.029797720955684781,
            0.043120229151099920,
        )
        for (value in expected) assertEquals(value, rng(), 0.0)
    }

    @Test
    fun mulberry32_seedOne_matchesReference() {
        val rng = Prng.mulberry32(1)
        assertEquals(0.62707394058816135, rng(), 0.0)
        assertEquals(0.0027357211802154779, rng(), 0.0)
        assertEquals(0.52744703995995224, rng(), 0.0)
    }

    @Test
    fun seededRng_sameSeedSameSequence_differentSeedDiverges() {
        val a = Prng.seededRng("seed-a")
        val b = Prng.seededRng("seed-a")
        val c = Prng.seededRng("seed-b")
        val fromA = List(10) { a() }
        val fromB = List(10) { b() }
        val fromC = List(10) { c() }
        assertEquals(fromA, fromB)
        assert(fromA != fromC)
    }
}
