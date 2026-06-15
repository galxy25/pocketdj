#!/usr/bin/env node
// EXPLICIT-FROM-LYRICS stage. For every song that has lyrics, asks a LOCAL model
// (LM Studio OpenAI-compatible API, default google/gemma-4-e4b @ 127.0.0.1:1234)
// whether the lyrics warrant a "Parental Advisory: Explicit Content" rating, and
// writes a flat per-song verdict JSONL. No cloud key, no Claude — fully local.
//
//   node enrich-explicit.mjs [--index index-out/current/index.json]
//     [--out index-out/shards-pw/explicit.jsonl] [--concurrency 2]
//     [--model google/gemma-4-e4b] [--endpoint http://127.0.0.1:1234]
//     [--limit N] [--slice A:B] [--progress-file PATH] [--retry-failed]
//
// Resumable: skips songIds already present in --out (unless --retry-failed, which
// reprocesses lines with source:"failed"). Per-song durable append. Defers on a
// reloading/unavailable model (leaves the song pending so it retries next pass).
// Output line: {"songId","explicit":bool,"confidence":0..1,"categories":[...],"source":"lyrics"}
import { readFileSync, writeFileSync, mkdirSync, appendFileSync, existsSync, renameSync } from 'node:fs';
import { dirname } from 'node:path';
import { classifyByRegex } from './explicit-lexicon.mjs';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const has = (flag) => process.argv.includes(flag);

const indexPath = arg('--index', 'index-out/current/index.json');
const outPath = arg('--out', 'index-out/shards-pw/explicit.jsonl');
const concurrency = Math.max(1, parseInt(arg('--concurrency', process.env.EXPL_CONC || '2'), 10));
const regexOnly = has('--regex-only'); // resolve only the clear-cut majority; leave 'uncertain' for a later LLM pass
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', '');
const progressFile = arg('--progress-file', '');
const endpoint = arg('--endpoint', 'http://127.0.0.1:1234').replace(/\/$/, '');
const model = arg('--model', process.env.EXPL_MODEL || 'google/gemma-4-e4b');
const maxTokens = parseInt(arg('--max-tokens', process.env.EXPL_MAX_TOKENS || '1200'), 10);
const reqTimeout = parseInt(arg('--timeout', process.env.EXPL_TIMEOUT || '75000'), 10);
const retryFailed = has('--retry-failed');

// A real song's lyrics are a few thousand chars. Anything far larger is a scrape
// artifact; feed the model a bounded prefix (we still classify, just don't choke it).
const SANE_LYRICS_CHARS = 16000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { out.push(JSON.parse(t)); } catch { /* skip partial */ }
  }
  return out;
}

function extractJson(text) {
  if (!text) return null;
  const start = text.indexOf('{');
  if (start < 0) return null;
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) {
      try { return JSON.parse(text.slice(start, i + 1)); } catch { return null; }
    }
  }
  return null;
}

const RUBRIC =
  'Rate a song EXPLICIT (true) if its lyrics would earn an RIAA "Parental Advisory: Explicit Content" label: ' +
  'strong profanity (fuck, shit, bitch, motherfucker, etc. used as such), explicit sexual content (graphic acts/anatomy/solicitation), ' +
  'graphic violence, slurs (racial/homophobic/etc.), or glorified hard-drug dealing/use. ' +
  'Do NOT flag mild words (damn, hell), romance without graphic detail, innuendo/metaphor without explicit terms, or figurative "kill/die". ' +
  'Censored but unmistakable spellings still count (f**k, n-word). categories must be a subset of ["profanity","sexual","violence","slurs","drugs"].';

