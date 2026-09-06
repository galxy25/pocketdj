// SPOT worker fleet — the spot→on-demand fallback DECISION, and a regression guard proving the
// spot switch did not disturb the scaling arithmetic.
//
// The stem fleet moves from on-demand m7i.large ($0.1008/hr) to spot (~$0.0375–0.0446/hr) — ~60%
// off, ~$26/mo at August's volume (426.9 hrs, 1,148 launches, 10,988 jobs). That is safe because
// the workers are stateless SQS consumers: a killed instance loses only the in-flight job, whose
// SQS message goes un-deleted, is redelivered, and lands in the DLQ only after 3 tries.
//
// The one thing that MUST be right is when to retry on-demand. Spot has its own failure modes that
// on-demand does not share (no spot capacity, price floor above our bid, spot request cap) — those
// are worth a second, more expensive attempt. Everything else fails IDENTICALLY on-demand, so a
// fallback there just doubles the error, doubles the latency, and can silently double the bill.
// VcpuLimitExceeded is the sharp case: it is a STANDARD-vCPU quota failure, which an on-demand
// retry hits just as hard.
import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchCount, shouldFallbackToOnDemand } from '../../scripts/stem-autoscaler.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Real `aws ec2 run-instances` stderr, as Node's execFileSync surfaces it: "Command failed: <cmd>\n"
// followed by the CLI's own "An error occurred (<Code>) when calling the RunInstances operation".
// The decision must key on the ERROR CODE, not on prose or on the command line.
const CMD = 'Command failed: aws ec2 run-instances --launch-template '
  + 'LaunchTemplateName=pocketdj-stem-worker-spot,Version=$Latest --count 1:4 --region us-west-2\n';
const awsErr = (code, detail) => `${CMD}\nAn error occurred (${code}) when calling the RunInstances operation: ${detail}`;

const NO_SPOT_CAPACITY = awsErr('InsufficientInstanceCapacity',
  'We currently do not have sufficient m7i.large capacity in the Availability Zone you requested '
  + '(us-west-2a). Our system will be working on provisioning additional capacity.');
const PRICE_TOO_LOW = awsErr('SpotMaxPriceTooLow',
  'Your Spot request price of 0.02 is lower than the minimum required Spot request fulfillment price of 0.0375.');
const SPOT_CAP = awsErr('MaxSpotInstanceCountExceeded', 'Max spot instance count exceeded');

const UNAUTHORIZED = awsErr('UnauthorizedOperation',
  'You are not authorized to perform this operation. User: arn:aws:iam::011183829623:user/levi is not '
  + 'authorized to perform: ec2:RunInstances. Encoded authorization failure message: aHR0cHM6Ly9zcG90');
const NO_TEMPLATE = awsErr('InvalidLaunchTemplateName.NotFoundException',
  'At least one of the launch templates specified in the request does not exist.');
const VCPU_QUOTA = awsErr('VcpuLimitExceeded',
  'You have requested more vCPU capacity than your current vCPU limit of 64 allows for the instance '
  + 'bucket that the specified instance type belongs to.');

