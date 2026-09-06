// ARMING the spot reclaim watch — the once-per-instance decision that has no second chance.
//
// `tests/unit/stem-spot-serve-loop.test.mjs` proves the loop reaches the timers phase and that the
// release fires. Both of those assume the watch got ARMED. This file pins the step before them.
//
// Arming happens in the first second of `--serve`, from one IMDSv2 token fetch bounded at
// `--connect-timeout 1 --max-time 2`. It used to be a single attempt: miss it, and `spotTimer` was
// never created, so the entire interruption path was dead for the whole life of that worker —
// every reclaim stranding its job for the full 1800 s visibility timeout and spending one of the
// queue's three deliveries, while the log said "not an EC2 instance" on an EC2 instance. IMDS
// answers 503 when it rate-limits and cloud-init can beat the network up, so one miss is a normal
// Tuesday, not a black swan. The retry costs ~2 s of startup and only ever on a box with no IMDS.
//
// The other half matters just as much: a laptop or CI box has NO IMDS, and must stand down rather
// than fork a curl at the link-local black hole every few seconds for the life of the process.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const WORKER = join(REPO, 'scripts', 'stem-worker.mjs');

let DIR;
const sh = (p, body) => { writeFileSync(p, body); chmodSync(p, 0o755); };

beforeAll(() => {
  DIR = mkdtempSync(join(tmpdir(), 'stem-spot-arm-'));
  mkdirSync(join(DIR, 'bin'), { recursive: true });

  // `curl` shim = IMDS. $TOKENFAIL holds a countdown of token fetches that fail (curl exit 7,
  // "couldn't connect" — what a rate-limited or not-yet-routable IMDS looks like to `curl -sf`).
  sh(join(DIR, 'bin', 'curl'), `#!/bin/bash
for a in "$@"; do case "$a" in */latest/api/token)
  if [ -f "$TOKENFAIL" ]; then n=$(cat "$TOKENFAIL")
    if [ "$n" -gt 0 ]; then echo $((n-1)) > "$TOKENFAIL"; exit 7; fi
  fi
  echo "TOKEN-OK"; exit 0;; esac; done
echo '<html><head><title>404 - Not Found</title></head></html>'
exit 0
`);
  // Empty queue forever: the worker arms, polls, and retires on idle. Arming is all we measure.
  sh(join(DIR, 'bin', 'aws'), `#!/bin/bash
case "$1 $2" in "sqs receive-message") echo '{}';; esac
exit 0
`);
});
afterAll(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

/// Run `--serve` to its idle exit and return everything it logged. `tokenFails` is how many IMDS
/// token fetches fail before one succeeds; 999 stands in for "there is no IMDS here at all".
function serve(tokenFails) {
  const tf = join(DIR, 'tokenfail');
  writeFileSync(tf, String(tokenFails));
  // spawnSync, not execFileSync: the worker logs to STDERR and exits 0, and execFileSync only
  // surfaces stderr on the throw — so a healthy run handed the assertions an empty string and
  // "armed" and "not armed" became indistinguishable. spawnSync returns both streams either way.
  const r = spawnSync(process.execPath, [WORKER, '--serve'], {
    encoding: 'utf8', timeout: 60_000,
    env: {
      ...process.env,
      PATH: `${join(DIR, 'bin')}:${process.env.PATH}`,
      TOKENFAIL: tf,
      POCKETDJ_STEM_IDLE_SECONDS: '1',       // retire at once; this test is about startup
      POCKETDJ_STEM_SPOT_POLL_MS: '250',
    },
  });
  return `${r.stderr || ''}`;
}

describe('armSpotWatch — a transient IMDS miss must not disable the watch for good', () => {
  it('arms immediately when IMDS is healthy', () => {
    expect(serve(0)).toMatch(/spot-interruption watch armed/);
  }, 30_000);

  it('RETRIES past a transient failure and still arms', () => {
    // Two failed token fetches then success — the shape of an IMDS 503 at boot. Pre-fix this
    // printed "spot watch off (not an EC2 instance)" and left every later reclaim unhandled.
    const err = serve(2);
    expect(err).toMatch(/spot-interruption watch armed/);
    expect(err).not.toMatch(/spot watch off/);
  }, 30_000);

  it('stands down after a BOUNDED number of tries when there is genuinely no IMDS', () => {
    // The other direction matters too: a laptop or CI box must not retry forever at startup, nor
    // leave a timer forking curl at 169.254.169.254 for the life of the process.
    const err = serve(999);
    expect(err).toMatch(/no IMDS after 3 tries/);
    expect(err).not.toMatch(/watch armed/);
  }, 30_000);
});
