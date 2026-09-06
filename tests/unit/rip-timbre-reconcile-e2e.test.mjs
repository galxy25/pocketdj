// END-TO-END: the ONGOING path must not re-run the corpus it already has, and must not overwrite
// a raw-source analog vector with a re-encoded one.
//
// The failure this pins is not hypothetical. On the machine this branch was built on, the live
// manifest holds 5,484 entries and ZERO timbre stamps, while the durable result corpus holds
// 15,489 vectors — 10,388 of them `vinyl-cut`. Restarting the rip server with a stamp-only sweep
// would therefore enqueue 5,388 already-measured songs (500 every 6 h, ~66 h of fleet spin-ups
// for zero new information), and 287 of them are analog songs whose vectors would come back
// measured from the BURNED CUT instead of the raw album file and replace the good rows.
//
// Boots the REAL rip-server.mjs with an isolated HOME containing a seeded results corpus, a fake
// `aws` whose SQS spool is readable, and an admin token — so every assertion is on the actual
// message bodies, the actual manifest on disk, and the actual HTTP status.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';
import { freePort } from './helpers/free-port.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
// ALLOCATED, not hand-picked (see helpers/free-port.mjs). Hand-picked constants only dodge the
// collisions their author knew about, and they are global state across concurrent runs of the
// suite; the loser of the race dies of EADDRINUSE after a clean-looking boot while the winner
// answers our probe, so the tests silently drive a stranger's server.
let base;
// TWO tiers, because that is the production posture the force gate has to survive: a public
// server with a user token the app carries and an admin token only Levi's own devices carry.
// (Before the MUST-1 fail-closed change a tokenless server answered every user-tier request;
// it now 401s under public posture, so the app tier must be a real credential here or every
// assertion below is testing the wrong gate.)
const USER = 'user-token-for-the-app-tier';
const ADMIN = 'admin-token-for-the-force-gate';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let work, srv, sqsDir, manifestPath, serverLog = '', srvExit = null;

const jobs = () => {
  const f = join(sqsDir, 'pocketdj-timbre-jobs.ndjson');
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const enqueuedIds = () => jobs().flatMap((j) => j.songs.map((s) => s.id));
// `token` defaults to the USER tier (what the app sends); pass ADMIN for the admin tier, or
// an explicit null to post anonymously.
const post = (p, body, token = USER) => fetch(base + p, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify(body),
});
// Poll a condition on a WALL-CLOCK deadline rather than a fixed iteration count: a loaded
// machine makes each iteration cost more than the sleep, so a count-based loop silently
// shortens its own timeout exactly when it needs to be longest.
async function waitFor(cond, ms, what) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (srvExit !== null) throw new Error(`rip-server exited (${srvExit}) while waiting for ${what}\n${serverLog}`);
    if (await cond()) return true;
    await sleep(50);
  }
  return false;
}

