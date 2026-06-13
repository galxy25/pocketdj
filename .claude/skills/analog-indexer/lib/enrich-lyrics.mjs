#!/usr/bin/env node
// Headless-Playwright LYRICS stage — reads EnrichedAlbum records (the same shape
// enrich-playwright.mjs writes to enriched.jsonl) and ADDS per-track lyrics, then
// carries every record forward verbatim. Mirrors enrich-playwright.mjs's conventions
// EXACTLY: Chromium launch, one reused page per worker, page.route asset-blocking,
// the in-page fetch/navigation pattern (fetches run inside page.evaluate so they
// carry a real browser fingerprint and dodge Cloudflare bot walls), polite
// single-lane throttle + backoff helpers, a per-item (per-song) timeout, a
// bounded-concurrency pool, resumable design via a durable JSONL, and readJsonl.
//
//   node enrich-lyrics.mjs --in <metadata.jsonl> --out <lyrics.jsonl> [options]
//     --concurrency 3            parallel browser pages (KEEP LOW: 2-3, polite)
//     --cap N                    lyrics lookups limited to first N tracks/album (default: all)
//     --limit N                  first N albums only
//     --slice A:B                albums [A,B)
//     --progress-file PATH       append "lyrics <albumsDone>/<total> songsWithLyrics=<k> at <ISO>"
//     --song-timeout 25000       per-song wall-clock cap so one stuck page can't stall
//
// Per-track lookup cycles two providers, both driven from INSIDE a real Chromium page
// so requests carry a genuine browser fingerprint (the reason Discogs' *website* fails
// but its API works — same trick here for Genius' Cloudflare-fronted host):
//   1) Genius (PRIMARY): in-page GET genius.com/api/search/multi?q=<artist title>, pick
//      the best song hit by fuzzy title match, then page.goto the song path and scrape
//      every [data-lyrics-container]. If it 403s/Cloudflares or yields nothing, fall through.
//   2) AZLyrics (FALLBACK): page.goto the slugged lyrics URL; the lyrics live in an
//      UNLABELED <div> (no class/id) inside div.col-xs-12.col-lg-8.text-center, right
//      after the "<!-- Usage of azlyrics.com ... -->" comment. AZLyrics rate-limits /
//      403s aggressively, so it gets its OWN throttle lane (>=1.5s spacing) + 403 backoff.
//
// Output: the SAME records, with each track's `lyrics` (string, trimmed ~3000 chars)
// and `lyricsStatus` ('found'|'notfound') filled. One album record appended per line
// as it completes (durable, album-by-album). Unmatched/empty albums pass through
// unchanged (their tracks, if any, keep lyricsStatus 'notfound').

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { chromium } from 'playwright';
import { normalize } from './normalize.js';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const inPath = arg('--in', '');
const outPath = arg('--out', '');
const concurrency = Math.max(1, Math.min(3, parseInt(arg('--concurrency', '3'), 10)));
const cap = parseInt(arg('--cap', '0'), 10); // 0 = all tracks
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', ''); // A:B
const progressFile = arg('--progress-file', '');
const songTimeoutMs = parseInt(arg('--song-timeout', '25000'), 10);

if (!inPath || !outPath) {
  process.stderr.write('usage: node enrich-lyrics.mjs --in <metadata.jsonl> --out <lyrics.jsonl> [options]\n');
  process.exit(1);
}


// Realistic desktop Chrome UA (same family enrich-playwright.mjs uses).
const BROWSER_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = (base, spread = 400) => base + Math.floor(Math.random() * spread);

// ---- throttle lanes: one shared gate per provider, ~1 call / GAP ms -----------
// Each lane serializes its provider's requests across ALL workers and lets us back
// off the whole lane when a provider 403s. Mirrors enrich-playwright.mjs's discogsSlot.
function makeLane(gapMs) {
  let gate = Promise.resolve();
  let pausedUntil = 0;
  return {
    async slot() {
      const mine = gate.then(() => sleep(jitter(gapMs, 350)));
      gate = mine;
      await mine;
      const wait = pausedUntil - Date.now();
      if (wait > 0) await sleep(wait);
    },
    backoff(ms) {
      pausedUntil = Date.now() + ms;
    },
  };
}
// Genius is friendlier; AZLyrics rate-limits hard -> >=1.5s spacing on its own lane.
const geniusLane = makeLane(900);
const azLane = makeLane(1600);

