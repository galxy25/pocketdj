package com.levi.pocketdj.data.games.inthepocket

/**
 * A tiny seedable PRNG (SplitMix64) — deterministic across platforms and runs. Bit-identical to
 * the Swift `SplitMix64`, so a round replayed from its uploaded seed picks the same songs.
 * The seed is a UInt64 carried as a decimal string on the wire (`InThePocketRound.seed`).
 */
class SplitMix64(seed: ULong) {
    private var state: ULong = seed

    fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }

    /** Uniform in [0, 1). */
    fun nextUnit(): Double = (next() shr 11).toLong().toDouble() / (1L shl 53).toDouble()

    companion object {
        /** Parse the wire seed (decimal UInt64 string); null if it isn't one. */
        fun parseSeed(s: String): ULong? = s.toULongOrNull()
    }
}
