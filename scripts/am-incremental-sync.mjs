#!/usr/bin/env node
// Incremental Apple Music catalog sync — append only what changed, never re-export the whole
// ~93k-track library. The full headless dump takes ~6h over AppleScript; this takes seconds
// because the committed public/apple-music-index.json ALREADY holds every existing track at full
// fidelity, so the only new information each run is the handful of tracks you just added/removed.
//
// Flow:
//   1. Bulk-fetch every current track's persistent ID (~0.6s — one AppleScript event).
//   2. Diff against the committed index by song id: new pids (to add) + removed song ids (gone).
//   3. Position-indexed enriched fetch of ONLY the new tracks (~seconds) → small Library.xml.
//   4. index-apple-music on that small XML → new songs + albums (ids match: same source-name/ns).
//   5. Re-dump playlists (fast) and remap membership to song ids via the shared hash (no need to
//      re-read all 92k tracks — song id = sha1(ns|persistentID)).
//   6. Merge into the committed index: drop removed songs, add new songs/albums, rebuild only the
//      touched albums' track order, replace playlists. EXISTING songs are preserved verbatim — so
//      their appleMusicId / explicit / length / etc. survive with no rebuild and no re-merge.
//
// Trade-off vs a full rebuild: this catches additions + removals, but not in-place metadata EDITS
// to existing tracks (rare). Those need an occasional full reconcile (cheap from a native
// Library.xml; the slow dump otherwise).
//
// Usage:
//   node scripts/am-incremental-sync.mjs --index public/apple-music-index.json --out merged.json
//     [--source-name "Apple Music (Local)"] [--timeout 1800] [--repo .] [--dry-run]

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { nsFor, songIdFor } from './lib/am-ids.mjs';
import { buildTrackScript, buildPlaylistScript, runOsascript, parsePlaylistRows, writeLibraryXml, nonMusicFlag } from './lib/am-music.mjs';
import {
  diffLibrary, partitionTrackRows, mergePlaylists,
  recordStrike, effectiveIgnoredPids, removalGuardTripped, playlistDumpLooksBroken, CONFIRM_STRIKES,
  reconcileRemovals, deferPlaylistRemovals, REMOVAL_CONFIRM_STRIKES,
} from './lib/am-sync-merge.mjs';
import { placeholderCandidates, mergeRefreshed, fillCatalogIds } from './lib/am-placeholder-refresh.mjs';

function arg(name, def) { const i = process.argv.indexOf('--' + name); return i >= 0 ? process.argv[i + 1] : def; }
const INDEX = arg('index', 'public/apple-music-index.json');
const OUT = arg('out');
const SOURCE = arg('source-name', 'Apple Music (Local)');
const TIMEOUT = parseInt(arg('timeout', '1800'), 10) * 1000;
const REPO = arg('repo', path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
const STATE_DIR = arg('state-dir', path.join(os.homedir(), '.pocketdj', 'am-sync'));
const DRY = process.argv.includes('--dry-run');
const LOOKUP_BASE = process.env.POCKETDJ_ITUNES_LOOKUP_BASE || 'https://itunes.apple.com/lookup';
const LINKS_CACHE = (process.env.POCKETDJ_LINKS_CACHE || path.join(os.homedir(), '.pocketdj', 'streaming-links', 'links-cache.ndjson'));
if (!OUT && !DRY) { console.error('usage: --index <committed.json> --out <merged.json> [--source-name N] [--timeout S] [--state-dir D] [--dry-run]'); process.exit(1); }

// Persistent ignore list for metadata-less "ghost" library entries (orphaned iCloud
// uploads whose every field reads back empty). They can never be indexed, so without
// this they re-diff as "new" every night forever. Delete the file to re-probe them.
const IGNORE_FILE = path.join(STATE_DIR, 'ignored-pids.json');
function loadIgnoredPids() {
  try { return JSON.parse(fs.readFileSync(IGNORE_FILE, 'utf8')).pids || {}; } catch { return {}; }
}
function saveIgnoredPids(pids) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(IGNORE_FILE, JSON.stringify({ version: 1, pids }, null, 2));
}

