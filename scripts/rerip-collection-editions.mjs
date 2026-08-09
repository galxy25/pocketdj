#!/usr/bin/env node
// COLLECTION-SCOPED edition re-rip — the ONE bulk path Levi asked for:
//   "only ones i want to re rip [are] all those in collections"
//
// Walks COLLECTION MEMBERS ONLY (pockets + playlists + setlists — ~31k songs, versus
// 96k catalog-wide) and enqueues the MISSING edition for each song whose catalog id for
// that edition is known. Songs outside every collection are deliberately NOT touched:
// they are served by the app's LAZY on-demand path (a play of a song whose wanted edition
// isn't stored enqueues that one song, at the moment of use).
//
// ONE MECHANISM, TWO TRIGGERS. This script does not have a queue, a worker or a storage
// scheme of its own. It POSTs the same variant song ids ("<baseId>_explicit" /
// "<baseId>_clean") to the same `POST /rip-collection` endpoint the app's collection RIP
// uses, which funnels every id through the same `acceptRip` → durable queue → single-flight
// dedup → `rips/<baseId>_<edition>.mp3` upload as the lazy on-demand miss. The only
// difference between the two triggers is who calls it.
//
// IDEMPOTENT at two layers: this script skips anything already in the rips manifest, and
// the server skips anything already ripped or already in flight. Re-running enqueues
// nothing new.
//
// DEFAULT DRY RUN. It prints the true cost — songs to enqueue, bytes implied at the
// current average rip size, and estimated wall-clock at the server's observed throughput —
// and exits without touching the server. Add --apply to actually enqueue.
//
// EDITION SELECTION mirrors the app's ONE precedence function (EditionPolicy.decide,
// apple/PocketDJ/Models/CleanOnly.swift), in the same order:
//   1. the collection carries `cleanOnly` → CLEAN, always (it beats the global preference);
//   2. otherwise the global preference (--edition, default `explicit`);
//   3. a substitution is REAL only when that edition's catalog id is known AND differs from
//      the song's primary `appleMusicId` — an edition we cannot NAME is never enqueued,
//      because the server would have to guess it from artist+title, which is exactly how
//      wrong-edition audio ends up filed under a right-looking key.
// A song that sits in BOTH a clean-only collection and an ordinary one takes CLEAN: the
// restriction is the safe answer, and it is what that song plays inside the clean-only
// collection.
//
// Usage:
//   node scripts/rerip-collection-editions.mjs                        # DRY RUN, explicit
//   node scripts/rerip-collection-editions.mjs --edition clean
//   node scripts/rerip-collection-editions.mjs --json worklist.json
//   node scripts/rerip-collection-editions.mjs --apply --server http://imac:8787
//
// Flags:
//   --index <path>       catalog index (repeatable; default public/apple-music-index.json)
//   --collections <path> the Mac app's pocketdj-collections.json
//   --edition explicit|clean   the GLOBAL preference to mirror (default explicit)
//   --manifest <url|path>      rips manifest (default: the public rips bucket)
//   --server <url> --token <t> rip server (only needed with --apply)
//   --batch N            ids per /rip-collection POST (default 500)
//   --limit N            cap the work list (for a cautious first run)
//   --json <path|->      write the work list as JSON ('-' = stdout)
//   --avg-bytes N --rate N     override the measured cost inputs
//   --apply              ACTUALLY enqueue (default is a dry run)

import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { collectionSongIds } from './resolve-explicit-variants.mjs';

const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

const DEFAULT_MANIFEST =
  'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com/rips/manifest.json';

const COLLECTIONS_DEFAULTS = [
  join(homedir(), 'Library', 'Containers', 'com.levi.pocketdj', 'Data', 'Library',
       'Application Support', 'pocketdj-collections.json'),
  join(homedir(), 'Library', 'Application Support', 'pocketdj-collections.json'),
];