// ---------- in-page fetch helper (runs in the browser, dodges bot walls) -------
// Copy of enrich-playwright.mjs's pageFetchJSON: the fetch executes inside the page
// so it shares the browser's TLS/UA/cookie fingerprint.
async function pageFetchJSON(page, url, headers, timeout = 12000) {
  try {
    return await page.evaluate(
      async ({ url, headers, timeout }) => {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), timeout);
        try {
          const res = await fetch(url, { headers, signal: ctrl.signal });
          const status = res.status;
          let body = null;
          try {
            body = await res.json();
          } catch {
            body = null;
          }
          return { status, body };
        } catch (e) {
          return { status: 0, body: null, err: String(e && e.message) };
        } finally {
          clearTimeout(t);
        }
      },
      { url, headers, timeout },
    );
  } catch {
    return { status: 0, body: null };
  }
}

// ---------- title/lyrics text helpers ------------------------------------------
// Normalize a song title for fuzzy comparison: lowercase, strip punctuation,
// drop "feat." credits and parenthetical/bracketed qualifiers ("(Remix)", "[Live]").
function normTitle(s) {
  if (!s) return '';
  return normalize(
    String(s)
      .replace(/[([].*?[)\]]/g, ' ') // drop (parens) / [brackets]
      .replace(/\bfeat(uring|\.)?\b.*$/i, ' ') // drop "feat. X" tail
      .replace(/\bft\.?\b.*$/i, ' '),
  );
}

// Roughly-matches: exact normalized equality, or one title contains the other and
// they share a decent token overlap. Tolerant enough for "Title" vs "Title (2009 Remaster)".
function titleMatches(a, b) {
  const na = normTitle(a);
  const nb = normTitle(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  if (na.includes(nb) || nb.includes(na)) return true;
  const ta = new Set(na.split(' ').filter(Boolean));
  const tb = new Set(nb.split(' ').filter(Boolean));
  if (!ta.size || !tb.size) return false;
  let inter = 0;
  for (const t of ta) if (tb.has(t)) inter++;
  const dice = (2 * inter) / (ta.size + tb.size);
  return dice >= 0.7;
}

// A scraped blob is real lyrics if it's long enough and actually has line breaks
// (a "not found" / redirect / interstitial page is short and/or single-line).
function looksLikeLyrics(text) {
  if (!text) return false;
  const t = String(text).trim();
  if (t.length < 60) return false;
  if (!/\n/.test(t)) return false;
  // Guard against obvious error/landing pages slipping through.
  if (/^\s*(page not found|not found|404|access denied)\b/i.test(t)) return false;
  return true;
}

// Strip Genius page chrome that innerText pulls into the first lyrics container:
// the "<N> Contributors / Translations / <Title> Lyrics / <description>...Read More"
// header, and a trailing "<N>Embed" footer.
function stripGeniusChrome(text) {
  let t = String(text || '').replace(/\r\n/g, '\n');
  // Cut everything before the first real section header if one exists.
  const headerIdx = t.search(/\[[^\]\n]{1,40}\]/); // first "[Verse]"/"[Intro]" etc.
  if (headerIdx > 0) {
    t = t.slice(headerIdx);
  } else {
    // No bracketed headers (some songs) -> cut after the "... Lyrics" title line.
    const m = t.match(/\n?.*\bLyrics\b[^\n]*\n/);
    if (m && m.index !== undefined && m.index < 600) {
      t = t.slice(m.index + m[0].length);
    }
  }
  // Trailing "123Embed" / "Embed" footer Genius appends.
  t = t.replace(/\d*\s*Embed\s*$/i, '');
  return t.trim();
}