// Pending-removal strike file: a removal only ships after REMOVAL_STRIKES sightings on
// distinct days (reappearance resets). POCKETDJ_REMOVAL_STRIKES=1 restores ship-same-run.
const PENDING_FILE = path.join(STATE_DIR, 'pending-removals.json');
const REMOVAL_STRIKES = Math.max(1, parseInt(process.env.POCKETDJ_REMOVAL_STRIKES || '', 10) || REMOVAL_CONFIRM_STRIKES);
function loadPendingRemovals() {
  try {
    const p = JSON.parse(fs.readFileSync(PENDING_FILE, 'utf8'));
    return { songs: p.songs || {}, playlists: p.playlists || {}, memberships: p.memberships || {} };
  } catch { return { songs: {}, playlists: {}, memberships: {} }; }
}
function savePendingRemovals(p) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(PENDING_FILE, JSON.stringify({ version: 1, ...p }, null, 2));
}

// A retitled song's streaming-link cache entries were resolved against the OLD title (and a
// cached miss is never retried), so drop them; the streaming-links nightly re-resolves them.
// Skipped while that job holds its lock — the next night's refresh can't lose the retitle, but
// the eviction would be lost, so it is logged loudly.
function evictStreamingLinks(ids) {
  if (!fs.existsSync(LINKS_CACHE)) return;
  if (fs.existsSync(path.join(path.dirname(LINKS_CACHE), '.sync.lock'))) {
    log(`  ⚠ streaming-links cache locked — NOT evicting ${ids.size} retitled song(s): ${[...ids].join(',')}`);
    return;
  }
  const lines = fs.readFileSync(LINKS_CACHE, 'utf8').split('\n');
  const kept = lines.filter((l) => { try { return !ids.has(JSON.parse(l).id); } catch { return true; } });
  if (kept.length === lines.length) return;
  const tmp = LINKS_CACHE + '.tmp';
  fs.writeFileSync(tmp, kept.join('\n'));
  fs.renameSync(tmp, LINKS_CACHE);
  log(`  evicted ${lines.length - kept.length} streaming-link cache entr(y/ies) for retitled songs`);
}

const ns = nsFor(SOURCE);
const tmpdir = fs.mkdtempSync(path.join(process.env.TMPDIR || '/tmp', 'am-inc-'));
const cleanup = () => { try { fs.rmSync(tmpdir, { recursive: true, force: true }); } catch { /* ignore */ } };
const log = (m) => console.error(m);

// 1. all current persistent IDs (in library order)
log('▶ fetching current persistent IDs…');
const pidRes = runOsascript('tell application "Music" to get persistent ID of every track of library playlist 1', TIMEOUT);
if (!pidRes.ok) { console.error('✗ pid fetch failed: ' + pidRes.err); cleanup(); process.exit(2); }
const allPids = pidRes.out.split(',').map((s) => s.trim()).filter(Boolean);
log(`  ${allPids.length} tracks in library`);

// 2. diff against the committed index by song id (known ghosts excluded, not "new")
const idx = JSON.parse(fs.readFileSync(INDEX, 'utf8'));
const oldSongs = idx.songs || [];
const oldById = new Map(oldSongs.map((s) => [s.id, s]));
const existing = new Set(oldById.keys());
const ignoredPids = loadIgnoredPids();
const { newPositions, newPids, removed, ignoredSeen } =
  diffLibrary({ allPids, existingIds: existing, ns, ignoredPids: effectiveIgnoredPids(ignoredPids) });

// SUBSCRIPTION ROWS ARE NOT REMOVALS. Music.app's `every track of library playlist 1` snapshot
// omits subscription-only tracks (catalog rows saved to a playlist but never added to the
// library), so a plain diff reads every one of them as deleted. They are stamped
// `librarySource:"subscription"` by scripts/union-am-index.mjs; without this filter their count
// alone trips the mass-removal guard below and the sync exits 2 EVERY night — which also skips
// the S3 + OpenSearch ship, so devices silently stay on a stale catalog forever.
//
// Filter `removed`, NOT `existingIds`: a subscription id missing from `existingIds` would be
// re-detected as NEW, and `finalSongs = oldSongs.filter(...).concat(partial.songs)` would then
// emit that id TWICE.
const exemptIds = new Set(oldSongs.filter((s) => s.librarySource === 'subscription').map((s) => s.id));
let exemptSkipped = 0;
for (const id of exemptIds) if (removed.delete(id)) exemptSkipped++;

log(`  new tracks: ${newPositions.length} | removed: ${removed.size}` +
  (exemptSkipped ? ` | subscription-exempt: ${exemptSkipped}` : '') +
  (ignoredSeen ? ` | ignored (ghost/non-music): ${ignoredSeen}` : ''));

