#!/usr/bin/env node
// Mislabel-audit split-fix lane (2026-09-12): repair albums whose RELEASE is right but
// whose artist/name came from a bad CamelCase split ("Kim — Weston Emotion Single",
// "J — Kwon Tipsy Single"). IN-PLACE field rename with STABLE ids — these albums may be
// ripped (S3 manifest keys their existing sng_/alb_ ids) or playlisted, so ids must not
// move; nothing at runtime re-derives ids from names. Songs' artist fields follow the
// album's corrected artist ONLY when they equaled the old album artist (a per-track
// featured credit is kept). For one-track synth singles the track name mirrors the
// corrected single name (minus any trailing "Single" marker).
//
//   node scripts/apply-split-fixes.mjs --index public/current-index.json \
//     --lanes index-out/mislabel-audit/repair-lanes.json [--extra ids.json] [--dry-run]
import { readFileSync, writeFileSync, copyFileSync } from 'node:fs';

const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const dryRun = process.argv.includes('--dry-run');
const indexPath = arg('--index', 'public/current-index.json');
const lanes = JSON.parse(readFileSync(arg('--lanes', 'index-out/mislabel-audit/repair-lanes.json'), 'utf8'));
const skip = new Set(JSON.parse(arg('--skip-json', 'null')) || []);

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const byId = new Map(idx.albums.map(a => [a.id, a]));
const songsByAlbum = new Map();
for (const s of idx.songs) {
  if (!songsByAlbum.has(s.albumId)) songsByAlbum.set(s.albumId, []);
  songsByAlbum.get(s.albumId).push(s);
}

let applied = 0;
for (const fix of lanes.splitFix) {
  if (skip.has(fix.id)) { console.error(`  SKIP ${fix.id} (excluded)`); continue; }
  const album = byId.get(fix.id);
  if (!album) { console.error(`  MISS ${fix.id}`); continue; }
  const [toArtist, toName] = fix.to.split(' — ');
  if (!toArtist || !toName || toName === '?') { console.error(`  SKIP ${fix.id}: unusable target "${fix.to}"`); continue; }
  const oldArtist = album.artist;
  console.error(`  ~ ${album.id}: "${album.artist} — ${album.name}" → "${toArtist} — ${toName}"`);
  album.artist = toArtist;
  album.name = toName;
  const songs = songsByAlbum.get(album.id) || [];
  for (const s of songs) {
    if (s.artist === oldArtist) s.artist = toArtist;
    if (songs.length === 1) s.name = toName.replace(/[\s(]*Single\)?$/i, '').trim() || s.name;
  }
  applied++;
}
console.error(`split-fix: ${applied}/${lanes.splitFix.length} applied`);
if (dryRun) { console.error('dry run — nothing written'); process.exit(0); }
copyFileSync(indexPath, indexPath + '.pre-split-fix.bak');
writeFileSync(indexPath, JSON.stringify(idx));
console.error(`wrote ${indexPath}`);
