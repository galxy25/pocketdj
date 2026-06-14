// Unit tests for the Camelot helpers that the existing camelot.test.ts does NOT
// cover: camelotColor (Key-mode grid tint), the keyToCamelot/camelotToKey
// round-trips that back the edit-modal dropdowns, and the published
// CAMELOT_KEYS / MUSICAL_KEYS valid-value lists.
import { describe, it, expect } from 'vitest';
import {
  camelotColor,
  keyToCamelot,
  camelotToKey,
  CAMELOT_KEYS,
  MUSICAL_KEYS,
} from './camelot';

describe('camelotColor', () => {
  it('returns null for nullish / empty / unparseable keys (caller falls back to neutral)', () => {
    expect(camelotColor(null)).toBeNull();
    expect(camelotColor(undefined)).toBeNull();
    expect(camelotColor('')).toBeNull();
    expect(camelotColor('   ')).toBeNull();
    expect(camelotColor('A minor')).toBeNull(); // musical name, not a Camelot code
    expect(camelotColor('2C')).toBeNull();
    expect(camelotColor('0A')).toBeNull();
    expect(camelotColor('13A')).toBeNull();
  });

  it('returns an hsl() string for every valid Camelot code', () => {
    for (const code of CAMELOT_KEYS) {
      const c = camelotColor(code);
      expect(c).toMatch(/^hsl\(\d+ 68% \d+%\)$/);
    }
  });

  it('maps the 12 wheel numbers onto 12 evenly-spaced hues (independent of A/B)', () => {
    // hue = round((num-1)/12 * 360); A and B of the same number share a hue.
    expect(camelotColor('1A')).toContain('hsl(0 ');
    expect(camelotColor('1B')).toContain('hsl(0 ');
    expect(camelotColor('4A')).toContain('hsl(90 '); // (4-1)/12*360 = 90
    expect(camelotColor('7A')).toContain('hsl(180 ');
    expect(camelotColor('10A')).toContain('hsl(270 ');
  });

  it('reads B (major) brighter than A (minor) at the same wheel number', () => {
    // lightness: B=50%, A=38%
    expect(camelotColor('5B')).toBe('hsl(120 68% 50%)');
    expect(camelotColor('5A')).toBe('hsl(120 68% 38%)');
  });

  it('is case-insensitive and trims whitespace', () => {
    expect(camelotColor('  8a ')).toBe(camelotColor('8A'));
    expect(camelotColor('11b')).toBe(camelotColor('11B'));
  });
});

describe('keyToCamelot / camelotToKey round-trips', () => {
  it('keyToCamelot returns null for nullish / unknown names', () => {
    expect(keyToCamelot(null)).toBeNull();
    expect(keyToCamelot(undefined)).toBeNull();
    expect(keyToCamelot('')).toBeNull();
    expect(keyToCamelot('H minor')).toBeNull();
    expect(keyToCamelot('8A')).toBeNull(); // a Camelot code is not a musical name
  });

  it('camelotToKey returns null for nullish / unknown codes', () => {
    expect(camelotToKey(null)).toBeNull();
    expect(camelotToKey(undefined)).toBeNull();
    expect(camelotToKey('')).toBeNull();
    expect(camelotToKey('13A')).toBeNull();
    expect(camelotToKey('A minor')).toBeNull();
  });

  it('maps known anchor keys both directions', () => {
    expect(keyToCamelot('A minor')).toBe('8A');
    expect(keyToCamelot('C major')).toBe('8B');
    expect(camelotToKey('8A')).toBe('A minor');
    expect(camelotToKey('8B')).toBe('C major');
  });

  it('round-trips every canonical musical key through Camelot and back', () => {
    for (const key of MUSICAL_KEYS) {
      const code = keyToCamelot(key);
      expect(code, `keyToCamelot(${key})`).not.toBeNull();
      expect(camelotToKey(code), `camelotToKey(${code})`).toBe(key);
    }
  });

  it('round-trips every Camelot code through the canonical key and back', () => {
    for (const code of CAMELOT_KEYS) {
      const key = camelotToKey(code);
      expect(key, `camelotToKey(${code})`).not.toBeNull();
      expect(keyToCamelot(key), `keyToCamelot(${key})`).toBe(code);
    }
  });

  it('accepts flat spellings as input even though the canonical output is sharp', () => {
    // The MUSICAL_TO_CAMELOT map carries both sharp + flat spellings.
    expect(keyToCamelot('Ab minor')).toBe('1A');
    expect(keyToCamelot('G# minor')).toBe('1A');
    expect(keyToCamelot('Bb major')).toBe('6B');
    // ...but camelotToKey only ever produces the canonical sharp spelling.
    expect(camelotToKey('1A')).toBe('G# minor');
    expect(camelotToKey('6B')).toBe('A# major');
  });
});

describe('CAMELOT_KEYS / MUSICAL_KEYS valid-value lists', () => {
  it('CAMELOT_KEYS has all 24 codes in wheel order (1A,1B,...,12B)', () => {
    expect(CAMELOT_KEYS).toHaveLength(24);
    expect(CAMELOT_KEYS[0]).toBe('1A');
    expect(CAMELOT_KEYS[1]).toBe('1B');
    expect(CAMELOT_KEYS[22]).toBe('12A');
    expect(CAMELOT_KEYS[23]).toBe('12B');
    expect(new Set(CAMELOT_KEYS).size).toBe(24); // unique
  });

  it('MUSICAL_KEYS has 24 unique keys (12 minor then 12 major)', () => {
    expect(MUSICAL_KEYS).toHaveLength(24);
    expect(new Set(MUSICAL_KEYS).size).toBe(24);
    expect(MUSICAL_KEYS.slice(0, 12).every((k) => k.endsWith('minor'))).toBe(true);
    expect(MUSICAL_KEYS.slice(12).every((k) => k.endsWith('major'))).toBe(true);
    expect(MUSICAL_KEYS[0]).toBe('C minor');
    expect(MUSICAL_KEYS[12]).toBe('C major');
  });

  it('every CAMELOT_KEYS entry parses to a color and the two lists pair 1:1', () => {
    for (const code of CAMELOT_KEYS) expect(camelotColor(code)).not.toBeNull();
    // Each Camelot code maps to a distinct musical key, covering MUSICAL_KEYS exactly.
    const mapped = new Set(CAMELOT_KEYS.map((c) => camelotToKey(c)));
    expect(mapped.size).toBe(MUSICAL_KEYS.length);
    for (const k of MUSICAL_KEYS) expect(mapped.has(k)).toBe(true);
  });
});
