// iTunes Search/Lookup API helpers (keyless) + a fuzzy-match scorer.
//
// The enrich agents call these endpoints via WebFetch; this module documents the
// URL shapes and provides a deterministic scorer the agent can mirror (and the
// CLI can use for offline scoring of cached results). No network here.
import { normalize, tokenSet, diceTokens, coverage } from './normalize.js';

/** Album search by the whole spaced blob (no artist/album split needed). */
export function searchUrl(term, { limit = 8, country = 'US' } = {}) {
  const q = encodeURIComponent(term);
  return `https://itunes.apple.com/search?term=${q}&entity=album&limit=${limit}&country=${country}`;
}

/** Tracklist lookup for a matched album. */
export function lookupUrl(collectionId, { country = 'US' } = {}) {
  return `https://itunes.apple.com/lookup?id=${collectionId}&entity=song&country=${country}`;
}

/** Upscale iTunes artwork URL: .../100x100bb.jpg -> .../600x600bb.jpg */
export function upscaleArtwork(url, size = 600) {
  if (!url) return url;
  return url.replace(/\/\d+x\d+bb\.(jpg|png)/, `/${size}x${size}bb.$1`);
}

const COMPILATION_PHRASES = ['greatest hits', 'best of', 'anthology', 'collection', 'the best'];

/**
 * Score one iTunes album result against the parsed blob (0..1).
 * Combined artist+album text is compared so the artist/album split is irrelevant.
 */
export function scoreCandidate(spacedBlob, cand) {
  const blobSet = tokenSet(spacedBlob);
  const candText = `${cand.artistName || ''} ${cand.collectionName || ''}`;
  const candSet = tokenSet(candText);

  let score = diceTokens(blobSet, candSet);

  // Bonus: artist tokens fully covered by the blob.
  const artistCov = coverage(cand.artistName || '', spacedBlob);
  score += 0.12 * artistCov;

  // Bonus: collection name substring present in normalized blob.
  const nb = normalize(spacedBlob);
  const nc = normalize(cand.collectionName || '');
  if (nc && nb.includes(nc)) score += 0.1;

  // Compilations ("Greatest Hits"/"Best Of") are EXPECTED for vinyl — don't penalize;
  // small bonus when both sides agree on the phrase.
  for (const p of COMPILATION_PHRASES) {
    if (nb.includes(p) && nc.includes(p)) { score += 0.05; break; }
  }

  // Penalties: spurious Single/EP, or Various Artists when blob looks single-artist.
  if (/\b(single|ep)\b/i.test(cand.collectionName || '') && !/\b(single|ep)\b/i.test(spacedBlob)) {
    score -= 0.15;
  }
  if ((cand.artistName || '').toLowerCase() === 'various artists' && artistCov < 0.5) {
    score -= 0.1;
  }

  return Math.max(0, Math.min(1.3, score));
}

/**
 * Rank iTunes results and classify the best match.
 *  strong:   top >= 0.62 AND margin >= 0.08
 *  weak:     top in [0.45, 0.62)
 *  unmatched: top < 0.45
 */
export function classifyMatch(spacedBlob, results) {
  if (!results || results.length === 0) return { status: 'unmatched', best: null, score: 0, margin: 0 };
  const scored = results
    .map((r) => ({ r, s: scoreCandidate(spacedBlob, r) }))
    .sort((a, b) => b.s - a.s);
  const top = scored[0];
  const second = scored[1]?.s ?? 0;
  const margin = top.s - second;
  let status, confidence;
  if (top.s >= 0.62 && margin >= 0.08) { status = 'matched'; confidence = 'strong'; }
  else if (top.s >= 0.45) { status = 'matched'; confidence = 'weak'; }
  else { status = 'unmatched'; confidence = undefined; }
  return { status, confidence, best: top.r, score: Number(top.s.toFixed(3)), margin: Number(margin.toFixed(3)) };
}

/** Year from an iTunes releaseDate ("1980-06-01T..."). */
export function yearOf(releaseDate) {
  if (!releaseDate) return undefined;
  const m = String(releaseDate).match(/^(\d{4})/);
  return m ? parseInt(m[1], 10) : undefined;
}
