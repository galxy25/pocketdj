// END-TO-END: does the REAL rip server actually enqueue cloud timbre jobs, and does a worker
// result actually REACH DISK?
//
// The pure layer is covered by timbre-cloud-jobs.test.mjs. This file tests the WIRING — the half
// that has failed twice in this codebase's history: a result folded in memory and deleted from
// the queue before the manifest save was durable (stems on S3, manifest never learns), and a
// dispatcher whose SQS bodies no test could see because the fake `aws` "succeeded silently".
//
// Boots scripts/rip-server.mjs with an isolated HOME, a private port, and a fake `aws` whose new
// SQS spool (FAKE_AWS_SQS_DIR) makes every enqueued message readable, so the assertions are on
// the ACTUAL message bodies and the ACTUAL manifest file, not on a log line.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TIMBRE_VERSION } from '../../scripts/lib/audio-analyze.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8815;                        // NOT 8787 — that is the live rip daemon
const base = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const JOBS_Q = 'https://sqs.test/pocketdj-timbre-jobs';
const RES_Q = 'https://sqs.test/pocketdj-timbre-results';

let work, srv, sqsDir, manifestPath, serverLog = '';

/// Poll until the spool holds `n` song ids. The sweep sends its batches CONCURRENTLY through the
/// bounded dispatcher, so "at least one message exists" says nothing about the rest having landed
/// — asserting on the first arrival is a race that passes alone and fails under load.
const waitForSongs = async (n, ms = 10_000) => {
  const end = Date.now() + ms;
  for (;;) {
    const ids = jobs().flatMap((j) => j.songs.map((s) => s.id));
    if (ids.length >= n || Date.now() > end) return ids;
    await sleep(50);
  }
};

