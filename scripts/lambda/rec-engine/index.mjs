// PocketDJ RECOMMENDATION ENGINE Lambda (WS-E) — API Gateway HTTP API $default catch-all -> this
// handler. Stores ONE per-profile state JSON (plays / favorites / collection activity / puzzle
// events / collections snapshot) in a PRIVATE S3 bucket and computes recommendations ON REQUEST
// from that state plus a slim precomputed public catalog-features file (rec-features.json, built
// by scripts/build-rec-features.mjs, served from the catalog CloudFront).
//
// ── Auth (single-user pragmatic, ENROLLMENT SECRET + TOFU) ──────────────────────────────────────
// Every route except /health requires the `x-pocketdj-profile` header (validated shape; 400 when
// missing/invalid) and `authorization: Bearer <key>` (401 when missing). State S3 key =
// rec/state/<sha256hex(profileId)>.json.
//
// CREATING state (the FIRST `POST /events` for a profile, which binds keyHash = sha256hex(key)
// trust-on-first-use) additionally requires the shared ENROLLMENT SECRET in
// `x-pocketdj-enroll` — `REC_ENROLL_SECRET` on the function's env, compared in constant time.
// WITHOUT that gate any bearer + any profile header minted a brand-new state object, i.e. the
// endpoint was an open, unbounded write into a bucket with no lifecycle expiry.
// SINGLE-USER TRADEOFF, deliberately noted for the multi-user revisit: the secret ships inside
// the app binary (`Config.recEngineEnrollSecret`), so it is a CAPABILITY TOKEN, not a per-user
// credential — anyone who extracts it can still enroll profiles. It raises the bar from "curl
// the public URL" to "reverse the binary", and it is rotatable (redeploy + ship a build). The
// real fix when this stops being a one-user service is a per-user identity (Sign in with Apple /
// CloudKit-verified user record) minting a per-profile token, at which point this header goes.
// An ALREADY-BOUND profile keeps working with nothing but its TOFU key — the secret is only ever
// consulted when state would be created (or destroyed, see below).
//
// Every later call must present the same key or 403 { error:'key-mismatch' }. A GET before any
// POST (no state object) returns the empty-recs 200s, never 403. Recovery for a genuinely wedged
// key (a reinstall without iCloud, or two devices racing before CloudKit synced the key doc):
// `DELETE /state` accepts EITHER the bound key OR the enrollment secret, so the in-app "Delete
// cloud data" button really can unwedge the profile — after it, the next POST re-binds fresh.
// REC_ALLOW_REBIND=1 (dev only) still bypasses both checks.
//
// ── Size limits (every one of these is load-bearing; the state object is re-read + re-written on
//    every /events call, inside a 1024 MB / 60 s Lambda) ──────────────────────────────────────────
//   MAX_BODY_BYTES  — raw request body, checked BEFORE parsing
//   MAX_BATCH_EVENTS— plays+favorites+activity+puzzle in one batch
//   CAPS            — per-stream stored caps, favorites INCLUDED (a map that only ever grew)
//   cleanSnapshot   — collections / songIds-per-collection / total-songIds truncation
//   MAX_STR         — every stored string
//   MAX_STATE_BYTES — hard backstop before the PUT, so no object can grow past what readState
//                     can safely parse
//
// ── Routes ──────────────────────────────────────────────────────────────────────────────────────
//   GET    /health                       -> { ok:true, service:'rec-engine', version:1 }
//   POST   /events                       -> ingest batch (id-deduped, capped) -> accepted/totals
//   GET    /recs/songs?limit=50          -> For You suggestions
//   GET    /recs/collections?songId=S    -> collection suggestions for a song
//   DELETE /state                        -> delete the state object
//
// ── Test seams (zero AWS) ───────────────────────────────────────────────────────────────────────
//   REC_LOCAL_DIR      — filesystem state store instead of S3 (the jukebox DRY_RUN idea)
//   REC_FEATURES_FILE  — local features fixture path instead of fetching FEATURES_URL
//   REC_ENROLL_SECRET  — read per request (not captured at module load) so a test can flip it

import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, unlinkSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REGION = process.env.AWS_REGION || 'us-west-2';
const REC_BUCKET = process.env.REC_BUCKET;
const FEATURES_URL = process.env.FEATURES_URL || 'https://d2p4cubg6se03u.cloudfront.net/rec-features.json';
const LOCAL_DIR = process.env.REC_LOCAL_DIR || null;
const FEATURES_FILE = process.env.REC_FEATURES_FILE || null;

