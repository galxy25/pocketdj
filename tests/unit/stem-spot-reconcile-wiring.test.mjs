// RECONCILE, WIRED — what the autoscaler PROCESS actually asks AWS for.
//
// The other files in this batch test pure functions. `tests/unit/stem-spot-serve-loop.test.mjs`
// exists because that was not enough once already: `armSpotWatch`, `parseSpotInterruption`,
// `releasePlan` and `shouldFallbackToOnDemand` were all green while the runtime path was DEAD — the
// idle loop starved the timer, so the reclaim notice was never read and no pure test could have
// known.
//
// All four fixes here have that same shape, and TWO OF THEM HAVE NO PURE SURFACE AT ALL: `spotGate`
// (the preflight) and `fallbackBudget` (the meter) are module-private and talk to S3 and EC2. Even
// the exported ones can ship broken while green — `launchPlan` can compute 16 while the launcher
// still passes 30, and `azOrder` can permute perfectly while every launch goes to the same subnet.
// Each of those ships green and costs real money or real songs. So this file runs the real
// `scripts/stem-autoscaler.mjs` with `aws` shimmed onto PATH and asserts on the argv it produced and
// the state it left behind.
//
// EVERY PASS IS A SEPARATE PROCESS, on purpose: that is what the LaunchAgent does every 60 s, and it
// is precisely why the fallback meter, the preflight verdict and the AZ cursor have to be on disk.
// An in-memory counter passes a pure test and permits an unbounded run of "first" fallbacks in
// production.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, chmodSync, existsSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const AUTOSCALER = join(REPO, 'scripts', 'stem-autoscaler.mjs');
const SPOT_CEILING = 16;      // 32 spot vCPU (L-34B43A08) ÷ 2 per m7i.large
const OD_CEILING = 28;        // 56 on-demand vCPU ÷ 2
const SUBNETS = ['subnet-00a23032877bbe190', 'subnet-00f9be279c616ff01',
  'subnet-0c623f93e8a27ea34', 'subnet-055bd6cc3fb64e8b7'];

let DIR;
const sh = (p, body) => { writeFileSync(p, body); chmodSync(p, 0o755); };

