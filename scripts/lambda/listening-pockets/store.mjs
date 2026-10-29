// LISTENING POCKETS — STORAGE. Two objects per profile in the rec-engine bucket, under its own
// `pockets/` prefix (the function's IAM role reaches nothing else):
//
//   pockets/events/<sha256(profileId)>.json   the stored play rows + TOFU keyHash + dirty flag
//                                             (+ `rounds`: "In the Pocket" game rounds, once any arrive)
//   pockets/results/<sha256(profileId)>.json  the last results.v1 document
//
// S3 with ETag-conditional puts, or the local filesystem when POCKETS_LOCAL_DIR is set (tests and
// the local runner) — local mode mirrors the conditional semantics with a content-hash pseudo-ETag,
// exactly like the rec engine's, so the retry path is testable without AWS.
//
// Also here: the STORED ROW shape (`cleanEvent`) and the per-id merge (`mergeEvents`), because
// "what is stored" is this module's contract with detect/analyze.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, unlinkSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { POCKET_LIMITS, POCKET_PARAMS } from './params.mjs';

const REGION = process.env.AWS_REGION || 'us-west-2';
const DAY_MS = 24 * 60 * 60 * 1000;
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
/// Read per call (not at module load) so a test can point it at a fresh temp dir.
const localDir = () => process.env.POCKETS_LOCAL_DIR || null;
const bucket = () => process.env.REC_BUCKET;

export class Precondition extends Error {}

let _s3 = null; let _s3mod = null;
async function s3() {
  if (!_s3) {
    _s3mod = await import('@aws-sdk/client-s3');
    _s3 = new _s3mod.S3Client({ region: REGION });
  }
  return { client: _s3, mod: _s3mod };
}

const eventsKey = (h) => `pockets/events/${h}.json`;
const resultsKey = (h) => `pockets/results/${h}.json`;
const localPath = (key) => join(localDir(), ...key.split('/'));
const isMissing = (e) => e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404;
const isPrecondition = (e) => {
  const code = e.$metadata?.httpStatusCode;
  return code === 412 || code === 409 || e.name === 'PreconditionFailed' || e.name === 'ConditionalRequestConflict';
};

async function getJson(key) {
  if (localDir()) {
    const p = localPath(key);
    if (!existsSync(p)) return null;
    const bytes = readFileSync(p, 'utf8');
    return { doc: JSON.parse(bytes), etag: sha256(bytes) };
  }
  const { client, mod } = await s3();
  try {
    const out = await client.send(new mod.GetObjectCommand({ Bucket: bucket(), Key: key }));
    return { doc: JSON.parse(await out.Body.transformToString()), etag: out.ETag };
  } catch (e) {
    if (isMissing(e)) return null;
    throw e;
  }
}

/// `ifMatch` = replace only that version; `create: true` = only if absent; neither = overwrite.
async function putJson(key, doc, { ifMatch, create } = {}) {
  const body = JSON.stringify(doc);
  if (localDir()) {
    const p = localPath(key);
    if (ifMatch) {
      const cur = existsSync(p) ? sha256(readFileSync(p, 'utf8')) : null;
      if (cur !== ifMatch) throw new Precondition('etag mismatch');
    } else if (create && existsSync(p)) {
      throw new Precondition('exists');
    }
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, body);
    return;
  }
  const { client, mod } = await s3();
  try {
    await client.send(new mod.PutObjectCommand({
      Bucket: bucket(), Key: key, Body: body, ContentType: 'application/json',
      ...(ifMatch ? { IfMatch: ifMatch } : create ? { IfNoneMatch: '*' } : {}),
    }));
  } catch (e) {
    if (isPrecondition(e)) throw new Precondition(e.message);
    throw e;
  }
}

async function deleteKey(key) {
  if (localDir()) {
    const p = localPath(key);
    if (existsSync(p)) unlinkSync(p);
    return;
  }
  const { client, mod } = await s3();
  await client.send(new mod.DeleteObjectCommand({ Bucket: bucket(), Key: key }));
}

