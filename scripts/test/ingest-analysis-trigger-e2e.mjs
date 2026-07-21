#!/usr/bin/env node
// Test of the CLOUD-ANALYSIS trigger for custom ("My Digital") audio. Two parts, no real S3/SQS:
//
//  Part 1 — the self-healing auto-enqueue in POST /ingest-digital. Boots the real rip-server with
//  a recording `aws` shim (captures every `sqs send-message` body) and fake SQS queue URLs, then
//  POSTs two digital entries — one WITHOUT bpm/analysis, one WITH — and asserts:
//    (a) the response reports analysisQueued === 1 (only the un-analyzed entry);
//    (b) exactly ONE `sqs send-message` lands, an {tasks:['analysis']} job for the bpm-less song;
//    (c) NO analysis job is sent for the entry that already carries bpm (idempotent gate).
//
//  Part 2 — scripts/fold-cloud-analysis.mjs restamps the manifest's cloud bpm/key/camelot back into
//  the DIGITAL catalog index (so Browse cards show BPM), and NEVER clobbers the analog catalog
//  (source guard). Pure Node, temp files, no server.
//
//   node scripts/test/ingest-analysis-trigger-e2e.mjs
import { spawn, execFileSync as exec } from 'node:child_process';
import { writeFileSync, readFileSync, mkdtempSync, mkdirSync, rmSync, existsSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8809;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-ingest-analysis-'));

// ---- minimal (empty) analog catalog so loadCatalog is happy — /ingest-digital creates its own records ----
const catalog = join(work, 'catalog.json');
writeFileSync(catalog, JSON.stringify({ manifest: { sourceType: 'analog', sourceName: 'Vinyl' }, albums: [], songs: [] }));

// ---- recording `aws` shim: prints an empty manifest on load, records every sqs send-message body ----
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const sqsLog = join(work, 'sqs-sends.jsonl');
const shimMjs = join(work, 'fake-aws-record.mjs');
writeFileSync(shimMjs, `
import { appendFileSync } from 'node:fs';
const argv = process.argv.slice(2);
const args = [];
for (let i = 0; i < argv.length; i++) { if (argv[i] === '--profile' || argv[i] === '--region') { i++; continue; } args.push(argv[i]); }
// aws s3 cp s3://.../rips/manifest.json -   → empty manifest (cold cache)
if (args[0] === 's3' && args[1] === 'cp') {
  if (args[3] === '-' && /\\/rips\\/manifest\\.json$/.test(args[2] || '')) { process.stdout.write('{}'); process.exit(0); }
  process.exit(0); // saveManifest / uploads → succeed silently
}
// aws sqs send-message --queue-url X --message-body Y → record Y
if (args[0] === 'sqs' && args[1] === 'send-message') {
  const i = args.indexOf('--message-body');
  if (i >= 0 && args[i + 1]) appendFileSync(${JSON.stringify(sqsLog)}, args[i + 1] + '\\n');
  process.stdout.write(JSON.stringify({ MessageId: 'fake-' + Date.now() }));
  process.exit(0);
}
// aws sqs receive-message … → no messages (keeps pumpStemResults idle-quiet)
if (args[0] === 'sqs' && args[1] === 'receive-message') { process.stdout.write('{}'); process.exit(0); }
process.exit(0);
`);
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(shimMjs)} "$@"\n`);
chmodSync(awsShim, 0o755);

function boot() {
  const env = {
    ...process.env,
    PATH: `${shimDir}:${process.env.PATH}`,
    RIP_PORT: String(PORT),
    RIP_BUCKET: 'pocketdj-test-bucket',
    RIP_SOURCES: catalog,
    // fake SQS URLs so the offload dispatcher targets our recording shim, not real AWS.
    POCKETDJ_STEM_JOBS_QUEUE: 'https://sqs.local/test/jobs',
    POCKETDJ_STEM_RESULTS_QUEUE: 'https://sqs.local/test/results',
    POCKETDJ_STEM_DLQ_QUEUE: 'https://sqs.local/test/dlq',
    HOME: join(work, 'home'),
  };
  return spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
}
const post = async (path, body) => {
  const r = await fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const waitUp = async () => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`${base}/health`)).ok) return true; } catch { /* not up */ } await sleep(200); } return false; };
const readSends = () => (existsSync(sqsLog) ? readFileSync(sqsLog, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);

// A digital entry WITHOUT analysis (must auto-enqueue) and one WITH bpm (must NOT).
const NOAN = 'sng_aaaaaaaaaaaa';   // no bpm → cloud analysis
const HASAN = 'sng_bbbbbbbbbbbb';  // bpm present → skip

let srv;
try {
  srv = boot();
  ok(await waitUp(), 'server up (ingest analysis trigger)');
  await sleep(300);

  const res = await post('/ingest-digital', { entries: [
    { songId: NOAN, key: `rips/${NOAN}.mp3`, source: 'digital', ext: 'mp3', name: 'Unanalyzed', artist: 'Tester' },
    { songId: HASAN, key: `rips/${HASAN}.mp3`, source: 'digital', ext: 'mp3', name: 'Analyzed', artist: 'Tester',
      bpm: 120, musicalKey: 'A minor', camelot: '8A' },
  ] });
  ok(res.status === 200, `(pre) /ingest-digital → 200 (got ${res.status})`);
  ok(res.body?.added === 2, `(pre) both entries added (got ${res.body?.added})`);
  ok(res.body?.analysisQueued === 1, `(a) analysisQueued === 1 — only the bpm-less entry (got ${res.body?.analysisQueued})`);

  // wait for the async offload send(s) to flush to the shim log
  for (let i = 0; i < 40 && readSends().length < 1; i++) await sleep(100);
  const sends = readSends();
  const analysisSends = sends.filter((m) => Array.isArray(m.tasks) && m.tasks.includes('analysis'));
  ok(analysisSends.length === 1, `(b) exactly ONE analysis SQS send (got ${analysisSends.length})`);
  ok(analysisSends.some((m) => m.songId === NOAN && m.srcKey === `rips/${NOAN}.mp3`),
    `(b) analysis job enqueued for the bpm-less song ${NOAN}`);
  ok(!sends.some((m) => m.songId === HASAN), `(c) NO analysis job for the already-analyzed song ${HASAN}`);

  srv.kill('SIGKILL'); srv = null; await sleep(200);

  // ===== Part 2: fold-cloud-analysis restamps digital, never clobbers analog =====
  const foldOut = join(work, 'fold-out');
  const manifestPath = join(work, 'manifest.json');
  writeFileSync(manifestPath, JSON.stringify({
    [NOAN]: { source: 'digital', key: `rips/${NOAN}.mp3`, bpm: 128, musicalKey: 'F minor', camelot: '4A' },
    'sng_cccccccccccc': { source: 'analog', key: 'rips/alb_x.mp3', bpm: null, musicalKey: null }, // analog: no per-song bpm
  }));
  const digIdx = join(work, 'digital-index.json');
  const anaIdx = join(work, 'analog-index.json');
  writeFileSync(digIdx, JSON.stringify({ manifest: {}, albums: [], songs: [
    { id: NOAN, bpm: null, key: null, camelot: null, name: 'Unanalyzed' }] }));
  writeFileSync(anaIdx, JSON.stringify({ manifest: {}, albums: [], songs: [
    { id: 'sng_cccccccccccc', bpm: 90, key: 'C', camelot: '8B', name: 'Curated Analog' }] }));

  exec('node', [join(REPO, 'scripts/fold-cloud-analysis.mjs'), '--apply', '--manifest', manifestPath], {
    env: { ...process.env, POCKETDJ_FOLD_INDEXES: `${digIdx},${anaIdx}`, POCKETDJ_FOLD_OUT: foldOut },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  const dig = JSON.parse(readFileSync(digIdx, 'utf8')).songs[0];
  const ana = JSON.parse(readFileSync(anaIdx, 'utf8')).songs[0];
  ok(dig.bpm === 128 && dig.key === 'F minor' && dig.camelot === '4A',
    `(d) digital card restamped from cloud manifest (bpm=${dig.bpm} key=${dig.key} camelot=${dig.camelot})`);
  ok(ana.bpm === 90 && ana.key === 'C' && ana.camelot === '8B',
    `(e) analog catalog NOT clobbered by the fold (bpm=${ana.bpm} key=${ana.key} camelot=${ana.camelot})`);

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all ingest-analysis-trigger checks passed'}`);
} finally {
  if (srv) srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