function cleanLyrics(text) {
  // No truncation — store full lyrics (longest songs are well under any model's
  // 32k+ context; the sentiment stage sends them whole).
  return String(text || '')
    .replace(/\r\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n') // collapse big gaps
    .replace(/[ \t]+\n/g, '\n')
    .trim();
}

// slug for AZLyrics: lowercase, keep only [a-z0-9], drop a leading "the".
function azSlug(s) {
  return String(s || '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/&/g, ' and ')
    .replace(/^the\s+/, '')
    .replace(/[^a-z0-9]+/g, '');
}

// =============================== GENIUS ========================================
// The page must be ON genius.com before we hit genius.com/api/* — a cross-origin
// in-page fetch is blocked by CORS ("Failed to fetch", status 0). We land on the
// genius.com home once per worker page and reuse it (cheap: stylesheets/images are
// already route-blocked) so subsequent same-origin API fetches succeed.
async function ensureGeniusOrigin(page) {
  try {
    const u = new URL(page.url());
    if (u.hostname.endsWith('genius.com')) return true;
  } catch {
    /* about:blank etc. */
  }
  try {
    await page.goto('https://genius.com/', { waitUntil: 'domcontentloaded', timeout: 18000 });
    return new URL(page.url()).hostname.endsWith('genius.com');
  } catch {
    return false;
  }
}

async function tryGenius(page, artist, title) {
  await geniusLane.slot();
  if (!(await ensureGeniusOrigin(page))) {
    geniusLane.backoff(20000); // home blocked/Cloudflare -> back off the lane
    return null;
  }
  const q = encodeURIComponent(`${artist} ${title}`.trim());
  const searchUrl = `https://genius.com/api/search/multi?q=${q}`;
  const sr = await pageFetchJSON(page, searchUrl, { Accept: 'application/json' }, 12000);
  if (sr.status === 403 || sr.status === 429) {
    geniusLane.backoff(30000); // Cloudflare wall -> back off the whole lane
    return null;
  }
  const sections = (sr.body && sr.body.response && sr.body.response.sections) || [];
  // Collect song hits across the "song"/"top" sections.
  const hits = [];
  for (const sec of sections) {
    for (const h of sec.hits || []) {
      if (h.type === 'song' && h.result && h.result.path) hits.push(h.result);
    }
  }
  if (!hits.length) return null;

  // Prefer a hit whose title roughly matches; tie-break toward an artist-name match.
  let pick = null;
  for (const r of hits) {
    const tOk = titleMatches(r.title || r.title_with_featured || '', title);
    if (!tOk) continue;
    const aName = (r.primary_artist && r.primary_artist.name) || '';
    const aOk = artist ? titleMatches(aName, artist) || normalize(aName).includes(normalize(artist)) : true;
    pick = r;
    if (aOk) break; // best: title AND artist match
  }
  // Fall back to the very first song hit if nothing title-matched (search is already ranked).
  if (!pick) pick = hits[0];
  if (!pick || !pick.path) return null;

  const songUrl = 'https://genius.com' + pick.path;
  try {
    await page.goto(songUrl, { waitUntil: 'domcontentloaded', timeout: 18000 });
  } catch {
    return null;
  }

  const text = await page.evaluate(() => {
    const containers = document.querySelectorAll('[data-lyrics-container]');
    if (!containers.length) return '';
    const parts = [];
    for (const el of containers) {
      // innerText preserves <br>-driven line breaks; section headers like [Chorus] stay.
      const t = el.innerText || el.textContent || '';
      if (t) parts.push(t);
    }
    return parts.join('\n');
  });

  // The first [data-lyrics-container] is prefixed with page chrome that lives outside
  // the actual lyric lines: "<N> Contributors", "Translations", "<Title> Lyrics", and
  // an "...Read More" song-description blurb. The lyrics proper begin at the first
  // section header ("[Verse 1]" / "[Intro]") or, lacking one, after the "Lyrics" line.
  const cleaned = cleanLyrics(stripGeniusChrome(text));
  if (!looksLikeLyrics(cleaned)) return null;
  return { lyrics: cleaned, source: 'genius' };
}

// =============================== AZLYRICS =======================================
async function tryAZLyrics(page, artist, title) {
  const aSlug = azSlug(artist);
  const tSlug = azSlug(title);
  if (!aSlug || !tSlug) return null;
  const url = `https://www.azlyrics.com/lyrics/${aSlug}/${tSlug}.html`;

  await azLane.slot();
  let resp;
  try {
    resp = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 18000 });
  } catch {
    return null;
  }
  const status = resp ? resp.status() : 0;
  if (status === 403 || status === 429) {
    azLane.backoff(60000); // AZLyrics blocks hard -> long cool-down on this lane
    return null;
  }
  if (status === 404 || status >= 400) return null;

  // AZLyrics serves a 200-status bot interstitial ("AZLyrics - request for access"
  // with a near-empty body) to headless Chromium. Detect it and back off the lane.
  const blocked = await page.evaluate(() =>
    /request for access|are you a robot|verify you are human/i.test(
      (document.title || '') + ' ' + (document.body ? document.body.innerText.slice(0, 400) : ''),
    ),
  );
  if (blocked) {
    azLane.backoff(60000);
    return null;
  }

  const text = await page.evaluate(() => {
    const wrap = document.querySelector('div.col-xs-12.col-lg-8.text-center');
    if (!wrap) return '';
    // The lyrics div is the unlabeled <div> (no class, no id) right after the
    // "<!-- Usage of azlyrics.com ... -->" comment node. Find that comment, then
    // walk forward to the next bare <div>.
    let node = wrap.firstChild;
    const isUsageComment = (n) =>
      n && n.nodeType === 8 && /Usage of azlyrics\.com/i.test(n.nodeValue || '');
    while (node && !isUsageComment(node)) node = node.nextSibling;
    if (node) {
      let el = node.nextSibling;
      while (el) {
        if (el.nodeType === 1 && el.tagName === 'DIV' && !el.className && !el.id) {
          return el.innerText || el.textContent || '';
        }
        el = el.nextSibling;
      }
    }
    // Fallback: among the direct-child bare <div>s, take the longest text block.
    let best = '';
    for (const el of wrap.children) {
      if (el.tagName === 'DIV' && !el.className && !el.id) {
        const t = el.innerText || el.textContent || '';
        if (t.length > best.length) best = t;
      }
    }
    return best;
  });

  const cleaned = cleanLyrics(text);
  if (!looksLikeLyrics(cleaned)) return null;
  return { lyrics: cleaned, source: 'azlyrics' };
}

