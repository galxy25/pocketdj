#!/usr/bin/env node
// Pipeline orchestrator — runs the indexer's sub-indexers as a chain and keeps a
// MANIFEST (index-out/manifest.jsonl) where every album records its per-stage
// status. Because each stage processes only items where its stage isn't done,
// resumability and SELECTIVE re-indexing are the same mechanism:
//
//   metadata (enrich-playwright) -> lyrics (enrich-lyrics) -> sentiment (enrich-sentiment) -> [audio]
//
// Commands:
//   pipeline.mjs status                         show per-stage coverage
//   pipeline.mjs import-metadata <enriched.jsonl>   fold metadata output into the manifest
//   pipeline.mjs run [--stages lyrics,sentiment] [--limit N]   run stages over pending items
//   pipeline.mjs redo <stage> [--failed]        mark a stage pending again (then `run`)
//   pipeline.mjs merge [--out-dir index-out/full]   write index.json from the manifest
//   (global: --manifest <path>  default index-out/manifest.jsonl)
//
// The metadata stage is the Playwright scraper (run separately / in the background);
// `import-metadata` folds its enriched.jsonl in. lyrics + sentiment are run here.

import { writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  STAGES,
  readJsonl,
  loadManifest,
  saveManifest,
  foldStage,
  pendingForStage,
  resetStage,
  statusReport,
  buildFromStages,
} from './manifest.mjs';
import { assembleShard } from './assemble.js';
import { mergeShards } from './merge.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = {
  lyrics: join(HERE, 'enrich-lyrics.mjs'),
  sentiment: join(HERE, 'enrich-sentiment.mjs'),
};

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const cmd = process.argv[2];
const manifestPath = arg('--manifest', 'index-out/manifest.jsonl');
const progressFile = arg('--progress-file', 'index-out/pipeline-progress.log');

function ensureDir(p) {
  mkdirSync(dirname(p), { recursive: true });
}

// status stamps per stage when folding stage output back in
function deriveStatus(stage) {
  return (rec) => {
    if (stage === 'metadata') {
      return rec.status === 'matched'
        ? { status: 'done', extra: { source: (rec.sources || [])[0] } }
        : { status: 'unmatched', extra: {} };
    }
    if (stage === 'lyrics') {
      const found = (rec.tracks || []).filter((t) => t.lyricsStatus === 'found').length;
      return { status: 'done', extra: { found } };
    }
    if (stage === 'sentiment') {
      const tagged = (rec.tracks || []).filter(
        (t) => (t.sentimentKeywords || []).length && t.sentimentSource !== 'failed',
      ).length;
      return { status: 'done', extra: { tagged } };
    }
    return { status: 'done', extra: {} };
  };
}

function runStage(stage, items, limit) {
  if (!items.length) {
    process.stderr.write(`[${stage}] nothing pending\n`);
    return [];
  }
  const slice = limit > 0 ? items.slice(0, limit) : items;
  const tmpIn = `index-out/.pipe-${stage}-in.jsonl`;
  const tmpOut = `index-out/.pipe-${stage}-out.jsonl`;
  ensureDir(tmpIn);
  writeFileSync(tmpIn, slice.map((r) => JSON.stringify(r)).join('\n') + '\n');
  if (existsSync(tmpOut)) writeFileSync(tmpOut, ''); // fresh (manifest is the resume state)
  process.stderr.write(`[${stage}] running over ${slice.length} pending items…\n`);
  execFileSync('node', [SCRIPTS[stage], '--in', tmpIn, '--out', tmpOut, '--progress-file', progressFile], {
    stdio: 'inherit',
  });
  return readJsonl(tmpOut);
}

// ------------------------------------------------------------------ commands
const streamDir = arg('--dir', '');

if (cmd === 'status') {
  const map = streamDir ? buildFromStages(streamDir) : loadManifest(manifestPath);
  const rep = statusReport(map);
  console.log(`Manifest: ${streamDir ? streamDir + ' (streaming stage files)' : manifestPath}`);
  console.log(`Albums: ${rep.total} (matched ${rep.albumsMatched}) · Songs: ${rep.songs}`);
  console.log(`Songs with lyrics: ${rep.songsWithLyrics} · Songs tagged (sentiment): ${rep.songsTagged}`);
  console.log('Per-stage (done / pending / other):');
  for (const s of STAGES) {
    const p = rep.perStage[s];
    console.log(`  ${s.padEnd(9)} ${p.done} done / ${p.pending} pending / ${p.other} other`);
  }
} else if (cmd === 'import-metadata') {
  const enriched = process.argv[3];
  const map = loadManifest(manifestPath);
  foldStage(map, readJsonl(enriched), 'metadata', deriveStatus('metadata'));
  ensureDir(manifestPath);
  saveManifest(manifestPath, map);
  const rep = statusReport(map);
  process.stderr.write(`imported ${rep.total} albums into manifest (matched ${rep.albumsMatched})\n`);
} else if (cmd === 'run') {
  const stages = (arg('--stages', 'lyrics,sentiment') || '').split(',').map((s) => s.trim()).filter(Boolean);
  const limit = parseInt(arg('--limit', '0'), 10);
  const map = loadManifest(manifestPath);
  for (const stage of stages) {
    if (!SCRIPTS[stage]) {
      process.stderr.write(`[${stage}] no runner (metadata=scraper, audio=future) — skipping\n`);
      continue;
    }
    const pending = pendingForStage(map, stage); // matched albums whose stage isn't done
    const out = runStage(stage, pending, limit);
    if (out.length) {
      foldStage(map, out, stage, deriveStatus(stage));
      saveManifest(manifestPath, map);
      process.stderr.write(`[${stage}] folded ${out.length} -> manifest saved\n`);
    }
  }
} else if (cmd === 'redo') {
  const stage = process.argv[3];
  const failedOnly = process.argv.includes('--failed');
  const map = loadManifest(manifestPath);
  const n = resetStage(map, stage, (rec) =>
    failedOnly ? rec.stages?.[stage]?.status && rec.stages[stage].status !== 'done' : true,
  );
  saveManifest(manifestPath, map);
  process.stderr.write(`reset ${stage} on ${n} items — run \`pipeline.mjs run --stages ${stage}\` to re-index them\n`);
} else if (cmd === 'merge') {
  const outDir = arg('--out-dir', 'index-out/full');
  const map = streamDir ? buildFromStages(streamDir) : loadManifest(manifestPath);
  // Carry each album's per-stage manifest into the assembled album as `indexing`
  // so the emitted index.json itself records what each sub-indexer did.
  // assembleShard preserves input order (one album out per album in), so we can
  // stamp by position.
  const recs = [...map.values()];
  const shard = assembleShard(recs);
  shard.albums.forEach((a, i) => {
    if (recs[i]) a.indexing = recs[i].stages || {};
  });
  const { index, coverageReport, runLog } = mergeShards([shard], {
    source: 'Vinyl.md',
    sourceName: 'My Vinyl',
    generatedAt: new Date().toISOString(),
  });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'index.json'), JSON.stringify(index, null, 2));
  writeFileSync(join(outDir, 'coverage-report.json'), JSON.stringify(coverageReport, null, 2));
  writeFileSync(join(outDir, 'run-log.json'), JSON.stringify(runLog, null, 2));
  process.stderr.write(`merged manifest -> ${outDir}/index.json (${index.albums.length} albums / ${index.songs.length} songs)\n`);
} else {
  process.stderr.write('usage: pipeline.mjs <status|import-metadata|run|redo|merge> [opts]\n');
  process.exit(1);
}
