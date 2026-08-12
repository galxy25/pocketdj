// Unit tests for the STALL SIGNAL in scripts/rip-backfill.mjs — the D2 half of the
// 2026-08-12 outage.
//
// For 38 hours the heartbeat looked healthy: `inflight: 10`, `pending: 3125`, and a confident
// `etaHours: 243.83`. `done` never moved off 166. Every number was accurate and none of them
// measured THROUGHPUT, so a permanent stall was indistinguishable from a quiet night — and the
// external monitor, which only sampled every 50 completions, printed nothing at all.
//
// These tests pin the three properties that would have caught it in minutes:
//   1. an idle window with work available is reported as `stalled: true`,
//   2. `etaHours` is NULL at zero throughput rather than a reassuring finite number,
//   3. the clock that decides all this SURVIVES A RESTART and is moved only by real captures.
// …plus a fourth the first three do not give you: the driver must ACT on the stall (throttle the
// refill, stop spending retry budget on the rig's fault) rather than merely announce it — see
// BACKPRESSURE at the bottom of this file.
import { describe, it, expect } from 'vitest';
import {
  ensureStats, noteSuccess, noteFailure, stallState, honestEtaHours, buildHeartbeat, etaHours,
  refillWindowFor, shouldDeferFailure,
} from '../../scripts/rip-backfill.mjs';

const HOUR = 3_600_000;
const NOW = 1_700_000_000_000;
const STALL_MS = 2 * HOUR;

// The heartbeat's real shape at the moment of the incident.
const incidentCounts = { done: 166, failed: 0, skipped: 900, inflight: 10, pending: 3125, total: 4201 };

describe('stallState', () => {
  it('flags a stall once the idle window passes WITH work available', () => {
    const s = stallState({ lastSuccessAtMs: NOW - 3 * HOUR, now: NOW, stallMs: STALL_MS, pending: 3125, inflight: 10 });
    expect(s.stalled).toBe(true);
    expect(s.hoursSinceLastSuccess).toBe(3);
    expect(s.everSucceeded).toBe(true);
  });

  it('does NOT flag a stall inside the window — a slow song must not cry wolf', () => {
    // the server's own retry ladder is ~32 min for one song; the window is deliberately longer
    const s = stallState({ lastSuccessAtMs: NOW - 1.9 * HOUR, now: NOW, stallMs: STALL_MS, pending: 3125, inflight: 10 });
    expect(s.stalled).toBe(false);
  });

  it('an IDLE driver is never "stalled" — no work is not the same as no progress', () => {
    const s = stallState({ lastSuccessAtMs: NOW - 50 * HOUR, now: NOW, stallMs: STALL_MS, pending: 0, inflight: 0 });
    expect(s.stalled).toBe(false);
  });

  it('a driver that has NEVER completed anything still stalls, measured from watchSinceMs', () => {
    // the incident's real duration, on a driver with no recorded success to measure from
    const s = stallState({ lastSuccessAtMs: null, watchSinceMs: NOW - 38 * HOUR, now: NOW, stallMs: STALL_MS, pending: 3125, inflight: 10 });
    expect(s.stalled).toBe(true);
    expect(s.everSucceeded).toBe(false);
    expect(s.hoursSinceLastSuccess).toBe(38);
  });
});

describe('honestEtaHours', () => {
  it('refuses to publish a finite ETA at zero throughput', () => {
    // the exact lie: remaining 3135 × the 280s CONSTANT = 243.83 h, printed while nothing moved
    expect(etaHours(3135, 280)).toBeCloseTo(243.83, 1);
    expect(honestEtaHours({ remaining: 3135, meanSec: 280, stalled: true })).toBeNull();
  });

  it('still gives the normal estimate when the pipeline is moving', () => {
    expect(honestEtaHours({ remaining: 3135, meanSec: 280, stalled: false })).toBeCloseTo(243.83, 1);
  });

  it('nothing remaining is 0 hours, not null', () => {
    expect(honestEtaHours({ remaining: 0, meanSec: 280, stalled: false })).toBe(0);
  });
});

