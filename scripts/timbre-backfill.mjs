#!/usr/bin/env node
// Enqueue the CLOUD TIMBRE backfill: every manifest song that has audio and no current-version
// vector, batched onto the timbre jobs queue through a bounded-concurrency dispatcher.
//
//   node scripts/timbre-backfill.mjs [--dry-run] [--max N] [--batch 50] [--conc 12] [--force]
//        [--results ~/.pocketdj/timbre-batch/results] [--no-results-skip] [--allow-src-change]
//
// ── REUSE WHAT IS ALREADY COMPUTED ────────────────────────────────────────────────────────────
// The 12,395 vectors measured locally live in <results>/*.ndjson, NOT as manifest stamps — the
// warm-batch driver's durable state has always been the result files (state.json is a per-run
// snapshot it regenerates, never the source of truth). So wantTimbre() alone, which reads the
// manifest, would classify every locally-analysed song as outstanding and re-run thousands of
// songs that already have a vector in the exact same space. This skips anything already present
// at the current TIMBRE_VERSION, using the SAME loader semantics as timbre-batch.mjs's loadDone()
// and fold-timbre.mjs's readResults(). --no-results-skip opts out.
//
// THE SAME LOGIC AS rip-server.mjs's POST /backfill-timbre — both call buildTimbreBatches() over
// wantTimbre() candidates from scripts/lib/timbre-jobs.mjs, so there is one definition of "needs
// analysis" and one of "how a batch is shaped". This CLI exists because the backfill has to be
// runnable against the AUTHORITATIVE S3 manifest without restarting the long-running rip server
// (which is mid-rip more often than not). The server's route is the ongoing path; this is the
// operator path.
//
// BOUNDED CONCURRENCY IS THE POINT: 3,000+ songs is ~62 messages, and firing every
// `aws sqs send-message` at once would fork 62 processes for no gain. Mirrors DISPATCH_CONC in
// rip-server.mjs — cap concurrent sends, never total throughput.
import { execFile } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { promisify } from 'node:util';
import { buildTimbreBatches, wantTimbre, timbreKeyFor, timbreHealth, readResultRows,
  crossesTimbreProvenance } from './lib/timbre-jobs.mjs';

const run = promisify(execFile);
const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const DRY = process.argv.includes('--dry-run');
const FORCE = process.argv.includes('--force');
const MAX = Number(arg('--max', Infinity));
const BATCH = Number(arg('--batch', 50));
const CONC = Number(arg('--conc', 12));
const BUCKET = process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623';
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const QUEUE = process.env.POCKETDJ_TIMBRE_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-timbre-jobs';

async function loadManifest() {
  const src = arg('--manifest', null);
  if (src && src !== 's3') return JSON.parse(readFileSync(src, 'utf8'));
  const cache = join(homedir(), '.pocketdj', 'rips', 'manifest.json');
  if (src !== 's3' && existsSync(cache)) return JSON.parse(readFileSync(cache, 'utf8'));
  const { stdout } = await run('aws', ['s3', 'cp', `s3://${BUCKET}/rips/manifest.json`, '-',
    '--profile', PROFILE, '--region', REGION], { maxBuffer: 512 * 1024 * 1024 });
  return JSON.parse(stdout || '{}');
}

async function main() {
  const manifest = await loadManifest();
  const resultsDir = arg('--results', join(homedir(), '.pocketdj', 'timbre-batch', 'results'));
  // readResultRows keeps the row (not just the id) so the PROVENANCE GATE below can see WHICH
  // audio a song's existing vector was measured from. --no-results-skip drops the reuse skip but
  // NOT the gate: re-measuring is a choice, silently swapping the source audio is not.
  const rows = readResultRows(resultsDir);
  const skipDone = !(process.argv.includes('--no-results-skip') || FORCE);
  const allowSrcChange = process.argv.includes('--allow-src-change');
  const health = timbreHealth(manifest);
  const entries = [];
  let alreadyDone = 0; let held = 0;
  for (const [id, e] of Object.entries(manifest)) {
    if (!FORCE && !wantTimbre(e)) continue;
    if (skipDone && rows.has(id)) { alreadyDone += 1; continue; }   // already measured — reuse, don't re-run
    // An analog song measured from its RAW album file (vinyl-cut) would come back from the cloud
    // measured from the BURNED cut mp3 (s3-cut) — different bytes, and fold-timbre would have to
    // hold the result anyway. Never enqueue work whose result cannot be folded.
    if (crossesTimbreProvenance(e, rows.get(id), { allowSrcChange })) { held += 1; continue; }
    const key = timbreKeyFor(e);
    if (key) entries.push([id, key, e.source]);
    if (entries.length >= MAX) break;
  }
  const batches = buildTimbreBatches(entries, { size: BATCH, dedup: !FORCE });
  console.error(`[timbre-backfill] manifest ${Object.keys(manifest).length} · already measured ${alreadyDone} `
    + `(local+cloud results) · held ${held} (provenance) · stamped ${health.analysed} `
    + `· enqueueing ${entries.length} song(s) in ${batches.length} batch(es)`);
  if (DRY) { console.log(JSON.stringify({ candidates: entries.length, held, alreadyDone, batches: batches.length, sample: batches[0]?.songs.slice(0, 3) }, null, 2)); return; }

  let sent = 0; let failed = 0; let i = 0;
  const worker = async () => {
    for (;;) {
      const b = batches[i++];
      if (!b) return;
      try { await run('aws', ['sqs', 'send-message', '--queue-url', QUEUE, '--message-body', JSON.stringify(b),
        '--profile', PROFILE, '--region', REGION]); sent += b.songs.length; }
      catch (e) { failed += 1; console.error(`  send failed for ${b.batchId}: ${e.message}`); }
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONC, batches.length) }, worker));
  console.log(JSON.stringify({ ok: failed === 0, enqueuedSongs: sent, batches: batches.length, failedBatches: failed }));
}

if (process.argv[1] && process.argv[1].endsWith('timbre-backfill.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
