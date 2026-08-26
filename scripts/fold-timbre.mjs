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
//  · …EXCEPT ACROSS PROVENANCE. `vinyl-cut` (a stream copy of the song's window out of the raw
//    album file) and `s3-cut` (the burned, re-encoded cut mp3 on S3) are measurements of two
//    DIFFERENT FILES, not two runs of one measurement — and the cloud lane can only ever produce
//    the latter, because /Volumes/RipBurnMix is not on EC2. Plain recency would let a cloud
//    re-analysis silently swap 10,388 raw-source analog vectors for re-encoded ones, leaving a
//    corpus whose rows are on two calibrations with nothing in the artifact saying which. So a
//    LOWER-ranked src never replaces a higher-ranked one (timbreSrcRank); it is counted as `held`.
//
// IDEMPOTENT: a deterministic function of (results dir, aliases file) — re-running after more
// results land picks up exactly the new songs. `generatedAt` is the only unstable byte.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { TIMBRE_VERSION } from './lib/audio-analyze.mjs';
import { timbreSrcRank } from './lib/timbre-jobs.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/// Pure fold. results: iterable of parsed NDJSON rows; aliases: {fromId:{to}} (or {fromId:to}).
export function foldTimbre(results, aliases = {}) {
  const songs = {};
  const best = new Map();       // id -> {atMs, rank} of the row currently folded
  let dropped = 0; let held = 0;
  for (const r of results) {
    if (!r || !r.id || r.v !== TIMBRE_VERSION || !r.ok || !r.f || typeof r.f !== 'object') { dropped += 1; continue; }
    const at = Number.isFinite(r.atMs) ? r.atMs : 0;
    const rank = timbreSrcRank(r.src);
    const cur = best.get(r.id);
    if (cur) {
      if (rank < cur.rank) { held += 1; continue; }         // different audio, worse provenance
      if (rank === cur.rank && cur.atMs >= at) continue;    // LWW within one provenance class
    }
    best.set(r.id, { atMs: at, rank });
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
  return { songs, stats: { vectors: best.size, aliased, pending, shadowed, dropped, held } };
}

/// Pure: refuse a write that would DELETE coverage. Mirrors build-timbre-aliases' shrinkGuard,
/// but on the vector count — the quantity that actually ships. Returns null when the write is
/// fine, or a reason string when it must be refused.
export function corpusShrinkGuard(prevVectors, nextVectors, tol = 0.05) {
  if (!Number.isFinite(prevVectors) || prevVectors <= 0) return null;      // no baseline yet
  if (Number.isFinite(nextVectors) && nextVectors >= prevVectors * (1 - tol)) return null;
  return `vector corpus collapsed ${prevVectors} → ${nextVectors} (> ${Math.round(tol * 100)}% shrink) `
    + `— is the results dir present? re-run with --allow-shrink if this is intended`;
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

  // SHRINK GUARD ON THE CORPUS ITSELF. build-timbre-aliases has one, but it measures the alias
  // TARGETS (is /Volumes mounted?) — a different quantity that does not move when the vectors do.
  // The vectors live ONLY in <results>/*.ndjson, an unbacked-up home directory, and the nightly
  // now COMMITS + PUSHES + SHIPS whatever this writes on any non-empty diff. So a lost, moved or
  // wrong-$HOME results dir would publish an empty corpus to every device while exiting 0.
  // Refuse instead, and make the operator say --allow-shrink.
  const reason = corpusShrinkGuard(prevVectorCount(outPath), stats.vectors);
  if (reason && !process.argv.includes('--allow-shrink')) {
    console.error(`[fold-timbre] REFUSING to write ${outPath}: ${reason}`);
    process.exit(3);
  }
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

/// The vector count of the artifact already on disk, or null when there is no comparable baseline.
/// A CALIBRATION BUMP IS NOT A BASELINE: at a new TIMBRE_VERSION the corpus legitimately restarts
/// near zero (nothing measured at v(N-1) folds), so comparing across versions would refuse the
/// very first v(N) fold. Only a same-version collapse is evidence of a broken environment.
function prevVectorCount(outPath) {
  if (!existsSync(outPath)) return null;
  try {
    const doc = JSON.parse(readFileSync(outPath, 'utf8'));
    if (doc?.timbreVersion !== TIMBRE_VERSION) return null;
    return Number.isFinite(doc?.counts?.vectors) ? doc.counts.vectors : null;
  } catch { return null; }
}

if (process.argv[1] && process.argv[1].endsWith('fold-timbre.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
