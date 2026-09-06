// THE ON-DEMAND TOP-UP KNOB — the one that decides whether a quota-capped lane costs $0.67/hr or
// $2.08/hr.
//
// `POCKETDJ_ONDEMAND_TOPUP` was read into CFG and then never consulted by anything. Both the module
// header and STEM-OFFLOAD.md documented it as the way to stop the autoscaler buying the 14-instance
// shortfall on-demand, so an operator who set it to 0 to cap the bill got a flag that did precisely
// nothing and a fleet that kept buying. A cost knob that silently does nothing is worse than no knob:
// it is believed.
//
// The arithmetic these tests pin, for the live account (spot L-34B43A08 = 32 vCPU, on-demand
// L-1216C47A = 64, repo cap 56, m7i.large = 2 vCPU) on a 300-message backlog at 2 jobs/worker:
//
//   desired 30 · spot ceiling 16 · shortfall 14
//   top-up ON  (default) → 16 spot + 14 on-demand ≈ 16×$0.042 + 14×$0.1008 ≈ $2.08/hr
//   top-up OFF           → 16 spot                ≈                         $0.67/hr
//   pre-fix behaviour    → 28 on-demand           ≈ 28×$0.1008              ≈ $2.82/hr
//
// The distinction the gate must NOT blur: the QUOTA-CAPPED top-up (spot cannot legally hold more) is
// what the knob governs. The CAPACITY FALLBACK (spot was asked and did not deliver) is a different
// question with its own meter, and turning the top-up off must not disarm it — that would convert a
// cost setting into a pipeline stall the first time a pool went dry.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, chmodSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { launchPlan, onDemandFallbackCount } from '../../scripts/stem-autoscaler.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const AUTOSCALER = join(REPO, 'scripts', 'stem-autoscaler.mjs');

// The live account, measured 2026-09-06 with `aws service-quotas get-service-quota`.
const STEM = {
  visible: 300, fleetSize: 0, maxWorkers: 30, jobsPerWorker: 2, vcpu: 2, market: 'spot',
  spotVcpuCap: 32, usedSpotVcpu: 0, onDemandVcpuCap: 56, usedOnDemandVcpu: 0,
};

describe('launchPlan — the top-up gate, in arithmetic', () => {
  it('DEFAULTS ON: 16 spot + the 14-instance shortfall, never the 28-30 the old code bought', () => {
    // Omitting the option entirely must keep the tested behaviour. A gate that defaulted off would
    // silently cut the fleet from 30 to 16 on every busy day — a throughput change nobody asked for,
    // arriving disguised as a cost fix.
    const p = launchPlan(STEM);
    expect(p.spot).toBe(16);
    expect(p.onDemand).toBe(14);
    expect(p.shortfall).toBe(14);
    expect(p.toLaunch).toBe(30);
  });

  it('OFF caps the lane at the spot ceiling and buys nothing', () => {
    const p = launchPlan({ ...STEM, onDemandTopup: false });
    expect(p.spot).toBe(16);
    expect(p.onDemand).toBe(0);
    expect(p.toLaunch).toBe(16);
  });

  it('still REPORTS the shortfall when it refuses to buy it', () => {
    // The number the ceiling notice and --status print. Zeroing it along with the purchase is how a
    // lane pinned at 16/30 stops being a setting and starts looking like a bug.
    expect(launchPlan({ ...STEM, onDemandTopup: false }).shortfall).toBe(14);
  });

  it('never gates an ON-DEMAND LANE — timbre has no spot half to cap', () => {
    // The gate keys on the spot half existing, not on the lane's name. Reading it as "no on-demand"
    // would take the timbre fleet to zero and stall the corpus backfill outright.
    for (const onDemandTopup of [true, false]) {
      const p = launchPlan({
        visible: 300, fleetSize: 0, maxWorkers: 3, jobsPerWorker: 16, vcpu: 8, market: 'on-demand',
        spotVcpuCap: 32, usedSpotVcpu: 0, onDemandVcpuCap: 56, usedOnDemandVcpu: 0, onDemandTopup,
      });
      expect(p.spot).toBe(0);
      expect(p.onDemand).toBe(3);
      expect(p.toLaunch).toBe(3);
    }
  });

  it('leaves the CAPACITY fallback armed — the knob is about quota, not about outages', () => {
    // With the top-up off, plan.onDemand is 0, so the whole on-demand bucket is still available to
    // rescue a dry pool. The rescue is bounded by what SPOT was asked for (16), never by the lane's
    // original 30 — that bound is the 2.7× fix itself.
    const p = launchPlan({ ...STEM, onDemandTopup: false });
    expect(onDemandFallbackCount(p, 0)).toBe(16);      // spot delivered nothing → rescue all 16
    expect(onDemandFallbackCount(p, 12)).toBe(4);      // spot delivered 12 → buy the 4 it missed
    expect(onDemandFallbackCount(p, 16)).toBe(0);      // spot delivered everything → buy nothing
  });

  it('no combination of settings ever plans a 30-instance on-demand ask', () => {
    // The bug this branch exists to prevent, asserted over the whole knob surface rather than at the
    // one point it was found.
    //
    // NOTE the two layers. At the PLAN layer the only guarantees are the on-demand bucket and "not
    // the whole fleet": `plan.onDemand + onDemandFallbackCount()` legitimately reaches 28 when the
    // top-up is on and spot delivers nothing, because the top-up's 14 and the rescue's 14 are
    // different purchases. The tighter "never more than the spot ask" bound is applied by
    // launchFleet, which clamps the sum to max(plan.spot, plan.onDemand) — that clamp is what the
    // process-level test below measures at 16. Asserting it here would only be re-typing launchFleet.
    for (const onDemandTopup of [true, false]) {
      for (const usedSpotVcpu of [0, 16, 32]) {
        const p = launchPlan({ ...STEM, onDemandTopup, usedSpotVcpu });
        const planned = p.onDemand + onDemandFallbackCount(p, 0);
        expect(planned).toBeLessThanOrEqual(p.byOnDemandQuota);
        expect(planned).toBeLessThan(30);
        expect(planned * STEM.vcpu).toBeLessThanOrEqual(STEM.onDemandVcpuCap);
      }
    }
  });
});

