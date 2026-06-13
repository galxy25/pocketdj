#!/usr/bin/env node
// Headless-Playwright batch enricher — the FALLBACK enrichment path for when the
// iTunes Search API gets IP-rate-limited at scale (403/429). Mirrors enrich.mjs's
// CLI, shard output, and EnrichedAlbum shape so `cli.mjs merge` works unchanged.
//
//   node enrich-playwright.mjs <parsed.json> --out-dir index-out/shards-pw [options]
//     --concurrency 3            parallel browser pages (KEEP LOW: 2-4, polite)
//     --size 100                 albums per shard file
//     --limit N                  first N candidates only
//     --slice A:B                candidates [A,B)
//     --progress-file PATH       append "enriched <done>/<total> matched=<m> at <ISO>"
//
// Two captcha-free data sources, queried from INSIDE a real browser page context
// (so fetches carry a genuine browser fingerprint):
//   1) Discogs public API (api.discogs.com, no token needed) — richest: structured
//      tracklist + year + genres/styles + country + hi-res cover. Throttled hard
//      (~one call per ~2.5s shared lane) since unauthenticated Discogs allows ~25/min.
//   2) Wikipedia REST search + article scrape — robust, never captcha'd: infobox
//      (genre/year/length/cover) + the "Track listing" table.
// We avoid Google/Discogs-website HTML (both serve bot captchas — Discogs' website
// returns a Cloudflare "Just a moment..." challenge to headless Chromium).
//
// Output: <out-dir>/batch-XXXX.json = { batchIndex, albums: EnrichedAlbum[] }.
// Lyrics/sentiment are left empty here (a later Haiku pass + merge fill those,
// same as the iTunes path).