describe('shouldFallbackToOnDemand — retry on-demand ONLY for spot-specific failures', () => {
  it('falls back when there is no spot capacity — on-demand has its own pool', () => {
    expect(shouldFallbackToOnDemand(NO_SPOT_CAPACITY)).toBe(true);
  });
  it('falls back when the spot price floor rose above our max price', () => {
    expect(shouldFallbackToOnDemand(PRICE_TOO_LOW)).toBe(true);
  });
  it('falls back when the account spot-request cap is full — the on-demand cap is separate', () => {
    expect(shouldFallbackToOnDemand(SPOT_CAP)).toBe(true);
  });

  it('does NOT fall back on VcpuLimitExceeded — the SAME standard-vCPU quota blocks on-demand', () => {
    // The trap: this is the one non-spot error that reads like a capacity error. Falling back
    // re-runs the identical request against the identical quota and logs the identical failure —
    // twice the API calls, twice the noise, zero instances. It also ends "…Exceeded", so a matcher
    // written as /Exceeded/ would get this wrong while looking right on MaxSpotInstanceCountExceeded.
    expect(shouldFallbackToOnDemand(VCPU_QUOTA)).toBe(false);
    expect(shouldFallbackToOnDemand(SPOT_CAP)).toBe(true);
  });
  it('does NOT fall back on an IAM denial — an on-demand retry is denied the same way', () => {
    expect(shouldFallbackToOnDemand(UNAUTHORIZED)).toBe(false);
  });
  it('does NOT fall back on a missing launch template — nothing to launch either way', () => {
    expect(shouldFallbackToOnDemand(NO_TEMPLATE)).toBe(false);
  });

  it('keys on the error CODE, not on the word "spot" appearing in the command line', () => {
    // Both non-spot fixtures carry "spot" in the echoed command (the template is named
    // pocketdj-stem-worker-SPOT) and UNAUTHORIZED's encoded blob happens to contain "spot" too.
    // A /spot/i matcher passes every positive case above and still gets both of these wrong.
    expect(UNAUTHORIZED.toLowerCase()).toContain('spot');
    expect(NO_TEMPLATE.toLowerCase()).toContain('spot');
    expect(shouldFallbackToOnDemand(UNAUTHORIZED)).toBe(false);
    expect(shouldFallbackToOnDemand(NO_TEMPLATE)).toBe(false);
  });

  it('never falls back on nothing — an empty/absent error is not a capacity signal', () => {
    // launch() catches and stringifies; a lost stderr must not turn into a phantom on-demand launch.
    expect(shouldFallbackToOnDemand('')).toBe(false);
    expect(shouldFallbackToOnDemand(undefined)).toBe(false);
    expect(shouldFallbackToOnDemand(null)).toBe(false);
  });
  it('is pure — the same stderr decides the same way every time, with no accumulated state', () => {
    for (let i = 0; i < 3; i += 1) {
      expect(shouldFallbackToOnDemand(NO_SPOT_CAPACITY)).toBe(true);
      expect(shouldFallbackToOnDemand(VCPU_QUOTA)).toBe(false);
    }
  });

  it('falls back on InsufficientHostCapacity too — same AZ-capacity story, different code', () => {
    expect(shouldFallbackToOnDemand(awsErr('InsufficientHostCapacity',
      'There is no available capacity for the requested instance type.'))).toBe(true);
  });
  it('does NOT fall back on InstanceLimitExceeded — that is the ON-DEMAND instance cap', () => {
    expect(shouldFallbackToOnDemand(awsErr('InstanceLimitExceeded',
      'You have requested more instances (30) than your current instance limit of 20 allows.'))).toBe(false);
  });
  it('does NOT fall back on an UNRECOGNISED failure — a stalled queue beats a surprise bill', () => {
    // Defaulting an unknown code to "retry on-demand" is the expensive direction to be wrong in:
    // it can SUCCEED and quietly bill full price for a launch path nobody has noticed is broken.
    // The reconcile re-runs in a minute, so refusing costs one tick of latency.
    expect(shouldFallbackToOnDemand(awsErr('RequestLimitExceeded', 'Request limit exceeded.'))).toBe(false);
    expect(shouldFallbackToOnDemand(awsErr('InvalidParameterValue', 'Invalid market options.'))).toBe(false);
    expect(shouldFallbackToOnDemand('aws: error: connection reset by peer')).toBe(false);
  });
  it('still recognises a BARE code when the CLI envelope is missing (wrapped/reshaped errors)', () => {
    expect(shouldFallbackToOnDemand('RunInstances failed: InsufficientInstanceCapacity')).toBe(true);
    expect(shouldFallbackToOnDemand('RunInstances failed: VcpuLimitExceeded')).toBe(false);
  });
});

