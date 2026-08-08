#!/usr/bin/env node
// End-to-end regression for VARIANT-RIP CANCEL ISOLATION (explicit/clean edition rips).
//
// A variant row is synthesized by spreading its BASE catalog row (resolveVariantRow), so a
// variant of an ANALOG song inherits the base's albumId — but acceptRip always keys variant
// jobs PER-SONG (sourceType 'digital'). cancelOne therefore must never probe the albumId key
// for a variant: any albumId hit is by construction a DIFFERENT job — the whole-album vinyl
// rip — and canceling a variant would kill that unrelated capture mid-recording.
//
//   (a) a variant's own job IS cancelable (the fix must not over-restrict)
//   (b) a SECOND cancel of the same variant (own job already gone — the routine
//       terminally-failed / already-canceled state) → 'notFound', and the analog album
//       job SURVIVES  [the bug: 'canceled' + the vinyl capture is killed]
//   (c) the /rip-cancel album-first FILL never reports 'canceled' for a variant sibling
//       off its base album's cancellation
//
//   node scripts/test/rip-variant-cancel-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, mkdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8813;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-variantcancel-'));

// ---- catalog: ONE analog album, two songs. Ids must be sng_<12 hex> so VARIANT_ID parses. ----
const ANALOG_ALBUM = 'alb_vinyl01';
const ANALOG_A = 'sng_aaaaaaaaaaaa';
const ANALOG_B = 'sng_bbbbbbbbbbbb';
const VARIANT = `${ANALOG_A}_clean`; // the cleanOnly substitution's rip key

const analogCatalog = join(work, 'analog.json');
writeFileSync(analogCatalog, JSON.stringify({
  manifest: { sourceType: 'analog', sourceName: 'Vinyl' },
  albums: [
    // pointer PRESENT but the file is absent → 'analog file not found' → a TRANSIENT failure,
    // which re-holds inflight[albumId] across a long backoff. That is the deterministic way to
    // park a live album job for the whole test without a real vinyl capture.
    { id: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog Album',
      pointer: { originalFilename: 'not-on-disk.flac' }, trackList: [ANALOG_A, ANALOG_B] },
  ],
  songs: [
    { id: ANALOG_A, albumId: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog A', length: 6000, explicit: true, pointer: { startMs: 0 } },
    { id: ANALOG_B, albumId: ANALOG_ALBUM, artist: 'Vinyl Tester', name: 'Analog B', length: 6000, pointer: { startMs: 6000 } },
  ],
}));

// ---- fake `aws` shim on PATH (nothing should reach S3 here, but never risk it) ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
chmodSync(awsShim, 0o755);

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: analogCatalog,
  RIP_WORKER: join(REPO, 'scripts/test/fake-rip-worker.mjs'),
  FAKE_HLS_SECONDS: '30',            // the variant capture stays live across the cancel
  POCKETDJ_ANALOG_BASE: join(work, 'no-vinyl-here'), // guarantees the not-found failure
  RIP_PUBLIC_FOLD: '0',              // never touch the repo's public/*.json
  RIP_TEST_BACKOFF_MS: '600000',     // 10 min: one failure, then inflight parked for the test
  HOME: join(work, 'home'),          // isolate ~/.pocketdj (jobs + durable queue)
};

console.log('booting rip-server (fake aws + fake worker, TOKENLESS)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });

const post = async (path, body) => {
  const r = await fetch(`${base}${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const rip = (songId) => post('/rip', { songId });
const cancel = (songIds) => post('/rip-cancel', { songIds });
const cancelStatus = (res, songId) => (res.body?.results || []).find((x) => x.songId === songId)?.status;

try {
  let up = false;
  for (let i = 0; i < 50; i++) { try { const r = await fetch(`${base}/health`); if (r.ok) { up = true; break; } } catch { /* not yet */ } await sleep(200); }
  ok(up, 'server is up (/health, no token)');

  // ---- park a live ALBUM job: enqueue the analog song, let it fail transiently, and confirm
  //      the album resource is still held (a sibling of the same album joins it) ----
  const a = await rip(ANALOG_A);
  ok(a.status === 200 && typeof a.body?.jobId === 'string', `analog rip enqueued (${a.status}, job ${a.body?.jobId})`);
  let sib = null;
  for (let i = 0; i < 40; i++) { sib = await rip(ANALOG_B); if (sib.body?.phase && sib.body?.jobId) break; await sleep(100); }
  const albumJobId = sib.body?.jobId;
  ok(!!albumJobId, `album job is inflight — the sibling joined it (job ${albumJobId})`);

  // ---- the variant rides its OWN per-song job (never the album's) ----
  const v = await rip(VARIANT);
  ok(v.status === 200, `POST /rip ${VARIANT} → 200 (got ${v.status})`);
  ok(typeof v.body?.jobId === 'string' && v.body.jobId !== albumJobId,
    `variant got its OWN job, not the album's (${v.body?.jobId} != ${albumJobId})`);

  // ---- (a) the variant's own job IS cancelable ----
  const c1 = await cancel([VARIANT]);
  ok(cancelStatus(c1, VARIANT) === 'canceled', `(a) variant's own job cancels (got ${cancelStatus(c1, VARIANT)})`);

  // wait for it to reach a terminal phase (the canceled-guard's fail() releases inflight)
  let settled = false;
  for (let i = 0; i < 60; i++) {
    const s = await (await fetch(`${base}/status/${encodeURIComponent(VARIANT)}`)).json().catch(() => null);
    if (s && !s.ready && s.job === null) { settled = true; break; }
    await sleep(200);
  }
  ok(settled, 'variant job reached a terminal phase (inflight released)');

  // ---- (b) THE REGRESSION: a second cancel must NOT fall through to the base's albumId ----
  const c2 = await cancel([VARIANT]);
  ok(cancelStatus(c2, VARIANT) === 'notFound',
    `(b) 2nd cancel of the variant → 'notFound', never the album's job (got ${cancelStatus(c2, VARIANT)})`);
  const stillThere = await rip(ANALOG_B);
  ok(stillThere.body?.jobId === albumJobId,
    `(b) the analog ALBUM job survived the variant cancel (${stillThere.body?.jobId} == ${albumJobId})`);

  // ---- (c) album-first fill never covers a variant sibling ----
  const c3 = await cancel([ANALOG_A, VARIANT]);
  ok(cancelStatus(c3, ANALOG_A) === 'canceled', `(c) the album job itself cancels (got ${cancelStatus(c3, ANALOG_A)})`);
  ok(cancelStatus(c3, VARIANT) === 'notFound',
    `(c) variant is NOT filled 'canceled' off its base album (got ${cancelStatus(c3, VARIANT)})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all variant-cancel checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
