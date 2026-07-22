package com.levi.pocketdj.data.collections

/**
 * Deterministic hashing + seeded PRNG — port of iOS `Performance/SeededRNG.swift`
 * (itself a port of the PWA's `src/lib/prng.ts`). The realize engine's only
 * randomness is the pocket anchor pick, and it must reproduce the PWA/iOS
 * choices bit-for-bit so the same seed yields the same setlist on every
 * device + runtime.
 *
 * All math runs in Kotlin `Int` (32-bit, wrapping `+`/`*` match JS `Math.imul`)
 * with `ushr` for the JS `>>>` unsigned shifts.
 */
object Prng {
    /** FNV-1a 32-bit string hash over UTF-16 code units (JS `charCodeAt` parity). */
    fun fnv1a(str: String): Int {
        var h = 0x811c9dc5.toInt()
        for (unit in str) { // Kotlin String iterates UTF-16 code units.
            h = h xor unit.code
            h *= 0x01000193
        }
        return h
    }

    /** mulberry32 PRNG: seed → a closure returning a Double in [0, 1). */
    fun mulberry32(seed: Int): () -> Double {
        var a = seed
        return {
            a += 0x6d2b79f5
            var t = a
            t = (t xor (t ushr 15)) * (t or 1)
            t = t xor (t + ((t xor (t ushr 7)) * (t or 61)))
            (t xor (t ushr 14)).toUInt().toDouble() / 4_294_967_296.0
        }
    }

    /** Seeded PRNG from a string seed: `mulberry32(fnv1a(seed))`. */
    fun seededRng(seed: String): () -> Double = mulberry32(fnv1a(seed))
}
