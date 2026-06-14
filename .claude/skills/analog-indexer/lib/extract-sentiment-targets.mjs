#!/usr/bin/env node
// Extract sentiment-UPGRADE candidates from a built index and shard them into batch
// files on disk — the input side of the Claude/Haiku sentiment-upgrade workflow
// (workflow/sentiment-upgrade.workflow.js) and the apply-sentiment-upgrade.mjs fold.
//
// A "candidate" is a song that already has real lyrics but whose sentiment was NOT
// derived from them (sentimentSource !== 'lyrics' — i.e. 'inferred' / 'failed' / unset).
// Re-running sentiment on these with the actual lyrics upgrades inferred -> lyrics-sourced.
//
// Writes <dir>/batches/batch-NNN.json (arrays of {songId, artist, title, genre, year,
// lyrics}) + <dir>/_meta.json. Keeps large lyrics OFF the workflow args/return path —
// each agent reads its own batch file from disk.
//
//   node extract-sentiment-targets.mjs [--index index-out/current/index.json]
//     [--dir /tmp/sent-upgrade] [--batch-size 18] [--max-chars 0]
//
//   --max-chars 0  = NO size cap (default). Claude handles long lyrics — that's a
//                    strength of the Claude/Haiku path; do NOT cap it. Set a cap
//                    (e.g. 16000) only when targeting the LOCAL small model, which
//                    chokes on very long prompts.
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const indexPath = arg('--index', 'index-out/current/index.json');
const dir = arg('--dir', '/tmp/sent-upgrade');
const batchSize = Math.max(1, parseInt(arg('--batch-size', '18'), 10));
const maxChars = parseInt(arg('--max-chars', '0'), 10); // 0 = no cap

const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const albumById = new Map(idx.albums.map((a) => [a.id, a]));

const targets = [];
let skippedOversize = 0;
for (const s of idx.songs) {
  const L = s.lyrics ? s.lyrics.length : 0;
  if (L <= 0) continue;
  if (s.sentimentSource === 'lyrics') continue; // already lyrics-sourced
  if (maxChars > 0 && L > maxChars) {
    skippedOversize++;
    continue;
  }
  const alb = albumById.get(s.albumId);
  targets.push({
    songId: s.id,
    artist: s.artist || (alb && alb.artist) || '',
    title: s.name,
    genre: (alb && alb.genre) || '',
    year: (alb && alb.year) || s.year || null,
    lyrics: s.lyrics,
  });
}

rmSync(join(dir, 'batches'), { recursive: true, force: true });
rmSync(join(dir, 'out'), { recursive: true, force: true });
mkdirSync(join(dir, 'batches'), { recursive: true });
mkdirSync(join(dir, 'out'), { recursive: true });

let b = 0;
for (let i = 0; i < targets.length; i += batchSize) {
  writeFileSync(
    join(dir, 'batches', `batch-${String(b).padStart(3, '0')}.json`),
    JSON.stringify(targets.slice(i, i + batchSize)),
  );
  b++;
}
const meta = { index: indexPath, targets: targets.length, batches: b, batchSize, maxChars, skippedOversize };
writeFileSync(join(dir, '_meta.json'), JSON.stringify(meta, null, 2));

process.stderr.write(
  `extract-sentiment-targets: ${targets.length} songs -> ${b} batches of ${batchSize} in ${dir}/batches/` +
    (skippedOversize ? ` (skipped ${skippedOversize} over ${maxChars} chars)` : '') +
    `\nrun the workflow with args {"numBatches": ${b}, "dir": "${dir}"}\n`,
);
