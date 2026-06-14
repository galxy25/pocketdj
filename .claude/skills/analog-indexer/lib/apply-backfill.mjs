#!/usr/bin/env node
// Fold the cover + lyrics BACKFILL shards into the index (idempotent):
//   covers-backfill.jsonl : {albumId, coverArt}  -> album.coverArt (only if missing)
//   lyrics-backfill.jsonl : {songId, lyrics}     -> song.lyrics + lyricsStatus 'found'
//
//   node apply-backfill.mjs [--index index-out/current/index.json] [--dir index-out/shards-pw]
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const dir = arg('--dir', 'index-out/shards-pw');

function readJsonl(p) {
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const albumById = new Map(idx.albums.map((a) => [a.id, a]));
const songById = new Map(idx.songs.map((s) => [s.id, s]));

let covers = 0;
for (const r of readJsonl(join(dir, 'covers-backfill.jsonl'))) {
  const a = albumById.get(r.albumId);
  if (a && r.coverArt && !a.coverArt) {
    a.coverArt = r.coverArt;
    covers++;
  }
}

let lyrics = 0;
for (const r of readJsonl(join(dir, 'lyrics-backfill.jsonl'))) {
  const s = songById.get(r.songId);
  if (s && r.lyrics && !s.lyrics) {
    s.lyrics = r.lyrics;
    s.lyricsStatus = 'found';
    lyrics++;
  }
}

writeFileSync(indexPath, JSON.stringify(idx));
const withCover = idx.albums.filter((a) => a.coverArt).length;
const withLyrics = idx.songs.filter((s) => s.lyrics).length;
process.stderr.write(
  `applied backfill: +${covers} covers (now ${withCover}/${idx.albums.length}), +${lyrics} lyrics (now ${withLyrics}/${idx.songs.length}) -> ${indexPath}\n`,
);