// ---------- args ----------
export function parseArgs(argv) {
  const a = {
    index: [], edition: 'explicit', manifest: DEFAULT_MANIFEST,
    batch: 500, apply: false, server: process.env.RIP_SERVER_URL || '',
    token: process.env.RIP_TOKEN || '',
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--index') a.index.push(next());
    else if (k === '--collections') a.collections = next();
    else if (k === '--edition') a.edition = next();
    else if (k === '--manifest') a.manifest = next();
    else if (k === '--server') a.server = next();
    else if (k === '--token') a.token = next();
    else if (k === '--batch') a.batch = parseInt(next(), 10);
    else if (k === '--limit') a.limit = parseInt(next(), 10);
    else if (k === '--json') a.json = next();
    else if (k === '--avg-bytes') a.avgBytes = parseInt(next(), 10);
    else if (k === '--rate') a.rate = parseFloat(next());
    else if (k === '--apply') a.apply = true;
  }
  if (!a.index.length) a.index = ['public/apple-music-index.json'];
  if (a.edition !== 'explicit' && a.edition !== 'clean') {
    throw new Error(`--edition must be "explicit" or "clean" (got "${a.edition}")`);
  }
  return a;
}

// ---------- the edition decision (the JS mirror of EditionPolicy.decide) ----------

/// The catalog id of a specific EDITION of a song — the mirror of
/// `IndexSong.appleMusicId(for:)`: the variant field, falling back to the primary id when
/// the primary IS already that edition per the `explicit` flag. Never invents an id.
export function catalogIdFor(song, edition) {
  if (edition === 'clean') {
    return song.appleMusicIdClean || (song.explicit === false ? song.appleMusicId : null) || null;
  }
  return song.appleMusicIdExplicit || (song.explicit === true ? song.appleMusicId : null) || null;
}

/// The edition decision for one song, mirroring `EditionPolicy.decide`. Returns
/// `{ edition, catalogId }` or null for "no substitution".
export function decide(song, { collectionCleanOnly, preferredEdition }) {
  if (!song) return null;
  if (collectionCleanOnly) {
    // Rule 1. Non-explicit songs already ARE a clean cut — pass through untouched.
    if (song.explicit !== true) return null;
    return substitution(song, 'clean');
  }
  return substitution(song, preferredEdition);
}

function substitution(song, edition) {
  const id = catalogIdFor(song, edition);
  if (!id) return null;                       // the edition is unresolved — never guessed
  if (id === song.appleMusicId) return null;  // the primary already IS this edition
  return { edition, catalogId: id };
}

/// The edition-keyed storage id — the same convention `SongVariant.variantId` and the rip
/// server's VARIANT_ID regex use, so the object lands at `rips/<baseId>_<edition>.mp3`
/// beside (never on top of) the song's existing rip.
export const variantId = (base, edition) => `${base}_${edition}`;

// ---------- per-collection membership (reusing collectionSongIds' walk) ----------

/// The pockets reachable from `roots` through `childPocketIds` (cycle-guarded). This is a
/// plain graph closure, NOT the song-gathering walk — that stays entirely inside
/// `collectionSongIds`, which we then run over exactly this sub-document so only the target
/// collection is seeded.
function reachablePockets(doc, roots) {
  const byId = new Map((doc?.pockets || []).filter((p) => p && p.id).map((p) => [p.id, p]));
  const seen = new Set();
  const out = [];
  const walk = (id) => {
    if (!id || seen.has(id)) return;
    seen.add(id);
    const p = byId.get(id);
    if (!p) return;
    out.push(p);
    for (const c of p.childPocketIds || []) walk(c);
  };
  for (const r of roots) walk(r);
  return out;
}

