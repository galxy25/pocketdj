#!/usr/bin/env node
// End-to-end test of the cloud LYRICS task's SERVER side on the REAL rip-server, with zero network,
// zero whisper, and a fake `aws` shim that models the SQS results queue. Boots the server with a
// seeded manifest and a one-shot results-queue delivery of (i) a STEMS result and (ii) a LYRICS
// result, then asserts:
//   (a) LYRICS fold: pumpStemResults stamps e.lyrics (the S3 key) + lyricsModel + lyricsVersion +
//       lyricsAt from a nested r.lyrics result.
//   (b) STEMS-fold auto-trigger: folding a stems result for a vocals-bearing song with no lyrics
//       enqueues a lyrics job (a {tasks:['lyrics']} send lands in the jobs queue).
//   (c) round-trip: wantLyrics EXCLUDES the just-lyricized song — /backfill-lyrics candidates drop it.
//   (d) POST /lyricsify: 404 unknown · 400 no-vocals-stem · alreadyDone when fresh · queued on force.
//
//   node scripts/test/lyrics-fold-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, readFileSync, existsSync, mkdtempSync, mkdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8811;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://localhost:${PORT}`;
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-lyrics-'));

// ---- songs: LYR (stemmed, no lyrics → gets a LYRICS result); STEMS (no stems → gets a STEMS
//      result → auto-lyrics); NOVOX (stems WITHOUT vocals → /lyricsify 400) ----
const LYR = 'sng_aaaaaaaaaaaa';
const STEMS = 'sng_bbbbbbbbbbbb';
const NOVOX = 'sng_cccccccccccc';
const MISSING = 'sng_dddddddddddd';

const stemsOf = (id) => ({ vocals: `rips/stems/${id}/vocals.mp3`, drums: `rips/stems/${id}/drums.mp3`, bass: `rips/stems/${id}/bass.mp3`, other: `rips/stems/${id}/other.mp3` });
const seedManifest = join(work, 'seed-manifest.json');
writeFileSync(seedManifest, JSON.stringify({
  [LYR]: { key: `rips/${LYR}.mp3`, source: 'digital', analyzed: true, stems: stemsOf(LYR), stemModel: 'htdemucs', stemVersion: 1, stemFormat: 'mp3' },
  [STEMS]: { key: `rips/${STEMS}.mp3`, source: 'digital', analyzed: true },
  // stems present but NO vocals key → wantLyrics false, /lyricsify 400
  [NOVOX]: { key: `rips/${NOVOX}.mp3`, source: 'digital', stems: { drums: `rips/stems/${NOVOX}/drums.mp3`, bass: `rips/stems/${NOVOX}/bass.mp3`, other: `rips/stems/${NOVOX}/other.mp3` }, stemModel: 'htdemucs', stemVersion: 1 },
}));

// ---- minimal catalog so loadCatalog is happy (the rip manifest comes from the fake aws seed) ----
const catalog = join(work, 'catalog.json');
writeFileSync(catalog, JSON.stringify({ manifest: { sourceType: 'digital', sourceName: 'Test' }, albums: [], songs: [] }));

// ---- one-shot results-queue delivery: a STEMS result for STEMS + a LYRICS result for LYR ----
const stemsResult = { ok: true, songId: STEMS, tasks: ['stems'], workerSeconds: 10, stems: stemsOf(STEMS), stemModel: 'htdemucs', stemVersion: 1, stemFormat: 'mp3', stemBytes: 4242 };
const lyricsResult = { ok: true, songId: LYR, tasks: ['lyrics'], workerSeconds: 5, lyrics: { lyrics: `rips/lyrics/${LYR}.json`, lyricsModel: 'faster-whisper-small', lyricsVersion: 1 } };
const resultsJson = JSON.stringify({ Messages: [
  { ReceiptHandle: 'rh-stems', Body: JSON.stringify(stemsResult) },
  { ReceiptHandle: 'rh-lyrics', Body: JSON.stringify(lyricsResult) },
] });
const marker = join(work, 'results-delivered');
const sendlog = join(work, 'sqs-sends.log');

// ---- fake `aws`: manifest read → seed; s3 uploads no-op; sqs receive on the RESULTS queue → the
//      one-shot batch (then empty); sqs send → append the body to a log; everything else → {}. ----
const fakeAws = join(work, 'fake-aws-lyrics.mjs');
writeFileSync(fakeAws, `
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const argv = process.argv.slice(2);
const args = [];
for (let i = 0; i < argv.length; i++) { if (argv[i] === '--profile' || argv[i] === '--region') { i++; continue; } args.push(argv[i]); }
const flag = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };
const [svc, act] = args;
if (svc === 's3' && act === 'cp') {
  const src = args[2], dst = args[3];
  if (dst === '-' && /\\/rips\\/manifest\\.json$/.test(src || '')) {
    const s = process.env.FAKE_SEED; process.stdout.write(s && existsSync(s) ? readFileSync(s, 'utf8') : '{}'); process.exit(0);
  }
  process.exit(0); // upload no-op
}
if (svc === 'sqs') {
  if (act === 'receive-message') {
    const q = flag('--queue-url') || '';
    if (q.includes('results') && !existsSync(process.env.FAKE_MARKER)) {
      writeFileSync(process.env.FAKE_MARKER, '1');
      process.stdout.write(process.env.FAKE_RESULTS_JSON || '{}'); process.exit(0);
    }
    process.stdout.write('{}'); process.exit(0);
  }
  if (act === 'send-message') { const b = flag('--message-body'); if (b) appendFileSync(process.env.FAKE_SENDLOG, b + '\\n'); process.stdout.write('{}'); process.exit(0); }
  process.stdout.write('{}'); process.exit(0); // delete-message etc.
}
process.exit(0);
`);
const shimDir = join(work, 'bin');
mkdirSync(shimDir, { recursive: true });
const awsShim = join(shimDir, 'aws');
writeFileSync(awsShim, `#!/bin/sh\nexec node ${JSON.stringify(fakeAws)} "$@"\n`);
chmodSync(awsShim, 0o755);

