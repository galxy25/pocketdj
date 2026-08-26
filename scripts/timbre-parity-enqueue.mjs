#!/usr/bin/env node
// PARITY GATE, half 1 — pick a STRATIFIED sample of songs that ALREADY have a locally-measured
// timbre vector and enqueue them for CLOUD analysis into a QUARANTINED S3 prefix.
//
//   node scripts/timbre-parity-enqueue.mjs [--n 120] [--prefix rips/timbre-parity/]
//
// WHY QUARANTINE: parity output must never be able to reach the corpus. fold-cloud-timbre.mjs
// syncs `rips/timbre/` only, so a FAILED parity run cannot contaminate public/timbre.json even
// by accident. dedup:false forces a real re-run rather than a skip against existing sidecars.
//
// WHY STRATIFIED AND NOT RANDOM: random alone would under-sample the two places a numeric shift
// actually shows up.
//   · RAIL-SATURATED rows (an axis clamped at exactly 0.0 or 1.0) sit ON the clamp boundary,
//     where a 1e-12 difference is most likely to change the rounded value.
//   · MID-RANGE `busy` is the one axis whose input is a DISCRETE decision — onset_detect does
//     threshold peak-picking, so one extra onset over ~90 s (~0.011 raw ≈ 0.0019 normalized) is
//     visible at 4 dp. If anything diverges, it will be `busy`.
//
// HONEST LIMITATION: only `s3-song`/`s3-cut` rows can be reproduced in the cloud — the 10,388
// `vinyl-cut` vectors were cut from raw album files on /Volumes/RipBurnMix, which no EC2 worker
// can reach. Claiming vinyl parity without the bytes would be a null verifier, so this samples
// exactly the rows whose input bytes are addressable from S3.
import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const N = Number(arg('--n', 120));
const PREFIX = arg('--prefix', 'rips/timbre-parity/');
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const QUEUE = process.env.POCKETDJ_TIMBRE_JOBS_QUEUE || 'https://sqs.us-west-2.amazonaws.com/011183829623/pocketdj-timbre-jobs';
const RESULTS = join(homedir(), '.pocketdj', 'timbre-batch', 'results');
const MANIFEST = join(homedir(), '.pocketdj', 'rips', 'manifest.json');
const aws = (...a) => execFileSync('aws', [...a, '--region', REGION, '--profile', PROFILE], { encoding: 'utf8' });

const RAIL_AXES = ['noisy', 'm1', 'm2', 'm3', 'm4', 'width', 'air', 'punch', 'dynamic', 'loud'];
const railed = (f) => RAIL_AXES.some((k) => f[k] === 0 || f[k] === 1);

/// Pure: choose the sample. rows = local result rows reproducible from S3, keyed by id.
export function chooseSample(rows, n) {
  const third = Math.max(1, Math.floor(n / 3));
  const rail = rows.filter((r) => railed(r.f));
  const busy = rows.filter((r) => !railed(r.f) && r.f.busy > 0.15 && r.f.busy < 0.85);
  const rest = rows.filter((r) => !rail.includes(r) && !busy.includes(r));
  const pick = [];
  const take = (arr, k) => { for (const r of arr) { if (pick.length >= n) break; if (!pick.includes(r) && k-- > 0) pick.push(r); } };
  take(rail, third); take(busy, third); take(rest, n - pick.length); take(rows, n - pick.length);
  return pick.slice(0, n);
}

function main() {
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  const rows = [];
  const seen = new Set();
  for (const f of readdirSync(RESULTS).sort()) {
    if (!f.endsWith('.ndjson')) continue;
    for (const line of readFileSync(join(RESULTS, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (!r.ok || !r.f || seen.has(r.id)) continue;
      if (r.src !== 's3-song' && r.src !== 's3-cut') continue;     // cloud-reachable bytes only
      const e = manifest[r.id];
      const key = e && (r.src === 's3-cut' ? e.cutKey : e.key);
      if (!key) continue;
      seen.add(r.id);
      rows.push({ ...r, key });
    }
  }
  const pick = chooseSample(rows, N);
  const batchId = `parity_${Date.now()}`;
  const songs = pick.map((r) => ({ id: r.id, key: r.key, kind: r.src }));
  // ONE message: the whole point of the batch shape is that N songs share one warm fleet.
  aws('sqs', 'send-message', '--queue-url', QUEUE, '--message-body', JSON.stringify({
    kind: 'timbre', v: 1, batchId, songs, dedup: false, outPrefix: PREFIX,
  }));
  const out = join(homedir(), '.pocketdj', 'timbre-batch', 'parity-sample.json');
  writeFileSync(out, JSON.stringify({ batchId, prefix: PREFIX, n: songs.length,
    railed: pick.filter((r) => railed(r.f)).length, ids: songs.map((s) => s.id) }, null, 2));
  console.log(JSON.stringify({ batchId, enqueued: songs.length, prefix: PREFIX, sample: out,
    railed: pick.filter((r) => railed(r.f)).length, candidates: rows.length }, null, 2));
}

if (process.argv[1] && process.argv[1].endsWith('timbre-parity-enqueue.mjs')) main();
