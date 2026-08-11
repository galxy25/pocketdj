#!/usr/bin/env node
// MEASURE the incumbent-artist share of the collection tiles — the number the owner's 50%
// newcomer floor is about — on the REAL pockets and the REAL catalog, BEFORE and AFTER the
// composition constraint.
//
// Owner, verbatim: "the recommendations are so biased on artist similarity, we should cap our
// for you per collection at max 50% of suggestions for artists that are already in the pocket,
// that way we can learn the features of related artists to make our recommendations more novel
// and collection expanding vs model collapse."
//
// INCUMBENT = a suggestion row whose artist is ALREADY IN the collection, by CREDIT identity
// (`creditArtistKeys` — the split machinery, imported from the Lambda so this measures the
// shipped test, not a lookalike). Raw-string matching is the known trap: both Dinner Party
// albums are filed under the five-name collaboration credit.
//
// Collections come from the owner's own store backup (pockets.json + playlists.json inside
// ~/.pocketdj/backfill/source-backup.pocketdj — the same population `CollectionsStore
// .suggestibleCollections()` feeds the tiles); the ranking is the measurement harness's port of
// `ZoneEngine.suggestions` (scripts/measure-rec-concentration.mjs), run in the SHIPPED
// multiplicative shape. AFTER = `composeIncumbentCap` (imported from the Lambda — the same
// compose the device mirrors) over the identical ranked candidates.
//
//   node scripts/measure-incumbent-share.mjs [--backup ~/.pocketdj/backfill/source-backup.pocketdj]
//                                            [--json out.json]

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { byId, suggestions, TUNING_AFTER } from './measure-rec-concentration.mjs';
import { creditArtistKeys, composeIncumbentCap } from './lambda/rec-engine/index.mjs';

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; };
const BACKUP = arg('--backup', join(homedir(), '.pocketdj', 'backfill', 'source-backup.pocketdj'));
const JSON_OUT = arg('--json', null);
const SHARE = 0.5;
const LIMIT = 25;
const CAP = 3;

const readEntry = (name) =>
  JSON.parse(execFileSync('unzip', ['-p', BACKUP, name], { maxBuffer: 64 * 1024 * 1024 }).toString());

// ── The owner's collections, the same shapes CollectionsStore holds ─────────────────────────────
const pockets = readEntry('pockets.json').map((p) => ({
  id: p.id, kind: 'pocket', name: p.name, songIds: (p.songIds || []).filter((x) => byId.has(x)),
}));
const playlists = readEntry('playlists.json').map((p) => ({
  id: p.id, kind: 'playlist', name: p.name,
  songIds: (p.sequences || []).flatMap((s) => (s.children || [])
    .filter((c) => c.kind === 'song' && c.songId).map((c) => c.songId))
    .filter((x) => byId.has(x)),
}));
const collections = [...playlists, ...pockets].filter((c) => c.songIds.length >= 5);

// ── The incumbent test — credit identity, memoized per credit string ────────────────────────────
const keyCache = new Map();
const keysOf = (credit) => {
  let k = keyCache.get(credit);
  if (k === undefined) { k = creditArtistKeys(credit); keyCache.set(credit, k); }
  return k;
};
const memberCreditSet = (songIds) => {
  const set = new Set();
  for (const id of songIds) {
    const a = byId.get(id)?.artist;
    if (a) for (const k of keysOf(a)) set.add(k);
  }
  return set;
};
const isIncumbent = (artist, memberKeys) => keysOf(artist).some((k) => memberKeys.has(k));

