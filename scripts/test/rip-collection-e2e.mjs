#!/usr/bin/env node
// End-to-end test of POST /rip-collection — the Feature 2 batch-rip endpoint. Boots the
// real rip-server (no Audio Hijack, no Music) with a temp catalog, a fake `aws` shim
// (deterministic seeded manifest, zero real S3), and the fake HLS worker, then asserts
// the per-song outcome array + counts object for every classification:
//   (a) unknown songId            → 'unknown'
//   (b) already-ripped song       → 'ready' (+ public url)
//   (c) fresh song                → 'queued' (newly enqueued, jobId present)
//   (d) 2nd song of SAME analog album → 'inflight' (single queue file per album; joins job)
//   (e) endpoint works WITHOUT a token (public — owner decision)
//   (f) a large batch (600 ids) is ACCEPTED with no 413 (no cap)
//   (g) empty array → empty results + zero counts
//
//   node scripts/test/rip-collection-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, mkdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8801;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-ripcol-'));

// ---- catalog: an analog album with two songs (shared albumId → shared queue) + a digital song ----
const ANALOG_ALBUM = 'alb_analog1';
const ANALOG_A = 'sng_analog_a';   // fresh → queued (creates the album job)
const ANALOG_B = 'sng_analog_b';   // same album → inflight (joins it)
const DIGITAL_FRESH = 'sng_digital_fresh'; // fresh digital → queued
const RIPPED = 'sng_already_ripped';       // pre-seeded in manifest → ready
const UNKNOWN = 'sng_does_not_exist';      // not in catalog → unknown

// The catalog loader stamps sourceType from each index's manifest.sourceType onto every
// record (it spreads the loader's value AFTER the record, overriding per-record fields),
// so analog vs digital must live in SEPARATE source files. The server reads them via the
// comma-joined RIP_SOURCES list.
const analogCatalog = join(work, 'analog.json');
writeFileSync(analogCatalog, JSON.stringify({
  manifest: { sourceType: 'analog', sourceName: 'Vinyl' },
  albums: [
    { id: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog Album',
      pointer: { originalFilename: 'does-not-exist.flac' }, trackList: [ANALOG_A, ANALOG_B] },
  ],
  songs: [
    { id: ANALOG_A, albumId: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog A', length: 6000, pointer: { startMs: 0 } },
    { id: ANALOG_B, albumId: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog B', length: 6000, pointer: { startMs: 6000 } },
  ],
}));
const digitalCatalog = join(work, 'digital.json');
writeFileSync(digitalCatalog, JSON.stringify({
  manifest: { sourceType: 'digital', sourceName: 'Test' },
  albums: [
    { id: 'alb_dig', artist: 'Digi', name: 'Digital Album', trackList: [DIGITAL_FRESH, RIPPED] },
  ],
  songs: [
    { id: DIGITAL_FRESH, albumId: 'alb_dig', artist: 'Digi', name: 'Digital Fresh', length: 6000 },
    { id: RIPPED, albumId: 'alb_dig', artist: 'Digi', name: 'Already Ripped', length: 6000 },
  ],
}));

// ---- seeded manifest: one already-ripped song so case (b) is deterministic ----
const RIPPED_KEY = 'rips/alb_dig_already.mp3';
const seedManifest = join(work, 'seed-manifest.json');
writeFileSync(seedManifest, JSON.stringify({
  [RIPPED]: { key: RIPPED_KEY, ext: 'mp3', bytes: 123456, source: 'digital', albumId: 'alb_dig', startMs: null, durationMs: 6000, rippedAt: 1700000000000 },
}));

// ---- fake `aws` shim on PATH (delegates to fake-aws.mjs) ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
chmodSync(awsShim, 0o755);

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  // NO RIP_TOKEN → server runs PUBLIC (case e). authed() returns true for every request.
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: `${analogCatalog},${digitalCatalog}`,
  RIP_WORKER: join(REPO, 'scripts/test/fake-rip-worker.mjs'),
  FAKE_AWS_MANIFEST: seedManifest,
  FAKE_HLS_SECONDS: '6',
  HOME: join(work, 'home'), // isolate ~/.pocketdj (jobs + durable queue under here)
};

console.log('booting rip-server (fake aws + fake worker, TOKENLESS)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });

const postCollection = async (songIds, headers = {}) => {
  const r = await fetch(`${base}/rip-collection`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ songIds }),
  });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const byId = (results, id) => results.find((x) => x.songId === id);

