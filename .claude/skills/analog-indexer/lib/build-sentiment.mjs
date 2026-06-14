#!/usr/bin/env node
// Build/stitch the Haiku sentiment pass. Two modes:
//
//   build:  node build-sentiment.mjs <shardsDir> <out.workflow.js> [--size 50] [--only-lyrics]
//           Flattens shard songs (deterministic order) into the workflow with a
//           global ordinal `sk`. Run the generated workflow with Workflow({scriptPath}).
//
//   stitch: node build-sentiment.mjs --stitch <shardsDir> <results.json>
//           Applies {results:[{sk,keywords,source}]} back onto the shards' tracks
//           (same deterministic flatten order). Overwrites the shard files.
//
// `sk` is the index into the flattened song list, which is reproducible from the
// shards, so build and stitch agree without a sidecar map.

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const TEMPLATE = join(here, '..', 'workflow', 'sentiment.workflow.js');

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const has = (f) => process.argv.includes(f);

function loadShards(dir) {
  const files = readdirSync(dir).filter((f) => /^batch-\d+\.json$/.test(f)).sort();
  return files.map((f) => ({ f, data: JSON.parse(readFileSync(join(dir, f), 'utf8')) }));
}

/** Deterministic flatten: shard file order -> album order -> track order. */
function flatten(shards, cb) {
  let sk = 0;
  for (const { data } of shards) {
    for (const album of data.albums || []) {
      for (const t of album.tracks || []) {
        cb(sk++, album, t);
      }
    }
  }
  return sk;
}

if (has('--stitch')) {
  const shardsDir = process.argv[3];
  const resultsPath = process.argv[4];
  const { results } = JSON.parse(readFileSync(resultsPath, 'utf8'));
  const map = new Map(results.map((r) => [r.sk, r]));
  const shards = loadShards(shardsDir);
  let applied = 0;
  flatten(shards, (sk, _album, t) => {
    const r = map.get(sk);
    if (r) {
      t.sentimentKeywords = r.keywords;
      t.sentimentSource = r.source;
      applied++;
    }
  });
  for (const { f, data } of shards) writeFileSync(join(shardsDir, f), JSON.stringify(data));
  process.stderr.write(`stitched ${applied} sentiment results into ${shards.length} shards\n`);
} else {
  const shardsDir = process.argv[2];
  const outPath = process.argv[3];
  const size = parseInt(arg('--size', '50'), 10);
  const onlyLyrics = has('--only-lyrics');
  const shards = loadShards(shardsDir);
  const songs = [];
  flatten(shards, (sk, album, t) => {
    if (onlyLyrics && t.lyricsStatus !== 'found') return;
    songs.push({
      sk,
      artist: t.artist || album.artist,
      album: album.name,
      title: t.name,
      genre: album.genre,
      year: t.year || album.year,
      lyrics: t.lyrics || null,
    });
  });

  let src = readFileSync(TEMPLATE, 'utf8');
  src = src.replace(/const songs = \[\]; \/\* __SONGS_INJECTION__ \*\//, `const songs = ${JSON.stringify(songs)}; /* injected ${songs.length} */`);
  src = src.replace(/const batchSize = 50; \/\* __BATCHSIZE_INJECTION__ \*\//, `const batchSize = ${size}; /* injected */`);
  writeFileSync(outPath, src);
  process.stderr.write(`wrote ${outPath} with ${songs.length} songs, batchSize ${size}, ${Math.ceil(songs.length / size)} Haiku batches\n`);
}
