import { describe, it, expect } from 'vitest';
import { camelotRank } from './camelot';

describe('camelotRank', () => {
  it('returns null for nullish/empty input', () => {
    expect(camelotRank(null)).toBeNull();
    expect(camelotRank(undefined)).toBeNull();
    expect(camelotRank('')).toBeNull();
    expect(camelotRank('   ')).toBeNull();
  });

  it('returns null for unparseable strings', () => {
    expect(camelotRank('C# major')).toBeNull();
    expect(camelotRank('2C')).toBeNull();
    expect(camelotRank('B2')).toBeNull();
    expect(camelotRank('13A')).toBeNull();
    expect(camelotRank('0A')).toBeNull();
    expect(camelotRank('2')).toBeNull();
    expect(camelotRank('A')).toBeNull();
  });

  it('parses valid camelot codes (1..12, A/B), case-insensitive, trimmed', () => {
    expect(camelotRank('1A')).toBe(2);
    expect(camelotRank('1B')).toBe(3);
    expect(camelotRank('12A')).toBe(24);
    expect(camelotRank('12B')).toBe(25);
    expect(camelotRank('2b')).toBe(5);
    expect(camelotRank('  11A ')).toBe(22);
  });

  it('orders A before B within the same number, and by number across', () => {
    // Sorting these raw codes by rank should give wheel order.
    const codes = ['2B', '1A', '11A', '2A', '1B', '12B', '10A'];
    const sorted = [...codes].sort((x, y) => camelotRank(x)! - camelotRank(y)!);
    expect(sorted).toEqual(['1A', '1B', '2A', '2B', '10A', '11A', '12B']);
  });

  it('rank is strictly increasing and contiguous across the full wheel', () => {
    const ranks: number[] = [];
    for (let n = 1; n <= 12; n++) {
      ranks.push(camelotRank(`${n}A`)!);
      ranks.push(camelotRank(`${n}B`)!);
    }
    for (let i = 1; i < ranks.length; i++) {
      expect(ranks[i]).toBe(ranks[i - 1] + 1);
    }
  });
});