export const readEvents = (h) => getJson(eventsKey(h));
/// Conditional on `ifMatch` when the caller read a version, create-only when it read nothing —
/// two first uploads racing can never both create.
export const writeEvents = (h, doc, { ifMatch } = {}) => putJson(eventsKey(h), doc, ifMatch ? { ifMatch } : { create: true });
export const readResults = async (h) => (await getJson(resultsKey(h)))?.doc ?? null;
/// With its ETag, for the compute job's conditional write.
export const readResultsVersioned = (h) => getJson(resultsKey(h));
/// Conditional like `writeEvents` (replace only the version read; create only if absent) — two
/// computes racing must not let the one over OLDER events land last (see `computeProfile`).
export const writeResults = (h, doc, { ifMatch } = {}) => putJson(resultsKey(h), doc, ifMatch ? { ifMatch } : { create: true });
export const deleteResults = (h) => deleteKey(resultsKey(h));

/// "Delete cloud data": both objects, each best-effort-absent.
export async function deleteProfile(h) {
  await deleteKey(eventsKey(h));
  try { await deleteKey(resultsKey(h)); } catch { /* absent or already gone */ }
}

async function listHashes(kind = 'events', stopAt = Infinity) {
  if (localDir()) {
    const dir = join(localDir(), 'pockets', kind);
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((f) => /^[0-9a-f]{64}\.json$/.test(f)).map((f) => f.slice(0, -5)).sort();
  }
  const { client, mod } = await s3();
  const re = new RegExp(`^pockets/${kind}/([0-9a-f]{64})\\.json$`);
  const hashes = []; let token;
  do {
    const out = await client.send(new mod.ListObjectsV2Command({
      Bucket: bucket(), Prefix: `pockets/${kind}/`, ContinuationToken: token, MaxKeys: 1000,
    }));
    for (const o of out.Contents || []) {
      const m = re.exec(o.Key || '');
      if (m) hashes.push(m[1]);
    }
    if (hashes.length >= stopAt) break;
    token = out.IsTruncated ? out.NextContinuationToken : undefined;
  } while (token);
  return hashes;
}

/// Every profile with an events object — the nightly job's work list.
export const listProfileHashes = () => listHashes('events');
/// Every results object — the nightly orphan sweep's work list.
export const listResultHashes = () => listHashes('results');
/// How many profiles exist, stopping at `cap`. Only the ENROLL branch calls it.
export async function countProfiles(cap) { return (await listHashes('events', cap)).length; }

// ── The stored row ──────────────────────────────────────────────────────────────────────────────

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const PLACE_RE = /^plc_[0-9a-f]{16}$/;
const TRIP_RE = /^trp_[0-9a-f]{16}$/;
export const INSTALL_RE = /^[A-Za-z0-9-]{8,64}$/;
const OUTCOMES = new Set(['completed', 'skipped', 'partial', 'unknown']);
/// skipped(3) > completed(2) > partial(1) > unknown(0): skip is MONOTONE, exactly as on the device
/// (`markSkipped` only ever goes false → true), and a finished verdict beats a partial one.
export const OUTCOME_RANK = { unknown: 0, partial: 1, completed: 2, skipped: 3 };

const jsonCost = (s) => JSON.stringify(s).length - 2;
/// Every stored string: absent/empty → null, otherwise truncated to `max` SERIALIZED bytes (the
/// rec engine's `str`: a control character costs six bytes once escaped, so a UTF-16 slice is not
/// a byte budget).
export function str(v, max = POCKET_LIMITS.maxStr) {
  if (typeof v !== 'string' || v === '') return null;
  let s = v.length > max ? v.slice(0, max) : v;
  while (s.length > 0 && jsonCost(s) > max) {
    const next = Math.min(s.length - 1, Math.max(0, Math.floor((s.length * max) / jsonCost(s))));
    s = s.slice(0, next);
  }
  const lastCode = s.charCodeAt(s.length - 1);
  if (lastCode >= 0xd800 && lastCode <= 0xdbff) s = s.slice(0, -1);
  return s === '' ? null : s;
}

/**
 * Upload ctx → stored ctx. Only opaque ids of the documented shapes survive; any other `kind`
 * token (a newer build's) — or a place/trip missing its ids — is stored as `{kind:'none'}`, the
 * same "unknown reads as no context" rule the device's lenient decode applies.
 */
