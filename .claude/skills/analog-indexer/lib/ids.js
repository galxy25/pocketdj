// Content-derived stable ids. Re-runs produce the SAME ids for the same album/
// song, so merging shards is idempotent (upsert by id).
import { createHash } from 'node:crypto';
import { normalize } from './normalize.js';

function sha1hex(s) {
  return createHash('sha1').update(s).digest('hex');
}

/** alb_<12 hex>. dupIndex keeps duplicate pressings ("Raw 2") as distinct items. */
export function albumId(artist, name, dupIndex = null) {
  const key = `${normalize(artist)}|${normalize(name)}|${dupIndex ?? 1}`;
  return 'alb_' + sha1hex(key).slice(0, 12);
}

/** sng_<12 hex>, scoped to its album + disc/track position. */
export function songId(albumIdStr, trackNumber, discNumber = 1) {
  const key = `${albumIdStr}|${discNumber ?? 1}|${trackNumber ?? 0}`;
  return 'sng_' + sha1hex(key).slice(0, 12);
}
