#!/usr/bin/env node
// Merge OUT-OF-BAND, rebuild-lossy fields from an OLD index onto a freshly-rebuilt NEW index, keyed
// by song id, and write the result to --out. Four fields are carried forward:
//
//   • appleMusicId — the Apple catalog "adam id" / store id, baked in by the multi-day iTunes crawl
//     (scripts/resolve-apple-music-catalog.mjs) straight into the COMMITTED public/apple-music-index.json.
//     Its cache ndjson (index-out/apple-music/catalog-cache.ndjson) is gitignored and ABSENT in the
//     agent's dedicated clone, so the committed index is the ONLY copy of the ~76k resolved ids — a
//     `cp rebuilt → public` would strip every one, dropping Apple Music streaming back to local-ripping.
//
//   • explicit — Music does NOT expose the explicit flag over AppleScript ("descriptor type mismatch"),
//     so the headless dump (scripts/dump-apple-music-library.mjs) can't capture it and a rebuild from a
//     dump-sourced XML sets explicit=false everywhere. The committed index holds ~27k true flags from a
//     prior native export; carry them forward so existing tracks keep their rating. (A native Library.xml
//     rebuild already has Explicit, so this is a no-op there — only the dump path needs it. Genuinely-new
//     tracks land explicit=false until backfilled out-of-band.)
//
//   • appleMusicIdExplicit / appleMusicIdClean — the edition-variant catalog ids, baked in by the
//     variant crawl (scripts/resolve-explicit-variants.mjs) straight into the COMMITTED index, exactly
//     the appleMusicId precedent: the crawl's ndjson cache lives in gitignored index-out/, so the
//     committed index is the ONLY durable copy. index-apple-music.mjs never emits these fields, so a
//     rebuild without this carry-forward silently wipes every variant id — cleanOnly collections then
//     DROP their explicit songs at ▶ (skip-not-fallback) and 'prefer explicit' reverts to primary cuts.
//
// Idempotent: a value already present on the NEW song wins (a native rebuild carries both); only missing
// appleMusicId / un-set explicit are filled from OLD. Output is single-line JSON (matches the resolver's
// writer), so re-runs from the same snapshot are byte-stable and the agent's git-diff guard collapses no-ops.
//
//   node --max-old-space-size=4096 scripts/am-merge-catalog-ids.mjs \
//     --old public/apple-music-index.json --new <rebuilt.json> --out <merged.json>

import { readFileSync, writeFileSync } from 'node:fs';

function arg(name) { const i = process.argv.indexOf(name); return i >= 0 ? process.argv[i + 1] : undefined; }
const oldPath = arg('--old'), newPath = arg('--new'), outPath = arg('--out');
if (!oldPath || !newPath || !outPath) {
  console.error('usage: node scripts/am-merge-catalog-ids.mjs --old <committed.json> --new <rebuilt.json> --out <merged.json>');
  process.exit(1);
}

const oldIdx = JSON.parse(readFileSync(oldPath, 'utf8'));
const ids = new Map();
const expl = new Set();
const explIds = new Map();   // appleMusicIdExplicit — variant-crawl output, rebuild-lossy
const cleanIds = new Map();  // appleMusicIdClean   — variant-crawl output, rebuild-lossy
for (const s of (oldIdx.songs || [])) {
  if (s.appleMusicId) ids.set(s.id, s.appleMusicId);
  if (s.explicit) expl.add(s.id);
  if (s.appleMusicIdExplicit) explIds.set(s.id, s.appleMusicIdExplicit);
  if (s.appleMusicIdClean) cleanIds.set(s.id, s.appleMusicIdClean);
}

const next = JSON.parse(readFileSync(newPath, 'utf8'));
let filled = 0, explFilled = 0, variantFilled = 0;
for (const s of (next.songs || [])) {
  if (!s.appleMusicId) { const a = ids.get(s.id); if (a) { s.appleMusicId = a; filled++; } }
  if (!s.explicit && expl.has(s.id)) { s.explicit = true; explFilled++; }
  // Variant ids: present-on-new wins (idempotent re-runs), only absent fields are filled.
  if (!s.appleMusicIdExplicit) { const v = explIds.get(s.id); if (v) { s.appleMusicIdExplicit = v; variantFilled++; } }
  if (!s.appleMusicIdClean) { const v = cleanIds.get(s.id); if (v) { s.appleMusicIdClean = v; variantFilled++; } }
}
// refresh the self-reported coverage counts if the manifest carries them (mirrors
// refreshManifestCounts() in resolve-explicit-variants.mjs for the variant fields)
const songs = next.songs || [];
const withId = songs.filter((s) => s.appleMusicId).length;
if (next.manifest && next.manifest.counts) {
  next.manifest.counts.songsWithAppleMusicId = withId;
  next.manifest.counts.songsWithExplicitVariant = songs.filter((s) => s.appleMusicIdExplicit).length;
  next.manifest.counts.songsWithCleanVariant = songs.filter((s) => s.appleMusicIdClean).length;
}

writeFileSync(outPath, JSON.stringify(next));
console.error(`✓ am-merge-catalog-ids: filled ${filled} appleMusicId(s) + ${explFilled} explicit flag(s) + ${variantFilled} variant id(s) from ${oldPath} (old had ${ids.size} ids / ${expl.size} explicit / ${explIds.size}+${cleanIds.size} variant; new total ${withId}/${songs.length})`);