const spool = (q) => {
  const f = join(sqsDir, `${q}.ndjson`);
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const jobs = () => spool('pocketdj-timbre-jobs');
const deleted = () => {
  const f = join(sqsDir, 'pocketdj-timbre-results.deleted.ndjson');
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean) : [];
};
const post = (p, body) => fetch(base + p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then((r) => r.json());

// A manifest with three shapes: analysable, ALREADY analysed, and no-audio-yet.
const SEED = {
  sng_aaaaaaaaaaaa: { source: 'digital', key: 'rips/sng_aaaaaaaaaaaa.mp3', rippedAt: 1 },
  sng_bbbbbbbbbbbb: { source: 'digital', key: 'rips/sng_bbbbbbbbbbbb.mp3', rippedAt: 2 },
  sng_cccccccccccc: { source: 'digital', key: 'rips/sng_cccccccccccc.mp3', timbre: 'rips/timbre/v1/sng_cccccccccccc.json', timbreVersion: 1 },
  sng_dddddddddddd: { source: 'digital' },                                   // no audio yet
  sng_eeeeeeeeeeee: { source: 'analog', key: 'rips/album.mp3', cutKey: 'rips/cuts/sng_eeeeeeeeeeee.mp3' },
};

beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'pdj-timbre-e2e-'));
  const shimDir = join(work, 'bin');
  sqsDir = join(work, 'sqs');
  mkdirSync(shimDir, { recursive: true });
  mkdirSync(sqsDir, { recursive: true });
  mkdirSync(join(work, 'home'), { recursive: true });

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
    HOME: join(work, 'home'),
    RIP_PORT: String(PORT),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    RIP_PUBLIC_FOLD: '0',
    POCKETDJ_STEM_OFFLOAD: '0',
    POCKETDJ_AUTO_STEM_ON_RIP: '0',
    POCKETDJ_ANALYSIS_OFFLOAD: '0',
    POCKETDJ_LYRICS_OFFLOAD: '0',
    POCKETDJ_TIMBRE_JOBS_QUEUE: JOBS_Q,
    POCKETDJ_TIMBRE_RESULTS_QUEUE: RES_Q,
    POCKETDJ_TIMBRE_DLQ_QUEUE: 'https://sqs.test/pocketdj-timbre-jobs-dlq',
    POCKETDJ_TIMBRE_BATCH_SIZE: '2',      // tiny, so batching is observable
    POCKETDJ_TIMBRE_SWEEP_MS: '86400000', // the startup sweep runs once; no repeat during the test
    FAKE_AWS_MANIFEST: manifestPath,     // load AND save round-trip through this file
    FAKE_AWS_SQS_DIR: sqsDir,
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
  try { srv?.kill('SIGKILL'); } catch { /* gone */ }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('rip server → cloud timbre lane', () => {
  it('the T3 BACKSTOP SWEEP fires at startup — the freeze cannot depend on anyone remembering', async () => {
    // This is the whole answer to "why not a launchd nightly": that nightly has been a no-op
    // since it was written because it needs a credential file its installer cannot create.
    const enqueued = await waitForSongs(3);
    expect(enqueued).toContain('sng_aaaaaaaaaaaa');
    expect(enqueued).toContain('sng_bbbbbbbbbbbb');
    expect(enqueued).toContain('sng_eeeeeeeeeeee');
    expect(enqueued).not.toContain('sng_cccccccccccc');   // already analysed at this version
    expect(enqueued).not.toContain('sng_dddddddddddd');   // no audio → nothing to analyse
  }, 30_000);

  it('an ANALOG song is enqueued by its per-song CUT, never the shared album file', async () => {
    await waitForSongs(3);
    const analog = jobs().flatMap((j) => j.songs).find((s) => s.id === 'sng_eeeeeeeeeeee');
    expect(analog.key).toBe('rips/cuts/sng_eeeeeeeeeeee.mp3');
    expect(analog.kind).toBe('s3-cut');
  });

  it('every message carries kind:timbre and respects the batch size', async () => {
    await waitForSongs(3);
    expect(jobs().every((j) => j.kind === 'timbre')).toBe(true);
    expect(jobs().every((j) => j.songs.length <= 2)).toBe(true);
  });

  it('/health reports the freeze signal so silence is never mistaken for health', async () => {
    const h = await (await fetch(`${base}/health`)).json();
    expect(h.timbre.offload).toBe(true);
    expect(h.timbre.analysed).toBe(1);                    // only sng_cccccccccccc is stamped
    expect(h.timbre.outstanding).toBe(3);
    expect(h.timbre.oldestOutstandingAgeMs).toBeGreaterThan(0);
  });

  it('POST /analyze-timbre enqueues ONLY the unanalysed-with-audio ids (the collection-add path)', async () => {
    const enqueued = await waitForSongs(3);               // let the startup sweep settle first
    const before = jobs().length;
    const r = await post('/analyze-timbre', {
      songIds: ['sng_cccccccccccc', 'sng_dddddddddddd', 'sng_aaaaaaaaaaaa', 'sng_unknown'],
    });
    expect(enqueued.length).toBe(3);
    expect(r.requested).toBe(4);
    expect(r.enqueued).toBe(1);                           // c analysed, d no audio, unknown absent
    for (let i = 0; i < 100 && jobs().length === before; i++) await sleep(50);
    expect(jobs().slice(before).flatMap((j) => j.songs.map((s) => s.id))).toEqual(['sng_aaaaaaaaaaaa']);
  }, 20_000);

  it('adding ONLY already-analysed songs sends no message at all', async () => {
    const before = jobs().length;
    const r = await post('/analyze-timbre', { songIds: ['sng_cccccccccccc'] });
    expect(r.enqueued).toBe(0);
    await sleep(400);
    expect(jobs().length).toBe(before);
  });

  it('a worker RESULT reaches DISK — the stamp is in manifest.json, not just in memory', async () => {
    writeFileSync(join(sqsDir, 'pocketdj-timbre-results.inbox.ndjson'), JSON.stringify({
      ok: true, kind: 'timbre', batchId: 'tb_test', timbreVersion: TIMBRE_VERSION, workerSeconds: 12,
      instanceId: 'i-test', songs: [{ id: 'sng_aaaaaaaaaaaa', ok: true, key: `rips/timbre/v${TIMBRE_VERSION}/sng_aaaaaaaaaaaa.json` }],
    }) + '\n');
    for (let i = 0; i < 100; i++) {
      const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
      if (m.sng_aaaaaaaaaaaa?.timbre) break;
      await sleep(100);
    }
    const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
    expect(m.sng_aaaaaaaaaaaa.timbre).toBe(`rips/timbre/v${TIMBRE_VERSION}/sng_aaaaaaaaaaaa.json`);
    expect(m.sng_aaaaaaaaaaaa.timbreVersion).toBe(TIMBRE_VERSION);
    expect(m.sng_aaaaaaaaaaaa.timbreAt).toBeGreaterThan(0);
    // …and WHICH AUDIO produced it, so the corpus's provenance stays recoverable from the manifest.
    expect(m.sng_aaaaaaaaaaaa.timbreSrc).toBe('s3-song');
    // The DELETE follows the durable save, never precedes it — so it lands strictly after the
    // stamp is on disk. Wait for it rather than assuming the two are simultaneous.
    for (let i = 0; i < 50 && !deleted().length; i++) await sleep(100);
    expect(deleted().length).toBeGreaterThan(0);
  }, 30_000);

  it('a result whose songs are ALL unknown is LEFT ON THE QUEUE, never deleted with nothing folded', async () => {
    const before = deleted().length;
    writeFileSync(join(sqsDir, 'pocketdj-timbre-results.inbox.ndjson'), JSON.stringify({
      ok: true, kind: 'timbre', batchId: 'tb_stray', timbreVersion: TIMBRE_VERSION,
      songs: [{ id: 'sng_ffffffffffff', ok: true, key: 'rips/timbre/v1/sng_ffffffffffff.json' }],
    }) + '\n');
    await sleep(1500);
    expect(deleted().length).toBe(before);                 // not deleted → redelivered later
    expect(serverLog).toMatch(/unknown song/);
  }, 20_000);
});
