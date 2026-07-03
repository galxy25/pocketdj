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
 * Ignore-list strike accounting. Emptiness-derived classifications (no-metadata ghosts,
 * titleless rows) can be TRANSIENT AppleScript read failures, so a pid only becomes
 * effectively ignored after CONFIRM_STRIKES sightings on distinct days — below that it
 * keeps re-fetching nightly and self-heals. Positive-evidence reasons ('non-music': the
 * row READ a video/podcast media kind) are deterministic and effective immediately.
 */
export const CONFIRM_STRIKES = 3;

export function recordStrike(ignoredPids, pid, reason, nowIso) {
  const e = ignoredPids[pid];
  if (!e) { ignoredPids[pid] = { firstSeen: nowIso, lastSeen: nowIso, strikes: 1, reason }; return; }
  if ((e.lastSeen || '').slice(0, 10) !== nowIso.slice(0, 10)) e.strikes = (e.strikes ?? 1) + 1;
  e.lastSeen = nowIso;
}

export function effectiveIgnoredPids(ignoredPids, confirmStrikes = CONFIRM_STRIKES) {
  return new Set(Object.entries(ignoredPids)
    .filter(([, e]) => e.reason === 'non-music' || (e.strikes ?? 1) >= confirmStrikes)
    .map(([pid]) => pid));
}

/**
 * Mass-removal circuit breaker: a single bad `every track` snapshot (empty or truncated,
 * exit 0) must not be shipped unattended as thousands of deletions — removed songs lose
 * their appleMusicId/explicit enrichment forever even if re-added later. Anything beyond
 * max(50, 0.5%) is implausible for one night and needs an explicit override.
 */
export function removalGuardTripped(removedCount, oldCount) {
  return removedCount > Math.max(50, Math.ceil(oldCount * 0.005));
}

/**
 * Playlist-dump circuit breaker: the dump AppleScript creates its output file BEFORE
 * writing any rows, so a hard failure can parse as "zero playlists" — which the merge
 * would faithfully ship as "every playlist deleted". An empty or >50%-shrunk dump when
 * the committed index has a real playlist population is treated as a read failure.
 */
export function playlistDumpLooksBroken(dumpCount, oldCount) {
  if (oldCount === 0) return false;
  if (dumpCount === 0) return true;
  return oldCount >= 8 && dumpCount < oldCount * 0.5;
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
  const oldByName = new Map((oldPlaylists || []).map((p) => [p.name, p]));
  const out = [];
  const seen = new Set();
  let unidentifiedRows = 0;
  for (const pl of playlistRows) {
    // A blank ppid is usually a transient `persistent ID of p` read failure — minting a
    // name-hash id would ship the real playlist's deletion + a doppelgänger for one
    // night. Reuse the committed same-name playlist's id; a blank ppid AND blank name is
    // unattributable, so the row is skipped and committed playlists are retained below.
    if (!pl.ppid && !pl.name) { unidentifiedRows++; continue; }
    const id = pl.ppid ? playlistIdFor(ns, pl.ppid)
      : (oldByName.get(pl.name)?.id ?? playlistIdFor(ns, pl.name));
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
  if (unidentifiedRows) {
    for (const p of oldPlaylists || []) {
      if (seen.has(p.id)) continue;
      log(`  ⚠ ${unidentifiedRows} unidentifiable dump rows — retaining committed playlist "${p.name}"`);
      out.push({ ...p, songIds: (p.songIds || []).filter((sid) => finalSongIds.has(sid)) });
    }
  }
  return out;
}