const PROFILE_RE = /^[A-Za-z0-9._-]{8,64}$/;
const CAPS = { plays: 5000, activity: 3000, puzzle: 2000, favorites: 5000 };
const MAX_BATCH_EVENTS = 2000;
/// Raw request body ceiling, checked before JSON.parse. Well under Lambda's 6 MB synchronous
/// invocation payload limit, and far above any honest batch (2000 events ≈ 250 KB, a snapshot of
/// a very large library ≈ 1 MB).
const MAX_BODY_BYTES = 4 * 1024 * 1024;
/// Hard ceiling on the SERIALIZED state object. readState GET+parses this on every route
/// (DELETE included), so a state that can't be parsed is a permanently wedged profile.
const MAX_STATE_BYTES = 20 * 1024 * 1024;
const MAX_STR = 256;
const MAX_COLLECTIONS = 500;
const MAX_SONGIDS_PER_COLLECTION = 5000;
const MAX_SNAPSHOT_SONGIDS = 100_000;
const DAY_MS = 24 * 60 * 60 * 1000;

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

// ── State store: S3 (ETag-conditional) or local filesystem (tests) ──────────────────────────────
// Local mode mirrors the conditional-put semantics with a content-hash pseudo-ETag so the retry
// path is testable without AWS.

let _s3 = null; let _s3mod = null;
async function s3() {
  if (!_s3) {
    _s3mod = await import('@aws-sdk/client-s3');
    _s3 = new _s3mod.S3Client({ region: REGION });
  }
  return { client: _s3, mod: _s3mod };
}

const stateKey = (profileHash) => `rec/state/${profileHash}.json`;
const localStatePath = (profileHash) => join(LOCAL_DIR, 'rec', 'state', `${profileHash}.json`);

class Precondition extends Error {}

async function readState(profileHash) {
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (!existsSync(p)) return null;
    const bytes = readFileSync(p, 'utf8');
    return { state: JSON.parse(bytes), etag: sha256(bytes) };
  }
  const { client, mod } = await s3();
  try {
    const out = await client.send(new mod.GetObjectCommand({ Bucket: REC_BUCKET, Key: stateKey(profileHash) }));
    return { state: JSON.parse(await out.Body.transformToString()), etag: out.ETag };
  } catch (e) {
    if (e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) return null;
    throw e;
  }
}

async function writeState(profileHash, state, { ifMatch } = {}) {
  const body = JSON.stringify(state);
  // Backstop: the caps above should make this unreachable, so reaching it means a cap was
  // missed — refuse the write rather than grow an object readState can no longer parse.
  if (Buffer.byteLength(body, 'utf8') > MAX_STATE_BYTES) {
    const err = new Error('state-too-large'); err.statusCode = 413; throw err;
  }
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (ifMatch) {
      const cur = existsSync(p) ? sha256(readFileSync(p, 'utf8')) : null;
      if (cur !== ifMatch) throw new Precondition('etag mismatch');
    } else if (existsSync(p)) {
      throw new Precondition('exists');
    }
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, body);
    return;
  }
  const { client, mod } = await s3();
  try {
    await client.send(new mod.PutObjectCommand({
      Bucket: REC_BUCKET, Key: stateKey(profileHash), Body: body, ContentType: 'application/json',
      ...(ifMatch ? { IfMatch: ifMatch } : { IfNoneMatch: '*' }),
    }));
  } catch (e) {
    const code = e.$metadata?.httpStatusCode;
    if (code === 412 || code === 409 || e.name === 'PreconditionFailed' || e.name === 'ConditionalRequestConflict') {
      throw new Precondition(e.message);
    }
    throw e;
  }
}

async function deleteState(profileHash) {
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (existsSync(p)) unlinkSync(p);
    return;
  }
  const { client, mod } = await s3();
  await client.send(new mod.DeleteObjectCommand({ Bucket: REC_BUCKET, Key: stateKey(profileHash) }));
}

// ── Features cache (module-level, survives warm invocations) ────────────────────────────────────

let _features = null;   // { parsed, byId, etag, fetchedAtMs }
const FEATURES_TTL_MS = 15 * 60 * 1000;

function indexFeatures(parsed) {
  const byId = new Map();
  for (const row of parsed?.songs || []) byId.set(row.i, row);
  return byId;
}

