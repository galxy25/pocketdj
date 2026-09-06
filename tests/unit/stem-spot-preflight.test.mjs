// THE ROLLOUT RACE — one definition of "spot-aware", agreed by four files that never call each other.
//
// Workers do NOT run this repo's `scripts/stem-worker.mjs`. The launch template's userdata copies it
// from `s3://pocketdj-rips-011183829623/worker-code/` on every boot, and that object was dated
// 2026-07-19 and contained ZERO mentions of `instance-action` — a month behind the tree, and
// completely spot-blind.
//
// The race that creates: the autoscaler runs FROM THE REPO via a 60 s LaunchAgent, so merging this
// branch flips the fleet to spot on the next tick, while every worker booting after that tick is
// still spot-blind. Each reclaim then strands its job for the full 1800 s visibility timeout AND
// spends one of the queue's three deliveries; three unlucky reclaims dead-letter a song that never
// failed, and rip-server's `pumpStemDlq()` marks it errored permanently. Songs that were never
// broken end up marked broken, and the only trace is a DLQ nobody is watching.
//
// A checklist cannot close that — "deploy the worker first" is a step someone forgets at 2am, or
// that a `git merge` performs on their behalf. So it is closed in code, by four files agreeing on
// one string:
//
//   scripts/stem-worker.mjs          CONTAINS the marker (it is the code that handles a reclaim)
//   scripts/stem-deploy-worker.sh    REFUSES to deploy a worker without it, and re-checks the bytes
//                                    it read back from S3
//   scripts/stem-autoscaler.mjs      REFUSES to request spot until the DEPLOYED object contains it
//   scripts/stem-worker-userdata.sh  is why "deployed" means that S3 prefix and not the repo
//
// EVERY LINK FAILS SILENTLY AND SAFELY. Rename the function the marker points at and the deploy
// script quietly refuses forever; point the autoscaler at the wrong key and the fleet quietly stays
// on-demand at 2.7×. Nobody gets an error — the discount just never arrives, and a month later
// someone reads an invoice. That is exactly why the agreement is asserted here rather than trusted:
// a silent, safe failure is the kind no runtime test will ever fail on.
//
// THE STAMP, and why it is metadata rather than the bytes. `stem-deploy-worker.sh` writes
// `x-amz-meta-spot-aware: yes` — but only AFTER it has read the uploaded bytes back and confirmed
// they carry the marker. A plain PUT clears user metadata, so the old habit this replaces (a
// hand-run `aws s3 cp`) leaves the object UNSTAMPED even when its body is fine. That is the stamp
// under-claiming, which is the safe direction; it may never over-claim. And a HEAD is a few hundred
// bytes against a whole worker download, which matters on a 60 s cadence.
//
// The CACHING and the fail-safe-on-unreadable behaviour live in `spotGate`, which is module-private
// and talks to S3, so they are driven end-to-end against the real script in
// tests/unit/stem-spot-reconcile-wiring.test.mjs.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeployedWorkerSpotAware, effectiveMarket } from '../../scripts/stem-autoscaler.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(REPO, p), 'utf8');

// The IMDS path a spot worker must poll: the string the deploy script refuses to ship without.
const MARKER = 'spot/instance-action';
const WORKER_CODE_PREFIX = 's3://pocketdj-rips-011183829623/worker-code';

// `aws s3api head-object --bucket pocketdj-rips-011183829623 --key worker-code/stem-worker.mjs`, as
// it answered before this branch: a real object, a month old, with no user metadata at all.
const HEAD_UNSTAMPED = {
  AcceptRanges: 'bytes',
  LastModified: '2026-07-19T04:11:33+00:00',
  ContentLength: 24_918,
  ETag: '"5f0c8b2e6a1d4f37c9b0e2a1d4f37c9b"',
  ContentType: 'text/javascript',
  Metadata: {},
};
// What the object looks like after `bash scripts/stem-deploy-worker.sh` verifies and stamps it.
const HEAD_STAMPED = {
  ...HEAD_UNSTAMPED,
  LastModified: '2026-09-06T10:02:11+00:00',
  ContentLength: 32_400,
  Metadata: { 'spot-aware': 'yes', sha256: 'b3d1'.repeat(16), 'deployed-at': '2026-09-06T10:02:11Z' },
};