/// Song ids of ONE collection, resolved by `collectionSongIds` over a sub-document that
/// seeds only that collection (plus whatever pockets it reaches). Album expansion, repeat
/// keys, nesting and the cycle guard all stay in the shared walk.
export function songIdsOfCollection(doc, coll, albumTracks) {
  if (coll.kind === 'pocket') {
    return collectionSongIds({ pockets: reachablePockets(doc, [coll.id]) }, albumTracks);
  }
  if (coll.kind === 'playlist') {
    const pocketRefs = [];
    const scan = (nodes) => {
      for (const n of nodes || []) {
        if (!n || typeof n !== 'object') continue;
        if (n.kind === 'pocket' && n.pocketId) pocketRefs.push(n.pocketId);
        else if (n.kind === 'sequence') scan(n.children);
      }
    };
    scan(coll.raw?.sequences);
    return collectionSongIds(
      { pockets: reachablePockets(doc, pocketRefs), playlists: [coll.raw] }, albumTracks);
  }
  return collectionSongIds({ setlists: [coll.raw] }, albumTracks);
}

/// Every collection in the doc, flattened to {kind, id, name, cleanOnly, raw}.
export function collectionsOf(doc) {
  const out = [];
  for (const p of doc?.pockets || []) {
    if (p && p.id) out.push({ kind: 'pocket', id: p.id, name: p.name || p.id, cleanOnly: p.cleanOnly === true, raw: p });
  }
  for (const p of doc?.playlists || []) {
    if (p && p.id) out.push({ kind: 'playlist', id: p.id, name: p.name || p.id, cleanOnly: p.cleanOnly === true, raw: p });
  }
  for (const s of doc?.setlists || []) {
    // A frozen setlist carries its editions per track; it has no clean-only flag of its own.
    if (s && s.id) out.push({ kind: 'setlist', id: s.id, name: s.name || s.id, cleanOnly: false, raw: s });
  }
  return out;
}

// ---------- the work list ----------

/// PURE: given the catalog, the collections doc and the rips manifest, decide what to
/// enqueue. `manifest` is the songId → entry map (only presence is read).
export function buildWorkList({ songsById, albumTracks, doc, manifest, preferredEdition }) {
  const members = collectionSongIds(doc, albumTracks);
  const colls = collectionsOf(doc);

  // Songs inside a clean-only collection take CLEAN regardless of the global preference.
  const cleanOnlyMembers = new Set();
  for (const c of colls) {
    if (!c.cleanOnly) continue;
    for (const id of songIdsOfCollection(doc, c, albumTracks)) cleanOnlyMembers.add(id);
  }

  const enqueue = [];
  const stats = {
    members: 0, alreadyStored: 0, noSubstitution: 0, unknownCatalogId: 0,
    cleanOnly: 0, explicit: 0, clean: 0,
  };

  for (const songId of members) {
    const song = songsById.get(songId);
    if (!song) continue;                       // studio / profile / stale id — not a catalog song
    stats.members++;
    const isCleanOnly = cleanOnlyMembers.has(songId);
    if (isCleanOnly) stats.cleanOnly++;
    const d = decide(song, {
      collectionCleanOnly: isCleanOnly,
      preferredEdition,
    });
    if (!d) {
      // Either the song's own cut already IS the wanted edition, or that edition has no
      // catalog id. Both mean "nothing to enqueue"; separate them for the report.
      const known = catalogIdFor(song, isCleanOnly ? 'clean' : preferredEdition);
      if (known) stats.noSubstitution++; else stats.unknownCatalogId++;
      continue;
    }
    const vid = variantId(songId, d.edition);
    if (manifest[vid]) { stats.alreadyStored++; continue; }   // idempotent: already ripped
    stats[d.edition]++;
    enqueue.push({
      songId: vid, baseId: songId, edition: d.edition, catalogId: d.catalogId,
      title: song.name, artist: song.artist, lengthMs: song.length || null,
      cleanOnlyCollection: isCleanOnly,
    });
  }
  return { enqueue, stats };
}

// ---------- cost model ----------

/// Average bytes of a completed rip, measured from the manifest itself.
export function averageRipBytes(manifest) {
  let n = 0, sum = 0;
  for (const e of Object.values(manifest)) {
    if (e && typeof e.bytes === 'number' && e.bytes > 0) { sum += e.bytes; n++; }
  }
  return n ? Math.round(sum / n) : 0;
}