async function loadFeatures() {
  if (FEATURES_FILE) {
    if (!_features) {
      const parsed = JSON.parse(readFileSync(FEATURES_FILE, 'utf8'));
      _features = { parsed, byId: indexFeatures(parsed), etag: null, fetchedAtMs: Date.now() };
    }
    return _features;
  }
  const now = Date.now();
  if (_features && now - _features.fetchedAtMs < FEATURES_TTL_MS) return _features;
  const headers = _features?.etag ? { 'If-None-Match': _features.etag } : {};
  const res = await fetch(FEATURES_URL, { headers, signal: AbortSignal.timeout(20_000) });
  if (res.status === 304 && _features) {
    _features.fetchedAtMs = now;
    return _features;
  }
  if (!res.ok) {
    if (_features) return _features;   // stale beats none
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  let parsed = null;
  try { parsed = await res.json(); } catch { /* SPA fallback HTML / partial body */ }
  if (!parsed || !Array.isArray(parsed.songs)) {
    // The catalog CDN answers missing files with the SPA shell (200 + HTML) — before
    // rec-features.json is deployed this is the path every /recs/* request takes.
    if (_features) return _features;
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  _features = { parsed, byId: indexFeatures(parsed), etag: res.headers.get('etag'), fetchedAtMs: now };
  return _features;
}

// ── Camelot ─────────────────────────────────────────────────────────────────────────────────────

/** Harmonic neighbor set of a Camelot code: itself, ±1 same letter (12↔1 wrap), same number
 *  other letter. Invalid/absent code -> empty set. */
export function camelotNeighbors(code) {
  const m = /^(\d{1,2})([AB])$/i.exec(String(code || '').trim());
  if (!m) return new Set();
  const n = parseInt(m[1], 10);
  if (n < 1 || n > 12) return new Set();
  const letter = m[2].toUpperCase();
  const prev = n === 1 ? 12 : n - 1;
  const next = n === 12 ? 1 : n + 1;
  const other = letter === 'A' ? 'B' : 'A';
  return new Set([`${n}${letter}`, `${prev}${letter}`, `${next}${letter}`, `${n}${other}`]);
}

/** Genre category of a song per the features file (g omitted = 'other'/unknown -> null). */
export function genreOf(byId, songId) {
  return byId.get(songId)?.g ?? null;
}

// ── State shape + batch merge ───────────────────────────────────────────────────────────────────

function freshState(profileId) {
  const now = Date.now();
  return {
    v: 1, profileId, keyHash: null, createdAtMs: now, updatedAtMs: now,
    plays: [], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
  };
}

const num = (v) => (Number.isFinite(v) ? v : null);
/// Every stored string goes through here: absent/empty -> null, everything else TRUNCATED to
/// MAX_STR. Truncation (not rejection) keeps an honest-but-long name/id ingesting, while a
/// megabyte "id" can no longer be parked in the state object.
const str = (v, max = MAX_STR) => (typeof v === 'string' && v ? v.slice(0, max) : null);

function cleanPlay(e) {
  const id = str(e?.id); const songId = str(e?.songId); const atMs = num(e?.atMs);
  if (!id || !songId || atMs == null) return null;
  const out = { id, songId, atMs };
  const source = str(e.source);
  if (source) out.source = source;
  return out;
}
function cleanFavorite(e) {
  const songId = str(e?.songId); const atMs = num(e?.atMs);
  if (!songId || atMs == null || typeof e?.favorited !== 'boolean') return null;
  return { songId, favorited: e.favorited, atMs };
}
function cleanActivity(e) {
  const id = str(e?.id); const atMs = num(e?.atMs);
  const kind = str(e?.kind); const itemId = str(e?.itemId);
  if (!id || atMs == null || !kind || !itemId) return null;
  const out = { id, atMs, kind, itemId };
  for (const k of ['collectionId', 'collectionKind', 'collectionName']) {
    const v = str(e[k]);
    if (v) out[k] = v;
  }
  return out;
}
function cleanPuzzle(e) {
  const id = str(e?.id); const atMs = num(e?.atMs); const action = str(e?.action);
  if (!id || atMs == null || !action) return null;
  const out = { id, atMs, action };
  for (const k of ['gameId', 'songId', 'collectionId']) {
    const v = str(e[k]);
    if (v) out[k] = v;
  }
  if (num(e.points) != null) out.points = e.points;
  return out;
}
/// The membership snapshot is stored WHOLESALE, and (unlike the event streams) it is not counted
/// toward MAX_BATCH_EVENTS — a legitimate flush carries a full batch AND the snapshot, so
/// counting it would reject honest uploads. It is bounded by TRUNCATION instead: at most
/// MAX_COLLECTIONS entries, MAX_SONGIDS_PER_COLLECTION ids each, MAX_SNAPSHOT_SONGIDS in total.
function cleanSnapshot(s) {
  if (!s || typeof s !== 'object' || !Array.isArray(s.collections)) return null;
  const list = [];
  let budget = MAX_SNAPSHOT_SONGIDS;
  for (const c of s.collections) {
    if (list.length >= MAX_COLLECTIONS) break;
    const id = str(c?.id); const kind = str(c?.kind); const name = str(c?.name) ?? '';
    if (!id || !kind || !Array.isArray(c?.songIds)) continue;
    const songIds = [];
    for (const x of c.songIds) {
      if (songIds.length >= MAX_SONGIDS_PER_COLLECTION || budget <= 0) break;
      const v = str(x);
      if (!v) continue;
      songIds.push(v); budget -= 1;
    }
    list.push({ id, kind, name, songIds });
  }
  return { atMs: num(s.atMs) ?? Date.now(), list };
}

function capOldest(arr, cap) {
  if (arr.length <= cap) return arr;
  return [...arr].sort((a, b) => a.atMs - b.atMs || (a.id < b.id ? -1 : 1)).slice(arr.length - cap);
}

/// Favorites are a MAP keyed by songId, so `capOldest` doesn't fit — but an uncapped map was the
/// one stream that only ever grew (2000 fresh songIds per batch, forever). Evict tombstones
/// (un-hearts, the least valuable rows) first, then oldest-atMs, until the map fits CAPS.
function capFavorites(favorites, cap) {
  const keys = Object.keys(favorites);
  if (keys.length <= cap) return favorites;
  keys.sort((a, b) => {
    const fa = favorites[a]; const fb = favorites[b];
    const ta = fa?.favorited ? 1 : 0; const tb = fb?.favorited ? 1 : 0;
    return ta - tb || (fa?.atMs || 0) - (fb?.atMs || 0) || (a < b ? -1 : 1);
  });
  for (const k of keys.slice(0, keys.length - cap)) delete favorites[k];
  return favorites;
}

/** Pure ingest merge: dedupe by event id (plays/activity/puzzle — idempotent re-uploads are the
 *  norm), favorites keyed by songId newer-atMs wins, collections snapshot replaced WHOLESALE when
 *  the batch carries one, caps applied after merge (drop oldest). Unknown batch fields ignored
 *  (the reserved `songFeatures` key is accepted and dropped in v1). Mutates + returns `state`
 *  with an `accepted` tally. */
export function mergeBatch(state, batch) {
  const accepted = { plays: 0, favorites: 0, activity: 0, puzzle: 0, collectionsSnapshot: false };

  const playIds = new Set(state.plays.map((e) => e.id));
  for (const raw of batch.plays || []) {
    const e = cleanPlay(raw);
    if (!e || playIds.has(e.id)) continue;
    playIds.add(e.id); state.plays.push(e); accepted.plays += 1;
  }
  state.plays = capOldest(state.plays, CAPS.plays);

  for (const raw of batch.favorites || []) {
    const e = cleanFavorite(raw);
    if (!e) continue;
    const cur = state.favorites[e.songId];
    if (cur && cur.atMs >= e.atMs) continue;
    state.favorites[e.songId] = { favorited: e.favorited, atMs: e.atMs };
    accepted.favorites += 1;
  }
  state.favorites = capFavorites(state.favorites, CAPS.favorites);

  const actIds = new Set(state.activity.map((e) => e.id));
  for (const raw of batch.activity || []) {
    const e = cleanActivity(raw);
    if (!e || actIds.has(e.id)) continue;
    actIds.add(e.id); state.activity.push(e); accepted.activity += 1;
  }
  state.activity = capOldest(state.activity, CAPS.activity);

  const puzIds = new Set(state.puzzle.map((e) => e.id));
  for (const raw of batch.puzzle || []) {
    const e = cleanPuzzle(raw);
    if (!e || puzIds.has(e.id)) continue;
    puzIds.add(e.id); state.puzzle.push(e); accepted.puzzle += 1;
  }
  state.puzzle = capOldest(state.puzzle, CAPS.puzzle);

  const snap = cleanSnapshot(batch.collectionsSnapshot);
  if (snap) { state.collections = { atMs: snap.atMs, list: snap.list }; accepted.collectionsSnapshot = true; }

  state.updatedAtMs = Date.now();
  return { state, accepted };
}

// ── For You (GET /recs/songs) ───────────────────────────────────────────────────────────────────

/** Deterministic For You compute over the profile state + the features doc. Pure. */
export function scoreForYou(state, featuresById, { nowMs = Date.now(), limit = 50 } = {}) {
  limit = Math.min(Math.max(Math.trunc(limit) || 50, 1), 200);

  // 1) Seeds: plays in the last 30 days grouped by song, recency-weighted; favorites and puzzle
  //    references add flat weight. Top 50 by weight.
  const weights = new Map();
  for (const p of state.plays) {
    const ageDays = (nowMs - p.atMs) / DAY_MS;
    if (ageDays < 0 || ageDays > 30) continue;
    weights.set(p.songId, (weights.get(p.songId) || 0) + Math.exp(-ageDays / 7));
  }
  const puzzleSongs = new Set(state.puzzle.map((e) => e.songId).filter(Boolean));
  for (const [songId, w] of weights) {
    let bonus = 0;
    if (state.favorites[songId]?.favorited) bonus += 1.0;
    if (puzzleSongs.has(songId)) bonus += 0.5;
    if (bonus) weights.set(songId, w + bonus);
  }
  const seeds = [...weights.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 50);
  const seedIds = new Set(seeds.map(([id]) => id));
  if (seeds.length === 0) return { v: 1, generatedAtMs: nowMs, seeds: [], songs: [] };

  // 2) Taste aggregates from the seed feature rows, weighted by w.
  const genreCount = new Map(); const seedGenreN = new Map(); const artistCount = new Map();
  let bpmW = 0; let bpmSum = 0; let yearW = 0; let yearSum = 0;
  const neighborSet = new Set(); const kwCount = new Map();
  for (const [songId, w] of seeds) {
    const row = featuresById.get(songId);
    if (!row) continue;
    if (row.g) {
      genreCount.set(row.g, (genreCount.get(row.g) || 0) + w);
      seedGenreN.set(row.g, (seedGenreN.get(row.g) || 0) + 1);
    }
    if (row.a) artistCount.set(row.a, (artistCount.get(row.a) || 0) + w);
    if (row.b != null) { bpmW += w; bpmSum += w * row.b; }
    if (row.y != null) { yearW += w; yearSum += w * row.y; }
    for (const c of camelotNeighbors(row.c)) neighborSet.add(c);
    for (const kw of row.s || []) kwCount.set(kw, (kwCount.get(kw) || 0) + w);
  }
  const mu = bpmW > 0 ? bpmSum / bpmW : null;
  const yearMean = yearW > 0 ? yearSum / yearW : null;
  const maxGenre = Math.max(0, ...genreCount.values());
  const top20 = new Set([...kwCount.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 20).map(([k]) => k));

  // Collection co-membership: every song sharing a user collection with any seed.
  const coMemberIds = new Set(); const coMemberName = new Map();
  for (const col of state.collections?.list || []) {
    if (!col.songIds?.some((id) => seedIds.has(id))) continue;
    for (const id of col.songIds) {
      coMemberIds.add(id);
      if (!coMemberName.has(id)) coMemberName.set(id, col.name);
    }
  }

  // 3) Exclusions: any play in the last 72 h + the seed songs themselves.
  const excluded = new Set(seedIds);
  for (const p of state.plays) if (nowMs - p.atMs < 72 * 60 * 60 * 1000) excluded.add(p.songId);

  // 4) Score every candidate. Each term contributes 0 when its field is absent.
  const scored = [];
  for (const row of featuresById.values()) {
    if (excluded.has(row.i)) continue;
    const terms = [];
    if (row.g && maxGenre > 0 && genreCount.has(row.g)) {
      terms.push(['genre', 2.0 * (genreCount.get(row.g) / maxGenre),
                  `Same genre as ${seedGenreN.get(row.g) || 1} recent play${(seedGenreN.get(row.g) || 1) === 1 ? '' : 's'}`]);
    }
    if (row.b != null && mu != null) {
      terms.push(['bpm', Math.exp(-((row.b - mu) ** 2) / (2 * 15 * 15)), `BPM near ${Math.round(mu)}`]);
    }
    if (row.c && neighborSet.has(row.c)) {
      terms.push(['camelot', 1.0, `Harmonically compatible key (${row.c})`]);
    }
    if (row.y != null && yearMean != null) {
      terms.push(['year', 0.5 * Math.exp(-Math.abs(row.y - yearMean) / 10), `From around ${Math.round(yearMean)}`]);
    }
    if (row.s?.length && top20.size) {
      const overlap = row.s.reduce((n, k) => n + (top20.has(k) ? 1 : 0), 0);
      if (overlap > 0) {
        terms.push(['sentiment', overlap / Math.max(1, Math.min(row.s.length, 5)), 'Similar mood to your recent plays']);
      }
    }
    if (coMemberIds.has(row.i)) {
      terms.push(['collection', 1.5, `In your collection ${coMemberName.get(row.i) || ''} with recent plays`.trim()]);
    }
    if (row.a && (artistCount.get(row.a) || 0) > 0) {
      terms.push(['artist', 0.75, `Artist you've played: ${row.a}`]);
    }
    const score = terms.reduce((s, [, v]) => s + v, 0);
    if (score <= 0) continue;
    const reasons = [...terms].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([, , r]) => r);
    scored.push({ row, score, reasons });
  }

  // 5) Deterministic order + diversity caps (max 2 per artist, 3 per album), then top `limit`.
  scored.sort((a, b) => b.score - a.score || (a.row.i < b.row.i ? -1 : 1));
  const perArtist = new Map(); const perAlbum = new Map();
  const out = [];
  for (const { row, score, reasons } of scored) {
    if (out.length >= limit) break;
    const a = row.a || ''; const al = row.al || '';
    if (a && (perArtist.get(a) || 0) >= 2) continue;
    if (al && (perAlbum.get(al) || 0) >= 3) continue;
    if (a) perArtist.set(a, (perArtist.get(a) || 0) + 1);
    if (al) perAlbum.set(al, (perAlbum.get(al) || 0) + 1);
    out.push({ songId: row.i, name: row.n ?? null, artist: row.a ?? null,
               score: Math.round(score * 100) / 100, reasons });
  }
  return { v: 1, generatedAtMs: nowMs, seeds: [...seedIds], songs: out };
}

// ── Collection suggestions (GET /recs/collections?songId=S) ─────────────────────────────────────

/** Deterministic per-song collection suggestions over the profile state + features doc. Pure. */
export function scoreCollections(state, featuresById, songId, { nowMs = Date.now(), threshold = 0.8 } = {}) {
  const S = featuresById.get(songId);
  if (!S) return { v: 1, songId, suggestions: [] };

  const sNeighbors = camelotNeighbors(S.c);
  const playsOfS = state.plays.filter((p) => p.songId === songId).map((p) => p.atMs);
  const lastActivityByCol = new Map();
  for (const a of state.activity) {
    if (!a.collectionId) continue;
    const cur = lastActivityByCol.get(a.collectionId) || 0;
    if (a.atMs > cur) lastActivityByCol.set(a.collectionId, a.atMs);
  }
  // Puzzle: an "added" event into a collection whose song shares S's genre category.
  const puzzleGenreCols = new Set();
  if (S.g) {
    for (const e of state.puzzle) {
      if (!e.collectionId || !e.songId) continue;
      if (featuresById.get(e.songId)?.g === S.g) puzzleGenreCols.add(e.collectionId);
    }
  }

  const scored = [];
  for (const col of state.collections?.list || []) {
    if (!col.songIds?.length || col.songIds.includes(songId)) continue;
    const sample = col.songIds.slice(0, 200);
    const rows = sample.map((id) => featuresById.get(id)).filter(Boolean);
    const terms = [];

    if (S.g && rows.length) {
      const share = rows.reduce((n, r) => n + (r.g === S.g ? 1 : 0), 0) / rows.length;
      if (share > 0) terms.push(['genre', 2.0 * share, `Mostly ${S.g} like this song`]);
    }
    const bpms = rows.map((r) => r.b).filter((b) => b != null);
    if (S.b != null && bpms.length) {
      const muc = bpms.reduce((a, b) => a + b, 0) / bpms.length;
      const variance = bpms.reduce((a, b) => a + (b - muc) ** 2, 0) / bpms.length;
      const sigma = Math.max(10, Math.sqrt(variance));
      terms.push(['bpm', Math.exp(-((S.b - muc) ** 2) / (2 * sigma * sigma)), `BPM fits (~${Math.round(muc)})`]);
    }
    const camelots = rows.map((r) => r.c).filter(Boolean);
    if (sNeighbors.size && camelots.length) {
      const frac = camelots.reduce((n, c) => n + (sNeighbors.has(c) ? 1 : 0), 0) / camelots.length;
      if (frac > 0) terms.push(['camelot', 0.75 * frac, 'Harmonically compatible keys']);
    }
    const years = rows.map((r) => r.y).filter((y) => y != null);
    if (S.y != null && years.length) {
      const muy = years.reduce((a, b) => a + b, 0) / years.length;
      terms.push(['year', 0.5 * Math.exp(-Math.abs(S.y - muy) / 10), `Era fits (~${Math.round(muy)})`]);
    }
    const withKw = rows.filter((r) => r.s?.length);
    if (S.s?.length && withKw.length) {
      const sSet = new Set(S.s);
      const jac = withKw.reduce((sum, r) => {
        const inter = r.s.reduce((n, k) => n + (sSet.has(k) ? 1 : 0), 0);
        const union = new Set([...r.s, ...S.s]).size;
        return sum + (union ? inter / union : 0);
      }, 0) / withKw.length;
      if (jac > 0) terms.push(['sentiment', 1.0 * jac, 'Similar mood']);
    }
    if (playsOfS.length) {
      const members = new Set(col.songIds);
      let coPlay = 0;
      for (const p of state.plays) {
        if (!members.has(p.songId)) continue;
        if (playsOfS.some((t) => Math.abs(p.atMs - t) <= 30 * 60 * 1000)) coPlay += 1;
      }
      if (coPlay > 0) terms.push(['coplay', 1.25 * Math.min(1, coPlay / 3), 'Often played together']);
    }
    const lastAct = lastActivityByCol.get(col.id);
    if (lastAct) {
      const days = Math.max(0, (nowMs - lastAct) / DAY_MS);
      terms.push(['recency', 0.5 * Math.exp(-days / 14), 'Recently updated']);
    }
    if (puzzleGenreCols.has(col.id)) {
      terms.push(['puzzle', 0.5, 'Matches your Collector’s Puzzle picks']);
    }

    const score = terms.reduce((s, [, v]) => s + v, 0);
    if (score <= 0) continue;
    const reasons = [...terms].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([, , r]) => r);
    scored.push({ id: col.id, kind: col.kind, name: col.name,
                  score: Math.round(score * 100) / 100, reasons });
  }
  scored.sort((a, b) => b.score - a.score || (a.id < b.id ? -1 : 1));
  return { v: 1, songId, suggestions: scored.filter((s) => s.score >= threshold).slice(0, 5) };
}

