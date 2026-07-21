#!/usr/bin/env node
// fold-cloud-analysis — surface the cloud AUDIO ANALYSIS (bpm/key/camelot, produced by the SQS
// analysis workers and folded into rips/manifest.json by the rip-server's pumpStemResults) back
// into the CATALOG index the Browse/song-detail cards read (public/digital-index.json).
//
// WHY: digital ingest no longer analyzes locally (index-digital-files.mjs only stages+uploads the
// mp3; /ingest-digital auto-enqueues cloud analysis). So a freshly-indexed digital song lands in
// digital-index.json with bpm/key/camelot = null, and the cloud fills them into the MANIFEST a
// few minutes later. The Mix/deck already reads bpm/beat-grid straight from the manifest via
// RipsStore, but the catalog CARD bpm/key comes from digital-index.json — this tool restamps the
// manifest's cloud values back into that index so the cards show BPM/key too. (Analog cloud rips
// fold into current-index.json in-process via the rip-server's requestPublicFold; this tool is the
// DIGITAL-index equivalent, run out-of-band after a backfill wave.)
//
// PRECEDENCE: the cloud analysis WINS for a digital song (it's the only analyzer now). Only a
// non-null manifest value is stamped — a song the cloud hasn't analyzed yet is left untouched (its
// null stays until the next run), and a manifest that lacks a field never NULLs a catalog value.
//
// SAFETY: digital-only by default (INDEXES = digital-index.json) and a per-entry source guard, so
// this can never overwrite the analog catalog's curated per-song bpm/key (analog manifest entries
// carry no per-song bpm). Side-output by default (index-out/analysis-cloud/<index-name>.json +
// report). --apply rewrites the public/ index in place (commit + deploy.sh ships it). --upload
// dev,prod republishes the changed index json to the web bucket(s) and invalidates it.
//
// IDEMPOTENT: output is a deterministic function of (indexes, manifest); re-running after more
// backfill results land picks up only the songs whose manifest analysis newly changed.
//
// Usage:
//   node scripts/fold-cloud-analysis.mjs                       # dry run + report
//   node scripts/fold-cloud-analysis.mjs --apply               # rewrite public/ index(es)
//   node scripts/fold-cloud-analysis.mjs --apply --upload dev,prod
//   [--manifest s3|<path>] [--limit N]

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { ANALYSIS_VERSION } from './lib/audio-analyze.mjs'; // keep in lock-step with the cloud analyzer

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const RIP_BUCKET = process.env.RIP_BUCKET || 'pocketdj-rips-011183829623';
const AWS_PROFILE = process.env.AWS_PROFILE || 'levi';
// Test seams: POCKETDJ_FOLD_INDEXES (comma list, absolute or repo-relative) + POCKETDJ_FOLD_OUT.
// Default DIGITAL-ONLY: the analog catalog folds cloud bpm/key in-process (rip-server ITEM 10).
const INDEXES = process.env.POCKETDJ_FOLD_INDEXES
  ? process.env.POCKETDJ_FOLD_INDEXES.split(',').map((s) => s.trim()).filter(Boolean)
  : ['public/digital-index.json'];

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);
const apply = has('--apply');
const uploadEnvs = (arg('--upload', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const limit = arg('--limit') ? parseInt(arg('--limit'), 10) : Infinity;

const outRoot = process.env.POCKETDJ_FOLD_OUT || join(REPO, 'index-out', 'analysis-cloud');
mkdirSync(outRoot, { recursive: true });

// ---- manifest (the durable cloud state the workers fold their analysis into) ----
function loadManifest() {
  const src = arg('--manifest');
  if (src && src !== 's3') return JSON.parse(readFileSync(src, 'utf8'));
  const cache = join(homedir(), '.pocketdj', 'rips', 'manifest.json');
  if (!src && existsSync(cache)) return JSON.parse(readFileSync(cache, 'utf8'));
  const raw = execFileSync('aws', ['s3', 'cp', `s3://${RIP_BUCKET}/rips/manifest.json`, '-',
    '--profile', AWS_PROFILE], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  return JSON.parse(raw);
}

const manifest = loadManifest();
const report = { generatedAt: new Date().toISOString(), analysisVersion: ANALYSIS_VERSION, apply, indexes: {}, stamped: 0 };

for (const rel of INDEXES) {
  const path = rel.startsWith('/') ? rel : join(REPO, rel);
  if (!existsSync(path)) continue;
  const idx = JSON.parse(readFileSync(path, 'utf8'));
  const r = { songs: idx.songs.length, candidates: 0, stamped: 0, unanalyzed: 0, nonDigitalSkipped: 0, noEntry: 0 };
  let n = 0;
  for (const s of idx.songs) {
    const e = manifest[s.id];
    if (!e) { r.noEntry++; continue; }
    if (e.source && e.source !== 'digital') { r.nonDigitalSkipped++; continue; } // never clobber the analog catalog
    if (e.bpm == null && e.musicalKey == null && e.camelot == null) { r.unanalyzed++; continue; } // cloud hasn't analyzed it yet
    if (n >= limit) break;
    n++;
    r.candidates++;
    // Stamp only non-null manifest values; a missing field never NULLs an existing catalog value.
    let changed = false;
    if (e.bpm != null && s.bpm !== e.bpm) { s.bpm = e.bpm; changed = true; }
    if (e.musicalKey != null && s.key !== e.musicalKey) { s.key = e.musicalKey; changed = true; }
    if (e.camelot != null && s.camelot !== e.camelot) { s.camelot = e.camelot; changed = true; }
    if (changed) { r.stamped++; report.stamped++; }
  }
  report.indexes[rel] = r;
  if (r.stamped > 0) {
    const dest = apply ? path : join(outRoot, basename(rel));
    writeFileSync(dest, JSON.stringify(idx));
    r.wrote = apply ? rel : dest;
  }
}

writeFileSync(join(outRoot, 'report.json'), JSON.stringify(report, null, 2));
console.error(JSON.stringify(report, null, 2));

// ---- CDN publish: republish each CHANGED index json to the web bucket(s) + invalidate ----
// Only runs with --apply (the public/ files must already carry the folded values).
if (uploadEnvs.length && apply && report.stamped > 0) {
  const acct = execFileSync('aws', ['sts', 'get-caller-identity', '--profile', AWS_PROFILE,
    '--query', 'Account', '--output', 'text'], { encoding: 'utf8' }).trim();
  const cf = { dev: process.env.CF_ID_DEV || 'E123GKAO9JVETP', prod: process.env.CF_ID_PROD || 'E1SP8M1SIF7Q8D' };
  const changedRels = Object.entries(report.indexes).filter(([, r]) => r.stamped > 0).map(([rel]) => rel);
  for (const env of uploadEnvs) {
    const bucket = `pocketdj-${env}-web-${acct}`;
    for (const rel of changedRels) {
      const name = basename(rel);
      console.error(`▶ Publishing ${name} (cloud analysis folded) -> s3://${bucket}/${name} …`);
      execFileSync('aws', ['s3', 'cp', join(REPO, rel), `s3://${bucket}/${name}`,
        '--profile', AWS_PROFILE, '--content-type', 'application/json', '--cache-control', 'no-cache',
        '--only-show-errors'], { stdio: 'inherit' });
    }
    if (cf[env]) {
      try {
        execFileSync('aws', ['cloudfront', 'create-invalidation', '--distribution-id', cf[env],
          '--paths', ...changedRels.map((rel) => `/${basename(rel)}`), '--profile', AWS_PROFILE,
          '--query', 'Invalidation.Id', '--output', 'text'], { encoding: 'utf8' });
      } catch { /* invalidation is best-effort (no-cache is the backstop) */ }
    }
    console.error(`✓ Cloud analysis folded into [${env}] catalog`);
  }
}
