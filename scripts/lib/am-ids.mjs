// Shared id derivation for the Apple Music catalog — the SINGLE source of truth for how a
// track's persistent ID, an (artist, album) pair, and a playlist map to stable catalog ids.
// index-apple-music.mjs (full rebuild) and am-incremental-sync.mjs (incremental append) BOTH
// import these so their ids are byte-identical; any drift here would orphan every song/album.
import { createHash } from 'node:crypto';

export function normalize(s) {
  if (!s) return '';
  return String(s)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/['’`]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^the\s+/, '');
}

export const sha1 = (s) => createHash('sha1').update(s).digest('hex');

// namespace for a data source, e.g. nsFor('Apple Music (Local)') -> 'digital|Apple Music (Local)'
export const nsFor = (sourceName) => `digital|${sourceName}`;

export const songIdFor = (ns, persistentId, fallback) =>
  'sng_' + sha1(`${ns}|${persistentId || fallback}`).slice(0, 12);

export const albumIdFor = (ns, artist, album) =>
  'alb_' + sha1(`${ns}|${normalize(artist)}|${normalize(album)}`).slice(0, 12);

export const playlistIdFor = (ns, persistentIdOrName) =>
  'pl_' + sha1(`${ns}|${persistentIdOrName}`).slice(0, 12);
