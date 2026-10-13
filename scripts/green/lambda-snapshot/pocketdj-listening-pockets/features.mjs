// LISTENING POCKETS — SONG FEATURES. The analysis joins each play to the public catalog features
// file the rec engine already reads (rec-features.json on the catalog CloudFront, built by
// scripts/build-rec-features.mjs). Row fields used here:
//   i id · a artist · g genre category · y year · b bpm · c Camelot · s sentiment keywords
//   am Apple Music store id · t timbre axes 0…1 (loud, punch, …)
//
// The identity rules are COPIED from scripts/lambda/rec-engine/index.mjs (`identityKeys`), not
// imported: each Lambda zip packages only its own directory, so a cross-directory import would
// work in the tests and fail in production.

import { readFileSync } from 'node:fs';

const DEFAULT_FEATURES_URL = 'https://d2p4cubg6se03u.cloudfront.net/rec-features.json';
const FEATURES_TTL_MS = 15 * 60 * 1000;

/// Every key one song id can be recognised by:
///   · `sng_<hex>_clean` / `_explicit`  -> the base recording
///   · `amrec_<storeId>`                -> `am:<storeId>` (an ad-hoc capture of an Apple Music song)
/// Mirrors rec-engine `identityKeys` (same placeholder guard on the store id).
export function identityKeys(songId) {
  const id = String(songId || '');
  if (!id) return [];
  const out = [];
  const variant = /^(sng_[0-9a-f]{12})_(clean|explicit)$/.exec(id);
  out.push(variant ? variant[1] : id);
  const adhoc = /^amrec_(\d+)$/.exec(id);
  if (adhoc && adhoc[1].length >= 4 && /[1-9]/.test(adhoc[1])) out.push(`am:${adhoc[1]}`);
  return out;
}

/** Parsed features file → `{ byId: Map<id,row>, byAm: Map<storeId,row> }`. */
export function indexFeatures(parsed) {
  const byId = new Map(); const byAm = new Map();
  for (const row of parsed?.songs || []) {
    if (!row || typeof row.i !== 'string') continue;
    byId.set(row.i, row);
    // First row wins for a store id shared by several catalog rows (a re-release, a variant):
    // deterministic, and any of them carries the same musical features.
    if (row.am != null && !byAm.has(String(row.am))) byAm.set(String(row.am), row);
  }
  return { byId, byAm };
}

/** The features row for `songId`, under any of its identities; null when the catalog has none. */
export function resolveSong(byId, byAm, songId) {
  if (!byId) return null;
  const direct = byId.get(songId);
  if (direct) return direct;
  for (const k of identityKeys(songId)) {
    if (k.startsWith('am:')) {
      const row = byAm?.get(k.slice(3));
      if (row) return row;
    } else {
      const row = byId.get(k);
      if (row) return row;
    }
  }
  return null;
}

// ── Loader (module-level cache, survives warm invocations) ─────────────────────────────────────
// `POCKETS_FEATURES_FILE` is the zero-network seam (tests, the local runner); otherwise the CDN
// with a 15-minute TTL and a conditional re-fetch. Stale beats none: a CDN hiccup after the first
// successful load keeps serving the cached index.

let _features = null;   // { byId, byAm, etag, fetchedAtMs, source }

export async function loadFeatures({ file = process.env.POCKETS_FEATURES_FILE || null,
  url = process.env.FEATURES_URL || DEFAULT_FEATURES_URL, nowMs = Date.now() } = {}) {
  if (file) {
    if (!_features || _features.source !== `file:${file}`) {
      const parsed = JSON.parse(readFileSync(file, 'utf8'));
      _features = { ...indexFeatures(parsed), etag: null, fetchedAtMs: nowMs, source: `file:${file}` };
    }
    return _features;
  }
  if (_features && _features.source === url && nowMs - _features.fetchedAtMs < FEATURES_TTL_MS) return _features;
  const headers = _features?.etag && _features.source === url ? { 'If-None-Match': _features.etag } : {};
  let res;
  try {
    res = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
  } catch (e) {
    if (_features) return _features;
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  if (res.status === 304 && _features) { _features.fetchedAtMs = nowMs; return _features; }
  let parsed = null;
  if (res.ok) { try { parsed = await res.json(); } catch { /* SPA fallback HTML / partial body */ } }
  if (!parsed || !Array.isArray(parsed.songs)) {
    if (_features) return _features;
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  _features = { ...indexFeatures(parsed), etag: res.headers.get('etag'), fetchedAtMs: nowMs, source: url };
  return _features;
}

/// Test seam: forget the cached index (a test that swaps the fixture file between cases).
export function _resetFeaturesCache() { _features = null; }
