// Fold explicit-from-lyrics classification results into the index.
// Mirrors apply-sentiment-upgrade.mjs: reads the per-song verdict JSONL produced
// by enrich-explicit.mjs (regex + local-LLM fallback) and folds a boolean
// `explicit` (+ provenance) onto songs by stable songId.
//
// Input: index-out/shards-pw/explicit.jsonl (EXPL=path) — one verdict per line:
//   {songId, explicit, confidence, categories, source:'regex'|'lyrics'|'failed'}
// Output: rewrites index-out/current/index.json in place (or OUT=path).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..', '..', '..', '..');
const indexPath = process.env.INDEX || join(ROOT, 'index-out', 'current', 'index.json');
const explPath = process.env.EXPL || join(ROOT, 'index-out', 'shards-pw', 'explicit.jsonl');
const outPath = process.env.OUT || indexPath;

function readJsonl(file) {
  const rows = [];
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { rows.push(JSON.parse(t)); } catch { /* skip malformed */ }
  }
  return rows;
}

if (!existsSync(explPath)) {
  console.error('No explicit verdict file:', explPath);
  process.exit(1);
}

// Last verdict wins per songId (idempotent re-folds; later passes override).
const verdict = new Map();
let rawRows = 0;
const bySource = {};
for (const r of readJsonl(explPath)) {
  if (!r || !r.songId) continue;
  verdict.set(r.songId, r);
  rawRows++;
  bySource[r.source || 'unknown'] = (bySource[r.source || 'unknown'] || 0) + 1;
}

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const songById = new Map(idx.songs.map((s) => [s.id, s]));

let covered = 0, setTrue = 0, setFalse = 0, missing = 0;
for (const [songId, v] of verdict) {
  const s = songById.get(songId);
  if (!s) { missing++; continue; }
  covered++;
  const ex = !!v.explicit;
  s.explicit = ex;
  s.explicitSource = v.source === 'failed' ? 'failed' : (v.source || 'lyrics'); // 'regex' | 'lyrics' | 'failed'
  if (ex && Array.isArray(v.categories) && v.categories.length) {
    s.explicitCategories = v.categories.map((c) => String(c).toLowerCase().trim()).filter(Boolean).slice(0, 6);
  } else {
    delete s.explicitCategories;
  }
  if (ex) setTrue++; else setFalse++;
}

// Refresh manifest tallies if present.
if (idx.manifest && idx.manifest.counts) {
  idx.manifest.counts.songsExplicit = idx.songs.filter((s) => s.explicit).length;
  idx.manifest.counts.songsExplicitClassified = idx.songs.filter((s) => s.explicitSource && s.explicitSource !== 'failed').length;
}

writeFileSync(outPath, JSON.stringify(idx));

console.log(JSON.stringify({
  verdictRows: rawRows, bySource,
  uniqueVerdicts: verdict.size, covered, missing,
  explicitTrue: setTrue, explicitFalse: setFalse,
  totalExplicitInIndex: idx.songs.filter((s) => s.explicit).length,
  out: outPath,
}));
