// SPOT QUOTA ARITHMETIC — the trap that turns a 60%-saving change into a 2.7× bill.
//
// SPOT AND ON-DEMAND ARE SEPARATE QUOTA BUCKETS. Verified against the live account (us-west-2,
// 011183829623) on 2026-09-06:
//
//   L-34B43A08  "All Standard (A,C,D,H,I,M,R,T,Z) Spot Instance Requests"    =  32 vCPU
//   L-1216C47A  "Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances"   =  64 vCPU
//
// m7i.large is 2 vCPU, so the SPOT ceiling for the stem fleet is 16 instances — not the 30 that
// `LANES.stem.maxWorkers` says, and not the 28 that `POCKETDJ_TOTAL_VCPU_CAP` (56) implies. That 56
// is an ON-DEMAND-shaped budget; spending it on a spot ask is a category error.
//
// WHAT WENT WRONG WITHOUT THIS. On a real backlog the old arithmetic asks for up to 28 spot
// instances. AWS refuses with `MaxSpotInstanceCountExceeded` — which is in SPOT_CAPACITY_ERRORS, so
// `launch()` retries. `run-instances` quota refusals are ALL-OR-NOTHING (`--count 1:n` fulfils what
// CAPACITY allows, but a quota refusal rejects the request outright), so the retry re-asks for the
// WHOLE 28 on-demand at $0.1008/hr against ~$0.0400 spot. The net effect of a change meant to save
// ~60% is a fleet running FULLY on-demand exactly when it is busiest — and nothing logs a problem,
// because both calls "succeeded".
//
// Two properties, and they are the whole file:
//   1. the SPOT ask never exceeds the SPOT ceiling — the refusal never happens in the first place;
//   2. any ON-DEMAND use is only the genuine SHORTFALL, never the whole request.
//
// The two lanes now draw on DIFFERENT buckets (stem spot, timbre on-demand), which one
// `totalVcpuCap` cannot express — hence the four separate cap/used fields. `launchCount` keeps its
// old single-cap signature and its old numbers; the regression block at the bottom pins that.
import { describe, it, expect } from 'vitest';
import { launchCount, launchPlan, onDemandFallbackCount } from '../../scripts/stem-autoscaler.mjs';

// The live account, as measured. Written as arithmetic, not as magic numbers, so a quota increase is
// a one-line edit here and the ceiling assertions move with it.
const SPOT_VCPU_QUOTA = 32;         // L-34B43A08
const ON_DEMAND_VCPU_CAP = 56;      // the repo's long-standing headroom under the raw L-1216C47A 64
const M7I_LARGE = 2;                // vCPU
const SPOT_CEILING = SPOT_VCPU_QUOTA / M7I_LARGE;         // 16 stem workers, and no more
const OD_CEILING = ON_DEMAND_VCPU_CAP / M7I_LARGE;        // 28

// The stem lane exactly as LANES.stem configures it, on an account with nothing else running.
const stem = {
  maxWorkers: 30, jobsPerWorker: 2, vcpu: M7I_LARGE, market: 'spot',
  spotVcpuCap: SPOT_VCPU_QUOTA, usedSpotVcpu: 0,
  onDemandVcpuCap: ON_DEMAND_VCPU_CAP, usedOnDemandVcpu: 0,
};
// A backlog deep enough that the lane cap, not the queue, is what binds: 1000 messages at 2 jobs per
// worker wants 500 workers and gets clipped to maxWorkers.
const DEEP = { visible: 1000, fleetSize: 0 };

