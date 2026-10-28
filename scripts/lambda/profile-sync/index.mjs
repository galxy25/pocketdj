// PocketDJ profile-sync Lambda — the HTTP API behind Android's S3CloudDocDatabase (SVC-9).
// iOS syncs whole-document LWW through CloudKit; Android has no CloudKit, so the same
// CloudDocDatabase contract (meta / fetch / save / delete / deleteAll) is served from a PRIVATE
// S3 bucket through this function. Design + contract: docs/design/profile-sync-s3.md.
//
// Routes (API Gateway HTTP API $default catch-all -> rawPath):
//   GET    /health                       -> { ok:true }                          (no auth)
//   POST   /enroll                       -> 200 { ok, created } | 401 | 409      (X-PocketDJ-Enroll)
//   GET    /meta[?keys=a,b]              -> { key: modifiedAtMs } (existing keys only)
//   GET    /doc/{key}                    -> raw body + X-PocketDJ-Modified-At/-Device | 404
//                                           (Accept-Encoding: gzip => stored gzip bytes passed through)
//   PUT    /doc/{key}                    -> 200 { ok, key, modifiedAtMs }  (Content-Encoding: gzip accepted)
//   DELETE /doc/{key}                    -> 200 { ok:true }  (idempotent)
//   DELETE /profile                      -> 200 { ok:true, deleted:n }  (wipes the whole prefix)
// Every route except /health and /enroll needs `X-PocketDJ-Profile: <profileId>` and
// `Authorization: Bearer <secret>`; the server stores only SHA-256(secret).
//
// S3 layout: profiles/<profileId>/_auth.json  ({secretHash, createdAtMs})
//            profiles/<profileId>/<key>.json  (body; metadata modified-at-ms, device)
// Env: PROFILE_BUCKET, ENROLL_SECRET (capability token, read per request; unset = fail closed),
//      MAX_PROFILES (optional enroll cap, read per request; 0/unset = unlimited).

import { createHash, timingSafeEqual } from 'node:crypto';
import { gunzipSync } from 'node:zlib';

const KEY_RE = /^[a-z0-9-]{1,40}$/;
const PROFILE_RE = /^[a-z0-9-]{1,64}$/;
const HASH_RE = /^[a-f0-9]{64}$/;
// Cap on the bytes that cross API Gateway/Lambda (6 MB hard limit; base64 inflates binary by 4/3, so a
// gzip body is capped on its WIRE size = 4 MB). Plain JSON bodies are capped at 5 MB. Clients with a
// bigger doc (iOS collections is ~4 MB and growing) MUST send `Content-Encoding: gzip` (JSON ~10:1).
const MAX_BODY_BYTES = 5 * 1024 * 1024;
const MAX_GZIP_WIRE_BYTES = 4 * 1024 * 1024;
const MAX_INFLATED_BYTES = 128 * 1024 * 1024; // decompression-bomb guard
const AUTH_KEY = '_auth';

// ── Store abstraction (S3 in prod, in-memory in tests) ──────────────────────────────────────────
let _store = null;
export function setStore(s) { _store = s; }