// ---------- per-song lookup with a wall-clock cap (never throws) ---------------
async function lookupSong(page, artist, title) {
  const work = (async () => {
    let res = null;
    try {
      res = await tryGenius(page, artist, title);
    } catch {
      res = null;
    }
    if (!res) {
      try {
        res = await tryAZLyrics(page, artist, title);
      } catch {
        res = null;
      }
    }
    return res;
  })();
  try {
    return await Promise.race([
      work,
      new Promise((resolve) => setTimeout(() => resolve(null), songTimeoutMs)),
    ]);
  } catch {
    return null;
  }
}

// ---------- per-album orchestration --------------------------------------------
// Carries the album record forward verbatim; only mutates each track's lyrics /
// lyricsStatus. Returns { album, found, bySrc } for progress accounting.
async function enrichAlbum(page, album) {
  const bySrc = { genius: 0, azlyrics: 0 };
  let found = 0;

  // Pass through unmatched / empty albums unchanged.
  const tracks = Array.isArray(album.tracks) ? album.tracks : [];
  if (album.status !== 'matched' || tracks.length === 0) {
    return { album, found, bySrc };
  }

  const albumArtist = album.artist || '';
  const max = cap > 0 ? Math.min(cap, tracks.length) : tracks.length;

  for (let i = 0; i < tracks.length; i++) {
    const tr = tracks[i];
    // Skip lyric lookups past the per-album cap (leave those tracks 'notfound').
    if (i >= max) {
      if (tr.lyricsStatus !== 'found') tr.lyricsStatus = tr.lyricsStatus || 'notfound';
      continue;
    }
    // If a prior run already filled this track (shouldn't happen with album-level
    // resume, but cheap insurance), keep it.
    if (tr.lyricsStatus === 'found' && tr.lyrics) {
      found += 1;
      continue;
    }
    const artist = tr.artist || albumArtist;
    const title = tr.name || '';
    if (!title) {
      tr.lyrics = tr.lyrics ?? null;
      tr.lyricsStatus = 'notfound';
      continue;
    }
    const res = await lookupSong(page, artist, title);
    if (res && res.lyrics) {
      tr.lyrics = res.lyrics;
      tr.lyricsStatus = 'found';
      found += 1;
      bySrc[res.source] = (bySrc[res.source] || 0) + 1;
    } else {
      tr.lyrics = tr.lyrics ?? null;
      tr.lyricsStatus = 'notfound';
    }
    // small random politeness delay between songs on this page
    await sleep(jitter(250, 450));
  }

  return { album, found, bySrc };
}

