#!/usr/bin/env node
// Emit per-song lyrics text files for LAZY in-app loading. The lean seed
// (public/current-index.json) strips lyrics to stay small; instead we host one tiny
// text file per song WITH lyrics at /lyrics/<songId>.txt (same-origin via CloudFront),
// and the app fetches+caches a song's lyrics only when its detail card is opened
// (SongDetailModal) — so an install only ever stores the lyrics you actually look at.
//
//   node build-lyrics-cdn.mjs [--index index-out/current/index.json] [--out index-out/lyrics]
// Then upload <out> to s3://<web-bucket>/lyrics/ (see scripts/lyrics-cdn.sh).
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const outDir = arg('--out', 'index-out/lyrics');

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

let n = 0;
for (const s of idx.songs) {
  if (s.lyrics && s.lyrics.length) {
    writeFileSync(join(outDir, `${s.id}.txt`), s.lyrics);
    n++;
  }
}
process.stderr.write(`build-lyrics-cdn: wrote ${n} lyrics files -> ${outDir}/ (of ${idx.songs.length} songs)\n`);