describe('isDeployedWorkerSpotAware — proof, not optimism', () => {
  it('says NO to the object that was actually deployed — the whole reason this exists', () => {
    expect(isDeployedWorkerSpotAware(HEAD_UNSTAMPED)).toBe(false);
  });

  it('says YES once a verified deploy has stamped it', () => {
    expect(isDeployedWorkerSpotAware(HEAD_STAMPED)).toBe(true);
  });

  it('says NO when the HEAD itself failed — an unknown is not a yes', () => {
    // A 404 (nothing deployed), an AccessDenied, a network blip: `s3api head-object` throws and the
    // caller has nothing to hand over. Defaulting to "probably fine" here is how the race stays open
    // on exactly the day S3 is having a bad morning.
    for (const head of [undefined, null, '', 0, false]) {
      expect(() => isDeployedWorkerSpotAware(head)).not.toThrow();
      expect(isDeployedWorkerSpotAware(head)).toBe(false);
    }
  });

  it('says NO to every near-miss stamp', () => {
    // The stamp's vocabulary is exactly what stem-deploy-worker.sh writes and reads back: the
    // literal string `yes`. Anything else is a hand-edit, a half-finished migration, or another
    // tool's metadata — none of which is a verified deploy vouching for the bytes.
    for (const v of ['', 'no', 'false', '0', '1', 'true', 'YES', 'Yes', ' yes', 'yes ', 'ye']) {
      expect(isDeployedWorkerSpotAware({ ...HEAD_UNSTAMPED, Metadata: { 'spot-aware': v } })).toBe(false);
    }
  });

  it('says NO when Metadata is missing or is not an object', () => {
    for (const Metadata of [undefined, null, 'yes', 7]) {
      const head = { ...HEAD_UNSTAMPED, Metadata };
      expect(() => isDeployedWorkerSpotAware(head)).not.toThrow();
      expect(isDeployedWorkerSpotAware(head)).toBe(false);
    }
  });

  it('does not accept a RECENT date, or a plausible SIZE, as a substitute for the stamp', () => {
    // The tempting shortcut — "the object is newer than the branch, so it must be fine" — is wrong
    // twice: a hand-run `aws s3 cp` from a stale checkout is recent AND spot-blind, and clock skew
    // between S3 and a laptop makes the comparison a coin flip. Circumstantial is not proof.
    expect(isDeployedWorkerSpotAware({ ...HEAD_UNSTAMPED, LastModified: new Date().toISOString() })).toBe(false);
    expect(isDeployedWorkerSpotAware({ ...HEAD_UNSTAMPED, ContentLength: 32_400 })).toBe(false);
  });

  it('returns a real boolean, not a truthy metadata value', () => {
    // The verdict is cached to a JSON file and compared later. A leaked string would survive the
    // round trip and read as "still fine" wherever the comparison is written as truthiness.
    expect(isDeployedWorkerSpotAware(HEAD_STAMPED)).toStrictEqual(true);
    expect(isDeployedWorkerSpotAware(HEAD_UNSTAMPED)).toStrictEqual(false);
  });

  it('is pure — asking twice about the same object gives the same answer', () => {
    const snapshot = JSON.stringify(HEAD_STAMPED);
    expect(isDeployedWorkerSpotAware(HEAD_STAMPED)).toBe(isDeployedWorkerSpotAware(HEAD_STAMPED));
    expect(JSON.stringify(HEAD_STAMPED)).toBe(snapshot);
  });
});

