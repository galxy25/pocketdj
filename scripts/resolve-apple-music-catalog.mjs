#!/usr/bin/env node
// Apple Music catalog-ID resolver — fills each "Apple Music (Local)" song with an
// `appleMusicId` (the Apple catalog "adam id", e.g. "944459436") so the native app
// can stream it via MusicKit instead of falling back to ripping.
//
// WHY a separate script (not folded into index-apple-music.mjs): the indexer is a
// fast (~1.6s), memory-bounded, NETWORK-FREE streaming parse of a 160MB plist.
// Catalog resolution is the opposite — a multi-DAY, network-bound crawl of ~93k
// songs against the public iTunes Search API (~20-60/min). Bolting that into the
// parser would couple a 1.6s job to a 3-day one. So this stands alone, is fully
// RESUMABLE (a per-song cache keyed by song id), and PACED with adaptive backoff.
//
// The iTunes Search API `trackId` IS the same Apple catalog id MusicKit plays by
// (`am:<storeID>`), so the client just does `MusicItemID(appleMusicId)`. The
// client-side consumer must still verify the id resolves and degrade to ripping if
// not (versions/regions can differ) — this script only supplies the candidate id.
//
// Usage:
//   node scripts/resolve-apple-music-catalog.mjs \
//     --index public/apple-music-index.json \
//     --cache index-out/apple-music/catalog-cache.ndjson \
//     [--delay-ms 2000] [--limit N] [--retry-misses] [--save-every 250] [--out FILE]
//
// Resume: just re-run the same command. Songs already in the cache (hit OR miss)
// are skipped; pass --retry-misses to re-attempt prior misses (e.g. after a
// throttling spell). Killing the process mid-run is safe: the cache is appended
// per-song and the index is flushed every --save-every resolutions.

import { createReadStream, mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

// ---------- args ----------
function parseArgs(argv) {
  const a = {
    index: 'public/apple-music-index.json',
    cache: 'index-out/apple-music/catalog-cache.ndjson',
    delayMs: 2000,        // ~30/min baseline; bursts of 60/min tested clean
    saveEvery: 250,
    retryMisses: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index = next();
    else if (k === '--cache') a.cache = next();
    else if (k === '--out') a.out = next();
    else if (k === '--delay-ms') a.delayMs = parseInt(next(), 10);
    else if (k === '--save-every') a.saveEvery = parseInt(next(), 10);
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--retry-misses') a.retryMisses = true;
  }
  return a;
}

// ---------- normalization (mirrors index-apple-music.mjs) ----------
function normalize(s) {
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
// "core" title: drop parentheticals/brackets (feat…, remaster…, version…) so a
// library "Post To Be (feat. Chris Brown & Jhene Aiko)" still matches a catalog
// row titled slightly differently.
function coreTitle(s) {
  return normalize(String(s || '').replace(/[\(\[].*?[\)\]]/g, ' '));
}
// version markers that should only match if BOTH sides have them (avoid grabbing a
// "Sped Up" / "Remix" / live take when the library track is the studio version).
const VERSION_WORDS = ['sped up', 'slowed', 'remix', 'mixed', 'live', 'karaoke', 'instrumental', 'acoustic', 'cover', 'commentary', 'demo', 'radio edit'];
function versionTags(s) {
  const n = normalize(s);
  return new Set(VERSION_WORDS.filter((w) => n.includes(normalize(w))));
}
const setEq = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));