beforeAll(() => {
  DIR = mkdtempSync(join(tmpdir(), 'stem-spot-wiring-'));
  mkdirSync(join(DIR, 'bin'), { recursive: true });

  // The `aws` shim. Every invocation is logged verbatim; the answers are the real API shapes for the
  // exact `--query`/`--output` each call site uses. Control files in $STATE flip the scenarios:
  //   $STATE/deployed — the DEPLOYED object carries x-amz-meta-spot-aware=yes, the stamp a verified
  //                     `bash scripts/stem-deploy-worker.sh` writes only after reading its own
  //                     upload back and finding the reclaim handler in it
  //   $STATE/pinned   — the launch template still defines a NetworkInterfaces block (as it does live)
  //   $STATE/spotfail — every spot run-instances refuses for AZ-scoped capacity
  //   $STATE/denied   — every spot run-instances refuses for a NON-capacity reason
  //   $STATE/notpl    — describe-launch-template-versions fails outright
  //   $STATE/s3fail   — the worker-code object cannot be read at all
  sh(join(DIR, 'bin', 'aws'), `#!/bin/bash
echo "$*" >> "$AWSLOG"
case "$1 $2" in
"sqs get-queue-attributes")
  echo '{"Attributes":{"ApproximateNumberOfMessages":"'"\${VISIBLE:-1000}"'","ApproximateNumberOfMessagesNotVisible":"0"}}'
  ;;
"ec2 describe-instances")   # --query 'Reservations[].Instances[].{id,lifecycle,state}' --output json
  echo '[]'
  ;;
"ec2 describe-launch-template-versions")
  if [ -f "\$STATE/notpl" ]; then
    echo "An error occurred (InvalidLaunchTemplateName.NotFoundException) when calling the DescribeLaunchTemplateVersions operation: At least one of the launch templates specified in the request does not exist." >&2
    exit 255
  fi
  if [ -f "\$STATE/pinned" ]; then
    echo '{"LaunchTemplateVersions":[{"VersionNumber":4,"LaunchTemplateData":{"InstanceType":"m7i.large","NetworkInterfaces":[{"DeviceIndex":0,"SubnetId":"subnet-00a23032877bbe190","AssociatePublicIpAddress":true,"DeleteOnTermination":true,"Groups":["sg-053afe62aa1e78bf9"]}]}}]}'
  else
    echo '{"LaunchTemplateVersions":[{"VersionNumber":5,"LaunchTemplateData":{"InstanceType":"m7i.large","SecurityGroupIds":["sg-053afe62aa1e78bf9"]}}]}'
  fi
  ;;
"s3api head-object")
  if [ -f "\$STATE/s3fail" ]; then
    echo "An error occurred (AccessDenied) when calling the HeadObject operation: Access Denied" >&2
    exit 255
  fi
  if [ -f "\$STATE/deployed" ]; then
    echo '{"ContentLength":32400,"ETag":"\\"aware\\"","LastModified":"2026-09-06T10:02:11+00:00","ContentType":"text/javascript","Metadata":{"spot-aware":"yes","sha256":"b3d1","deployed-at":"2026-09-06T10:02:11Z"}}'
  else
    echo '{"ContentLength":24918,"ETag":"\\"blind\\"","LastModified":"2026-07-19T04:11:33+00:00","ContentType":"text/javascript","Metadata":{}}'
  fi
  ;;
"ec2 run-instances")
  n=\$(echo "\$*" | sed -n 's/.*--count 1:\\([0-9][0-9]*\\).*/\\1/p'); n=\${n:-1}
  case "\$*" in
    *--instance-market-options*)
      if [ -f "\$STATE/denied" ]; then
        echo "An error occurred (UnauthorizedOperation) when calling the RunInstances operation: You are not authorized to perform this operation." >&2
        exit 255
      fi
      if [ -f "\$STATE/spotfail" ]; then
        echo "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation: We currently do not have sufficient m7i.large capacity in the Availability Zone you requested." >&2
        exit 255
      fi
      pfx=spot ;;
    *) pfx=od ;;
  esac
  ids=""; i=0
  while [ \$i -lt \$n ]; do ids="\$ids i-\${pfx}\$(printf '%04d' \$i)"; i=\$((i+1)); done
  echo \$ids
  ;;
*) echo '{}' ;;
esac
exit 0
`);
});