// ── Measure ─────────────────────────────────────────────────────────────────────────────────────
const rows = [];
for (const c of collections) {
  const r = suggestions(c.songIds, TUNING_AFTER);
  if (!r || !r.picks.length) continue;
  const memberKeys = memberCreditSet(c.songIds);
  const before = r.picks.map((p) => ({ id: p.id, capKey: p.primaryKey,
                                       isIncumbent: isIncumbent(p.artist, memberKeys) }));
  // AFTER: the identical ranked candidates, composed under the newcomer floor.
  const ranked = r.scored.map((p) => ({ id: p.id, capKey: p.primaryKey,
                                        isIncumbent: isIncumbent(p.artist, memberKeys) }));
  const after = composeIncumbentCap(ranked, { limit: LIMIT, maxPerArtist: CAP, incumbentMaxShare: SHARE });
  const share = (list) => (list.length ? list.filter((x) => x.isIncumbent).length / list.length : 0);
  rows.push({
    id: c.id, kind: c.kind, name: c.name, members: c.songIds.length,
    n: before.length, nAfter: after.length,
    incBefore: before.filter((x) => x.isIncumbent).length,
    incAfter: after.filter((x) => x.isIncumbent).length,
    shareBefore: share(before), shareAfter: share(after),
    unchanged: before.length === after.length && before.every((x, i) => x.id === after[i].id),
  });
}

const f = (x) => `${(100 * x).toFixed(1)}%`;
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
rows.sort((a, b) => b.shareBefore - a.shareBefore);

console.log(`collections measured: ${rows.length} (of ${collections.length} with ≥5 resolvable members; `
  + `${playlists.length} playlists + ${pockets.length} pockets in the backup)`);
console.log(`ranking: harness port of ZoneEngine.suggestions, shipped multiplicative shape · limit ${LIMIT} · cap ${CAP}/artist`);
console.log('');
console.log('── BEFORE (today\'s composition: per-artist cap only) ──');
const totB = rows.reduce((s, r) => s + r.n, 0);
const incB = rows.reduce((s, r) => s + r.incBefore, 0);
console.log(`  incumbent rows overall: ${incB}/${totB} = ${f(incB / totB)}   mean per-collection share ${f(mean(rows.map((r) => r.shareBefore)))}`);
console.log(`  collections over the 50% cap: ${rows.filter((r) => r.shareBefore > 0.5).length}/${rows.length}`
  + `   at 100%: ${rows.filter((r) => r.shareBefore === 1).length}`);
console.log('  worst 12:');
for (const r of rows.slice(0, 12)) {
  console.log(`    ${f(r.shareBefore).padStart(6)}  ${r.kind.padEnd(8)} ${r.name}  (${r.incBefore}/${r.n} rows, ${r.members} members)`);
}
console.log('');
console.log('── AFTER (composed under the 50% newcomer floor) ──');
const totA = rows.reduce((s, r) => s + r.nAfter, 0);
const incA = rows.reduce((s, r) => s + r.incAfter, 0);
console.log(`  incumbent rows overall: ${incA}/${totA} = ${f(incA / totA)}   mean per-collection share ${f(mean(rows.map((r) => r.shareAfter)))}`);
const overCap = rows.filter((r) => r.incAfter > Math.floor(r.nAfter * SHARE));
console.log(`  collections over ⌊n·0.5⌋ after: ${overCap.length}  (0 expected — fail-open lists excepted)`);
for (const r of overCap) console.log(`    OVER: ${r.name} ${r.incAfter}/${r.nAfter}`);
const shortened = rows.filter((r) => r.nAfter < r.n);
console.log(`  lists shortened by the floor: ${shortened.length} (0 expected — the floor may reorder, never starve)`);
const underBefore = rows.filter((r) => r.incBefore <= Math.floor(r.n * SHARE));
const disturbed = underBefore.filter((r) => !r.unchanged);
console.log(`  collections already at/under the cap: ${underBefore.length} — disturbed by the compose: ${disturbed.length} (0 expected)`);
for (const r of disturbed) console.log(`    DISTURBED: ${r.name}`);
console.log(`  lists changed at all: ${rows.filter((r) => !r.unchanged).length}/${rows.length}`);

if (JSON_OUT) {
  writeFileSync(JSON_OUT, JSON.stringify({ rows }, null, 1));
  console.log(`\nwrote ${JSON_OUT}`);
}
