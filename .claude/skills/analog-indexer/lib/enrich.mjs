#!/usr/bin/env node
// Fast, deterministic Node enricher — the PRIMARY enrichment path.
//
// iTunes Search/Lookup + (opt-in) MusicBrainz country + (capped) lyrics.ovh, all
// with real concurrency. This replaces doing the mechanical web fetches inside a
// slow sequential LLM agent loop; agents are reserved for what actually needs a
// model: the Wikipedia fallback (unmatched albums) and Haiku sentiment.
//
//   node enrich.mjs <parsed.json> --out-dir index-out/shards [options]
//     --concurrency 10     parallel albums
//     --lyrics-cap 6       lyrics.ovh attempts per album (0 to disable)
//     --country            also query MusicBrainz for country (slower, ~1 req/s)
//     --size 50            albums per shard file
//     --limit N            first N candidates only
//
// Output: index-out/shards/batch-XXXX.json = { batchIndex, albums: EnrichedAlbum[] }
// (compatible with assemble.js / cli.mjs merge). Sentiment is left empty here and
// filled by the Haiku pass (sentiment.mjs / the sentiment workflow).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { searchUrl, lookupUrl, upscaleArtwork, classifyMatch, yearOf } from './itunes.js';
import { chunk } from './batching.js';

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}
const has = (flag) => process.argv.includes(flag);

const parsedPath = process.argv[2];
const outDir = arg('--out-dir', 'index-out/shards');
const concurrency = parseInt(arg('--concurrency', '10'), 10);
const lyricsCap = parseInt(arg('--lyrics-cap', '6'), 10);
const doCountry = has('--country');
const shardSize = parseInt(arg('--size', '50'), 10);
const limit = parseInt(arg('--limit', '0'), 10);
const slice = arg('--slice', ''); // A:B
// iTunes Search API rate-limits aggressively (~20 req/min). Space iTunes calls
// through a single lane and back off hard on 403/429.
const itunesDelay = parseInt(arg('--itunes-delay', '0'), 10);
const retries = parseInt(arg('--retries', '4'), 10);

const UA = 'PocketDJ-Indexer/1.0 (levismschoen@gmail.com)';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchJSON(url, { timeout = 8000, headers } = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers });
    if (!res.ok) return { __status: res.status };
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

// Single-lane throttle + adaptive backoff for iTunes. `gate` serializes the
// spacing; `pausedUntil` enforces a global cooldown after a rate-limit hit.
let gate = Promise.resolve();
let pausedUntil = 0;
async function itunesGet(url) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    // wait for our slot in the lane (spacing)
    const mine = gate.then(() => sleep(itunesDelay));
    gate = mine;
    await mine;
    const wait = pausedUntil - Date.now();
    if (wait > 0) await sleep(wait);
    const j = await fetchJSON(url, { timeout: 9000 });
    if (j && j.__status && (j.__status === 429 || j.__status === 403 || j.__status >= 500)) {
      // rate-limited: global cooldown with exponential backoff, then retry
      const backoff = Math.min(60000, 4000 * Math.pow(2, attempt));
      pausedUntil = Date.now() + backoff;
      continue;
    }
    return j && j.__status ? null : j;
  }
  return null;
}

async function fetchLyrics(artist, title) {
  const url = `https://api.lyrics.ovh/v1/${encodeURIComponent(artist)}/${encodeURIComponent(title)}`;
  const j = await fetchJSON(url, { timeout: 5000 });
  const lyr = j && typeof j.lyrics === 'string' ? j.lyrics.trim() : '';
  return lyr ? lyr.slice(0, 1500) : null;
}

async function country(artist) {
  if (!doCountry) return undefined;
  const url = `https://musicbrainz.org/ws/2/artist/?query=artist:${encodeURIComponent(artist)}&fmt=json&limit=1`;
  const j = await fetchJSON(url, { timeout: 6000, headers: { 'User-Agent': UA } });
  const a = j && j.artists && j.artists[0];
  return a ? a.country || (a.area && a.area.name) || undefined : undefined;
}

