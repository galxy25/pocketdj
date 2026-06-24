#!/usr/bin/env node
// End-to-end test of the "Rip from cloud source" routing — the ripFromCloud flag on
// POST /rip + /rip-collection. Boots the real rip-server (no Audio Hijack / Music / S3)
// with a temp catalog, a fake `aws` shim, a synthetic Apple Music library XML, a real
// analog source file (ffmpeg sine tone), and a SELECTABLE fake digital worker, then
// asserts:
//   (1) flag ACCEPTED on both endpoints (no 400).
//   (2) acceptRip cloud routing: an ANALOG song that EXACT-matches the library, with
//       ripFromCloud:true, becomes a PER-SONG cloud job (resourceKey=songId) — its
//       album sibling does NOT inflight-join it (they would under the per-album key).
//   (3) NO-match analog song with ripFromCloud:true falls back to analog at ACCEPT time
//       (Tier 1) — it shares the per-album queue with a sibling (inflight join).
//   (4) ripFromCloud:false → analog song stays per-album even when it DOES match.
//   (5) cloud SUCCESS: matched analog + uploading worker → manifest entry source:'digital',
//       key rips/<songId>.mp3, startMs:null (indistinguishable from a real digital rip).
//   (6) Tier-2 FALLBACK: matched analog + a worker that never uploads → server falls back
//       to the analog vinyl path → manifest entry source:'analog', key rips/<albumId>.mp3,
//       per-song startMs preserved; exactly one inflight key during the run.
//
//   node scripts/test/rip-cloud-e2e.mjs
import { spawn, execFileSync as exec } from 'node:child_process';
import { writeFileSync, mkdtempSync, mkdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8803;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-ripcloud-'));

// ---- catalog: an analog album with two songs; A is in the library (exact), B is not ----
const ALB = 'alb_cloud1';
const A = 'sng_cloud_a';   // EXACT library match → cloud-eligible
const B = 'sng_cloud_b';   // NOT in library → analog fallback
const analogCatalog = join(work, 'analog.json');
writeFileSync(analogCatalog, JSON.stringify({
  manifest: { sourceType: 'analog', sourceName: 'Vinyl' },
  albums: [
    { id: ALB, artist: 'Cloud Tester', name: 'Cloud Album',
      pointer: { originalFilename: 'cloud-src.wav' }, trackList: [A, B] },
  ],
  songs: [
    { id: A, albumId: ALB, artist: 'Cloud Tester', name: 'Matched Track', length: 6000, pointer: { startMs: 0 } },
    { id: B, albumId: ALB, artist: 'Cloud Tester', name: 'Unmatched Track', length: 6000, pointer: { startMs: 6000 } },
  ],
}));

// ---- synthetic Apple Music library XML: contains ONLY "Cloud Tester – Matched Track" ----
// loadLibraryXML parses one <key>…</key><string>…</string> per line inside a <dict>.
const libXml = join(work, 'Library.xml');
writeFileSync(libXml, [
  '<plist><dict><key>Tracks</key><dict><dict>',
  '<key>Name</key><string>Matched Track</string>',
  '<key>Artist</key><string>Cloud Tester</string>',
  '<key>Album</key><string>Cloud Album</string>',
  '<key>Persistent ID</key><string>ABC123</string>',
  '</dict></dict></dict></plist>',
].join('\n'));

// ---- a real analog source file so the (Tier-2 + analog) ffmpeg transcode succeeds ----
const analogBase = join(work, 'analog-src');
mkdirSync(analogBase, { recursive: true });
exec('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
  'sine=frequency=440:duration=2', join(analogBase, 'cloud-src.wav')]);

// ---- fake `aws` shim ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(join(REPO, 'scripts/test/fake-aws.mjs'))} "$@"\n`);
chmodSync(awsShim, 0o755);

// ---- two fake digital workers: one that UPLOADS (cloud success), one that FAILS (Tier-2) ----
// The server reads the worker's status file; phase 'uploaded' + key = success.
const uploadWorker = join(work, 'worker-upload.mjs');
writeFileSync(uploadWorker, `
import { writeFileSync } from 'node:fs';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
const key = 'rips/'+a['song-id']+'.mp3';
writeFileSync(a.status, JSON.stringify({ songId:a['song-id'], phase:'uploaded', key, bytes:4242, updatedAt:Date.now() }));
console.log('RESULT '+JSON.stringify({ ok:true, key, bytes:4242 }));
`);
const failWorker = join(work, 'worker-fail.mjs');
writeFileSync(failWorker, `
import { writeFileSync } from 'node:fs';
const a = {}; for (let i=2;i<process.argv.length;i++){const k=process.argv[i];if(k.startsWith('--'))a[k.slice(2)]=process.argv[++i];}
writeFileSync(a.status, JSON.stringify({ songId:a['song-id'], phase:'error', error:'no audio captured', reason:'no-match', updatedAt:Date.now() }));
console.log('RESULT '+JSON.stringify({ ok:false, error:'no audio captured', reason:'no-match' }));
`);

function boot(worker) {
  const env = {
    ...process.env,
    PATH: `${shimDir}:${process.env.PATH}`,
    RIP_PORT: String(PORT),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: analogCatalog,
    RIP_WORKER: worker,
    POCKETDJ_LIBRARY_XML: libXml,
    POCKETDJ_ANALOG_BASE: analogBase,
    HOME: join(work, `home-${Math.random().toString(36).slice(2)}`),
  };
  return spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
}

