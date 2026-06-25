#!/usr/bin/env node
// End-to-end test of ITEM 10 (CRITIC-H): the rip-server IN-PROCESS fold of a cloud-analog
// analysis into public/current-index.json. Boots the real rip-server with a temp ANALOG
// catalog (also used as RIP_PUBLIC_INDEX), a synthetic Apple Music library XML, and the
// fake `aws` shim, then drives analysis via POST /analysis (deterministic — no Docker /
// librosa / ffmpeg) and asserts:
//   (1) a cloud-analog analysis (digital + analyzed, EXACT am-match to an analog catalog
//       song) folds bpm/key/camelot/length into the public index with CLOUD PRECEDENCE,
//       and stamps index.manifest.cloudReindex + a per-song cloudReindex provenance.
//   (2) a NON-exact (loose / no-match) analog song is NEVER overwritten by the fold.
//   (3) the fold is EXACTLY-ONCE per change: an idempotent re-submit (same values) does
//       NOT rewrite the file (no change → no write; mtime + content stable).
//   (4) NO deploy / CloudFront invalidation is triggered (the fake `aws` records every
//       invocation; the fold must never call `aws cloudfront` or `aws s3 sync`).
//
//   node scripts/test/rip-public-fold-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, readFileSync, statSync, mkdtempSync, mkdirSync, rmSync, chmodSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8807;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-publicfold-'));

// ---- analog catalog (also the RIP_PUBLIC_INDEX the fold writes into) ----
// A = EXACT library match, suspect analog bpm/key/length → must be cloud-overwritten.
// B = NOT in the library (no match) → must NEVER be touched by the fold.
const ALB = 'alb_fold1';
const A = 'sng_fold_a';
const B = 'sng_fold_b';
const ANALOG_BPM = 111, ANALOG_KEY = 'C major', ANALOG_CAMELOT = '8B', ANALOG_LEN = 200000;
const CLOUD_BPM = 128, CLOUD_KEY = 'A minor', CLOUD_CAMELOT = '8A', CLOUD_LEN = 222000;
const publicIndex = join(work, 'current-index.json');
function writePublicIndex() {
  writeFileSync(publicIndex, JSON.stringify({
    manifest: { sourceType: 'analog', sourceName: 'My Vinyl' },
    albums: [{ id: ALB, artist: 'Fold Tester', name: 'Fold Album', pointer: { originalFilename: 'fold-src.wav' }, trackList: [A, B] }],
    songs: [
      { id: A, albumId: ALB, artist: 'Fold Tester', name: 'Matched Track', bpm: ANALOG_BPM, key: ANALOG_KEY, camelot: ANALOG_CAMELOT, length: ANALOG_LEN, pointer: { startMs: 0 } },
      { id: B, albumId: ALB, artist: 'Fold Tester', name: 'Unmatched Track', bpm: 99, key: 'D major', camelot: '10B', length: 180000, pointer: { startMs: 200000 } },
    ],
  }));
}
writePublicIndex();

// ---- synthetic Apple Music library XML: ONLY "Fold Tester – Matched Track" (Total Time = cloud length) ----
const libXml = join(work, 'Library.xml');
writeFileSync(libXml, [
  '<plist><dict><key>Tracks</key><dict><dict>',
  '<key>Name</key><string>Matched Track</string>',
  '<key>Artist</key><string>Fold Tester</string>',
  '<key>Album</key><string>Fold Album</string>',
  '<key>Persistent ID</key><string>FOLD123</string>',
  `<key>Total Time</key><integer>${CLOUD_LEN}</integer>`,
  '</dict></dict></dict></plist>',
].join('\n'));

// ---- fake `aws` shim that ALSO records every invocation to a log (deploy-detection) ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsLog = join(work, 'aws-calls.log');
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\necho "$@" >> ${JSON.stringify(awsLog)}\nexec node ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
chmodSync(awsShim, 0o755);

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: publicIndex,           // catalog the server resolves songs from
  RIP_PUBLIC_INDEX: publicIndex,      // the analog catalog the fold writes into (temp — never the repo file)
  POCKETDJ_LIBRARY_XML: libXml,
  RIP_TEST_FOLD_DEBOUNCE_MS: '150',   // shrink the trailing debounce so the test is fast
  HOME: join(work, 'home'),
};

