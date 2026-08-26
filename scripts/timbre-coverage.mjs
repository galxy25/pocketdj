#!/usr/bin/env node
// TIMBRE COVERAGE REPORT — the artifact that makes a corpus FREEZE legible instead of inferable.
// public/timbre.json silently froze for 14 days and nothing anywhere said so; a coverage number
// nobody prints is a coverage number nobody notices.
//
//   node scripts/timbre-coverage.mjs [--timbre public/timbre.json] [--json out.json]
//
// Reports, against the owner's live collections (the rec-engine profile state on S3):
//   · total vectors + aliases in the corpus, and the corpus's age
//   · POCKET coverage: analysed members / total members, overall and median per pocket
//   · how many of the pockets fall under the engine's timbreMinVectors=3 (the audio term is OFF
//     for those entirely) and how many have ZERO analysed members
//   · per-DECADE and per-GENRE coverage — the skew that matters, because the corpus is a census
//     of a vinyl crate and is thinnest exactly where new music comes from
//
// TWO SCOPES, because they answer different questions and get confused for each other:
//   --scope pockets (default)  over songs that are IN a collection — what the rec engine sees
//   --scope all                over every song in the shipped catalogs — the corpus-wide skew
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE = process.env.AWS_PROFILE || 'levi';
const REC_BUCKET = process.env.POCKETDJ_REC_BUCKET || 'pocketdj-rec-011183829623';
export const TIMBRE_MIN_VECTORS = 3;      // mirrors TIMBRE_MIN_VECTORS in lambda/rec-engine/index.mjs

const pct = (a, b) => (b > 0 ? Math.round((a / b) * 1000) / 10 : 0);
const median = (xs) => { if (!xs.length) return 0; const a = [...xs].sort((x, y) => x - y); const m = a.length >> 1; return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2; };

/// Pure: is this song analysed? An ALIAS counts only when its target actually has a vector —
/// fold-timbre already drops dangling aliases, but counting an alias as coverage without
/// checking would let the report overstate exactly what it exists to police.
export function analysed(songs, id, depth = 0) {
  const r = songs[id];
  if (!r || depth > 2) return false;
  if (r.f) return true;
  if (r.alias) return analysed(songs, r.alias, depth + 1);
  return false;
}

/// Pure: the whole report. collections = [{id,kind,name,songIds}], songs = timbre.json songs map,
/// meta = id -> {year, genre}.
export function coverageReport(collections, songs, meta, scope = 'pockets') {
  const pockets = collections.filter((c) => (c.kind || c.type) === 'pocket');
  const perPocket = [];
  const memberIds = new Set();
  for (const p of pockets) {
    const ids = [...new Set(p.songIds || [])];
    const ok = ids.filter((id) => analysed(songs, id));
    for (const id of ids) memberIds.add(id);
    perPocket.push({ id: p.id, name: p.name, total: ids.length, analysed: ok.length, pct: pct(ok.length, ids.length) });
  }
  const totalMembers = [...memberIds].length;
  const analysedMembers = [...memberIds].filter((id) => analysed(songs, id)).length;
  const byDecade = {}; const byGenre = {};
  const scopeIds = scope === 'all' ? new Set(Object.keys(meta)) : memberIds;
  for (const id of scopeIds) {
    const m = meta[id] || {};
    const dec = Number.isFinite(m.year) && m.year > 1900 ? `${Math.floor(m.year / 10) * 10}s` : 'unknown';
    const g = m.genre || 'unknown';
    for (const [bucket, k] of [[byDecade, dec], [byGenre, g]]) {
      const b = bucket[k] || (bucket[k] = { total: 0, analysed: 0 });
      b.total += 1; if (analysed(songs, id)) b.analysed += 1;
    }
  }
  for (const b of [byDecade, byGenre]) for (const k of Object.keys(b)) b[k].pct = pct(b[k].analysed, b[k].total);
  return {
    pockets: pockets.length,
    pocketCoveragePct: pct(analysedMembers, totalMembers),
    pocketMembers: totalMembers,
    pocketMembersAnalysed: analysedMembers,
    medianPerPocketPct: median(perPocket.map((p) => p.pct)),
    pocketsUnderMinVectors: perPocket.filter((p) => p.analysed < TIMBRE_MIN_VECTORS).length,
    pocketsWithZero: perPocket.filter((p) => p.analysed === 0).length,
    scope, scopeSongs: scopeIds.size, byDecade, byGenre,
    perPocket: perPocket.sort((a, b) => a.pct - b.pct),
  };
}

