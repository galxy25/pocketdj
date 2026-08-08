#!/usr/bin/env node
// Explicit/clean VARIANT resolver — stamps each song with its sibling-EDITION catalog
// ids (`appleMusicIdExplicit` / `appleMusicIdClean`) via the public iTunes Search API,
// so the app can stream/rip the edition the user prefers (Settings ▸ Apple Music ▸
// Explicit versions) and per-collection "Clean versions only" can substitute clean cuts.
//
// ADD-ONLY GUARANTEE: this script only ADDS the two variant fields. It never deletes
// rows, never overwrites a present variant id with null, and never touches
// `appleMusicId` (the user's cut), `explicit`, albums, or any audio.
//
// Like resolve-apple-music-catalog.mjs it is RESUMABLE (append-only ndjson cache keyed
// by song id — kill-safe at any point; re-run the same command to continue) and PACED
// (~20/min against the iTunes budget). By default it scopes to COLLECTION MEMBERS
// (songs referenced by any pocket/playlist/setlist in the Mac app's collections doc);
// pass --all for the whole index.
//
// OPS RUNBOOK (manual-run only — no nightly install):
//   1. node scripts/resolve-explicit-variants.mjs
//        (apple-music index, collection-scoped; ~6-7 h for ~8k members at 20/min)
//   2. Optionally the other sources, same collections file:
//        node scripts/resolve-explicit-variants.mjs --index public/current-index.json \
//          --cache index-out/analog/explicit-variants.ndjson
//        node scripts/resolve-explicit-variants.mjs --index public/digital-index.json \
//          --cache index-out/digital/explicit-variants.ndjson
//   3. Commit public/*.json, merge, deploy via publish-s3; on the iMac pull + restart
//      rip-server so its RIP_SOURCES copies carry the variant fields.
//   4. Levi flips Settings ▸ Apple Music ▸ Explicit versions ON (prefer explicit) —
//      that is what restores explicit listening (streams resolve appleMusicIdExplicit
//      first). Until the toggle is explicitly set, existing songs keep streaming their
//      primary cut (the tri-state substitution gate).
//
// Usage:
//   node scripts/resolve-explicit-variants.mjs \
//     [--index public/apple-music-index.json] \
//     [--cache index-out/apple-music/explicit-variants.ndjson] \
//     [--collections <pocketdj-collections.json>] [--all] \
//     [--delay-ms 3000] [--save-every 100] [--limit N] [--retry-misses] \
//     [--out FILE] [--dry-run]