export function cleanCtx(c) {
  if (c == null || typeof c !== 'object') return null;
  if (c.kind === 'place' && PLACE_RE.test(c.placeId || '')) return { kind: 'place', placeId: c.placeId };
  if (c.kind === 'trip' && TRIP_RE.test(c.tripId || '') && PLACE_RE.test(c.origin || '')) {
    return { kind: 'trip', tripId: c.tripId, origin: c.origin,
      destination: PLACE_RE.test(c.destination || '') ? c.destination : null };
  }
  return { kind: 'none' };
}

/**
 * One upload event → a stored row, or null (counted as `rejected`; the batch is never rejected for
 * one bad row). `atMs` is floored to the minute HERE too, whatever the client sent — coarse time is
 * a promise the server keeps, not one it trusts the client to keep.
 */
export function cleanEvent(e, uploaderInstallId, nowMs = Date.now()) {
  if (!e || typeof e !== 'object') return null;
  if (typeof e.id !== 'string' || !UUID_RE.test(e.id)) return null;
  const songId = str(e.songId);
  if (!songId) return null;
  if (!Number.isFinite(e.atMs) || e.atMs <= 0) return null;
  const atMs = Math.floor(e.atMs / 60_000) * 60_000;
  if (atMs > nowMs + POCKET_LIMITS.futureSkewMs) return null;
  if (atMs < nowMs - POCKET_LIMITS.retentionDays * DAY_MS) return null;
  const origin = typeof e.originInstallId === 'string' && INSTALL_RE.test(e.originInstallId) ? e.originInstallId : null;
  const fraction = Number.isFinite(e.fraction) ? Math.round(Math.min(1, Math.max(0, e.fraction)) * 1000) / 1000 : null;
  return {
    id: e.id.toUpperCase(), songId, atMs,
    ord: Number.isInteger(e.ord) && e.ord >= 0 ? Math.min(e.ord, 100_000) : 0,
    installId: origin || uploaderInstallId,
    tzOffsetMin: Number.isInteger(e.tzOffsetMin) && Math.abs(e.tzOffsetMin) <= 840 ? e.tzOffsetMin : null,
    source: str(e.source, 32),
    // An outcome token this build does not know is a play we cannot classify — `unknown`, not a
    // rejected row (the same forward-compat rule as ctx.kind).
    outcome: OUTCOMES.has(e.outcome) ? e.outcome : 'unknown',
    fraction,
    artist: str(e.artist),
    carPlay: typeof e.carPlay === 'boolean' ? e.carPlay : null,
    ctx: cleanCtx(e.ctx),
    // Collections (pockets-collections.md): the collection the play started from. Only written
    // when the client sent one, so an old client's rows keep their exact stored shape.
    ...contextOf(e),
    // Pocket Wheel (docs/design/pocket-wheel.md §5, Phase 6): the play's derived listening MODE
    // (incl. running / walking — W4, Levi 2026-10-29) and, for plays a wheel run started, the run
    // tag. Both additive: absent unless the client sent them (old rows keep their stored shape).
    ...modeOf(e),
    ...runOf(e),
  };
}

/// Modes that only the device's sensors can know (they beat the surface modes on merge).
const BODY_MODES = new Set(['running', 'walking', 'trip', 'carPlay']);
/// The Pocket Wheel modes (`PocketMode` raw values). An unknown token is dropped, never stored.
export const WHEEL_MODES = new Set(['carPlay', 'running', 'walking', 'trip', 'mix', 'browse', 'collection']);
function modeOf(e) {
  return typeof e.mode === 'string' && WHEEL_MODES.has(e.mode) ? { mode: e.mode } : {};
}