const post = async (path, body) => {
  const r = await fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const getStatus = async (songId) => (await fetch(`${base}/status/${songId}`)).json();
const waitUp = async () => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`${base}/health`)).ok) return true; } catch {} await sleep(200); } return false; };
const waitReady = async (songId, ms = 15000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { const s = await getStatus(songId); if (s.ready) return s; await sleep(200); }
  return await getStatus(songId);
};

let srv;
try {
  // ===== Part 1: routing (worker that uploads — so cloud success is observable) =====
  srv = boot(uploadWorker);
  ok(await waitUp(), 'server up (cloud routing, upload worker)');
  await sleep(400); // let warmLibIndex's setImmediate parse the XML

  // (2)+(3): collection with both songs, ripFromCloud:true.
  //   A matches → per-SONG cloud job; B no-match → per-ALBUM analog → they must NOT join.
  const col = await post('/rip-collection', { songIds: [A, B], ripFromCloud: true });
  ok(col.status === 200, `(1) /rip-collection accepts ripFromCloud → 200 (got ${col.status})`);
  const ra = col.body.results.find((x) => x.songId === A);
  const rb = col.body.results.find((x) => x.songId === B);
  ok(ra?.status === 'queued', `(2) matched analog A → 'queued' (got ${ra?.status})`);
  ok(rb?.status === 'queued', `(3) unmatched analog B → 'queued' (got ${rb?.status})`);
  ok(ra && rb && ra.jobId !== rb.jobId,
    `(2/3) matched-cloud A and analog B have SEPARATE jobs (no per-album join): ${ra?.jobId} != ${rb?.jobId}`);

  // (5) cloud success: A uploads → manifest source:'digital', key rips/<A>.mp3, startMs null
  const sA = await waitReady(A);
  ok(sA.ready === true, `(5) matched analog A becomes ready (cloud) (ready=${sA.ready})`);
  ok(sA.entry?.source === 'digital', `(5) A manifest source==='digital' (got ${sA.entry?.source})`);
  ok(sA.entry?.key === `rips/${A}.mp3`, `(5) A key === rips/${A}.mp3 (got ${sA.entry?.key})`);
  ok(sA.entry?.startMs === null, `(5) A startMs === null (per-song file, no album offset) (got ${sA.entry?.startMs})`);

  // B (no cloud) ripped via analog: source:'analog', key rips/<ALB>.mp3, per-song startMs
  const sB = await waitReady(B);
  ok(sB.entry?.source === 'analog', `(3) unmatched B manifest source==='analog' (got ${sB.entry?.source})`);
  ok(sB.entry?.key === `rips/${ALB}.mp3`, `(3) B key === rips/${ALB}.mp3 (analog per-album) (got ${sB.entry?.key})`);
  srv.kill('SIGKILL'); srv = null; await sleep(300);

  // ===== Part 2: ripFromCloud:false → matched song stays per-album analog =====
  srv = boot(uploadWorker);
  ok(await waitUp(), 'server up (flag-off routing)');
  await sleep(400);
  const offCol = await post('/rip-collection', { songIds: [A, B] }); // no flag
  const offA = offCol.body.results.find((x) => x.songId === A);
  const offB = offCol.body.results.find((x) => x.songId === B);
  const phases = [offA?.status, offB?.status].sort().join(',');
  ok(phases === 'inflight,queued', `(4) flag off: A+B share per-album queue (one queued, one inflight) (got ${phases})`);
  ok(offA?.jobId === offB?.jobId, `(4) flag off: A and B share ONE album job (${offA?.jobId})`);
  const offSA = await waitReady(A);
  ok(offSA.entry?.source === 'analog' && offSA.entry?.key === `rips/${ALB}.mp3`,
    `(4) flag off: matched A still rips ANALOG (source=${offSA.entry?.source}, key=${offSA.entry?.key})`);
  srv.kill('SIGKILL'); srv = null; await sleep(300);

  // ===== Part 3: Tier-2 fallback — matched A, worker that NEVER uploads → analog vinyl =====
  srv = boot(failWorker);
  ok(await waitUp(), 'server up (Tier-2 fallback, failing worker)');
  await sleep(400);
  const t2 = await post('/rip', { songId: A, ripFromCloud: true });
  ok(t2.status === 200, `(6) /rip accepts ripFromCloud → 200 (got ${t2.status})`);
  const sT2 = await waitReady(A);
  ok(sT2.ready === true, `(6) A becomes ready via Tier-2 analog fallback (ready=${sT2.ready})`);
  ok(sT2.entry?.source === 'analog', `(6) Tier-2 manifest source==='analog' (got ${sT2.entry?.source})`);
  ok(sT2.entry?.key === `rips/${ALB}.mp3`, `(6) Tier-2 key === rips/${ALB}.mp3 (analog per-album) (got ${sT2.entry?.key})`);
  ok(sT2.entry?.startMs === 0, `(6) Tier-2 preserves per-song startMs (got ${sT2.entry?.startMs})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all rip-cloud checks passed'}`);
} finally {
  if (srv) srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
