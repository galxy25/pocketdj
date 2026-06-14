#!/usr/bin/env node
// METADATA BACKFILL — recover albums the Discogs/Wikipedia first pass couldn't match
// (status:"unmatched") by searching the web in a REAL browser, the way a normal user
// would: open the search engine's HOMEPAGE, type the query into the search box, and
// submit. Headless/bot-style direct-URL requests get captcha-walled; a real headed
// Chrome (or Safari) typing into the box behaves like a person and usually isn't.
// The local model (gemma) then extracts a tracklist + the album's metadata from the
// results page.
//
// RELENTLESS by design: for each album it cycles SEARCH ENGINES (google -> duckduckgo
// -> bing) and, if the primary browser comes up empty, a SECOND BROWSER (chrome ->
// safari via AppleScript — a real, non-headless browser). DuckDuckGo's html endpoint
// rarely captchas, so most albums recover with no human intervention.
//
//   node enrich-google.mjs --in <enriched.jsonl> --out <google.jsonl> [options]
//     --browser chrome|safari          primary browser (default chrome = Playwright
//                                      drives real Chrome; safari = AppleScript)
//     --fallback-browser safari|chrome|none   second browser tried when the primary
//                                      finds nothing for an album (default none; the
//                                      backfill runner does a dedicated Safari pass)
//     --engines google,duckduckgo,bing search engines to cycle, in order
//     --profile-dir DIR                Chrome persistent profile dir (give each parallel
//                                      shard its OWN dir). default /tmp/pocketdj-google-profile
//     --captcha-wait 3                 re-fetch attempts (×5s) on a captcha before
//                                      moving to the next engine
//     --captcha-pause                  block forever so a human can solve the captcha
//     --limit N --slice A:B --progress-file PATH --delay 2500
//     --model google/gemma-4-e4b --endpoint http://127.0.0.1:1234 --max-tokens -1
//
// Reads only status:"unmatched" albums; writes EnrichedAlbum records (same shape the
// other stages use) with the recovering engine/browser recorded in `sources`.
// Resumable (skips done candidateIndex). If the local model is UNAVAILABLE (you're
// reloading it), the album is DEFERRED — not written — so a re-run picks it up rather
// than burning it as unmatched. A recovered album becomes "matched" and is folded into
// the final index by the merge step (manifest reads google.jsonl).

import { readFileSync, mkdirSync, appendFileSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { execFileSync } from 'node:child_process';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const inPath = arg('--in', '');
const outPath = arg('--out', '');
const browser = arg('--browser', 'chrome');
const fallbackBrowser = arg('--fallback-browser', 'none');
const engineNames = (arg('--engines', 'google,duckduckgo,bing') || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);
const profileDir = arg('--profile-dir', '/tmp/pocketdj-google-profile');
const captchaWait = parseInt(arg('--captcha-wait', '3'), 10);
const captchaPause = process.argv.includes('--captcha-pause');
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', '');
const progressFile = arg('--progress-file', '');
const delayMs = parseInt(arg('--delay', '2500'), 10);
const endpoint = arg('--endpoint', 'http://127.0.0.1:1234').replace(/\/$/, '');
const model = arg('--model', 'google/gemma-4-e4b');
// Finite output cap (8k): plenty for a metadata JSON + a long double-LP tracklist plus
// the reasoning model's scratch, but bounded so a request can't run away / hang at 0%.
// Overridable via --max-tokens.
const maxTokens = parseInt(arg('--max-tokens', '8000'), 10);

if (!inPath || !outPath) {
  process.stderr.write('usage: enrich-google.mjs --in <jsonl> --out <jsonl> [--browser chrome|safari]\n');
  process.exit(1);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = (base) => base + Math.floor(Math.random() * base);

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip partial */
    }
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
      try {
        return JSON.parse(text.slice(start, i + 1));
      } catch {
        return null;
      }
    }
  }
  return null;
}
const looksCaptcha = (t) =>
  /unusual traffic|not a robot|recaptcha|detected unusual|verify you('| a)re|systems have detected|to continue, please|please enable javascript/i.test(
    t || '',
  );