describe('launchPlan — the SPOT ask never exceeds the SPOT quota', () => {
  it('caps a deep backlog at 16 spot workers, not 30 and not 28', () => {
    // 30 is the lane cap; 28 is floor(56/2), the on-demand-shaped budget the old guard reasoned
    // about. Both are wrong for a spot ask. 32 vCPU ÷ 2 = 16 is the only number that is right.
    const p = launchPlan({ ...stem, ...DEEP });
    expect(p.bySpotQuota).toBe(SPOT_CEILING);
    expect(p.spot).toBe(16);
    expect(p.spot).not.toBe(30);
    expect(p.spot).not.toBe(28);
  });

  it('never asks for more spot vCPU than the quota leaves, across the whole input space', () => {
    // The invariant, stated once and swept. Anything that fails here comes back from AWS as
    // MaxSpotInstanceCountExceeded — the error that triggers the full-price fallback.
    for (const visible of [0, 1, 2, 7, 31, 60, 61, 1000]) {
      for (const fleetSize of [0, 1, 8, 15, 16, 17, 30]) {
        for (const usedSpotVcpu of [0, 2, 16, 30, 31, 32, 40]) {
          const p = launchPlan({ ...stem, visible, fleetSize, usedSpotVcpu });
          expect(p.spot * M7I_LARGE).toBeLessThanOrEqual(Math.max(0, SPOT_VCPU_QUOTA - usedSpotVcpu));
          expect(p.spot).toBeGreaterThanOrEqual(0);
        }
      }
    }
  });

  it('counts the spot fleet ALREADY RUNNING against the spot ceiling', () => {
    // 10 spot workers up = 20 of the 32 spot vCPU spent, so only 6 more may be requested. The old
    // arithmetic would have offered 28 - 10 = 18 and had the whole request refused for the excess.
    const p = launchPlan({ ...stem, ...DEEP, fleetSize: 10, usedSpotVcpu: 20 });
    expect(p.bySpotQuota).toBe(6);
    expect(p.spot).toBe(6);
  });

  it('asks for NO spot at all once the spot bucket is full', () => {
    const p = launchPlan({ ...stem, ...DEEP, fleetSize: 16, usedSpotVcpu: SPOT_VCPU_QUOTA });
    expect(p.bySpotQuota).toBe(0);
    expect(p.spot).toBe(0);
  });

  it('sizes to the BACKLOG when the backlog is smaller than the ceiling', () => {
    // The ceiling is a cap, not a target. 7 messages at 2 jobs/worker is 4 workers, all spot.
    const p = launchPlan({ ...stem, visible: 7, fleetSize: 0 });
    expect(p.desired).toBe(4);
    expect(p.spot).toBe(4);
    expect(p.onDemand).toBe(0);
  });

  it('launches NOTHING on an empty queue — neither market', () => {
    expect(launchPlan({ ...stem, visible: 0, fleetSize: 0 }))
      .toMatchObject({ desired: 0, spot: 0, onDemand: 0, toLaunch: 0 });
  });

  it('never returns a negative count when the fleet already exceeds the cap', () => {
    const p = launchPlan({ ...stem, visible: 100, fleetSize: 40, usedSpotVcpu: 80, usedOnDemandVcpu: 80 });
    expect(p.spot).toBe(0);
    expect(p.onDemand).toBe(0);
    expect(p.toLaunch).toBe(0);
  });
});

