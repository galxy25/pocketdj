#!/usr/bin/env node
// resolve-streaming-links — the F3 "Sharing" pipeline's BROWSER backfill. Apple Music links
// come free from `appleMusicId` (scripts/fold-apple-music-links.mjs); Spotify + YouTube expose
// no usable API here (no creds, YouTube API is quota-blocked), so we drive a headless Chromium
// (Playwright) against each service's public SEARCH deep-link, pick the best-matching track, and
// capture its canonical URL:
//
//   Spotify:  https://open.spotify.com/search/<q>       -> https://open.spotify.com/track/<id>
//   YouTube:  https://music.youtube.com/search?q=<q>    -> https://music.youtube.com/watch?v=<id>
//
// SHAPE mirrors scripts/resolve-apple-music-catalog.mjs: same normalize()/coreTitle()/
// versionTags() matching, the SAME version-marker discipline (never grab a remix/sped-up/cover
// the library track lacks — record a MISS instead of a wrong link), a fully RESUMABLE per-song
// ndjson cache (hits AND misses), polite pacing, and infinite self-healing network retry so a
// multi-hour run survives connectivity blips. Killing it mid-run is safe (cache is appended
// per-song); re-run the same command to continue.
//
// Precision over recall: a weak match is dropped (recorded as a per-service null), because a
// WRONG "Share on Spotify" link is worse than none. Tune with --min-score.
//
// Usage:
//   node scripts/resolve-streaming-links.mjs --index apple-music --limit 15
//   node scripts/resolve-streaming-links.mjs --index current --services spotify,youtube
//   node scripts/resolve-streaming-links.mjs --index public/digital-index.json --retry-misses
//   [--cache FILE] [--delay-ms 1800] [--min-score 60] [--headed] [--nav-timeout-ms 30000]
//
// --index accepts a shorthand (apple-music | current | digital) or an explicit index path.
// Resume: re-run. A song is skipped once EVERY enabled service has a cached result (hit or
// miss); --retry-misses re-attempts the null ones (e.g. after a bot-wall spell).

import { chromium } from 'playwright';
import { createReadStream, mkdirSync, readFileSync, existsSync, appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);
const ALL_SERVICES = ['spotify', 'youtube'];

// ---------- args ----------
export function parseArgs(argv) {
  const a = {
    index: 'apple-music',
    cache: 'index-out/streaming-links/links-cache.ndjson',
    delayMs: 1800,          // per-song pause (2 nav loads/song → ~15-20 songs/min)
    minScore: 60,           // reject anything softer than a solid title+artist match
    navTimeoutMs: 30000,
    services: ALL_SERVICES.slice(),
    retryMisses: false,
    headed: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index = next();
    else if (k === '--cache') a.cache = next();
    else if (k === '--delay-ms') a.delayMs = parseInt(next(), 10);
    else if (k === '--min-score') a.minScore = parseInt(next(), 10);
    else if (k === '--nav-timeout-ms') a.navTimeoutMs = parseInt(next(), 10);
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--services') a.services = next().split(',').map((s) => s.trim()).filter(Boolean);
    else if (k === '--retry-misses') a.retryMisses = true;
    else if (k === '--headed') a.headed = true;
  }
  return a;
}

// Map an --index shorthand to a repo path.
export function indexPath(spec) {
  const short = { 'apple-music': 'public/apple-music-index.json', current: 'public/current-index.json', digital: 'public/digital-index.json' };
  const rel = short[spec] || spec;
  return rel.startsWith('/') ? rel : join(REPO, rel);
}

// ---------- normalization + scoring (parity with resolve-apple-music-catalog.mjs) ----------
export function normalize(s) {
  if (!s) return '';
  return String(s)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/['’`]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^the\s+/, '');
}
export function coreTitle(s) {
  return normalize(String(s || '').replace(/[\(\[].*?[\)\]]/g, ' '));
}
const VERSION_WORDS = ['sped up', 'slowed', 'reverb', 'remix', 'mixed', 'live', 'karaoke', 'instrumental', 'acoustic', 'cover', 'commentary', 'demo', 'radio edit', 'nightcore', '8d'];
function versionTags(s) {
  const n = normalize(s);
  return new Set(VERSION_WORDS.filter((w) => n.includes(normalize(w))));
}
const setEq = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));