// sng_measured / sng_vinyl already have vectors in the RESULT CORPUS but no manifest stamp —
// exactly the live shape. sng_fresh has neither. sng_dead ran and produced nothing usable.
const SEED = {
  sng_measured: { source: 'digital', key: 'rips/sng_measured.mp3', rippedAt: 1 },
  sng_vinyl: { source: 'analog', key: 'rips/album.mp3', cutKey: 'rips/cuts/sng_vinyl.mp3', rippedAt: 2 },
  sng_fresh: { source: 'digital', key: 'rips/sng_fresh.mp3', rippedAt: 3 },
  sng_dead: { source: 'digital', key: 'rips/sng_dead.mp3', rippedAt: 4 },
};
const RESULTS = [
  { id: 'sng_measured', v: TIMBRE_VERSION, src: 's3-song', atMs: 1700000000000, ok: true, f: { c: 1 } },
  { id: 'sng_vinyl', v: TIMBRE_VERSION, src: 'vinyl-cut', atMs: 1700000000001, ok: true, f: { c: 2 } },
  { id: 'sng_dead', v: TIMBRE_VERSION, permanent: true, error: 'too short' },
];

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-timbre-rec-'));
  const shimDir = join(work, 'bin');
  const home = join(work, 'home');
  const results = join(home, '.pocketdj', 'timbre-batch', 'results');
  sqsDir = join(work, 'sqs');
  mkdirSync(shimDir, { recursive: true });
  mkdirSync(sqsDir, { recursive: true });
  mkdirSync(results, { recursive: true });

  // Two files, exactly as on the real machine: local shards plus the cloud fold's output.
  writeFileSync(join(results, 'shard-0.ndjson'), RESULTS.map((r) => JSON.stringify(r)).join('\n') + '\n');
  writeFileSync(join(results, 'cloud.ndjson'), '');

  manifestPath = join(work, 'manifest.json');
  writeFileSync(manifestPath, JSON.stringify(SEED));
  writeFileSync(join(shimDir, 'aws'),
    `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
  chmodSync(join(shimDir, 'aws'), 0o755);

  const catalog = join(work, 'digital.json');
  writeFileSync(catalog, JSON.stringify({ manifest: { sourceType: 'digital', sourceName: 'T' }, albums: [], songs: [] }));

  const env = {
      ...process.env,
      PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: home,
      RIP_BUCKET: 'pocketdj-test-bucket',
      RIP_SOURCES: catalog,
      RIP_PUBLIC_FOLD: '0',
      // The real production posture: PUBLIC (behind the Funnel), user tier gated by RIP_TOKEN,
      // admin tier gated separately. Both must be set — a public server with no token now fails
      // closed and 401s the user tier, which would mask the `force` gate this file exists to pin.
      RIP_TOKEN: USER,
      RIP_ADMIN_TOKEN: ADMIN,
      POCKETDJ_STEM_OFFLOAD: '0',
      POCKETDJ_AUTO_STEM_ON_RIP: '0',
      POCKETDJ_ANALYSIS_OFFLOAD: '0',
      POCKETDJ_LYRICS_OFFLOAD: '0',
      POCKETDJ_TIMBRE_JOBS_QUEUE: 'https://sqs.test/pocketdj-timbre-jobs',
      POCKETDJ_TIMBRE_RESULTS_QUEUE: 'https://sqs.test/pocketdj-timbre-results',
      POCKETDJ_TIMBRE_DLQ_QUEUE: 'https://sqs.test/pocketdj-timbre-jobs-dlq',
      POCKETDJ_TIMBRE_BATCH_SIZE: '2',
      POCKETDJ_TIMBRE_SWEEP_MS: '86400000',
      FAKE_AWS_MANIFEST: manifestPath,
      FAKE_AWS_SQS_DIR: sqsDir,
  };

  // Boot on an allocated port, watching the child's own exit. freePort() releases its probe
  // socket before rip-server binds, and rip-server does all of its startup BEFORE listen(), so a
  // lost race looks like a clean boot right up to the EADDRINUSE exit — retry on a fresh port.
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
    for (let i = 0; i < 300 && srvExit === null && !up; i++) {
      try { up = (await fetch(`${base}/health`)).ok; } catch { /* not up yet */ }
      if (!up) await sleep(100);
    }
    if (up) break;
    try { srv.kill('SIGKILL'); } catch { /* already gone */ }
    if (srvExit !== null && /EADDRINUSE/.test(serverLog) && attempt < 5) continue;  // lost the race
    throw new Error(`rip-server never became healthy on ${base} (exit=${srvExit})\n${serverLog}`);
  }
  // The startup sweep is async. Wait on its OBSERVABLE COMPLETION — the reconcile log line plus
  // the only enqueue it should ever make — not on a fixed number of sleeps.
  if (!await waitFor(async () => /timbre reconcile:/.test(serverLog) && enqueuedIds().includes('sng_fresh'), 30_000, 'startup sweep'))
    throw new Error(`startup sweep never reconciled + enqueued sng_fresh\njobs=${JSON.stringify(enqueuedIds())}\n${serverLog}`);
  // Settle: prove the sweep sent NOTHING MORE. The assertions below are about what is absent,
  // so a quiet spool has to stay quiet, not merely be quiet at the instant sng_fresh landed.
  const settled = jobs().length;
  await sleep(400);
  expect(jobs().length).toBe(settled);
}, 90_000);

afterAll(() => {
  try { srv?.kill('SIGKILL'); } catch { /* gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('rip server → durable corpus reconcile', () => {
  it('the startup sweep enqueues ONLY the genuinely un-measured song', () => {
    expect(enqueuedIds()).toEqual(['sng_fresh']);
  });

  it('an analog song measured from the RAW ALBUM FILE is never re-run from the burned cut', () => {
    // The one path where cloud and local read different bytes — and the one path the 120-song
    // parity sample (all s3-song) can say nothing about.
    expect(enqueuedIds()).not.toContain('sng_vinyl');
  });

  it('the reconcile reaches DISK — stamps are in manifest.json, with the provenance recorded', () => {
    const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
    expect(m.sng_measured).toMatchObject({ timbreVersion: TIMBRE_VERSION, timbreSrc: 's3-song' });
    expect(m.sng_vinyl).toMatchObject({ timbreVersion: TIMBRE_VERSION, timbreSrc: 'vinyl-cut' });
    expect(m.sng_fresh.timbreVersion).toBeUndefined();
  });

  it('a permanently-unanalysable song is marked, not counted as coverage', async () => {
    const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
    expect(m.sng_dead.timbrePermanent).toBe(true);
    const h = await (await fetch(`${base}/health`)).json();
    expect(h.timbre.analysed).toBe(2);      // measured + vinyl
    expect(h.timbre.failed).toBe(1);        // dead — stamped so it never re-runs, but NOT coverage
    expect(h.timbre.outstanding).toBe(1);   // fresh
  });

  it('re-adding an already-measured song to a collection sends nothing', async () => {
    const before = jobs().length;
    const r = await (await post('/analyze-timbre', { songIds: ['sng_measured', 'sng_vinyl'] })).json();
    expect(r.enqueued).toBe(0);
    await sleep(400);
    expect(jobs().length).toBe(before);
  });
});

describe('POST /analyze-timbre — `force` is an admin capability', () => {
  // The route is deliberately user-tier (a collection add must work from the app), takes 5,000
  // ids, has no confirmLarge cap, and the server is PUBLIC-BY-DEFAULT behind a tokenless Funnel.
  // wantTimbre-filtering is the ONLY thing that makes that safe — and `force` turns it off AND
  // rides dedup:false to the worker, disabling the S3 skip too. One anonymous POST would be
  // 5,000 real re-analyses on a three-instance c7g.2xlarge fleet.
  it('is REFUSED with only the USER token — and refused loudly, not silently downgraded', async () => {
    const before = jobs().length;
    const res = await post('/analyze-timbre', { songIds: ['sng_measured'], force: true });
    // 403, not 401: the caller IS authenticated, just at the wrong tier. The distinction is the
    // whole point — a 401 here would mean the app tier can't reach the route at all.
    expect(res.status).toBe(403);
    expect((await res.json()).error).toMatch(/admin/);
    await sleep(300);
    expect(jobs().length).toBe(before);
  });

  it('an ANONYMOUS caller never reaches the route at all — the server fails closed when public', async () => {
    // MUST-1. The tokenless Funnel is the threat model the force gate was written against; this
    // pins the outer layer that now closes it, so a regression to "no token = open" is caught
    // here and not in production.
    const before = jobs().length;
    const res = await post('/analyze-timbre', { songIds: ['sng_measured'], force: true }, null);
    expect(res.status).toBe(401);
    await sleep(300);
    expect(jobs().length).toBe(before);
  });

  it('the unforced call on the same id is still accepted — the gate is on `force`, not the route', async () => {
    const res = await post('/analyze-timbre', { songIds: ['sng_measured'] });
    expect(res.status).toBe(200);
    expect((await res.json()).enqueued).toBe(0);
  });

  it('WITH the admin token it forces — but the provenance gate still holds the analog song', async () => {
    const before = jobs().length;
    const r = await (await post('/analyze-timbre', { songIds: ['sng_measured', 'sng_vinyl'], force: true }, ADMIN)).json();
    expect(r.enqueued).toBe(2);                    // both pass the wantTimbre bypass…
    // offloadTimbre is fire-and-forget, so the 200 lands before the spool write. Wait on the
    // write, on a deadline.
    expect(await waitFor(async () => jobs().length > before, 15_000, 'forced enqueue')).toBe(true);
    await sleep(300);                              // and let any SECOND batch land, so an extra send would be caught
    const sent = jobs().slice(before).flatMap((j) => j.songs.map((s) => s.id));
    expect(sent).toEqual(['sng_measured']);        // …but only the same-bytes one is actually sent
    expect(serverLog).toMatch(/provenance gate/);
  }, 20_000);
});
