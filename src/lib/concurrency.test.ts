import { describe, it, expect, vi } from 'vitest';
import { pMap } from './concurrency';

const tick = () => new Promise((r) => setTimeout(r, 0));

describe('pMap — results', () => {
  it('runs the worker on every item and preserves INPUT order', async () => {
    const input = [1, 2, 3, 4, 5];
    const res = await pMap(input, async (n) => n * 10, 2);
    expect(res.map((r) => r.value)).toEqual([10, 20, 30, 40, 50]);
    expect(res.every((r) => r.ok)).toBe(true);
  });

  it('passes the index as the second worker arg', async () => {
    const res = await pMap(['a', 'b', 'c'], async (item, i) => `${item}${i}`, 2);
    expect(res.map((r) => r.value)).toEqual(['a0', 'b1', 'c2']);
  });

  it('returns [] for an empty input (no workers spawned)', async () => {
    const worker = vi.fn(async (n: number) => n);
    const res = await pMap([], worker, 4);
    expect(res).toEqual([]);
    expect(worker).not.toHaveBeenCalled();
  });
});

describe('pMap — never rejects (failures captured per item)', () => {
  it('captures a thrown error and keeps processing the rest', async () => {
    const res = await pMap([1, 2, 3], async (n) => {
      if (n === 2) throw new Error('boom');
      return n;
    }, 1);
    expect(res[0]).toEqual({ ok: true, value: 1 });
    expect(res[1].ok).toBe(false);
    expect((res[1].error as Error).message).toBe('boom');
    expect(res[2]).toEqual({ ok: true, value: 3 });
  });

  it('the returned promise resolves (does not reject) even when all workers throw', async () => {
    const res = await pMap([1, 2], async () => {
      throw new Error('always');
    }, 2);
    expect(res.every((r) => !r.ok)).toBe(true);
  });
});

describe('pMap — respects the concurrency cap', () => {
  it('never has more than `concurrency` workers in flight at once', async () => {
    const concurrency = 3;
    let inFlight = 0;
    let maxInFlight = 0;
    const input = Array.from({ length: 12 }, (_, i) => i);

    const res = await pMap(input, async (n) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await tick();
      await tick();
      inFlight--;
      return n;
    }, concurrency);

    expect(res.map((r) => r.value)).toEqual(input);
    expect(maxInFlight).toBeLessThanOrEqual(concurrency);
    expect(maxInFlight).toBe(concurrency); // saturates the pool
  });

  it('spawns at most `items.length` runners when concurrency exceeds item count', async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const input = [1, 2];
    await pMap(input, async (n) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await tick();
      inFlight--;
      return n;
    }, 10);
    expect(maxInFlight).toBeLessThanOrEqual(input.length);
  });
});

describe('pMap — progress callback', () => {
  it('reports done/total monotonically, ending at total', async () => {
    const calls: Array<[number, number]> = [];
    const input = [1, 2, 3, 4];
    await pMap(input, async (n) => n, 2, (done, total) => calls.push([done, total]));
    expect(calls.length).toBe(input.length);
    // total is always the input length
    expect(calls.every(([, total]) => total === input.length)).toBe(true);
    // done is non-decreasing and ends at total
    const dones = calls.map(([d]) => d);
    for (let i = 1; i < dones.length; i++) expect(dones[i]).toBeGreaterThanOrEqual(dones[i - 1]);
    expect(dones[dones.length - 1]).toBe(input.length);
    // each item reported exactly once -> the multiset of `done` is 1..total
    expect([...dones].sort((a, b) => a - b)).toEqual([1, 2, 3, 4]);
  });

  it('progress fires even for failing items', async () => {
    let progressCount = 0;
    await pMap([1, 2, 3], async (n) => {
      if (n === 2) throw new Error('x');
      return n;
    }, 1, () => progressCount++);
    expect(progressCount).toBe(3);
  });
});
