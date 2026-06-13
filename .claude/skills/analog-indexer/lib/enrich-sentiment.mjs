#!/usr/bin/env node
// SENTIMENT stage of the indexer pipeline. Reads albums (ideally already through
// the lyrics stage) and fills each song's sentimentKeywords using a LOCAL model
// served by LM Studio's OpenAI-compatible API (default google/gemma-4-26b-a4b at
// http://127.0.0.1:1234). No cloud key needed — fully automatic in Node.
//
//   node enrich-sentiment.mjs --in <in.jsonl> --out <out.jsonl> \
//     [--batch 12] [--limit N] [--slice A:B] [--progress-file PATH]
//     [--endpoint http://127.0.0.1:1234] [--model google/gemma-4-26b-a4b]
//
// Mirrors the other stages: reads/writes album JSONL (carried forward verbatim),
// resumable (skips albums already in --out by candidateIndex), per-album durable
// append. Gemma 4 is a REASONING model, so we allow generous max_tokens and read
// the `content` field (the `reasoning_content` is ignored).

import { readFileSync, writeFileSync, mkdirSync, appendFileSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const inPath = arg('--in', '');
const outPath = arg('--out', '');
const batchSize = parseInt(arg('--batch', '12'), 10);
// parallel albums in flight — LM Studio serves several at once (its "Parallel" slots)
const concurrency = Math.max(1, parseInt(arg('--concurrency', '4'), 10));
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', '');
const progressFile = arg('--progress-file', '');
const endpoint = arg('--endpoint', 'http://127.0.0.1:1234').replace(/\/$/, '');
const model = arg('--model', 'google/gemma-4-e4b');

if (!inPath || !outPath) {
  process.stderr.write('usage: enrich-sentiment.mjs --in <in.jsonl> --out <out.jsonl> [options]\n');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip partial line */
    }
  }
  return out;
}

function chunk(arr, n) {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

// Pull the first balanced {...} JSON object out of model content (defensive —
// the model usually returns clean JSON, but reasoning models sometimes add text).
function extractJson(text) {
  if (!text) return null;
  const start = text.indexOf('{');
  if (start < 0) return null;
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) {
      try {
        return JSON.parse(text.slice(start, i + 1));
      } catch {
        return null;
      }
    }
  }
  return null;
}

async function callModel(songs, attempt = 0) {
  const body = {
    model,
    temperature: 0.2,
    max_tokens: 2200,
    messages: [
      {
        role: 'system',
        content: 'You are a music sentiment analyst. Output ONLY minified JSON, no prose.',
      },
      {
        role: 'user',
        content:
          'For each song give 3-7 lowercase mood/theme keywords (1-2 words each). ' +
          'If `lyrics` is present derive them FROM the lyrics (source "lyrics"); if null, INFER from artist/title/genre/era (source "inferred"). ' +
          'Echo each `sk` exactly. Return {"results":[{"sk":N,"keywords":[...],"source":"lyrics"|"inferred"}]}.\n' +
          'SONGS:' +
          JSON.stringify(songs),
      },
    ],
  };
  try {
    const res = await fetch(`${endpoint}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const j = await res.json();
    const content = j.choices?.[0]?.message?.content || '';
    const parsed = extractJson(content);
    if (parsed && Array.isArray(parsed.results)) return parsed.results;
    throw new Error('no parseable results');
  } catch (e) {
    if (attempt < 2) {
      await sleep(1500 * (attempt + 1));
      return callModel(songs, attempt + 1);
    }
    process.stderr.write(`  sentiment call failed: ${e.message}\n`);
    return null;
  }
}

async function sentimentForAlbum(album) {
  const tracks = album.tracks || [];
  if (!tracks.length) return;
  // sk = index into this album's track list
  const songs = tracks.map((t, sk) => ({
    sk,
    artist: t.artist || album.artist,
    title: t.name,
    genre: album.genre,
    year: t.year || album.year,
    lyrics: t.lyrics || null, // full lyrics — both local models have 32k context
  }));
  for (const group of chunk(songs, batchSize)) {
    const results = await callModel(group);
    const bySk = new Map();
    for (const r of results || []) bySk.set(r.sk, r);
    for (const s of group) {
      const r = bySk.get(s.sk);
      const t = tracks[s.sk];
      if (r && Array.isArray(r.keywords) && r.keywords.length) {
        t.sentimentKeywords = r.keywords.map((k) => String(k).toLowerCase().trim()).filter(Boolean).slice(0, 7);
        t.sentimentSource = r.source === 'lyrics' && t.lyrics ? 'lyrics' : r.source === 'lyrics' ? 'inferred' : r.source || 'inferred';
      } else {
        t.sentimentKeywords = t.sentimentKeywords || [];
        t.sentimentSource = 'failed';
      }
    }
  }
}

// ---- main -------------------------------------------------------------------
let albums = readJsonl(inPath);
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  albums = albums.slice(a || 0, isNaN(b) ? undefined : b);
}
if (limit > 0) albums = albums.slice(0, limit);

mkdirSync(dirname(outPath), { recursive: true });
const doneSet = new Set();
for (const a of readJsonl(outPath)) if (typeof a.candidateIndex === 'number') doneSet.add(a.candidateIndex);
const todo = albums.filter((a) => !doneSet.has(a.candidateIndex));

process.stderr.write(
  `sentiment: ${albums.length} albums via ${model} @ ${endpoint}; resuming ${doneSet.size} done, ${todo.length} remaining\n`,
);

let done = doneSet.size;
let songCount = 0;
const total = albums.length;

// bounded-concurrency pool over albums (parallel model calls). appendFileSync is
// atomic per call in single-threaded Node, so per-album durability is safe.
async function pool(items, n) {
  let idx = 0;
  async function run() {
    while (idx < items.length) {
      const album = items[idx++];
      try {
        await sentimentForAlbum(album);
      } catch (e) {
        process.stderr.write(`  album ${album.candidateIndex} sentiment error: ${e.message}\n`);
      }
      songCount += (album.tracks || []).filter((t) => (t.sentimentKeywords || []).length && t.sentimentSource !== 'failed').length;
      appendFileSync(outPath, JSON.stringify(album) + '\n');
      done += 1;
      const line = `sentiment ${done}/${total} songsTagged=${songCount} at ${new Date().toISOString()}`;
      if (progressFile) {
        try {
          appendFileSync(progressFile, line + '\n');
        } catch {
          /* ignore */
        }
      }
      if (done % 5 === 0 || done === total) process.stderr.write('  ' + line + '\n');
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
}

await pool(todo, concurrency);
process.stderr.write(`done: sentiment for ${done}/${total} albums -> ${outPath}\n`);
