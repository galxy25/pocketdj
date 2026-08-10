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
//   • artists[] — the TOP-LEVEL artist table (normalized name → Apple Music artist id), baked in by
//     scripts/backfill-artist-ids.mjs and required by the release feed (the artists catalog endpoint
//     takes ARTIST ids, and songs only carry track ids). This one is NOT song-keyed, so it needs its
//     own carry-forward: the loop below walks `next.songs`, and `index-apple-music.mjs` never emits
//     an `artists` key at all — a rebuild would drop the whole table on the floor with no per-song
//     evidence that anything was lost. Its derivation cache (index-out/apple-music/song-meta.ndjson)
//     is gitignored and ABSENT in the agent's clone, exactly the appleMusicId precedent, so the
//     committed index is again the only durable copy. The `songs` counts ARE recomputed against the
//     new song set (they are cheap and local); only the network-derived name→id mapping is carried.
//     Artists that are new since the last backfill are simply absent until it re-runs — the feed
//     degrades to fewer artists, never to a broken document.
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
const songs = next.songs || [];

// Artist table: present-on-new wins (idempotent), else carry the old one forward. The name→id
// mapping is the irreplaceable part; the per-artist song counts are re-derived below against the
// NEW song set so a rebuild that adds or removes tracks doesn't leave stale totals behind.
let artistsCarried = 0;
if (!next.artists && Array.isArray(oldIdx.artists) && oldIdx.artists.length) {
  next.artists = oldIdx.artists.map((a) => ({ ...a }));
  artistsCarried = next.artists.length;
}
if (Array.isArray(next.artists) && next.artists.length) {
  // Must match backfill-artist-ids.mjs's key normalization exactly, or the join silently misses.
  const norm = (s) => String(s).trim().toLowerCase().replace(/\s+/g, ' ');
  const counts = new Map();
  for (const s of songs) {
    if (!s.artist) continue;
    const k = norm(s.artist);
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  for (const a of next.artists) a.songs = counts.get(a.key) || 0;
}

// refresh the self-reported coverage counts if the manifest carries them (mirrors
// refreshManifestCounts() in resolve-explicit-variants.mjs for the variant fields)
const withId = songs.filter((s) => s.appleMusicId).length;
if (next.manifest && next.manifest.counts) {
  next.manifest.counts.songsWithAppleMusicId = withId;
  next.manifest.counts.songsWithExplicitVariant = songs.filter((s) => s.appleMusicIdExplicit).length;
  next.manifest.counts.songsWithCleanVariant = songs.filter((s) => s.appleMusicIdClean).length;
  if (Array.isArray(next.artists)) {
    const norm = (s) => String(s).trim().toLowerCase().replace(/\s+/g, ' ');
    const keys = new Set(next.artists.map((a) => a.key));
    next.manifest.counts.artists = next.artists.length;
    next.manifest.counts.songsWithArtistId = songs.filter((s) => s.artist && keys.has(norm(s.artist))).length;
  }
}

writeFileSync(outPath, JSON.stringify(next));
console.error(`✓ am-merge-catalog-ids: filled ${filled} appleMusicId(s) + ${explFilled} explicit flag(s) + ${variantFilled} variant id(s) + carried ${artistsCarried} artist(s) from ${oldPath} (old had ${ids.size} ids / ${expl.size} explicit / ${explIds.size}+${cleanIds.size} variant / ${(oldIdx.artists || []).length} artists; new total ${withId}/${songs.length})`);
