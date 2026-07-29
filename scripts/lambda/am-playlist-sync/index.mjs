// PocketDJ Apple Music playlist-sync Lambda — the server half of WS2 (bidirectional PocketDJ <->
// Apple Music library-playlist sync), replacing the iMac/Tailscale path with an on-demand AWS
// endpoint (API Gateway HTTP API -> this Lambda).
//
// ── ASYNC JOB + POLL (why) ──────────────────────────────────────────────────────────────────────
// Pulling a real library (100+ playlists, each needing a tracks fetch) is >100 sequential Apple
// Music calls and easily exceeds API Gateway's HARD 30s integration timeout -> a 503 to the client.
// So the API-facing calls are FAST: POST /pull|/push writes a "pending" job to S3, ASYNC self-invokes
// the Lambda (InvocationType Event) to do the long work, and returns { jobId } immediately. The
// worker invocation (no API Gateway timeout — bounded only by the Lambda timeout, 300s) does the
// full pull/push and writes the result to S3. The client POLLS GET /job/{jobId} until done.
//
// ── The two-token model ─────────────────────────────────────────────────────────────────────────
// A per-user Apple Music library call needs an app-wide DEVELOPER token (ES256 JWT this Lambda mints
// from the MusicKit .p8 in Secrets Manager) AND a per-user MUSIC-USER-TOKEN (minted on-device, sent
// per request, NEVER stored — it rides in the job payload only for the worker's lifetime). The
// Music-User-Token is the per-user gate: Apple rejects any /v1/me call without a valid one.
//
// ── What the server can/can't do (Apple Music Web API) ──────────────────────────────────────────
// Library playlists are CREATE + APPEND only. Reorder/remove happen on-device (MusicLibrary.edit).
//
// Routes (API Gateway HTTP API $default catch-all -> rawPath):
//   GET  /musickit-token          -> { token, expiresAt }               (developer token for the client)
//   POST /pull   { musicUserToken } -> 202 { jobId }
//   POST /push   { musicUserToken, playlists:[{name,description?,trackCatalogIds}] } -> 202 { jobId }
//   GET  /job/{jobId}             -> { status:'pending'|'done'|'error', result?, error? }
//   GET  /health                  -> { ok:true }
//
// Result store: a PRIVATE S3 bucket (JOBS_BUCKET), key am-sync-jobs/<jobId>.json, read only via this
// Lambda (GET /job) so the user's playlist data never leaves through a public object. jobIds are
// UUIDs (unguessable); a lifecycle rule expires the prefix after a day.

import { createPrivateKey, sign as cryptoSign, randomUUID } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { LambdaClient, InvokeCommand } from '@aws-sdk/client-lambda';

const AM = 'https://api.music.apple.com';
const SECRET_ID = process.env.SECRET_ID || 'pocketdj/am-playlist-sync';
const REGION = process.env.AWS_REGION || 'us-west-2';
const JOBS_BUCKET = process.env.JOBS_BUCKET;
const SELF_FUNCTION = process.env.AWS_LAMBDA_FUNCTION_NAME;

const sm = new SecretsManagerClient({ region: REGION });
const s3 = new S3Client({ region: REGION });
const lambda = new LambdaClient({ region: REGION });

// ── Secret + developer-token caching (survives warm invocations) ────────────────────────────────
let _secret = null;
let _devToken = null;

async function loadSecret() {
  if (_secret) return _secret;
  const out = await sm.send(new GetSecretValueCommand({ SecretId: SECRET_ID }));
  const s = JSON.parse(out.SecretString);
  if (!s.p8 || !s.kid || !s.team) throw new Error('secret missing p8/kid/team');
  _secret = { ttlSec: 150 * 24 * 3600, ...s };
  return _secret;
}

function b64url(input) {
  return Buffer.from(input).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

async function mintDeveloperToken() {
  const now = Math.floor(Date.now() / 1000);
  if (_devToken && _devToken.exp - now > 7 * 24 * 3600) return _devToken;
  const { p8, kid, team, ttlSec } = await loadSecret();
  const exp = now + ttlSec;
  const header = { alg: 'ES256', kid, typ: 'JWT' };
  const payload = { iss: team, iat: now, exp };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = createPrivateKey(p8);
  const sig = cryptoSign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' });
  _devToken = { token: `${signingInput}.${b64url(sig)}`, exp };
  return _devToken;
}

// ── Apple Music request helper ──────────────────────────────────────────────────────────────────
async function am(method, path, { devToken, userToken, body } = {}) {
  const headers = { Authorization: `Bearer ${devToken}` };
  if (userToken) headers['Music-User-Token'] = userToken;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${AM}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 204s + some errors have no JSON body */ }
  if (!res.ok) {
    const err = new Error(`AM ${method} ${path} -> ${res.status}`);
    err.status = res.status; err.body = json || text;
    throw err;
  }
  return json;
}

async function getStorefront(devToken, userToken) {
  const r = await am('GET', '/v1/me/storefront', { devToken, userToken });
  return r?.data?.[0]?.id || 'us';
}

async function pull(devToken, userToken) {
  const storefront = await getStorefront(devToken, userToken);
  const playlists = [];
  let next = '/v1/me/library/playlists?limit=100';
  while (next) {
    const page = await am('GET', next, { devToken, userToken });
    for (const pl of page?.data || []) {
      const attrs = pl.attributes || {};
      const tracks = await pullTracks(devToken, userToken, pl.id);
      playlists.push({
        id: pl.id,
        name: attrs.name || '(untitled)',
        canEdit: attrs.canEdit ?? false,
        description: attrs.description?.standard,
        trackCatalogIds: tracks.map((t) => t.catalogId).filter(Boolean),
        trackTitles: tracks.map((t) => t.title),
      });
    }
    next = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
  }
  return { storefront, playlists };
}

