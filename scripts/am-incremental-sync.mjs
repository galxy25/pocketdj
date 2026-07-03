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
import { buildTrackScript, buildPlaylistScript, runOsascript, parsePlaylistRows, writeLibraryXml } from './lib/am-music.mjs';
import { diffLibrary, partitionTrackRows, mergePlaylists } from './lib/am-sync-merge.mjs';

function arg(name, def) { const i = process.argv.indexOf('--' + name); return i >= 0 ? process.argv[i + 1] : def; }
const INDEX = arg('index', 'public/apple-music-index.json');
const OUT = arg('out');
const SOURCE = arg('source-name', 'Apple Music (Local)');
const TIMEOUT = parseInt(arg('timeout', '1800'), 10) * 1000;
const REPO = arg('repo', path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
const STATE_DIR = arg('state-dir', path.join(os.homedir(), '.pocketdj', 'am-sync'));
const DRY = process.argv.includes('--dry-run');
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
  diffLibrary({ allPids, existingIds: existing, ns, ignoredPids: new Set(Object.keys(ignoredPids)) });
log(`  new tracks: ${newPositions.length} | removed: ${removed.size}` +
  (ignoredSeen ? ` | ignored (ghost/non-music): ${ignoredSeen}` : ''));

if (DRY) {
  log(`(dry-run) would add up to ${newPositions.length} new tracks and drop ${removed.size} removed.`);
  cleanup();
  process.exit(0);
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
    const now = new Date().toISOString();
    for (const pid of ghostPids) ignoredPids[pid] = ignoredPids[pid] || { firstSeen: now, reason: 'no-metadata' };
    saveIgnoredPids(ignoredPids);
    log(`  ⚠ ${ghostPids.length} metadata-less ghost tracks → ignore list (${IGNORE_FILE})`);
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
  // The indexer's skips are deterministic (music videos, podcasts, titleless rows) —
  // without ignoring them they'd re-diff as "new" every night forever, like the ghosts.
  const indexedIds = new Set(partial.songs.map((s) => s.id));
  const nonMusicPids = rows.map((r) => r.persistentID).filter((pid) => !indexedIds.has(songIdFor(ns, pid)));
  if (nonMusicPids.length) {
    const now = new Date().toISOString();
    for (const pid of nonMusicPids) ignoredPids[pid] = ignoredPids[pid] || { firstSeen: now, reason: 'non-music' };
    saveIgnoredPids(ignoredPids);
    log(`  ⚠ ${nonMusicPids.length} non-music tracks → ignore list (${IGNORE_FILE})`);
  }
}

// 5. playlists — always re-dump + remap to song ids (membership changes carry no date)
log('▶ dumping playlists…');
const plRaw = path.join(tmpdir, 'pl.tsv');
const pr = runOsascript(buildPlaylistScript({ rawPath: plRaw, timeoutSec: Math.floor(TIMEOUT / 1000) }), TIMEOUT + 30000);
let playlistRows = null;
if (pr.ok && fs.existsSync(plRaw)) playlistRows = parsePlaylistRows(fs.readFileSync(plRaw, 'utf8'));
else log('  ⚠ playlist dump failed — keeping existing playlists (minus removed songs)');

// 6. merge
// 6a. songs: drop removed, append new (existing songs preserved verbatim)
const finalSongs = oldSongs.filter((s) => !removed.has(s.id)).concat(partial.songs || []);
const finalSongIds = new Set(finalSongs.map((s) => s.id));

// 6b. albums: keep untouched verbatim; rebuild touched (gained/lost a song) from final songs
const touched = new Set();
for (const s of (partial.songs || [])) touched.add(s.albumId);
for (const sid of removed) { const s = oldById.get(sid); if (s) touched.add(s.albumId); }
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
for (const a of (partial.albums || [])) {                    // brand-new albums
  if (oldAlbumIds.has(a.id)) continue;
  const songs = touchedSongs.get(a.id);
  finalAlbums.push(songs && songs.length ? { ...a, trackList: sortTracks(songs) } : a);
}

// 6c. playlists: rebuild from the fresh dump (membership remapped via hash), else prune existing.
// Presence in the dump governs existence — an empty playlist ships EMPTY, it is not a
// deletion. (The old zero-members-means-drop rule shipped the deletion of "OTG" on
// 2026-06-30 while its contents were mid-swap in Music.)
let finalPlaylists;
if (playlistRows) {
  finalPlaylists = mergePlaylists({ playlistRows, oldPlaylists: idx.playlists, finalSongIds, ns, log });
} else {
  finalPlaylists = (idx.playlists || [])
    .map((p) => ({ ...p, songIds: (p.songIds || []).filter((sid) => finalSongIds.has(sid)) }));
}

// 6d. assemble (preserve key order: manifest, albums, playlists, songs) + refresh counts
const out = { ...idx, albums: finalAlbums, playlists: finalPlaylists, songs: finalSongs };
// "changed" gates the generatedAt bump so a genuine no-op run produces a BYTE-IDENTICAL file —
// the nightly job's `cmp` then skips the commit/deploy entirely. (A pure playlist reorder still
// ships: the playlists array itself differs, which cmp catches regardless of generatedAt.)
const addedSongs = (partial.songs || []).length;
const changed = addedSongs > 0 || removed.size > 0 ||
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
console.error(`  songs ${oldSongs.length} → ${finalSongs.length} (+${addedSongs} added, -${removed.size} removed)`);
console.error(`  albums ${(idx.albums || []).length} → ${finalAlbums.length} | playlists ${(idx.playlists || []).length} → ${finalPlaylists.length}`);
console.error(`  explicit ${finalSongs.filter((s) => s.explicit).length} | appleMusicId ${finalSongs.filter((s) => s.appleMusicId).length} (existing tracks keep theirs)`);