/// `{ run: { id, moment, slot, collectionId } }` for a wheel-run play, else `{}`.
function runOf(e) {
  const r = e.run;
  if (!r || typeof r !== 'object' || typeof r.id !== 'string' || !UUID_RE.test(r.id)) return {};
  const moment = typeof r.moment === 'string' && /^h\d{2}\|d[1-7]\|[A-Za-z]{2,16}$/.test(r.moment) ? r.moment : null;
  return { run: {
    id: r.id.toUpperCase(), moment,
    slot: Number.isInteger(r.slot) && r.slot > 0 ? Math.min(r.slot, 10_000) : null,
    collectionId: opaqueId(r.collectionId),
  } };
}

// ── Collections: play context, membership snapshot, add history ─────────────────────────────────
// Ids only, NEVER names: a collection id must be a short opaque token (printable ASCII, no
// whitespace, ≤ `maxIdChars`) — a display name ("Sunday Jazz") fails the no-space rule, and one that
// happens to pass is still truncated to an opaque-sized token, never echoed with a label.

const CONTEXT_KINDS = new Set(['pocket', 'playlist', 'setlist', 'source']);
const COLLECTION_KINDS = new Set(['pocket', 'playlist', 'source']);
const ADD_KINDS = new Set(['add', 'remove']);

/// A short opaque id, or null.
export function opaqueId(v, max = POCKET_LIMITS.maxIdChars) {
  return typeof v === 'string' && v.length <= max && /^[\x21-\x7E]+$/.test(v) ? v : null;
}

/// `{ contextId, contextKind }` from an upload event, or `{}`. A kind this build does not know
/// drops BOTH (a newer client's context might be something an id rule cannot vouch for).
function contextOf(e) {
  const id = opaqueId(e.contextId);
  if (!id) return {};
  if (e.contextKind != null && !CONTEXT_KINDS.has(e.contextKind)) return {};
  return { contextId: id, contextKind: CONTEXT_KINDS.has(e.contextKind) ? e.contextKind : null };
}

/**
 * Upload `collections` → the stored snapshot `{ atMs, list: [{ id, kind, songIds, adds }] }`, or
 * null when the upload carries none. Bounded by TRUNCATION exactly like the rec engine's
 * `cleanSnapshot` (≤ maxCollections, ≤ maxCollectionSongs each, ≤ maxSnapshotSongs in total);
 * duplicate collection ids keep the first; song ids deduplicated; `adds` keep only CURRENT
 * members with a sane minute-floored time (`[songId, atMs]` pairs — compact on disk).
 */
export function cleanCollections(list, atMs, nowMs = Date.now()) {
  if (!Array.isArray(list)) return null;
  const out = []; const seenIds = new Set();
  let budget = POCKET_LIMITS.maxSnapshotSongs;
  for (const c of list) {
    if (out.length >= POCKET_LIMITS.maxCollections) break;
    if (!c || typeof c !== 'object' || !Array.isArray(c.songIds)) continue;
    const id = opaqueId(c.id);
    if (!id || seenIds.has(id)) continue;
    seenIds.add(id);
    const songIds = []; const members = new Set();
    for (const x of c.songIds) {
      if (songIds.length >= POCKET_LIMITS.maxCollectionSongs || budget <= 0) break;
      const v = str(x);
      if (!v || members.has(v)) continue;
      members.add(v); songIds.push(v); budget -= 1;
    }
    const addAt = new Map();
    for (const a of Array.isArray(c.adds) ? c.adds : []) {
      if (!a || typeof a !== 'object' || !Number.isFinite(a.atMs) || a.atMs <= 0) continue;
      const songId = str(a.songId);
      if (!songId || !members.has(songId)) continue;
      const t = minuteFloor(a.atMs);
      if (t > nowMs + POCKET_LIMITS.futureSkewMs) continue;
      if (!addAt.has(songId) || t > addAt.get(songId)) addAt.set(songId, t);   // latest add wins
    }
    out.push({ id, kind: COLLECTION_KINDS.has(c.kind) ? c.kind : null, songIds,
      adds: songIds.filter((s) => addAt.has(s)).map((s) => [s, addAt.get(s)]) });
  }
  return { atMs, list: out };
}

