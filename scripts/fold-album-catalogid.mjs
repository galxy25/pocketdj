#!/usr/bin/env node
// Stamp album `appleMusicId` into an Apple-Music index by aggregating the member tracks'
// `collectionId` (captured by resolve-apple-music-catalog.mjs) — the SAME mode-per-album
// logic index-apple-music.mjs uses, applied as a fold so we don't need to re-run the full
// Library.xml indexer. This is what activates the F7 Discover-album dedupe for OWNED albums:
// a provisional Discover album (appleMusicId = iTunes collectionId) is then superseded by the
// real indexed album carrying the same id.
//
// Usage:
//   node scripts/fold-album-catalogid.mjs [index.json] [catalog-cache.ndjson] [--apply]
//   (default index public/apple-music-index.json, cache index-out/apple-music/catalog-cache.ndjson)
//   Dry-run by default (prints how many albums WOULD be stamped); --apply writes the index.

import { readFileSync, writeFileSync, createReadStream, existsSync } from 'node:fs';
import { createInterface } from 'node:readline';

const args = process.argv.slice(2).filter((a) => a !== '--apply');
const APPLY = process.argv.includes('--apply');
const INDEX = args[0] || 'public/apple-music-index.json';
const CACHE = args[1] || 'index-out/apple-music/catalog-cache.ndjson';

export function mostCommonNonEmpty(values) {
  const counts = new Map();
  for (const v of values) { if (!v) continue; counts.set(v, (counts.get(v) || 0) + 1); }
  let best, bestN = 0;
  for (const [k, n] of counts) if (n > bestN) { bestN = n; best = k; }
  return best;
}

async function loadCollectionIds(cachePath) {
  const map = new Map();
  if (!existsSync(cachePath)) return map;
  const rl = createInterface({ input: createReadStream(cachePath, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const ln of rl) {
    if (!ln.trim()) continue;
    let o; try { o = JSON.parse(ln); } catch { continue; }
    if (o.id && o.collectionId) map.set(o.id, String(o.collectionId));
  }
  return map;
}

async function main() {
  if (!existsSync(INDEX)) { console.error('index not found:', INDEX); process.exit(1); }
  const collectionIds = await loadCollectionIds(CACHE);
  const idx = JSON.parse(readFileSync(INDEX, 'utf8'));
  const albums = idx.albums || [];
  let stamped = 0, already = 0;
  for (const a of albums) {
    // trackList entries are plain song-id strings in the published index
    // (older builds used {sid} objects — accept both).
    const cid = mostCommonNonEmpty(
      (a.trackList || []).map((e) => collectionIds.get(typeof e === 'string' ? e : e && e.sid)),
    );
    if (!cid) continue;
    if (a.appleMusicId === cid) { already++; continue; }
    a.appleMusicId = cid; stamped++;
  }
  console.error(`albums=${albums.length}  cache collectionIds=${collectionIds.size}  stamped=${stamped}  already=${already}`);
  if (APPLY) { writeFileSync(INDEX, JSON.stringify(idx)); console.error('wrote ' + INDEX); }
  else console.error('(dry-run — pass --apply to write the index)');
}

import { pathToFileURL } from 'node:url';
if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
