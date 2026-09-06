// The spot ceiling is DISCOVERED from Service Quotas, not carried as a constant, because the
// failure mode of a stale constant is silent and expensive: a quota raised 32 -> 64 that nobody
// mirrored into POCKETDJ_SPOT_VCPU_CAP caps the lane at 16 workers forever and tops the remaining
// 14 up on-demand at ~2.7x, which in the logs looks exactly like spot capacity being tight rather
// than like a number nobody updated.
//
// `spotCapFrom` is the whole policy in one pure function: discovery may RAISE the configured floor,
// never lower it. These tests pin that asymmetry, because "believe the API" is the obvious reading
// and it is the wrong one — a throttled call or a renamed quota parsed into a small number would
// cap the fleet on bad data, while an over-large value costs at worst one
// MaxSpotInstanceCountExceeded that the capacity fallback already knows how to absorb.
import { describe, it, expect } from 'vitest';
import { spotCapFrom } from '../../scripts/stem-autoscaler.mjs';

const FLOOR = 32;   // the measured L-34B43A08 value at the time of writing

describe('spotCapFrom — discovery raises, never lowers', () => {
  it('takes the discovered ceiling when the quota has been raised', () => {
    // The case this whole mechanism exists for: the increase lands and the lane widens on its own.
    expect(spotCapFrom(64, FLOOR)).toBe(64);
  });

  it('keeps the floor when discovery agrees with it', () => {
    expect(spotCapFrom(32, FLOOR)).toBe(32);
  });

  it('REFUSES a smaller discovered value rather than capping the fleet on it', () => {
    // A genuine quota reduction is rare; a bad parse is not. Erring toward the floor means the
    // worst case is one absorbed capacity refusal, not a fleet quietly halved.
    expect(spotCapFrom(2, FLOOR)).toBe(FLOOR);
    expect(spotCapFrom(0, FLOOR)).toBe(FLOOR);
    expect(spotCapFrom(-8, FLOOR)).toBe(FLOOR);
  });

  it('falls back to the floor for every shape a failed lookup can leave behind', () => {
    // c.vcpu is whatever survived in a JSON state file across process restarts, so it is not
    // enough for the happy path to work — undefined is the first-run case, and the rest are what
    // a truncated write, a hand-edit, or a stubbed CLI can leave in the slot.
    for (const bad of [undefined, null, '', 'sixty-four', NaN, Infinity, {}, [], true]) {
      expect(spotCapFrom(bad, FLOOR)).toBe(FLOOR);
    }
  });

  it('reads a numeric string, because JSON round-trips are not always typed', () => {
    expect(spotCapFrom('64', FLOOR)).toBe(64);
  });

  it('scales the worker ceiling the way the plan will consume it', () => {
    // The number only matters through this division: m7i.large is 2 vCPU, so the difference the
    // pending quota request makes is 16 workers vs 32 — the entire top-up question.
    expect(Math.floor(spotCapFrom(32, FLOOR) / 2)).toBe(16);
    expect(Math.floor(spotCapFrom(64, FLOOR) / 2)).toBe(32);
  });
});
