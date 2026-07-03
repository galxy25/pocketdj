// Pure diff/merge helpers for the incremental Apple Music sync (am-incremental-sync.mjs).
// Split out so the decisions that once shipped real data loss — most notably deleting the
// mid-edit "OTG" playlist on 2026-06-30 because its membership momentarily resolved to
// zero — are unit-testable without AppleScript or a 90MB index.

import { songIdFor, playlistIdFor } from './am-ids.mjs';
import { COLS, TSV_HEADER } from './am-music.mjs';

/**
 * Diff the live library's persistent IDs against the committed index.
 * `ignoredPids` are known metadata-less ghosts (see partitionTrackRows) — they exist in
 * the library but can never be indexed, so they are excluded from `newPositions` instead
 * of churning as "new" every night forever.
 * Returns { newPositions (1-based), newPids, currentSongIds, ignoredSeen }.
 */
export function diffLibrary({ allPids, existingIds, ns, ignoredPids = new Set() }) {
  const currentSongIds = new Set();
  const newPositions = [];
  const newPids = [];
  let ignoredSeen = 0;
  allPids.forEach((pid, i) => {
    const sid = songIdFor(ns, pid);
    currentSongIds.add(sid);
    if (existingIds.has(sid)) return;
    if (ignoredPids.has(pid)) { ignoredSeen++; return; }
    newPositions.push(i + 1); // 1-based for AppleScript
    newPids.push(pid);
  });
  const removed = new Set([...existingIds].filter((sid) => !currentSongIds.has(sid)));
  return { newPositions, newPids, currentSongIds, removed, ignoredSeen };
}

/**
 * Parse + partition the enriched-track TSV against the pids we asked for.
 *  - rows:      usable rows (have a title or artist AND are pids we requested)
 *  - ghostPids: requested pids that fetched with NO title and NO artist — orphaned
 *               library entries whose metadata reads come back empty ("shared track"
 *               ghosts). Callers persist these to the ignore list.
 *  - skewPids:  pids we did NOT request (the position-indexed fetch re-snapshots the
 *               library; if it changed in between, positions land on other tracks).
 *               Dropped — indexing them would duplicate already-indexed songs.
 */
export function partitionTrackRows(text, requestedPids) {
  const requested = new Set(requestedPids);
  const nz = (v) => (v === 'missing value' ? '' : (v || ''));
  const rows = [];
  const ghostPids = [];
  const skewPids = [];
  for (const ln of text.split('\n')) {
    if (!ln || ln === TSV_HEADER) continue;
    const c = ln.split('\t');
    const e = {};
    COLS.forEach((col, i) => { e[col] = nz(c[i]); });
    if (!e.persistentID) continue;
    if (!requested.has(e.persistentID)) { skewPids.push(e.persistentID); continue; }
    if (!e.title && !e.artist) { ghostPids.push(e.persistentID); continue; }
    rows.push(e);
  }
  return { rows, ghostPids, skewPids };
}

/**
 * Rebuild the index's playlists from a fresh Music.app dump.
 * Presence in the dump governs existence: a playlist that Music still has stays in the
 * index even when none of its members resolve (songIds: []) — an empty playlist is a
 * state, not a deletion. Only a playlist absent from the dump (deleted in Music) drops.
 * A readError row means membership is UNKNOWN, so the previous membership is kept
 * (pruned to songs that still exist) rather than shipping a spurious wipe.
 */
export function mergePlaylists({ playlistRows, oldPlaylists, finalSongIds, ns, log = () => {} }) {
  const oldById = new Map((oldPlaylists || []).map((p) => [p.id, p]));
  const out = [];
  const seen = new Set();
  for (const pl of playlistRows) {
    const id = playlistIdFor(ns, pl.ppid || pl.name);
    if (seen.has(id)) continue; // duplicate name w/o ppid — first wins, as before
    seen.add(id);
    if (pl.readError) {
      const prev = oldById.get(id);
      const kept = prev ? (prev.songIds || []).filter((sid) => finalSongIds.has(sid)) : [];
      log(`  ⚠ playlist "${pl.name}" track read failed — keeping previous membership (${kept.length} songs)`);
      out.push({ id, name: pl.name, songIds: kept });
      continue;
    }
    const songIds = pl.pids.map((pid) => songIdFor(ns, pid)).filter((sid) => finalSongIds.has(sid));
    out.push({ id, name: pl.name, songIds });
  }
  return out;
}
