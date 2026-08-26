#!/usr/bin/env node
// build-timbre-aliases — the id-alias map for songs whose RECORDING already has analysed audio
// under a DIFFERENT persistent id (the same cut living in two catalogs: e.g. an Apple Music
// library row and the vinyl/digital rip of the same recording). ~1,255 collection songs were
// measured in this state. The alias lets fold-timbre attach the existing analysis to the
// collection song's id via an EXPLICIT {alias} field — never by copying rows blind.
//
//   node scripts/build-timbre-aliases.mjs [--manifest <path>|s3] [--lane1-state <path>]
//        [--out data/timbre-aliases.json] [--dry-run]
//
// ── THE MATCHER IS THE TIGHT ONE, DELIBERATELY ────────────────────────────────────────────────
// Over-aliasing corrupts: a wrong alias hands a song ANOTHER recording's vector, which is worse
// than no vector (the fabricated-row lesson, f2b427c5). So an alias requires, via the SAME
// normalization the rip server trusts for capture decisions (scripts/lib/am-match.mjs):
//   · artist agreement          (normArtist — case/punct/diacritics/feat-tail insensitive)
//   · base-title agreement      (comparableTitle — cosmetic parens dropped)
//   · version-marker agreement  (comparableTitle KEEPS recording-altering markers: a mix/edit/
//                                instrumental/live marker on one side and not the other is a
//                                DIFFERENT recording → no alias; keep the user's cut)
// plus a LENGTH sanity guard on top: when both sides carry a duration they must agree within
// max(20 s, 10%) — same-title different-length is an unlabeled different cut. Ambiguity
// (several audio-bearing twins under one key) resolves to the closest length, then lexicographic
// id, deterministically; the alternatives are recorded.
//
// Lane 1 (rip-backfill) records the same mapping in its state file; when one is given/found it
// is read FIRST and every entry is re-validated with this same matcher — a lane-1 alias that
// fails tight matching is rejected loudly, not trusted.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { normArtist, comparableTitle } from './lib/am-match.mjs';
import { buildWorkList } from './timbre-batch.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export const aliasKey = (artist, title) => {
  const na = normArtist(artist); const ct = comparableTitle(title);
  if (!na || !ct) return null;                       // an empty side can match anything — refuse
  return na + '\x00' + ct;
};

/// GUARD against a SILENT COLLAPSE. The alias TARGETS come from buildWorkList(), which needs
/// POCKETDJ_ANALOG_BASE (/Volumes/RipBurnMix) mounted: with the volume unmounted every vinyl
/// target vanishes, the map shrinks from ~2,900 to near zero, and the fold quietly DELETES that
/// much coverage while exiting 0. A shrink of more than `tol` versus the previous artifact's
/// counts.audioBearing is a broken environment, not a real change — refuse and say so.
/// Returns null when the write is fine, or a reason string when it must be refused.
export function shrinkGuard(prevAudioBearing, nextAudioBearing, tol = 0.05) {
  if (!Number.isFinite(prevAudioBearing) || prevAudioBearing <= 0) return null;   // no baseline yet
  if (nextAudioBearing >= prevAudioBearing * (1 - tol)) return null;
  return `audio-bearing targets collapsed ${prevAudioBearing} → ${nextAudioBearing} `
    + `(> ${Math.round(tol * 100)}% shrink) — is POCKETDJ_ANALOG_BASE mounted? refusing to write`;
}

export function lengthsAgree(aMs, bMs) {
  if (!Number.isFinite(aMs) || !Number.isFinite(bMs)) return true;   // unknown → no evidence against
  const d = Math.abs(aMs - bMs);
  // max(20 s, 10%): vinyl segmentation slop (lead-in/fade cut points) is seconds, an unlabeled
  // different cut (album vs single edit) is tens of seconds to minutes. 20 s absorbs the slop on
  // short songs; 10% scales for long ones.
  return d <= Math.max(20000, 0.10 * Math.max(aMs, bMs));
}