import { readFileSync, writeFileSync, mkdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { normalize, tokenSet, diceTokens, coverage } from './normalize.js';
import { chunk } from './batching.js';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const parsedPath = process.argv[2];
const outDir = arg('--out-dir', 'index-out/shards-pw');
const concurrency = Math.max(1, Math.min(4, parseInt(arg('--concurrency', '3'), 10)));
const shardSize = parseInt(arg('--size', '100'), 10);
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', ''); // A:B
const progressFile = arg('--progress-file', '');
const albumTimeoutMs = parseInt(arg('--album-timeout', '45000'), 10);

// Realistic desktop Chrome UA + a Discogs API UA (their TOS wants a descriptive one).
const BROWSER_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const DISCOGS_UA = 'PocketDJ-Indexer/1.0 +levismschoen@gmail.com';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = (base, spread = 400) => base + Math.floor(Math.random() * spread);

// ---- Discogs throttle: single shared lane, ~1 call / DISCOGS_GAP ms -----------
// Unauthenticated Discogs allows ~25 req/min. With each album making up to 2 calls
// (search + release detail), space them so we stay well under that ceiling.
const DISCOGS_GAP = 2600;
let discogsGate = Promise.resolve();
let discogsPausedUntil = 0;
async function discogsSlot() {
  const mine = discogsGate.then(() => sleep(DISCOGS_GAP));
  discogsGate = mine;
  await mine;
  const wait = discogsPausedUntil - Date.now();
  if (wait > 0) await sleep(wait);
}

// ---------- in-page fetch helpers (run in the browser, dodge bot walls) --------
// Each fetch happens inside the page so it shares the browser's TLS/UA fingerprint.
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

// ---------- duration parsing: "4:58" / "1:25:43" / "A1 4:57" -> ms -------------
function durationToMs(raw) {
  if (!raw) return undefined;
  const m = String(raw).match(/(\d{1,2}):(\d{2})(?::(\d{2}))?/);
  if (!m) return undefined;
  let h = 0,
    min,
    sec;
  if (m[3] != null) {
    h = parseInt(m[1], 10);
    min = parseInt(m[2], 10);
    sec = parseInt(m[3], 10);
  } else {
    min = parseInt(m[1], 10);
    sec = parseInt(m[2], 10);
  }
  const total = (h * 3600 + min * 60 + sec) * 1000;
  return total > 0 ? total : undefined;
}

function yearFromString(s) {
  if (!s) return undefined;
  const m = String(s).match(/(19|20)\d{2}/);
  return m ? parseInt(m[0], 10) : undefined;
}

// Discogs vinyl positions look like "A1", "B3", "C2"; map the side letter -> disc.
// "1-1" / "2-03" multi-disc CD positions -> disc from the leading number.
function discFromPosition(pos, fallback = 1) {
  if (!pos) return fallback;
  const s = String(pos).trim();
  const sideMatch = s.match(/^([A-H])\d/i);
  if (sideMatch) {
    const letter = sideMatch[1].toUpperCase().charCodeAt(0) - 65; // A=0
    return Math.floor(letter / 2) + 1; // A,B -> disc1 ; C,D -> disc2
  }
  const cdMatch = s.match(/^(\d+)\s*[-.]\s*\d+/);
  if (cdMatch) return parseInt(cdMatch[1], 10) || fallback;
  return fallback;
}

// ---------- fuzzy scoring (reuse normalize.js, mirror itunes.js spirit) --------
const COMPILATION_PHRASES = ['greatest hits', 'best of', 'anthology', 'collection', 'the best'];

function scoreMatch(spacedBlob, artist, name) {
  const blobSet = tokenSet(spacedBlob);
  const candSet = tokenSet(`${artist || ''} ${name || ''}`);
  let score = diceTokens(blobSet, candSet);
  score += 0.12 * coverage(artist || '', spacedBlob);
  const nb = normalize(spacedBlob);
  const nc = normalize(name || '');
  if (nc && nb.includes(nc)) score += 0.1;
  for (const p of COMPILATION_PHRASES) {
    if (nb.includes(p) && nc.includes(p)) {
      score += 0.05;
      break;
    }
  }
  return Math.max(0, Math.min(1.3, score));
}
function classify(score) {
  if (score >= 0.62) return 'strong';
  if (score >= 0.45) return 'weak';
  return null; // unmatched
}

// ============================ DISCOGS ==========================================
async function tryDiscogs(page, cand) {
  const term = cand.spacedBlob;
  await discogsSlot();
  const searchUrl =
    'https://api.discogs.com/database/search?q=' +
    encodeURIComponent(term) +
    '&type=release&per_page=8';
  const sr = await pageFetchJSON(page, searchUrl, { 'User-Agent': DISCOGS_UA });
  if (sr.status === 429 || sr.status === 403) {
    discogsPausedUntil = Date.now() + 30000; // back off the whole lane
    return null;
  }
  const results = (sr.body && sr.body.results) || [];
  if (!results.length) return null;

  // Pick the highest-scoring release by its "Artist - Title" string.
  let best = null;
  for (const r of results) {
    const t = r.title || '';
    const dash = t.indexOf(' - ');
    const artist = dash >= 0 ? t.slice(0, dash) : '';
    const name = dash >= 0 ? t.slice(dash + 3) : t;
    const score = scoreMatch(term, artist, name);
    if (!best || score > best.score) best = { r, artist, name, score };
  }
  if (!best) return null;
  const conf = classify(best.score);
  if (!conf) return null; // let Wikipedia try

  // Fetch the release detail for the structured tracklist.
  await discogsSlot();
  const dr = await pageFetchJSON(
    page,
    'https://api.discogs.com/releases/' + best.r.id,
    { 'User-Agent': DISCOGS_UA },
    14000,
  );
  if (dr.status === 429 || dr.status === 403) {
    discogsPausedUntil = Date.now() + 30000;
    return null;
  }
  const d = dr.body;
  if (!d) return null;

  const artist =
    (Array.isArray(d.artists) && d.artists.map((a) => a.name).join(', ').replace(/\s*\(\d+\)\s*/g, '')) ||
    best.artist;
  const name = (d.title || best.name || '').trim();
  const year = (typeof d.year === 'number' && d.year) || yearFromString(best.r.year) || undefined;
  const genreParts = [...(d.genres || []), ...(d.styles || [])];
  const genre = genreParts.length ? genreParts.slice(0, 3).join(', ') : undefined;
  const country = d.country || best.r.country || undefined;
  let coverArt;
  const img = (d.images || []).find((i) => i.type === 'primary') || (d.images || [])[0];
  if (img) coverArt = img.uri || img.resource_url || img.uri150;
  if (!coverArt && best.r.cover_image && !/spacer\.gif/.test(best.r.cover_image))
    coverArt = best.r.cover_image;

  // Tracklist: keep real audio tracks (skip headings/index entries with no position).
  const tracks = [];
  let n = 0;
  for (const t of d.tracklist || []) {
    if (t.type_ && t.type_ !== 'track') continue; // skip "heading"/"index"
    const title = (t.title || '').trim();
    if (!title) continue;
    n += 1;
    tracks.push({
      discNumber: discFromPosition(t.position, 1),
      trackNumber: n,
      name: title,
      artist,
      year,
      lengthMs: durationToMs(t.duration),
      explicit: false,
      lyrics: null,
      lyricsStatus: 'notfound',
      sentimentKeywords: [],
      sentimentSource: 'inferred',
    });
  }
  if (!tracks.length) return null; // no usable tracklist -> let Wikipedia try

  // Renumber per-disc so trackNumbers restart at each disc (assemble.js keys on disc+track).
  const perDisc = new Map();
  for (const tr of tracks) {
    const c = (perDisc.get(tr.discNumber) || 0) + 1;
    perDisc.set(tr.discNumber, c);
    tr.trackNumber = c;
  }

  return {
    matched: true,
    confidence: conf,
    score: Number(best.score.toFixed(3)),
    source: 'discogs',
    artist,
    name,
    year,
    genre,
    country,
    coverArt,
    tracks,
  };
}

// ============================ WIKIPEDIA ========================================
async function wikiSearch(page, term) {
  const url =
    'https://en.wikipedia.org/w/rest.php/v1/search/page?q=' +
    encodeURIComponent(term) +
    '&limit=6';
  const r = await pageFetchJSON(page, url, {}, 10000);
  return (r.body && r.body.pages) || [];
}

async function tryWikipedia(page, cand) {
  const term = cand.spacedBlob;
  // Bias the query toward an album page.
  const pages =
    (await wikiSearch(page, term + ' album')).concat(await wikiSearch(page, term)) || [];
  if (!pages.length) return null;

  // Pick the candidate whose title+description best matches and looks album-ish.
  let best = null;
  const seen = new Set();
  for (const pg of pages) {
    if (seen.has(pg.key)) continue;
    seen.add(pg.key);
    const desc = (pg.description || '').toLowerCase();
    const looksAlbum = /album|ep\b|soundtrack|compilation/.test(desc);
    // title often "Diamond Life"; desc "1984 studio album by Sade" carries the artist.
    const candText = `${pg.title} ${pg.description || ''}`;
    let score = scoreMatch(term, pg.description || '', pg.title);
    if (looksAlbum) score += 0.12;
    if (/\bby\b/.test(desc) && coverage(term, candText) > 0.4) score += 0.05;
    if (!best || score > best.score) best = { pg, score, looksAlbum };
  }
  if (!best || (!best.looksAlbum && best.score < 0.45)) return null;
  const conf = classify(best.score);
  if (!conf) return null;

  // Open the article and scrape infobox + the Track listing table.
  const articleUrl = 'https://en.wikipedia.org/wiki/' + encodeURIComponent(best.pg.key);
  try {
    await page.goto(articleUrl, { waitUntil: 'domcontentloaded', timeout: 20000 });
  } catch {
    return null;
  }

  const data = await page.evaluate(() => {
    const ib = document.querySelector('.infobox');
    const getRow = (label) => {
      if (!ib) return null;
      for (const tr of ib.querySelectorAll('tr')) {
        const th = tr.querySelector('th');
        const td = tr.querySelector('td');
        if (th && td && th.textContent.trim().toLowerCase().startsWith(label))
          return td.textContent.trim();
      }
      return null;
    };
    let cover = null;
    if (ib) {
      const img = ib.querySelector('img');
      if (img) {
        const srcset = img.getAttribute('srcset');
        // srcset's last (2x) entry is the highest-res thumbnail.
        if (srcset) {
          const parts = srcset.split(',').map((s) => s.trim().split(/\s+/)[0]);
          cover = parts[parts.length - 1] || img.getAttribute('src');
        } else {
          cover = img.getAttribute('src');
        }
      }
    }
    // Artist: infobox subheader "Studio album by X" or "by X".
    let artist = null;
    if (ib) {
      const sub = [...ib.querySelectorAll('th, .description, .album-misc-info')]
        .map((e) => e.textContent.trim())
        .find((t) => /album by |by /i.test(t) && /by /i.test(t));
      if (sub) {
        const m = sub.match(/by\s+(.+)$/i);
        if (m) artist = m[1].trim();
      }
    }
    const tables = [...document.querySelectorAll('table.tracklist')];
    const tracklists = tables.map((tbl) => {
      const headerCells = [...(tbl.querySelector('tr')?.querySelectorAll('th, td') || [])].map((c) =>
        c.textContent.trim().toLowerCase(),
      );
      const titleIdx = headerCells.findIndex((h) => /title/.test(h));
      const lenIdx = headerCells.findIndex((h) => /length/.test(h));
      const rows = [];
      for (const tr of tbl.querySelectorAll('tr')) {
        const cells = [...tr.querySelectorAll('td')];
        // a data row starts with a "No." cell that is a number
        const first = tr.querySelector('td, th');
        if (!cells.length) continue;
        const noText = (first && first.textContent.trim()) || '';
        if (!/^\d+\.?$/.test(noText)) continue;
        const allCells = [...tr.querySelectorAll('th, td')].map((c) => c.textContent.trim());
        const title = titleIdx >= 0 ? allCells[titleIdx] : allCells[1];
        const length = lenIdx >= 0 ? allCells[lenIdx] : allCells[allCells.length - 1];
        if (title) rows.push({ title, length });
      }
      return rows;
    });
    return {
      released: getRow('released'),
      genre: getRow('genre'),
      cover,
      artist,
      tracklists,
    };
  });

  // Flatten tracklists -> tracks (each table = a disc/side group).
  const tracks = [];
  let disc = 0;
  for (const list of data.tracklists) {
    if (!list.length) continue;
    disc += 1;
    let n = 0;
    for (const row of list) {
      n += 1;
      const title = String(row.title || '')
        .replace(/^["“]|["”]$/g, '')
        .replace(/["“”]/g, '')
        .trim();
      if (!title) continue;
      tracks.push({
        discNumber: disc,
        trackNumber: n,
        name: title,
        artist: data.artist || best.pg.description || '',
        year: yearFromString(data.released) || yearFromString(best.pg.description),
        lengthMs: durationToMs(row.length),
        explicit: false,
        lyrics: null,
        lyricsStatus: 'notfound',
        sentimentKeywords: [],
        sentimentSource: 'inferred',
      });
    }
  }
  if (!tracks.length) return null;

  const year = yearFromString(data.released) || yearFromString(best.pg.description) || undefined;
  const genre = data.genre
    ? data.genre
        .replace(/\[\d+\]/g, '')
        .split(/\n+/)
        .map((g) => g.trim())
        .filter(Boolean)
        .slice(0, 3)
        .join(', ')
    : undefined;
  let coverArt = data.cover || undefined;
  if (coverArt && coverArt.startsWith('//')) coverArt = 'https:' + coverArt;

  const artist = (data.artist || '').replace(/\[\d+\]/g, '').trim();

  return {
    matched: true,
    confidence: conf,
    score: Number(best.score.toFixed(3)),
    source: 'wikipedia',
    artist: artist || cand.artistGuess || '',
    name: best.pg.title,
    year,
    genre,
    country: undefined,
    coverArt,
    tracks,
  };
}

// ============================ per-album orchestration ==========================
async function enrichOne(page, cand, ci) {
  const base = {
    candidateIndex: ci,
    originalFilename: cand.originalFilename,
    fileLocation: cand.fileLocation,
    fileType: cand.fileType,
    dupIndex: cand.dupIndex ?? null,
    artist: cand.artistGuess || cand.spacedBlob,
    name: cand.albumGuess || cand.spacedBlob,
    tracks: [],
    sources: [],
    status: 'unmatched',
    score: 0,
  };

  // Per-album timeout so one slow page can't stall the pool.
  const work = (async () => {
    let res = null;
    try {
      res = await tryDiscogs(page, cand);
    } catch {
      res = null;
    }
    if (!res || !res.matched) {
      try {
        res = await tryWikipedia(page, cand);
      } catch {
        res = null;
      }
    }
    return res;
  })();

  let res = null;
  try {
    res = await Promise.race([
      work,
      new Promise((resolve) => setTimeout(() => resolve(null), albumTimeoutMs)),
    ]);
  } catch {
    res = null;
  }

  if (res && res.matched) {
    base.status = 'matched';
    base.matchConfidence = res.confidence;
    base.score = res.score;
    base.artist = res.artist || base.artist;
    base.name = res.name || base.name;
    base.year = res.year;
    base.genre = res.genre;
    base.country = res.country;
    base.coverArt = res.coverArt;
    base.tracks = res.tracks;
    base.sources = [res.source];
  }

  // small random politeness delay between albums on this page
  await sleep(jitter(300, 500));
  return base;
}

// bounded-concurrency pool, one dedicated page per worker (reuse the page).
async function pool(items, browser, n) {
  const out = new Array(items.length);
  let idx = 0;
  let done = 0;
  let matched = 0;
  const total = items.length;

  async function reportProgress() {
    const line = `enriched ${done}/${total} matched=${matched} at ${new Date().toISOString()}`;
    process.stderr.write('  ' + line + '\n');
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
    // Block heavy assets to keep pages fast & polite.
    await page.route('**/*', (route) => {
      const type = route.request().resourceType();
      if (type === 'image' || type === 'media' || type === 'font' || type === 'stylesheet')
        return route.abort();
      return route.continue();
    });
    try {
      while (idx < items.length) {
        const i = idx++;
        out[i] = await enrichOne(page, items[i], i);
        done += 1;
        if (out[i].status === 'matched') matched += 1;
        if (done % 10 === 0 || done === total) await reportProgress();
      }
    } finally {
      await ctx.close().catch(() => {});
    }
  }

  await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
  return { out, matched };
}

// ============================ main ============================================
const parsed = JSON.parse(readFileSync(parsedPath, 'utf8'));
let candidates = parsed.candidates || [];
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  candidates = candidates.slice(a || 0, isNaN(b) ? undefined : b);
}
if (limit > 0) candidates = candidates.slice(0, limit);

process.stderr.write(
  `enriching ${candidates.length} albums via Playwright (concurrency ${concurrency}, sources: discogs+wikipedia)\n`,
);
if (progressFile) {
  try {
    appendFileSync(
      progressFile,
      `start ${candidates.length} albums concurrency=${concurrency} at ${new Date().toISOString()}\n`,
    );
  } catch {
    /* ignore */
  }
}

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
let result;
try {
  result = await pool(candidates, browser, concurrency);
} finally {
  await browser.close().catch(() => {});
}
const enriched = result.out;

mkdirSync(outDir, { recursive: true });
const shards = chunk(enriched, shardSize);
shards.forEach((albums, bi) => {
  writeFileSync(
    join(outDir, `batch-${String(bi).padStart(4, '0')}.json`),
    JSON.stringify({ batchIndex: bi, albums }),
  );
});
const matched = enriched.filter((a) => a.status === 'matched').length;
const tracks = enriched.reduce((n, a) => n + a.tracks.length, 0);
const bySrc = enriched.reduce((m, a) => {
  for (const s of a.sources || []) m[s] = (m[s] || 0) + 1;
  return m;
}, {});
process.stderr.write(
  `done: ${matched}/${enriched.length} matched, ${tracks} tracks -> ${shards.length} shards in ${outDir} ` +
    `(${Object.entries(bySrc).map(([k, v]) => `${k}=${v}`).join(' ')})\n`,
);
if (progressFile) {
  try {
    appendFileSync(
      progressFile,
      `done ${matched}/${enriched.length} matched ${tracks} tracks at ${new Date().toISOString()}\n`,
    );
  } catch {
    /* ignore */
  }
}
