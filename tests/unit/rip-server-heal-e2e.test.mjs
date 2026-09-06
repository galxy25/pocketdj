// END-TO-END: does the REAL rip server actually heal a wedged Music.app?
//
// captureWithHeal is unit-tested in music-health.test.mjs. This file tests the thing that was
// missing on 2026-08-12 — the WIRING. The remedy existed as a concept ("quit and relaunch
// Music") and was reachable from no code path at all, so 6 retries × 32 minutes of waiting ran
// for 38 hours against a condition that waiting cannot fix.
//
// Boots the real scripts/rip-server.mjs with:
//   · an isolated HOME (so the LIVE daemon's ~/.pocketdj/rips queue is never touched),
//   · a private port (the live server owns 8787),
//   · a fake `aws` (scripts/test/fake-aws.mjs) and a fake `osascript` (fake-music-rig.mjs),
//   · a fake capture worker that reports the wedge signature and then, ONLY IF Music was
//     really relaunched, succeeds — so a passing retry PROVES the heal did something.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort } from './helpers/free-port.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
// ALLOCATED, not hand-picked (see helpers/free-port.mjs). A constant port is global state: a
// second run of this file — another agent in this checkout, a watch window — puts two servers
// on one number, and because rip-server does its whole startup BEFORE listen(), the loser logs
// a clean boot and only dies at the end while the winner answers our health probe with a
// byte-identical /health. The suite then drives the STRANGER and asserts on our own tmpdir.
let base;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The REAL production posture (see rip-timbre-reconcile-e2e.test.mjs, which models the same
// thing). Since the MUST-1 gate landed, authed() fails CLOSED under the default public posture:
// a tokenless public server 401s every endpoint except /health. /health sitting ahead of the gate
// is why a token-less harness still sails through the boot probe below and then fails 30s later
// on an assertion that says nothing about auth — so the tokens are load-bearing here.
const USER = 'user-token-for-the-app-tier';
const ADMIN = 'admin-token-for-the-admin-tier';
const AUTH = { authorization: `Bearer ${USER}` };

const WEDGED_ONCE = 'sng_wedged_once';   // wedged, then captures once Music is relaunched
const WEDGED_ALWAYS = 'sng_wedged_always'; // wedged on every attempt (the gate must bound it)

let work, srv, serverLog = '', srvExit = null, healFlag, rigLog, countsDir;

const rig = () => (existsSync(rigLog) ? readFileSync(rigLog, 'utf8') : '');
const countOf = (s, needle) => s.split(needle).length - 1;
const attempts = (songId) => { try { return readFileSync(join(countsDir, `${songId}.log`), 'utf8').length; } catch { return 0; } };
const getStatus = async (songId) => (await fetch(`${base}/status/${songId}`, { headers: AUTH })).json();
const postRip = async (songId) => (await fetch(`${base}/rip`, {
  method: 'POST', headers: { 'content-type': 'application/json', ...AUTH }, body: JSON.stringify({ songId }),
})).json();
// Every gate that can silently swallow a rip (401 unauthorized, MUST-5 capture-ineligible →
// `200 null`) shows up here as a missing jobId. Assert it AT THE ENQUEUE so a future gate change
// fails by name instead of as a 30s poll that ends in `expected undefined to be true`.
const expectAccepted = (r, songId) => {
  expect(r && r.jobId, `POST /rip ${songId} did not enqueue — got ${JSON.stringify(r)}\n${serverLog}`).toBeTruthy();
};

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-heal-e2e-'));
  const shimDir = join(work, 'bin');
  countsDir = join(work, 'counts');
  healFlag = join(work, 'music-relaunched.flag');
  rigLog = join(work, 'rig.log');
  mkdirSync(shimDir, { recursive: true });
  mkdirSync(countsDir, { recursive: true });
  mkdirSync(join(work, 'home'), { recursive: true });

  const shell = (p, body) => { writeFileSync(p, body); chmodSync(p, 0o755); };
  shell(join(shimDir, 'aws'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
  shell(join(shimDir, 'osascript'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-music-rig.mjs'))} "$@"\n`);
  // NON-NEGOTIABLE: `pkill` must be shimmed too. The heal escalates to `pkill -x Music` if a
  // graceful quit misses its deadline, and /usr/bin/pkill would kill the REAL Music.app that
  // the live rip daemon is capturing from. A test must never be one scripted-fake tweak away
  // from force-quitting the user's music player.
  shell(join(shimDir, 'pkill'), `#!/bin/sh\nprintf 'pkill\\t%s\\n' "$*" >> ${JSON.stringify(rigLog)}\nexit 0\n`);

  const catalog = join(work, 'digital.json');
  writeFileSync(catalog, JSON.stringify({
    // sourceName MUST be a real capture-eligible source. The MUST-5 provenance gate
    // (CAPTURE_ELIGIBLE_SOURCES = My Vinyl | My Digital) is a strict allowlist: any other name
    // makes acceptRip return 'ineligible', which /rip reports as a bare `200 null` — the rip is
    // refused with no job, no worker, and no log line. "My Digital" is the user's own uploaded
    // files, which is exactly the provenance the digital capture path here serves.
    manifest: { sourceType: 'digital', sourceName: 'My Digital' },
    albums: [{ id: 'alb_d', artist: 'Digi', name: 'D', trackList: [WEDGED_ONCE, WEDGED_ALWAYS] }],
    songs: [
      { id: WEDGED_ONCE, albumId: 'alb_d', artist: 'Digi', name: 'Wedged Once', length: 3000 },
      { id: WEDGED_ALWAYS, albumId: 'alb_d', artist: 'Digi', name: 'Wedged Always', length: 3000 },
    ],
  }));

  // Fake capture worker: reports the wedge signature. WEDGED_ONCE only succeeds once the heal
  // flag exists — i.e. only because Music.app was actually quit + relaunched.
  const worker = join(work, 'worker.mjs');
  writeFileSync(worker, `
import { writeFileSync, appendFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const SONG = a['song-id'];
appendFileSync(join(${JSON.stringify(countsDir)}, SONG + '.log'), 'x');
const relaunched = existsSync(${JSON.stringify(healFlag)});
if (SONG === ${JSON.stringify(WEDGED_ONCE)} && relaunched) {
  const key = 'rips/' + SONG + '.mp3';
  writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'uploaded', key, bytes: 4242, updatedAt: Date.now() }));
  console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes: 4242 }));
} else {
  const error = 'play accepted but Music never reached state=playing within 20000ms (last state=stopped, position=missing value) — playback engine wedged';
  writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'error', error, reason: 'play-not-started', updatedAt: Date.now() }));
  console.log('RESULT ' + JSON.stringify({ ok: false, error, reason: 'play-not-started' }));
}
`);

  const env = {
    ...process.env,
    PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: join(work, 'home'),            // isolates CFG.tmp from the LIVE daemon's queue
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    RIP_WORKER: worker,
    RIP_PUBLIC_FOLD: '0',
    // Public posture (the default, behind the Funnel) + both tiers, exactly as deployed. Without
    // these a tokenless public server fails closed and 401s /rip and /status, so the heal path
    // this file exists to pin would never be reached at all.
    RIP_TOKEN: USER,
    RIP_ADMIN_TOKEN: ADMIN,
    POCKETDJ_STEM_OFFLOAD: '0',
    POCKETDJ_AUTO_STEM_ON_RIP: '0',
    POCKETDJ_ANALYSIS_OFFLOAD: '0',
    // fake Music: pinned at stopped|missing value until `launch` writes the flag
    PDJ_FAKE_MODE: 'wedged-then-healthy',
    PDJ_FAKE_HEAL_FLAG: healFlag,
    PDJ_FAKE_LOG: rigLog,
    // The play-position counter the fake advances once Music is "healthy". It defaults to
    // $TMPDIR/pdj-fake-counter — one file shared by every run on the machine — and this is the
    // only rip e2e whose mode ever reaches the branch that writes it. Scope it to our work dir
    // so two concurrent runs cannot interleave writes to the same file.
    PDJ_FAKE_COUNTER: join(work, 'fake-counter'),
    // shrink the ladder + the heal so the whole cycle runs in seconds
    RIP_TEST_DIGITAL_BUFFER_MS: '2000',
    RIP_TEST_DIGITAL_FLOOR_MS: '2000',
    RIP_TEST_MAX_ATTEMPTS: '2',
    RIP_TEST_BACKOFF_MS: '400,400',
    RIP_TEST_HEAL_QUIT_MS: '1000',
    RIP_TEST_HEAL_RELAUNCH_MS: '5000',
    // cooldown stays long (default 20 min) ON PURPOSE: the second wedged song must be REFUSED
  };
  // Boot on an allocated port and wait on READINESS, not on a fixed iteration count. Watch the
  // child's own exit as well: freePort() releases its probe socket before rip-server binds, and
  // rip-server does all of its startup BEFORE listen(), so a lost race looks like a perfectly
  // healthy boot in the log and only surfaces as an EADDRINUSE exit at the very end. Take a
  // fresh port and try again; never let a test run against a server that is not ours.
  for (let attempt = 1; ; attempt++) {
    const port = await freePort();
    base = `http://127.0.0.1:${port}`;
    serverLog = ''; srvExit = null;
    srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')],
      { env: { ...env, RIP_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
    srv.stdout.on('data', (d) => { serverLog += d; });
    srv.stderr.on('data', (d) => { serverLog += d; });
    srv.on('exit', (code, sig) => { srvExit = sig || code; });

    let up = false;
    for (let i = 0; i < 300 && srvExit === null && !up; i++) {   // ≤30s of readiness polling
      try { up = (await fetch(`${base}/health`)).ok; } catch { /* not up yet */ }
      if (!up) await sleep(100);
    }
    if (up) break;
    try { srv.kill('SIGKILL'); } catch { /* already gone */ }
    if (srvExit !== null && /EADDRINUSE/.test(serverLog) && attempt < 5) continue;  // lost the race
    throw new Error(`rip-server never became healthy on ${base} (exit=${srvExit})\n${serverLog}`);
  }
}, 60_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* already gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('rip server heals a wedged Music.app', () => {
  it('(b) restarts Music.app and retries ONCE — and the retry only succeeds BECAUSE of the restart', async () => {
    expectAccepted(await postRip(WEDGED_ONCE), WEDGED_ONCE);
    const end = Date.now() + 30_000;
    let st = null;
    while (Date.now() < end) { st = await getStatus(WEDGED_ONCE); if (st.ready) break; await sleep(150); }

    expect(st.ready).toBe(true);                       // the capture ultimately succeeded…
    expect(existsSync(healFlag)).toBe(true);           // …only after Music.app was relaunched
    expect(rig()).toMatch(/music-quit/);               // graceful quit was issued
    expect(rig()).toMatch(/music-launch/);
    expect(attempts(WEDGED_ONCE)).toBe(2);             // exactly one retry, not a loop
    expect(serverLog).toMatch(/HEAL /);                // the greppable token
    expect(serverLog).toMatch(/HEAL-OK/);
    expect(rig()).not.toMatch(/pkill/);                // graceful quit landed → no force kill
  }, 60_000);

  it('(c) the cooldown refuses a second heal — a dead Mac cannot become a quit/relaunch loop', async () => {
    const quitsBefore = countOf(rig(), 'music-quit');
    expectAccepted(await postRip(WEDGED_ALWAYS), WEDGED_ALWAYS);
    const end = Date.now() + 30_000;
    while (Date.now() < end) { const s = await getStatus(WEDGED_ALWAYS); if (!s.ready && !s.job) break; await sleep(200); }

    expect(countOf(rig(), 'music-quit')).toBe(quitsBefore);   // ← Music was NOT restarted again
    expect(serverLog).toMatch(/HEAL-SKIPPED/);
    expect(serverLog).toMatch(/cooldown/);
    // and it still went through the ORDINARY retry ladder rather than being dropped
    expect(attempts(WEDGED_ALWAYS)).toBeGreaterThanOrEqual(2);
  }, 60_000);
});