describe('effectiveMarket — fail SAFE, never fail open', () => {
  it('a spot-blind deployed worker forces the lane to ON-DEMAND', () => {
    // THE RACE, closed. Merging the branch with the July object still in place must produce
    // on-demand launches, not spot ones — regardless of what LANES.stem.market says.
    expect(effectiveMarket({ market: 'spot', spotAware: isDeployedWorkerSpotAware(HEAD_UNSTAMPED) })).toBe('on-demand');
  });

  it('a spot-AWARE deployed worker permits spot — the guard is a gate, not a wall', () => {
    expect(effectiveMarket({ market: 'spot', spotAware: isDeployedWorkerSpotAware(HEAD_STAMPED) })).toBe('spot');
  });

  it('every UNKNOWN resolves to on-demand', () => {
    // undefined is what a preflight that never ran hands over, and it must read like a "no". A
    // truthiness check treating a missing value as "not checked yet, carry on" reopens the race.
    for (const spotAware of [undefined, null, false, 0, '', NaN, 'yes', 1, {}]) {
      expect(effectiveMarket({ market: 'spot', spotAware })).toBe('on-demand');
    }
  });

  it('never upgrades an on-demand lane to spot', () => {
    // POCKETDJ_STEM_MARKET=on-demand is the documented manual brake — for a capacity outage, for a
    // suspect worker build, for any reason at all. A preflight that says "the worker is fine!" must
    // not override the operator who deliberately turned spot off. Same for the timbre lane, whose
    // ~50-song batches each spend a redelivery on every interruption.
    for (const spotAware of [true, false, undefined]) {
      expect(effectiveMarket({ market: 'on-demand', spotAware })).toBe('on-demand');
    }
  });

  it('only ever returns spot or on-demand — the caller has no third branch', () => {
    for (const market of ['spot', 'on-demand', undefined, null, 'Spot', 'nonsense']) {
      for (const spotAware of [true, false, undefined]) {
        expect(['spot', 'on-demand']).toContain(effectiveMarket({ market, spotAware }));
      }
    }
  });

  it('resolves an unrecognised market to on-demand rather than to spot', () => {
    // The module already exits(2) on a mistyped POCKETDJ_STEM_MARKET before it can launch anything,
    // so this is belt-and-braces — but the belt must point the same way as the braces.
    expect(effectiveMarket({ market: 'Spot ', spotAware: true })).toBe('on-demand');
    expect(effectiveMarket({ market: 'SPOT', spotAware: true })).toBe('on-demand');
  });
});

describe('the spot-aware marker — one string, three files', () => {
  it('the WORKER carries it: it polls IMDS for the reclaim notice', () => {
    // If this fails the marker is not a marker — it points at nothing. Everything downstream then
    // fails safe (no deploy, no spot) and the whole spot switch is inert while looking healthy.
    expect(read('scripts/stem-worker.mjs')).toContain(MARKER);
  });

  it('the DEPLOY SCRIPT gates on it, so a spot-blind worker cannot reach S3', () => {
    const deploy = read('scripts/stem-deploy-worker.sh');
    expect(deploy).toContain(MARKER);
    expect(deploy).toMatch(/Refusing to deploy/i);
  });

  it('the AUTOSCALER names it too, so the agreement is greppable from either end', () => {
    // The autoscaler gates on the STAMP, which is the deploy script's promise about these bytes.
    // Carrying the marker string here as well is what makes the chain findable: rename the handler
    // in the worker and a grep for this string turns up every file that has to change with it.
    expect(read('scripts/stem-autoscaler.mjs')).toContain(MARKER);
  });

  it('the worker\'s reclaim path is real, not just the comment that names the path', () => {
    // A marker that only ever appeared in prose would satisfy every check above while the fleet
    // stayed spot-blind. These are the actual mechanism: arm the watch, read the notice, hand the
    // in-flight job back before the box dies.
    const worker = read('scripts/stem-worker.mjs');
    for (const name of ['armSpotWatch', 'releaseInflight', 'parseSpotInterruption']) {
      expect(worker).toContain(name);
    }
  });
});

