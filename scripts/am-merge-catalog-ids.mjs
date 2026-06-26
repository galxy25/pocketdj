#!/usr/bin/env node
// Merge resolved `appleMusicId` (the Apple catalog "adam id" / store id) from an OLD index onto a
// freshly-rebuilt NEW index, keyed by song id, and write the result to --out.
//
// WHY this exists: the cron agent rebuilds `public/apple-music-index.json` from Library.xml, but a
// raw rebuild does NOT know the storeIds. Those are baked in OUT-OF-BAND by the multi-day iTunes
// crawl (scripts/resolve-apple-music-catalog.mjs), which writes them straight into the COMMITTED
// `public/apple-music-index.json`; its cache ndjson (index-out/apple-music/catalog-cache.ndjson)
// is gitignored and ABSENT in the agent's dedicated clone. So the committed index is the ONLY copy
// of the ~76k resolved ids — and a `cp rebuilt → public` would strip every one, dropping Apple
// Music streaming back to local-ripping. This merge carries them forward.
//
// Idempotent: an id already present on a NEW song wins (the rebuild may itself carry one); only
// missing ones are filled from OLD. Output is single-line JSON (matches the resolver's writer), so
// re-runs from the same snapshot are byte-stable and the agent's git-diff guard collapses no-ops.
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
for (const s of (oldIdx.songs || [])) if (s.appleMusicId) ids.set(s.id, s.appleMusicId);

const next = JSON.parse(readFileSync(newPath, 'utf8'));
let filled = 0;
for (const s of (next.songs || [])) {
  if (!s.appleMusicId) { const a = ids.get(s.id); if (a) { s.appleMusicId = a; filled++; } }
}
// refresh the self-reported coverage count if the manifest carries one
const withId = (next.songs || []).filter((s) => s.appleMusicId).length;
if (next.manifest && next.manifest.counts) next.manifest.counts.songsWithAppleMusicId = withId;

writeFileSync(outPath, JSON.stringify(next));
console.error(`✓ am-merge-catalog-ids: filled ${filled} appleMusicId(s) from ${oldPath} (old had ${ids.size} resolved; new total ${withId}/${(next.songs || []).length})`);