describe('launchPlan — on-demand covers the SHORTFALL, and stays cheap when it can', () => {
  it('spends nothing on-demand while spot alone can carry the backlog', () => {
    // The saving IS this assertion. Any backlog inside the spot ceiling must be 100% spot; an
    // implementation that "helpfully" tops up with on-demand throws away the discount silently.
    for (const visible of [1, 2, 6, 20, 32]) {   // ≤ 16 workers at 2 jobs each
      const p = launchPlan({ ...stem, visible, fleetSize: 0 });
      expect(p.onDemand).toBe(0);
      expect(p.spot).toBe(p.toLaunch);
    }
  });

  it('tops up with on-demand ONLY past the spot ceiling, and only by the gap', () => {
    // 30 wanted, 16 available on spot → the genuine shortfall is 14. Not 30, not 28. Sixteen workers
    // at spot prices plus fourteen at full price beats both "30 on-demand" (the bug) and "the queue
    // stalls at 16" (the over-correction). How OFTEN that 14 gets bought is the fallback guard's job.
    const p = launchPlan({ ...stem, ...DEEP });
    expect(p.byLane).toBe(30);
    expect(p.spot).toBe(16);
    expect(p.onDemand).toBe(14);
    expect(p.onDemand).toBe(p.byLane - p.spot);
    expect(p.toLaunch).toBe(30);
  });

  it('clips the shortfall to the ON-DEMAND budget too — a shortfall is not a licence', () => {
    // Timbre holding its full fleet (3 × c7g.2xlarge = 24 vCPU) leaves 56 - 24 = 32 on-demand vCPU
    // → 16 m7i.large. The shortfall wants 14, which fits; squeeze it further and it must not.
    const roomy = launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu: 24 });
    expect(roomy.byOnDemandQuota).toBe(16);
    expect(roomy.onDemand).toBe(14);

    const tight = launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu: 50 });
    expect(tight.byOnDemandQuota).toBe(3);      // floor((56-50)/2)
    expect(tight.onDemand).toBe(3);
    expect(tight.spot).toBe(16);                // the spot half is untouched by the on-demand squeeze
  });

  it('keeps toLaunch === spot + onDemand for every input', () => {
    for (const visible of [0, 3, 31, 1000]) {
      for (const usedSpotVcpu of [0, 16, 32]) {
        for (const usedOnDemandVcpu of [0, 24, 56, 60]) {
          const p = launchPlan({ ...stem, visible, fleetSize: 0, usedSpotVcpu, usedOnDemandVcpu });
          expect(p.toLaunch).toBe(p.spot + p.onDemand);
        }
      }
    }
  });

  it('is pure — the same inputs plan the same way twice', () => {
    const args = { ...stem, ...DEEP, fleetSize: 4, usedSpotVcpu: 8 };
    expect(launchPlan(args)).toEqual(launchPlan(args));
  });
});

describe('onDemandFallbackCount — the capacity fallback pays for the SHORTFALL, not the request', () => {
  it('THE MOTIVATING SCENARIO: a deep backlog must never produce a 30-instance on-demand launch', () => {
    // This is the bug, in one assertion. Old path: ask spot for 28 → MaxSpotInstanceCountExceeded →
    // runInstances(28, 'on-demand'). 28 × $0.1008 = $2.82/hr for as long as the backlog lasts,
    // against $1.12 on spot, logged as a success. New path: the spot ask is 16 (so the quota refusal
    // cannot happen at all), and if spot then refuses for genuine CAPACITY the fallback covers only
    // what spot failed to deliver, clipped by whatever the on-demand budget has left after the
    // planned 14.
    const p = launchPlan({ ...stem, ...DEEP });
    const fb = onDemandFallbackCount(p);
    expect(fb).toBeLessThan(30);
    expect(fb).toBeLessThanOrEqual(p.spot);                          // never more than spot failed to give
    expect(fb).toBeLessThanOrEqual(p.byOnDemandQuota - p.onDemand);  // never past the on-demand budget
    expect(p.onDemand + fb).toBeLessThanOrEqual(p.byOnDemandQuota);  // and the two together still fit
    expect(fb).toBe(14);                                             // min(16, 28 - 14)
  });

  it('the WORST CASE — spot dry in all four AZs — still stays inside the on-demand bucket', () => {
    // The full-outage bill: 14 planned plus 14 rescued = 28 = exactly the on-demand ceiling. Two
    // fewer than the lane's 30, and every one of them metered by the fallback guard.
    const p = launchPlan({ ...stem, ...DEEP });
    expect(p.onDemand + onDemandFallbackCount(p, 0)).toBe(OD_CEILING);
    expect((p.onDemand + onDemandFallbackCount(p, 0)) * M7I_LARGE).toBeLessThanOrEqual(ON_DEMAND_VCPU_CAP);
  });

  it('covers only what the PARTIAL spot launch missed', () => {
    // `--count 1:n` can come back with fewer than asked without throwing, and each AZ in the ring is
    // its own attempt. If 12 of 16 landed on spot, the fallback is worth 4 — paying for the 12 that
    // already exist would double the fleet.
    const p = launchPlan({ ...stem, ...DEEP });
    expect(onDemandFallbackCount(p, 12)).toBe(4);
    expect(onDemandFallbackCount(p, 16)).toBe(0);
    expect(onDemandFallbackCount(p, 99)).toBe(0);   // more than asked: still zero, never negative
  });

  it('never overdraws the on-demand bucket the planned half has already spent', () => {
    for (const usedOnDemandVcpu of [0, 10, 24, 40, 50, 56, 60]) {
      const p = launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu });
      const fb = onDemandFallbackCount(p);
      expect(fb).toBeGreaterThanOrEqual(0);
      expect((p.onDemand + fb) * M7I_LARGE).toBeLessThanOrEqual(Math.max(0, ON_DEMAND_VCPU_CAP - usedOnDemandVcpu));
    }
  });

  it('is zero when there was no spot ask to fall back FROM', () => {
    const onDemandLane = launchPlan({ ...stem, ...DEEP, market: 'on-demand' });
    expect(onDemandLane.spot).toBe(0);
    expect(onDemandFallbackCount(onDemandLane)).toBe(0);
  });

  it('is zero when the on-demand budget is already spent — a slow queue beats a refused bill', () => {
    const p = launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu: ON_DEMAND_VCPU_CAP });
    expect(p.byOnDemandQuota).toBe(0);
    expect(onDemandFallbackCount(p)).toBe(0);
  });

  it('is pure — the same plan decides the same way, and never mutates it', () => {
    const p = launchPlan({ ...stem, ...DEEP });
    const snapshot = JSON.stringify(p);
    expect(onDemandFallbackCount(p)).toBe(onDemandFallbackCount(p));
    expect(JSON.stringify(p)).toBe(snapshot);
  });
});

