// explicit-variants — pure matching for the explicit/clean VARIANT re-index
// (scripts/resolve-explicit-variants.mjs). Given one song and its iTunes Search
// results, find the best catalog row for EACH explicitness class of the SAME
// recording — the tight-matching doctrine (recording markers must agree; see
// am-match.mjs) applied per edition. No I/O, fully unit-testable
// (scripts/test-explicit-variants.mjs).
import { normArtist, comparableTitle } from './am-match.mjs';

/// iTunes `trackExplicitness` → 'explicit' | 'clean' | null (unknown/absent).
/// 'cleaned' and 'notExplicit' both mean the row is a non-explicit edition.
export function classifyExplicitness(trackExplicitness) {
  if (trackExplicitness === 'explicit') return 'explicit';
  if (trackExplicitness === 'cleaned' || trackExplicitness === 'notExplicit') return 'clean';
  return null;
}

/// Best catalog row per explicitness class for `song` → { explicitId, cleanId }
/// (String trackIds or null). Gates, per candidate row:
///   • artist: normArtist equal OR containment either way (feat. spillover);
///   • title: comparableTitle equality — recording markers MUST agree (a remix/live/
///     edit never matches the standard cut; explicit/clean parentheticals are cosmetic
///     there, so both editions compare equal — exactly what we want);
///   • duration: when BOTH song.length and r.trackTimeMillis are known, within 7 s;
///     when either is unknown the candidate is REJECTED (can't verify the recording).
/// Scoring per surviving candidate (class-internal ranking only):
///   +25 album title matches (clean albums are "X (Clean)" — cosmetic-stripped they
///       compare equal), +15 duration within 2 s, +10 exact raw normalized title.
/// Recording an id even when it equals song.appleMusicId is fine — it just confirms
/// the primary's class (the app's appleMusicId(for:) handles the equality).
export function findEditions(song, albumName, results) {
  const na = normArtist(song.artist);
  const ct = comparableTitle(song.name);
  const ca = comparableTitle(albumName || '');
  const rawTitle = String(song.name || '').toLowerCase().trim();
  const best = { explicit: null, clean: null };   // { id, score } per class

  for (const r of results || []) {
    const cls = classifyExplicitness(r.trackExplicitness);
    if (!cls) continue;
    // artist gate
    const ra = normArtist(r.artistName);
    if (!(ra === na || ra.includes(na) || na.includes(ra)) || !na || !ra) continue;
    // title gate — the same recording, per the tight matcher
    if (!ct || comparableTitle(r.trackName) !== ct) continue;
    // duration gate — both-known within 7 s, else reject (unverifiable recording)
    const len = Number(song.length) || 0;
    const rlen = Number(r.trackTimeMillis) || 0;
    if (!len || !rlen || Math.abs(len - rlen) > 7000) continue;

    let score = 0;
    if (ca && comparableTitle(r.collectionName) === ca) score += 25;
    if (Math.abs(len - rlen) <= 2000) score += 15;
    if (String(r.trackName || '').toLowerCase().trim() === rawTitle) score += 10;

    if (!best[cls] || score > best[cls].score) best[cls] = { id: String(r.trackId), score };
  }

  return {
    explicitId: best.explicit ? best.explicit.id : null,
    cleanId: best.clean ? best.clean.id : null,
  };
}