import { createReadStream, mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { findEditions } from './lib/explicit-variants.mjs';

const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

// ---------- args ----------
function parseArgs(argv) {
  const a = {
    index: 'public/apple-music-index.json',
    cache: 'index-out/apple-music/explicit-variants.ndjson',
    delayMs: 3000,        // ~20/min — the documented iTunes budget
    saveEvery: 100,
    retryMisses: false,
    all: false,
    dryRun: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index = next();
    else if (k === '--cache') a.cache = next();
    else if (k === '--collections') a.collections = next();
    else if (k === '--out') a.out = next();
    else if (k === '--delay-ms') a.delayMs = parseInt(next(), 10);
    else if (k === '--save-every') a.saveEvery = parseInt(next(), 10);
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--retry-misses') a.retryMisses = true;
    else if (k === '--all') a.all = true;
    else if (k === '--dry-run') a.dryRun = true;
  }
  return a;
}

// Default collections-doc locations (the Mac app's sandbox container first, then the
// un-sandboxed Application Support path older builds used).
const COLLECTIONS_DEFAULTS = [
  join(homedir(), 'Library', 'Containers', 'com.levi.pocketdj', 'Data', 'Library',
       'Application Support', 'pocketdj-collections.json'),
  join(homedir(), 'Library', 'Application Support', 'pocketdj-collections.json'),
];

// ---------- collection-membership scoping (in-script, lenient — no app involvement) ----------
// Gathers every song id referenced by pockets (own songs + repeats keys + album expands +
// nested pockets, cycle-guarded), playlists (recursive node walk), and setlists. The result
// is intersected with the index's songs, which naturally drops studio/profile/amrec ids.
export function collectionSongIds(doc, albumsById) {
  const out = new Set();
  const pocketsById = new Map();
  for (const p of doc?.pockets || []) if (p && p.id) pocketsById.set(p.id, p);

  const addAlbum = (albumId) => {
    for (const sid of albumsById.get(albumId) || []) out.add(sid);
  };
  const seenPockets = new Set();
  const addPocket = (pocketId) => {
    if (!pocketId || seenPockets.has(pocketId)) return;   // cycle guard (DAG walk)
    seenPockets.add(pocketId);
    const p = pocketsById.get(pocketId);
    if (!p) return;
    for (const sid of p.songIds || []) out.add(sid);
    for (const sid of Object.keys(p.songRepeats || {})) out.add(sid);
    for (const aid of p.albumIds || []) addAlbum(aid);
    for (const cid of p.childPocketIds || []) addPocket(cid);
  };
  const walkNodes = (nodes) => {
    for (const n of nodes || []) {
      if (!n || typeof n !== 'object') continue;
      if (n.kind === 'song' && n.songId) out.add(n.songId);
      else if (n.kind === 'album' && n.albumId) addAlbum(n.albumId);
      else if (n.kind === 'pocket' && n.pocketId) addPocket(n.pocketId);
      else if (n.kind === 'sequence') walkNodes(n.children);
    }
  };

  for (const p of doc?.pockets || []) if (p && p.id) addPocket(p.id);
  for (const pl of doc?.playlists || []) walkNodes(pl?.sequences);
  for (const sl of doc?.setlists || []) {
    for (const t of sl?.tracks || []) if (t?.songId) out.add(t.songId);
  }
  return out;
}

// ---------- iTunes Search with adaptive backoff (verbatim from resolve-apple-music-catalog) ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let curDelay = 0;        // set from args in main
let backoff = 0;         // extra delay added after throttling, decays over time

async function searchITunes(term) {
  const url = `https://itunes.apple.com/search?term=${encodeURIComponent(term)}&entity=song&limit=25`;
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await fetch(url, { headers: { 'User-Agent': 'PocketDJ-catalog-resolver/1.0' } });
    } catch (e) {
      // Transient network error (offline, DNS, EHOSTUNREACH, laptop asleep). This is a
      // multi-HOUR run, so NEVER give up — back off (capped at 60s) and keep retrying so
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

// ---------- cache (ndjson, one {id, explicitId|null, cleanId|null, checkedAt} per line) ----------
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

// ADD-only stamp — never delete, never overwrite with null, never touch appleMusicId/explicit.
function stamp(s, rec) {
  if (rec.explicitId) s.appleMusicIdExplicit = rec.explicitId;
  if (rec.cleanId) s.appleMusicIdClean = rec.cleanId;
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
  const cachePath = resolve(expand(args.cache));
  if (!existsSync(indexPath)) { console.error('index not found:', indexPath); process.exit(1); }
  mkdirSync(dirname(cachePath), { recursive: true });

  console.error(`Reading index: ${indexPath}`);
  const index = JSON.parse(readFileSync(indexPath, 'utf8'));
  const songs = index.songs || [];
  const albumName = new Map((index.albums || []).map((a) => [a.id, a.name]));
  const albumTracks = new Map((index.albums || []).map((a) => [a.id, a.trackList || []]));

  // ---- scope: collection members (default) or --all ----
  let scope = null;   // Set<songId> | null = whole index
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

  const cache = await loadCache(cachePath);
  const inIndex = new Set(songs.map((s) => s.id));
  const scoped = scope ? songs.filter((s) => scope.has(s.id)) : songs;
  console.error(`  songs in index: ${songs.length}  in collections: ${scope ? [...scope].filter((id) => inIndex.has(id)).length : songs.length}  cached: ${cache.size}`);

  // Apply prior cache hits to the in-memory index up front (the resolver's pattern), so
  // an early flush already reflects previous runs; then build the work list.
  const todo = [];
  for (const s of scoped) {
    const c = cache.get(s.id);
    if (c) stamp(s, c);
    if (s.appleMusicIdExplicit && s.appleMusicIdClean) continue;   // both known — done
    if (c && !(args.retryMisses && !c.explicitId && !c.cleanId)) continue; // cached (partial counts as answered)
    todo.push(s);
  }
  console.error(`  to resolve: ${todo.length}${args.limit ? ` (capped at ${args.limit})` : ''}${args.dryRun ? ' [dry-run]' : ''}`);
  const work = args.limit ? todo.slice(0, args.limit) : todo;

  let done = 0, both = 0, one = 0, none = 0;
  const t0 = Date.now();
  for (const s of work) {
    const term = `${s.name} ${s.artist}`;
    const results = await searchITunes(term);
    if (results == null) {
      // hard failure for this term — record nothing (will retry next run)
      none++;
    } else {
      const { explicitId, cleanId } = findEditions(s, albumName.get(s.albumId), results);
      const rec = { id: s.id, explicitId, cleanId, checkedAt: Date.now() };
      if (explicitId && cleanId) both++; else if (explicitId || cleanId) one++; else none++;
      if (!args.dryRun) {
        appendFileSync(cachePath, JSON.stringify(rec) + '\n');   // append-only = the resume state
        stamp(s, rec);
      }
    }

    done++;
    if (done % args.saveEvery === 0) {
      if (!args.dryRun) atomicWriteJSON(outPath, index);
      const rate = done / ((Date.now() - t0) / 60000);
      const etaMin = (work.length - done) / Math.max(rate, 0.1);
      process.stderr.write(`  ${done}/${work.length}  both=${both} one=${one} none=${none}  ${rate.toFixed(0)}/min  ETA ~${(etaMin / 60).toFixed(1)}h\n`);
    }
    await sleep(curDelay);
  }

  if (args.dryRun) {
    console.error(`\n[dry-run] would stamp: both=${both} one-edition=${one} none=${none} (no files written)`);
    return;
  }
  refreshManifestCounts(index);
  atomicWriteJSON(outPath, index);

  console.error(`\n✓ ${outPath}`);
  console.error(`  resolved this run: both=${both} one-edition=${one} none=${none}`);
  console.error(`  totals: explicit=${songs.filter((s) => s.appleMusicIdExplicit).length} clean=${songs.filter((s) => s.appleMusicIdClean).length} of ${songs.length}`);
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
