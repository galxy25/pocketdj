// SPOT reclaim, WIRING — does `--serve` actually notice the notice?
//
// Every other spot test in this suite exercises a PURE function (parseSpotInterruption,
// releasePlan, stemsFromListing, shouldFallbackToOnDemand). All of them passed while the runtime
// path was dead: `armSpotWatch()` armed a `setInterval`, and `serve()`'s idle loop then starved it.
// `poll()` returns `[]` from `if (!msg) return []` without ever awaiting real I/O, so `await poll()`
// resolved as a MICROTASK; Node drains the microtask queue completely before advancing to the
// timers phase, so on an idle worker the interval NEVER FIRED. Measured on the pre-fix code:
// 0 IMDS polls in a 20 s idle serve at a 2 s interval. `spotNotice` stayed null, the "take nothing
// new" guard in poll() never tripped, and the worker kept CLAIMING FRESH JOBS for the whole
// ~2-minute reclaim window — the one behaviour the notice exists to prevent.
//
// A pure-function test cannot catch that, by construction. So this one runs the real script with
// `aws` and `curl` shimmed onto PATH and asserts on what the process actually did.
//
// TWO RUNS, SHARED. Each run is a real ~2-6 s process, so they happen once in beforeAll and every
// assertion reads the captured logs. IDLE_RECLAIM: empty queue, notice at 1.5 s, idle-exit at 12 s
// — the fixed worker retires in ~2 s, the starved one ran the full 12 s. HELD_RECLAIM: one job in
// flight behind a sleeping stand-in for Demucs, notice at 2 s, mid-separation.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, chmodSync, mkdirSync, readFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const WORKER = join(REPO, 'scripts', 'stem-worker.mjs');
const IDLE_SECONDS = 12;

let DIR;
const sh = (p, body) => { writeFileSync(p, body); chmodSync(p, 0o755); };

/// Run the real `stem-worker.mjs --serve` against the shims and return what it did.
///
/// The reclaim notice is armed by a DETACHED `sh`, never by a timer here: `execFileSync` blocks
/// this process's event loop for the whole run, so a `setTimeout` in the test would not fire until
/// the worker had already exited — the notice would never land and every assertion would read a
/// clean idle-exit as a pass. (That is not hypothetical; it is what the first draft of this file
/// did.) A separate process has its own clock and is immune.
function run({ reclaimAfterMs, oneJob = false, pollMs = 250 }) {
  const state = join(DIR, 'state');
  rmSync(state, { recursive: true, force: true }); mkdirSync(state, { recursive: true });
  const awsLog = join(DIR, 'aws.log'); const imdsLog = join(DIR, 'imds.log');
  writeFileSync(awsLog, ''); writeFileSync(imdsLog, '');

  const arm = spawn('sh', ['-c', `sleep ${reclaimAfterMs / 1000}; : > "${join(state, 'reclaim')}"`],
    { detached: true, stdio: 'ignore' });
  arm.unref();

  const t0 = Date.now();
  let stdout = '';
  try {
    stdout = execFileSync(process.execPath, [WORKER, '--serve'], {
      encoding: 'utf8', timeout: 90_000, stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        PATH: `${join(DIR, 'bin')}:${process.env.PATH}`,
        STATE: state, AWSLOG: awsLog, IMDSLOG: imdsLog,
        ...(oneJob ? { SERVE_ONE_JOB: '1' } : {}),
        POCKETDJ_STEM_VENV: join(DIR, 'venv'),
        POCKETDJ_STEM_PY: join(DIR, 'separate-one.py'),
        POCKETDJ_STEM_SPOT_POLL_MS: String(pollMs),
        POCKETDJ_STEM_IDLE_SECONDS: String(IDLE_SECONDS),
      },
    });
  } finally { try { process.kill(-arm.pid); } catch { /* already gone */ } }
  return {
    ms: Date.now() - t0, stdout,
    aws: readFileSync(awsLog, 'utf8').split('\n').filter(Boolean),
    imds: readFileSync(imdsLog, 'utf8').split('\n').filter(Boolean),
  };
}

let IDLE_RECLAIM;
let HELD_RECLAIM;