async function s3Store() {
  const mod = await import('@aws-sdk/client-s3');
  const { S3Client, GetObjectCommand, HeadObjectCommand, PutObjectCommand, DeleteObjectCommand, ListObjectsV2Command } = mod;
  const client = new S3Client({ region: process.env.AWS_REGION || 'us-west-2' });
  const Bucket = () => process.env.PROFILE_BUCKET;
  const missing = (e) => e && (e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404);
  return {
    async get(k) {
      try {
        const r = await client.send(new GetObjectCommand({ Bucket: Bucket(), Key: k }));
        const meta = r.Metadata || {};
        const bytes = await r.Body.transformToByteArray();
        return { body: meta.encoding === 'gzip' ? Buffer.from(bytes) : Buffer.from(bytes).toString('utf8'), meta };
      } catch (e) { if (missing(e)) return null; throw e; }
    },
    async head(k) {
      try {
        const r = await client.send(new HeadObjectCommand({ Bucket: Bucket(), Key: k }));
        return { meta: r.Metadata || {} };
      } catch (e) { if (missing(e)) return null; throw e; }
    },
    async put(k, body, meta) {
      await client.send(new PutObjectCommand({
        Bucket: Bucket(), Key: k, Body: body, ContentType: 'application/json', Metadata: meta,
      }));
    },
    /** Create-only put; resolves false when the key already exists (412). */
    async putIfAbsent(k, body, meta) {
      try {
        await client.send(new PutObjectCommand({
          Bucket: Bucket(), Key: k, Body: body, ContentType: 'application/json', Metadata: meta, IfNoneMatch: '*',
        }));
        return true;
      } catch (e) { if (e.$metadata?.httpStatusCode === 412 || e.name === 'PreconditionFailed') return false; throw e; }
    },
    async del(k) { await client.send(new DeleteObjectCommand({ Bucket: Bucket(), Key: k })); },
    async list(prefix) {
      const out = []; let token;
      do {
        const r = await client.send(new ListObjectsV2Command({ Bucket: Bucket(), Prefix: prefix, ContinuationToken: token }));
        for (const o of r.Contents || []) out.push(o.Key);
        token = r.IsTruncated ? r.NextContinuationToken : undefined;
      } while (token);
      return out;
    },
  };
}
async function store() { return (_store ??= await s3Store()); }

// ── helpers ─────────────────────────────────────────────────────────────────────────────────────
const json = (status, obj, extra = {}) => ({
  statusCode: status,
  headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra },
  body: JSON.stringify(obj),
});
const sha256hex = (s) => createHash('sha256').update(s).digest('hex');
function safeEq(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}
function hdr(event, name) {
  const h = event.headers || {};
  for (const k of Object.keys(h)) if (k.toLowerCase() === name) return String(h[k]);
  return '';
}
const prefixOf = (profileId) => `profiles/${profileId}/`;
const objKey = (profileId, key) => `${prefixOf(profileId)}${key}.json`;

export function enrollOk(event) {
  const want = process.env.ENROLL_SECRET || '';
  if (!want) return false; // fail closed
  return safeEq(hdr(event, 'x-pocketdj-enroll'), want);
}

/** Resolve + verify the caller. Returns the profileId or null (=> 401). */
async function authenticate(event) {
  const profileId = hdr(event, 'x-pocketdj-profile').toLowerCase();
  const m = /^Bearer\s+(.+)$/i.exec(hdr(event, 'authorization').trim());
  if (!PROFILE_RE.test(profileId) || !m) return null;
  const s = await store();
  const rec = await s.get(objKey(profileId, AUTH_KEY));
  if (!rec) return null;
  let stored;
  try { stored = JSON.parse(rec.body).secretHash; } catch { return null; }
  if (typeof stored !== 'string' || !HASH_RE.test(stored)) return null;
  return safeEq(sha256hex(m[1].trim()), stored) ? profileId : null;
}

const isGzip = (event) => hdr(event, 'content-encoding').toLowerCase() === 'gzip';
/** Raw request bytes (base64-decoded when API Gateway encoded them). */
function rawBytes(event) {
  const raw = event.body ?? '';
  return Buffer.from(raw, event.isBase64Encoded ? 'base64' : 'utf8');
}

function bodyOf(event) {
  const raw = event.body ?? '';
  return event.isBase64Encoded ? Buffer.from(raw, 'base64').toString('utf8') : raw;
}