/// Upload `addEvents` → stored rows `{ songId, collectionId, atMs, kind, installId }` (bad rows
/// dropped). `installId` is the uploader's: the add history is per device.
export function cleanAddEvents(list, uploaderInstallId, nowMs = Date.now()) {
  if (!Array.isArray(list)) return null;
  const out = [];
  const from = nowMs - POCKET_LIMITS.addRetentionDays * DAY_MS;
  for (const a of list.slice(0, POCKET_LIMITS.maxStoredAddEvents)) {
    if (!a || typeof a !== 'object' || !ADD_KINDS.has(a.kind) || !Number.isFinite(a.atMs)) continue;
    const songId = str(a.songId); const collectionId = opaqueId(a.collectionId);
    if (!songId || !collectionId) continue;
    const atMs = minuteFloor(a.atMs);
    if (atMs < from || atMs > nowMs + POCKET_LIMITS.futureSkewMs) continue;
    out.push({ songId, collectionId, atMs, kind: a.kind, installId: uploaderInstallId });
  }
  return out;
}

const addKey = (a) => `${a.songId}\u0000${a.collectionId}\u0000${a.atMs}\u0000${a.kind}`;

/**
 * Fold an upload's collection data into the events document. The snapshot is replaced WHOLESALE
 * (keep the latest: a snapshot stamped OLDER than the stored one — two devices uploading out of
 * order — is ignored); add events are UNION-merged by (songId, collectionId, atMs, kind), retention
 * `addRetentionDays`, newest `maxStoredAddEvents` kept. Neither key is created on a document whose
 * upload carries neither field, so an old client's document keeps its exact shape.
 * Returns `{ changed, collections, addEvents }` (the stored counts).
 */
export function mergeCollectionsUpload(doc, body, uploaderInstallId, nowMs = Date.now()) {
  let changed = false;
  if (Array.isArray(body?.collections)) {
    const sent = Number.isFinite(body.sentAtMs) && body.sentAtMs > 0 && body.sentAtMs <= nowMs + POCKET_LIMITS.futureSkewMs
      ? body.sentAtMs : nowMs;
    const snap = cleanCollections(body.collections, sent, nowMs);
    const cur = doc.collections;
    if (!cur || !(cur.atMs > snap.atMs)) {
      if (!cur || JSON.stringify(cur.list) !== JSON.stringify(snap.list)) changed = true;
      doc.collections = snap;
    }
  }
  if (Array.isArray(body?.addEvents)) {
    const rows = cleanAddEvents(body.addEvents, uploaderInstallId, nowMs);
    if (!Array.isArray(doc.addEvents)) doc.addEvents = [];
    const keys = new Set(doc.addEvents.map(addKey));
    for (const r of rows) {
      const k = addKey(r);
      if (keys.has(k)) continue;
      keys.add(k); doc.addEvents.push(r); changed = true;
    }
    const before = doc.addEvents.length;
    const from = nowMs - POCKET_LIMITS.addRetentionDays * DAY_MS;
    doc.addEvents = doc.addEvents.filter((a) => a.atMs >= from)
      .sort((a, b) => b.atMs - a.atMs || (addKey(a) < addKey(b) ? -1 : 1))
      .slice(0, POCKET_LIMITS.maxStoredAddEvents);
    if (doc.addEvents.length !== before) changed = true;
  }
  return { changed, collections: doc.collections?.list?.length ?? 0, addEvents: doc.addEvents?.length ?? 0 };
}

/// Upload label snapshots → stored ones (bad rows dropped, counts capped).
export function cleanLabels(places, trips) {
  const P = (Array.isArray(places) ? places : []).slice(0, POCKET_LIMITS.maxPlaces).filter((p) => p && PLACE_RE.test(p.id || ''))
    .map((p) => {
      const out = { id: p.id, rank: Number.isInteger(p.rank) && p.rank >= 1 ? p.rank : null, label: str(p.label, 32) || 'Place' };
      if (Number.isFinite(p.share)) out.share = Math.round(Math.min(1, Math.max(0, p.share)) * 1000) / 1000;
      return out;
    });
  const T = (Array.isArray(trips) ? trips : []).slice(0, POCKET_LIMITS.maxTrips)
    .filter((t) => t && TRIP_RE.test(t.id || '') && PLACE_RE.test(t.origin || ''))
    .map((t) => {
      const out = { id: t.id, origin: t.origin, destination: PLACE_RE.test(t.destination || '') ? t.destination : null,
        label: str(t.label, 32) || 'Trip' };
      if (Number.isInteger(t.occurrences) && t.occurrences >= 1) out.occurrences = t.occurrences;
      return out;
    });
  return { places: P, trips: T };
}

