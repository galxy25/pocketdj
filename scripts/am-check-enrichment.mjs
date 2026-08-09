#!/usr/bin/env node
// ENRICHMENT REGRESSION GUARD — refuse to publish an index that has LESS out-of-band
// enrichment than the one already committed. Exit 0 = safe to ship, exit 1 = coverage
// collapsed.
//
// WHY this exists: every enrichment field in the Apple Music index is rebuild-lossy —
// index-apple-music.mjs regenerates songs from Library.xml and emits none of them, so they
// survive only because am-merge-catalog-ids.mjs carries them forward from the committed
// index. That makes the merge a SINGLE POINT OF FAILURE with no alarm on it: if the merge
// runs against an `--old` that is itself missing a field (e.g. the agent's clone tracks a
// branch the enrichment commits were never pushed to), the carry-forward fills zero, the
// rebuilt index ships with the field gone catalog-wide, and the git-diff guard waves it
// through because the diff is enormous and "expected".
//
// That is not hypothetical — it is how 14,390 appleMusicIdExplicit ids reached S3 as zero:
// "prefer explicit" silently reverted to the primary (clean) cut on every song, streaming
// the clean edition while a download of the same song still played the explicit one (the
// rip captures the user's own file, which is the right edition). One assertion here would
// have stopped the deploy instead.
//
//   node scripts/am-check-enrichment.mjs --old <committed.json> --new <would-be-published.json>

import { readFileSync } from 'node:fs';

function arg(name) { const i = process.argv.indexOf(name); return i >= 0 ? process.argv[i + 1] : undefined; }
const oldPath = arg('--old'), newPath = arg('--new');
if (!oldPath || !newPath) {
  console.error('usage: node scripts/am-check-enrichment.mjs --old <committed.json> --new <new.json>');
  process.exit(2);
}

// Each field is counted over songs, never over the raw file, so a shrinking library can't
// masquerade as a coverage gain.
const FIELDS = ['appleMusicId', 'appleMusicIdExplicit', 'appleMusicIdClean', 'explicit'];
const coverage = (path) => {
  const songs = JSON.parse(readFileSync(path, 'utf8')).songs || [];
  const c = Object.fromEntries(FIELDS.map((f) => [f, 0]));
  for (const s of songs) for (const f of FIELDS) if (s[f]) c[f]++;
  return { songs: songs.length, ...c };
};

const before = coverage(oldPath), after = coverage(newPath);

// TOLERANCE: songs genuinely leave the library, so a proportional dip is normal. Only a
// collapse is a bug — anything under 90 % of the prior count, and ANY total wipe of a field
// that used to be populated (the exact shape of the failure above).
const failures = [];
for (const f of FIELDS) {
  if (before[f] === 0) continue;                       // nothing to lose
  if (after[f] === 0 || after[f] < before[f] * 0.9) {
    failures.push(`${f}: ${before[f]} → ${after[f]}`);
  }
}

const fmt = (c) => FIELDS.map((f) => `${f}=${c[f]}`).join(' ');
console.error(`  committed: songs=${before.songs} ${fmt(before)}`);
console.error(`  candidate: songs=${after.songs} ${fmt(after)}`);

if (failures.length) {
  console.error(`✗ am-check-enrichment: enrichment coverage COLLAPSED — refusing to publish:`);
  for (const f of failures) console.error(`    ${f}`);
  console.error(`  These fields are rebuild-lossy and live ONLY in the committed index. A drop`);
  console.error(`  this size means the carry-forward (scripts/am-merge-catalog-ids.mjs) ran`);
  console.error(`  against an --old that lacks them — check that the enrichment commits are`);
  console.error(`  actually on the branch this checkout tracks before re-running.`);
  process.exit(1);
}
console.error('✓ am-check-enrichment: enrichment coverage preserved');
