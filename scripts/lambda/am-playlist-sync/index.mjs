// PocketDJ Apple Music playlist-sync Lambda — the server half of WS2 (bidirectional
// PocketDJ <-> Apple Music library-playlist sync), replacing the iMac/Tailscale path with an
// on-demand AWS endpoint (API Gateway HTTP API -> this Lambda).
//
// ── The two-token model ────────────────────────────────────────────────────────────────────────
// A per-user Apple Music library call needs BOTH:
//   (1) an app-wide DEVELOPER token — an ES256 JWT this Lambda mints from the MusicKit .p8
//       (kid 9JRN4H68X4 / team EC27UF79GL), lifted verbatim from scripts/rip-server.mjs. The .p8
//       and the app bearer token live in AWS Secrets Manager (SECRET_ID) — NEVER in the artifact.
//   (2) a per-user MUSIC-USER-TOKEN — minted on-device by the app via MusicKit's
//       MusicUserTokenProvider and sent with each request. This Lambda NEVER stores it (per-call).
// The Music-User-Token is the real per-user gate: without a valid one Apple rejects every /v1/me
// call, and a token only ever affects its own owner's library. The app bearer token is
// defence-in-depth (stops the endpoint being a free developer-token oracle).
//
// ── What the server can and can't do (Apple Music Web API, verified 2026) ───────────────────────
// Library playlists are CREATE + APPEND only: list, read tracks, create (with an ordered initial
// track list), append tracks. There is NO server-side remove or reorder — those happen on-device
// via MusicKit MusicLibrary.edit (the app's hybrid push). So this Lambda does: pull (list+read),
// create, and append. Reorder/remove are the client's job.
//
// Routes (all POST unless noted; JSON in/out; API Gateway HTTP API $default catch-all -> rawPath):
//   GET  /musickit-token          -> { token, expiresAt }         (developer token for the client)
//   POST /pull   { musicUserToken } -> { storefront, playlists: [{ id, name, canEdit, trackCatalogIds, trackTitles }] }
//   POST /push   { musicUserToken, playlists: [{ name, description?, trackCatalogIds: [] }] }
//                                  -> { created: [{ name, id }], errors: [{ name, error }] }
//   GET  /health                  -> { ok: true }
//
// Dependency-free: node20 runtime globals only (fetch, crypto, SecretsManager via a signed fetch is
// avoided — we use the AWS SDK v3 that ships in the runtime).

import { createPrivateKey, sign as cryptoSign } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';

const AM = 'https://api.music.apple.com';
const SECRET_ID = process.env.SECRET_ID || 'pocketdj/am-playlist-sync';
const REGION = process.env.AWS_REGION || 'us-west-2';

const sm = new SecretsManagerClient({ region: REGION });

// ── Secret + developer-token caching (survives warm invocations) ────────────────────────────────
let _secret = null;                       // { p8, kid, team, appToken, ttlSec }
let _devToken = null;                      // { token, exp }

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

// ES256 developer token — identical algorithm to rip-server.mjs mintMusicKitToken (raw r‖s / JOSE
// signature via dsaEncoding 'ieee-p1363'; a DER signature 401s at Apple).
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

// ── PULL: read the user's library playlists + their tracks (catalog ids where available) ─────────
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
      // A library-song exposes its catalog id via playParams.catalogId (streamable) when present.
      const catalogId = attrs.playParams?.catalogId || attrs.playParams?.id || null;
      out.push({ catalogId, title: attrs.name || '' });
    }
    next = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
  }
  return out;
}

// ── PUSH: create library playlists with their ordered catalog tracks ─────────────────────────────
async function push(devToken, userToken, incoming) {
  const created = [];
  const errors = [];
  for (const pl of incoming || []) {
    try {
      const trackData = (pl.trackCatalogIds || [])
        .filter(Boolean)
        .map((id) => ({ id: String(id), type: 'songs' })); // catalog id + type songs (also adds to library)
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
  const method = event.requestContext?.http?.method || 'GET';
  const path = (event.rawPath || '/').replace(/\/+$/, '') || '/';

  if (method === 'GET' && path === '/health') return reply(200, { ok: true });

  let secret;
  try { secret = await loadSecret(); } catch (e) { return reply(500, { error: 'secret unavailable' }); }

  // App bearer token (defence-in-depth). Enforced when the secret defines one.
  if (secret.appToken && bearerOf(event) !== secret.appToken) {
    return reply(401, { error: 'unauthorized' });
  }

  try {
    const dev = await mintDeveloperToken();

    if (method === 'GET' && path === '/musickit-token') {
      return reply(200, { token: dev.token, expiresAt: dev.exp * 1000, ttlSec: secret.ttlSec });
    }

    if (method === 'POST' && (path === '/pull' || path === '/push')) {
      const req = event.body ? JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body) : {};
      const userToken = req.musicUserToken;
      if (!userToken) return reply(400, { error: 'musicUserToken required' });
      if (path === '/pull') return reply(200, await pull(dev.token, userToken));
      return reply(200, await push(dev.token, userToken, req.playlists));
    }

    return reply(404, { error: 'not found', path });
  } catch (e) {
    const status = e.status && e.status >= 400 && e.status < 600 ? e.status : 502;
    return reply(status, { error: e.message, detail: e.body ?? undefined });
  }
}
