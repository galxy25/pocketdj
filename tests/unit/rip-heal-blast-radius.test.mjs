// ADVERSARIAL REVIEW (blast radius) of the wedged-Music heal — ef88421d.
//
// This file PINS three properties this code needs on a Mac that runs unattended for days:
//   1. a cancellation that lands DURING the heal must stop the retry
//   2. the server must keep answering HTTP while it heals
//   3. the gate's bounds must actually bound
// At ef88421d, 1 and 2 were real defects (captureWithHeal read canceled() once, before the heal,
// then ran runCapture(2) unconditionally; healMusic's osa was runOsascript — spawnSync — which
// blocks the Node event loop for the whole quit+relaunch, taking the HTTP daemon off the air).
// Both are FIXED on main as of 33ecef5d/4a2615cf: captureWithHeal re-checks canceled() after
// heal() returns, and rip-server.mjs wires the non-blocking runOsascriptAsync into healMusicApp.
// Tests 1 and 2 below now pass and exist to keep it that way. Test 3's sub-case (how long a
// permanently-broken Mac keeps getting restarted) also changed since the review: main added
// maxIneffective as a circuit breaker, so the old "72/day forever" number is superseded — see
// that test for the current, bounded number.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureWithHeal, createHealGate } from '../../scripts/lib/music-health.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8815;                       // NOT 8787 (live daemon), NOT 8809/8811 (branch's own tests)
const base = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LAUNCH_MS = 4000;                  // how long the fake Music.app takes to relaunch

const WEDGE = 'sng_wedge';

let work, srv, healFlag, rigLog, countsDir;