async function callModel(song, attempt = 0) {
  const body = {
    model,
    temperature: 0.1,
    ...(maxTokens > 0 ? { max_tokens: maxTokens } : {}),
    messages: [
      { role: 'system', content: 'You are a strict music content-rating classifier. Output ONLY minified JSON, no prose.' },
      {
        role: 'user',
        content:
          RUBRIC +
          '\nClassify this song and return EXACTLY {"explicit":true|false,"confidence":0..1,"categories":[...]}.\n' +
          'SONG:' + JSON.stringify(song),
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
      if (/context|n_ctx|n_keep/i.test(t)) throw new Error('CONTEXT_OVERFLOW');
      throw new Error('HTTP 400');
    }
    if (res.status === 503 || res.status === 502 || res.status === 504 || res.status === 429) throw new Error('MODEL_UNAVAILABLE');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const j = await res.json();
    const content = j.choices?.[0]?.message?.content || '';
    const parsed = extractJson(content);
    if (parsed && typeof parsed.explicit === 'boolean') return parsed;
    throw new Error('no parseable verdict');
  } catch (e) {
    if (e.message === 'CONTEXT_OVERFLOW' || e.message === 'MODEL_UNAVAILABLE') throw e;
    if (e.name === 'AbortError') {
      process.stderr.write(`  explicit call timed out after ${reqTimeout}ms — marking failed\n`);
      return null;
    }
    if (/fetch failed|ECONNREFUSED|ECONNRESET|socket hang up|terminated|network/i.test(e.message)) throw new Error('MODEL_UNAVAILABLE');
    if (attempt < 2) { await sleep(1500 * (attempt + 1)); return callModel(song, attempt + 1); }
    process.stderr.write(`  explicit call failed: ${e.message}\n`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// ---- main -------------------------------------------------------------------
const idx = JSON.parse(readFileSync(indexPath, 'utf8'));
const albumById = new Map(idx.albums.map((a) => [a.id, a]));
let songs = idx.songs.filter((s) => s.lyrics && s.lyrics.trim().length);
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  songs = songs.slice(a || 0, isNaN(b) ? undefined : b);
}
if (limit > 0) songs = songs.slice(0, limit);

mkdirSync(dirname(outPath), { recursive: true });

// Resume: which songIds are already done. With --retry-failed, drop failed lines
// from the out file first so they get reprocessed.
let prior = readJsonl(outPath);
if (retryFailed) {
  const kept = prior.filter((r) => r.source !== 'failed');
  if (kept.length !== prior.length) {
    writeFileSync(outPath + '.tmp', kept.map((r) => JSON.stringify(r)).join('\n') + (kept.length ? '\n' : ''));
    renameSync(outPath + '.tmp', outPath);
    prior = kept;
  }
}
const done = new Set(prior.map((r) => r.songId));
const todo = songs.filter((s) => !done.has(s.id));

let completed = done.size;
let explicitCount = prior.filter((r) => r.explicit).length;
let regexResolved = 0, llmResolved = 0, deferred = 0, failed = 0;
const total = songs.length;

function writeVerdict(line) {
  appendFileSync(outPath, JSON.stringify(line) + '\n');
  completed++;
  if (line.explicit) explicitCount++;
  const msg = `explicit ${completed}/${total} explicit=${explicitCount} regex=${regexResolved} llm=${llmResolved} failed=${failed} at ${new Date().toISOString()}`;
  if (progressFile) { try { appendFileSync(progressFile, msg + '\n'); } catch { /* ignore */ } }
  if (completed % 100 === 0 || completed === total) process.stderr.write('  ' + msg + '\n');
}

// PASS 1 (instant): regex resolves the clear-cut majority — explicit on a STRONG
// hit, clean on no signal at all. Only the AMBIGUOUS middle is deferred to the LLM.
const uncertain = [];
for (const s of todo) {
  const r = classifyByRegex(s.lyrics);
  if (r.verdict === 'uncertain') { uncertain.push(s); continue; }
  regexResolved++;
  writeVerdict({ songId: s.id, explicit: r.verdict === 'explicit', confidence: r.verdict === 'explicit' ? 0.99 : 0.97, categories: r.categories, source: 'regex' });
}

process.stderr.write(
  `explicit: ${total} songs-with-lyrics; ${done.size} already done; regex resolved ${regexResolved}; ${uncertain.length} uncertain -> ${regexOnly ? 'SKIPPED (regex-only)' : `LLM ${model} @ ${endpoint} conc=${concurrency}`}\n`,
);

// PASS 2: the local model adjudicates only the uncertain set (bounded concurrency).
async function pool(items, n) {
  let i = 0;
  async function run() {
    while (i < items.length) {
      const s = items[i++];
      const payload = {
        title: s.name,
        artist: s.artist,
        genre: s.albumId && albumById.get(s.albumId) ? albumById.get(s.albumId).genre : undefined,
        lyrics: s.lyrics.length <= SANE_LYRICS_CHARS ? s.lyrics : s.lyrics.slice(0, SANE_LYRICS_CHARS),
      };
      let verdict;
      try {
        verdict = await callModel(payload);
      } catch (e) {
        if (e.message === 'CONTEXT_OVERFLOW' || e.message === 'MODEL_UNAVAILABLE') { deferred++; continue; }
        process.stderr.write(`  song ${s.id} error: ${e.message}\n`);
        verdict = null;
      }
      if (verdict) {
        const ex = !!verdict.explicit;
        const cats = Array.isArray(verdict.categories)
          ? verdict.categories.map((c) => String(c).toLowerCase().trim()).filter(Boolean).slice(0, 6) : [];
        llmResolved++;
        writeVerdict({ songId: s.id, explicit: ex, confidence: typeof verdict.confidence === 'number' ? verdict.confidence : null, categories: ex ? cats : [], source: 'lyrics' });
      } else {
        failed++;
        writeVerdict({ songId: s.id, explicit: false, categories: [], source: 'failed' });
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
}

if (!regexOnly) await pool(uncertain, concurrency);

process.stderr.write(
  `done: explicit ${completed}/${total}, explicit=${explicitCount} (regex=${regexResolved}, llm=${llmResolved}), failed=${failed}` +
  `${deferred ? `, ${deferred} deferred (model unavailable — rerun to finish)` : ''}` +
  `${regexOnly && uncertain.length ? `, ${uncertain.length} uncertain left for the LLM pass` : ''} -> ${outPath}\n`,
);
