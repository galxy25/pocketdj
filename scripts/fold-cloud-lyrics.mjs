#!/usr/bin/env node
// fold-cloud-lyrics — surface the cloud TIMED transcripts (rips/lyrics/<id>.json, produced by
// the SQS lyrics workers) in the CATALOG lyrics system the apps already ship: song detail cards
// lazy-load /lyrics/<songId>.txt off the web CDN when song.lyricsStatus === 'found'
// (PWA IndexedDB cache + native LyricsStore). This fold makes a whisper transcript fill that
// slot for every song that has NO scraped lyrics yet — scraped lyrics always win (official text
// beats ASR), so a song already 'found' is never touched.
//
// WHAT IT DOES, per index (current-index.json, apple-music-index.json, digital-index.json):
//   1. candidate = song whose manifest entry carries `lyrics` (the sidecar key) AND whose
//      lyricsStatus !== 'found';
//   2. fetch the sidecar (public S3; cached under index-out/lyrics-cloud/sidecars/ so re-runs
//      are cheap), derive plain text — words grouped into lines on a ≥1.2 s gap or 12 words,
//      the SAME grouping the native Demuxer renders (DemuxLine.lines parity);
//   3. write index-out/lyrics-cloud/txt/<id>.txt and stamp the song lyricsStatus='found' +
//      lyricsSource='whisper' (provenance — a later scraped/official pass may replace these);
//      empty-word sidecars (instrumentals) are left untouched.
//
// IDEMPOTENT: output is a deterministic function of (indexes, manifest, sidecars); re-running
// after more backfill results land picks up only the new songs.
//
// SAFETY: side-output by default (index-out/lyrics-cloud/<index-name>.json + report). --apply
// rewrites the public/ indexes in place (commit + deploy.sh ships them). --upload dev,prod
// copies the txt files to the web buckets' /lyrics/ WITHOUT --delete (the scraped corpus lives
// there too — lyrics-cdn.sh's --delete sync must NOT be used for this partial set) and
// invalidates /lyrics/*.
//
// Usage:
//   node scripts/fold-cloud-lyrics.mjs                       # dry run + report
//   node scripts/fold-cloud-lyrics.mjs --apply               # rewrite public/ indexes
//   node scripts/fold-cloud-lyrics.mjs --apply --upload dev,prod
//   [--manifest s3|<path>] [--sidecar-dir <dir>] [--limit N]

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const RIP_BUCKET = process.env.RIP_BUCKET || 'pocketdj-rips-011183829623';
const RIPS_BASE = `https://${RIP_BUCKET}.s3.us-west-2.amazonaws.com`;
const AWS_PROFILE = process.env.AWS_PROFILE || 'levi';
// Test seams: POCKETDJ_FOLD_INDEXES (comma list, absolute or repo-relative) + POCKETDJ_FOLD_OUT.
const INDEXES = process.env.POCKETDJ_FOLD_INDEXES
  ? process.env.POCKETDJ_FOLD_INDEXES.split(',').map((s) => s.trim()).filter(Boolean)
  : ['public/current-index.json', 'public/apple-music-index.json', 'public/digital-index.json'];

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);
const apply = has('--apply');
const uploadEnvs = (arg('--upload', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const limit = arg('--limit') ? parseInt(arg('--limit'), 10) : Infinity;
const sidecarDirOverride = arg('--sidecar-dir');   // test seam: read sidecars from a local dir

const outRoot = process.env.POCKETDJ_FOLD_OUT || join(REPO, 'index-out', 'lyrics-cloud');
const sidecarCache = sidecarDirOverride || join(outRoot, 'sidecars');
const txtDir = join(outRoot, 'txt');
mkdirSync(sidecarCache, { recursive: true });
mkdirSync(txtDir, { recursive: true });

// ---- manifest (the durable cloud state; `lyrics` is the sidecar key) ----
function loadManifest() {
  const src = arg('--manifest');
  if (src && src !== 's3') return JSON.parse(readFileSync(src, 'utf8'));
  const cache = join(homedir(), '.pocketdj', 'rips', 'manifest.json');
  if (!src && existsSync(cache)) return JSON.parse(readFileSync(cache, 'utf8'));
  const raw = execFileSync('aws', ['s3', 'cp', `s3://${RIP_BUCKET}/rips/manifest.json`, '-',
    '--profile', AWS_PROFILE], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  return JSON.parse(raw);
}

// ---- line derivation (DemuxLine.lines parity: gap ≥ 1200 ms or 12 words per line) ----
function linesFromWords(words, gapMs = 1200, maxWords = 12) {
  const lines = [];
  let line = [];
  let prevEnd = null;
  for (const w of words || []) {
    const text = String(w.text ?? '').trim();
    if (!text) continue;
    if (line.length && (line.length >= maxWords || (prevEnd != null && w.startMs - prevEnd >= gapMs))) {
      lines.push(line.join(' '));
      line = [];
    }
    line.push(text);
    prevEnd = w.endMs ?? w.startMs;
  }
  if (line.length) lines.push(line.join(' '));
  return lines;
}

async function fetchSidecar(id, key) {
  const cached = join(sidecarCache, `${id}.json`);
  if (existsSync(cached)) {
    try { return JSON.parse(readFileSync(cached, 'utf8')); } catch { /* refetch */ }
  }
  if (sidecarDirOverride) return null;               // test seam: cache-only, no network
  const res = await fetch(`${RIPS_BASE}/${key}`);
  if (!res.ok) return null;
  const j = await res.json().catch(() => null);
  if (j) writeFileSync(cached, JSON.stringify(j));
  return j;
}

const manifest = loadManifest();
const report = { generatedAt: new Date().toISOString(), apply, indexes: {}, txtWritten: 0 };

for (const rel of INDEXES) {
  const path = rel.startsWith('/') ? rel : join(REPO, rel);
  if (!existsSync(path)) continue;
  const idx = JSON.parse(readFileSync(path, 'utf8'));
  const r = { songs: idx.songs.length, candidates: 0, stamped: 0, instrumental: 0, missingSidecar: 0, alreadyFound: 0 };
  let n = 0;
  for (const s of idx.songs) {
    const e = manifest[s.id];
    if (!e || !e.lyrics) continue;
    if (s.lyricsStatus === 'found') { r.alreadyFound++; continue; }   // scraped/official wins
    if (n >= limit) break;
    n++;
    r.candidates++;
    const sc = await fetchSidecar(s.id, e.lyrics);
    if (!sc || !Array.isArray(sc.words)) { r.missingSidecar++; continue; }
    const lines = linesFromWords(sc.words);
    if (!lines.length) { r.instrumental++; continue; }               // nothing sung — leave untouched
    writeFileSync(join(txtDir, `${s.id}.txt`), lines.join('\n') + '\n');
    s.lyricsStatus = 'found';
    s.lyricsSource = 'whisper';                                       // provenance (scraped pass may replace)
    r.stamped++;
    report.txtWritten++;
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

// ---- CDN upload: ADDITIVE copy (never --delete — the scraped corpus shares the prefix) ----
if (uploadEnvs.length && report.txtWritten > 0) {
  const acct = execFileSync('aws', ['sts', 'get-caller-identity', '--profile', AWS_PROFILE,
    '--query', 'Account', '--output', 'text'], { encoding: 'utf8' }).trim();
  const cf = { dev: process.env.CF_ID_DEV || 'E123GKAO9JVETP', prod: process.env.CF_ID_PROD || 'E1SP8M1SIF7Q8D' };
  for (const env of uploadEnvs) {
    const bucket = `pocketdj-${env}-web-${acct}`;
    console.error(`▶ Copying ${report.txtWritten} whisper lyrics -> s3://${bucket}/lyrics/ …`);
    execFileSync('aws', ['s3', 'cp', txtDir, `s3://${bucket}/lyrics/`, '--recursive',
      '--profile', AWS_PROFILE, '--content-type', 'text/plain; charset=utf-8',
      '--cache-control', 'public,max-age=86400', '--only-show-errors'], { stdio: 'inherit' });
    if (cf[env]) {
      try {
        execFileSync('aws', ['cloudfront', 'create-invalidation', '--distribution-id', cf[env],
          '--paths', '/lyrics/*', '--profile', AWS_PROFILE,
          '--query', 'Invalidation.Id', '--output', 'text'], { encoding: 'utf8' });
      } catch { /* invalidation is best-effort (86400 TTL is the backstop) */ }
    }
    console.error(`✓ Whisper lyrics on [${env}] CDN`);
  }
}
