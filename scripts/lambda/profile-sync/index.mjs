// PocketDJ profile-sync Lambda — the HTTP API behind Android's S3CloudDocDatabase (SVC-9).
// iOS syncs whole-document LWW through CloudKit; Android has no CloudKit, so the same
// CloudDocDatabase contract (meta / fetch / save / delete / deleteAll) is served from a PRIVATE
// S3 bucket through this function. Design + contract: docs/design/profile-sync-s3.md.
//
// Routes (API Gateway HTTP API $default catch-all -> rawPath):
//   GET    /health                       -> { ok:true }                          (no auth)
//   POST   /enroll                       -> 200 { ok, created } | 401 | 409      (X-PocketDJ-Enroll)
//   GET    /meta[?keys=a,b]              -> { key: modifiedAtMs } (existing keys only)
//   GET    /doc/{key}                    -> raw body + X-PocketDJ-Modified-At | 404
//   PUT    /doc/{key}                    -> 200 { ok, key, modifiedAtMs }
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

const KEY_RE = /^[a-z0-9-]{1,40}$/;
const PROFILE_RE = /^[a-z0-9-]{1,64}$/;
const HASH_RE = /^[a-f0-9]{64}$/;
const MAX_BODY_BYTES = 5 * 1024 * 1024; // API Gateway/Lambda payload cap is 6 MB
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
        return { body: await r.Body.transformToString(), meta: r.Metadata || {} };
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
  const existing = await s.get(objKey(profileId, AUTH_KEY));
  if (existing) {
    let prev = '';
    try { prev = JSON.parse(existing.body).secretHash; } catch { /* corrupt => treated as mismatch */ }
    return safeEq(prev, secretHash) ? json(200, { ok: true, created: false }) : json(409, { error: 'profile already enrolled' });
  }
  const cap = parseInt(process.env.MAX_PROFILES || '0', 10);
  if (cap > 0) {
    const n = (await s.list('profiles/')).filter((k) => k.endsWith(`/${AUTH_KEY}.json`)).length;
    if (n >= cap) return json(429, { error: 'enrollment cap reached' });
  }
  await s.put(objKey(profileId, AUTH_KEY), JSON.stringify({ secretHash, createdAtMs: Date.now() }), {});
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

async function getDoc(profileId, key) {
  const r = await (await store()).get(objKey(profileId, key));
  if (!r) return json(404, { error: 'not found' });
  return {
    statusCode: 200,
    headers: {
      'content-type': 'application/json', 'cache-control': 'no-store',
      'x-pocketdj-modified-at': String(Number(r.meta['modified-at-ms']) || 0),
    },
    body: r.body,
  };
}

async function putDoc(event, profileId, key) {
  const body = bodyOf(event);
  if (!body) return json(400, { error: 'empty body' });
  if (Buffer.byteLength(body) > MAX_BODY_BYTES) return json(413, { error: 'too large' });
  try { JSON.parse(body); } catch { return json(400, { error: 'body must be json' }); }
  const raw = hdr(event, 'x-pocketdj-modified-at');
  const parsed = /^\d{1,15}$/.test(raw) ? Number(raw) : NaN;
  const modifiedAtMs = Number.isFinite(parsed) ? parsed : Date.now();
  const device = hdr(event, 'x-pocketdj-device').replace(/[^\x20-\x7e]/g, '').slice(0, 100);
  await (await store()).put(objKey(profileId, key), body, { 'modified-at-ms': String(modifiedAtMs), device });
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
      const key = decodeURIComponent(doc[1]);
      if (!KEY_RE.test(key)) return json(400, { error: 'bad key' });
      if (method === 'GET') return await getDoc(profileId, key);
      if (method === 'PUT') return await putDoc(event, profileId, key);
      if (method === 'DELETE') { await (await store()).del(objKey(profileId, key)); return json(200, { ok: true }); }
    }
    return json(405, { error: 'method not allowed' });
  } catch (e) {
    console.error('profile-sync error', e);
    return json(500, { error: 'internal' });
  }
}
