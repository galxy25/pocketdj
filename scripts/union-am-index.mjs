#!/usr/bin/env node
// union-am-index — reconcile two divergent apple-music-index.json versions with ZERO entity loss.
//
//   node scripts/union-am-index.mjs --local <a.json> --origin <b.json> --out <merged.json>
//
// WHY THIS EXISTS. The dev checkout and the nightly's always-on-main clone can both write this
// index, and when they diverge neither side is a superset: a full re-index
// (scripts/index-apple-music.mjs) rebuilds from Library.xml and so carries `dateAdded`, fresh
// `explicit` flags and downloaded-file pointers, but DROPS rows Music.app's XML export omits
// (subscription-only tracks, video rows) — while the nightly's incremental append
// (scripts/am-incremental-sync.mjs) preserves those rows and the folded share-links, but never
// acquires any field its own indexer doesn't emit. Picking a side silently destroys the other's
// data; this unions them.
//
// RULES (each earned from measuring the two sides, not assumed):
//   songs     union by id. Shared rows take the ORIGIN row as base (it carries the folded
//             spotify/youtube/appleMusicUrl + lyrics columns) and overlay every DEFINED local
//             field, because a fresh re-index is strictly fresher on name/year/length/artist/
//             albumId/pointer and is the only source of `dateAdded`. `explicit` is a logical OR
//             (the AppleScript delta path can't capture it, so origin false-negatives); `pointer`
//             is field-merged so neither side's `fileLocation` is lost.
//   albums    union by id. Shared rows take the LOCAL row as base (fresher genre/year) and
//             back-fill EVERY field local lacks — not a hard-coded list, or origin-only values
//             (album appleMusicId/appleMusicUrl, a pointer, a year) vanish silently.
//   trackList REBUILT from the merged song set for every album, so orphans, dangling refs and
//             unreachable songs are structurally impossible rather than merely asserted.
//   playlists union by id; membership is a per-id MULTIPLICITY union (max of the two counts).
//             An Apple Music playlist may legitimately list a song twice, and any shrink is read
//             downstream as a user removal.
//   manifest  counts regenerated (origin's albumsUnmatched is stale and self-contradictory).
//
// `librarySource: "subscription"` is stamped on every row present only in the local re-index.
// Those are exactly the rows Music.app's XML omits from its master playlist, so without the
// stamp the next nightly's diff reads all of them as REMOVALS, trips the mass-removal guard
// (scripts/am-incremental-sync.mjs) and hard-fails — blocking the S3/OpenSearch ship every
// night. am-incremental-sync exempts stamped rows from removal for that reason.
import { readFileSync, writeFileSync } from 'node:fs';

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const L = JSON.parse(readFileSync(arg('--local'), 'utf8'));
const O = JSON.parse(readFileSync(arg('--origin'), 'utf8'));
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const log = (...a) => console.error(...a);

// ---------- 1. songs ----------
const oById = new Map(O.songs.map((s) => [s.id, s]));
const lById = new Map(L.songs.map((s) => [s.id, s]));

// A local-only row whose (artist|name|length) matches an origin row is id-churn, not a new track;
// collapsing it keeps playlist membership from splitting across two ids. Guarded on the origin
// twin being absent locally — when local holds BOTH ids they are distinct Music.app entries (a
// library copy and a subscription-playlist copy) and must NOT be collapsed.
const oByKey = new Map();
for (const s of O.songs) { const k = norm(s.artist) + '|' + norm(s.name); (oByKey.get(k) || oByKey.set(k, []).get(k)).push(s); }
const remap = new Map();
for (const s of L.songs) {
  if (oById.has(s.id)) continue;
  const cands = oByKey.get(norm(s.artist) + '|' + norm(s.name));
  if (!cands || !cands.length) continue;
  const exact = cands.find((c) => c.length != null && s.length != null && Math.abs(c.length - s.length) <= 2)
    || (cands.length === 1 ? cands[0] : null);
  if (exact && !lById.has(exact.id)) remap.set(s.id, exact.id);
}
log(`dupe collapse: ${remap.size} local-only song ids remapped onto origin ids`);
const rid = (id) => remap.get(id) || id;

const mergeSong = (o, l) => {
  if (!o) return { ...l };
  if (!l) return { ...o };
  const m = { ...o };
  for (const [k, v] of Object.entries(l)) {
    if (v === undefined || v === null) continue;
    if (k === 'explicit' || k === 'pointer') continue;
    m[k] = v;
  }
  m.explicit = Boolean(l.explicit || o.explicit);
  if (l.pointer || o.pointer) {
    const p = { ...(o.pointer || {}), ...(l.pointer || {}) };
    if (!p.fileLocation && o.pointer?.fileLocation) p.fileLocation = o.pointer.fileLocation;
    m.pointer = p;
  }
  if (!m.explicit) delete m.explicit;
  return m;
};

