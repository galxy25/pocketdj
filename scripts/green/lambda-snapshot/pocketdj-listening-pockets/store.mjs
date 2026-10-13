// LISTENING POCKETS — STORAGE. Two objects per profile in the rec-engine bucket, under its own
// `pockets/` prefix (the function's IAM role reaches nothing else):
//
//   pockets/events/<sha256(profileId)>.json   the stored play rows + TOFU keyHash + dirty flag
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
import { POCKET_LIMITS } from './params.mjs';

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
  };
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
    for (const k of ['tzOffsetMin', 'artist', 'carPlay', 'source']) if (cur[k] == null && r[k] != null) set(k, r[k]);
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