// ── routes ──────────────────────────────────────────────────────────────────────────────────────
async function enroll(event) {
  if (!enrollOk(event)) return json(401, { error: 'unauthorized' });
  let b;
  try { b = JSON.parse(bodyOf(event) || '{}'); } catch { return json(400, { error: 'bad json' }); }
  const profileId = typeof b.profileId === 'string' ? b.profileId.toLowerCase() : '';
  const secretHash = typeof b.secretHash === 'string' ? b.secretHash.toLowerCase() : '';
  if (!PROFILE_RE.test(profileId) || !HASH_RE.test(secretHash)) return json(400, { error: 'bad profileId/secretHash' });
  const s = await store();
  const sameOrConflict = (rec) => {
    let prev = '';
    try { prev = JSON.parse(rec.body).secretHash; } catch { /* corrupt => treated as mismatch */ }
    return safeEq(prev, secretHash) ? json(200, { ok: true, created: false }) : json(409, { error: 'profile already enrolled' });
  };
  const existing = await s.get(objKey(profileId, AUTH_KEY));
  if (existing) return sameOrConflict(existing);
  const cap = parseInt(process.env.MAX_PROFILES || '0', 10);
  if (cap > 0) {
    const n = (await s.list('profiles/')).filter((k) => k.endsWith(`/${AUTH_KEY}.json`)).length;
    if (n >= cap) { console.warn(`profile-sync: enrollment cap reached (${n}/${cap})`); return json(429, { error: 'enrollment cap reached' }); }
    if (n >= cap * 0.8) console.warn(`profile-sync: enrollment cap nearly reached (${n}/${cap})`);
  }
  // Atomic create: a racing enroll of the same new profileId cannot overwrite the first writer.
  const created = await s.putIfAbsent(objKey(profileId, AUTH_KEY), JSON.stringify({ secretHash, createdAtMs: Date.now() }), {});
  if (!created) {
    const winner = await s.get(objKey(profileId, AUTH_KEY));
    return winner ? sameOrConflict(winner) : json(409, { error: 'profile already enrolled' });
  }
  return json(200, { ok: true, created: true });
}

async function meta(event, profileId) {
  const s = await store();
  const qs = event.queryStringParameters?.keys;
  let keys;
  if (qs !== undefined && qs !== '') {
    keys = qs.split(',').map((k) => k.trim()).filter(Boolean);
    if (keys.some((k) => !KEY_RE.test(k))) return json(400, { error: 'bad key' });
  } else {
    const pre = prefixOf(profileId);
    keys = (await s.list(pre))
      .map((k) => k.slice(pre.length))
      .filter((k) => k.endsWith('.json'))
      .map((k) => k.slice(0, -5))
      .filter((k) => KEY_RE.test(k)); // drops _auth
  }
  const out = {};
  await Promise.all(keys.map(async (k) => {
    const h = await s.head(objKey(profileId, k));
    if (!h) return;
    const ms = Number(h.meta['modified-at-ms']);
    out[k] = Number.isFinite(ms) ? ms : 0;
  }));
  return json(200, out);
}

async function getDoc(event, profileId, key) {
  const r = await (await store()).get(objKey(profileId, key));
  if (!r) return json(404, { error: 'not found' });
  const headers = {
    'content-type': 'application/json', 'cache-control': 'no-store',
    'x-pocketdj-modified-at': String(Number(r.meta['modified-at-ms']) || 0),
    'x-pocketdj-device': r.meta.device || '',
  };
  if (r.meta.encoding === 'gzip') {
    const buf = Buffer.isBuffer(r.body) ? r.body : Buffer.from(r.body, 'binary');
    // Hand the gzip bytes straight through when the client accepts them (keeps big docs under the 6 MB
    // response cap); otherwise inflate.
    if (/\bgzip\b/i.test(hdr(event, 'accept-encoding'))) {
      return { statusCode: 200, headers: { ...headers, 'content-encoding': 'gzip' }, body: buf.toString('base64'), isBase64Encoded: true };
    }
    return { statusCode: 200, headers, body: gunzipSync(buf).toString('utf8') };
  }
  return { statusCode: 200, headers, body: r.body };
}