/// A fresh events document for a profile about to be enrolled.
/// `rev` counts content changes (bumped by every POST that changed something); with `createdAtMs`
/// (a new document after a delete is a new generation) it is what results are stamped with.
export function freshEventsDoc(nowMs = Date.now()) {
  return { v: 1, keyHash: null, createdAtMs: nowMs, updatedAtMs: nowMs, rev: 0, dirty: false,
    labels: { places: [], trips: [], atMs: null }, events: [] };
}

/**
 * Fold cleaned rows into a document, PER EVENT ID, idempotent and order-independent:
 *   new id      → insert (atMs, ord, songId, installId are immutable from here on)
 *   existing id → outcome = max rank · fraction = max · ctx: a null ctx adopts the incoming one,
 *                 a non-null ctx is kept · tzOffsetMin / artist / carPlay / source: existing ?? incoming
 * Then retention (180 d) and the row cap (oldest first). Returns the counts the POST answers with;
 * `changed` is whether anything at all moved (an identical re-upload changes nothing).
 */
export function mergeEvents(doc, rows, nowMs = Date.now()) {
  const byId = new Map(doc.events.map((e, i) => [e.id, i]));
  let accepted = 0; let updated = 0; let unchanged = 0;
  for (const r of rows) {
    const i = byId.get(r.id);
    if (i === undefined) {
      byId.set(r.id, doc.events.length);
      doc.events.push(r);
      accepted += 1;
      continue;
    }
    const cur = doc.events[i];
    let changed = false;
    const set = (k, v) => { if (cur[k] !== v) { cur[k] = v; changed = true; } };
    if ((OUTCOME_RANK[r.outcome] ?? 0) > (OUTCOME_RANK[cur.outcome] ?? 0)) set('outcome', r.outcome);
    if (r.fraction != null && (cur.fraction == null || r.fraction > cur.fraction)) set('fraction', r.fraction);
    if (cur.ctx == null && r.ctx != null) { cur.ctx = r.ctx; changed = true; }
    for (const k of ['tzOffsetMin', 'artist', 'carPlay', 'source', 'contextId', 'contextKind']) if (cur[k] == null && r[k] != null) set(k, r[k]);
    // Pocket Wheel: a body/vehicle mode (settled later from CoreMotion / the trip engine) upgrades
    // a surface mode; never the reverse. The run tag is write-once.
    if (r.mode != null && (cur.mode == null || (BODY_MODES.has(r.mode) && !BODY_MODES.has(cur.mode)))) set('mode', r.mode);
    if (cur.run == null && r.run != null) { cur.run = r.run; changed = true; }
    if (changed) updated += 1; else unchanged += 1;
  }
  const evicted = applyRetention(doc, nowMs);
  return { accepted, updated, unchanged, evicted, changed: accepted + updated + evicted > 0 };
}

/// Drop rows past the retention window, then cap the count (oldest first), then shed oldest rows
/// until the serialized document fits the byte budget — never refuse a write, or the profile wedges
/// (the rec engine's `shedToFit` lesson).
export function applyRetention(doc, nowMs = Date.now()) {
  const before = doc.events.length;
  const from = nowMs - POCKET_LIMITS.retentionDays * DAY_MS;
  doc.events = doc.events.filter((e) => e.atMs >= from);
  doc.events.sort((a, b) => a.atMs - b.atMs || (a.ord ?? 0) - (b.ord ?? 0) || (a.id < b.id ? -1 : 1));
  if (doc.events.length > POCKET_LIMITS.maxStoredEvents) doc.events.splice(0, doc.events.length - POCKET_LIMITS.maxStoredEvents);
  for (let guard = 0; guard < 200 && doc.events.length
       && Buffer.byteLength(JSON.stringify(doc), 'utf8') > POCKET_LIMITS.maxStateBytes; guard++) {
    doc.events.splice(0, Math.max(1, Math.ceil(doc.events.length / 8)));
  }
  return before - doc.events.length;
}