const rig = () => (existsSync(rigLog) ? readFileSync(rigLog, 'utf8') : '');
const attempts = (songId) => { try { return readFileSync(join(countsDir, `${songId}.log`), 'utf8').length; } catch { return 0; } };
const waitFor = async (pred, ms) => { const end = Date.now() + ms; while (Date.now() < end) { if (pred()) return true; await sleep(25); } return false; };

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
  // pkill MUST be shimmed: the heal escalates to `pkill -x Music`, and the REAL one would kill
  // the Music.app the LIVE rip daemon is capturing from right now.
  shell(join(shimDir, 'pkill'), `#!/bin/sh\nprintf 'pkill\\t%s\\n' "$*" >> ${JSON.stringify(rigLog)}\nexit 0\n`);

  // osascript shim whose RELAUNCH takes 4s. The real one is not instant either: Music takes
  // seconds to come back and answer a library query, which is exactly why healMusic polls for it.
  const osa = join(work, 'osa.mjs');
  writeFileSync(osa, `
import { appendFileSync, writeFileSync, existsSync } from 'node:fs';
const s = process.argv[3] || '';
const note = (k) => appendFileSync(${JSON.stringify(rigLog)}, k + '\\n');
const nap = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
if (/is running/.test(s)) { console.log('no'); process.exit(0); }
if (/to quit/.test(s)) { note('music-quit'); process.exit(0); }
if (/to launch/.test(s)) { note('music-launch'); nap(${LAUNCH_MS}); writeFileSync(${JSON.stringify(healFlag)}, '1'); process.exit(0); }
if (/library playlist 1/.test(s)) { console.log(existsSync(${JSON.stringify(healFlag)}) ? 'Library' : ''); process.exit(0); }
console.log('');
`);
  shell(join(shimDir, 'osascript'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(osa)} "$@"\n`);

  const catalog = join(work, 'digital.json');
  writeFileSync(catalog, JSON.stringify({
    manifest: { sourceType: 'digital', sourceName: 'Test' },
    albums: [{ id: 'alb_d', artist: 'Digi', name: 'D', trackList: [WEDGE] }],
    songs: [{ id: WEDGE, albumId: 'alb_d', artist: 'Digi', name: 'Wedge', length: 60_000 }], // ~92s deadline
  }));

  const worker = join(work, 'worker.mjs');
  writeFileSync(worker, `
import { writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const SONG = a['song-id'];
appendFileSync(join(${JSON.stringify(countsDir)}, SONG + '.log'), 'x');
const error = 'play accepted but Music never reached state=playing';
writeFileSync(a.status, JSON.stringify({ songId: SONG, phase: 'error', error, reason: 'play-not-started', updatedAt: Date.now() }));
console.log('RESULT ' + JSON.stringify({ ok: false, error, reason: 'play-not-started' }));
`);

  const env = {
    ...process.env,
    PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: join(work, 'home'),            // isolates CFG.tmp from the LIVE daemon's queue
    RIP_PORT: String(PORT),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    RIP_WORKER: worker,
    RIP_PUBLIC_FOLD: '0',
    POCKETDJ_STEM_OFFLOAD: '0',
    POCKETDJ_AUTO_STEM_ON_RIP: '0',
    POCKETDJ_ANALYSIS_OFFLOAD: '0',
    RIP_TEST_MAX_ATTEMPTS: '1',          // no backoff ladder — isolate the heal's own retry
    RIP_TEST_HEAL_QUIT_MS: '500',
    RIP_TEST_HEAL_RELAUNCH_MS: '20000',
    RIP_TEST_HEAL_COOLDOWN_MS: '0',
    RIP_TEST_HEAL_MAX_PER_HOUR: '50',
  };
  srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  srv.stdout.on('data', () => {});
  srv.stderr.on('data', () => {});
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* not up yet */ }
    await sleep(200);
  }
}, 60_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* already gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('blast radius of the wedged-Music heal', () => {
  // ── 1. cancellation inside the heal window ────────────────────────────────────────────────────
  // FIXED on main: captureWithHeal now re-checks canceled() after heal() returns, not just
  // before it. In production the heal spans up to quitTimeoutMs (15s) + relaunchTimeoutMs (60s),
  // and BOTH things that terminate a job asynchronously — the per-job watchdog in pump() and
  // POST /rip-cancel — can land inside that window, so the re-check is load-bearing.
  it('a job canceled DURING the heal must not be captured afterwards', async () => {
    let canceled = false;
    const calls = [];
    const r = await captureWithHeal({
      runCapture: async (n) => { calls.push(n); return { phase: 'error', reason: 'play-not-started' }; },
      heal: async () => { canceled = true; return { healed: true }; }, // Stop pressed while Music restarts
      gate: createHealGate({ cooldownMs: 0 }),
      canceled: () => canceled,
    });
    expect(calls).toEqual([1]);
    expect(r.attempts).toBe(1);
  });

  // ── 2. the heal freezes the whole server ──────────────────────────────────────────────────────
  // FIXED on main: rip-server.mjs wires runOsascriptAsync (execFile-based) into healMusicApp,
  // not the blocking runOsascript (spawnSync). The old bug — spawnSync blocks the Node event
  // loop for the duration of every AppleScript, taking a live HTTP daemon off the air for the
  // whole quit+relaunch — no longer applies to the heal path.
  it('the server keeps answering HTTP while Music.app is being restarted', async () => {
    await fetch(`${base}/rip`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ songId: WEDGE }) });
    expect(await waitFor(() => /music-launch/.test(rig()), 15_000)).toBe(true); // heal in flight
    const t0 = Date.now();
    await fetch(`${base}/health`);
    const ms = Date.now() - t0;
    expect(ms).toBeLessThan(LAUNCH_MS / 2); // ← blocks for the whole relaunch instead
  }, 60_000);

  // ── 3. the bounds that DO hold — verified, not read ───────────────────────────────────────────
  it('the cooldown is the binding bound — and it holds', () => {
    let t = 1_000_000;
    const gate = createHealGate({ now: () => t, cooldownMs: 20 * 60_000, maxPerHour: 3 });
    expect(gate.allow().ok).toBe(true);
    gate.record();
    expect(gate.allow()).toMatchObject({ ok: false, reason: 'cooldown' }); // immediately after
    t += 19 * 60_000;
    expect(gate.allow().ok).toBe(false);                                    // still inside cooldown
    t += 2 * 60_000;
    expect(gate.allow().ok).toBe(true);                                     // released at 20 min
  });

  // The gate advertises TWO independent bounds. At the shipped defaults the second one never
  // BINDS: three heals spaced >= 20 min apart already span 40 min, and a fourth needs 60 min from
  // the first — by which point the first has left the rolling hour. maxPerHour changes the
  // refusal message, never the rate, so the real cap is the cooldown alone.
  it('the per-hour ceiling does not reduce the heal rate below the cooldown', () => {
    const perDay = (maxPerHour) => {
      let t = 0, heals = 0;
      const gate = createHealGate({ now: () => t, cooldownMs: 20 * 60_000, maxPerHour });
      for (let minute = 0; minute < 24 * 60; minute++) {
        t = minute * 60_000;
        if (gate.allow().ok) { gate.record(); heals += 1; }
      }
      return heals;
    };
    expect(perDay(3)).toBe(perDay(1000));
  });

  it('captureWithHeal runs at most two captures even when the retry reports the wedge again', async () => {
    const calls = [];
    const r = await captureWithHeal({
      runCapture: async (n) => { calls.push(n); return { phase: 'error', reason: 'play-not-started' }; },
      heal: async () => ({ healed: true }),
      gate: createHealGate({ cooldownMs: 0 }),
    });
    expect(calls).toEqual([1, 2]);
    expect(r.healed).toBe(true);
  });

  // ── how long a permanently-broken Mac keeps getting restarted ─────────────────────────────────
  // At ef88421d the gate was a pure rate limiter with no terminal state — it never concluded
  // "healing does not work here, stop", so a permanently-broken Mac was restarted at the ceiling
  // rate (72/day) forever. main added maxIneffective as a CIRCUIT BREAKER since then (see
  // createHealGate's header): a heal counts against it the moment it is record()ed, and with no
  // intervening noteCaptureOk() the gate refuses forever after maxIneffective heals. This asserts
  // THAT bound now — the terminal state a rate limiter alone structurally cannot provide.
  it('a permanently broken Mac is restarted maxIneffective times, then never again', () => {
    let t = 0;
    const gate = createHealGate({ now: () => t, cooldownMs: 20 * 60_000, maxPerHour: 3 });
    let heals = 0;
    for (let minute = 0; minute < 24 * 60; minute++) { // one day of failing captures, minute by minute
      t = minute * 60_000;
      if (gate.allow().ok) { gate.record(); heals += 1; }
    }
    expect(heals).toBe(3); // capped by the circuit breaker's default maxIneffective, not 72/day
    expect(gate.circuitOpen()).toBe(true);
  });
});