// Circuit breaker: an empty/truncated `every track` snapshot that exits 0 must never
// ship as a mass deletion — removed songs lose appleMusicId/explicit enrichment forever.
if (allPids.length === 0 && oldSongs.length > 0) {
  console.error('✗ empty library snapshot with a populated index — refusing to treat as mass removal');
  cleanup(); process.exit(2);
}
if (removalGuardTripped(removed.size, oldSongs.length) && process.env.POCKETDJ_ALLOW_MASS_REMOVAL !== '1') {
  console.error(`✗ implausible removal count (${removed.size} of ${oldSongs.length}) — refusing to ship unattended. ` +
    'Set POCKETDJ_ALLOW_MASS_REMOVAL=1 if this purge is intentional.');
  cleanup(); process.exit(2);
}

if (DRY) {
  log(`(dry-run) would add up to ${newPositions.length} new tracks; ${removed.size} removal candidate(s), ` +
    `each ships only after ${REMOVAL_STRIKES} distinct-day sightings (${PENDING_FILE}).`);
  cleanup();
  process.exit(0);
}

// Removal confirmation: strike today's missing songs, ship only the confirmed ones.
// (Breakers above still abort on implausible snapshots BEFORE any strikes are recorded.)
const pendingRemovals = loadPendingRemovals();
const nowIsoRun = new Date().toISOString();
const { confirmed: confirmedRemoved, deferred: deferredRemoved } =
  reconcileRemovals({ pending: pendingRemovals.songs, missing: [...removed], nowIso: nowIsoRun, confirmStrikes: REMOVAL_STRIKES });
if (removed.size) {
  log(`  removals: ${confirmedRemoved.size} confirmed (${REMOVAL_STRIKES} distinct days), ` +
    `${deferredRemoved.size} pending (${PENDING_FILE})`);
}

// 3 + 4. enriched-fetch only the new tracks → small Library.xml → index-apple-music
let partial = { songs: [], albums: [] };
if (newPositions.length) {
  log('▶ enriched-fetching new tracks…');
  const raw = path.join(tmpdir, 'new.tsv');
  const tr = runOsascript(buildTrackScript({ rawPath: raw, timeoutSec: Math.floor(TIMEOUT / 1000), positions: newPositions }), TIMEOUT + 30000);
  if (!tr.ok) { console.error('✗ enriched fetch failed: ' + tr.err); cleanup(); process.exit(2); }
  const { rows, ghostPids, skewPids } = partitionTrackRows(fs.readFileSync(raw, 'utf8'), newPids);
  log(`  fetched ${rows.length} enriched rows`);
  if (skewPids.length) log(`  ⚠ ${skewPids.length} rows landed on unrequested tracks (library changed mid-run) — dropped, retried next run`);
  if (ghostPids.length) {
    // A systemic blank-read night (Music quitting, TCC denial) is harmless here: these
    // are strikes, not ignores — a pid only stops re-fetching after CONFIRM_STRIKES
    // sightings on distinct days, so real tracks self-heal the next night.
    const now = new Date().toISOString();
    for (const pid of ghostPids) recordStrike(ignoredPids, pid, 'no-metadata', now);
    saveIgnoredPids(ignoredPids);
    const confirmed = ghostPids.filter((p) => (ignoredPids[p].strikes ?? 1) >= CONFIRM_STRIKES).length;
    log(`  ⚠ ${ghostPids.length} metadata-less tracks struck (${confirmed} now confirmed ghosts, ` +
      `${ghostPids.length - confirmed} will retry — ${CONFIRM_STRIKES} strikes on distinct days confirm; ${IGNORE_FILE})`);
  }
  const smallXml = path.join(tmpdir, 'new.xml');
  writeLibraryXml({ rows, playlists: [], runStart: Date.now(), out: smallXml });
  const partialOut = path.join(tmpdir, 'partial.json');
  const ir = spawnSync('node', ['--max-old-space-size=4096', path.join(REPO, 'scripts/index-apple-music.mjs'),
    '--xml', smallXml, '--out', partialOut, '--source-name', SOURCE], { encoding: 'utf8' });
  if (ir.status !== 0) { console.error('✗ index-apple-music failed: ' + (ir.stderr || '')); cleanup(); process.exit(2); }
  partial = JSON.parse(fs.readFileSync(partialOut, 'utf8'));
  // In-run + cross-run dedup: a skew-shifted or double-listed row must never append a
  // song id that already exists (or append the same id twice).
  const dedupSeen = new Set(existing);
  partial.songs = (partial.songs || []).filter((s) => !dedupSeen.has(s.id) && dedupSeen.add(s.id));
  log(`  indexed new: ${partial.songs.length} songs, ${(partial.albums || []).length} albums` +
    ((partial.songs.length < rows.length) ? ` (${rows.length - partial.songs.length} non-music/video/no-name skipped by indexer)` : ''));
  // Keep indexer-skipped rows from re-diffing as "new" every night forever — but only
  // POSITIVE evidence (the row READ a video/podcast media kind) may ignore immediately;
  // a titleless row can be a transient read failure, so it gets strikes like a ghost.
  // Any pid that indexes successfully is rescued from the list.
  const indexedIds = new Set(partial.songs.map((s) => s.id));
  const now2 = new Date().toISOString();
  let nonMusic = 0, noName = 0, rescued = 0;
  for (const r of rows) {
    if (indexedIds.has(songIdFor(ns, r.persistentID))) {
      if (ignoredPids[r.persistentID]) { delete ignoredPids[r.persistentID]; rescued++; }
    } else if (nonMusicFlag(r)) {
      ignoredPids[r.persistentID] = ignoredPids[r.persistentID] || { firstSeen: now2, lastSeen: now2, reason: 'non-music' };
      nonMusic++;
    } else {
      recordStrike(ignoredPids, r.persistentID, 'no-name', now2);
      noName++;
    }
  }
  if (nonMusic || noName || rescued) {
    saveIgnoredPids(ignoredPids);
    log(`  ignore list: +${nonMusic} non-music, ${noName} no-name strikes, ${rescued} rescued (${IGNORE_FILE})`);
  }
}