// bounded-concurrency pool, one dedicated page per worker (reuse the page).
// `items` are the NOT-yet-done album records (resume filters them). Each completed
// album is appended to outPath IMMEDIATELY (durable, album-by-album).
async function pool(items, browser, n, base) {
  // base = { total, startDone, startFound }
  let idx = 0;
  let done = base.startDone;
  let songsWithLyrics = base.startFound;
  const total = base.total;

  function reportProgress() {
    const line = `lyrics ${done}/${total} songsWithLyrics=${songsWithLyrics} at ${new Date().toISOString()}`;
    if (progressFile) {
      try {
        appendFileSync(progressFile, line + '\n');
      } catch {
        /* ignore progress write errors */
      }
    }
  }

  async function run() {
    const ctx = await browser.newContext({
      userAgent: BROWSER_UA,
      viewport: { width: 1280, height: 900 },
      locale: 'en-US',
    });
    const page = await ctx.newPage();
    // Block heavy assets to keep pages fast & polite (mirror enrich-playwright.mjs).
    await page.route('**/*', (route) => {
      const type = route.request().resourceType();
      if (type === 'image' || type === 'media' || type === 'font' || type === 'stylesheet')
        return route.abort();
      return route.continue();
    });
    try {
      while (idx < items.length) {
        const i = idx++;
        const album = items[i];
        let result;
        try {
          result = await enrichAlbum(page, album);
        } catch {
          // never throw out of the pool: emit the album as-is.
          result = { album, found: 0, bySrc: {} };
        }
        // durable per-album write FIRST, then count + report album-by-album.
        try {
          appendFileSync(outPath, JSON.stringify(result.album) + '\n');
        } catch {
          /* ignore — in-memory copy survives for the final summary */
        }
        done += 1;
        songsWithLyrics += result.found;
        reportProgress();
        if (done % 10 === 0 || idx >= items.length)
          process.stderr.write(`  lyrics ${done}/${total} songsWithLyrics=${songsWithLyrics}\n`);
      }
    } finally {
      await ctx.close().catch(() => {});
    }
  }

  await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
  return { done, songsWithLyrics };
}

// Read all records from a JSONL file (skips blank/partial lines). Same helper as
// enrich-playwright.mjs.
function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip a partial last line from a crash mid-write */
    }
  }
  return out;
}

// =============================== main ==========================================
let records = readJsonl(inPath);
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  records = records.slice(a || 0, isNaN(b) ? undefined : b);
}
if (limit > 0) records = records.slice(0, limit);

const total = records.length;
mkdirSync(dirname(outPath) || '.', { recursive: true });

// ---- RESUME: skip albums already recorded in the output JSONL -----------------
const doneSet = new Set();
let resumedFound = 0;
for (const a of readJsonl(outPath)) {
  if (typeof a.candidateIndex === 'number') {
    doneSet.add(a.candidateIndex);
    for (const tr of a.tracks || []) if (tr.lyricsStatus === 'found') resumedFound += 1;
  }
}
const todo = records.filter((r) => !doneSet.has(r.candidateIndex));

process.stderr.write(
  `lyrics: ${total} albums (concurrency ${concurrency}, sources: genius+azlyrics, cap=${cap || 'all'}); ` +
    `resuming ${doneSet.size} done, ${todo.length} remaining\n`,
);
if (progressFile) {
  try {
    appendFileSync(
      progressFile,
      `start ${total} albums (resume ${doneSet.size} done, ${todo.length} remaining) concurrency=${concurrency} at ${new Date().toISOString()}\n`,
    );
  } catch {
    /* ignore */
  }
}

if (todo.length > 0) {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    await pool(todo, browser, concurrency, {
      total,
      startDone: doneSet.size,
      startFound: resumedFound,
    });
  } finally {
    await browser.close().catch(() => {});
  }
}

// ---- final summary from the FULL durable record (resumed + new) ---------------
const all = readJsonl(outPath).sort((a, b) => (a.candidateIndex ?? 0) - (b.candidateIndex ?? 0));
let songsTotal = 0;
let songsFound = 0;
for (const a of all) {
  for (const tr of a.tracks || []) {
    songsTotal += 1;
    if (tr.lyricsStatus === 'found') songsFound += 1;
  }
}
process.stderr.write(
  `done: ${all.length} albums, ${songsFound}/${songsTotal} songs with lyrics -> ${outPath}\n`,
);
if (progressFile) {
  try {
    appendFileSync(
      progressFile,
      `done ${all.length} albums ${songsFound}/${songsTotal} songsWithLyrics at ${new Date().toISOString()}\n`,
    );
  } catch {
    /* ignore */
  }
}