async function enrichOne(cand, ci) {
  const sources = [];
  const base = {
    candidateIndex: ci,
    originalFilename: cand.originalFilename,
    fileLocation: cand.fileLocation,
    fileType: cand.fileType,
    dupIndex: cand.dupIndex ?? null,
    artist: cand.artistGuess || cand.spacedBlob,
    name: cand.albumGuess || cand.spacedBlob,
    tracks: [],
    sources,
    calls: {},
  };

  // 1) iTunes search + deterministic match (throttled + retried)
  const search = await itunesGet(searchUrl(cand.spacedBlob, { limit: 8 }));
  const results = (search && search.results) || [];
  const m = classifyMatch(cand.spacedBlob, results);
  base.calls.itunesResults = results.length;

  if (m.status !== 'matched' || !m.best) {
    base.status = 'unmatched';
    base.score = m.score;
    return base; // Wikipedia fallback (agent) handled separately
  }
  sources.push('itunes');
  const best = m.best;
  base.status = 'matched';
  base.matchConfidence = m.confidence;
  base.score = m.score;
  base.itunesCollectionId = best.collectionId;
  base.artist = best.artistName || base.artist;
  base.name = best.collectionName || base.name;
  base.genre = best.primaryGenreName;
  base.year = yearOf(best.releaseDate);
  base.coverArt = upscaleArtwork(best.artworkUrl100, 600);

  // 2) iTunes lookup -> tracklist (throttled + retried)
  const lookup = await itunesGet(lookupUrl(best.collectionId));
  const tracks = ((lookup && lookup.results) || []).filter((r) => r.wrapperType === 'track' || r.kind === 'song');
  base.tracks = tracks.map((t) => ({
    discNumber: t.discNumber ?? 1,
    trackNumber: t.trackNumber,
    name: t.trackName,
    artist: t.artistName,
    year: yearOf(t.releaseDate) ?? base.year,
    lengthMs: t.trackTimeMillis,
    explicit: t.trackExplicitness === 'explicit',
    lyrics: null,
    lyricsStatus: 'notfound',
    sentimentKeywords: [],
    sentimentSource: 'inferred',
  }));

  // 3) country (opt-in)
  base.country = await country(base.artist);
  if (base.country) sources.push('musicbrainz');

  // 4) lyrics (capped, concurrent within the album)
  if (lyricsCap > 0 && base.tracks.length) {
    const targets = base.tracks.slice(0, lyricsCap);
    await Promise.all(
      targets.map(async (t) => {
        const lyr = await fetchLyrics(t.artist || base.artist, t.name);
        if (lyr) {
          t.lyrics = lyr;
          t.lyricsStatus = 'found';
        }
      }),
    );
    if (targets.some((t) => t.lyricsStatus === 'found')) sources.push('lyrics.ovh');
  }

  return base;
}

// bounded-concurrency map
async function pool(items, worker, n) {
  const out = new Array(items.length);
  let idx = 0;
  let done = 0;
  async function run() {
    while (idx < items.length) {
      const i = idx++;
      out[i] = await worker(items[i], i);
      done++;
      if (done % 10 === 0 || done === items.length) process.stderr.write(`  enriched ${done}/${items.length}\n`);
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
  return out;
}

const parsed = JSON.parse(readFileSync(parsedPath, 'utf8'));
let candidates = parsed.candidates || [];
if (slice) {
  const [a, b] = slice.split(':').map((x) => parseInt(x, 10));
  candidates = candidates.slice(a || 0, isNaN(b) ? undefined : b);
}
if (limit > 0) candidates = candidates.slice(0, limit);

process.stderr.write(`enriching ${candidates.length} albums (concurrency ${concurrency}, lyricsCap ${lyricsCap}, country ${doCountry})\n`);
const enriched = await pool(candidates, (c, i) => enrichOne(c, i), concurrency);

mkdirSync(outDir, { recursive: true });
const shards = chunk(enriched, shardSize);
shards.forEach((albums, bi) => {
  writeFileSync(join(outDir, `batch-${String(bi).padStart(4, '0')}.json`), JSON.stringify({ batchIndex: bi, albums }));
});
const matched = enriched.filter((a) => a.status === 'matched').length;
const tracks = enriched.reduce((n, a) => n + a.tracks.length, 0);
const lyr = enriched.reduce((n, a) => n + a.tracks.filter((t) => t.lyricsStatus === 'found').length, 0);
process.stderr.write(`done: ${matched}/${enriched.length} matched, ${tracks} tracks, ${lyr} with lyrics -> ${shards.length} shards in ${outDir}\n`);
