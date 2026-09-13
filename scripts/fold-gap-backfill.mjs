#!/usr/bin/env node
// One-shot fold for the 2026-09-12 vinyl index gap backfill (P1: RipBurnMix files
// missing from My Vinyl). Appends the mini-index's albums+songs into
// public/current-index.json, and REPLACES the mislabeled Stylistics album
// (alb_88246691afe0 "Thank You Baby" — a weak Discogs match that renamed the real
// "You Are Beautiful" file) with its re-enriched record, transplanting the old
// record's audioTracks (they describe the FILE, which didn't change) onto the new
// album + per-song bpm/key/startMs/endMs by trackNumber, mirroring apply-audio.
//
//   node scripts/fold-gap-backfill.mjs --index public/current-index.json \
//     --add index-out/gap-full/index.json --replace index-out/gap-fix/index.json \
//     --replace-old alb_88246691afe0 [--dry-run]
import { readFileSync, writeFileSync, copyFileSync } from 'node:fs';

const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const dryRun = process.argv.includes('--dry-run');
const indexPath = arg('--index', 'public/current-index.json');
const addPath = arg('--add');
const replacePath = arg('--replace');
const replaceOldId = arg('--replace-old');

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const albumIds = new Set(idx.albums.map(a => a.id));
const songIds = new Set(idx.songs.map(s => s.id));
let added = 0, replaced = 0;

function addAlbum(album, songs) {
  if (albumIds.has(album.id)) { console.error(`  SKIP ${album.id} (${album.artist} — ${album.name}): id already in index`); return; }
  const clash = songs.find(s => songIds.has(s.id));
  if (clash) { console.error(`  SKIP ${album.id}: song id clash ${clash.id}`); return; }
  idx.albums.push(album);
  idx.songs.push(...songs);
  albumIds.add(album.id); songs.forEach(s => songIds.add(s.id));
  added++;
  console.error(`  + ${album.id} ${album.artist} — ${album.name} (${songs.length} songs)`);
}

if (addPath) {
  const mini = JSON.parse(readFileSync(addPath, 'utf8'));
  for (const album of mini.albums) {
    const songs = mini.songs.filter(s => s.albumId === album.id);
    addAlbum(album, songs);
  }
}

if (replacePath && replaceOldId) {
  const mini = JSON.parse(readFileSync(replacePath, 'utf8'));
  const oldAlbum = idx.albums.find(a => a.id === replaceOldId);
  if (!oldAlbum) { console.error(`  replace: old album ${replaceOldId} not found`); process.exit(1); }
  const newAlbum = mini.albums.find(a => a.pointer?.originalFilename === oldAlbum.pointer?.originalFilename);
  if (!newAlbum) { console.error('  replace: no mini album shares the old album\'s originalFilename'); process.exit(1); }
  const newSongs = mini.songs.filter(s => s.albumId === newAlbum.id);
  // Transplant the audio stage: album-level segments verbatim, per-song fields by
  // trackNumber (segment i ↔ trackNumber i+1 — the apply-audio convention).
  if (oldAlbum.audioTracks?.length) {
    newAlbum.audioTracks = oldAlbum.audioTracks;
    for (const s of newSongs) {
      const seg = oldAlbum.audioTracks.find(t => t.trackNumber === s.trackNumber);
      if (!seg) continue;
      s.bpm = seg.bpm; s.key = seg.key; s.camelot = seg.camelot;
      s.pointer = { ...(s.pointer || {}), startMs: seg.startMs, endMs: seg.endMs };
    }
  }
  const oldSongIds = new Set(oldAlbum.trackList || []);
  idx.albums = idx.albums.filter(a => a.id !== replaceOldId);
  idx.songs = idx.songs.filter(s => !(oldSongIds.has(s.id) || s.albumId === replaceOldId));
  albumIds.delete(replaceOldId); oldSongIds.forEach(id => songIds.delete(id));
  addAlbum(newAlbum, newSongs);
  replaced++;
  console.error(`  ~ replaced ${replaceOldId} ("${oldAlbum.artist} — ${oldAlbum.name}") → ${newAlbum.id} ("${newAlbum.artist} — ${newAlbum.name}")`);
}

console.error(`fold: +${added} albums (${replaced} replacement) → albums=${idx.albums.length} songs=${idx.songs.length}`);
if (dryRun) { console.error('dry run — nothing written'); process.exit(0); }
copyFileSync(indexPath, indexPath + '.pre-gap-backfill.bak');
writeFileSync(indexPath, JSON.stringify(idx));
console.error(`wrote ${indexPath} (backup at .pre-gap-backfill.bak)`);