// 4b. pre-release placeholder refresh. Music.app retitles a pre-release album's "Track N" rows IN
// PLACE on release day (same persistent IDs, no modification-date bump), so the new-pid diff above
// never sees it. Re-read every song on a still-placeholder album and merge the fresh metadata.
let refresh = { updated: new Map(), renamed: new Set(), touchedAlbums: new Set() };
let refreshAlbums = [];
let catalogIdsFilled = 0;
const refreshIds = placeholderCandidates(oldSongs.filter((s) => !confirmedRemoved.has(s.id)), idx.albums);
if (refreshIds.size) {
  const positions = [], pids = [];
  allPids.forEach((pid, i) => { if (refreshIds.has(songIdFor(ns, pid))) { positions.push(i + 1); pids.push(pid); } });
  log(`▶ re-reading ${positions.length} song(s) on ${new Set([...refreshIds].map((id) => oldById.get(id)?.albumId)).size} placeholder album(s)…`);
  if (positions.length) {
    const raw = path.join(tmpdir, 'refresh.tsv');
    const tr = runOsascript(buildTrackScript({ rawPath: raw, timeoutSec: Math.floor(TIMEOUT / 1000), positions }), TIMEOUT + 30000);
    if (!tr.ok) log('  ⚠ placeholder re-read failed — keeping committed rows: ' + tr.err);
    else {
      const { rows } = partitionTrackRows(fs.readFileSync(raw, 'utf8'), pids);
      const xml = path.join(tmpdir, 'refresh.xml');
      writeLibraryXml({ rows, playlists: [], runStart: Date.now(), out: xml });
      const out = path.join(tmpdir, 'refresh.json');
      const ir = spawnSync('node', ['--max-old-space-size=4096', path.join(REPO, 'scripts/index-apple-music.mjs'),
        '--xml', xml, '--out', out, '--source-name', SOURCE], { encoding: 'utf8' });
      if (ir.status !== 0) log('  ⚠ placeholder re-index failed — keeping committed rows: ' + (ir.stderr || ''));
      else {
        const fresh = JSON.parse(fs.readFileSync(out, 'utf8'));
        refresh = mergeRefreshed({ oldById, refreshedSongs: fresh.songs });
        refreshAlbums = fresh.albums || [];
      }
    }
  }
  // Catalog ids for refreshed rows: one unfiltered iTunes LOOKUP per album (search filters
  // explicit tracks; lookup doesn't). Non-fatal — a miss just leaves the id for next night.
  const oldAlbumById = new Map((idx.albums || []).map((a) => [a.id, a]));
  const byAlbum = new Map();
  for (const s of refresh.updated.values()) {
    const amId = oldAlbumById.get(s.albumId)?.appleMusicId || oldAlbumById.get(oldById.get(s.id)?.albumId)?.appleMusicId;
    if (!amId || s.appleMusicId) continue;
    (byAlbum.get(amId) || byAlbum.set(amId, []).get(amId)).push(s);
  }
  for (const [amId, songs] of byAlbum) {
    try {
      const res = await fetch(`${LOOKUP_BASE}?id=${encodeURIComponent(amId)}&entity=song&limit=200`, { signal: AbortSignal.timeout(15000) });
      const tracks = ((await res.json()).results || []).filter((r) => r.wrapperType === 'track');
      const { songs: filled, filled: n } = fillCatalogIds(songs, tracks);
      for (const s of filled) refresh.updated.set(s.id, s);
      catalogIdsFilled += n;
    } catch (e) { log(`  ⚠ iTunes lookup for album ${amId} failed (${e.message}) — retry next night`); }
  }
  log(`  refreshed ${refresh.updated.size} song(s) (${refresh.renamed.size} retitled, ${catalogIdsFilled} catalog id(s) filled)`);
  if (refresh.renamed.size) evictStreamingLinks(refresh.renamed);
}

