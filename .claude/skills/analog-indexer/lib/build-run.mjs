#!/usr/bin/env node
// Generate a self-contained, runnable copy of the enrichment workflow with the
// parsed candidates embedded as a const. This avoids passing a large `args`
// payload through the Workflow tool call (which would bloat the agent's context);
// instead we invoke Workflow({ scriptPath: <generated file> }).
//
//   node build-run.mjs <parsed.json> <out.workflow.js> [--size N] [--slice A:B] [--completed 1,2]
//
// --slice A:B  -> only candidates[A:B] (for chunking the full 1,366-album run).

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const TEMPLATE = join(here, '..', 'workflow', 'index-vinyl.workflow.js');

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const parsedPath = process.argv[2];
const outPath = process.argv[3];
if (!parsedPath || !outPath) {
  process.stderr.write('usage: build-run.mjs <parsed.json> <out.js> [--size N] [--slice A:B] [--completed 1,2]\n');
  process.exit(1);
}

const parsed = JSON.parse(readFileSync(parsedPath, 'utf8'));
let candidates = parsed.candidates || [];

const slice = arg('--slice', '');
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  candidates = candidates.slice(a || 0, isNaN(b) ? undefined : b);
}

// Keep only the fields the workflow uses (lean script).
const slim = candidates.map((c) => ({
  originalFilename: c.originalFilename,
  fileLocation: c.fileLocation,
  fileType: c.fileType,
  dupIndex: c.dupIndex ?? null,
  spacedBlob: c.spacedBlob,
  artistGuess: c.artistGuess,
  albumGuess: c.albumGuess,
  altSplits: c.altSplits,
}));

const size = parseInt(arg('--size', '10'), 10);
const completed = arg('--completed', '');
const completedArr = completed ? completed.split(',').map((x) => parseInt(x, 10)) : [];

let src = readFileSync(TEMPLATE, 'utf8');
src = src.replace(
  /const candidates = \(args && args\.candidates\) \|\| \[\]; \/\* __CANDIDATES_INJECTION__ \*\//,
  `const candidates = ${JSON.stringify(slim)}; /* injected ${slim.length} */`,
);
src = src.replace(
  /const batchSize = \(args && args\.batchSize\) \|\| 10; \/\* __BATCHSIZE_INJECTION__ \*\//,
  `const batchSize = ${size}; /* injected */`,
);
src = src.replace(
  /const completed = new Set\(\(args && args\.completedBatches\) \|\| \[\]\); \/\* __COMPLETED_INJECTION__ \*\//,
  `const completed = new Set(${JSON.stringify(completedArr)}); /* injected */`,
);

writeFileSync(outPath, src);
process.stderr.write(
  `wrote ${outPath} with ${slim.length} candidates, batchSize ${size}, ${Math.ceil(slim.length / size) * 2} agent calls\n`,
);
