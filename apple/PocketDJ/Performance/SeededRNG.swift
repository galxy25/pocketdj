import Foundation

// MARK: - Deterministic hashing + seeded PRNG
//
// Pure port of `src/lib/prng.ts`. The realize engine's only randomness is the
// pocket anchor pick, and it must reproduce the PWA's choices bit-for-bit so the
// same seed yields the same setlist on every device + runtime. All math is done
// in UInt32 with wrapping operators to mirror JS's `Math.imul` / `>>> 0`.

enum PRNG {
    /// FNV-1a 32-bit string hash → UInt32. Mirrors the JS `charCodeAt` (UTF-16
    /// code units), so identical seed strings hash identically across runtimes.
    static func fnv1a(_ str: String) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for unit in str.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// mulberry32 PRNG: seed → a closure returning a Double in [0,1). Mirrors the
    /// JS `Math.imul` (32-bit signed multiply) + unsigned-shift sequence exactly.
    static func mulberry32(_ seed: UInt32) -> () -> Double {
        var a = seed
        return {
            a = a &+ 0x6d2b_79f5
            var t = a
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double((t ^ (t >> 14))) / 4_294_967_296.0
        }
    }

    /// Seeded PRNG from a string seed: `mulberry32(fnv1a(seed))`.
    static func seededRng(_ seed: String) -> () -> Double {
        mulberry32(fnv1a(seed))
    }
}
