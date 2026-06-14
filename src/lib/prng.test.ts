import { describe, it, expect } from 'vitest';
import { fnv1a, mulberry32, seededRng, hashKey } from './prng';

describe('fnv1a', () => {
  it('is deterministic for the same input', () => {
    expect(fnv1a('hello')).toBe(fnv1a('hello'));
  });

  it('returns an unsigned 32-bit integer', () => {
    for (const s of ['', 'a', 'hello world', 'alb_12345', '🎵unicode']) {
      const h = fnv1a(s);
      expect(Number.isInteger(h)).toBe(true);
      expect(h).toBeGreaterThanOrEqual(0);
      expect(h).toBeLessThanOrEqual(0xffffffff);
    }
  });

  it('uses the FNV-1a offset basis for the empty string', () => {
    // No bytes mixed in -> the 32-bit offset basis 0x811c9dc5.
    expect(fnv1a('')).toBe(0x811c9dc5);
  });

  it('differs for different inputs (incl. single-char and order changes)', () => {
    expect(fnv1a('a')).not.toBe(fnv1a('b'));
    expect(fnv1a('ab')).not.toBe(fnv1a('ba'));
    expect(fnv1a('hello')).not.toBe(fnv1a('hellp'));
  });

  it('matches a known FNV-1a 32-bit reference value', () => {
    // Independently computed reference for the FNV-1a 32-bit algorithm.
    expect(fnv1a('a')).toBe(0xe40c292c);
  });
});

describe('mulberry32', () => {
  it('produces floats in [0, 1)', () => {
    const rng = mulberry32(12345);
    for (let i = 0; i < 1000; i++) {
      const v = rng();
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThan(1);
    }
  });

  it('same seed => identical sequence', () => {
    const a = mulberry32(42);
    const b = mulberry32(42);
    const seqA = Array.from({ length: 20 }, () => a());
    const seqB = Array.from({ length: 20 }, () => b());
    expect(seqA).toEqual(seqB);
  });

  it('different seeds => different sequences', () => {
    const a = mulberry32(1);
    const b = mulberry32(2);
    const seqA = Array.from({ length: 10 }, () => a());
    const seqB = Array.from({ length: 10 }, () => b());
    expect(seqA).not.toEqual(seqB);
  });

  it('advances state (successive draws are not all equal)', () => {
    const rng = mulberry32(7);
    const vals = Array.from({ length: 5 }, () => rng());
    expect(new Set(vals).size).toBeGreaterThan(1);
  });
});

describe('seededRng', () => {
  it('same string seed => identical sequence (cross-reload stability)', () => {
    const a = seededRng('alb_xyz');
    const b = seededRng('alb_xyz');
    const seqA = Array.from({ length: 25 }, () => a());
    const seqB = Array.from({ length: 25 }, () => b());
    expect(seqA).toEqual(seqB);
  });

  it('different string seeds => different sequences', () => {
    const a = Array.from({ length: 10 }, seededRng('x:alb_1'));
    const b = Array.from({ length: 10 }, seededRng('x:alb_2'));
    expect(a).not.toEqual(b);
  });

  it('is equivalent to mulberry32(fnv1a(seed))', () => {
    const seed = 'r:alb_99';
    const viaSeeded = seededRng(seed);
    const viaCompose = mulberry32(fnv1a(seed));
    expect(Array.from({ length: 8 }, () => viaSeeded())).toEqual(
      Array.from({ length: 8 }, () => viaCompose()),
    );
  });

  it('spreads roughly uniformly across [0,1) (sanity: mean near 0.5)', () => {
    const rng = seededRng('spread-seed');
    const n = 5000;
    let sum = 0;
    const buckets = new Array(10).fill(0);
    for (let i = 0; i < n; i++) {
      const v = rng();
      sum += v;
      buckets[Math.min(9, Math.floor(v * 10))]++;
    }
    const mean = sum / n;
    expect(mean).toBeGreaterThan(0.45);
    expect(mean).toBeLessThan(0.55);
    // Every decile bucket should be populated (no gross clustering).
    for (const b of buckets) expect(b).toBeGreaterThan(0);
  });
});

describe('hashKey', () => {
  it('is deterministic', () => {
    expect(hashKey('cover:alb_1')).toBe(hashKey('cover:alb_1'));
  });

  it('is a 16-char lowercase hex string (two zero-padded uint32s)', () => {
    const k = hashKey('x');
    expect(k).toMatch(/^[0-9a-f]{16}$/);
  });

  it('zero-pads each half to 8 hex chars', () => {
    // Length is always 16 regardless of the magnitude of either hash half.
    for (const s of ['', 'a', 'a-much-longer-input-string', '1']) {
      expect(hashKey(s).length).toBe(16);
    }
  });

  it('differs for different inputs', () => {
    expect(hashKey('a')).not.toBe(hashKey('b'));
  });

  it('the two halves are derived from different salted passes (not a doubled single hash)', () => {
    const k = hashKey('z');
    const first = k.slice(0, 8);
    const second = k.slice(8);
    expect(first).not.toBe(second);
  });
});