// ---------- match scoring ----------
// Pick the best catalog row for a library song. Returns {storeId, collectionId, ...} or null.
export function bestMatch(song, albumName, results) {
  const aArtist = normalize(song.artist);
  const aTitle = normalize(song.name);
  const aCore = coreTitle(song.name);
  const aAlbum = normalize(albumName);
  const aTags = versionTags(song.name);

  let best = null, bestScore = -1;
  for (const r of results) {
    const rArtist = normalize(r.artistName);
    const rTitle = normalize(r.trackName);
    const rCore = coreTitle(r.trackName);
    const rAlbum = normalize(r.collectionName);
    const rTags = versionTags(r.trackName);

    // artist gate: equal, or one contained in the other (handles "feat." spillover)
    const artistOK = rArtist === aArtist || rArtist.includes(aArtist) || aArtist.includes(rArtist);
    if (!artistOK) continue;

    let score = 0;
    if (rTitle === aTitle) score += 100;
    else if (rCore === aCore && aCore) score += 70;
    else if (rCore.includes(aCore) || aCore.includes(rCore)) score += 35;
    else continue; // title doesn't plausibly match → skip

    if (rArtist === aArtist) score += 20;
    if (aAlbum && rAlbum === aAlbum) score += 25;      // same album → strong signal
    else if (aAlbum && rAlbum.includes(aAlbum)) score += 8;
    if (setEq(aTags, rTags)) score += 15;              // version markers agree
    else if (rTags.size > aTags.size) score -= 40;     // catalog adds remix/sped-up the library track lacks

    if (score > bestScore) { bestScore = score; best = r; }
  }
  if (!best || bestScore < 35) return null;
  return {
    storeId: String(best.trackId),
    // The SAME catalog row that gives the song's trackId also carries the album's
    // catalog id (`collectionId`). Capturing it lets index-apple-music.mjs emit each
    // album's `appleMusicId`, so a provisional Discover album is cleanly superseded by
    // the real indexed one. Undefined when the row has no collectionId (older/partial rows).
    collectionId: best.collectionId != null ? String(best.collectionId) : undefined,
    matchArtist: best.artistName,
    matchTitle: best.trackName,
    matchAlbum: best.collectionName,
    score: bestScore,
  };
}

// ---------- iTunes Search with adaptive backoff ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let curDelay = 0;        // set from args in main
let backoff = 0;         // extra delay added after throttling, decays over time

async function searchITunes(term) {
  const url = `https://itunes.apple.com/search?term=${encodeURIComponent(term)}&entity=song&limit=15`;
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await fetch(url, { headers: { 'User-Agent': 'PocketDJ-catalog-resolver/1.0' } });
    } catch (e) {
      // Transient network error (offline, DNS, EHOSTUNREACH, laptop asleep). This is a
      // multi-DAY run, so NEVER give up — back off (capped at 60s) and keep retrying so
      // the job self-heals when connectivity returns instead of crashing the process.
      const wait = Math.min(60000, 2000 * Math.min(attempt + 1, 30));
      process.stderr.write(`\n  🌐 network error (${e.cause?.code || e.code || e.message}); retry in ${Math.round(wait / 1000)}s\n`);
      await sleep(wait);
      continue;
    }
    if (res.status === 200) {
      if (backoff > 0) backoff = Math.max(0, backoff - 250); // decay after a clean hit
      const body = await res.json().catch(() => ({ results: [] }));
      return body.results || [];
    }
    if (res.status === 403 || res.status === 429) {
      backoff = Math.min(60000, (backoff || 1000) * 2);
      const wait = backoff;
      process.stderr.write(`\n  ⏳ throttled (${res.status}); backing off ${Math.round(wait / 1000)}s\n`);
      await sleep(wait);
      continue; // retry same term
    }
    // other 5xx/4xx — brief retry then give up on this term
    if (attempt >= 4) return null;
    await sleep(1500 * (attempt + 1));
  }
}

// ---------- cache (ndjson, one {id, storeId|null} per line) ----------
async function loadCache(file) {
  const map = new Map();
  if (!existsSync(file)) return map;
  const rl = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const ln of rl) {
    if (!ln.trim()) continue;
    try { const o = JSON.parse(ln); map.set(o.id, o); } catch { /* skip bad line */ }
  }
  return map;
}

function atomicWriteJSON(file, obj) {
  const tmp = file + '.tmp';
  writeFileSync(tmp, JSON.stringify(obj));
  renameSync(tmp, file);
}