class ModelUnavailable extends Error {
  constructor() {
    super('MODEL_UNAVAILABLE');
  }
}

// ---------------- the model: extract album metadata from results text ----------
// Throws ModelUnavailable on a reloading/overloaded server (so the caller DEFERS the
// album instead of recording it unmatched); returns null on a genuine no-result.
async function extractMetadata(album, pageText) {
  const prompt =
    `From this web-search results text, extract metadata for the album "${album.artist} — ${album.name}". ` +
    `Return ONLY minified JSON: {"found":bool,"artist":str,"name":str,"year":int|null,"genre":str|null,` +
    `"country":str|null,"tracks":[track titles in order]}. ` +
    `Set found=false if there is no clear tracklist for THIS album. Do not invent tracks; copy them verbatim from the text.\nTEXT:\n` +
    pageText;
  const body = {
    model,
    temperature: 0.1,
    ...(maxTokens > 0 ? { max_tokens: maxTokens } : {}),
    messages: [
      { role: 'system', content: 'You extract structured music metadata. Output ONLY minified JSON.' },
      { role: 'user', content: prompt },
    ],
  };
  let res;
  try {
    res = await fetch(`${endpoint}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    // connection refused/reset while LM Studio reloads the model -> defer
    if (/fetch failed|ECONNREFUSED|ECONNRESET|socket hang up|terminated|network/i.test(e.message)) throw new ModelUnavailable();
    return null;
  }
  if (res.status === 503 || res.status === 502 || res.status === 504 || res.status === 429) throw new ModelUnavailable();
  if (!res.ok) return null;
  try {
    const j = await res.json();
    return extractJson(j.choices?.[0]?.message?.content || '');
  } catch {
    return null;
  }
}

// ---------------- search engines ----------------------------------------------
// mode 'human' = open the homepage and TYPE the query into the search box (a real
// user); mode 'url' = hit a scraping-friendly server-rendered endpoint directly
// (DuckDuckGo's /html has no JS box and essentially never captchas).
const enc = (q) => encodeURIComponent(q);
const ENGINES = {
  google: {
    name: 'google',
    mode: 'human',
    home: 'https://www.google.com/?hl=en&gl=us',
    box: 'textarea[name="q"], input[name="q"]',
    url: (q) => 'https://www.google.com/search?hl=en&gl=us&num=20&q=' + enc(q),
    async consent(page) {
      for (const sel of [
        '#L2AGLb',
        'button:has-text("Accept all")',
        'button:has-text("I agree")',
        'button:has-text("Reject all")',
        'button[aria-label*="Accept" i]',
      ]) {
        const btn = await page.$(sel).catch(() => null);
        if (btn) {
          await btn.click({ timeout: 3000 }).catch(() => {});
          await page.waitForLoadState('domcontentloaded').catch(() => {});
          return;
        }
      }
    },
  },
  duckduckgo: {
    name: 'duckduckgo',
    mode: 'url',
    url: (q) => 'https://html.duckduckgo.com/html/?kl=us-en&q=' + enc(q),
  },
  bing: {
    name: 'bing',
    mode: 'human',
    home: 'https://www.bing.com/?setlang=en-us&cc=us',
    box: 'input[name="q"], textarea[name="q"]',
    url: (q) => 'https://www.bing.com/search?setlang=en-us&cc=us&q=' + enc(q),
  },
};
const engines = engineNames.map((n) => ENGINES[n]).filter(Boolean);

// ---------------- browser drivers ---------------------------------------------
// Safari via AppleScript (osascript over stdin to avoid -e escaping). A real, visible
// (non-headless) browser — Google rarely bot-walls it.
function osa(script) {
  return execFileSync('osascript', ['-'], { input: script, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }).trim();
}
function makeSafari() {
  async function load(url) {
    osa(`tell application "Safari" to set URL of document 1 to ${JSON.stringify(url)}`);
    await sleep(delayMs);
    for (let i = 0; i < 24; i++) {
      let st = '';
      try {
        st = osa('tell application "Safari" to do JavaScript "document.readyState" in document 1');
      } catch {
        /* page still loading */
      }
      if (st === 'complete') break;
      await sleep(500);
    }
    return osa('tell application "Safari" to do JavaScript "document.body.innerText" in document 1');
  }
  return {
    name: 'safari',
    async init() {
      osa('tell application "Safari"\nactivate\nif (count of documents) = 0 then make new document\nend tell');
    },
    // Safari can't easily type into a JS box via AppleScript; use the engine's direct
    // results URL (Safari's real fingerprint still dodges most walls).
    async query(engine, q) {
      return load(engine.url(q));
    },
    async close() {},
  };
}

// Chrome via Playwright (real Chrome channel, headed, persistent profile so cookies/
// consent + any solved captcha persist across the run). Each parallel shard MUST use
// its own --profile-dir (Chrome locks a profile to one process).
async function makeChrome() {
  const { chromium } = await import('playwright');
  const ctx = await chromium.launchPersistentContext(profileDir, {
    channel: 'chrome',
    headless: false,
    viewport: null,
    args: ['--no-first-run', '--no-default-browser-check'],
  });
  const page = ctx.pages()[0] || (await ctx.newPage());
  page.setDefaultTimeout(30000);

  async function readText() {
    await page.waitForLoadState('domcontentloaded').catch(() => {});
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        return await page.evaluate(() => document.body.innerText);
      } catch (e) {
        // a late navigation (consent redirect) destroyed the context — settle + retry
        if (/context was destroyed|navigation|detached/i.test(e.message)) {
          await page.waitForLoadState('domcontentloaded').catch(() => {});
          await sleep(900);
          continue;
        }
        throw e;
      }
    }
    return '';
  }

  return {
    name: 'chrome',
    async init() {},
    async query(engine, q) {
      if (engine.mode === 'human') {
        // Act like a person: land on the homepage, type into the search box, submit.
        try {
          await page.goto(engine.home, { waitUntil: 'domcontentloaded', timeout: 30000 });
        } catch {
          /* try anyway */
        }
        if (engine.consent) await engine.consent(page).catch(() => {});
        const box = await page.waitForSelector(engine.box, { timeout: 8000 }).catch(() => null);
        if (box) {
          await box.click({ timeout: 3000 }).catch(() => {});
          await box.type(q, { delay: 45 + Math.floor(Math.random() * 60) }).catch(() => {});
          await sleep(250 + Math.floor(Math.random() * 300));
          await page.keyboard.press('Enter').catch(() => {});
          await sleep(delayMs);
          return readText();
        }
        // search box not found — fall back to the direct results URL
      }
      try {
        await page.goto(engine.url(q), { waitUntil: 'domcontentloaded', timeout: 30000 });
      } catch {
        /* read whatever rendered */
      }
      if (engine.consent) await engine.consent(page).catch(() => {});
      await sleep(delayMs);
      return readText();
    },
    async close() {
      await ctx.close().catch(() => {});
    },
  };
}

async function makeDriver(name) {
  if (name === 'safari') return makeSafari();
  if (name === 'chrome') return makeChrome();
  return null;
}

// ---------------- recovery ------------------------------------------------------
function applyRecovery(album, meta, via) {
  album.status = 'matched';
  album.matchConfidence = 'weak';
  album.sources = [...(album.sources || []), via];
  album.artist = meta.artist || album.artist;
  album.name = meta.name || album.name;
  album.year = meta.year ?? album.year;
  album.genre = meta.genre ?? album.genre;
  album.country = meta.country ?? album.country;
  album.tracks = meta.tracks
    .map((name, i) => ({
      discNumber: 1,
      trackNumber: i + 1,
      name: String(name).trim(),
      artist: album.artist,
      lyrics: null,
      lyricsStatus: 'notfound',
      sentimentKeywords: [],
      sentimentSource: 'inferred',
    }))
    .filter((t) => t.name);
}

// One (driver, engine) attempt: search, ride out a captcha, ask the model.
// Returns meta on success, null on no-result. Propagates ModelUnavailable.
async function tryPair(album, driver, engine) {
  const query = `${album.artist} ${album.name} album tracklist`;
  let text = '';
  try {
    text = (await driver.query(engine, query)) || '';
  } catch (e) {
    process.stderr.write(`  ${album.candidateIndex} ${driver.name}/${engine.name} fetch error: ${e.message}\n`);
    return null;
  }
  let tries = 0;
  const maxTries = captchaPause ? 240 : captchaWait;
  while (looksCaptcha(text) && tries < maxTries) {
    if (tries === 0) {
      process.stderr.write(
        `  ⚠ ${driver.name}/${engine.name} captcha${captchaPause ? ' — solve it in the window; waiting…' : ' — short wait then next engine'}\n`,
      );
    }
    await sleep(5000);
    try {
      text = (await driver.query(engine, query)) || '';
    } catch {
      /* keep waiting */
    }
    tries++;
  }
  if (!text || looksCaptcha(text)) return null;
  const meta = await extractMetadata(album, text); // may throw ModelUnavailable
  if (meta && meta.found && Array.isArray(meta.tracks) && meta.tracks.length) return meta;
  return null;
}

// Try every engine on the primary browser, then (if configured) every engine on the
// fallback browser. Returns {meta, via} | null. Propagates ModelUnavailable to defer.
async function recoverAlbum(album, primary, getFallback) {
  for (const engine of engines) {
    const meta = await tryPair(album, primary, engine);
    if (meta) return { meta, via: `${primary.name}/${engine.name}` };
    await sleep(jitter(700));
  }
  const fb = await getFallback();
  if (fb) {
    for (const engine of engines) {
      const meta = await tryPair(album, fb, engine);
      if (meta) return { meta, via: `${fb.name}/${engine.name}` };
      await sleep(700);
    }
  }
  return null;
}

// ---------------- main ---------------------------------------------------------
let albums = readJsonl(inPath).filter((a) => a.status === 'unmatched');
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
  `google backfill: ${albums.length} unmatched · engines=[${engineNames.join(', ')}] · ` +
    `${browser}${fallbackBrowser !== 'none' ? ' -> ' + fallbackBrowser : ''} · profile=${profileDir}; ` +
    `resuming ${doneSet.size} done, ${todo.length} remaining\n`,
);

const primary = await makeDriver(browser);
await primary.init();
let fallback = null;
async function getFallback() {
  if (fallbackBrowser === 'none' || fallbackBrowser === browser) return null;
  if (!fallback) {
    process.stderr.write(`  spinning up fallback browser: ${fallbackBrowser}\n`);
    fallback = await makeDriver(fallbackBrowser);
    await fallback.init();
  }
  return fallback;
}

let done = doneSet.size;
let recovered = 0;
let deferred = 0;
const total = albums.length;
try {
  for (const album of todo) {
    let result = null;
    try {
      result = await recoverAlbum(album, primary, getFallback);
    } catch (e) {
      if (e instanceof ModelUnavailable || e.message === 'MODEL_UNAVAILABLE') {
        // Model is reloading/overloaded — DON'T record this album; leave it for a re-run.
        deferred += 1;
        if (deferred === 1 || deferred % 10 === 0) {
          process.stderr.write(`  ⏸ model unavailable — deferring (${deferred} so far; re-run to retry)\n`);
        }
        await sleep(4000);
        continue;
      }
      process.stderr.write(`  ${album.candidateIndex} recover error: ${e.message}\n`);
    }

    if (result) {
      applyRecovery(album, result.meta, result.via);
      recovered++;
    }
    appendFileSync(outPath, JSON.stringify(album) + '\n');
    done++;
    const line = `google ${done}/${total} recovered=${recovered}${result ? ' via ' + result.via : ''} at ${new Date().toISOString()}`;
    if (progressFile) {
      try {
        appendFileSync(progressFile, line + '\n');
      } catch {
        /* ignore */
      }
    }
    if (done % 5 === 0 || done === total || result) process.stderr.write('  ' + line + '\n');
    await sleep(jitter(800)); // polite gap between albums
  }
} finally {
  await primary.close();
  if (fallback) await fallback.close();
}
process.stderr.write(
  `done: google backfill recovered ${recovered}/${todo.length}${deferred ? `, ${deferred} deferred (model unavailable — re-run)` : ''} -> ${outPath}\n`,
);