// Score one candidate {title, artist, rowText?} against a library song {name, artist}.
// Returns a number; a negative score means "not a plausible match".
export function scoreCandidate(song, cand) {
  const aArtist = normalize(song.artist);
  const aTitle = normalize(song.name);
  const aCore = coreTitle(song.name);
  const aTags = versionTags(song.name);
  const rArtist = normalize(cand.artist);
  const rTitle = normalize(cand.title);
  const rCore = coreTitle(cand.title);
  const rTags = versionTags(cand.title);

  // artist gate: prefer the candidate's own artist field; when a fallback extractor
  // only gave us concatenated row text, match the artist inside that instead.
  const hay = rArtist || normalize(cand.rowText || '');
  const artistOK = rArtist
    ? (rArtist === aArtist || rArtist.includes(aArtist) || aArtist.includes(rArtist))
    : (aArtist && hay.includes(aArtist));
  if (!artistOK) return -1;

  let score = 0;
  if (rTitle === aTitle) score += 100;
  else if (rCore === aCore && aCore) score += 70;
  else if (rCore && aCore && (rCore.includes(aCore) || aCore.includes(rCore))) score += 35;
  else return -1;

  if (rArtist && rArtist === aArtist) score += 20;
  if (setEq(aTags, rTags)) score += 15;                 // version markers agree
  else if (rTags.size > aTags.size) score -= 40;        // candidate adds remix/sped-up/cover the library lacks
  return score;
}

export function pickBest(song, cands, minScore) {
  let best = null, bestScore = -1;
  for (const c of cands) {
    const sc = scoreCandidate(song, c);
    if (sc > bestScore) { bestScore = sc; best = c; }
  }
  if (!best || bestScore < minScore) return null;
  return { url: best.url, title: best.title, artist: best.artist, score: bestScore };
}

