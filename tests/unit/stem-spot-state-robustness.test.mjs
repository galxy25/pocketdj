// THE STATE FILE MUST NOT BE ABLE TO WEDGE THE AUTOSCALER.
//
// stem-autoscaler.mjs is a stateless 60 s LaunchAgent, so everything it remembers between ticks —
// the fallback meter, the preflight verdict, the cached template shape, the AZ cursor — lives in
// ~/.pocketdj/stem-autoscaler/<lane>.json. That file is therefore an INPUT the process cannot
// validate away, and the failure mode is uniquely nasty: an uncaught throw ends the pass, launchd
// restarts in 60 s, reads the SAME file, and throws again. The fleet freezes at whatever size it
// happened to be and nothing ever launches again until a human finds it. `reconcile` even writes the
// bad shape straight back from its `finally`, so it is self-sealing.
//
// `parseJson` is NOT that guard. It only catches text that will not parse; `null`, `"nope"` and `[]`
// all parse perfectly and then detonate on the first `state.x ||= {}`. This file pins the shapes.
//
// It also pins the SECOND way a cache can take the pipeline down: a stale `multi-az` verdict against
// a template that has been re-pinned by `stem-spot-setup.mjs --revert`. That combination makes the
// controller pass `--subnet-id` to a template with a NetworkInterfaces block, which the API refuses
// with InvalidParameterCombination — an error in NEITHER the next-AZ set nor the on-demand fallback
// set, so every launch fails and nothing recovers it. Left cached it is a ten-minute total scale-up
// outage in the middle of a rollback.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, chmodSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const AUTOSCALER = join(REPO, 'scripts', 'stem-autoscaler.mjs');

let DIR;

beforeAll(() => {
  DIR = mkdtempSync(join(tmpdir(), 'stem-spot-state-'));
  mkdirSync(join(DIR, 'bin'), { recursive: true });
  // The same `aws` shim idiom as stem-spot-reconcile-wiring.test.mjs, plus the ONE behaviour that
  // file has no reason to model: run-instances REFUSING `--subnet-id` against a template that still
  // carries a NetworkInterfaces block. That refusal is the whole point of the netMode cache test,
  // and its wording is the API's own.
  const p = join(DIR, 'bin', 'aws');
  writeFileSync(p, `#!/bin/bash
echo "$*" >> "$AWSLOG"
case "$1 $2" in
"sqs get-queue-attributes")
  echo '{"Attributes":{"ApproximateNumberOfMessages":"1000","ApproximateNumberOfMessagesNotVisible":"0"}}' ;;
"ec2 describe-instances") echo '[]' ;;
"ec2 describe-launch-template-versions")
  echo '{"LaunchTemplateVersions":[{"VersionNumber":4,"LaunchTemplateData":{"InstanceType":"m7i.large","NetworkInterfaces":[{"DeviceIndex":0,"SubnetId":"subnet-00a23032877bbe190","AssociatePublicIpAddress":true,"DeleteOnTermination":true,"Groups":["sg-053afe62aa1e78bf9"]}]}}]}' ;;
"s3api head-object")
  echo '{"ContentLength":32400,"ETag":"\\"aware\\"","LastModified":"2026-09-06T10:02:11+00:00","Metadata":{"spot-aware":"yes"}}' ;;
"ec2 run-instances")
  case "$*" in
    *--subnet-id*)
      echo "An error occurred (InvalidParameterCombination) when calling the RunInstances operation: Network interfaces and an instance-level subnet ID may not be specified on the same request" >&2
      exit 255 ;;
  esac
  n=$(echo "$*" | sed -n 's/.*--count 1:\\([0-9][0-9]*\\).*/\\1/p'); n=\${n:-1}
  case "$*" in *--instance-market-options*) pfx=spot ;; *) pfx=od ;; esac
  ids=""; i=0
  while [ $i -lt $n ]; do ids="$ids i-\${pfx}$(printf '%04d' $i)"; i=$((i+1)); done
  echo $ids ;;
*) echo '{}' ;;
esac
exit 0
`);
  chmodSync(p, 0o755);
});