describe('buildHeartbeat — what an external watcher can actually act on', () => {
  it('THE INCIDENT: 38h without a capture reports stalled + a null ETA', () => {
    const { hb, stalled } = buildHeartbeat({
      counts: incidentCounts, stats: { lastSuccessAtMs: NOW - 38 * HOUR, consecutiveFailures: 212 },
      now: NOW, stallMs: STALL_MS, meanSec: 280, external: 0,
    });
    expect(stalled).toBe(true);
    expect(hb.stalled).toBe(true);
    expect(hb.etaHours).toBeNull();               // ← no more confident 243.83
    expect(hb.hoursSinceLastSuccess).toBe(38);
    expect(hb.consecutiveFailures).toBe(212);
    expect(hb.lastSuccessAtMs).toBe(NOW - 38 * HOUR);
    expect(hb.done).toBe(166);                    // the frozen counter is still reported…
  });

  it('a HEALTHY pipeline reports the same fields with stalled:false and a real ETA', () => {
    const { hb, stalled } = buildHeartbeat({
      counts: incidentCounts, stats: { lastSuccessAtMs: NOW - 4 * 60_000, consecutiveFailures: 0 },
      now: NOW, stallMs: STALL_MS, meanSec: 280,
    });
    expect(stalled).toBe(false);
    expect(hb.etaHours).toBeCloseTo(243.83, 1);
    expect(hb.hoursSinceLastSuccess).toBeCloseTo(0.07, 2);
  });

  it('every field the monitor greps is present, including on a fresh state with no stats', () => {
    const { hb } = buildHeartbeat({ counts: incidentCounts, stats: {}, now: NOW, stallMs: STALL_MS, meanSec: 280 });
    for (const k of ['hb', 't', 'done', 'failed', 'skipped', 'inflight', 'pending', 'total',
      'externalQueue', 'meanCaptureSec', 'etaHours', 'lastSuccessAtMs', 'hoursSinceLastSuccess',
      'consecutiveFailures', 'stalled']) {
      expect(hb, `heartbeat is missing ${k}`).toHaveProperty(k);
    }
    expect(hb.lastSuccessAtMs).toBeNull();
    expect(hb.stalled).toBe(false); // no history yet → not yet evidence of a stall
  });

  it('ignores state.done entirely — a SKIP must never look like throughput', () => {
    // state.done is also written for rows that already had audio (skips). If the stall clock
    // read max(done.atMs) it would refresh on every skip and mask a total capture outage.
    const stats = { lastSuccessAtMs: NOW - 9 * HOUR };
    const withFreshSkips = buildHeartbeat({
      counts: { ...incidentCounts, done: 4000 }, stats, now: NOW, stallMs: STALL_MS, meanSec: 280,
    });
    expect(withFreshSkips.stalled).toBe(true);
    expect(withFreshSkips.hb.etaHours).toBeNull();
  });
});

describe('the stall clock survives a restart and moves only on real captures', () => {
  it('noteSuccess resets the clock and the failure streak; noteFailure grows the streak', () => {
    const state = { done: {}, failed: {} };
    ensureStats(state, NOW);
    expect(state.stats.lastSuccessAtMs).toBeNull();
    expect(state.stats.watchSinceMs).toBe(NOW);

    noteFailure(state, NOW + 1000);
    noteFailure(state, NOW + 2000);
    expect(state.stats.consecutiveFailures).toBe(2);

    noteSuccess(state, NOW + 3000);
    expect(state.stats.lastSuccessAtMs).toBe(NOW + 3000);
    expect(state.stats.consecutiveFailures).toBe(0); // a completion clears the streak
    expect(state.stats.successes).toBe(1);
  });

  it('the counters round-trip through the state FILE — a launchd restart cannot hide a stall', () => {
    // pump()'s own completionsThisRun / firstRequestAt are run-locals and reset on every
    // restart; the stall signal must not be derived from anything that forgetful.
    const state = { done: {}, failed: {} };
    ensureStats(state, NOW - 38 * HOUR);
    noteFailure(state, NOW - 20 * HOUR);
    const reloaded = JSON.parse(JSON.stringify(state)); // ← what saveState/loadState do
    ensureStats(reloaded, NOW);                         // a fresh process re-seeds…
    expect(reloaded.stats.watchSinceMs).toBe(NOW - 38 * HOUR); // …without resetting the clock
    expect(reloaded.stats.consecutiveFailures).toBe(1);
    const { hb } = buildHeartbeat({ counts: incidentCounts, stats: reloaded.stats, now: NOW, stallMs: STALL_MS, meanSec: 280 });
    expect(hb.stalled).toBe(true);
    expect(hb.hoursSinceLastSuccess).toBe(38);
  });
});