// ---------- in-page extractors (validated headless 2026-07) ----------
// Each returns an array of {url, title, artist, rowText}. Selectors have a structured path
// plus a bare-anchor fallback so a class rename degrades to "artist from row text" rather than
// to zero results.
function spotifyExtract() {
  const out = [];
  const rows = document.querySelectorAll('[role="row"]');
  rows.forEach((r) => {
    const t = r.querySelector('a[href*="/track/"]');
    if (!t) return;
    const id = (t.getAttribute('href') || '').split('/track/')[1]?.split(/[?/#]/)[0];
    if (!id) return;
    const artists = [...r.querySelectorAll('a[href*="/artist/"]')].map((a) => a.textContent.trim()).filter(Boolean);
    out.push({ url: `https://open.spotify.com/track/${id}`, title: t.textContent.trim(), artist: artists.join(', '), rowText: (r.textContent || '').trim() });
  });
  if (out.length) return out;
  document.querySelectorAll('a[href*="/track/"]').forEach((t) => {
    const id = (t.getAttribute('href') || '').split('/track/')[1]?.split(/[?/#]/)[0];
    if (id) out.push({ url: `https://open.spotify.com/track/${id}`, title: t.textContent.trim(), artist: '', rowText: t.textContent.trim() });
  });
  return out;
}
function youtubeExtract() {
  const out = [];
  const items = document.querySelectorAll('ytmusic-responsive-list-item-renderer');
  items.forEach((r) => {
    const t = r.querySelector('a[href*="watch?v="]');
    if (!t) return;
    const href = t.getAttribute('href') || '';
    const id = new URLSearchParams(href.split('?')[1] || '').get('v');
    if (!id) return;
    const cols = [...r.querySelectorAll('.secondary-flex-columns yt-formatted-string, .flex-column yt-formatted-string')].map((e) => e.textContent.trim());
    // cols[0] like "Song • Childish Gambino • 112M plays" (type • artist • plays)
    const parts = (cols[0] || '').split('•').map((s) => s.trim());
    const type = (parts[0] || '').toLowerCase();
    const artist = parts.length >= 2 ? parts.slice(1, -1).join(', ') || parts[1] : '';
    if (type && !/^(song|video)$/.test(type)) return;   // skip album/artist/playlist rows
    out.push({ url: `https://music.youtube.com/watch?v=${id}`, title: (t.textContent || t.getAttribute('aria-label') || '').trim(), artist, rowText: [t.textContent, ...cols].join(' ').trim() });
  });
  if (out.length) return out;
  document.querySelectorAll('a[href*="watch?v="]').forEach((t) => {
    const id = new URLSearchParams((t.getAttribute('href') || '').split('?')[1] || '').get('v');
    if (id) out.push({ url: `https://music.youtube.com/watch?v=${id}`, title: (t.textContent || t.getAttribute('aria-label') || '').trim(), artist: '', rowText: (t.textContent || t.getAttribute('aria-label') || '').trim() });
  });
  return out;
}

const SERVICE = {
  spotify: {
    field: 'spotifyUrl',
    searchUrl: (q) => `https://open.spotify.com/search/${encodeURIComponent(q)}`,
    waitFor: 'a[href*="/track/"]',
    extract: spotifyExtract,
  },
  youtube: {
    field: 'youtubeUrl',
    searchUrl: (q) => `https://music.youtube.com/search?q=${encodeURIComponent(q)}`,
    waitFor: 'a[href*="watch?v="]',
    extract: youtubeExtract,
  },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Load one service's search page and return scored candidates, with self-healing retry.
// Returns { candidates } on a page that loaded (candidates may be []), or throws only after
// exhausting retries on a hard nav failure.
async function fetchCandidates(page, svc, query, navTimeoutMs) {
  const s = SERVICE[svc];
  for (let attempt = 0; ; attempt++) {
    try {
      await page.goto(s.searchUrl(query), { waitUntil: 'domcontentloaded', timeout: navTimeoutMs });
      try { await page.waitForSelector(s.waitFor, { timeout: Math.min(12000, navTimeoutMs) }); } catch { /* no results / late render → extract what's there */ }
      const cands = await page.evaluate(s.extract);
      return cands || [];
    } catch (e) {
      // Transient nav error (timeout, connection reset, laptop asleep). Multi-hour run → never
      // give up on a blip: back off (capped 60s) and retry. After many attempts on ONE query,
      // give up on this query (return empty → recorded as a miss) so the run keeps moving.
      const wait = Math.min(60000, 2000 * Math.min(attempt + 1, 30));
      process.stderr.write(`\n  🌐 ${svc} nav error (${e.message?.split('\n')[0]}); retry in ${Math.round(wait / 1000)}s\n`);
      if (attempt >= 6) { process.stderr.write(`  ↳ giving up on this ${svc} query after ${attempt} tries\n`); return []; }
      await sleep(wait);
    }
  }
}

// ---------- resumable ndjson cache (one merged record per song id) ----------
async function loadCache(file) {
  const map = new Map();
  if (!existsSync(file)) return map;
  const rl = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const ln of rl) {
    if (!ln.trim()) continue;
    try { const o = JSON.parse(ln); if (o.id) map.set(o.id, { ...(map.get(o.id) || {}), ...o }); } catch { /* skip bad line */ }
  }
  return map;
}

// A song still needs work on a service when that service's field is absent from the cache,
// or is null AND --retry-misses is set.
function needsService(rec, field, retryMisses) {
  if (!rec || !(field in rec)) return true;
  return rec[field] == null && retryMisses;
}

async function main() {
  const args = parseArgs(process.argv);
  const services = args.services.filter((s) => SERVICE[s]);
  if (!services.length) { console.error('no valid --services (choose from: spotify,youtube)'); process.exit(1); }
  const idxPath = indexPath(args.index);
  if (!existsSync(idxPath)) { console.error('index not found:', idxPath); process.exit(1); }
  const cachePath = resolve(expand(args.cache));
  mkdirSync(dirname(cachePath), { recursive: true });

  console.error(`Reading index: ${idxPath}`);
  const index = JSON.parse(readFileSync(idxPath, 'utf8'));
  const songs = index.songs || [];
  const cache = await loadCache(cachePath);
  console.error(`  songs=${songs.length} cached=${cache.size} services=${services.join('+')} minScore=${args.minScore}`);

  // Work list: songs missing ANY enabled service.
  const todo = songs.filter((s) => services.some((svc) => needsService(cache.get(s.id), SERVICE[svc].field, args.retryMisses)));
  console.error(`  to resolve: ${todo.length}${args.limit ? ` (capped at ${args.limit})` : ''}`);
  const work = args.limit ? todo.slice(0, args.limit) : todo;
  if (!work.length) { console.error('nothing to do (all enabled services cached)'); return; }

  const browser = await chromium.launch({ headless: !args.headed });
  const ctx = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    locale: 'en-US',
    viewport: { width: 1280, height: 900 },
  });
  const page = await ctx.newPage();

  let done = 0;
  const tally = Object.fromEntries(services.map((s) => [s, { hit: 0, miss: 0 }]));
  const t0 = Date.now();
  try {
    for (const s of work) {
      const query = `${s.artist} ${s.name}`;
      const prev = cache.get(s.id) || {};
      const rec = { id: s.id };
      for (const svc of services) {
        const field = SERVICE[svc].field;
        if (!needsService(prev, field, args.retryMisses)) { rec[field] = prev[field]; continue; }
        const cands = await fetchCandidates(page, svc, query, args.navTimeoutMs);
        const best = pickBest(s, cands, args.minScore);
        rec[field] = best ? best.url : null;
        if (best) { tally[svc].hit++; rec[`${svc}Match`] = { title: best.title, artist: best.artist, score: best.score }; }
        else tally[svc].miss++;
      }
      appendFileSync(cachePath, JSON.stringify(rec) + '\n');
      done++;
      if (done <= 20 || done % 50 === 0) {
        const rate = done / Math.max((Date.now() - t0) / 60000, 1e-6);
        process.stderr.write(`  [${done}/${work.length}] "${s.artist} — ${s.name}"  ` +
          services.map((svc) => `${svc}:${rec[SERVICE[svc].field] ? '✓' : '·'}`).join(' ') +
          `  ${rate.toFixed(0)}/min\n`);
      }
      await sleep(args.delayMs);
    }
  } finally {
    await browser.close();
  }

  const rate = done / Math.max((Date.now() - t0) / 60000, 1e-6);
  console.error(`\n✓ resolved ${done} songs @ ~${rate.toFixed(0)}/min`);
  for (const svc of services) console.error(`  ${svc}: hits=${tally[svc].hit} miss=${tally[svc].miss}`);
  console.error(`  cache: ${cachePath}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
