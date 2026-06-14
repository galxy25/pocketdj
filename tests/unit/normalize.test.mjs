// Tests for the shared string-normalization helpers (apostrophes / & / "the" /
// diacritics) and the token-similarity functions used by the iTunes matcher.
import { describe, it, expect } from 'vitest';
import {
  normalize,
  tokens,
  tokenSet,
  diceTokens,
  coverage,
} from '../../.claude/skills/analog-indexer/lib/normalize.js';

describe('normalize', () => {
  it('returns empty string for falsy input', () => {
    expect(normalize('')).toBe('');
    expect(normalize(null)).toBe('');
    expect(normalize(undefined)).toBe('');
  });

  it('lowercases', () => {
    expect(normalize('ABBA')).toBe('abba');
  });

  it('expands "&" to " and "', () => {
    expect(normalize('Hall & Oates')).toBe('hall and oates');
    expect(normalize('Faith Hope & Charity')).toBe('faith hope and charity');
  });

  it('drops apostrophes entirely (straight, curly, backtick)', () => {
    expect(normalize("Don't")).toBe('dont');
    expect(normalize('Don’t')).toBe('dont');
    expect(normalize('O`Jays')).toBe('ojays');
  });

  it('strips combining diacritics', () => {
    expect(normalize('Beyoncé')).toBe('beyonce');
    expect(normalize('Mötley Crüe')).toBe('motley crue');
  });

  it('drops a leading "the" but not an internal one', () => {
    expect(normalize('The Brothers Johnson')).toBe('brothers johnson');
    expect(normalize('Light Up The Night')).toBe('light up the night');
  });

  it('converts other punctuation to a single space and collapses whitespace', () => {
    expect(normalize('A.B.C - D')).toBe('a b c d');
    expect(normalize('Hello,   World!!!')).toBe('hello world');
  });

  it('treats apostrophe-then-"the" so the leading-the rule still fires after stripping', () => {
    // sanity: leading "the" strip happens after punctuation collapse
    expect(normalize("The O'Jays")).toBe('ojays');
  });

  it('is idempotent on already-normalized strings', () => {
    const once = normalize('The Mötley & Crüe');
    expect(normalize(once)).toBe(once);
  });
});

describe('tokens / tokenSet', () => {
  it('returns the normalized word array', () => {
    expect(tokens('The Brothers Johnson')).toEqual(['brothers', 'johnson']);
  });

  it('returns an empty array for empty input', () => {
    expect(tokens('')).toEqual([]);
    expect(tokens('   ')).toEqual([]);
  });

  it('tokenSet dedupes repeated tokens', () => {
    const s = tokenSet('na na na na');
    expect(s).toBeInstanceOf(Set);
    expect([...s]).toEqual(['na']);
  });
});

describe('diceTokens', () => {
  it('is 1 for two empty inputs', () => {
    expect(diceTokens('', '')).toBe(1);
  });

  it('is 0 when exactly one side is empty', () => {
    expect(diceTokens('abba', '')).toBe(0);
    expect(diceTokens('', 'abba')).toBe(0);
  });

  it('is 1 for identical token sets', () => {
    expect(diceTokens('abba greatest hits', 'abba greatest hits')).toBe(1);
  });

  it('computes the Sørensen–Dice coefficient for partial overlap', () => {
    // A = {a,b}, B = {b,c}; inter = 1 -> 2*1/(2+2) = 0.5
    expect(diceTokens('a b', 'b c')).toBe(0.5);
  });

  it('accepts pre-built Sets as well as strings', () => {
    const a = tokenSet('abba greatest hits');
    const b = tokenSet('abba greatest hits');
    expect(diceTokens(a, b)).toBe(1);
  });

  it('treats "&"/"and" and "The"-prefix as equal after normalization', () => {
    expect(diceTokens('Hall & Oates', 'Hall and Oates')).toBe(1);
    expect(diceTokens('The Cure', 'Cure')).toBe(1);
  });
});

describe('coverage', () => {
  it('is 0 when A is empty', () => {
    expect(coverage('', 'anything here')).toBe(0);
  });

  it('is the fraction of A tokens present in B', () => {
    // A = {abba}, fully present in B
    expect(coverage('ABBA', 'ABBA Greatest Hits')).toBe(1);
    // A = {a,b,c}, only a,b in B -> 2/3
    expect(coverage('a b c', 'a b z')).toBeCloseTo(2 / 3, 10);
  });

  it('is directional (not symmetric)', () => {
    const ab = coverage('a', 'a b c d');
    const ba = coverage('a b c d', 'a');
    expect(ab).toBe(1);
    expect(ba).toBe(0.25);
  });
});
