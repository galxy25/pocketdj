#!/usr/bin/env node
// Emit the SENTIMENT todo: every matched album (with tracks) that still has at least
// one un-tagged song, assembled from the full stage overlay (so it includes the
// web-recovered albums + singles, with lyrics where the lyrics stage found them).
// The Claude-agent sentiment path reads slices of this file.
//
//   node sentiment-todo.mjs --dir index-out/shards-pw --out /tmp/sent-todo.jsonl
//
// Prints the todo album count on stdout.

import { writeFileSync } from 'node:fs';
import { buildFromStages } from './manifest.mjs';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const dir = arg('--dir', 'index-out/shards-pw');
const out = arg('--out', '/tmp/sent-todo.jsonl');

const map = buildFromStages(dir);
const todo = [];
for (const a of map.values()) {
  const tracks = a.tracks || [];
  if (!tracks.length) continue; // trackless (unmatched) — nothing to tag
  // needs sentiment if any track has no keywords yet
  if (tracks.some((t) => !(t.sentimentKeywords && t.sentimentKeywords.length))) todo.push(a);
}
writeFileSync(out, todo.map((a) => JSON.stringify(a)).join('\n') + (todo.length ? '\n' : ''));
process.stderr.write(`sentiment-todo: ${todo.length} albums need sentiment -> ${out}\n`);
console.log(todo.length);