// ── and the same thing through the real process, because a pure default proves nothing about CFG ──
let DIR;
beforeAll(() => {
  DIR = mkdtempSync(join(tmpdir(), 'stem-topup-'));
  mkdirSync(join(DIR, 'bin'), { recursive: true });
  const p = join(DIR, 'bin', 'aws');
  writeFileSync(p, `#!/bin/bash
echo "$*" >> "$AWSLOG"
case "$1 $2" in
"sqs get-queue-attributes") echo '{"Attributes":{"ApproximateNumberOfMessages":"300","ApproximateNumberOfMessagesNotVisible":"0"}}';;
"ec2 describe-instances") echo '[]';;
"ec2 describe-launch-template-versions") echo '{"LaunchTemplateVersions":[{"LaunchTemplateData":{"InstanceType":"m7i.large","NetworkInterfaces":[{"DeviceIndex":0,"SubnetId":"subnet-00a23032877bbe190"}]}}]}';;
"s3api head-object") echo '{"ETag":"\\"aware\\"","Metadata":{"spot-aware":"yes"}}';;
"ec2 run-instances")
  n=\$(echo "\$*" | sed -n 's/.*--count 1:\\([0-9][0-9]*\\).*/\\1/p'); n=\${n:-1}
  case "\$*" in *--instance-market-options*)
    if [ -n "\$SPOTFAIL" ]; then echo "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation: no capacity" >&2; exit 255; fi
    pfx=spot;; *) pfx=od;; esac
  ids=""; i=0; while [ \$i -lt \$n ]; do ids="\$ids i-\${pfx}\$(printf '%04d' \$i)"; i=\$((i+1)); done; echo \$ids;;
*) echo '{}';;
esac
exit 0
`);
  chmodSync(p, 0o755);
});
afterAll(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

function run(env = {}) {
  const home = mkdtempSync(join(DIR, 'run-'));
  const awsLog = join(home, 'aws.log');
  writeFileSync(awsLog, '');
  const r = spawnSync(process.execPath, [AUTOSCALER], {
    encoding: 'utf8',
    timeout: 60_000,
    env: {
      ...process.env,
      PATH: `${join(DIR, 'bin')}:${process.env.PATH}`,
      AWS_PROFILE: '',
      AWS_REGION: 'us-west-2',
      AWSLOG: awsLog,
      POCKETDJ_AUTOSCALER_STATE_DIR: join(home, 'state'),
      ...env,
    },
  });
  const launches = readFileSync(awsLog, 'utf8').split('\n').filter((l) => l.startsWith('ec2 run-instances'));
  const count = (l) => Number(/--count 1:(\d+)/.exec(l)?.[1] ?? 0);
  const spot = launches.filter((l) => l.includes('--instance-market-options'));
  const od = launches.filter((l) => !l.includes('--instance-market-options'));
  const sum = (ls) => ls.reduce((a, l) => a + count(l), 0);
  return { out: `${r.stdout || ''}${r.stderr || ''}`, spot: sum(spot), od: sum(od), odCalls: od.length };
}

describe('the knob is WIRED to the process, not just to the function', () => {
  it('unset behaves as ON — 16 spot + 14 on-demand', () => {
    const r = run();
    expect(r.spot).toBe(16);
    expect(r.od).toBe(14);
  });

  it('POCKETDJ_ONDEMAND_TOPUP=0 really does stop the purchase', () => {
    // The regression. Before the fix this launched 14 on-demand regardless, and the operator who set
    // the flag had no way to tell except from the invoice.
    const r = run({ POCKETDJ_ONDEMAND_TOPUP: '0' });
    expect(r.spot).toBe(16);
    expect(r.od).toBe(0);
    expect(r.odCalls).toBe(0);
  });

  it('says WHY the fleet stopped at 16/30 rather than going quiet', () => {
    const out = run({ POCKETDJ_ONDEMAND_TOPUP: '0' }).out;
    expect(out).toMatch(/ceiling/i);
    expect(out).toMatch(/POCKETDJ_ONDEMAND_TOPUP=0/);
  });

  it('a dry pool is still rescued with the top-up off — and never with 30 instances', () => {
    // Cost setting, not an availability setting.
    const r = run({ POCKETDJ_ONDEMAND_TOPUP: '0', SPOTFAIL: '1' });
    expect(r.od).toBe(16);
    expect(r.od).toBeLessThan(30);
    expect(r.out).toMatch(/paying on-demand/i);
  });
});
