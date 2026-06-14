#!/usr/bin/env node
// Merge step for the CLAUDE-AGENT sentiment path. The sentiment-claude workflow fans
// albums out to Claude sub-agents that emit COMPACT per-track keyword results to part
// files; this folds those back into the full album records (from the todo snapshot)
// and appends them to sentiment.jsonl in the same shape the local-model path produces.
//
//   node sentiment-claude-merge.mjs --todo <todo.jsonl> --parts <dir> --out <sentiment.jsonl>
//
// Part file lines (one per album): {"ci":N,"results":[{"i":0,"keywords":[...],"source":"lyrics"|"inferred"}, ...]}
// Resumable: albums already in --out (by candidateIndex) are skipped.

import { readFileSync, writeFileSync, appendFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const todoPath = arg('--todo', '');
const partsDir = arg('--parts', '');
const outPath = arg('--out', '');
if (!todoPath || !partsDir || !outPath) {
  process.stderr.write('usage: sentiment-claude-merge.mjs --todo <jsonl> --parts <dir> --out <jsonl>\n');
  process.exit(1);
}

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip */
    }
  }
  return out;
}

// ci -> per-track keyword results (last writer wins)
const kwByCi = new Map();
for (const f of readdirSync(partsDir)) {
  if (!/\.jsonl$/.test(f)) continue;
  for (const rec of readJsonl(join(partsDir, f))) {
    if (typeof rec.ci === 'number' && Array.isArray(rec.results)) kwByCi.set(rec.ci, rec.results);
  }
}

const done = new Set();
for (const a of readJsonl(outPath)) if (typeof a.candidateIndex === 'number') done.add(a.candidateIndex);

let written = 0;
let tagged = 0;
for (const album of readJsonl(todoPath)) {
  const ci = album.candidateIndex;
  if (done.has(ci)) continue;
  const results = kwByCi.get(ci);
  if (!results) continue; // not processed yet
  const tracks = album.tracks || [];
  const byIdx = new Map();
  for (const r of results) if (typeof r.i === 'number') byIdx.set(r.i, r);
  for (let i = 0; i < tracks.length; i++) {
    const r = byIdx.get(i);
    const t = tracks[i];
    if (r && Array.isArray(r.keywords) && r.keywords.length) {
      t.sentimentKeywords = r.keywords.map((k) => String(k).toLowerCase().trim()).filter(Boolean).slice(0, 7);
      t.sentimentSource = r.source === 'lyrics' && t.lyrics ? 'lyrics' : r.source === 'lyrics' ? 'inferred' : r.source || 'inferred';
      tagged++;
    } else {
      t.sentimentKeywords = t.sentimentKeywords || [];
      t.sentimentSource = t.sentimentSource && t.sentimentSource !== 'failed' ? t.sentimentSource : 'inferred';
    }
  }
  appendFileSync(outPath, JSON.stringify(album) + '\n');
  written++;
}

process.stderr.write(`sentiment-claude-merge: appended ${written} albums (${tagged} songs tagged) -> ${outPath}\n`);