function loadCollections() {
  const list = execFileSync('aws', ['s3', 'ls', `s3://${REC_BUCKET}/rec/state/`, '--region', REGION, '--profile', PROFILE], { encoding: 'utf8' })
    .trim().split('\n').map((l) => l.trim().split(/\s+/).pop()).filter((f) => f && f.endsWith('.json'));
  const out = [];
  for (const f of list) {
    const doc = JSON.parse(execFileSync('aws', ['s3', 'cp', `s3://${REC_BUCKET}/rec/state/${f}`, '-', '--region', REGION, '--profile', PROFILE], { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 }));
    for (const c of doc?.collections?.list || []) out.push(c);
  }
  return out;
}

function loadMeta() {
  const meta = {};
  for (const f of ['current-index.json', 'apple-music-index.json', 'digital-index.json']) {
    const p = join(REPO, 'public', f);
    if (!existsSync(p)) continue;
    const idx = JSON.parse(readFileSync(p, 'utf8'));
    const albums = new Map((idx.albums || []).map((a) => [a.id, a]));
    for (const s of idx.songs || []) {
      const al = albums.get(s.albumId) || {};
      const year = Number(s.year ?? al.year ?? (String(al.releaseDate || '').slice(0, 4))) || null;
      const genre = s.genre || al.genre || (Array.isArray(al.genres) ? al.genres[0] : null) || null;
      if (!meta[s.id]) meta[s.id] = { year, genre };
    }
  }
  return meta;
}

function main() {
  const timbrePath = arg('--timbre', join(REPO, 'public', 'timbre.json'));
  const doc = JSON.parse(readFileSync(timbrePath, 'utf8'));
  const scope = arg('--scope', 'pockets');
  const rep = coverageReport(loadCollections(), doc.songs || {}, loadMeta(), scope);
  const ageDays = Math.round((Date.now() - Date.parse(doc.generatedAt)) / 86400000 * 10) / 10;
  const out = { corpus: { ...doc.counts, generatedAt: doc.generatedAt, ageDays }, ...rep };
  const table = (b) => Object.entries(b).sort(([x], [y]) => (x < y ? -1 : 1))
    .map(([k, v]) => `    ${k.padEnd(22)} ${String(v.analysed).padStart(6)}/${String(v.total).padStart(6)}  ${String(v.pct).padStart(5)}%`).join('\n');
  console.log(`TIMBRE COVERAGE  (corpus ${doc.generatedAt}, ${ageDays}d old)`);
  console.log(`  vectors ${doc.counts.vectors}  aliased ${doc.counts.aliased}  pending ${doc.counts.pending}  songs ${doc.counts.songs}`);
  console.log(`  pockets ${rep.pockets}  coverage ${rep.pocketCoveragePct}% (${rep.pocketMembersAnalysed}/${rep.pocketMembers})  median/pocket ${rep.medianPerPocketPct}%`);
  console.log(`  pockets under timbreMinVectors=${TIMBRE_MIN_VECTORS}: ${rep.pocketsUnderMinVectors}   with ZERO vectors: ${rep.pocketsWithZero}`);
  console.log(`  by decade (scope=${rep.scope}, ${rep.scopeSongs} songs):\n${table(rep.byDecade)}`);
  console.log(`  by genre (top 15):\n${table(Object.fromEntries(Object.entries(rep.byGenre).sort((a, b) => b[1].total - a[1].total).slice(0, 15)))}`);
  const j = arg('--json', null);
  if (j) writeFileSync(j, JSON.stringify(out, null, 1));
}

if (process.argv[1] && process.argv[1].endsWith('timbre-coverage.mjs')) main();