// 5. playlists — always re-dump + remap to song ids (membership changes carry no date)
log('▶ dumping playlists…');
const plRaw = path.join(tmpdir, 'pl.tsv');
const pr = runOsascript(buildPlaylistScript({ rawPath: plRaw, timeoutSec: Math.floor(TIMEOUT / 1000) }), TIMEOUT + 30000);
let playlistRows = null;
if (pr.ok && fs.existsSync(plRaw)) playlistRows = parsePlaylistRows(fs.readFileSync(plRaw, 'utf8'));
else log('  ⚠ playlist dump failed — keeping existing playlists (minus removed songs)');
// The dump script creates its file BEFORE writing rows, so a hard mid-dump failure can
// parse as "zero playlists" — which the merge would ship as "every playlist deleted".
if (playlistRows && playlistDumpLooksBroken(playlistRows.length, (idx.playlists || []).length) &&
    process.env.POCKETDJ_ALLOW_PLAYLIST_SHRINK !== '1') {
  log(`  ⚠ playlist dump implausibly small (${playlistRows.length} vs ${(idx.playlists || []).length} committed) — ` +
    'treating as read failure (set POCKETDJ_ALLOW_PLAYLIST_SHRINK=1 if this mass deletion is intentional)');
  playlistRows = null;
}

// 6. merge
// 6a. songs: drop CONFIRMED removed (deferred ones stay until confirmed), append new
const finalSongs = oldSongs.filter((s) => !confirmedRemoved.has(s.id))
  .map((s) => refresh.updated.get(s.id) || s)
  .concat(partial.songs || []);
const finalSongIds = new Set(finalSongs.map((s) => s.id));

// 6b. albums: keep untouched verbatim; rebuild touched (gained/lost a song) from final songs
const touched = new Set();
for (const s of (partial.songs || [])) touched.add(s.albumId);
for (const sid of confirmedRemoved) { const s = oldById.get(sid); if (s) touched.add(s.albumId); }
for (const aid of refresh.touchedAlbums) touched.add(aid);
const touchedSongs = new Map(); // albumId -> [song]
for (const s of finalSongs) {
  if (!touched.has(s.albumId)) continue;
  (touchedSongs.get(s.albumId) || touchedSongs.set(s.albumId, []).get(s.albumId)).push(s);
}
const sortTracks = (songs) => songs
  .sort((x, y) => ((x.pointer?.disc || 1) - (y.pointer?.disc || 1)) || ((x.pointer?.track || 0) - (y.pointer?.track || 0)))
  .map((s) => s.id);