// ═══════════════════════════════ BACKPRESSURE — acting on the stall ══════════════════════════════
// Reporting a stall is not the same as surviving one. During the incident this driver kept 10
// rows in flight against a rig that could not capture anything, at exactly the rate it uses when
// everything is fine, and every one came back failed with attempts=1 — after which the
// end-of-pass pass spent each row's ONE remaining attempt against the same dead rig. That is the
// mechanism that turned a temporary wedge into 212 PERMANENT failures.
describe('refillWindowFor — the driver stops feeding a rig it knows is dead', () => {
  it('a healthy rig gets the full window', () => {
    expect(refillWindowFor({ stalled: false, window: 10, stallWindow: 1 })).toBe(10);
  });

  it('a STALLED rig gets a single canary row', () => {
    expect(refillWindowFor({ stalled: true, window: 10, stallWindow: 1 })).toBe(1);
  });

  it('never throttles to zero — recovery has to be DETECTABLE', () => {
    // A canary is not politeness, it is the sensor: its success is what moves lastSuccessAtMs,
    // clears `stalled` and reopens the window. Refilling nothing would make the stall permanent
    // by construction and the driver would never notice the rig coming back.
    expect(refillWindowFor({ stalled: true, window: 10, stallWindow: 0 })).toBe(1);
    expect(refillWindowFor({ stalled: true, window: 10, stallWindow: -5 })).toBe(1);
  });

  it('never widens the window — the stall setting is a cap, not a target', () => {
    expect(refillWindowFor({ stalled: true, window: 1, stallWindow: 8 })).toBe(1);
  });
});

describe('shouldDeferFailure — a dead rig must not burn the queue into permanent failure', () => {
  it('defers while stalled: the failure is the RIG\'s verdict, not the ROW\'s', () => {
    expect(shouldDeferFailure({ stalled: true, deferrals: 0, max: 2 })).toBe(true);
    expect(shouldDeferFailure({ stalled: true, deferrals: 1, max: 2 })).toBe(true);
  });

  it('records normally when the rig is healthy — an ordinary bad row still fails', () => {
    expect(shouldDeferFailure({ stalled: false, deferrals: 0, max: 2 })).toBe(false);
  });

  it('is BOUNDED per row, so a plan of genuinely unrippable rows still drains and exits', () => {
    // Without this bound a stall that never clears (every remaining row unrippable) would churn
    // the same rows forever and the driver would never reach ALL DONE.
    expect(shouldDeferFailure({ stalled: true, deferrals: 2, max: 2 })).toBe(false);
    expect(shouldDeferFailure({ stalled: true, deferrals: 9, max: 2 })).toBe(false);
  });

  it('max 0 disables deferral entirely', () => {
    expect(shouldDeferFailure({ stalled: true, deferrals: 0, max: 0 })).toBe(false);
  });
});

describe('the heartbeat publishes what the driver is DOING about the stall', () => {
  it('refillWindow drops with `stalled`, so a watcher sees throttling and not just a complaint', () => {
    const stalledHb = buildHeartbeat({
      counts: incidentCounts, stats: { lastSuccessAtMs: NOW - 38 * HOUR }, now: NOW,
      stallMs: STALL_MS, meanSec: 280, refillWindow: 1,
    });
    expect(stalledHb.hb.stalled).toBe(true);
    expect(stalledHb.hb.refillWindow).toBe(1);
    expect(stalledHb.hb.etaHours).toBeNull();

    const healthyHb = buildHeartbeat({
      counts: incidentCounts, stats: { lastSuccessAtMs: NOW - 60_000 }, now: NOW,
      stallMs: STALL_MS, meanSec: 280, refillWindow: 10,
    });
    expect(healthyHb.hb.stalled).toBe(false);
    expect(healthyHb.hb.refillWindow).toBe(10);
  });
});