async function putDoc(event, profileId, key) {
  let body, stored, meta = {};
  if (isGzip(event)) {
    const bytes = rawBytes(event);
    if (!bytes.length) return json(400, { error: 'empty body' });
    if (bytes.length > MAX_GZIP_WIRE_BYTES) return json(413, { error: 'too large' });
    try { body = gunzipSync(bytes, { maxOutputLength: MAX_INFLATED_BYTES }).toString('utf8'); }
    catch (e) { return json(e?.code === 'ERR_BUFFER_TOO_LARGE' ? 413 : 400, { error: 'bad gzip body' }); }
    stored = bytes; meta.encoding = 'gzip';
  } else {
    body = bodyOf(event);
    if (!body) return json(400, { error: 'empty body' });
    if (Buffer.byteLength(body) > MAX_BODY_BYTES) return json(413, { error: 'too large' });
    stored = body;
  }
  try { JSON.parse(body); } catch { return json(400, { error: 'body must be json' }); }
  // Present-but-malformed => 400 (never silently substitute server time into the LWW clock).
  // Accepts any finite non-negative decimal incl. fractional / exponent forms (Double.toString), rounded.
  const raw = hdr(event, 'x-pocketdj-modified-at').trim();
  let modifiedAtMs;
  if (raw === '') modifiedAtMs = Date.now();
  else {
    const n = /^[0-9.eE+]+$/.test(raw) ? Number(raw) : NaN;
    if (!Number.isFinite(n) || n < 0 || n > 1e15) return json(400, { error: 'bad X-PocketDJ-Modified-At' });
    modifiedAtMs = Math.round(n);
  }
  const device = hdr(event, 'x-pocketdj-device').replace(/[^\x20-\x7e]/g, '').slice(0, 100);
  await (await store()).put(objKey(profileId, key), stored, { 'modified-at-ms': String(modifiedAtMs), device, ...meta });
  return json(200, { ok: true, key, modifiedAtMs });
}

async function wipe(profileId) {
  const s = await store();
  const keys = await s.list(prefixOf(profileId));
  // _auth last, so a partial failure leaves the caller able to retry.
  const ordered = keys.filter((k) => !k.endsWith(`/${AUTH_KEY}.json`)).concat(keys.filter((k) => k.endsWith(`/${AUTH_KEY}.json`)));
  for (const k of ordered) await s.del(k);
  return json(200, { ok: true, deleted: keys.length });
}

export async function handler(event) {
  try {
    const method = (event.requestContext?.http?.method || event.httpMethod || 'GET').toUpperCase();
    const path = (event.rawPath || event.path || '/').replace(/\/+$/, '') || '/';
    if (path === '/health' && method === 'GET') return json(200, { ok: true });
    if (path === '/enroll' && method === 'POST') return await enroll(event);

    const doc = /^\/doc\/([^/]*)$/.exec(path);
    const known = path === '/meta' || path === '/profile' || doc;
    if (!known) return json(404, { error: 'not found' });

    const profileId = await authenticate(event);
    if (!profileId) return json(401, { error: 'unauthorized' });

    if (path === '/meta' && method === 'GET') return await meta(event, profileId);
    if (path === '/profile' && method === 'DELETE') return await wipe(profileId);
    if (doc) {
      let key;
      try { key = decodeURIComponent(doc[1]); } catch { return json(400, { error: 'bad key' }); }
      if (!KEY_RE.test(key)) return json(400, { error: 'bad key' });
      if (method === 'GET') return await getDoc(event, profileId, key);
      if (method === 'PUT') return await putDoc(event, profileId, key);
      if (method === 'DELETE') { await (await store()).del(objKey(profileId, key)); return json(200, { ok: true }); }
    }
    return json(405, { error: 'method not allowed' });
  } catch (e) {
    console.error('profile-sync error', e);
    return json(500, { error: 'internal' });
  }
}