/// OBSERVED throughput in rips/hour, from the manifest's `rippedAt` stamps: the most recent
/// `window` completions divided by the wall-clock they span. Returns 0 when the manifest
/// carries too few timestamps to measure (the caller then falls back to the real-time floor).
export function observedRipsPerHour(manifest, window = 200) {
  const stamps = Object.values(manifest)
    .map((e) => (e && typeof e.rippedAt === 'number' ? e.rippedAt : 0))
    .filter((t) => t > 0)
    .sort((a, b) => b - a)
    .slice(0, window);
  if (stamps.length < 5) return 0;
  const spanHours = (stamps[0] - stamps[stamps.length - 1]) / 3_600_000;
  if (!(spanHours > 0)) return 0;
  return (stamps.length - 1) / spanHours;
}

const fmtBytes = (b) => {
  if (!b) return '?';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = b;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v < 10 ? 1 : 0)} ${u[i]}`;
};
const fmtHours = (h) => (h >= 48 ? `${(h / 24).toFixed(1)} days` : `${h.toFixed(1)} h`);

export function costReport(enqueue, { avgBytes, ripsPerHour }) {
  const bytes = avgBytes ? avgBytes * enqueue.length : 0;
  // A capture runs in REAL TIME, so the sum of the songs' own durations is a hard floor on
  // the wall clock regardless of what the queue has historically managed.
  const realtimeHours = enqueue.reduce((s, e) => s + (e.lengthMs || 0), 0) / 3_600_000;
  const observedHours = ripsPerHour > 0 ? enqueue.length / ripsPerHour : 0;
  return { count: enqueue.length, avgBytes, bytes, realtimeHours, ripsPerHour, observedHours };
}

// ---------- manifest ----------

async function loadManifest(src) {
  if (/^https?:/.test(src)) {
    const res = await fetch(src, { headers: { 'User-Agent': 'PocketDJ-rerip/1.0' } });
    if (!res.ok) throw new Error(`manifest fetch ${res.status} ${src}`);
    return await res.json();
  }
  const p = resolve(expand(src));
  if (!existsSync(p)) throw new Error(`manifest not found: ${p}`);
  return JSON.parse(readFileSync(p, 'utf8'));
}

// ---------- enqueue (the --apply path) ----------

/// POST the variant ids to the SAME `/rip-collection` the app's collection RIP uses — the
/// same durable queue, the same single-flight dedup, the same worker. Batched only so one
/// request body stays sane; the server treats each id exactly as a single `/rip` would.
export async function enqueueBatches(ids, { server, token, batch = 500, fetchImpl = fetch, log = () => {} }) {
  const counts = { ready: 0, queued: 0, inflight: 0, unknown: 0, total: 0 };
  for (let i = 0; i < ids.length; i += batch) {
    const slice = ids.slice(i, i + batch);
    const headers = { 'content-type': 'application/json' };
    if (token) headers.authorization = `Bearer ${token}`;
    const res = await fetchImpl(`${server.replace(/\/$/, '')}/rip-collection`, {
      method: 'POST', headers, body: JSON.stringify({ songIds: slice }),
    });
    if (!res.ok) throw new Error(`/rip-collection ${res.status}`);
    const body = await res.json();
    for (const k of Object.keys(counts)) counts[k] += (body.counts && body.counts[k]) || 0;
    log(`  batch ${i / batch + 1}: +${slice.length} → queued ${counts.queued} / ready ${counts.ready} / inflight ${counts.inflight} / unknown ${counts.unknown}`);
  }
  return counts;
}

// ---------- main ----------

async function main() {
  const args = parseArgs(process.argv);

  // catalog
  const songsById = new Map();
  const albumTracks = new Map();
  for (const p of args.index) {
    const path = resolve(expand(p));
    if (!existsSync(path)) { console.error('index not found:', path); process.exit(1); }
    const idx = JSON.parse(readFileSync(path, 'utf8'));
    for (const s of idx.songs || []) if (s && s.id) songsById.set(s.id, s);
    for (const a of idx.albums || []) if (a && a.id) albumTracks.set(a.id, a.trackList || []);
    console.error(`  index: ${path} (${(idx.songs || []).length} songs)`);
  }

  // collections
  const candidates = args.collections ? [expand(args.collections)] : COLLECTIONS_DEFAULTS;
  const collectionsPath = candidates.find((p) => existsSync(p));
  if (!collectionsPath) {
    console.error('No collections document found. Looked at:');
    for (const p of candidates) console.error('  ' + p);
    console.error('Pass --collections <path>.');
    process.exit(1);
  }
  const doc = JSON.parse(readFileSync(collectionsPath, 'utf8'));
  console.error(`  collections: ${collectionsPath}`);

  // manifest (what is ALREADY stored — the idempotence gate)
  const manifest = await loadManifest(args.manifest);
  console.error(`  manifest: ${args.manifest} (${Object.keys(manifest).length} entries)`);

  const { enqueue, stats } = buildWorkList({
    songsById, albumTracks, doc, manifest, preferredEdition: args.edition,
  });
  const work = args.limit ? enqueue.slice(0, args.limit) : enqueue;

  const avgBytes = args.avgBytes || averageRipBytes(manifest);
  const ripsPerHour = args.rate || observedRipsPerHour(manifest);
  const cost = costReport(work, { avgBytes, ripsPerHour });

  console.error('');
  console.error(`COLLECTION MEMBERS (catalog songs):   ${stats.members}`);
  console.error(`  in a clean-only collection:        ${stats.cleanOnly}`);
  console.error(`  already stored for this edition:   ${stats.alreadyStored}`);
  console.error(`  no substitution needed:            ${stats.noSubstitution}`);
  console.error(`  edition's catalog id UNKNOWN:      ${stats.unknownCatalogId}  (never enqueued — resolve ids first)`);
  console.error('');
  console.error(`TO ENQUEUE:                          ${cost.count}   (explicit ${stats.explicit} / clean ${stats.clean})`);
  console.error(`  average rip size (measured):       ${fmtBytes(cost.avgBytes)}`);
  console.error(`  storage implied:                   ${fmtBytes(cost.bytes)}`);
  console.error(`  wall clock, real-time capture:     ${fmtHours(cost.realtimeHours)}  (floor: Σ song lengths)`);
  console.error(cost.ripsPerHour > 0
    ? `  wall clock, observed throughput:   ${fmtHours(cost.observedHours)}  (${cost.ripsPerHour.toFixed(1)} rips/h measured)`
    : `  wall clock, observed throughput:   n/a (manifest carries too few timestamps)`);
  console.error('');

  if (args.json) {
    const payload = { generatedAt: new Date().toISOString(), edition: args.edition, stats, cost, enqueue: work };
    if (args.json === '-') {
      process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
    } else {
      const out = resolve(expand(args.json));
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, JSON.stringify(payload, null, 2));
      console.error(`  work list → ${out}`);
    }
  }

  if (!args.apply) {
    console.error('DRY RUN — nothing was enqueued. Re-run with --apply --server <url> to start.');
    return;
  }
  if (!args.server) { console.error('--apply needs --server <url> (or RIP_SERVER_URL).'); process.exit(1); }
  if (!work.length) { console.error('Nothing to enqueue.'); return; }
  console.error(`ENQUEUEING ${work.length} edition rips → ${args.server}/rip-collection`);
  const counts = await enqueueBatches(work.map((e) => e.songId), {
    server: args.server, token: args.token, batch: args.batch,
    log: (m) => console.error(m),
  });
  console.error(`Done. queued ${counts.queued} · inflight ${counts.inflight} · ready ${counts.ready} · unknown ${counts.unknown}`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