const songs = []; const seen = new Set();
for (const o of O.songs) { const l = lById.get(o.id); songs.push(mergeSong(o, l)); seen.add(o.id); }
let stampedSongs = 0;
for (const l of L.songs) {
  if (seen.has(l.id)) continue;
  if (remap.has(l.id)) {                       // fold onto the origin twin already emitted
    const tid = remap.get(l.id); const i = songs.findIndex((s) => s.id === tid);
    if (i >= 0) songs[i] = mergeSong(songs[i], { ...l, id: tid });
    continue;
  }
  songs.push({ ...l, librarySource: 'subscription' }); seen.add(l.id); stampedSongs++;
}
const songIds = new Set(songs.map((s) => s.id));

// ---------- 2. albums ----------
const oAlb = new Map(O.albums.map((a) => [a.id, a]));
const albums = []; const albSeen = new Set();
// Back-fill EVERY field the base lacks. A hard-coded field list drops whatever isn't on it.
const emitAlbum = (base, other) => {
  const a = { ...base };
  if (other) for (const [k, v] of Object.entries(other)) if (a[k] == null && v != null) a[k] = v;
  return a;
};
for (const l of L.albums) { albums.push(emitAlbum(l, oAlb.get(l.id))); albSeen.add(l.id); }
for (const o of O.albums) { if (!albSeen.has(o.id)) { albums.push({ ...o }); albSeen.add(o.id); } }

// Rebuild every trackList from the merged song set → integrity by construction.
const byAlbum = new Map();
for (const s of songs) { if (!s.albumId) continue; (byAlbum.get(s.albumId) || byAlbum.set(s.albumId, []).get(s.albumId)).push(s); }
const sortTracks = (ss) => ss.slice()
  .sort((x, y) => ((x.pointer?.disc || 1) - (y.pointer?.disc || 1)) || ((x.pointer?.track || 0) - (y.pointer?.track || 0)))
  .map((s) => s.id);
for (const a of albums) a.trackList = sortTracks(byAlbum.get(a.id) || []);
const kept = albums.filter((a) => a.trackList.length > 0);
log(`albums: ${albums.length} unioned, ${albums.length - kept.length} empty dropped -> ${kept.length}`);

// ---------- 3. playlists ----------
const oPl = new Map(O.playlists.map((p) => [p.id, p]));
const playlists = []; const plSeen = new Set();
const unionIds = (a, b) => {
  const countOf = (arr) => { const m = new Map(); for (const id of arr || []) { const r = rid(id); if (!songIds.has(r)) continue; m.set(r, (m.get(r) || 0) + 1); } return m; };
  const ca = countOf(a), cb = countOf(b), have = new Map(), out = [];
  for (const id of (a || [])) { const r = rid(id); if (!songIds.has(r)) continue; out.push(r); have.set(r, (have.get(r) || 0) + 1); }
  for (const id of (b || [])) {
    const r = rid(id); if (!songIds.has(r)) continue;
    const n = have.get(r) || 0, want = Math.max(ca.get(r) || 0, cb.get(r) || 0);
    if (n < want) { out.push(r); have.set(r, n + 1); }
  }
  return out;
};
let stampedPlaylists = 0;
for (const l of L.playlists) {
  const o = oPl.get(l.id);
  const p = { ...(o || {}), ...l, songIds: unionIds(l.songIds, o?.songIds) };
  if (!o) { p.librarySource = 'subscription'; stampedPlaylists++; }
  playlists.push(p); plSeen.add(l.id);
}
for (const o of O.playlists) { if (!plSeen.has(o.id)) { playlists.push({ ...o, songIds: unionIds(o.songIds, []) }); plSeen.add(o.id); } }

// ---------- 4. manifest ----------
const manifest = { ...(O.manifest || {}), ...(L.manifest || {}) };
manifest.schemaVersion = manifest.schemaVersion || '1.0.0';
manifest.generatedAt = new Date().toISOString();
manifest.counts = {
  ...(manifest.counts || {}),
  albums: kept.length, songs: songs.length,
  songsWithAppleMusicId: songs.filter((s) => s.appleMusicId).length,
};
delete manifest.counts.albumsUnmatched; delete manifest.counts.albumsMatched;
manifest.playlistsCount = playlists.length;

writeFileSync(arg('--out'), JSON.stringify({ manifest, albums: kept, songs, playlists }));
log(`✓ wrote ${arg('--out')}: ${songs.length} songs / ${kept.length} albums / ${playlists.length} playlists`);
log(`  librarySource="subscription" stamped: ${stampedSongs} songs, ${stampedPlaylists} playlists`);
