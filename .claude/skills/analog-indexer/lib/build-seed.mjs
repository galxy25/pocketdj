#!/usr/bin/env node
// Build the LEAN seed the app auto-loads on first boot (public/current-index.json) from
// the full built index. The seed keeps everything the UI needs — album/song metadata,
// coverArtSources, audio (bpm/key/segments), sentiment keywords — but STRIPS the bulky
// per-song `lyrics` text (lyrics are only needed by the out-of-band sentiment indexer,
// not shown in the app), which keeps the seed ~9MB instead of ~23MB.
//
//   node build-seed.mjs [--index index-out/current/index.json] [--out public/current-index.json]
import { readFileSync, writeFileSync } from 'node:fs';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const outPath = arg('--out', 'public/current-index.json');

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
let stripped = 0;
for (const s of idx.songs) {
  if (s.lyrics) {
    delete s.lyrics;
    stripped++;
  }
}
writeFileSync(outPath, JSON.stringify(idx));

const withSources = idx.albums.filter((a) => a.coverArtSources && a.coverArtSources.length).length;
const bytes = Buffer.byteLength(JSON.stringify(idx));
process.stderr.write(
  `build-seed: ${idx.albums.length} albums (${withSources} w/ coverArtSources), ${idx.songs.length} songs, ` +
    `stripped lyrics from ${stripped} -> ${outPath} (${(bytes / 1e6).toFixed(1)}MB)\n`,
);