// ── "In the Pocket" rounds ──────────────────────────────────────────────────────────────────────
// A round is the game's PREDICTION (3–4 songs the scorer expected to play through without a skip,
// in a stated context, from stated targets) plus what actually happened and the player's optional
// rating / free-text feedback. Rounds live in the SAME events document (`doc.rounds`) as the plays,
// so they share its TOFU key binding, its dirty/rev bookkeeping (a new round recomputes), its
// retention, and `DELETE /state`. The array is only created when the first round arrives — a
// profile that never played keeps the exact document shape it had before the game existed.

const ROUND_OUTCOMES = new Set(['pocket', 'broke', 'abandoned']);
const SONG_OUTCOMES = new Set(['completed', 'skipped', 'partial', 'unknown', 'notPlayed']);
const ROUND_MODES = new Set(['cloud', 'history', 'cold']);
const DAY_TYPES = new Set(['weekday', 'weekend']);
const TARGET_DIMS = new Set(['artist', 'genre', 'mood', 'camelot', 'bpm', 'energy', 'year',
  'timeBucket', 'dayType', 'dow', 'source', 'place', 'trip', 'carPlay', 'song', 'collection']);

/// Free text, capped in UTF-16 code units (never splitting a surrogate pair), control characters
/// other than newline/tab stripped. Empty after trimming → null.
export function capText(v, max = POCKET_LIMITS.maxFeedbackChars) {
  if (typeof v !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  let s = v.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim();
  if (s.length > max) {
    s = s.slice(0, max);
    const last = s.charCodeAt(s.length - 1);
    if (last >= 0xd800 && last <= 0xdbff) s = s.slice(0, -1);
  }
  return s === '' ? null : s;
}

const finiteOr = (x, d = null) => (Number.isFinite(x) ? x : d);
const minuteFloor = (ms) => Math.floor(ms / 60_000) * 60_000;

/**
 * One uploaded round → the stored row, or null (counted as `rejected`). Like `cleanEvent`, time is
 * floored to the minute here whatever the client sent, every string is bounded, unknown tokens in
 * optional fields degrade instead of rejecting the round — but a round with no songs, no id, or an
 * outcome this build does not know is not a label and is rejected.
 */
export function cleanRound(r, uploaderInstallId, nowMs = Date.now()) {
  if (!r || typeof r !== 'object') return null;
  if (typeof r.id !== 'string' || !UUID_RE.test(r.id)) return null;
  if (!ROUND_OUTCOMES.has(r.outcome)) return null;
  if (!Number.isFinite(r.startedAtMs) || r.startedAtMs <= 0) return null;
  const startedAtMs = minuteFloor(r.startedAtMs);
  if (startedAtMs > nowMs + POCKET_LIMITS.futureSkewMs) return null;
  if (startedAtMs < nowMs - POCKET_LIMITS.retentionDays * DAY_MS) return null;
  const songsIn = Array.isArray(r.songs) ? r.songs.slice(0, POCKET_LIMITS.maxRoundSongs) : [];
  const songs = [];
  for (const s of songsIn) {
    if (!s || typeof s !== 'object') continue;
    const songId = str(s.songId);
    if (!songId) continue;
    const fraction = Number.isFinite(s.fraction) ? Math.round(Math.min(1, Math.max(0, s.fraction)) * 1000) / 1000 : null;
    songs.push({
      songId, artist: str(s.artist),
      score: Number.isFinite(s.score) ? Math.round(s.score * 1000) / 1000 : null,
      outcome: SONG_OUTCOMES.has(s.outcome) ? s.outcome : 'unknown',
      fraction,
    });
  }
  if (songs.length === 0) return null;
  const c = r.context && typeof r.context === 'object' ? r.context : {};
  const bucketNames = new Set(POCKET_PARAMS.timeBuckets.map((b) => b[0]));
  const context = {
    timeBucket: bucketNames.has(c.timeBucket) ? c.timeBucket : null,
    dayType: DAY_TYPES.has(c.dayType) ? c.dayType : null,
    dow: Number.isInteger(c.dow) && c.dow >= 0 && c.dow <= 6 ? c.dow : null,
    ctx: cleanCtx(c.ctx),
  };
  const targets = (Array.isArray(r.targets) ? r.targets : []).slice(0, POCKET_LIMITS.maxRoundTargets)
    .filter((t) => t && TARGET_DIMS.has(t.dim) && str(t.value, 64))
    .map((t) => ({ dim: t.dim, value: str(t.value, 64),
      weight: Number.isFinite(t.weight) ? Math.round(t.weight * 1000) / 1000 : null }));
  const brokeAt = r.outcome === 'broke' && Number.isInteger(r.brokeAt) && r.brokeAt >= 1 && r.brokeAt <= songs.length
    ? r.brokeAt : null;
  if (r.outcome === 'broke' && brokeAt == null) return null;   // a break with no position is not a label
  const ended = Number.isFinite(r.endedAtMs) && r.endedAtMs >= startedAtMs ? minuteFloor(r.endedAtMs) : null;
  return {
    id: r.id.toUpperCase(),
    installId: typeof r.originInstallId === 'string' && INSTALL_RE.test(r.originInstallId) ? r.originInstallId : uploaderInstallId,
    startedAtMs, endedAtMs: ended,
    updatedAtMs: Math.min(finiteOr(r.updatedAtMs, startedAtMs), nowMs + POCKET_LIMITS.futureSkewMs),
    tzOffsetMin: Number.isInteger(r.tzOffsetMin) && Math.abs(r.tzOffsetMin) <= 840 ? r.tzOffsetMin : null,
    context,
    mode: ROUND_MODES.has(r.mode) ? r.mode : null,
    seed: str(r.seed, 32),
    algoVersion: Number.isInteger(r.algoVersion) ? r.algoVersion : null,
    targets,
    songs,
    outcome: r.outcome,
    brokeAt,
    rating: Number.isInteger(r.rating) && r.rating >= 1 && r.rating <= 5 ? r.rating : null,
    feedback: capText(r.feedback),
    appVersion: str(r.appVersion, 32),
  };
}

/**
 * Fold cleaned rounds into a document, PER ROUND ID. A round is mutable on the device (feedback and
 * a rating can be added after it ends), so the row with the newer `updatedAtMs` REPLACES the stored
 * one whole; an equal-or-older re-send changes nothing. Then retention (`retentionDays`) and the
 * `maxStoredRounds` cap, oldest first. Returns the counts the POST answers with.
 */
export function mergeRounds(doc, rows, nowMs = Date.now()) {
  if (!Array.isArray(doc.rounds)) doc.rounds = [];
  const byId = new Map(doc.rounds.map((r, i) => [r.id, i]));
  let accepted = 0; let updated = 0; let unchanged = 0;
  for (const r of rows) {
    const i = byId.get(r.id);
    if (i === undefined) {
      byId.set(r.id, doc.rounds.length);
      doc.rounds.push(r);
      accepted += 1;
      continue;
    }
    const cur = doc.rounds[i];
    if ((r.updatedAtMs ?? 0) > (cur.updatedAtMs ?? 0) && JSON.stringify({ ...r, updatedAtMs: 0 }) !== JSON.stringify({ ...cur, updatedAtMs: 0 })) {
      doc.rounds[i] = r;
      updated += 1;
    } else {
      unchanged += 1;
    }
  }
  const before = doc.rounds.length;
  const from = nowMs - POCKET_LIMITS.retentionDays * DAY_MS;
  doc.rounds = doc.rounds.filter((r) => r.startedAtMs >= from)
    .sort((a, b) => a.startedAtMs - b.startedAtMs || (a.id < b.id ? -1 : 1));
  if (doc.rounds.length > POCKET_LIMITS.maxStoredRounds) doc.rounds.splice(0, doc.rounds.length - POCKET_LIMITS.maxStoredRounds);
  const evicted = before - doc.rounds.length;
  return { accepted, updated, unchanged, evicted, changed: accepted + updated + evicted > 0 };
}
