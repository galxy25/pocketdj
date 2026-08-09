#!/usr/bin/env node
// Explicit-edition resolver, LOOKUP route — stamps `appleMusicIdExplicit` on songs whose
// catalog id points at a clean edition.
//
// Replaces the discovery half of resolve-explicit-variants.mjs, which could not work: the
// iTunes *search* endpoint filters explicit content out of every response, so a 6-hour
// 31,038-song crawl on it returned 24,936 clean ids and 0 explicit ones. See
// lib/explicit-lookup.mjs for the evidence. The *lookup* endpoint is unfiltered, so this
// walks song → artist → the artist's explicit album of the same title → the matching track.
//
// It is ADD-only: never deletes, never overwrites `appleMusicId` or `explicit`, and leaves
// the `appleMusicIdClean` values the earlier crawl produced intact (those are real, and
// they power the per-playlist "Clean versions only" toggle).
//
// Three append-only ndjson caches make a multi-hour run resumable at any point:
//   song-meta.ndjson    {id, artistId, collectionName, cls}
//   artist-albums.ndjson {artistId, albums:[{id,name,cls}]}
//   album-tracks.ndjson  {albumId, tracks:[{id,name,ms,cls}]}
//
// Usage:
//   node scripts/resolve-explicit-lookup.mjs                 # collection members only
//   node scripts/resolve-explicit-lookup.mjs --all           # the whole index
//   node scripts/resolve-explicit-lookup.mjs --dry-run --limit 200
import { createReadStream, mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { collectionSongIds } from './resolve-explicit-variants.mjs';
import { pickSiblingAlbum, pickTrackInAlbum, albumRow, trackRow } from './lib/explicit-lookup.mjs';
import { classifyExplicitness } from './lib/explicit-variants.mjs';

const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const a = {
    index: 'public/apple-music-index.json',
    cacheDir: 'index-out/apple-music',
    delayMs: 3000,      // ~20/min — the documented iTunes budget
    saveEvery: 200,
    all: false,
    dryRun: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index = next();
    else if (k === '--cache-dir') a.cacheDir = next();
    else if (k === '--collections') a.collections = next();
    else if (k === '--out') a.out = next();
    else if (k === '--delay-ms') a.delayMs = parseInt(next(), 10);
    else if (k === '--save-every') a.saveEvery = parseInt(next(), 10);
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--all') a.all = true;
    else if (k === '--dry-run') a.dryRun = true;
  }
  return a;
}

const COLLECTIONS_DEFAULTS = [
  join(homedir(), 'Library', 'Containers', 'com.levi.pocketdj', 'Data', 'Library',
       'Application Support', 'pocketdj-collections.json'),
  join(homedir(), 'Library', 'Application Support', 'pocketdj-collections.json'),
];

// ---------- iTunes lookup with adaptive backoff (same self-healing contract as the
// original resolver: this is a multi-hour job, so a network blip must never end it) ----------
let curDelay = 3000;
let backoff = 0;

async function lookup(params) {
  const url = `https://itunes.apple.com/lookup?${params}`;
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await fetch(url, { headers: { 'User-Agent': 'PocketDJ-explicit-lookup/1.0' } });
    } catch (e) {
      const wait = Math.min(60000, 2000 * Math.min(attempt + 1, 30));
      process.stderr.write(`\n  🌐 network error (${e.cause?.code || e.code || e.message}); retry in ${Math.round(wait / 1000)}s\n`);
      await sleep(wait);
      continue;
    }
    if (res.status === 200) {
      if (backoff > 0) backoff = Math.max(0, backoff - 250);
      const body = await res.json().catch(() => ({ results: [] }));
      return body.results || [];
    }
    if (res.status === 403 || res.status === 429) {
      backoff = Math.min(60000, (backoff || 1000) * 2);
      process.stderr.write(`\n  ⏳ throttled (${res.status}); backing off ${Math.round(backoff / 1000)}s\n`);
      await sleep(backoff);
      continue;
    }
    if (attempt >= 4) return null;
    await sleep(1500 * (attempt + 1));
  }
}

async function loadNdjson(file, key) {
  const map = new Map();
  if (!existsSync(file)) return map;
  const rl = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const ln of rl) {
    if (!ln.trim()) continue;
    try { const o = JSON.parse(ln); map.set(String(o[key]), o); } catch { /* skip bad line */ }
  }
  return map;
}

function atomicWriteJSON(file, obj) {
  const tmp = file + '.tmp';
  writeFileSync(tmp, JSON.stringify(obj));
  renameSync(tmp, file);
}

