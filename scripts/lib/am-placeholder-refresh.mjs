// Pre-release placeholder refresh for the Apple Music (Local) index.
//
// A pre-release album added to the library carries Apple's placeholder metadata ("Track 16",
// album "Sorry, we don't have an album title yet ..."). On release day Music.app rewrites those
// rows IN PLACE — same persistent IDs, so same PocketDJ song ids — without bumping their
// modification date. The incremental sync only fetched NEW persistent IDs, so placeholder rows
// stayed frozen forever. These helpers pick the rows worth re-reading, merge the fresh metadata
// over the committed rows, and fill catalog ids from an iTunes album lookup.

import { comparableTitle } from './am-match.mjs';

const TRACK_PLACEHOLDER = /^track\s*\d+$/i;
const ALBUM_PLACEHOLDER = /^sorry,?\s+we\s+don.?t\s+have\s+an\s+album\s+title\s+yet/i;

export const isPlaceholderTitle = (name) => TRACK_PLACEHOLDER.test(String(name || '').trim());
export const isPlaceholderAlbum = (name) => ALBUM_PLACEHOLDER.test(String(name || '').trim());

/**
 * Song ids to re-read: every song on an album that is still (partly) placeholder. Whole
 * albums, not just the placeholder rows — a release can also retitle/reorder real rows.
 */
export function placeholderCandidates(songs, albums) {
  const albumById = new Map((albums || []).map((a) => [a.id, a]));
  const dirtyAlbums = new Set();
  for (const s of songs || []) {
    if (isPlaceholderTitle(s.name) || isPlaceholderAlbum(albumById.get(s.albumId)?.name)) dirtyAlbums.add(s.albumId);
  }
  return new Set((songs || []).filter((s) => dirtyAlbums.has(s.albumId)).map((s) => s.id));
}

// Fields the Music.app re-read is authoritative for. Everything else on the committed row
// (explicit, bpm/key from audio analysis, appleMusicId, dateAdded …) is kept.
const METADATA_FIELDS = ['albumId', 'artist', 'name', 'trackNumber', 'year', 'length', 'pointer', 'genre'];
// Derived from the OLD title — stale once the title changes; their producers refill them.
const TITLE_DERIVED_FIELDS = ['appleMusicUrl', 'spotifyUrl', 'youtubeUrl', 'lyricsStatus', 'lyricsSource'];

/**
 * Merge re-read rows over committed ones. Returns the updated songs (by id), the ids whose
 * title/artist changed (their title-derived caches must be evicted), and every album id whose
 * membership or order may have changed.
 */
export function mergeRefreshed({ oldById, refreshedSongs }) {
  const updated = new Map();
  const renamed = new Set();
  const touchedAlbums = new Set();
  for (const fresh of refreshedSongs || []) {
    const old = oldById.get(fresh.id);
    if (!old) continue;
    const next = { ...old };
    let changed = false;
    for (const f of METADATA_FIELDS) {
      if (fresh[f] === undefined) continue;
      if (JSON.stringify(fresh[f]) !== JSON.stringify(old[f])) { next[f] = fresh[f]; changed = true; }
    }
    if (!changed) continue;
    if (next.name !== old.name || next.artist !== old.artist) {
      renamed.add(fresh.id);
      for (const f of TITLE_DERIVED_FIELDS) delete next[f];
    }
    touchedAlbums.add(old.albumId);
    touchedAlbums.add(next.albumId);
    updated.set(fresh.id, next);
  }
  return { updated, renamed, touchedAlbums };
}

/**
 * Fill `appleMusicId` on songs that lack one from an iTunes album lookup's track rows
 * (`{trackId, trackName, trackNumber, discNumber}`). A row matches only when disc + track
 * number agree AND the normalized titles agree — never on position alone.
 */
export function fillCatalogIds(songs, lookupTracks) {
  const byPos = new Map();
  for (const t of lookupTracks || []) byPos.set(`${t.discNumber || 1}|${t.trackNumber}`, t);
  let filled = 0;
  const out = (songs || []).map((s) => {
    if (s.appleMusicId || isPlaceholderTitle(s.name)) return s;
    const t = byPos.get(`${s.pointer?.disc || 1}|${s.trackNumber ?? s.pointer?.track}`);
    if (!t || comparableTitle(t.trackName) !== comparableTitle(s.name)) return s;
    filled++;
    return { ...s, appleMusicId: String(t.trackId) };
  });
  return { songs: out, filled };
}