// ── HTTP plumbing ───────────────────────────────────────────────────────────────────────────────

function reply(status, obj) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function authOf(event) {
  const h = event.headers || {};
  const profile = h['x-pocketdj-profile'] || h['X-PocketDJ-Profile'];
  if (!profile || !PROFILE_RE.test(profile)) return { fail: reply(400, { error: 'bad-request' }) };
  const raw = h.authorization || h.Authorization || '';
  const key = raw.startsWith('Bearer ') ? raw.slice(7).trim() : '';
  if (!key) return { fail: reply(401, { error: 'unauthorized' }) };
  return { profileId: profile, profileHash: sha256(profile), keyHash: sha256(key) };
}

/// Constant-time compare of the presented enrollment secret against `REC_ENROLL_SECRET`.
/// FAIL-CLOSED: an unset/empty env var rejects every enrollment (a redeploy that forgets the
/// variable must not silently re-open the write path). Read per call so tests can flip it.
export function enrollOk(event) {
  const want = process.env.REC_ENROLL_SECRET || '';
  if (!want) return false;
  const h = event.headers || {};
  const got = h['x-pocketdj-enroll'] || h['X-PocketDJ-Enroll'] || '';
  if (typeof got !== 'string' || got.length !== want.length) return false;
  return timingSafeEqual(Buffer.from(got, 'utf8'), Buffer.from(want, 'utf8'));
}

