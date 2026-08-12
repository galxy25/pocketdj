// END-TO-END: the BLAST RADIUS of healing a wedged Music.app.
//
// rip-server-heal-e2e.test.mjs proves the heal WORKS. This file proves it does not take anything
// else down with it. Both defects it pins were invisible to the unit tests and only appear when
// the real HTTP daemon runs the real heal:
//
//   1. THE SERVER MUST STAY UP WHILE IT HEALS. healMusic's `osa` used to be runOsascript, which
//      is spawnSync — it blocks the Node event loop for the whole AppleScript. rip-server is a
//      live daemon serving status polls, HLS segments and the Stop button, so a heal took the
//      entire server off the air: measured at 4s here, with a production worst case near 160s
//      (quit, an `is running` loop whose deadline is only checked between 20s script timeouts,
//      launch, then the library-liveness poll). The fix is the async execFile form.
//
//   2. A STOP THAT LANDS DURING THE HEAL MUST STOP. captureWithHeal read canceled() once, BEFORE
//      the heal, then ran the retry unconditionally — so a cancel arriving inside a 75-second
//      window was ignored and a capture ran anyway. These two defects hid each other: while the
//      event loop was blocked the cancel could not even be RECEIVED, so whether Stop "worked"
//      came down to whether the queued request was processed before or after the retry child
//      spawned. Fixing (1) alone would make the race reliably LOSE; both fixes together make it
//      a decision.
//
// Safety, non-negotiable in this file: an isolated HOME (never the live daemon's queue), a
// private port (the live daemon owns 8787; the sibling e2es own 8809/8811), a fake `aws`, a fake
// `osascript` — and a shimmed `pkill`, because the heal escalates to `pkill -x Music` and the
// real one would kill the Music.app the LIVE rip daemon is capturing from right now.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8813;                    // NOT 8787 (live daemon), NOT 8809/8811 (sibling e2es)
const base = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LAUNCH_MS = 4000;               // how long the fake Music.app takes to come back

const SLOW = 'sng_slow_heal';         // used for the responsiveness measurement
const STOPPED = 'sng_stop_mid_heal';  // canceled while Music is restarting

let work, srv, serverLog = '', healFlag, rigLog, countsDir;