afterAll(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

/// One scenario = a fresh state dir and N sequential reconcile PROCESSES — the LaunchAgent's 60 s
/// cadence, minus the waiting. Returns every `aws` argv the runs produced, plus their output.
function reconcile({
  passes = 1, deployed = true, pinned = true, spotfail = false, denied = false, notpl = false,
  s3fail = false, visible = 1000, args = [], env = {},
} = {}) {
  const home = mkdtempSync(join(DIR, 'run-'));
  const ctl = join(home, 'ctl');
  mkdirSync(ctl, { recursive: true });
  for (const [flag, on] of [['deployed', deployed], ['pinned', pinned], ['spotfail', spotfail],
    ['denied', denied], ['notpl', notpl], ['s3fail', s3fail]]) {
    if (on) writeFileSync(join(ctl, flag), '');
  }
  const awsLog = join(home, 'aws.log');
  writeFileSync(awsLog, '');
  const stateDir = join(home, 'state');

  const runs = [];
  for (let i = 0; i < passes; i += 1) {
    runs.push(spawnSync(process.execPath, [AUTOSCALER, ...args], {
      encoding: 'utf8', timeout: 60_000,
      env: {
        ...process.env,
        PATH: `${join(DIR, 'bin')}:${process.env.PATH}`,
        AWS_PROFILE: '',
        AWS_REGION: 'us-west-2',
        AWSLOG: awsLog, STATE: ctl, VISIBLE: String(visible),
        POCKETDJ_AUTOSCALER_STATE_DIR: stateDir,
        ...env,
      },
    }));
  }
  const lane = args.includes('timbre') ? 'timbre' : 'stem';
  const stateFile = join(stateDir, `${lane}.json`);
  const calls = readFileSync(awsLog, 'utf8').split('\n').filter(Boolean);
  return {
    runs, calls, stateFile,
    state: () => (existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : null),
    out: runs.map((r) => `${r.stdout || ''}${r.stderr || ''}`).join('\n'),
    launches: calls.filter((l) => l.startsWith('ec2 run-instances')),
  };
}

const isSpotLaunch = (l) => l.includes('--instance-market-options');
const countOf = (l) => Number(/--count 1:(\d+)/.exec(l)?.[1] ?? 0);
const subnetOf = (l) => /--subnet-id (subnet-[0-9a-f]+)/.exec(l)?.[1] ?? null;
const total = (ls) => ls.reduce((a, l) => a + countOf(l), 0);
const odLaunches = (r) => r.launches.filter((l) => !isSpotLaunch(l));
const spotLaunches = (r) => r.launches.filter(isSpotLaunch);
// The guard's knobs. The ceiling and the burst brake are separate properties, so the tests that
// exercise one switch the other off rather than letting them mask each other.
const GUARD = { POCKETDJ_STEM_FALLBACK_COOLDOWN_S: '0' };

describe('PREFLIGHT is wired — a spot-blind DEPLOYED worker really does force on-demand', () => {
  it('launches ON-DEMAND while the deployed object cannot handle a reclaim', () => {
    // The rollout race, end to end. Merging this branch with the July object still on S3 must not
    // put a single spot instance in the air, whatever LANES.stem.market says — every reclaim of a
    // spot-blind worker strands a job for 1800 s and spends one of its three deliveries, and three
    // unlucky reclaims dead-letter a song that never failed.
    const r = reconcile({ deployed: false });
    expect(r.launches.length).toBeGreaterThan(0);
    expect(spotLaunches(r)).toHaveLength(0);
  });

  it('SAYS so, loudly, rather than downgrading in silence', () => {
    // A silent downgrade is a fleet quietly billing 2.7× with nothing to grep for. The whole point of
    // holding spot is that somebody finds out and runs the deploy.
    const out = reconcile({ deployed: false }).out;
    expect(out).toMatch(/SPOT HELD/i);
    expect(out).toMatch(/stem-deploy-worker\.sh/);      // …and names the fix
  });

  it('launches SPOT once the deployed worker really is spot-aware', () => {
    // The gate is a gate, not a wall: a verified deploy must actually unlock the discount, or the
    // whole change is inert and the ~60% saving never arrives.
    expect(spotLaunches(reconcile({ deployed: true })).length).toBeGreaterThan(0);
  });

  it('asks about the DEPLOYED object, not the repo copy sitting beside it', () => {
    const r = reconcile({ deployed: true });
    expect(r.calls.some((l) => l.includes('worker-code/stem-worker.mjs'))).toBe(true);
  });

  it('CACHES the verdict across the 60 s cadence instead of re-checking every tick', () => {
    // Cached in memory is not cached: every tick is a brand-new process, so an in-process cache is
    // one S3 round trip per minute for an object that changes about once a month — and, worse, it
    // is the same structural mistake as an in-memory fallback counter. On disk, four passes cost
    // exactly one HEAD.
    const r = reconcile({ passes: 4, deployed: true, env: { POCKETDJ_STEM_PREFLIGHT_TTL_S: '600' } });
    expect(r.calls.filter((l) => l.startsWith('s3api head-object'))).toHaveLength(1);
  });

  it('re-checks once the cache expires — a stale yes must not authorise spot for ever', () => {
    // The other direction. A verdict cached without expiry would let a yes from last week authorise
    // spot after the worker-code object had been replaced by a hand-run `aws s3 cp`.
    const r = reconcile({ passes: 3, deployed: true, env: { POCKETDJ_STEM_PREFLIGHT_TTL_S: '0' } });
    expect(r.calls.filter((l) => l.startsWith('s3api head-object'))).toHaveLength(3);
  });

  it('never downloads the worker body — the stamp is metadata, and a HEAD is enough', () => {
    // A few hundred bytes per check instead of 32 KB, on a 60 s cadence, for a verdict that changes
    // monthly.
    const r = reconcile({ passes: 3, deployed: true, env: { POCKETDJ_STEM_PREFLIGHT_TTL_S: '0' } });
    expect(r.calls.filter((l) => l.startsWith('s3 cp'))).toHaveLength(0);
  });

  it('fails SAFE when the object cannot be READ — no verdict, no spot, but still launches', () => {
    // An AccessDenied on the check (a credentials change, a bucket-policy edit) while everything else
    // works. "Cannot tell" has to mean on-demand — guessing on-demand overpays for a few minutes,
    // guessing spot dead-letters songs — and the queue must still drain, so a permissions problem
    // costs money rather than availability.
    const r = reconcile({ deployed: true, s3fail: true, visible: 1000 });
    expect(r.launches.length).toBeGreaterThan(0);
    expect(spotLaunches(r)).toHaveLength(0);
    expect(r.out).toMatch(/SPOT HELD|cannot verify/i);
  });
});

describe('QUOTA is wired — the spot ask is sized against the SPOT bucket', () => {
  it('asks for at most 16 spot instances on a backlog that wants 30', () => {
    // visible=1000 at 2 jobs/worker wants the full lane cap of 30. The spot quota (L-34B43A08 = 32
    // vCPU) allows 16 m7i.large. Asking for more earns MaxSpotInstanceCountExceeded, which the
    // fallback set treats as "pay full price" — for the ENTIRE request, because a quota refusal is
    // all-or-nothing. That is the trap; this is the assertion that closes it.
    const spot = spotLaunches(reconcile({ deployed: true, visible: 1000 }));
    expect(spot.length).toBeGreaterThan(0);
    for (const l of spot) expect(countOf(l)).toBeLessThanOrEqual(SPOT_CEILING);
  });

  it('NEVER launches 30 on-demand instances, in any scenario', () => {
    // The bug, wired: ~28-30 × $0.1008 ≈ $3/hr against ~$0.64 on spot, for as long as the backlog
    // lasts, and logged as a success. Whatever the pass meets — spot fine, spot dry, spot blind,
    // top-up opted in — no on-demand ask may be the whole fleet.
    for (const scenario of [{}, { spotfail: true }, { deployed: false }, { pinned: false, spotfail: true },
      { env: { POCKETDJ_ONDEMAND_TOPUP: '1' } }]) {
      const r = reconcile({ visible: 1000, ...scenario });
      for (const l of odLaunches(r)) {
        expect(countOf(l)).not.toBe(30);
        expect(countOf(l)).toBeLessThanOrEqual(OD_CEILING);
      }
    }
  });

  it('takes 16 CHEAP and buys only the GAP — never 30 at full price', () => {
    // The saving IS this split. Sixteen workers at spot prices plus the fourteen the spot quota
    // cannot hold beats both "30 on-demand" (the bug: ~$3/hr against ~$0.64) and "the queue stalls
    // at 16" (the over-correction) — and the fourteen are metered, so they cannot become permanent
    // silently.
    const r = reconcile({ deployed: true, visible: 1000 });
    expect(total(spotLaunches(r))).toBe(SPOT_CEILING);
    const od = odLaunches(r);
    expect(od).toHaveLength(1);
    expect(countOf(od[0])).toBe(30 - SPOT_CEILING);
    expect(r.out).toMatch(/ceiling/i);          // …and the 16/30 is explained rather than mysterious
  });

  it('sizes to a SMALL backlog and pays nothing for it', () => {
    // 6 messages = 3 workers, comfortably inside the spot ceiling.
    const r = reconcile({ deployed: true, visible: 6 });
    expect(odLaunches(r)).toHaveLength(0);
    for (const l of r.launches) expect(countOf(l)).toBeLessThanOrEqual(3);
  });

  it('stays inside the SPOT bucket across a whole pass, even when it walks four AZs', () => {
    // Each AZ attempt is its own run-instances, so a walk must not ask for 16 four times over. The
    // launcher tracks what is still MISSING, not what it originally wanted.
    const attempts = spotLaunches(reconcile({ deployed: true, pinned: false, spotfail: true, visible: 1000 }));
    expect(attempts.length).toBeGreaterThan(1);
    for (const l of attempts) expect(countOf(l)).toBeLessThanOrEqual(SPOT_CEILING);
  });

  it('launches nothing at all on an empty queue', () => {
    expect(reconcile({ deployed: true, visible: 0 }).launches).toHaveLength(0);
  });

  it('honours a raised spot quota without a code change', () => {
    // The knob to re-read after a quota increase. A stale cap is a silent throughput ceiling, so it
    // has to be an env var and it has to actually move the ask.
    const r = reconcile({ deployed: true, visible: 1000, env: { POCKETDJ_SPOT_VCPU_CAP: '60' } });
    expect(total(spotLaunches(r))).toBe(30);      // the lane cap now binds, not the quota
    expect(odLaunches(r)).toHaveLength(0);
  });
});

describe('AZ FAN-OUT is wired — four pools, and the right call for the template it finds', () => {
  it('does NOT name a subnet while the live template still pins one', () => {
    // `RunInstances` rejects --subnet-id when the template defines a NetworkInterfaces block, and
    // every live version of pocketdj-stem-worker does. That refusal is InvalidParameterCombination:
    // 100% of launches, every AZ, immediately — and it is in neither the next-AZ set nor the
    // on-demand fallback set, so nothing recovers from it. Staying single-AZ costs only the fan-out.
    const r = reconcile({ deployed: true, pinned: true, spotfail: true, visible: 1000 });
    expect(r.launches.length).toBeGreaterThan(0);
    for (const l of r.launches) expect(l).not.toContain('--subnet-id');
  });

  it('walks EVERY AZ before giving up, once the template has been restructured', () => {
    // The single-pool exposure, removed. Four distinct subnets attempted in one pass proves the walk
    // is real and not just a different pinned AZ.
    const tried = spotLaunches(reconcile({ deployed: true, pinned: false, spotfail: true, visible: 1000 }))
      .map(subnetOf).filter(Boolean);
    expect(new Set(tried).size).toBe(4);
    expect(new Set(tried)).toEqual(new Set(SUBNETS));
  });

  it('rotates which AZ LEADS from one tick to the next', () => {
    // The cursor is persisted, because the process does not survive to remember it. A fixed lead
    // concentrates the fleet in one pool, which is how a single reclaim wave takes out every worker.
    const r = reconcile({ passes: 2, deployed: true, pinned: false, spotfail: true, visible: 1000 });
    const leads = spotLaunches(r).map(subnetOf);
    expect(leads[0]).not.toBe(leads[4]);        // first attempt of pass 1 vs first attempt of pass 2
    expect(r.state().azCursor).toBeGreaterThan(0);
  });

  it('only ever names subnets that exist in the default VPC', () => {
    const r = reconcile({ deployed: true, pinned: false, spotfail: true, visible: 1000 });
    for (const s of r.launches.map(subnetOf).filter(Boolean)) expect(SUBNETS).toContain(s);
  });

  it('honours POCKETDJ_STEM_SUBNETS — an operator can pin the walk to one AZ', () => {
    // The knob for reproducing a capacity report, or for staying out of an AZ having a bad day.
    const tried = spotLaunches(reconcile({
      deployed: true, pinned: false, spotfail: true, visible: 1000,
      env: { POCKETDJ_STEM_SUBNETS: `us-west-2c:${SUBNETS[2]}` },
    })).map(subnetOf);
    expect(tried.length).toBeGreaterThan(0);
    expect(new Set(tried)).toEqual(new Set([SUBNETS[2]]));
  });

  it('STOPS at the first AZ on a non-capacity refusal — one error, not four', () => {
    // An IAM denial fails identically in every AZ and identically on-demand. Fanning out is a storm;
    // paying is money spent on a config nobody has noticed is broken.
    const r = reconcile({ deployed: true, pinned: false, denied: true, visible: 1000 });
    expect(spotLaunches(r)).toHaveLength(1);
    expect(odLaunches(r)).toHaveLength(0);
  });

  it('degrades to the template\'s own AZ when the template cannot be read at all', () => {
    // A describe that fails must cost the SPREAD, not the launch: guessing an override shape for a
    // template you cannot see is how --subnet-id reaches a NetworkInterfaces block and fails 100% of
    // launches. Degrade, never break — and say why.
    const r = reconcile({ deployed: true, visible: 6, notpl: true });
    expect(r.launches.length).toBeGreaterThan(0);
    for (const l of r.launches) expect(subnetOf(l)).toBeNull();
    expect(r.out).toMatch(/cannot read launch template/i);
  });

  it('caches the template shape too — it changes about as often as the worker code', () => {
    const r = reconcile({ passes: 3, deployed: true, pinned: false, spotfail: true, visible: 1000 });
    expect(r.calls.filter((l) => l.startsWith('ec2 describe-launch-template-versions'))).toHaveLength(1);
  });
});

describe('FALLBACK BUDGET is wired — a capacity outage costs a bounded amount', () => {
  it('does pay at first — the brake must not be a block', () => {
    // A dry market has to keep the queue draining, or a cost guard becomes an availability bug.
    const r = reconcile({ deployed: true, spotfail: true, visible: 1000 });
    expect(odLaunches(r).length).toBeGreaterThan(0);
    expect(r.out).toMatch(/on-demand/i);
  });

  it('the fallback covers the SHORTFALL, never the original request', () => {
    // Old behaviour: spot refused → retry the WHOLE ask on-demand, because a capacity or quota
    // refusal is all-or-nothing. The fix is that the RESCUE is sized from what spot failed to
    // deliver, so it is measured here by DIFFERENCE: a healthy pass buys the planned shortfall
    // (30 - 16 = 14), and a totally dry pass buys that plus at most the 16 spot could not supply.
    const healthy = total(odLaunches(reconcile({ deployed: true, visible: 1000 })));
    const dry = total(odLaunches(reconcile({ deployed: true, spotfail: true, visible: 1000 })));
    expect(healthy).toBe(30 - SPOT_CEILING);
    expect(dry - healthy).toBeLessThanOrEqual(SPOT_CEILING);   // the rescue, on its own
    expect(dry).toBeLessThanOrEqual(OD_CEILING);               // and the pair still fits the bucket
    expect(dry).toBeLessThan(30);                              // …and is never the whole fleet
  });

  it('the CEILING stops it, across separate processes', () => {
    // Ten reconciles into a total spot outage. Each is a fresh `node` that exits in about a second,
    // so the only thing that can hold the meter is the state file — an in-memory counter would permit
    // ten "first" fallbacks, which is precisely the storm this exists to stop. Cooldown 0 isolates
    // the ceiling from the burst brake.
    const r = reconcile({
      passes: 10, deployed: true, spotfail: true, visible: 1000,
      env: { ...GUARD, POCKETDJ_STEM_FALLBACK_MAX: '3', POCKETDJ_FALLBACK_BUDGET: '42' },
    });
    // Three PAID passes out of ten, whichever unit the meter counts in.
    expect(odLaunches(r).length).toBeGreaterThan(0);
    expect(odLaunches(r).length).toBeLessThanOrEqual(3);
  });

  it('the COOLDOWN stops a burst even with the ceiling wide open', () => {
    // Ten passes inside a couple of seconds against a 10-minute cooldown: exactly one may pay. The
    // two brakes are independent, so neither can be hiding the other's absence.
    const r = reconcile({
      passes: 10, deployed: true, spotfail: true, visible: 1000,
      env: { POCKETDJ_STEM_FALLBACK_MAX: '999', POCKETDJ_FALLBACK_BUDGET: '9999',
        POCKETDJ_STEM_FALLBACK_COOLDOWN_S: '600' },
    });
    expect(odLaunches(r)).toHaveLength(1);
  });

  it('a ceiling of ZERO is a hard brake, not "unlimited"', () => {
    // Reading 0 as permissive is how a config meant as a brake becomes an accelerator.
    const r = reconcile({
      passes: 3, deployed: true, spotfail: true, visible: 1000,
      env: { ...GUARD, POCKETDJ_STEM_FALLBACK_MAX: '0', POCKETDJ_FALLBACK_BUDGET: '0' },
    });
    expect(odLaunches(r)).toHaveLength(0);
  });

  it('SHOUTS when it withholds, naming the override', () => {
    // The missing alarm, at the only place that can raise one. A silent brake is a fleet that
    // mysteriously stops keeping up with its queue and nobody can say why.
    const r = reconcile({
      passes: 4, deployed: true, spotfail: true, visible: 1000,
      env: { ...GUARD, POCKETDJ_STEM_FALLBACK_MAX: '1', POCKETDJ_FALLBACK_BUDGET: '1' },
    });
    expect(r.out).toMatch(/WITHHELD|BUDGET SPENT/i);
    expect(r.out).toMatch(/POCKETDJ_\w*FALLBACK_\w+/);
  });

  it('keeps asking for SPOT while the guard is engaged — the brake is on price, not on work', () => {
    // Refusing to pay must not stop trying spot: the pool may recover at any minute, and a guard that
    // stopped launching altogether would turn a cost problem into a pipeline outage.
    const r = reconcile({
      passes: 4, deployed: true, spotfail: true, visible: 1000,
      env: { POCKETDJ_STEM_FALLBACK_MAX: '1', POCKETDJ_FALLBACK_BUDGET: '1' },
    });
    expect(spotLaunches(r).length).toBeGreaterThanOrEqual(4);
  });

  it('a PREFLIGHT HOLD still drains the queue — it is a safety hold, not a market condition', () => {
    // The fix for a spot-blind deploy is one command, so the hold must not also stall the pipeline:
    // it is a full-price fleet, loudly, until someone runs the deploy. (Whether the guard should
    // meter those launches is a live question — the guard's own comment says it should not, while
    // the code meters on the lane's CONFIGURED market, which is still `spot` during a hold. This
    // asserts only the part both readings agree on.)
    const r = reconcile({ passes: 3, deployed: false, visible: 1000 });
    expect(odLaunches(r).length).toBeGreaterThan(0);
    expect(spotLaunches(r)).toHaveLength(0);
    expect(r.out).toMatch(/SPOT HELD/i);
  });

  it('persists the meter as a small JSON file, one per lane', () => {
    const r = reconcile({ deployed: true, spotfail: true, visible: 1000 });
    const raw = readFileSync(r.stateFile, 'utf8');
    expect(() => JSON.parse(raw)).not.toThrow();
    expect(raw.length).toBeLessThan(8_000);       // read and rewritten every 60 s, for ever
    const f = JSON.parse(raw).fallback;
    expect(f).toBeTruthy();
    expect(Number(f.count ?? f.instances)).toBeGreaterThan(0);
  });

  it('survives a CORRUPT state file instead of wedging every future tick', () => {
    // A truncated write (the box lost power mid-tick) must not make every reconcile throw before it
    // reaches the queue. Failing open is right here and only here: a damaged meter is not evidence of
    // a storm, and refusing to launch would stall the pipeline over one bad byte.
    for (const junk of ['', '   ', '{"fallback":', 'not json', '[1,2', '{"fallback":null}']) {
      const home = mkdtempSync(join(DIR, 'corrupt-'));
      const ctl = join(home, 'ctl'); mkdirSync(ctl, { recursive: true });
      writeFileSync(join(ctl, 'deployed'), ''); writeFileSync(join(ctl, 'pinned'), '');
      const stateDir = join(home, 'state'); mkdirSync(stateDir, { recursive: true });
      writeFileSync(join(stateDir, 'stem.json'), junk);
      const awsLog = join(home, 'aws.log'); writeFileSync(awsLog, '');
      const run = spawnSync(process.execPath, [AUTOSCALER], {
        encoding: 'utf8', timeout: 60_000,
        env: {
          ...process.env, PATH: `${join(DIR, 'bin')}:${process.env.PATH}`, AWS_PROFILE: '',
          AWS_REGION: 'us-west-2', AWSLOG: awsLog, STATE: ctl, VISIBLE: '1000',
          POCKETDJ_AUTOSCALER_STATE_DIR: stateDir,
        },
      });
      expect(run.status).toBe(0);
      expect(readFileSync(awsLog, 'utf8')).toContain('run-instances');
    }
  });

  it('a state dir it cannot write does not take the pipeline down', () => {
    // Worst case is losing the meter for a tick and re-verifying the preflight — both fail toward
    // "be careful". Throwing would stop the queue over a permissions problem.
    const r = reconcile({ deployed: true, visible: 6, env: { POCKETDJ_AUTOSCALER_STATE_DIR: '/proc/nope/state' } });
    expect(r.runs[0].status).toBe(0);
    expect(r.launches.length).toBeGreaterThan(0);
  });
});

describe('the reconcile still does its old job', () => {
  it('--status changes nothing', () => {
    // The dry run is what an operator reaches for mid-incident. It must never launch.
    expect(reconcile({ deployed: true, visible: 1000, args: ['--status'] }).launches).toHaveLength(0);
  });

  it('--status reports the three things reconcile otherwise decides silently', () => {
    // The fallback meter, the preflight verdict, and the AZ order the next launch would walk — the
    // facts that were previously discoverable only by grepping a log or reading an invoice.
    const out = reconcile({ deployed: true, visible: 1000, args: ['--status'] }).out;
    expect(out).toMatch(/fallback: \d+\/\d+/);
    expect(out).toMatch(/worker-code:/);
    expect(out).toMatch(/AZ order:/);
  });

  it('--status tells the truth about a spot-blind deploy', () => {
    expect(reconcile({ deployed: false, visible: 1000, args: ['--status'] }).out).toMatch(/NOT spot-aware/);
  });

  it('reports the market that actually WON, not the one it asked for', () => {
    // A run of silent on-demand launches is the only warning that spot has dried up; the log line has
    // to distinguish them or the fallback stays invisible even with the meter in place.
    expect(reconcile({ deployed: true, spotfail: true, visible: 1000 }).out).toMatch(/launched \d+ on on-demand/);
    expect(reconcile({ deployed: true, visible: 6 }).out).toMatch(/launched \d+ on spot/);
  });

  it('the TIMBRE lane is untouched — on-demand, no AZ spread, no preflight', () => {
    // The spot work must not have leaked into the lane that deliberately stays on-demand: one timbre
    // message is a ~50-song batch, and every interruption spends one of its three deliveries.
    const r = reconcile({ deployed: false, visible: 1000, args: ['--lane', 'timbre'] });
    expect(r.launches.length).toBeGreaterThan(0);
    expect(spotLaunches(r)).toHaveLength(0);
    for (const l of r.launches) expect(subnetOf(l)).toBeNull();
    expect(r.calls.filter((l) => l.startsWith('s3api head-object'))).toHaveLength(0);   // no preflight needed
  });

  it('a mistyped market still refuses the pass before it can launch anything', () => {
    const r = reconcile({ deployed: true, visible: 1000, env: { POCKETDJ_STEM_MARKET: 'Spot ' } });
    expect(r.runs[0].status).toBe(2);
    expect(r.launches).toHaveLength(0);
  });

  it('counts BOTH lanes\' fleets — the cross-lane vCPU guard is still in the loop', () => {
    // The guard predates all of this and must survive it: a reconcile that looked only at its own
    // lane would ask for capacity the other lane already spent.
    const r = reconcile({ deployed: true, visible: 1000 });
    expect(r.calls.some((l) => l.includes('describe-instances') && l.includes('pocketdj-stem-worker'))).toBe(true);
    expect(r.calls.some((l) => l.includes('describe-instances') && l.includes('pocketdj-timbre-worker'))).toBe(true);
  });
});