describe('launchPlan — TWO LANES, TWO BUCKETS', () => {
  const timbre = {
    maxWorkers: 3, jobsPerWorker: 16, vcpu: 8, market: 'on-demand',
    spotVcpuCap: SPOT_VCPU_QUOTA, usedSpotVcpu: 0,
    onDemandVcpuCap: ON_DEMAND_VCPU_CAP, usedOnDemandVcpu: 0,
  };

  it('a full SPOT stem fleet does not shrink what the ON-DEMAND timbre lane may launch', () => {
    // The honest model of the fix: 16 stem workers on spot spend 32 SPOT vCPU and ZERO on-demand
    // vCPU. Charging them to one shared 56-vCPU cap (as the old code had to) left timbre 24 → 3
    // instances by luck, and would leave it 0 the moment the stem lane grew past 16.
    const p = launchPlan({ ...timbre, visible: 1000, fleetSize: 0, usedSpotVcpu: 32, usedOnDemandVcpu: 0 });
    expect(p.byOnDemandQuota).toBe(7);     // floor(56/8) — untouched by the spot fleet
    expect(p.onDemand).toBe(3);            // the lane cap binds, as it always did
    expect(p.spot).toBe(0);                // timbre is deliberately on-demand: one message = ~50 songs
  });

  it('the ON-DEMAND timbre fleet still fences the stem lane\'s on-demand half', () => {
    // The cross-lane guard has to keep working — it just moved into the right bucket. Timbre at 24
    // vCPU leaves 32 on-demand vCPU = 16 m7i.large, more than the 14-instance shortfall, so the
    // shortfall lands whole; at 48 it does not.
    expect(launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu: 24 }).onDemand).toBe(14);
    expect(launchPlan({ ...stem, ...DEEP, usedOnDemandVcpu: 48 }).onDemand).toBe(4);   // floor((56-48)/2)
  });

  it('the SPOT bucket is shared too — a timbre backfill on spot shrinks the stem ask', () => {
    // POCKETDJ_TIMBRE_MARKET=spot for a big, restartable backfill is documented and supported, so
    // the guard must subtract whatever holds spot vCPU regardless of which lane owns it.
    const timbreOnSpot = 3 * 8;    // 3 × c7g.2xlarge
    const p = launchPlan({ ...stem, ...DEEP, usedSpotVcpu: timbreOnSpot });
    expect(p.bySpotQuota).toBe(4);   // floor((32 - 24) / 2)
    expect(p.spot).toBe(4);
    expect(p.onDemand).toBe(26);     // …and the rest is the shortfall, bounded by the OTHER bucket
  });

  it('an on-demand STEM lane reproduces the legacy single-cap numbers exactly', () => {
    // POCKETDJ_STEM_MARKET=on-demand is the documented manual brake, and it is also where the
    // preflight hold lands the lane. In that mode the plan must agree with launchCount against the
    // on-demand cap — the escape hatch has to be boring.
    for (const usedOnDemandVcpu of [0, 8, 32, 52, 60]) {
      const p = launchPlan({ ...stem, ...DEEP, market: 'on-demand', usedOnDemandVcpu });
      const legacy = launchCount({
        ...DEEP, maxWorkers: 30, jobsPerWorker: 2, vcpu: M7I_LARGE,
        usedVcpu: usedOnDemandVcpu, totalVcpuCap: ON_DEMAND_VCPU_CAP,
      });
      expect(p.onDemand).toBe(legacy.toLaunch);
      expect(p.toLaunch).toBe(legacy.toLaunch);
      expect(p.byOnDemandQuota).toBe(legacy.byQuota);
      expect(p.spot).toBe(0);
    }
  });

  it('an unrecognised market is treated as on-demand, never as spot', () => {
    // The module already exits(2) on a mistyped POCKETDJ_STEM_MARKET before it can launch anything,
    // so this is belt-and-braces — but the belt must point the same way as the braces. Defaulting an
    // unknown to spot would ask the spot bucket for a fleet nobody authorised.
    for (const market of [undefined, 'Spot', 'SPOT', '', null]) {
      const p = launchPlan({ ...stem, ...DEEP, market });
      expect(p.spot).toBe(0);
      expect(p.onDemand).toBeGreaterThan(0);
    }
  });
});