afterAll(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

/// One reconcile PROCESS against a state dir the caller owns, so a test can seed the file first.
function pass(home, args = []) {
  const stateDir = join(home, 'state');
  const awsLog = join(home, 'aws.log');
  writeFileSync(awsLog, '');
  const r = spawnSync(process.execPath, [AUTOSCALER, ...args], {
    encoding: 'utf8',
    timeout: 60_000,
    env: {
      ...process.env,
      PATH: `${join(DIR, 'bin')}:${process.env.PATH}`,
      AWS_PROFILE: '',
      AWS_REGION: 'us-west-2',
      AWSLOG: awsLog,
      POCKETDJ_AUTOSCALER_STATE_DIR: stateDir,
    },
  });
  const calls = readFileSync(awsLog, 'utf8').split('\n').filter(Boolean);
  return {
    status: r.status,
    out: `${r.stdout || ''}${r.stderr || ''}`,
    calls,
    launches: calls.filter((l) => l.startsWith('ec2 run-instances')),
    state: JSON.parse(readFileSync(join(stateDir, 'stem.json'), 'utf8')),
  };
}

function seeded(contents) {
  const home = mkdtempSync(join(DIR, 'run-'));
  mkdirSync(join(home, 'state'), { recursive: true });
  if (contents !== undefined) writeFileSync(join(home, 'state', 'stem.json'), contents);
  return home;
}

describe('a malformed state file cannot stop the fleet from ever launching again', () => {
  // Every one of these PARSES. That is the point: the shapes that survive JSON.parse are exactly the
  // ones a `catch` around the parse cannot see, and each used to throw on a different line —
  // `readState` for the scalars, `notice()` for a non-object `notices`, `spotGate` for a truthy
  // non-object `workerCode`. A hand-edit during debugging is the realistic origin, which is to say
  // it happens when somebody is already trying to fix something else.
  const shapes = {
    'a bare null': 'null',
    'a bare string': '"wedged"',
    'an array': '[]',
    'a number': '42',
    'notices as a string': '{"notices":"x"}',
    'workerCode as a number': '{"workerCode":123}',
    'netMode as a string': '{"netMode":"multi-az"}',
    'every slot the wrong type': '{"notices":[],"workerCode":"s","netMode":7,"fallback":"s","azCursor":{}}',
    'truncated mid-write': '{"fallback":{"count":3,',
    'not JSON at all': 'GARBAGE',
    'empty': '',
  };
  for (const [name, body] of Object.entries(shapes)) {
    it(`survives ${name} — and still launches`, () => {
      const r = pass(seeded(body));
      expect(r.status).toBe(0);
      expect(r.out).not.toMatch(/TypeError|Cannot read properties|Cannot create property/);
      // Not merely "did not crash": a guard that swallowed the pass would be just as bad, because
      // the queue would stay unserved while every log line said fine.
      expect(r.launches.length).toBeGreaterThan(0);
    });
  }

  it('rewrites the bad file as a usable one, so the damage does not persist', () => {
    // The `finally` writes state back on every pass. If a bad shape survived that round-trip the
    // file would stay poisoned for ever, which is the difference between one bad tick and an
    // indefinite outage.
    const home = seeded('null');
    pass(home);
    const second = pass(home);
    expect(second.status).toBe(0);
    expect(second.state).toBeTypeOf('object');
    expect(Array.isArray(second.state)).toBe(false);
  });
});

describe('a stale multi-AZ verdict cannot outlive a --revert', () => {
  // The rollback hazard. `stem-spot-setup.mjs --revert` re-pins the template in one API call, but
  // this controller caches the template's network shape for POCKETDJ_STEM_TEMPLATE_TTL_S (600 s by
  // default) — so without invalidation it keeps naming a subnet the template no longer permits, and
  // InvalidParameterCombination is in neither error set, so nothing falls back and nothing retries.
  const stale = JSON.stringify({
    netMode: { template: 'pocketdj-stem-worker', atMs: Date.now(), mode: 'multi-az' },
    workerCode: { uri: 's3://pocketdj-rips-011183829623/worker-code/stem-worker.mjs', checkedAtMs: Date.now(), spotAware: true },
  });

  it('the first pass after the revert does fail — this is the window being bounded', () => {
    const r = pass(seeded(stale));
    expect(r.launches.some((l) => l.includes('--subnet-id'))).toBe(true);
    expect(r.out).toMatch(/InvalidParameterCombination/);
  });

  it('…and the NEXT pass re-reads the template instead of repeating it', () => {
    const home = seeded(stale);
    const first = pass(home);
    expect(first.launches.some((l) => l.includes('--subnet-id'))).toBe(true);

    const second = pass(home);
    // Re-read, not re-used: the cache was invalidated by the config-shaped failure.
    expect(second.calls.filter((l) => l.startsWith('ec2 describe-launch-template-versions')).length)
      .toBeGreaterThan(0);
    expect(second.state.netMode.mode).toBe('pinned');
    // And the recovery is real, not just a cache write: launches resume, without a subnet.
    expect(second.launches.length).toBeGreaterThan(0);
    expect(second.launches.some((l) => l.includes('--subnet-id'))).toBe(false);
    expect(second.out).not.toMatch(/InvalidParameterCombination/);
  });
});
