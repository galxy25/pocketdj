#!/usr/bin/env node
// Indexer CLI — the deterministic steps that run in the MAIN LOOP (Node), since
// the Workflow sandbox can't touch the filesystem. The workflow handles only the
// networked enrichment fan-out.
//
//   node cli.mjs parse  <vinylTxt> [--limit N] [--out parsed.json] [--location DIR]
//   node cli.mjs merge  <shardsDir> [--out-dir index-out] [--source Vinyl.md] [--lines N --vinyl N]
//   node cli.mjs plan   <vinylTxt> [--limit N] [--size 10]
//
// `parse` emits the candidate array consumed by the workflow via `args`.
// `merge` reads batch-*.json shards and writes index.json + coverage-report.json
// + run-log.json.

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFile } from './parser.js';
import { mergeShards } from './merge.js';
import { assembleShard } from './assemble.js';
import { planBatches } from './batching.js';

const __dir = dirname(fileURLToPath(import.meta.url));

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const cmd = process.argv[2];

if (cmd === 'parse') {
  const txtPath = process.argv[3];
  const limit = parseInt(arg('--limit', '0'), 10);
  const out = arg('--out', '');
  const location = arg('--location', 'Vinyl crate');
  const text = readFileSync(txtPath, 'utf8');
  const { candidates, skipped } = parseFile(text, location);
  const sliced = limit > 0 ? candidates.slice(0, limit) : candidates;
  const payload = {
    source: txtPath.split('/').pop(),
    parseLines: text.split(/\r?\n/).filter((l) => l.trim()).length,
    parseVinyl: candidates.length,
    skipped: skipped.length,
    skippedSamples: skipped.slice(0, 10),
    count: sliced.length,
    candidates: sliced,
  };
  if (out) {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, JSON.stringify(payload, null, 2));
  }
  process.stderr.write(
    `parsed ${candidates.length} vinyl / ${payload.parseLines} lines, skipped ${skipped.length}; emitting ${sliced.length}\n`,
  );
  if (!out) process.stdout.write(JSON.stringify(payload));
} else if (cmd === 'plan') {
  const txtPath = process.argv[3];
  const limit = parseInt(arg('--limit', '0'), 10);
  const size = parseInt(arg('--size', '10'), 10);
  const text = readFileSync(txtPath, 'utf8');
  const { candidates } = parseFile(text);
  const n = limit > 0 ? Math.min(limit, candidates.length) : candidates.length;
  process.stdout.write(JSON.stringify(planBatches(n, size), null, 2) + '\n');
} else if (cmd === 'merge') {
  const shardsDir = process.argv[3];
  const outDir = arg('--out-dir', 'index-out');
  const source = arg('--source', 'Vinyl.md');
  const parseLines = parseInt(arg('--lines', '0'), 10) || null;
  const parseVinyl = parseInt(arg('--vinyl', '0'), 10) || null;
  const batchSize = parseInt(arg('--size', '10'), 10);
  const files = readdirSync(shardsDir)
    .filter((f) => /^batch-\d+\.json$/.test(f))
    .sort();
  // Each shard from the workflow is { batchIndex, albums: EnrichedAlbum[] }.
  // Assemble into canonical {albums, songs, log} with content-derived ids.
  const shards = files.map((f) => {
    const raw = JSON.parse(readFileSync(join(shardsDir, f), 'utf8'));
    return assembleShard(raw.albums || []);
  });
  const { index, coverageReport, runLog } = mergeShards(shards, {
    source,
    sourceName: 'My Vinyl',
    parseLines,
    parseVinyl,
    batchSize,
    generatedAt: new Date().toISOString(),
  });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'index.json'), JSON.stringify(index, null, 2));
  writeFileSync(join(outDir, 'coverage-report.json'), JSON.stringify(coverageReport, null, 2));
  writeFileSync(join(outDir, 'run-log.json'), JSON.stringify(runLog, null, 2));
  process.stderr.write(
    `merged ${shards.length} shards -> ${index.albums.length} albums / ${index.songs.length} songs; ` +
      `match ${coverageReport.albums.matchRate}, lyrics ${coverageReport.songs.lyricsRate}\n`,
  );
} else {
  process.stderr.write('usage: cli.mjs <parse|plan|merge> ...\n');
  process.exit(1);
}

void __dir;
void existsSync;