async function pullTracks(devToken, userToken, playlistId) {
  const out = [];
  let next = `/v1/me/library/playlists/${encodeURIComponent(playlistId)}/tracks?limit=100`;
  while (next) {
    let page;
    try {
      page = await am('GET', next, { devToken, userToken });
    } catch (e) {
      if (e.status === 404) break; // empty playlist -> 404 on tracks
      throw e;
    }
    for (const t of page?.data || []) {
      const attrs = t.attributes || {};
      const catalogId = attrs.playParams?.catalogId || attrs.playParams?.id || null;
      out.push({ catalogId, title: attrs.name || '' });
    }
    next = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
  }
  return out;
}

async function push(devToken, userToken, incoming) {
  const created = [];
  const errors = [];
  for (const pl of incoming || []) {
    try {
      const trackData = (pl.trackCatalogIds || [])
        .filter(Boolean)
        .map((id) => ({ id: String(id), type: 'songs' }));
      const body = {
        attributes: { name: pl.name, ...(pl.description ? { description: pl.description } : {}) },
        ...(trackData.length ? { relationships: { tracks: { data: trackData } } } : {}),
      };
      const res = await am('POST', '/v1/me/library/playlists', { devToken, userToken, body });
      created.push({ name: pl.name, id: res?.data?.[0]?.id || null });
    } catch (e) {
      errors.push({ name: pl.name, error: `${e.message}${e.body ? ' ' + JSON.stringify(e.body).slice(0, 300) : ''}` });
    }
  }
  return { created, errors };
}

// ── Job store (private S3) ──────────────────────────────────────────────────────────────────────
async function writeJob(jobId, obj) {
  await s3.send(new PutObjectCommand({
    Bucket: JOBS_BUCKET, Key: `am-sync-jobs/${jobId}.json`,
    Body: JSON.stringify(obj), ContentType: 'application/json',
  }));
}
async function readJob(jobId) {
  try {
    const out = await s3.send(new GetObjectCommand({ Bucket: JOBS_BUCKET, Key: `am-sync-jobs/${jobId}.json` }));
    return JSON.parse(await out.Body.transformToString());
  } catch { return null; }
}

// ── HTTP plumbing ───────────────────────────────────────────────────────────────────────────────
function reply(status, obj) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}
function bearerOf(event) {
  const h = event.headers || {};
  const raw = h.authorization || h.Authorization || '';
  return raw.startsWith('Bearer ') ? raw.slice(7) : raw;
}

export async function handler(event) {
  // ── WORKER MODE (async self-invoke): do the long pull/push, write the result to S3. No API
  // Gateway timeout applies here — only the Lambda timeout (raised for this path).
  if (event && event.worker) {
    const { jobId, op, musicUserToken, playlists } = event;
    try {
      const dev = (await mintDeveloperToken()).token;
      const result = op === 'pull' ? await pull(dev, musicUserToken) : await push(dev, musicUserToken, playlists);
      await writeJob(jobId, { status: 'done', result });
    } catch (e) {
      await writeJob(jobId, { status: 'error', error: e.message, detail: e.body ?? undefined });
    }
    return { ok: true };
  }

  // ── API GATEWAY MODE (fast: submit a job, or poll one) ──────────────────────────────────────────
  const method = event.requestContext?.http?.method || 'GET';
  const path = (event.rawPath || '/').replace(/\/+$/, '') || '/';

  if (method === 'GET' && path === '/health') return reply(200, { ok: true });

  let secret;
  try { secret = await loadSecret(); } catch { return reply(500, { error: 'secret unavailable' }); }
  if (secret.appToken && bearerOf(event) !== secret.appToken) return reply(401, { error: 'unauthorized' });

  try {
    if (method === 'GET' && path === '/musickit-token') {
      const dev = await mintDeveloperToken();
      return reply(200, { token: dev.token, expiresAt: dev.exp * 1000, ttlSec: secret.ttlSec });
    }

    // Poll a job's status/result.
    if (method === 'GET' && path.startsWith('/job/')) {
      const jobId = path.slice('/job/'.length);
      const job = await readJob(jobId);
      // Absent object ⇒ the worker hasn't written it yet (or an unknown id) — report pending.
      return reply(200, job || { status: 'pending' });
    }

    // Submit an async pull/push job and return immediately.
    if (method === 'POST' && (path === '/pull' || path === '/push')) {
      const req = event.body
        ? JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body)
        : {};
      if (!req.musicUserToken) return reply(400, { error: 'musicUserToken required' });
      const jobId = randomUUID();
      await writeJob(jobId, { status: 'pending' });
      await lambda.send(new InvokeCommand({
        FunctionName: SELF_FUNCTION,
        InvocationType: 'Event',
        Payload: Buffer.from(JSON.stringify({
          worker: true, jobId, op: path.slice(1),
          musicUserToken: req.musicUserToken, playlists: req.playlists,
        })),
      }));
      return reply(202, { jobId });
    }

    return reply(404, { error: 'not found', path });
  } catch (e) {
    const status = e.status && e.status >= 400 && e.status < 600 ? e.status : 502;
    return reply(status, { error: e.message, detail: e.body ?? undefined });
  }
}
