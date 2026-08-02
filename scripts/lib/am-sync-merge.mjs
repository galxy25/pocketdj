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
 * Removal confirmation — a removal (library song gone, playlist gone from the dump,
 * song gone from a playlist's membership) only ships after being observed missing on
 * REMOVAL_CONFIRM_STRIKES distinct days. A transient bad snapshot/dump therefore defers
 * a removal instead of shipping it; the item reappearing on any later run resets its
 * strikes entirely. Same distinct-day accounting as the ghost ignore list.
 */
export const REMOVAL_CONFIRM_STRIKES = 3;

/**
 * One reconcile pass over a pending-strike map for a set of currently-missing keys.
 * Mutates `pending`: keys no longer missing are cleared (reappeared or moot), missing
 * keys get a distinct-day strike. Returns { confirmed, deferred } (Sets of keys) —
 * confirmed keys are also cleared from `pending` (the removal ships now).
 */
export function reconcileRemovals({ pending, missing, nowIso, confirmStrikes = REMOVAL_CONFIRM_STRIKES }) {
  const missingSet = new Set(missing);
  for (const k of Object.keys(pending)) if (!missingSet.has(k)) delete pending[k];
  const confirmed = new Set();
  const deferred = new Set();
  for (const k of missingSet) {
    recordStrike(pending, k, 'removed', nowIso);
    if ((pending[k].strikes ?? 1) >= confirmStrikes) { confirmed.add(k); delete pending[k]; }
    else deferred.add(k);
  }
  return { confirmed, deferred };
}

export const membershipKey = (playlistId, songId) => `${playlistId}|${songId}`;

/**
 * Layer removal confirmation on top of mergePlaylists' output. Two levels:
 *  - playlist-level: a committed playlist absent from `merged` (deleted in Music) is
 *    retained (membership pruned to live songs) until its deletion is confirmed on
 *    `confirmStrikes` distinct days; it is reinserted at its old index to avoid churn.
 *  - membership-level: a song present in the committed playlist but missing from the
 *    fresh dump membership (and still in the library) is reinserted at its old index
 *    until confirmed. Library-wide song removals are NOT membership edits — callers
 *    pass `finalSongIds` so those prune via the normal path with their own confirmation.
 * Mutates pending.playlists / pending.memberships (created if absent).
 */
export function deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso,
  confirmStrikes = REMOVAL_CONFIRM_STRIKES, log = () => {} }) {
  pending.playlists = pending.playlists || {};
  pending.memberships = pending.memberships || {};
  const old = oldPlaylists || [];
  const mergedById = new Map(merged.map((p) => [p.id, p]));
  const oldById = new Map(old.map((p) => [p.id, p]));

  // SUBSCRIPTION PLAYLISTS ARE NEVER IN THE DUMP. Apple editorial playlists saved from the
  // catalog don't appear in Music.app's playlist dump, so they look "deleted" every single run.
  // They are stamped `librarySource:"subscription"` by scripts/union-am-index.mjs and exempted
  // here. NOTE the asymmetry that makes this subtle: songs default to KEEP, playlists default to
  // DROP — `out` below starts as dump-only and reinserts solely from `plDeferred`. So merely
  // filtering these out of `missingPl` would delete them on the FIRST run, faster than doing
  // nothing; they must also be explicitly reinserted (see the exempt loop below).
  const exemptPl = new Set(old.filter((p) => p.librarySource === 'subscription').map((p) => p.id));

  // Playlist-level: absent from the merge output = deleted in Music this run.
  const missingPl = old.filter((p) => !mergedById.has(p.id) && !exemptPl.has(p.id)).map((p) => p.id);
  const { confirmed: plConfirmed, deferred: plDeferred } =
    reconcileRemovals({ pending: pending.playlists, missing: missingPl, nowIso, confirmStrikes });

  // Membership-level: playlists present in both — diff committed membership vs fresh.
  const missingMem = [];
  for (const p of merged) {
    const prev = oldById.get(p.id);
    if (!prev) continue;
    const cur = new Set(p.songIds || []);
    for (const sidX of prev.songIds || []) {
      if (!cur.has(sidX) && finalSongIds.has(sidX)) missingMem.push(membershipKey(p.id, sidX));
    }
  }
  const { deferred: memDeferred } =
    reconcileRemovals({ pending: pending.memberships, missing: missingMem, nowIso, confirmStrikes });

  // Rebuild: reinsert deferred members at their committed index…
  const out = merged.map((p) => {
    const prev = oldById.get(p.id);
    if (!prev) return p;
    const prevIds = prev.songIds || [];
    const deferredSids = prevIds.filter((sidX) => memDeferred.has(membershipKey(p.id, sidX)));
    if (!deferredSids.length) return p;
    const songIds = [...(p.songIds || [])];
    for (const sidX of deferredSids) songIds.splice(Math.min(prevIds.indexOf(sidX), songIds.length), 0, sidX);
    log(`  ⏳ playlist "${p.name}": ${deferredSids.length} member removal(s) pending confirmation ` +
      `(${confirmStrikes} distinct days) — retained for now`);
    return { ...p, songIds };
  });
  // …then reinsert deletion-deferred playlists at their committed index.
  for (const [i, p] of old.entries()) {
    if (exemptPl.has(p.id) && !mergedById.has(p.id)) {
      // Subscription playlist: not in the dump by nature, so carry it forward verbatim
      // (membership pruned to live songs) rather than letting the default-DROP path eat it.
      out.splice(Math.min(i, out.length), 0,
        { ...p, songIds: (p.songIds || []).filter((sidX) => finalSongIds.has(sidX)) });
    } else if (plDeferred.has(p.id)) {
      log(`  ⏳ playlist "${p.name}" missing from dump — deletion pending confirmation (${confirmStrikes} distinct days), retained`);
      out.splice(Math.min(i, out.length), 0, { ...p, songIds: (p.songIds || []).filter((sidX) => finalSongIds.has(sidX)) });
    } else if (plConfirmed.has(p.id)) {
      log(`  ✂ playlist "${p.name}" deletion confirmed on ${confirmStrikes} distinct days — dropped`);
    }
  }
  return out;
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