const post = async (path, body) => {
  const r = await fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const waitUp = async () => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`${base}/health`)).ok) return true; } catch {} await sleep(200); } return false; };
const readPub = () => JSON.parse(readFileSync(publicIndex, 'utf8'));
const songOf = (idx, id) => (idx.songs || []).find((s) => s.id === id);
// wait until song A reflects the cloud bpm (the fold landed), or time out.
const waitFold = async (ms = 6000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { if (songOf(readPub(), A).bpm === CLOUD_BPM) return true; } catch {} await sleep(100); }
  return false;
};

let srv;
try {
  srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
  ok(await waitUp(), 'server up');
  await sleep(500); // let warmLibIndex's setImmediate parse the synthetic XML

  // ---- (1) cloud-analog analysis folds with cloud precedence ----
  // Submit a DIGITAL analysis for A's own id (a cloud rip of the vinyl track). This creates
  // a manifest entry source:'digital', analyzed:true, which triggers the in-process fold.
  const r1 = await post('/analysis', {
    songId: A, key: `rips/${A}.mp3`, source: 'digital',
    bpm: CLOUD_BPM, musicalKey: CLOUD_KEY, camelot: CLOUD_CAMELOT, durationMs: 999999,
  });
  ok(r1.status === 200 && r1.body?.ok, `(setup) POST /analysis accepted (status ${r1.status})`);

  ok(await waitFold(), '(1) fold landed: song A bpm reflects the CLOUD value');
  let pub = readPub();
  const a = songOf(pub, A);
  ok(a.bpm === CLOUD_BPM, `(1) A.bpm cloud-overwritten ${ANALOG_BPM} → ${CLOUD_BPM} (got ${a.bpm})`);
  ok(a.key === CLOUD_KEY, `(1) A.key cloud-overwritten → ${CLOUD_KEY} (got ${a.key})`);
  ok(a.camelot === CLOUD_CAMELOT, `(1) A.camelot cloud-overwritten → ${CLOUD_CAMELOT} (got ${a.camelot})`);
  ok(a.length === CLOUD_LEN, `(1) A.length cloud-overwritten (AM Total Time) → ${CLOUD_LEN} (got ${a.length})`);
  ok(Array.isArray(a.cloudReindex?.fields) && a.cloudReindex.fields.includes('bpm'),
    `(1) A carries cloudReindex provenance (fields=${a.cloudReindex?.fields})`);
  ok(!!pub.manifest?.cloudReindex && pub.manifest.cloudReindex.changed >= 1,
    `(1) index.manifest.cloudReindex stamp present (changed=${pub.manifest?.cloudReindex?.changed})`);

  // ---- (2) the non-matching analog song B is never touched ----
  const b = songOf(pub, B);
  ok(b.bpm === 99 && b.key === 'D major' && b.camelot === '10B' && b.length === 180000,
    `(2) unmatched B untouched (bpm=${b.bpm} key=${b.key} camelot=${b.camelot} len=${b.length})`);
  ok(!b.cloudReindex, '(2) unmatched B has NO cloudReindex provenance');

  // ---- (3) idempotent: re-submitting the SAME analysis does not rewrite the file ----
  const mtimeBefore = statSync(publicIndex).mtimeMs;
  await sleep(50);
  const r2 = await post('/analysis', {
    songId: A, key: `rips/${A}.mp3`, source: 'digital',
    bpm: CLOUD_BPM, musicalKey: CLOUD_KEY, camelot: CLOUD_CAMELOT,
  });
  ok(r2.status === 200, '(3) idempotent re-submit accepted');
  await sleep(600); // > debounce; a fold would have fired by now if it were going to write
  const mtimeAfter = statSync(publicIndex).mtimeMs;
  ok(mtimeAfter === mtimeBefore, `(3) idempotent re-run did NOT rewrite the file (mtime stable)`);

  // ---- (4) no deploy / CloudFront invalidation was ever triggered ----
  const awsCalls = existsSync(awsLog) ? readFileSync(awsLog, 'utf8') : '';
  ok(!/cloudfront/i.test(awsCalls), '(4) no `aws cloudfront` invalidation was triggered');
  ok(!/\bs3 sync\b/i.test(awsCalls), '(4) no `aws s3 sync` deploy was triggered');

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all rip-public-fold checks passed'}`);
} finally {
  if (srv) srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
