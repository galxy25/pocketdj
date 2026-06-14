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
// One song per request (batch 1): each song gets the model's full reasoning budget,
// and there's no batch to overflow/split. Overridable via --batch.
const batchSize = parseInt(arg('--batch', '1'), 10);
// Parallel albums in flight. Default 2 — keep the two 64k-output requests light on the
// model. Overridable via the SENT_CONC env var or the --concurrency flag (flag wins).
const concurrency = Math.max(1, parseInt(arg('--concurrency', process.env.SENT_CONC || '2'), 10));
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', '');
const progressFile = arg('--progress-file', '');
const endpoint = arg('--endpoint', 'http://127.0.0.1:1234').replace(/\/$/, '');
const model = arg('--model', 'google/gemma-4-e4b');
// Output cap. The actual output is tiny (3-7 keywords ≈ 50 tokens of JSON), so a huge
// cap doesn't improve quality — it just lets the *reasoning* model ramble/loop for tens
// of thousands of tokens at the model's slow speed, stalling a song for many minutes
// (observed: 64k hung a song 20+ min). 2000 gives ample reasoning headroom (~40× the
// real output) while bounding generation. Override via SENT_MAX_TOKENS.
const maxTokens = parseInt(arg('--max-tokens', process.env.SENT_MAX_TOKENS || '2000'), 10);
// Per-request wall-clock timeout (ms). Without this, ONE rambling generation pins a
// model slot indefinitely and stalls the whole stage (observed). On timeout we abort,
// mark the song failed, and move on — keeping throughput bounded. Override via SENT_TIMEOUT.
const reqTimeout = parseInt(arg('--timeout', process.env.SENT_TIMEOUT || '75000'), 10);

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
    // max_tokens only when explicitly capped (>0); otherwise omit so the model
    // generates to its own context limit (see maxTokens above).
    ...(maxTokens > 0 ? { max_tokens: maxTokens } : {}),
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
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), reqTimeout);
  try {
    const res = await fetch(`${endpoint}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ac.signal,
    });
    if (res.status === 400) {
      const t = await res.text();
      // Prompt longer than the model's loaded context — don't retry, defer the
      // album so it auto-recovers once the model is reloaded with a bigger context.
      if (/context|n_ctx|n_keep/i.test(t)) throw new Error('CONTEXT_OVERFLOW');
      throw new Error('HTTP 400');
    }
    // Model not loaded / server reloading / overloaded -> DEFER (don't burn the album
    // as failed; it auto-retries next pass once the model is back). LM Studio returns
    // 503/502/504 while a model is (re)loading, 429 when the request queue is full.
    if (res.status === 503 || res.status === 502 || res.status === 504 || res.status === 429) {
      throw new Error('MODEL_UNAVAILABLE');
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const j = await res.json();
    const content = j.choices?.[0]?.message?.content || '';
    const parsed = extractJson(content);
    if (parsed && Array.isArray(parsed.results)) return parsed.results;
    throw new Error('no parseable results');
  } catch (e) {
    if (e.message === 'CONTEXT_OVERFLOW' || e.message === 'MODEL_UNAVAILABLE') throw e; // propagate — defer the album
    // Per-request timeout fired: a rambling/stuck generation pinned the slot. Don't
    // retry (it'd just hang again) — mark this song failed and free the slot.
    if (e.name === 'AbortError') {
      process.stderr.write(`  sentiment call timed out after ${reqTimeout}ms — skipping song\n`);
      return null;
    }
    // A raw fetch rejection (connection refused / reset while the server reloads)
    // is also "model unavailable" — defer, don't fail.
    if (/fetch failed|ECONNREFUSED|ECONNRESET|socket hang up|terminated|network/i.test(e.message)) {
      throw new Error('MODEL_UNAVAILABLE');
    }
    if (attempt < 2) {
      await sleep(1500 * (attempt + 1));
      return callModel(songs, attempt + 1);
    }
    process.stderr.write(`  sentiment call failed: ${e.message}\n`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function applyResults(group, tracks, results) {
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

// Adaptive batching: if a batch overflows the model's context (full lyrics on a
// big album can exceed even 32k), split it in half and retry — never truncate.
async function processGroup(group, tracks) {
  let results;
  try {
    results = await callModel(group);
  } catch (e) {
    if (e.message === 'CONTEXT_OVERFLOW' && group.length > 1) {
      const mid = Math.ceil(group.length / 2);
      await processGroup(group.slice(0, mid), tracks);
      await processGroup(group.slice(mid), tracks);
      return;
    }
    if (e.message === 'CONTEXT_OVERFLOW') {
      // one song's lyrics overflow the whole context on their own (extremely rare)
      const t = tracks[group[0].sk];
      t.sentimentKeywords = t.sentimentKeywords || [];
      t.sentimentSource = 'failed';
      return;
    }
    throw e;
  }
  applyResults(group, tracks, results);
}

// A real song's lyrics are at most a few thousand chars. Anything far larger is a
// SCRAPE ARTIFACT (the lyrics stage grabbed a whole page / duplicated content — we've
// seen 70k–825k char blobs), which is ~tens of thousands of tokens and chokes/stalls
// the model. We don't truncate the STORED lyrics (kept verbatim); we just don't feed an
// implausible blob to the sentiment model — infer from title/artist/genre instead.
const SANE_LYRICS_CHARS = 16000;

async function sentimentForAlbum(album) {
  const tracks = album.tracks || [];
  if (!tracks.length) return;
  const songs = tracks.map((t, sk) => ({
    sk,
    artist: t.artist || album.artist,
    title: t.name,
    genre: album.genre,
    year: t.year || album.year,
    // real lyrics passed verbatim; oversized scrape garbage -> null (infer from metadata)
    lyrics: t.lyrics && t.lyrics.length <= SANE_LYRICS_CHARS ? t.lyrics : null,
  }));
  for (const group of chunk(songs, batchSize)) await processGroup(group, tracks);
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
let deferred = 0;
const total = albums.length;

// bounded-concurrency pool over albums (parallel model calls). appendFileSync is
// atomic per call in single-threaded Node, so per-album durability is safe.
async function pool(items, n) {
  let idx = 0;
  async function run() {
    while (idx < items.length) {
      const album = items[idx++];
      let defer = false;
      try {
        await sentimentForAlbum(album);
      } catch (e) {
        if (e.message === 'CONTEXT_OVERFLOW' || e.message === 'MODEL_UNAVAILABLE') defer = true;
        else process.stderr.write(`  album ${album.candidateIndex} sentiment error: ${e.message}\n`);
      }
      // Context-overflow / model-unavailable albums are left PENDING (not written) so
      // they auto-retry next pass — e.g. once the model is reloaded (bigger context).
      if (defer) {
        deferred += 1;
        continue;
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
process.stderr.write(
  `done: sentiment ${done}/${total} albums${deferred ? `, ${deferred} deferred (context too small — will retry)` : ''} -> ${outPath}\n`,
);