const finalAlbums = [];
for (const a of (idx.albums || [])) {
  if (!touched.has(a.id)) { finalAlbums.push(a); continue; } // untouched — byte-identical
  const songs = touchedSongs.get(a.id);
  if (!songs || !songs.length) continue;                     // emptied by removals — drop
  finalAlbums.push({ ...a, trackList: sortTracks(songs) });
}
const oldAlbumIds = new Set((idx.albums || []).map((a) => a.id));
// A retitled placeholder ALBUM gets a new id (album ids hash the name); it inherits the old
// album's catalog id, which already identified the real release.
const movedFrom = new Map();
for (const s of refresh.updated.values()) {
  const was = oldById.get(s.id)?.albumId;
  if (was && was !== s.albumId) movedFrom.set(s.albumId, was);
}
const oldAlbumsById = new Map((idx.albums || []).map((a) => [a.id, a]));
const refreshNewAlbums = refreshAlbums.filter((a) => movedFrom.has(a.id)).map((a) => {
  const old = oldAlbumsById.get(movedFrom.get(a.id));
  return old && old.appleMusicId && !a.appleMusicId ? { ...a, appleMusicId: old.appleMusicId, appleMusicUrl: old.appleMusicUrl } : a;
});
const seenNewAlbum = new Set();
for (const a of [...(partial.albums || []), ...refreshNewAlbums]) {   // brand-new albums
  if (oldAlbumIds.has(a.id) || seenNewAlbum.has(a.id)) continue;
  seenNewAlbum.add(a.id);
  const songs = touchedSongs.get(a.id);
  finalAlbums.push(songs && songs.length ? { ...a, trackList: sortTracks(songs) } : a);
}

// 6c. playlists: rebuild from the fresh dump (membership remapped via hash), else prune existing.
// Presence in the dump governs existence — an empty playlist ships EMPTY, it is not a
// deletion. (The old zero-members-means-drop rule shipped the deletion of "OTG" on
// 2026-06-30 while its contents were mid-swap in Music.)
// Removal confirmation applies here too: a playlist deletion or a member removal only
// ships after REMOVAL_STRIKES distinct-day sightings; until then the committed shape is
// retained. A failed/broken dump leaves pending playlist strikes untouched entirely.
let finalPlaylists;
if (playlistRows) {
  const mergedPl = mergePlaylists({ playlistRows, oldPlaylists: idx.playlists, finalSongIds, ns, log });
  finalPlaylists = deferPlaylistRemovals({
    merged: mergedPl, oldPlaylists: idx.playlists, pending: pendingRemovals,
    finalSongIds, nowIso: nowIsoRun, confirmStrikes: REMOVAL_STRIKES, log,
  });
} else {
  finalPlaylists = (idx.playlists || [])
    .map((p) => ({ ...p, songIds: (p.songIds || []).filter((sid) => finalSongIds.has(sid)) }));
}
savePendingRemovals(pendingRemovals);

// 6d. assemble (preserve key order: manifest, albums, playlists, songs) + refresh counts
const out = { ...idx, albums: finalAlbums, playlists: finalPlaylists, songs: finalSongs };
// "changed" gates the generatedAt bump so a genuine no-op run produces a BYTE-IDENTICAL file —
// the nightly job's `cmp` then skips the commit/deploy entirely. (A pure playlist reorder still
// ships: the playlists array itself differs, which cmp catches regardless of generatedAt.)
const addedSongs = (partial.songs || []).length;
const changed = addedSongs > 0 || confirmedRemoved.size > 0 || refresh.updated.size > 0 ||
  JSON.stringify(finalPlaylists) !== JSON.stringify(idx.playlists || []);
if (out.manifest) {
  out.manifest.counts = {
    ...(out.manifest.counts || {}),
    albums: finalAlbums.length, songs: finalSongs.length,
    songsWithAppleMusicId: finalSongs.filter((s) => s.appleMusicId).length,
  };
  out.manifest.playlistsCount = finalPlaylists.length;
  if (changed) out.manifest.generatedAt = new Date().toISOString();
}
fs.writeFileSync(OUT, JSON.stringify(out));
cleanup();

console.error(`✓ am-incremental-sync → ${OUT}${changed ? '' : ' (no change)'}`);
console.error(`  songs ${oldSongs.length} → ${finalSongs.length} (+${addedSongs} added, -${confirmedRemoved.size} removed` +
  (deferredRemoved.size ? `, ${deferredRemoved.size} removal(s) pending confirmation` : '') + ')');
if (refresh.updated.size) console.error(`  placeholder refresh: ${refresh.updated.size} song(s) updated, ${refresh.renamed.size} retitled, ${catalogIdsFilled} catalog id(s) filled`);
console.error(`  albums ${(idx.albums || []).length} → ${finalAlbums.length} | playlists ${(idx.playlists || []).length} → ${finalPlaylists.length}`);
console.error(`  explicit ${finalSongs.filter((s) => s.explicit).length} | appleMusicId ${finalSongs.filter((s) => s.appleMusicId).length} (existing tracks keep theirs)`);