function refreshManifestCounts(index) {
  if (!index.manifest) return;
  const songs = index.songs || [];
  index.manifest.counts = {
    ...(index.manifest.counts || {}),
    songsWithExplicitVariant: songs.filter((s) => s.appleMusicIdExplicit).length,
    songsWithCleanVariant: songs.filter((s) => s.appleMusicIdClean).length,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  curDelay = args.delayMs;
  const indexPath = resolve(expand(args.index));
  const outPath = resolve(expand(args.out || args.index));
  const cacheDir = resolve(expand(args.cacheDir));
  if (!existsSync(indexPath)) { console.error('index not found:', indexPath); process.exit(1); }
  mkdirSync(cacheDir, { recursive: true });
  const songMetaPath = join(cacheDir, 'song-meta.ndjson');
  const artistPath = join(cacheDir, 'artist-albums.ndjson');
  const albumPath = join(cacheDir, 'album-tracks.ndjson');

  console.error(`Reading index: ${indexPath}`);
  const index = JSON.parse(readFileSync(indexPath, 'utf8'));
  const songs = index.songs || [];
  const albumName = new Map((index.albums || []).map((a) => [a.id, a.name]));
  const albumTracks = new Map((index.albums || []).map((a) => [a.id, a.trackList || []]));

  let scope = null;
  if (!args.all) {
    const candidates = args.collections ? [expand(args.collections)] : COLLECTIONS_DEFAULTS;
    const collectionsPath = candidates.find((p) => existsSync(p));
    if (!collectionsPath) {
      console.error('No collections document found. Looked at:');
      for (const p of candidates) console.error('  ' + p);
      console.error('Pass --collections <path>, or --all to resolve the WHOLE index.');
      process.exit(1);
    }
    let doc = {};
    try { doc = JSON.parse(readFileSync(collectionsPath, 'utf8')); }
    catch (e) { console.error(`collections doc unreadable (${e.message}):`, collectionsPath); process.exit(1); }
    scope = collectionSongIds(doc, albumTracks);
    console.error(`  collections: ${collectionsPath}`);
  }

  const scoped = scope ? songs.filter((s) => scope.has(s.id)) : songs;
  // Only songs with a catalog id can take this route — the artist is discovered from it.
  const todoAll = scoped.filter((s) => !s.appleMusicIdExplicit && s.appleMusicId);
  const skippedNoId = scoped.filter((s) => !s.appleMusicIdExplicit && !s.appleMusicId).length;
  const todo = args.limit ? todoAll.slice(0, args.limit) : todoAll;
  console.error(`  scoped: ${scoped.length}  needing explicit: ${todoAll.length}  (no catalog id, skipped: ${skippedNoId})`);
  console.error(`  working on: ${todo.length}${args.dryRun ? ' [dry-run]' : ''}\n`);

  const songMeta = await loadNdjson(songMetaPath, 'id');
  const artistCache = await loadNdjson(artistPath, 'artistId');
  const albumCache = await loadNdjson(albumPath, 'albumId');
  console.error(`  caches: songs=${songMeta.size} artists=${artistCache.size} albums=${albumCache.size}`);

  const append = (f, o) => { if (!args.dryRun) appendFileSync(f, JSON.stringify(o) + '\n'); };
  const t0 = Date.now();
  const progress = (label, done, total) => {
    const rate = done / Math.max((Date.now() - t0) / 60000, 0.01);
    const eta = (total - done) / Math.max(rate, 0.1);
    process.stderr.write(`  ${label} ${done}/${total}  ${rate.toFixed(0)}/min  ETA ~${(eta / 60).toFixed(1)}h\n`);
  };

  // ---- phase 1: song metadata, 100 ids per lookup call ----
  const needMeta = todo.filter((s) => !songMeta.has(String(s.appleMusicId)));
  console.error(`\n[1/4] song metadata — ${needMeta.length} to fetch (${Math.ceil(needMeta.length / 100)} batched calls)`);
  for (let i = 0; i < needMeta.length; i += 100) {
    const batch = needMeta.slice(i, i + 100);
    const ids = batch.map((s) => s.appleMusicId).join(',');
    const rows = await lookup(`id=${ids}`);
    const byId = new Map((rows || []).filter((r) => r.wrapperType === 'track').map((r) => [String(r.trackId), r]));
    for (const s of batch) {
      const r = byId.get(String(s.appleMusicId));
      const rec = r
        ? { id: String(s.appleMusicId), artistId: r.artistId || null, collectionName: r.collectionName || '', cls: classifyExplicitness(r.trackExplicitness) }
        : { id: String(s.appleMusicId), artistId: null, collectionName: '', cls: null };
      songMeta.set(rec.id, rec);
      append(songMetaPath, rec);
    }
    if ((i / 100) % 5 === 0) progress('[1/4]', Math.min(i + 100, needMeta.length), needMeta.length);
    await sleep(curDelay);
  }

  // Free win: a song whose own catalog id is already the explicit edition needs no crawl.
  let already = 0;
  for (const s of todo) {
    const m = songMeta.get(String(s.appleMusicId));
    if (m && m.cls === 'explicit') { s.appleMusicIdExplicit = String(s.appleMusicId); already++; }
  }
  console.error(`  already explicit (stamped from own id): ${already}`);

  // ---- phase 2: artist album catalogs (the unfiltered source of explicit albums) ----
  const need = todo.filter((s) => !s.appleMusicIdExplicit);
  const artistIds = [...new Set(need.map((s) => songMeta.get(String(s.appleMusicId))?.artistId).filter(Boolean).map(String))];
  const needArtists = artistIds.filter((a) => !artistCache.has(a));
  console.error(`\n[2/4] artist catalogs — ${needArtists.length} to fetch (of ${artistIds.length} distinct artists)`);
  let n = 0;
  for (const aid of needArtists) {
    const rows = await lookup(`id=${aid}&entity=album&limit=200`);
    const albums = (rows || []).filter((r) => r.wrapperType === 'collection').map(albumRow).filter((a) => a.id);
    const rec = { artistId: aid, albums };
    artistCache.set(aid, rec);
    append(artistPath, rec);
    if (++n % 25 === 0) progress('[2/4]', n, needArtists.length);
    await sleep(curDelay);
  }

  // ---- phase 3: track lists for the explicit sibling albums we actually need ----
  const wanted = new Map();   // albumId -> songs waiting on it
  for (const s of need) {
    const m = songMeta.get(String(s.appleMusicId));
    if (!m?.artistId) continue;
    const cat = artistCache.get(String(m.artistId));
    if (!cat) continue;
    const sib = pickSiblingAlbum(cat.albums, 'explicit', albumName.get(s.albumId), m.collectionName);
    if (!sib) continue;
    if (!wanted.has(sib)) wanted.set(sib, []);
    wanted.get(sib).push(s);
  }
  const needAlbums = [...wanted.keys()].filter((a) => !albumCache.has(String(a)));
  console.error(`\n[3/4] explicit album track lists — ${needAlbums.length} to fetch (of ${wanted.size} matched sibling albums)`);
  n = 0;
  for (const aid of needAlbums) {
    const rows = await lookup(`id=${aid}&entity=song&limit=200`);
    const tracks = (rows || []).filter((r) => r.wrapperType === 'track').map(trackRow).filter((t) => t.id);
    const rec = { albumId: String(aid), tracks };
    albumCache.set(String(aid), rec);
    append(albumPath, rec);
    if (++n % 25 === 0) {
      progress('[3/4]', n, needAlbums.length);
      if (!args.dryRun) atomicWriteJSON(outPath, index);
    }
    await sleep(curDelay);
  }

  // ---- phase 4: match tracks and stamp ----
  console.error(`\n[4/4] matching`);
  let stamped = 0, noAlbum = 0, noTrack = 0;
  for (const s of need) {
    const m = songMeta.get(String(s.appleMusicId));
    const cat = m?.artistId ? artistCache.get(String(m.artistId)) : null;
    const sib = cat ? pickSiblingAlbum(cat.albums, 'explicit', albumName.get(s.albumId), m.collectionName) : null;
    if (!sib) { noAlbum++; continue; }
    const al = albumCache.get(String(sib));
    const hit = al ? pickTrackInAlbum(s, al.tracks, 'explicit') : null;
    if (hit) { s.appleMusicIdExplicit = hit; stamped++; } else noTrack++;
  }

  if (args.dryRun) {
    console.error(`\n[dry-run] would stamp ${stamped + already} explicit ids (own-id ${already}, resolved ${stamped}); no sibling album ${noAlbum}, no track match ${noTrack}`);
    return;
  }
  refreshManifestCounts(index);
  atomicWriteJSON(outPath, index);
  console.error(`\n✓ ${outPath}`);
  console.error(`  stamped this run: ${stamped + already} (own-id ${already}, resolved ${stamped})`);
  console.error(`  unresolved: no sibling album ${noAlbum}, no track match ${noTrack}`);
  console.error(`  totals: explicit=${songs.filter((s) => s.appleMusicIdExplicit).length} clean=${songs.filter((s) => s.appleMusicIdClean).length} of ${songs.length}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