describe('market config — a mistyped market must REFUSE, not guess', () => {
  it('exits non-zero on an unknown POCKETDJ_STEM_MARKET before it can launch anything', () => {
    // Coercing an unknown value either way is a money bug: reading `Spot` as on-demand bills full
    // price silently for months, and reading it as spot would put the timbre lane (deliberately
    // on-demand: one message = a ~50-song batch, and each interruption spends a redelivery) on a
    // market its operator never asked for. This guard runs at module load, before any AWS call.
    let code = 0; let out = '';
    try {
      execFileSync(process.execPath, [join(REPO, 'scripts/stem-autoscaler.mjs'), '--status'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, POCKETDJ_STEM_MARKET: 'Spot ' } });
    } catch (e) { code = e.status; out = `${e.stderr || ''}`; }
    expect(code).toBe(2);
    expect(out).toMatch(/market/i);
  });
});

// ── Regression guard ────────────────────────────────────────────────────────────────────────────
// The spot switch is a `launch()` concern (InstanceMarketOptions on the run-instances call). None
// of the arithmetic below may move because of it. tests/unit/timbre-autoscaler-vcpu.test.mjs pins
// the timbre lane; this pins the STEM lane (m7i.large, 2 vCPU) and the cross-lane sum.
const stem = { maxWorkers: 30, jobsPerWorker: 2, vcpu: 2, totalVcpuCap: 56 };
const timbre = { maxWorkers: 3, jobsPerWorker: 16, vcpu: 8, totalVcpuCap: 56 };

describe('launchCount — unchanged by the move to spot', () => {
  it('still launches nothing on an empty queue', () => {
    expect(launchCount({ visible: 0, fleetSize: 0, usedVcpu: 0, ...stem }).toLaunch).toBe(0);
  });
  it('still sizes the stem fleet to the backlog at 2 jobs per worker', () => {
    expect(launchCount({ visible: 2, fleetSize: 0, usedVcpu: 0, ...stem }).toLaunch).toBe(1);
    expect(launchCount({ visible: 7, fleetSize: 0, usedVcpu: 0, ...stem }).toLaunch).toBe(4);
  });
  it('still lets the shared vCPU cap bind BELOW the stem lane cap', () => {
    // 30 × m7i.large would be 60 vCPU against a 56 cap — the guard, not the lane, is the limit.
    const r = launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 0, ...stem });
    expect(r.byLane).toBe(30);
    expect(r.byQuota).toBe(28);
    expect(r.toLaunch).toBe(28);
  });
  it('still counts the OTHER lane: a full timbre fleet shrinks what stem may launch', () => {
    // 3 × c7g.2xlarge = 24 vCPU held by timbre, plus 4 stem workers = 8 → 32 used, 24 left → 12.
    const r = launchCount({ visible: 10_000, fleetSize: 4, usedVcpu: 24 + 8, ...stem });
    expect(r.byLane).toBe(26);
    expect(r.byQuota).toBe(12);
    expect(r.toLaunch).toBe(12);
  });
  it('still refuses the timbre lane when stem has spent the quota (the original guard case)', () => {
    const r = launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 52, ...timbre });
    expect(r.byLane).toBe(3);
    expect(r.byQuota).toBe(0);
    expect(r.toLaunch).toBe(0);
    expect(launchCount({ visible: 10_000, fleetSize: 0, usedVcpu: 40, ...timbre }).toLaunch).toBe(2);
  });
  it('still never returns a negative count when the fleet already exceeds the cap', () => {
    expect(launchCount({ visible: 100, fleetSize: 40, usedVcpu: 80, ...stem }).toLaunch).toBe(0);
  });

  it('stays MARKET-BLIND — the spot/on-demand choice never enters the arithmetic', () => {
    // Spot draws on a SEPARATE account quota from on-demand standard vCPU, so it is tempting to
    // make the guard market-aware. Do not: the fallback path can launch on-demand from the same
    // reconcile, and a guard that budgeted only against the spot quota would then overshoot the
    // on-demand one. launchCount must return the same numbers whatever market the caller intends.
    const args = { visible: 10_000, fleetSize: 4, usedVcpu: 32, ...stem };
    expect(launchCount({ ...args, market: 'spot' })).toEqual(launchCount(args));
    expect(launchCount({ ...args, market: 'on-demand' })).toEqual(launchCount(args));
  });
});
