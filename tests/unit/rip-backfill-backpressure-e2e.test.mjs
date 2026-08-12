// END-TO-END: does the REAL rip-backfill driver ACT on a stall, or only announce one?
//
// rip-backfill-stall.test.mjs pins the SIGNAL (stalled / hoursSinceLastSuccess / a null ETA).
// A signal nobody acts on is what the 2026-08-12 incident actually cost: for 38 hours the driver
// kept 10 rows in flight against a rig that could not capture anything, every row came back
// failed with attempts=1, and the end-of-pass pass then spent each row's ONE remaining attempt
// against the same dead rig — 212 consecutive failures, most of them permanent, none of which
// said anything about the songs.
//
// So this file boots the actual scripts/rip-backfill.mjs against a fake rip server that fails
// every capture, and asserts the two behaviours that make a stall survivable:
//   1. the refill window collapses to a single CANARY row while stalled (and stays at the full
//      window when it is not — the control run, so the throttle is attributable to the stall),
//   2. a failure produced by a stalled RIG is DEFERRED rather than charged to the ROW — bounded,
//      so a plan of genuinely unrippable rows still drains.
//
// Everything is temp-scoped: its own state file, queue dir, log, pid and an in-process fake
// server on a private port. It never reads ~/.pocketdj/backfill/rip-backfill-state.json and
// never talks to the live rip daemon.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8817;                    // not 8787 (live rip daemon), not any sibling e2e's port
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const HOUR = 3_600_000;
const SONGS = ['sng_a', 'sng_b', 'sng_c'];
// The driver floors --poll-sec at 5s so a mis-set flag cannot hammer the rip server;
// RIP_TEST_MIN_POLL_SEC lowers that floor for tests. Durations below are counted in CYCLES, not
// seconds, because every behaviour here is "what happens on the next pass".
const POLL_SEC = 1;
const CYCLE_MS = POLL_SEC * 1000;

let work, server, posts = [];

// A rip server that accepts everything and captures nothing — the rig as it was during the wedge.
function startFakeServer() {
  return new Promise((res) => {
    server = createServer((req, r) => {
      const url = req.url || '';
      const send = (code, body) => { r.writeHead(code, { 'content-type': 'application/json' }); r.end(JSON.stringify(body)); };
      if (url === '/health') return send(200, { ok: true, protocol: 2 });
      if (url === '/rip' && req.method === 'POST') {
        let b = '';
        req.on('data', (d) => { b += d; });
        return req.on('end', () => {
          const songId = (JSON.parse(b || '{}').songId) || '';
          posts.push({ songId, atMs: Date.now() });
          send(200, { jobId: `job_${songId}_${posts.length}`, phase: 'queued' });
        });
      }
      // every job terminates in the generic capture failure the wedge produced
      if (url.startsWith('/jobs/')) return send(200, { jobId: decodeURIComponent(url.slice(6)), phase: 'error', error: 'no audio captured — is the track in the library and audio routed to system output?' });
      if (url.startsWith('/status/')) return send(200, { ready: false });
      send(404, { error: 'nope' });
    });
    server.listen(PORT, '127.0.0.1', res);
  });
}

// Seed a state file whose plan is already computed, so the driver skips planning (which would
// need the real indexes + backup) and goes straight to the pump.
function seedState(dir, { hoursSinceSuccess, songs }) {
  const sourcePath = join(dir, 'source-backup.pocketdj');
  writeFileSync(sourcePath, '{}');
  const st = statSync(sourcePath);
  const now = Date.now();
  const state = {
    v: 1,
    plan: {
      sourcePath, sourceMtimeMs: st.mtimeMs, sourceBytes: st.size, computedAt: now,
      pockets: 1, entries: songs.length, skips: {},
      rips: songs.map((songId) => ({ songId, route: 'digital', pocketName: 'P' })),
    },
    done: {}, failed: {}, requested: {}, aliases: {}, retryBudget: {}, stallDeferred: {},
    // The stall clock, pre-aged. This is the ONLY difference between the two runs below.
    stats: {
      lastSuccessAtMs: now - hoursSinceSuccess * HOUR,
      watchSinceMs: now - hoursSinceSuccess * HOUR,
      consecutiveFailures: 0, successes: 1,
    },
  };
  const statePath = join(dir, 'state.json');
  writeFileSync(statePath, JSON.stringify(state));
  return { statePath, sourcePath };
}