const rig = () => (existsSync(rigLog) ? readFileSync(rigLog, 'utf8') : '');
const countOf = (s, needle) => s.split(needle).length - 1;
const attempts = (songId) => { try { return readFileSync(join(countsDir, `${songId}.log`), 'utf8').length; } catch { return 0; } };
const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
const getStatus = async (songId) => (await fetch(`${base}/status/${songId}`)).json();
const waitFor = async (pred, ms) => { const end = Date.now() + ms; while (Date.now() < end) { if (await pred()) return true; await sleep(25); } return false; };

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-heal-blast-'));
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
  shell(join(shimDir, 'pkill'), `#!/bin/sh\nprintf 'pkill\\t%s\\n' "$*" >> ${JSON.stringify(rigLog)}\nexit 0\n`);

  const catalog = join(work, 'digital.json');
  writeFileSync(catalog, JSON.stringify({
    manifest: { sourceType: 'digital', sourceName: 'Test' },
    albums: [{ id: 'alb_d', artist: 'Digi', name: 'D', trackList: [SLOW, STOPPED] }],
    songs: [
      { id: SLOW, albumId: 'alb_d', artist: 'Digi', name: 'Slow Heal', length: 3000 },
      { id: STOPPED, albumId: 'alb_d', artist: 'Digi', name: 'Stopped Mid Heal', length: 3000 },
    ],
  }));

  // Capture worker that always reports the wedge signature. Every attempt is counted, so
  // "did a SECOND capture run?" is a file length, not an inference.
  const worker = join(work, 'worker.mjs');
  writeFileSync(worker, `
import { writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const SONG = a['song-id'];
appendFileSync(join(${JSON.stringify(countsDir)}, SONG + '.log'), 'x');
const error = 'play accepted but Music never reached state=playing (last state=stopped, position=missing value)';
writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'error', error, reason: 'play-not-started', updatedAt: Date.now() }));
console.log('RESULT ' + JSON.stringify({ ok: false, error, reason: 'play-not-started' }));
`);

  const env = {
    ...process.env,
    PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: join(work, 'home'),          // isolates CFG.tmp from the LIVE daemon's queue
    RIP_PORT: String(PORT),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    RIP_WORKER: worker,
    RIP_PUBLIC_FOLD: '0',
    POCKETDJ_STEM_OFFLOAD: '0',
    POCKETDJ_AUTO_STEM_ON_RIP: '0',
    POCKETDJ_ANALYSIS_OFFLOAD: '0',
    PDJ_FAKE_MODE: 'wedged',           // never recovers — the heal's own bounds are not under test here
    PDJ_FAKE_LOG: rigLog,
    PDJ_FAKE_LAUNCH_DELAY_MS: String(LAUNCH_MS),
    // Deadlines long enough that the WATCHDOG never fires inside the 4s heal — this file is
    // about the cancel path, and a watchdog kill would be a different (unit-tested) story.
    RIP_TEST_DIGITAL_BUFFER_MS: '60000',
    RIP_TEST_DIGITAL_FLOOR_MS: '60000',
    RIP_TEST_MAX_ATTEMPTS: '1',        // no backoff ladder: every capture in countsDir is the heal's
    RIP_TEST_HEAL_QUIT_MS: '500',
    RIP_TEST_HEAL_RELAUNCH_MS: '20000',
    RIP_TEST_HEAL_COOLDOWN_MS: '0',    // both tests must be allowed to heal…
    RIP_TEST_HEAL_MAX_PER_HOUR: '50',
    RIP_TEST_HEAL_MAX_INEFFECTIVE: '0', // …and the breaker is pinned by unit tests, not here
  };
  srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  srv.stdout.on('data', (d) => { serverLog += d; });
  srv.stderr.on('data', (d) => { serverLog += d; });
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* not up yet */ }
    await sleep(200);
  }
}, 60_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* already gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('healing a wedged Music.app must not take the rip server down with it', () => {
  it('the server keeps answering HTTP while Music.app is being restarted', async () => {
    await post('/rip', { songId: SLOW });
    // The fake logs `music-launch` BEFORE it blocks, so this is the start of the relaunch window.
    expect(await waitFor(async () => /music-launch/.test(rig()), 20_000)).toBe(true);

    const t0 = Date.now();
    const r = await fetch(`${base}/health`);
    const ms = Date.now() - t0;
    expect(r.ok).toBe(true);
    // With the synchronous osascript this fetch could not even be dispatched until the 4s
    // relaunch returned. Half the launch window is a generous margin either way.
    expect(ms).toBeLessThan(LAUNCH_MS / 2);

    // …and the heal itself still completed and still retried (the fix must not disable it).
    expect(await waitFor(async () => attempts(SLOW) === 2, 30_000)).toBe(true);
    expect(serverLog).toMatch(/HEAL /);
    expect(await waitFor(async () => { const s = await getStatus(SLOW); return !s.ready && !s.job; }, 30_000)).toBe(true);
  }, 90_000);

  it('a Stop pressed DURING the heal is honoured — no capture runs after the restart', async () => {
    const quitsBefore = countOf(rig(), 'music-quit');
    await post('/rip', { songId: STOPPED });
    expect(await waitFor(async () => attempts(STOPPED) === 1, 30_000)).toBe(true);
    // wait until THIS song's relaunch is in flight (a new quit is the marker)
    expect(await waitFor(async () => countOf(rig(), 'music-quit') > quitsBefore, 20_000)).toBe(true);

    // Stop, from inside the relaunch window. This request has to be RECEIVED here, which is only
    // possible because the heal no longer blocks the event loop.
    const t0 = Date.now();
    const res = await post('/rip-cancel', { songIds: [STOPPED] });
    expect(res.ok).toBe(true);
    expect(Date.now() - t0).toBeLessThan(LAUNCH_MS / 2);

    // The heal runs to completion (it is not abortable mid-relaunch, and quitting halfway would
    // be worse) — but the capture that used to follow it must NOT run.
    await sleep(LAUNCH_MS + 1500);
    expect(attempts(STOPPED)).toBe(1);                 // ← one capture, not two
    expect(serverLog).toMatch(/HEAL-ABANDONED sng_stop_mid_heal/);
    const st = await getStatus(STOPPED);
    expect(st.ready).toBeFalsy();
  }, 90_000);

  it('the PATH shims were really used — this test never drove the live rig', () => {
    // If PATH interception had failed, everything above would have quietly driven the user's
    // Music.app (and `pkill -x Music` would have hit the live daemon's capture). Assert the fake
    // was exercised, and that nothing escalated to a force kill.
    expect(rig()).toMatch(/music-quit/);
    expect(rig()).toMatch(/music-launch/);
    expect(rig()).not.toMatch(/pkill/);
  });
});