// ── Regression: the ORIGINAL guard is untouched ─────────────────────────────────────────────────
// tests/unit/timbre-autoscaler-vcpu.test.mjs and tests/unit/stem-spot-fallback.test.mjs both pin
// `launchCount`. It must keep its old signature and its old numbers — the two-bucket split adds a
// function, it does not change one.
describe('launchCount — unchanged by the quota split', () => {
  const legacyStem = { maxWorkers: 30, jobsPerWorker: 2, vcpu: 2, totalVcpuCap: 56 };
  const legacyTimbre = { maxWorkers: 3, jobsPerWorker: 16, vcpu: 8, totalVcpuCap: 56 };

  it('still returns { desired, toLaunch, byLane, byQuota } with the same arithmetic', () => {
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 0, ...legacyStem }))
      .toEqual({ desired: 30, byLane: 30, byQuota: 28, toLaunch: 28 });
  });
  it('still refuses the timbre lane when stem has spent the shared cap', () => {
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 52, ...legacyTimbre }).toLaunch).toBe(0);
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 40, ...legacyTimbre }).toLaunch).toBe(2);
  });
  it('still never returns a negative count when the fleet already exceeds the cap', () => {
    expect(launchCount({ visible: 100, fleetSize: 40, usedVcpu: 80, ...legacyStem }).toLaunch).toBe(0);
  });
  it('stays MARKET-BLIND — passing a market must not change its numbers', () => {
    const args = { visible: 10_000, fleetSize: 4, usedVcpu: 32, ...legacyStem };
    expect(launchCount({ ...args, market: 'spot' })).toEqual(launchCount(args));
    expect(launchCount({ ...args, market: 'on-demand' })).toEqual(launchCount(args));
  });
});
