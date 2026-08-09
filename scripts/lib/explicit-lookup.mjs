// explicit-lookup — pure matching for the LOOKUP-based explicit-edition resolver
// (scripts/resolve-explicit-lookup.mjs).
//
// WHY THIS EXISTS. The original resolver (resolve-explicit-variants.mjs) discovered
// editions through the iTunes *search* endpoint. That endpoint filters explicit content
// out of its results unconditionally — `&explicit=Yes` and `&country=US` make no
// difference, and a term like "Kendrick Lamar HUMBLE." comes back 100% cleaned/notExplicit.
// A full 31,038-song crawl on that route therefore found 24,936 clean ids and ZERO
// explicit ones, which is the exact opposite of what the feature is for.
//
// The *lookup* endpoint is not filtered. `lookup?id=<artistId>&entity=album` returns the
// artist's explicit albums, and `lookup?id=<albumId>&entity=song` returns their explicit
// tracks. So the route is: song → artistId → the artist's explicit album whose title
// matches → the track on it that matches. Verified 8/8 against real catalog songs.
//
// The tight-matching doctrine from am-match.mjs still governs every comparison: recording
// markers must agree, and a duration we cannot verify is a rejection, not a guess.
import { comparableTitle } from './am-match.mjs';
import { classifyExplicitness } from './explicit-variants.mjs';

/// The sibling album of `albumTitle` in `albums`, restricted to `wantClass`.
/// `albums` is [{ id, name, cls }]. Clean and explicit editions of one album share a
/// title ("DAMN." / "DAMN."), and comparableTitle strips the cosmetic parenthetical a
/// storefront sometimes adds ("DAMN. (Clean)"), so equality is the right test.
/// `altTitles` lets a caller offer the index's album name AND the storefront's
/// collectionName — either matching is enough, since the two disagree often.
export function pickSiblingAlbum(albums, wantClass, ...altTitles) {
  const wanted = altTitles.map((t) => comparableTitle(t || '')).filter(Boolean);
  if (!wanted.length) return null;
  // Prefer the earliest-listed match: the artist lookup returns an artist's albums with
  // the canonical release ahead of the reissues/compilations that reuse its title.
  for (const a of albums || []) {
    if (!a || a.cls !== wantClass) continue;
    if (wanted.includes(comparableTitle(a.name || ''))) return String(a.id);
  }
  return null;
}

/// The track in `tracks` that is the same recording as `song`, restricted to `wantClass`.
/// `tracks` is [{ id, name, ms, cls }]. Gates, deliberately identical in spirit to
/// findEditions(): title must compare equal (a remix/live/edit is a different recording),
/// and duration must be known on both sides and within 7 s — an unverifiable duration is
/// rejected rather than assumed, because stamping the wrong edition is worse than
/// stamping none. Ties break toward the closest duration.
export function pickTrackInAlbum(song, tracks, wantClass) {
  const ct = comparableTitle(song?.name || '');
  const len = Number(song?.length) || 0;
  if (!ct || !len) return null;
  let best = null;
  for (const t of tracks || []) {
    if (!t || t.cls !== wantClass) continue;
    if (comparableTitle(t.name || '') !== ct) continue;
    const ms = Number(t.ms) || 0;
    if (!ms) continue;
    const delta = Math.abs(len - ms);
    if (delta > 7000) continue;
    if (!best || delta < best.delta) best = { id: String(t.id), delta };
  }
  return best ? best.id : null;
}

/// Normalize an iTunes lookup album row → { id, name, cls }.
export function albumRow(r) {
  return {
    id: r?.collectionId,
    name: r?.collectionName || '',
    cls: classifyExplicitness(r?.collectionExplicitness),
  };
}

/// Normalize an iTunes lookup track row → { id, name, ms, cls }.
export function trackRow(r) {
  return {
    id: r?.trackId,
    name: r?.trackName || '',
    ms: r?.trackTimeMillis || 0,
    cls: classifyExplicitness(r?.trackExplicitness),
  };
}