beforeAll(() => {
  DIR = mkdtempSync(join(tmpdir(), 'stem-spot-serve-'));
  mkdirSync(join(DIR, 'bin'), { recursive: true });
  mkdirSync(join(DIR, 'venv', 'bin'), { recursive: true });

  // `aws` shim. Hands out ONE job when SERVE_ONE_JOB is set, then answers empty forever. The
  // `sleep 1` on receive stands in for the 20 s SQS long poll — without it the idle loop spins far
  // faster than production and the "stopped receiving" assertion would measure nothing real.
  sh(join(DIR, 'bin', 'aws'), `#!/bin/bash
echo "$*" >> "$AWSLOG"
case "$1 $2" in
"sqs receive-message")
  if [ -n "$SERVE_ONE_JOB" ] && [ ! -f "$STATE/received" ]; then touch "$STATE/received"
    echo '{"Messages":[{"ReceiptHandle":"RH-TEST-1","Body":"{\\"songId\\":\\"sng_3be2079ad5e3\\",\\"srcKey\\":\\"rips/sng_3be2079ad5e3.mp3\\",\\"tasks\\":[\\"stems\\"],\\"dedup\\":false}"}]}'
  else sleep 1; echo '{}'; fi ;;
"s3 ls") exit 1 ;;
"s3 cp") for a in "$@"; do case "$a" in /*) : > "$a";; esac; done ;;
esac
exit 0
`);

  // `curl` shim = IMDS. The PUT token always succeeds (we are pretending to be on EC2); the
  // instance-action GET returns the real 404 body until $STATE/reclaim exists, then the notice.
  sh(join(DIR, 'bin', 'curl'), `#!/bin/bash
for a in "$@"; do case "$a" in */latest/api/token) echo "TOKEN-OK"; exit 0;; esac; done
echo "imds" >> "$IMDSLOG"
if [ -f "$STATE/reclaim" ]; then echo '{"action":"terminate","time":"2026-09-06T12:34:56Z"}'
else echo '<html><head><title>404 - Not Found</title></head></html>'; fi
exit 0
`);

  // Stand-in for demucs: sleeps long enough that the reclaim lands mid-separation.
  sh(join(DIR, 'venv', 'bin', 'python'), `#!/bin/bash
sleep 10
echo '{"ok":true,"model":"htdemucs","stems":{"vocals":"vocals.mp3","drums":"drums.mp3","bass":"bass.mp3","other":"other.mp3"}}'
`);
  writeFileSync(join(DIR, 'separate-one.py'), '# stub\n');

  IDLE_RECLAIM = run({ reclaimAfterMs: 1_500 });
  HELD_RECLAIM = run({ reclaimAfterMs: 2_000, oneJob: true });
}, 120_000);

afterAll(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

describe('serve() actually polls IMDS — the idle loop must not starve the timer', () => {
  it('polls IMDS AT ALL while the queue is EMPTY', () => {
    // THE REGRESSION, and zero is the whole point: pre-fix this was EXACTLY 0 for a 20 s idle
    // serve at a 2 s interval, because `await poll()` on an empty queue resolves as a microtask
    // and the event loop never reached the timers phase. So `> 0` is the exact discriminator.
    // Deliberately NOT `> 1`: on a loaded machine the worker can take longer to boot than the
    // 1.5 s arming sleep, in which case the very FIRST poll already sees the notice and there is
    // legitimately only one. That flaked in a full-suite run; the count is not the property here,
    // the timer having run at all is.
    expect(IDLE_RECLAIM.imds.length).toBeGreaterThan(0);
  });

  it('retires on the notice instead of idling out — an idle worker stops taking work', () => {
    // Pre-fix the worker ran the FULL idle window and exited via "idle 12s", never seeing the
    // notice. A notice at 1.5 s against a 12 s idle-exit makes the two outcomes unconfusable.
    expect(IDLE_RECLAIM.ms).toBeLessThan(IDLE_SECONDS * 1000 * 0.6);
    expect(JSON.parse(IDLE_RECLAIM.stdout).ok).toBe(true);
  });

  it('STOPS RECEIVING once the notice lands — no job is claimed inside the reclaim window', () => {
    // The sharpest consequence of the starved timer: a worker with ~2 minutes to live kept calling
    // receive-message. Claiming a job seconds before the box dies is how a song ends up stalled for
    // the full visibility timeout with one of its three deliveries already spent. At ~1 s per
    // receive, retiring at 1.5 s means ~2 receives; the starved loop kept going for all 12 s.
    expect(IDLE_RECLAIM.aws.filter((l) => l.includes('receive-message')).length).toBeLessThan(6);
  });
});

describe('serve() releases the job it is HOLDING when the notice lands mid-Demucs', () => {
  it('re-sends the job, THEN deletes the original — that order, on that receipt handle', () => {
    // Send BEFORE delete is load-bearing: a failed delete costs a duplicate (dedup eats it), while
    // a failed send after a delete loses the job outright.
    const send = HELD_RECLAIM.aws.findIndex((l) => l.includes('sqs send-message') && l.includes('stem-jobs'));
    const del = HELD_RECLAIM.aws.findIndex((l) => l.includes('sqs delete-message'));
    expect(send).toBeGreaterThanOrEqual(0);
    expect(del).toBeGreaterThan(send);
    expect(HELD_RECLAIM.aws[del]).toContain('RH-TEST-1');
  });

  it('carries the whole job body across, with the hop counter set', () => {
    const send = HELD_RECLAIM.aws.find((l) => l.includes('sqs send-message') && l.includes('stem-jobs'));
    const body = JSON.parse(send.match(/--message-body (\{.*\}) --region/)[1]);
    expect(body).toMatchObject({
      songId: 'sng_3be2079ad5e3', srcKey: 'rips/sng_3be2079ad5e3.mp3', dedup: false, spotRequeues: 1,
    });
  });

  it('never posts a RESULT for the separation it abandoned', () => {
    // The stand-in python sleeps 10 s and the notice lands at 2 s, so the job cannot have finished.
    // A result here would mean the worker stamped a song whose stems were never uploaded.
    expect(HELD_RECLAIM.aws.some((l) => l.includes('stem-results'))).toBe(false);
  });

  it('exits promptly rather than waiting out the separation it can no longer finish', () => {
    expect(HELD_RECLAIM.ms).toBeLessThan(8_000);   // python sleeps 10 s; the notice lands at 2 s
  });
});