/// Pure: compute the alias map.
///  targets: [{id, artist, name, length}] — songs that HAVE audio (the timbre work list).
///  sources: [{id, artist, name, length}] — songs with NO audio of their own.
/// Returns { aliases: {fromId: {to, dLenMs, alternatives}}, rejected: [{from, to, reason}] }.
export function computeAliases(targets, sources, lane1 = null) {
  const byKey = new Map();
  const targetById = new Map();
  for (const t of targets) {
    targetById.set(t.id, t);
    const k = aliasKey(t.artist, t.name);
    if (!k) continue;
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k).push(t);
  }
  const aliases = {};
  const rejected = [];

  // Lane 1's mapping first — validated with the SAME rule, never trusted blind.
  for (const [from, to] of Object.entries(lane1 || {})) {
    const src = sources.find((s) => s.id === from);
    const tgt = targetById.get(to);
    if (!src || !tgt) { rejected.push({ from, to, reason: 'lane1-unknown-id' }); continue; }
    const kFrom = aliasKey(src.artist, src.name); const kTo = aliasKey(tgt.artist, tgt.name);
    if (!kFrom || kFrom !== kTo) { rejected.push({ from, to, reason: 'lane1-tight-match-failed' }); continue; }
    if (!lengthsAgree(src.length, tgt.length)) { rejected.push({ from, to, reason: 'lane1-length-mismatch' }); continue; }
    aliases[from] = { to, dLenMs: Number.isFinite(src.length) && Number.isFinite(tgt.length) ? Math.abs(src.length - tgt.length) : null };
  }

  for (const s of sources) {
    if (aliases[s.id]) continue;
    const k = aliasKey(s.artist, s.name);
    if (!k) continue;
    const cands = (byKey.get(k) || []).filter((t) => t.id !== s.id && lengthsAgree(s.length, t.length));
    if (!cands.length) continue;
    // Deterministic pick: closest known length first, then lexicographic id.
    const scored = cands.map((t) => ({
      t,
      d: Number.isFinite(s.length) && Number.isFinite(t.length) ? Math.abs(s.length - t.length) : Infinity,
    })).sort((x, y) => (x.d - y.d) || (x.t.id < y.t.id ? -1 : 1));
    const best = scored[0];
    aliases[s.id] = {
      to: best.t.id,
      dLenMs: best.d === Infinity ? null : best.d,
      ...(scored.length > 1 ? { alternatives: scored.slice(1).map((x) => x.t.id) } : {}),
    };
  }
  return { aliases, rejected };
}

// ── CLI ─────────────────────────────────────────────────────────────────────────────────────────
async function main() {
  const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
  const dryRun = process.argv.includes('--dry-run');
  const outPath = arg('--out', join(REPO, 'data', 'timbre-aliases.json'));

  const manifestPath = arg('--manifest', join(homedir(), '.pocketdj', 'rips', 'manifest.json'));
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const indexes = ['current-index.json', 'apple-music-index.json', 'digital-index.json']
    .map((n) => [n, JSON.parse(readFileSync(join(REPO, 'public', n), 'utf8'))]);
  const analogIndex = indexes[0][1];

  // Audio-bearing = exactly the timbre work list (same code path — one definition of "has audio").
  const { existsSync: exists } = await import('node:fs');
  const analogBase = (process.env.POCKETDJ_ANALOG_BASE || '/Volumes/RipBurnMix').replace(/^~/, homedir());
  const { tasks } = buildWorkList({ manifest, analogIndex, analogBase, exists });
  const audioIds = new Set(tasks.map((t) => t.id));

  const targets = []; const sources = []; const seen = new Set();
  for (const [, idx] of indexes) {
    for (const s of idx.songs || []) {
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      const row = { id: s.id, artist: s.artist, name: s.name, length: s.length ?? null };
      (audioIds.has(s.id) ? targets : sources).push(row);
    }
  }

  // Lane 1's state file, if the rip-backfill lane has produced one.
  let lane1 = null;
  const lane1Path = arg('--lane1-state', null);
  const candidates = lane1Path ? [lane1Path] : [
    join(homedir(), '.pocketdj', 'rip-backfill', 'state.json'),
    join(homedir(), '.pocketdj', 'rip-backfill-state.json'),
  ];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const doc = JSON.parse(readFileSync(p, 'utf8'));
      const m = doc.aliases || doc.idAliases || doc.aliasMap || null;
      if (m && typeof m === 'object') {
        lane1 = Object.fromEntries(Object.entries(m).map(([k, v]) => [k, typeof v === 'string' ? v : v?.to]));
        console.error(`[timbre-aliases] lane-1 state: ${p} (${Object.keys(lane1).length} aliases to validate)`);
      }
      break;
    } catch (e) { console.error(`[timbre-aliases] unreadable lane-1 state ${p}: ${e.message}`); }
  }

  const { aliases, rejected } = computeAliases(targets, sources, lane1);
  const doc = {
    v: 1,
    generatedAt: new Date().toISOString(),
    counts: { audioBearing: targets.length, candidates: sources.length,
              aliases: Object.keys(aliases).length, rejectedLane1: rejected.length },
    rejectedLane1: rejected,
    aliases: Object.fromEntries(Object.entries(aliases).sort(([x], [y]) => (x < y ? -1 : 1))),
  };
  console.error(JSON.stringify(doc.counts, null, 1));
  let prev = null;
  try { prev = JSON.parse(readFileSync(outPath, 'utf8'))?.counts?.audioBearing ?? null; } catch { /* first run */ }
  const refuse = shrinkGuard(prev, targets.length, Number(arg('--shrink-tol', '0.05')));
  if (refuse) { console.error(`[timbre-aliases] REFUSED: ${refuse}`); process.exit(1); }
  if (!dryRun) {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(doc, null, 1));
    console.error(`[timbre-aliases] wrote ${outPath}`);
  }
}

if (process.argv[1] && process.argv[1].endsWith('build-timbre-aliases.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