/// Raw request-body size, BEFORE parsing (base64 bodies are 4/3 of their decoded length).
function bodyBytes(event) {
  if (!event.body) return 0;
  return event.isBase64Encoded
    ? Math.floor((event.body.length * 3) / 4)
    : Buffer.byteLength(event.body, 'utf8');
}

function parseBody(event) {
  if (!event.body) return {};
  const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
  return JSON.parse(text);
}

export async function handler(event) {
  const method = event.requestContext?.http?.method || 'GET';
  const path = (event.rawPath || '/').replace(/\/+$/, '') || '/';
  const qs = event.queryStringParameters || {};

  if (method === 'GET' && path === '/health') {
    return reply(200, { ok: true, service: 'rec-engine', version: 1 });
  }

  const auth = authOf(event);
  if (auth.fail) return auth.fail;
  const allowRebind = process.env.REC_ALLOW_REBIND === '1';

  try {
    if (method === 'POST' && path === '/events') {
      if (bodyBytes(event) > MAX_BODY_BYTES) {
        return reply(413, { error: 'body-too-large', max: MAX_BODY_BYTES });
      }
      let batch;
      try { batch = parseBody(event); } catch { return reply(400, { error: 'bad-request' }); }
      const total = (batch.plays?.length || 0) + (batch.favorites?.length || 0)
        + (batch.activity?.length || 0) + (batch.puzzle?.length || 0);
      if (total > MAX_BATCH_EVENTS) return reply(400, { error: 'batch-too-large', max: MAX_BATCH_EVENTS });

      // Read-merge-write with ETag-conditional puts: on a 412 re-read + re-merge (max 3), then 503
      // (the client keeps its cursors and simply retries next flush — cursors only advance on 2xx).
      for (let attempt = 0; attempt < 3; attempt++) {
        const read = await readState(auth.profileHash);
        const state = read ? read.state : freshState(auth.profileId);
        if (!state.keyHash) {
          // CREATING state for this profile — the enrollment gate (see the header). An
          // already-bound profile never reaches this branch, so a legitimate device that
          // enrolled under an older build keeps uploading with its key alone.
          if (!allowRebind && !enrollOk(event)) return reply(403, { error: 'enrollment-required' });
          state.keyHash = auth.keyHash;   // trust-on-first-use bind
        } else if (state.keyHash !== auth.keyHash && !allowRebind) {
          return reply(403, { error: 'key-mismatch' });
        } else if (allowRebind) {
          state.keyHash = auth.keyHash;
        }
        const { accepted } = mergeBatch(state, batch);
        try {
          await writeState(auth.profileHash, state, { ifMatch: read?.etag });
        } catch (e) {
          if (e instanceof Precondition) continue;
          throw e;
        }
        return reply(200, {
          ok: true, accepted,
          totals: {
            plays: state.plays.length, activity: state.activity.length,
            puzzle: state.puzzle.length, favorites: Object.keys(state.favorites).length,
            collections: state.collections?.list?.length || 0,
          },
        });
      }
      return reply(503, { error: 'conflict-retry' });
    }

    if (method === 'GET' && path === '/recs/songs') {
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { v: 1, generatedAtMs: Date.now(), seeds: [], songs: [] });
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const features = await loadFeatures();
      const limit = parseInt(qs.limit || '50', 10) || 50;
      return reply(200, scoreForYou(read.state, features.byId, { limit }));
    }

    if (method === 'GET' && path === '/recs/collections') {
      const songId = qs.songId;
      if (!songId) return reply(400, { error: 'bad-request' });
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { v: 1, songId, suggestions: [] });
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const features = await loadFeatures();
      const threshold = Number(process.env.REC_COLLECTION_THRESHOLD) || 0.8;
      return reply(200, scoreCollections(read.state, features.byId, songId, { threshold }));
    }

    if (method === 'DELETE' && path === '/state') {
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { deleted: true });
      // Deletion accepts the bound key OR the enrollment secret. That second door is what makes
      // the in-app "Delete cloud data" a REAL recovery from a wedged key (it used to 403 too,
      // so the app's own advice was a dead end); deletion is destructive-only and profile-scoped,
      // and re-binding afterwards still requires the same enrollment secret.
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash
          && !allowRebind && !enrollOk(event)) {
        return reply(403, { error: 'key-mismatch' });
      }
      await deleteState(auth.profileHash);
      return reply(200, { deleted: true });
    }

    return reply(404, { error: 'not-found' });
  } catch (e) {
    const status = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 502;
    return reply(status, { error: e.message || 'internal' });
  }
}
