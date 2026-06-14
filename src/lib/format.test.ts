import { describe, it, expect } from 'vitest';
import { msToClock, clockToMs, truncate } from './format';

describe('msToClock', () => {
  it('formats ms as m:ss with zero-padded seconds', () => {
    expect(msToClock(286000)).toBe('4:46');
    expect(msToClock(60000)).toBe('1:00');
    expect(msToClock(5000)).toBe('0:05');
    expect(msToClock(0)).toBe('0:00');
  });

  it('rounds to the nearest second', () => {
    expect(msToClock(1499)).toBe('0:01');
    expect(msToClock(1500)).toBe('0:02');
    expect(msToClock(59999)).toBe('1:00'); // rounds up to 60s -> 1:00
  });

  it('handles long durations (>= 1 hour stays in m:ss, minutes overflow 60)', () => {
    expect(msToClock(3600000)).toBe('60:00');
    expect(msToClock(3661000)).toBe('61:01');
  });

  it('returns "" for null / undefined / non-finite', () => {
    expect(msToClock(null)).toBe('');
    expect(msToClock(undefined)).toBe('');
    expect(msToClock(Infinity)).toBe('');
    expect(msToClock(NaN)).toBe('');
  });
});

describe('clockToMs', () => {
  it('parses m:ss into ms', () => {
    expect(clockToMs('4:46')).toBe(286000);
    expect(clockToMs('1:00')).toBe(60000);
    expect(clockToMs('0:05')).toBe(5000);
  });

  it('trims surrounding whitespace', () => {
    expect(clockToMs('  2:30 ')).toBe(150000);
  });

  it('treats a missing seconds part as 0', () => {
    expect(clockToMs('3:')).toBe(180000);
  });

  it('returns undefined for empty / whitespace-only', () => {
    expect(clockToMs('')).toBeUndefined();
    expect(clockToMs('   ')).toBeUndefined();
  });

  it('returns undefined for unparseable non-numeric input', () => {
    expect(clockToMs('abc')).toBeUndefined();
  });

  it('heuristic: small bare numbers are seconds, large are already ms', () => {
    expect(clockToMs('286')).toBe(286000); // seconds
    expect(clockToMs('6000')).toBe(6000000); // 6000 <= 6000 -> seconds path
    expect(clockToMs('6001')).toBe(6001); // > 6000 -> already ms
    expect(clockToMs('286000')).toBe(286000); // already ms
  });

  it('rounds fractional seconds/ms', () => {
    expect(clockToMs('1.5')).toBe(1500); // 1.5s -> 1500ms
    expect(clockToMs('6000.7')).toBe(6001); // > 6000 -> ms, rounded
  });
});

describe('msToClock <-> clockToMs round trips', () => {
  it('round-trips representative whole-second durations', () => {
    for (const ms of [0, 5000, 60000, 150000, 286000, 599000]) {
      expect(clockToMs(msToClock(ms))).toBe(ms);
    }
  });
});

describe('truncate', () => {
  it('leaves short strings unchanged', () => {
    expect(truncate('hello', 10)).toBe('hello');
    expect(truncate('hello', 5)).toBe('hello'); // length == n, not >
  });

  it('truncates and appends an ellipsis when longer than n', () => {
    expect(truncate('hello world', 5)).toBe('hell…');
    expect(truncate('abcdef', 4)).toBe('abc…');
  });

  it('the result length equals n when truncated (ellipsis counts as 1)', () => {
    const out = truncate('abcdefghij', 6);
    expect(out).toBe('abcde…');
    expect([...out].length).toBe(6);
  });
});
