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

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8816;                        // NOT 8787 (the live daemon) and NOT 8815 (the sibling e2e)
const base = `http://localhost:${PORT}`;
const ADMIN = 'admin-token-for-the-force-gate';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let work, srv, sqsDir, manifestPath, serverLog = '';

const jobs = () => {
  const f = join(sqsDir, 'pocketdj-timbre-jobs.ndjson');
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const enqueuedIds = () => jobs().flatMap((j) => j.songs.map((s) => s.id));
const post = (p, body, token) => fetch(base + p, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify(body),
});

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

  srv = spawn(process.execPath, [join(REPO, 'scripts/rip-server.mjs')], {
    env: {
      ...process.env,
      PATH: `${shimDir}:${dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: home,
      RIP_PORT: String(PORT),
      RIP_BUCKET: 'pocketdj-test-bucket',
      RIP_SOURCES: catalog,
      RIP_PUBLIC_FOLD: '0',
      RIP_ADMIN_TOKEN: ADMIN,          // user tier stays open (the real posture); admin is gated
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
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  srv.stdout.on('data', (d) => { serverLog += d; });
  srv.stderr.on('data', (d) => { serverLog += d; });
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* not up yet */ }
    await sleep(200);
  }
  // The startup sweep is async; give it room to send whatever it is going to send.
  for (let i = 0; i < 60 && !enqueuedIds().includes('sng_fresh'); i++) await sleep(100);
  await sleep(400);
}, 60_000);

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
  it('is REFUSED without the admin token — and refused loudly, not silently downgraded', async () => {
    const before = jobs().length;
    const res = await post('/analyze-timbre', { songIds: ['sng_measured'], force: true });
    expect(res.status).toBe(403);
    expect((await res.json()).error).toMatch(/admin/);
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
    for (let i = 0; i < 60 && jobs().length === before; i++) await sleep(50);
    const sent = jobs().slice(before).flatMap((j) => j.songs.map((s) => s.id));
    expect(sent).toEqual(['sng_measured']);        // …but only the same-bytes one is actually sent
    expect(serverLog).toMatch(/provenance gate/);
  }, 20_000);
});
