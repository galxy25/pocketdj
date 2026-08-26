// The PARITY GATE's comparator. This is the check that decides whether a cloud backfill may run
// at all, so its FAILURE modes matter more than its success mode: a gate that only ever says
// PASS is a null verifier, and a mixed-provenance corpus corrupts every similarity comparison
// silently, with nothing in the artifact recording which machine produced which row.
import { describe, it, expect } from 'vitest';
import { compareVectors, EPS } from '../../scripts/timbre-parity-check.mjs';
import { chooseSample } from '../../scripts/timbre-parity-enqueue.mjs';

const AXES = ['bright', 'busy', 'noisy', 'm1'];
const vec = (o = {}) => Object.fromEntries(AXES.map((k) => [k, o[k] ?? 0.5]));
const corpus = (n, mut = () => ({})) => {
  const local = new Map(); const cloud = new Map();
  for (let i = 0; i < n; i++) {
    local.set(`sng_${i}`, vec());
    cloud.set(`sng_${i}`, vec(mut(i)));
  }
  return [local, cloud];
};

describe('compareVectors', () => {
  it('PASSes only when every axis of every song is bit-identical', () => {
    const [l, c] = corpus(30);
    const r = compareVectors(l, c);
    expect(r.verdict).toBe('PASS');
    expect(r.worstMax).toBe(0);
    expect(r.compared).toBe(30);
  });

  it('CONDITIONAL: one song, one axis, one ulp of the engine\'s own round(…,4)', () => {
    const [l, c] = corpus(30, (i) => (i === 0 ? { bright: 0.5 + EPS } : {}));
    const r = compareVectors(l, c);
    expect(r.verdict).toBe('CONDITIONAL');
    expect(r.axes.bright.median).toBe(0);        // the median stays 0 — it is a boundary tie
  });

  it('FAILs on a deviation larger than one ulp — that is a different stack, not rounding', () => {
    const [l, c] = corpus(30, (i) => (i === 0 ? { bright: 0.5 + 2 * EPS } : {}));
    expect(compareVectors(l, c).verdict).toBe('FAIL');
  });

  it('FAILs on a SYSTEMATIC 1e-4 shift even though every single |Δ| is within tolerance', () => {
    // This is the arm a magnitude-only gate would wave through: a recalibrated stack that happens
    // to move every song the same tiny amount in the same direction.
    const [l, c] = corpus(30, () => ({ bright: 0.5 + EPS }));
    const r = compareVectors(l, c);
    expect(r.worstMax).toBeLessThanOrEqual(EPS * 1.0000001);
    expect(r.verdict).toBe('FAIL');
  });

  it('FAILs when the MEDIAN moves — half the corpus differing is not float noise', () => {
    const [l, c] = corpus(30, (i) => (i % 2 ? { busy: 0.5 + EPS } : { busy: 0.5 - EPS }));
    const r = compareVectors(l, c);
    expect(r.axes.busy.median).toBeGreaterThan(0);
    expect(r.verdict).toBe('FAIL');
  });

  it('FAILs on a null↔number flip — an axis that stopped being computed at all', () => {
    const l = new Map([['sng_0', vec()]]);
    const c = new Map([['sng_0', { ...vec(), noisy: null }]]);
    const r = compareVectors(l, c);
    expect(r.flips).toBe(1);
    expect(r.verdict).toBe('FAIL');
  });

  it('counts songs the cloud never returned as missing rather than silently passing on the rest', () => {
    const [l, c] = corpus(10);
    c.delete('sng_3');
    const r = compareVectors(l, c);
    expect(r.compared).toBe(9);
    expect(r.missing).toBe(1);
  });
});

describe('chooseSample — stratification', () => {
  const f = (o) => ({ bright: 0.5, busy: 0.5, noisy: 0.5, m1: 0.5, m2: 0.5, m3: 0.5, m4: 0.5, width: 0.5, air: 0.5, punch: 0.5, dynamic: 0.5, loud: 0.5, ...o });
  const rows = [
    ...Array.from({ length: 50 }, (_, i) => ({ id: `rail_${i}`, f: f({ noisy: 0 }) })),      // clamp boundary
    ...Array.from({ length: 50 }, (_, i) => ({ id: `busy_${i}`, f: f({ busy: 0.42 }) })),    // discrete onset decision
    ...Array.from({ length: 50 }, (_, i) => ({ id: `mid_${i}`, f: f({ busy: 0.01 }) })),
  ];
  it('reaches into all three strata rather than sampling one', () => {
    const pick = chooseSample(rows, 30);
    expect(pick).toHaveLength(30);
    expect(pick.some((r) => r.id.startsWith('rail_'))).toBe(true);
    expect(pick.some((r) => r.id.startsWith('busy_'))).toBe(true);
  });
  it('never returns more than the corpus holds', () => {
    expect(chooseSample(rows.slice(0, 5), 30)).toHaveLength(5);
  });
});