try {
  // wait for server (NO auth header — proves the endpoint is public)
  let up = false;
  for (let i = 0; i < 50; i++) { try { const r = await fetch(`${base}/health`); if (r.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
  ok(up, 'server is up (/health, no token)');

  // confirm the seeded manifest loaded (case b precondition)
  const health = await (await fetch(`${base}/health`)).json();
  ok(health.cached === 1, `seeded manifest loaded (cached=${health.cached})`);
  ok(health.auth === false, `server is PUBLIC (auth=${health.auth})`);

  // ---- main batch: covers (a) unknown, (b) ready, (c) queued, (d) inflight, (e) no token ----
  const ids = [UNKNOWN, RIPPED, DIGITAL_FRESH, ANALOG_A, ANALOG_B];
  const { status, body } = await postCollection(ids); // NO Authorization header
  ok(status === 200, `POST /rip-collection (no token) → 200 (got ${status})`);
  const results = body?.results || [];
  ok(results.length === ids.length, `results has one entry per id (${results.length}/${ids.length})`);

  // (a) unknown
  const u = byId(results, UNKNOWN);
  ok(u && u.status === 'unknown', `(a) unknown songId → 'unknown' (got ${u?.status})`);
  ok(u && u.jobId === null && u.url === null, '(a) unknown has no jobId / url');

  // (b) already-ripped
  const r = byId(results, RIPPED);
  ok(r && r.status === 'ready', `(b) already-ripped → 'ready' (got ${r?.status})`);
  ok(r && typeof r.url === 'string' && r.url.includes(RIPPED_KEY), `(b) ready carries the public url (${r?.url})`);

  // (c) fresh digital
  const d = byId(results, DIGITAL_FRESH);
  ok(d && d.status === 'queued', `(c) fresh song → 'queued' (got ${d?.status})`);
  ok(d && typeof d.jobId === 'string', '(c) queued carries a jobId');

  // (d) two songs of the SAME analog album: first 'queued', second 'inflight' (shared album queue)
  const a1 = byId(results, ANALOG_A);
  const a2 = byId(results, ANALOG_B);
  // exactly one of the album pair is the queue-creator, the other joins it (order-independent)
  const phases = [a1?.status, a2?.status].sort().join(',');
  ok(phases === 'inflight,queued', `(d) same-album pair → one 'queued' + one 'inflight' (got ${phases})`);
  ok(a1 && a2 && a1.jobId === a2.jobId, `(d) both album songs share ONE jobId (single queue per album) (${a1?.jobId} == ${a2?.jobId})`);

  // ---- counts object reflects the batch ----
  const c = body?.counts || {};
  ok(c.total === 5, `counts.total === 5 (got ${c.total})`);
  ok(c.unknown === 1, `counts.unknown === 1 (got ${c.unknown})`);
  ok(c.ready === 1, `counts.ready === 1 (got ${c.ready})`);
  ok(c.queued === 2, `counts.queued === 2 [digital + analog-A] (got ${c.queued})`);
  ok(c.inflight === 1, `counts.inflight === 1 [analog-B] (got ${c.inflight})`);
  ok((c.ready + c.queued + c.inflight + c.unknown) === c.total, 'counts buckets sum to total');

  // ---- (f) large batch (600 ids) ACCEPTED, no 413, no cap ----
  const big = Array.from({ length: 600 }, (_, i) => `sng_bulk_${i}`); // all unknown → fine for cap test
  const bigRes = await postCollection(big);
  ok(bigRes.status === 200, `(f) 600-id batch → 200, NOT 413 (got ${bigRes.status})`);
  ok((bigRes.body?.results || []).length === 600, `(f) 600 results returned (${bigRes.body?.results?.length})`);
  ok(bigRes.body?.counts?.total === 600, `(f) counts.total === 600 (got ${bigRes.body?.counts?.total})`);
  ok(bigRes.body?.counts?.unknown === 600, `(f) all 600 classified unknown (got ${bigRes.body?.counts?.unknown})`);

  // a duplicate id within one request is deduped (Set) — sanity that the no-cap path still dedupes
  const dup = await postCollection([DIGITAL_FRESH, DIGITAL_FRESH, DIGITAL_FRESH]);
  ok((dup.body?.results || []).length === 1, `duplicate ids deduped within a request (${dup.body?.results?.length})`);

  // ---- (g) empty array → empty results + zero counts ----
  const empty = await postCollection([]);
  ok(empty.status === 200, `(g) empty array → 200 (got ${empty.status})`);
  ok((empty.body?.results || []).length === 0, `(g) empty results (${empty.body?.results?.length})`);
  const ec = empty.body?.counts || {};
  ok(ec.total === 0 && ec.ready === 0 && ec.queued === 0 && ec.inflight === 0 && ec.unknown === 0,
    `(g) all counts zero (${JSON.stringify(ec)})`);

  // missing/non-array songIds is also treated as empty (defensive)
  const missing = await postCollection(undefined);
  ok(missing.status === 200 && (missing.body?.results || []).length === 0, 'missing songIds → empty results (defensive)');

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all rip-collection checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
