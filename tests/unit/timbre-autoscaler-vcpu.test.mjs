// The cross-lane vCPU guard. The two worker fleets share ONE account-level standard-vCPU quota
// (64). At their configured maxima they sum to 84 — stem 30 × 2 plus timbre 3 × 8 — so without
// this arithmetic a reconcile can ask for capacity the other lane already spent and fail the
// whole pass, not just the excess.
import { describe, it, expect } from 'vitest';
import { launchCount } from '../../scripts/stem-autoscaler.mjs';

const timbre = { maxWorkers: 3, jobsPerWorker: 16, vcpu: 8, totalVcpuCap: 56 };

describe('launchCount', () => {
  it('launches nothing when the queue is empty — the fleet tracks depth, and depth is zero', () => {
    expect(launchCount({ visible: 0, fleetSize: 0, usedVcpu: 0, ...timbre }).toLaunch).toBe(0);
  });
  it('sizes the fleet to the backlog, not to the cap', () => {
    expect(launchCount({ visible: 16, fleetSize: 0, usedVcpu: 0, ...timbre }).toLaunch).toBe(1);
    expect(launchCount({ visible: 62, fleetSize: 0, usedVcpu: 0, ...timbre }).toLaunch).toBe(3);
  });
  it('never exceeds the lane cap even with a huge backlog', () => {
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 0, ...timbre }).toLaunch).toBe(3);
  });
  it('counts what is already running so a second pass does not double the fleet', () => {
    expect(launchCount({ visible: 62, fleetSize: 2, usedVcpu: 16, ...timbre }).toLaunch).toBe(1);
  });
  it('REFUSES to launch past the shared quota even when its own lane has headroom', () => {
    // The stem lane holding 52 vCPU leaves 4 — not enough for one 8-vCPU timbre instance.
    const r = launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 52, ...timbre });
    expect(r.byLane).toBe(3);
    expect(r.byQuota).toBe(0);
    expect(r.toLaunch).toBe(0);
  });
  it('launches only what the remaining quota affords', () => {
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 40, ...timbre }).toLaunch).toBe(2);
  });
  it('never returns a negative launch count when the fleet already exceeds the cap', () => {
    expect(launchCount({ visible: 100, fleetSize: 5, usedVcpu: 40, ...timbre }).toLaunch).toBe(0);
  });
});