// Run the real driver for a bounded number of cycles, then SIGTERM it (its own clean-stop path).
async function runDriver(dir, { hoursSinceSuccess, deferMax, cycles, songs = SONGS }) {
  const { statePath, sourcePath } = seedState(dir, { hoursSinceSuccess, songs });
  const queueDir = join(dir, 'queue');
  mkdirSync(queueDir, { recursive: true });
  writeFileSync(join(dir, 'manifest.json'), '{}');
  posts = [];
  let out = '';
  const p = spawn(process.execPath, [
    join(REPO, 'scripts/rip-backfill.mjs'),
    '--state', statePath, '--source', sourcePath, '--queue-dir', queueDir,
    '--log', join(dir, 'driver.log'), '--pid', join(dir, 'driver.pid'),
    '--rip-server', `http://127.0.0.1:${PORT}`, '--manifest-file', join(dir, 'manifest.json'),
    '--poll-sec', String(POLL_SEC), '--window', '10',
    '--stall-hours', '0.05', '--stall-defer-max', String(deferMax),
  ], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, RIP_TEST_MIN_POLL_SEC: String(POLL_SEC) } });
  p.stdout.on('data', (d) => { out += d; });
  p.stderr.on('data', (d) => { out += d; });
  await sleep(cycles * CYCLE_MS - CYCLE_MS / 2); // stop mid-sleep of the last cycle
  p.kill('SIGTERM');
  await new Promise((res) => { p.on('close', res); setTimeout(res, 5000); });
  const finalState = JSON.parse(readFileSync(statePath, 'utf8'));
  const heartbeats = out.split('\n').filter((l) => l.includes('HEARTBEAT ')).map((l) => JSON.parse(l.slice(l.indexOf('HEARTBEAT ') + 10)));
  return { out, finalState, heartbeats };
}

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-backpressure-'));
  await startFakeServer();
}, 30_000);

afterAll(async () => {
  await new Promise((res) => (server ? server.close(res) : res()));
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('the backfill driver stops feeding a rig it already knows is dead', () => {
  it('THE INCIDENT: 38h with no capture → one canary in flight, not ten, and no permanent failures', async () => {
    const dir = join(work, 'stalled');
    mkdirSync(dir, { recursive: true });
    const { out, finalState, heartbeats } = await runDriver(dir, { hoursSinceSuccess: 38, deferMax: 1, cycles: 3 });

    // — the signal —
    const hb = heartbeats.at(-1);
    expect(hb.stalled).toBe(true);
    expect(hb.etaHours).toBeNull();
    expect(hb.hoursSinceLastSuccess).toBeGreaterThanOrEqual(38);
    expect(out).toMatch(/STALL \{/);

    // — the action (1): a single canary, though the window is 10 and 3 rows are pending —
    expect(hb.refillWindow).toBe(1);
    const perCycle = {};
    for (const p of posts) perCycle[Math.round((p.atMs - posts[0].atMs) / 500)] = (perCycle[Math.round((p.atMs - posts[0].atMs) / 500)] || 0) + 1;
    expect(Math.max(...Object.values(perCycle))).toBe(1); // never two rows on the rig at once
    expect(heartbeats.every((h) => h.inflight <= 1)).toBe(true);

    // — the action (2): the rig's verdict is not charged to the row —
    expect(out).toMatch(/⏸ sng_[abc]: no-match while the rig is STALLED/);
    expect(Object.keys(finalState.stallDeferred).length).toBeGreaterThan(0);
    // …and the failure is still COUNTED, so the stall signal stays honest
    expect(finalState.stats.consecutiveFailures).toBeGreaterThan(0);
  }, 60_000);

  it('the deferral is BOUNDED — a row the rig keeps refusing still becomes a recorded failure', async () => {
    // Otherwise a stall that never clears (every remaining row genuinely unrippable) would churn
    // the same rows forever and the driver would never reach ALL DONE.
    const dir = join(work, 'bounded');
    mkdirSync(dir, { recursive: true });
    // ONE row, so the bound is reached in three cycles: post → defer(1/1) + re-post → record.
    const { out, finalState } = await runDriver(dir, { hoursSinceSuccess: 38, deferMax: 1, cycles: 4, songs: ['sng_a'] });
    expect(out).toMatch(/⏸ sng_a: .*defer 1\/1/);              // forgiven exactly once…
    expect(out).toMatch(/✗ sng_a: no-match \(attempt 1\)/);     // …then charged to the row
    expect(finalState.failed.sng_a).toBeTruthy();
  }, 60_000);

  it('CONTROL: a HEALTHY rig still gets the full window — the throttle is caused by the stall', async () => {
    const dir = join(work, 'healthy');
    mkdirSync(dir, { recursive: true });
    const { out, finalState, heartbeats } = await runDriver(dir, { hoursSinceSuccess: 0, deferMax: 1, cycles: 3 });

    expect(heartbeats[0].stalled).toBe(false);
    expect(heartbeats[0].refillWindow).toBe(10);
    expect(heartbeats[0].etaHours).toBeGreaterThan(0);   // an honest ETA is published when it can be
    expect(out).not.toMatch(/STALL \{/);
    // all three rows go out in the FIRST cycle rather than one at a time
    expect(posts.filter((p) => p.atMs - posts[0].atMs < 500).length).toBe(SONGS.length);
    // and failures are charged to the rows normally — no deferral when the rig is fine
    expect(out).not.toMatch(/⏸ /);
    expect(Object.keys(finalState.stallDeferred).length).toBe(0);
    expect(Object.keys(finalState.failed).length).toBe(SONGS.length);
  }, 60_000);
});
