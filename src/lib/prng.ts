// Deterministic hashing + seeded PRNG (zero-dep). Shared by the cover-art
// placeholder generator and the star-map layout, so the same album always
// renders at the same spot / with the same placeholder, across reloads.

/** FNV-1a 32-bit string hash -> uint32. */
export function fnv1a(str: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** mulberry32 PRNG: seed -> () => float in [0,1). */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Seeded PRNG from a string seed. */
export function seededRng(seed: string): () => number {
  return mulberry32(fnv1a(seed));
}

/** Short stable hex key from a string (e.g. for art cache keys). */
export function hashKey(str: string): string {
  // Combine two FNV passes for fewer collisions.
  const a = fnv1a(str);
  const b = fnv1a('salt:' + str);
  return (a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0'));
}