async function main() {
  const args = parseArgs(process.argv);
  curDelay = args.delayMs;
  const indexPath = resolve(expand(args.index));
  const outPath = resolve(expand(args.out || args.index));
  const cachePath = resolve(expand(args.cache));
  if (!existsSync(indexPath)) { console.error('index not found:', indexPath); process.exit(1); }
  mkdirSync(dirname(cachePath), { recursive: true });

  console.error(`Reading index: ${indexPath}`);
  const index = JSON.parse(readFileSync(indexPath, 'utf8'));
  const songs = index.songs || [];
  const albumName = new Map((index.albums || []).map((a) => [a.id, a.name]));
  const cache = await loadCache(cachePath);
  console.error(`  songs=${songs.length} cached=${cache.size}`);

  // Apply existing cache hits to the in-memory index up front (so a flush early on
  // already reflects prior runs), and build the work list.
  const todo = [];
  for (const s of songs) {
    const c = cache.get(s.id);
    // Skip a cache HIT only once it ALSO carries the album `collectionId` (added for the
    // Discover-album dedupe). A legacy hit with storeId but no collectionId is re-resolved
    // so the album id gets captured; its storeId is still applied meanwhile.
    if (c && c.storeId && c.collectionId) { s.appleMusicId = c.storeId; continue; }
    if (c && c.storeId) s.appleMusicId = c.storeId;                 // keep the song id while we re-resolve for collectionId
    if (c && !c.storeId && !args.retryMisses) continue; // known miss, skip
    todo.push(s);
  }
  console.error(`  to resolve: ${todo.length}${args.limit ? ` (capped at ${args.limit})` : ''}`);
  const work = args.limit ? todo.slice(0, args.limit) : todo;

  let done = 0, hits = 0, misses = 0;
  const t0 = Date.now();
  for (const s of work) {
    const term = `${s.name} ${s.artist}`;
    const results = await searchITunes(term);
    let rec;
    if (results == null) {
      // hard failure for this term — record nothing (will retry next run)
      misses++;
    } else {
      const m = bestMatch(s, albumName.get(s.albumId), results);
      // `collectionId` (the album catalog id) is written next to `storeId`; JSON.stringify
      // omits it when undefined, so the record stays backward-compatible. On re-runs, cache
      // HITS are skipped below (never re-appended), so an already-captured collectionId is
      // preserved as-is; older records lacking it simply resolve to no album id — expected.
      if (m) { s.appleMusicId = m.storeId; hits++; rec = { id: s.id, storeId: m.storeId, collectionId: m.collectionId, matchTitle: m.matchTitle, matchArtist: m.matchArtist, matchAlbum: m.matchAlbum }; }
      else { misses++; rec = { id: s.id, storeId: null }; }
      appendFileSync(cachePath, JSON.stringify(rec) + '\n');
    }

    done++;
    if (done % args.saveEvery === 0) {
      atomicWriteJSON(outPath, index);
      const rate = done / ((Date.now() - t0) / 60000);
      const etaMin = (work.length - done) / Math.max(rate, 0.1);
      process.stderr.write(`  ${done}/${work.length}  hits=${hits} miss=${misses}  ${rate.toFixed(0)}/min  ETA ~${(etaMin / 60).toFixed(1)}h\n`);
    }
    await sleep(curDelay);
  }

  atomicWriteJSON(outPath, index);
  // refresh manifest counts so the artifact self-reports streamable coverage
  const withId = songs.filter((s) => s.appleMusicId).length;
  if (index.manifest) { index.manifest.counts = { ...(index.manifest.counts || {}), songsWithAppleMusicId: withId }; }
  atomicWriteJSON(outPath, index);

  console.error(`\n✓ ${outPath}`);
  console.error(`  resolved this run: hits=${hits} miss=${misses}  total with appleMusicId: ${withId}/${songs.length}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