describe('what "deployed" means — the S3 prefix, never the repo', () => {
  it('userdata fetches the worker from the worker-code prefix on every boot', () => {
    // The fact that makes the whole preflight necessary: the AMI's copy is overwritten at boot by
    // whatever sits at this prefix, so the repo's opinion of the worker is worth nothing to a
    // booting instance.
    expect(read('scripts/stem-worker-userdata.sh')).toContain(WORKER_CODE_PREFIX);
  });

  it('the deploy script pushes to that same bucket and prefix', () => {
    // Asserted in pieces because the script composes them (BUCKET=… PREFIX=… B="s3://$BUCKET/$PREFIX").
    // Pushing to a DIFFERENT prefix is the silent failure this pins: the deploy reports success, the
    // autoscaler keeps reading the untouched old object, and the fleet never leaves on-demand.
    const deploy = read('scripts/stem-deploy-worker.sh');
    expect(deploy).toContain('pocketdj-rips-011183829623');
    expect(deploy).toContain('worker-code');
    expect(deploy).toContain('stem-worker.mjs');
  });

  it('the autoscaler preflights that same object — not scripts/stem-worker.mjs', () => {
    // The tempting shortcut is to check the file sitting next to the autoscaler, which is always
    // spot-aware on this branch and tells you nothing whatsoever about the fleet.
    expect(read('scripts/stem-autoscaler.mjs')).toContain(`${WORKER_CODE_PREFIX}/stem-worker.mjs`);
  });

  it('checks the object by its STAMP, and gets it from a HEAD rather than a download', () => {
    // A HEAD is a few hundred bytes; downloading a 32 KB worker every TTL to look for one string
    // would be a silly amount of traffic for a verdict that changes about once a month.
    const src = read('scripts/stem-autoscaler.mjs');
    expect(src).toMatch(/head-object/);
    expect(src).toContain('spot-aware');
  });

  it('the deploy script writes exactly the key/value the autoscaler gates on', () => {
    expect(read('scripts/stem-deploy-worker.sh')).toContain('spot-aware=yes');
    expect(isDeployedWorkerSpotAware({ Metadata: { 'spot-aware': 'yes' } })).toBe(true);
  });

  it('the stamp is EARNED, not written alongside the upload', () => {
    // The invariant that makes it trustworthy: a plain PUT clears user metadata, so the object is
    // unstamped from the moment it is uploaded until the read-back has proved it. A script that
    // stamped during the upload could vouch for bytes it never checked.
    const deploy = read('scripts/stem-deploy-worker.sh');
    expect(deploy.indexOf('cmp -s')).toBeLessThan(deploy.lastIndexOf('spot-aware=yes'));
  });
});

describe('the deploy script — the other half of the interlock', () => {
  it('verifies by reading the bytes BACK from S3, not by trusting the upload\'s exit code', () => {
    // `aws s3 cp` exiting 0 says the request was accepted, not that a booting worker will read what
    // we meant to ship: a push to the wrong prefix, or a stale object from a half-finished earlier
    // deploy, both exit 0. The read-back is what makes "deployed" mean something.
    const deploy = read('scripts/stem-deploy-worker.sh');
    expect(deploy).toContain('cmp -s');
    expect(deploy).toMatch(/verify|read-back/i);
  });

  it('offers a --check that answers "is the fleet safe for spot right now?" without deploying', () => {
    // The command to run before merging. Without it, the only way to find out is to merge and watch
    // the DLQ.
    expect(read('scripts/stem-deploy-worker.sh')).toContain('--check');
  });

  it('deploys every file the userdata actually fetches', () => {
    // A new `aws s3 cp $B/foo.py` landing in userdata while the deploy script's FILES list is
    // forgotten boots a worker that dies on a missing helper — and only on the NEXT launch, long
    // after the commit that caused it.
    const userdata = read('scripts/stem-worker-userdata.sh');
    const deploy = read('scripts/stem-deploy-worker.sh');
    const fetched = [...userdata.matchAll(/\$B\/([A-Za-z0-9._-]+)/g)].map((m) => m[1]);
    expect(fetched.length).toBeGreaterThan(0);
    for (const name of new Set(fetched)) expect(deploy).toContain(name);
  });
});