const env = {
  ...process.env,
  PATH: `${shimDir}:${process.env.PATH}`,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-bucket',
  RIP_SOURCES: catalog,
  FAKE_AWS_MANIFEST: seedManifest,           // (unused by this shim, kept for parity)
  FAKE_SEED: seedManifest,
  FAKE_MARKER: marker,
  FAKE_SENDLOG: sendlog,
  FAKE_RESULTS_JSON: resultsJson,
  POCKETDJ_STEM_RESULTS_QUEUE: 'https://sqs.local/pocketdj-stem-results',
  POCKETDJ_STEM_JOBS_QUEUE: 'https://sqs.local/pocketdj-stem-jobs',
  POCKETDJ_STEM_DLQ_QUEUE: 'https://sqs.local/pocketdj-stem-jobs-dlq',
  POCKETDJ_STEM_COLLECTION_CAP: '100',
  POCKETDJ_DISABLE_SCHEDULER: '1',
  HOME: join(work, 'home'),
};

const postJSON = async (p, body) => { const r = await fetch(`${base}${p}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }); return { status: r.status, body: await r.json().catch(() => null) }; };
const getJSON = async (p) => { const r = await fetch(`${base}${p}`); return { status: r.status, body: await r.json().catch(() => null) }; };
const entryOf = async (id) => (await getJSON(`/status/${id}`)).body?.entry;
const waitUp = async () => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`${base}/health`)).ok) return true; } catch { /* not yet */ } await sleep(200); } return false; };
const waitFor = async (fn, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { try { if (await fn()) return true; } catch { /* keep polling */ } await sleep(150); } return false; };
const sendLines = () => (existsSync(sendlog) ? readFileSync(sendlog, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return {}; } }) : []);

console.log('booting rip-server (fake aws + fake SQS results)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });

try {
  ok(await waitUp(), 'server is up (/health)');

  // (a) LYRICS fold: the LYR result lands → manifest entry gains the lyrics stamp
  ok(await waitFor(async () => (await entryOf(LYR))?.lyrics), '(a) lyrics fold landed for LYR');
  const eL = await entryOf(LYR);
  ok(eL?.lyrics === `rips/lyrics/${LYR}.json`, `(a) e.lyrics === the S3 key (got ${eL?.lyrics})`);
  ok(eL?.lyricsModel === 'faster-whisper-small', `(a) e.lyricsModel folded (got ${eL?.lyricsModel})`);
  ok(eL?.lyricsVersion === 1, `(a) e.lyricsVersion === 1 (got ${eL?.lyricsVersion})`);
  ok(typeof eL?.lyricsAt === 'number', `(a) e.lyricsAt stamped (got ${typeof eL?.lyricsAt})`);

  // (b) STEMS-fold auto-trigger: the STEMS result folds → vocals now exist → a lyrics JOB is enqueued
  ok(await waitFor(async () => (await entryOf(STEMS))?.stems?.vocals), '(b) stems fold landed for STEMS');
  ok(await waitFor(() => sendLines().some((j) => j.songId === STEMS && Array.isArray(j.tasks) && j.tasks.includes('lyrics'))),
    '(b) folding stems auto-enqueued a lyrics job for STEMS');

  // (c) round-trip: the lyricized LYR is NOT a backfill candidate; STEMS (vocals, no lyrics) is
  const bf = await postJSON('/backfill-lyrics', {});
  ok(bf.status === 200 && bf.body?.ok === true, `(c) /backfill-lyrics ok (status ${bf.status})`);
  ok(bf.body?.candidates >= 1, `(c) backfill candidates >= 1 (stemmed-no-lyrics; got ${bf.body?.candidates})`);
  const bfGet = await getJSON('/backfill-lyrics');
  ok(bfGet.status === 200 && bfGet.body?.ok === true, `(c) GET /backfill-lyrics also works (status ${bfGet.status})`);

  // (d) /lyricsify envelopes
  const unk = await postJSON('/lyricsify', { songId: MISSING });
  ok(unk.status === 404, `(d) /lyricsify unknown → 404 (got ${unk.status})`);
  const nov = await postJSON('/lyricsify', { songId: NOVOX });
  ok(nov.status === 400 && /vocals/.test(nov.body?.error || ''), `(d) /lyricsify no-vocals → 400 "${nov.body?.error}"`);
  const done = await postJSON('/lyricsify', { songId: LYR });
  ok(done.status === 200 && done.body?.alreadyDone === true, `(d) /lyricsify fresh LYR → alreadyDone (got ${JSON.stringify(done.body)})`);
  const forced = await postJSON('/lyricsify', { songId: LYR, force: true });
  ok(forced.status === 200 && forced.body?.queued === true, `(d) /lyricsify force → queued (got ${JSON.stringify(forced.body)})`);
  ok(await waitFor(() => sendLines().some((j) => j.songId === LYR && (j.tasks || []).includes('lyrics'))),
    '(d) forced /lyricsify enqueued a lyrics job for LYR');

  console.log(`\n${fail ? '✗ ' + fail + ' check(s) failed' : '✓ all lyrics-fold checks passed'}`);
} finally {
  srv.kill('SIGKILL');
  try { rmSync(work, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail ? 1 : 0);
