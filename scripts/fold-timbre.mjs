#!/usr/bin/env node
// fold-timbre — fold the warm-batch results (+ the id-alias map) into public/timbre.json, the
// per-song timbre corpus keyed by the song's OWN id. build-rec-features.mjs reads this file and
// attaches each vector to the song's rec-features row, so the corpus ships on the EXISTING
// catalog build/deploy path (deploy.sh → CDN) with no new upload machinery.
//
//   node scripts/fold-timbre.mjs [--results <dir>] [--aliases <path>] [--out public/timbre.json]
//
// Shape:
//   { "v":1, "timbreVersion":1, "generatedAt":"…", "counts":{…},
//     "songs": { "sng_a": {"v":1,"f":{…14 axes…}},          ← analysed under its own id
//                "sng_b": {"alias":"sng_a"} } }             ← same recording, different id
//
// ── ATTRIBUTION RULES (the whole point) ────────────────────────────────────────────────────────
//  · A vector lands ONLY under the id whose audio produced it — the driver keys every result on
//    the rip's/cut's own segment identity, and this fold never re-keys anything.
//  · An alias is an EXPLICIT {alias} indirection, auditable in the artifact, resolvable at
//    read time — never a silent copy of the vector. Removing a bad alias un-corrupts instantly.
//  · An alias whose target has no vector (yet) is DROPPED from the output and counted as
//    pending — a dangling alias must not pretend coverage exists.
//  · An alias for a song that has its OWN vector is ignored (own analysis always wins).
//  · Only rows at the current TIMBRE_VERSION fold; within one id, last write (atMs) wins —
//    a re-analysis replaces, never accumulates.
//
// IDEMPOTENT: a deterministic function of (results dir, aliases file) — re-running after more
// results land picks up exactly the new songs. `generatedAt` is the only unstable byte.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/// Pure fold. results: iterable of parsed NDJSON rows; aliases: {fromId:{to}} (or {fromId:to}).
export function foldTimbre(results, aliases = {}) {
  const songs = {};
  const best = new Map();       // id -> atMs of the row currently folded
  let dropped = 0;
  for (const r of results) {
    if (!r || !r.id || r.v !== TIMBRE_VERSION || !r.ok || !r.f || typeof r.f !== 'object') { dropped += 1; continue; }
    const at = Number.isFinite(r.atMs) ? r.atMs : 0;
    if (best.has(r.id) && best.get(r.id) >= at) continue;   // LWW per id
    best.set(r.id, at);
    songs[r.id] = { v: r.v, f: r.f };
  }
  let aliased = 0; let pending = 0; let shadowed = 0;
  for (const [from, spec] of Object.entries(aliases || {})) {
    const to = typeof spec === 'string' ? spec : spec?.to;
    if (!to) continue;
    if (songs[from]) { shadowed += 1; continue; }           // own analysis wins over any alias
    if (!songs[to] || songs[to].alias) { pending += 1; continue; } // no target vector → no row
    songs[from] = { alias: to };
    aliased += 1;
  }
  return { songs, stats: { vectors: best.size, aliased, pending, shadowed, dropped } };
}

function* readResults(dir) {
  if (!existsSync(dir)) return;
  for (const f of readdirSync(dir).sort()) {
    if (!f.endsWith('.ndjson')) continue;
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try { yield JSON.parse(line); } catch { /* torn tail line — the driver re-runs that song */ }
    }
  }
}

async function main() {
  const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
  const resultsDir = arg('--results', join(homedir(), '.pocketdj', 'timbre-batch', 'results'));
  const aliasPath = arg('--aliases', join(REPO, 'data', 'timbre-aliases.json'));
  const outPath = arg('--out', join(REPO, 'public', 'timbre.json'));

  const aliases = existsSync(aliasPath) ? (JSON.parse(readFileSync(aliasPath, 'utf8')).aliases || {}) : {};
  const { songs, stats } = foldTimbre(readResults(resultsDir), aliases);
  const doc = {
    v: 1,
    timbreVersion: TIMBRE_VERSION,
    generatedAt: new Date().toISOString(),
    counts: { songs: Object.keys(songs).length, ...stats },
    songs: Object.fromEntries(Object.entries(songs).sort(([x], [y]) => (x < y ? -1 : 1))),
  };
  writeFileSync(outPath, JSON.stringify(doc));
  console.error(`[fold-timbre] wrote ${outPath} — ${JSON.stringify(doc.counts)}`);
}

if (process.argv[1] && process.argv[1].endsWith('fold-timbre.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
