#!/usr/bin/env node
// Pull the CLOUD timbre sidecars down and rewrite them as ONE local NDJSON result file, so the
// existing fold sees cloud work exactly as it sees local work. Modelled on fold-cloud-analysis.mjs.
//
//   node scripts/fold-cloud-timbre.mjs [--prefix rips/timbre/] [--results <dir>] [--cache <dir>]
//   node scripts/fold-cloud-timbre.mjs --stats     count sidecars, write nothing
//
// ── WHY ONE FILE, AND WHY THAT IS THE ROLLBACK STORY ───────────────────────────────────────────
// Output goes to <results>/cloud.ndjson and NOTHING else is touched. loadDone() in
// timbre-batch.mjs and readResults() in fold-timbre.mjs both glob *.ndjson, so this needs zero
// changes in either: the local driver skips what the cloud did, and the fold merges both in one
// pass. The six existing shard-N.ndjson files — the locally-measured 12,395 — are never
// rewritten or renumbered. To un-fold every cloud vector:
//     rm <results>/cloud.ndjson && node scripts/fold-timbre.mjs
// and public/timbre.json returns byte-exact to the local corpus (only generatedAt differs).
//
// Deterministic + idempotent: the sync is incremental (only new keys transfer), the rewrite is
// sorted by id, and re-running after more sidecars land picks up exactly the new ones.
// PARITY OUTPUT IS EXCLUDED BY CONSTRUCTION: parity writes under rips/timbre-parity/, a
// different prefix, so a failed parity run can never reach the corpus.
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const PREFIX = arg('--prefix', 'rips/timbre/');
const BUCKET = process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623';
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const RESULTS = arg('--results', join(homedir(), '.pocketdj', 'timbre-batch', 'results'));
const CACHE = arg('--cache', join(homedir(), '.pocketdj', 'timbre-batch', 'cloud-sidecars'));

/// Pure: sidecar objects -> the NDJSON rows fold-timbre.mjs consumes. Drops anything at a
/// different TIMBRE_VERSION (a stale calibration must never enter the corpus) and anything with
/// no vector (a permanent engine failure is resume state, not coverage). LWW by atMs per id.
export function sidecarsToRows(sidecars) {
  const best = new Map();
  for (const s of sidecars) {
    if (!s || !s.id || s.v !== TIMBRE_VERSION || !s.ok || !s.f || typeof s.f !== 'object') continue;
    const at = Number.isFinite(s.atMs) ? s.atMs : 0;
    const cur = best.get(s.id);
    if (cur && (Number.isFinite(cur.atMs) ? cur.atMs : 0) >= at) continue;
    const row = { id: s.id, v: s.v, src: s.src || 's3-song', atMs: at, ok: true, f: s.f };
    if (Number.isFinite(s.ms)) row.ms = s.ms;
    if (Number.isFinite(s.durationSec)) row.durationSec = s.durationSec;
    if (s.by) row.by = s.by;
    if (s.image) row.image = s.image;
    best.set(s.id, row);
  }
  return [...best.values()].sort((a, b) => (a.id < b.id ? -1 : 1));
}

function main() {
  const dir = join(CACHE, `v${TIMBRE_VERSION}`);
  mkdirSync(dir, { recursive: true });
  execFileSync('aws', ['s3', 'sync', `s3://${BUCKET}/${PREFIX}v${TIMBRE_VERSION}/`, dir,
    '--region', REGION, '--profile', PROFILE, '--only-show-errors'], { stdio: 'inherit' });
  const sidecars = [];
  let unusable = 0;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.json')) continue;
    try { sidecars.push(JSON.parse(readFileSync(join(dir, f), 'utf8'))); } catch { unusable += 1; }
  }
  const rows = sidecarsToRows(sidecars);
  if (process.argv.includes('--stats')) {
    console.log(JSON.stringify({ sidecars: sidecars.length, rows: rows.length, unusable }));
    return;
  }
  mkdirSync(RESULTS, { recursive: true });
  const out = join(RESULTS, 'cloud.ndjson');
  writeFileSync(out, rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
  console.error(`[fold-cloud-timbre] ${sidecars.length} sidecar(s) → ${rows.length} row(s) → ${out}`
    + (unusable ? ` (${unusable} unreadable)` : ''));
}

if (process.argv[1] && process.argv[1].endsWith('fold-cloud-timbre.mjs')) main();
