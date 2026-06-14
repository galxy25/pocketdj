// Tests for the batching helpers + agent-count budget math.
import { describe, it, expect } from 'vitest';
import {
  DEFAULT_BATCH_SIZE,
  chunk,
  planBatches,
} from '../../.claude/skills/analog-indexer/lib/batching.js';

describe('chunk', () => {
  it('splits into chunks of the default size', () => {
    const arr = Array.from({ length: 25 }, (_, i) => i);
    const out = chunk(arr);
    expect(DEFAULT_BATCH_SIZE).toBe(10);
    expect(out).toHaveLength(3);
    expect(out[0]).toHaveLength(10);
    expect(out[2]).toHaveLength(5);
  });

  it('honors a custom size', () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
  });

  it('returns an empty array for empty input', () => {
    expect(chunk([])).toEqual([]);
  });

  it('returns a single chunk when size >= length', () => {
    expect(chunk([1, 2, 3], 10)).toEqual([[1, 2, 3]]);
  });

  it('does not lose or duplicate elements', () => {
    const arr = Array.from({ length: 37 }, (_, i) => i);
    const flat = chunk(arr, 7).flat();
    expect(flat).toEqual(arr);
  });
});

describe('planBatches', () => {
  it('computes batches and the 2-stage agent-call budget', () => {
    const p = planBatches(25);
    expect(p).toEqual({
      albums: 25,
      batchSize: 10,
      batches: 3,
      agentCalls: 6, // 3 batches * 2 stages
      underCap: true,
    });
  });

  it('rounds the batch count up', () => {
    expect(planBatches(1).batches).toBe(1);
    expect(planBatches(11).batches).toBe(2);
  });

  it('flags when the agent-call budget exceeds the 1000 cap', () => {
    // 1366 albums one-agent-each (size 1) -> 1366 batches * 2 = 2732 calls > 1000
    const over = planBatches(1366, 1);
    expect(over.agentCalls).toBe(2732);
    expect(over.underCap).toBe(false);
  });

  it('stays under the cap for the real catalog at the default size', () => {
    const p = planBatches(1366);
    expect(p.batches).toBe(137);
    expect(p.agentCalls).toBe(274);
    expect(p.underCap).toBe(true);
  });

  it('reports the exact boundary (500 batches -> 1000 calls) as under cap', () => {
    const p = planBatches(5000, 10); // 500 batches * 2 = 1000
    expect(p.agentCalls).toBe(1000);
    expect(p.underCap).toBe(true);
  });

  it('handles zero albums', () => {
    expect(planBatches(0)).toMatchObject({ batches: 0, agentCalls: 0, underCap: true });
  });
});
