// PocketDJ Apple Music playlist-sync Lambda — the server half of WS2 (bidirectional PocketDJ <->
// Apple Music library-playlist sync), replacing the iMac/Tailscale path with an on-demand AWS
// endpoint (API Gateway HTTP API -> this Lambda).
//
// ── ASYNC JOB + POLL + CHECKPOINTED CONTINUATIONS (why) ─────────────────────────────────────────
// Pulling a real library (100+ playlists, each needing paged tracks fetches) is hundreds of
// sequential Apple Music calls: far beyond API Gateway's HARD 30s integration timeout (a 503),
// and for a big library beyond even one Lambda invocation's timeout. So:
//   • POST /pull|/push writes a job record to S3, async self-invokes a WORKER, returns {jobId}
//     (202) in <1s.
//   • The WORKER processes in CHUNKS, checkpointing partial results + a resume cursor to S3 as it
//     goes. When its own time runs low (context.getRemainingTimeInMillis) it CHAINS: async
//     self-invokes a continuation that resumes from the checkpoint. Total runtime is unbounded;
//     each hop stays inside the Lambda timeout.
//   • Every checkpoint also records PROGRESS ({label, done, total}) — the client polls
//     GET /job/{jobId} and shows step-by-step progress instead of a dead spinner, and detects a
//     genuinely-stuck job by progress stalling (not by a wall clock).
//
// ── The two-token model ─────────────────────────────────────────────────────────────────────────
// A per-user library call needs the app-wide DEVELOPER token (ES256 JWT minted here from the
// MusicKit .p8 in Secrets Manager) AND the caller's MUSIC-USER-TOKEN. The MUT is NEVER at rest:
// it rides the invoke-chain payloads only (submit -> worker -> continuations), never S3.
//
// ── What the server can/can't do (Apple Music Web API) ──────────────────────────────────────────
// Library playlists are CREATE + APPEND only. Reorder/remove happen on-device (MusicLibrary.edit).
//
// Routes (API Gateway HTTP API $default catch-all -> rawPath):
//   GET  /musickit-token            -> { token, expiresAt }
//   POST /pull   { musicUserToken } -> 202 { jobId }
//   POST /push   { musicUserToken, playlists:[{name,description?,trackCatalogIds}] } -> 202 { jobId }
//   GET  /job/{jobId}               -> { status:'pending'|'running'|'done'|'error',
//                                        progress?:{label,done,total}, result?, error? }   (404 unknown)
//   GET  /health                    -> { ok:true }
//
// Job store: PRIVATE S3 bucket (JOBS_BUCKET), key am-sync-jobs/<jobId>.json — full record with
// internal resume state; GET /job strips internals. UUID jobIds; 1-day lifecycle expiry.

import { createPrivateKey, sign as cryptoSign, randomUUID } from 'node:crypto';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { LambdaClient, InvokeCommand } from '@aws-sdk/client-lambda';

const AM = 'https://api.music.apple.com';
const SECRET_ID = process.env.SECRET_ID || 'pocketdj/am-playlist-sync';
const REGION = process.env.AWS_REGION || 'us-west-2';
const JOBS_BUCKET = process.env.JOBS_BUCKET;
const SELF_FUNCTION = process.env.AWS_LAMBDA_FUNCTION_NAME;
// Chain a continuation when less than this much of the invocation remains: enough to finish the
// in-flight AM call, write the checkpoint, and fire the self-invoke.
const LOW_TIME_MS = 45_000;
// Runaway guard — a real library finishes in a handful of hops; hundreds means a loop.
const MAX_HOPS = 60;

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
// The per-request abort matters: LOW_TIME_MS is only sampled BETWEEN calls, so without it a single
// hung Apple response rides the invocation into the uncatchable 300s Lambda kill (no suspend, no
// error write — a stranded job). With it, a hang becomes a thrown error -> status:'error' -> the
// client resubmits and the idempotent state machine resumes.
async function am(method, path, { devToken, userToken, body } = {}) {
  const headers = { Authorization: `Bearer ${devToken}` };
  if (userToken) headers['Music-User-Token'] = userToken;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${AM}${path}`, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(25_000),
  });
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

// ── Job store (private S3) ──────────────────────────────────────────────────────────────────────
async function writeJob(jobId, obj, { ifMatch } = {}) {
  await s3.send(new PutObjectCommand({
    Bucket: JOBS_BUCKET, Key: `am-sync-jobs/${jobId}.json`,
    Body: JSON.stringify({ ...obj, updatedAt: new Date().toISOString() }),
    ContentType: 'application/json',
    ...(ifMatch ? { IfMatch: ifMatch } : {}),
  }));
}
// Returns { job, etag } or null ONLY for a genuinely-missing object. Transient S3 failures RETHROW:
// swallowing them here once turned a mid-flight push into a false "done, pushed nothing" (the
// worker saw `{}`: no request, no state, vacuously complete) — the worst kind of silent data bug.
async function readJob(jobId) {
  try {
    const out = await s3.send(new GetObjectCommand({ Bucket: JOBS_BUCKET, Key: `am-sync-jobs/${jobId}.json` }));
    return { job: JSON.parse(await out.Body.transformToString()), etag: out.ETag };
  } catch (e) {
    if (e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) return null;
    throw e;
  }
}
function isPreconditionFailure(e) {
  const code = e.$metadata?.httpStatusCode;
  return code === 412 || code === 409 || e.name === 'PreconditionFailed' || e.name === 'ConditionalRequestConflict';
}

// Fire the next hop of this job. The MUT rides the payload (never S3); state lives in S3.
async function chain(jobId, op, musicUserToken, hop) {
  await lambda.send(new InvokeCommand({
    FunctionName: SELF_FUNCTION,
    InvocationType: 'Event',
    Payload: Buffer.from(JSON.stringify({ worker: true, jobId, op, musicUserToken, hop })),
  }));
}

// ── Worker: chunked PULL with checkpoints ───────────────────────────────────────────────────────
// State machine persisted in job.state:
//   phase 'list'   — page through /me/library/playlists, collecting metas [{id,name,canEdit,desc}]
//   phase 'tracks' — for metas[idx], page through its tracks (trackNext resumes mid-playlist);
//                    completed playlists accumulate in results[]
async function pullChunked({ jobId, job, hop, lease, devToken, userToken, timeLeft }) {
  const low = () => timeLeft() < LOW_TIME_MS;
  const st = job.state || {
    phase: 'list', listNext: '/v1/me/library/playlists?limit=100',
    metas: [], results: [], idx: 0, trackNext: null, tracks: [], storefront: null,
  };
  // hops is the LAST COMPLETED hop watermark: mid-hop checkpoints write hop-1 so a Lambda
  // failure-retry of a crashed hop passes the entry guard and resumes from the freshest state;
  // only suspend (about to chain hop+1) and the terminal writes stamp `hop` as completed.
  const checkpoint = async (progress) =>
    writeJob(jobId, { status: 'running', op: 'pull', hops: hop - 1, ...lease, progress, state: st });
  const suspend = async (progress) => {
    await writeJob(jobId, { status: 'running', op: 'pull', hops: hop, claimedHop: null, leaseUntil: 0, progress, state: st });
    await chain(jobId, 'pull', userToken, hop + 1);
  };

  if (!st.storefront) {
    const r = await am('GET', '/v1/me/storefront', { devToken, userToken });
    st.storefront = r?.data?.[0]?.id || 'us';
  }

  while (st.phase === 'list') {
    if (low()) return suspend({ label: 'Listing Apple Music playlists', done: st.metas.length, total: null });
    const page = await am('GET', st.listNext, { devToken, userToken });
    for (const pl of page?.data || []) {
      const a = pl.attributes || {};
      st.metas.push({ id: pl.id, name: a.name || '(untitled)', canEdit: a.canEdit ?? false, description: a.description?.standard });
    }
    st.listNext = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
    if (!st.listNext) { st.phase = 'tracks'; }
    await checkpoint({ label: 'Listing Apple Music playlists', done: st.metas.length, total: st.phase === 'tracks' ? st.metas.length : null });
  }

  while (st.idx < st.metas.length) {
    const meta = st.metas[st.idx];
    const progress = () => ({ label: `Reading “${meta.name}”`, done: st.idx, total: st.metas.length });
    if (low()) return suspend(progress());
    let next = st.trackNext || `/v1/me/library/playlists/${encodeURIComponent(meta.id)}/tracks?limit=100`;
    let done = false;
    while (!done) {
      let page = null;
      try {
        page = await am('GET', next, { devToken, userToken });
      } catch (e) {
        if (e.status !== 404) throw e; // 404 = empty playlist; anything else is real
      }
      for (const t of page?.data || []) {
        const a = t.attributes || {};
        st.tracks.push({ catalogId: a.playParams?.catalogId || a.playParams?.id || null, title: a.name || '' });
      }
      next = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
      if (!next) { done = true; break; }
      st.trackNext = next;
      if (low()) return suspend(progress()); // mid-playlist checkpoint: trackNext resumes here
    }
    st.results.push({
      id: meta.id, name: meta.name, canEdit: meta.canEdit, description: meta.description,
      trackCatalogIds: st.tracks.map((t) => t.catalogId).filter(Boolean),
      trackTitles: st.tracks.map((t) => t.title),
    });
    st.tracks = []; st.trackNext = null; st.idx += 1;
    await checkpoint({ label: `Reading “${meta.name}”`, done: st.idx, total: st.metas.length });
  }

  await writeJob(jobId, {
    status: 'done', op: 'pull', hops: hop,
    progress: { label: 'Finished', done: st.metas.length, total: st.metas.length },
    result: { storefront: st.storefront, playlists: st.results },
  });
}

// ── Worker: IDEMPOTENT chunked PUSH with checkpoints ────────────────────────────────────────────
// THE DUPLICATE BUG THIS EXISTS TO KILL (Levi 2026-07-29): the old push created every incoming
// playlist unconditionally, so every sync minted another "comfort zone" copy in Apple Music. And a
// single create with ~1000 track relationships gets silently TRUNCATED by Apple (791/1000 landed).
// So push now:
//   1. Lists the user's remote library playlists (names only — cheap).
//   2. Per incoming playlist, matches by normalized name:
//        no match  -> CREATE with the first chunk of tracks, then APPEND the rest in chunks.
//        match(es) -> pick the candidate with the largest track overlap, and APPEND ONLY THE
//                     MISSING tracks (re-running a partial sync tops the playlist up — never dupes).
//   3. Checkpoints after every chunk so a continuation resumes mid-playlist.
// The Web API cannot delete or reorder (append-only) — removals/reorders stay on-device.
// state = { phase:'remote-list'|'apply', listNext, remote:[{id,name}], i, sub, results:[], errors:[] }
const PUSH_CHUNK = 100;
const normName = (s) => String(s || '').trim().toLowerCase().replace(/\s+/g, ' ');
// Song-identity key for the NAME+ARTIST duplicate gate (Levi 2026-07-29: "we shouldn't add a
// new song to a collection on either side if there is already a song with that same name and
// artist"). Diacritic-folded + quote-stripped + whitespace-collapsed; version markers KEPT
// (different cuts stay distinct — the tight-matching doctrine).
const trackKey = (name, artist) => {
  const one = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/['’"“”\[\]{}]/g, '').replace(/\s+/g, ' ').trim();
  return one(name) + '' + one(artist);
};

async function pushChunked({ jobId, job, hop, lease, devToken, userToken, timeLeft }) {
  const low = () => timeLeft() < LOW_TIME_MS;
  const incoming = job.request?.playlists || [];
  const st = job.state || {
    phase: 'remote-list', listNext: '/v1/me/library/playlists?limit=100',
    remote: [], i: 0, sub: null, results: [], errors: [],
  };
  // See pullChunked: hops = last COMPLETED hop; only suspend/terminal writes stamp this hop done.
  const checkpoint = async (progress) =>
    writeJob(jobId, { status: 'running', op: 'push', hops: hop - 1, ...lease, progress, state: st, request: job.request });
  const suspend = async (progress) => {
    await writeJob(jobId, { status: 'running', op: 'push', hops: hop, claimedHop: null, leaseUntil: 0, progress, state: st, request: job.request });
    await chain(jobId, 'push', userToken, hop + 1);
  };

  // Phase 1: names of every remote library playlist (smart playlists are invisible to this API —
  // by design we only ever match the regular copies this sync itself created).
  while (st.phase === 'remote-list') {
    if (low()) return suspend({ label: 'Checking existing Apple Music playlists', done: st.remote.length, total: null });
    const page = await am('GET', st.listNext, { devToken, userToken });
    for (const pl of page?.data || []) st.remote.push({ id: pl.id, name: pl.attributes?.name || '' });
    st.listNext = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
    if (!st.listNext) st.phase = 'apply';
    await checkpoint({ label: 'Checking existing Apple Music playlists', done: st.remote.length, total: null });
  }

  // Read a remote playlist's full track list (paged): catalog ids AND name+artist identity keys
  // (the duplicate gate compares song identity, not just ids — the same recording can live under
  // several catalog/library ids, which is exactly how the duplicate flood happened). Returns null
  // when time runs low mid-read — the caller suspends and redoes the (read-only) matching next hop.
  const remoteTracks = async (playlistId) => {
    const ids = [];
    const keys = new Set();
    let next = `/v1/me/library/playlists/${encodeURIComponent(playlistId)}/tracks?limit=100`;
    while (next) {
      if (low()) return null;
      let page = null;
      try { page = await am('GET', next, { devToken, userToken }); }
      catch (e) { if (e.status === 404) break; throw e; } // 404 = empty playlist
      for (const t of page?.data || []) {
        const a = t.attributes || {};
        const id = a.playParams?.catalogId || a.playParams?.id;
        if (id) ids.push(String(id));
        if (a.name) keys.add(trackKey(a.name, a.artistName));
      }
      next = page?.next ? `${page.next}${page.next.includes('?') ? '&' : '?'}limit=100` : null;
    }
    return { ids, keys };
  };

  // Per-catalog-id identity meta the client sends (id -> {n, a}); absent for old clients.
  const metaFor = (pl) => {
    const map = new Map();
    for (const m of pl.trackMeta || []) if (m && m.id) map.set(String(m.id), m);
    return map;
  };

  // Phase 2: apply each incoming playlist (create-if-absent, then append-missing in chunks).
  while (st.i < incoming.length) {
    const pl = incoming[st.i];
    const meta = metaFor(pl);
    // Within-batch NAME+ARTIST dedupe first: two local ids for the same recording must send one.
    const seenKeys = new Set();
    const ids = [];
    for (const raw of (pl.trackCatalogIds || []).filter(Boolean).map(String)) {
      const m = meta.get(raw);
      if (m && m.n) {
        const k = trackKey(m.n, m.a);
        if (seenKeys.has(k)) continue;
        seenKeys.add(k);
      }
      ids.push(raw);
    }
    const progress = () => ({ label: `Syncing “${pl.name}”`, done: st.i, total: incoming.length });
    if (low()) return suspend(progress());
    try {
      // Establish the target (create or match) once per playlist; appends resume via st.sub.
      if (!st.sub) {
        const candidates = st.remote.filter((r) => normName(r.name) === normName(pl.name));
        if (candidates.length === 0) {
          // CREATE with only the first chunk — large single creates are what Apple truncates.
          const first = ids.slice(0, PUSH_CHUNK);
          const body = {
            attributes: { name: pl.name, ...(pl.description ? { description: pl.description } : {}) },
            ...(first.length ? { relationships: { tracks: { data: first.map((id) => ({ id, type: 'songs' })) } } } : {}),
          };
          const res = await am('POST', '/v1/me/library/playlists', { devToken, userToken, body });
          const newId = res?.data?.[0]?.id || null;
          if (newId) st.remote.push({ id: newId, name: pl.name }); // a same-name sibling later matches this
          st.sub = { targetId: newId, created: true, missing: ids.slice(first.length), appendIdx: 0, added: first.length };
        } else {
          // MATCH: pick the candidate sharing the most tracks (dupes from the old bug may linger;
          // converge on the fullest copy and let the user delete the rest).
          let best = null; let bestOverlap = -1; let bestSet = null; let bestKeys = null;
          for (const c of candidates) {
            if (low()) return suspend(progress()); // reads only — safe to redo this playlist entirely
            const fetched = await remoteTracks(c.id);
            if (fetched === null) return suspend(progress()); // ran out of time mid-read — same redo
            const have = new Set(fetched.ids);
            const overlap = ids.reduce((n, id) => n + (have.has(id) ? 1 : 0), 0);
            if (overlap > bestOverlap) { bestOverlap = overlap; best = c; bestSet = have; bestKeys = fetched.keys; }
          }
          // MISSING = not present by CATALOG ID **and** not present by NAME+ARTIST identity —
          // the second clause is the duplicate-flood killer: the same recording under a
          // different id must never be appended again.
          const missing = ids.filter((id) => {
            if (bestSet.has(id)) return false;
            const m = meta.get(id);
            if (m && m.n && bestKeys.has(trackKey(m.n, m.a))) return false;
            return true;
          });
          st.sub = { targetId: best.id, created: false, missing, appendIdx: 0, added: 0 };
        }
        await checkpoint(progress());
      }
      // Append the missing tracks in chunks, checkpointing after each so a continuation
      // resumes at appendIdx instead of re-adding (the "only add the missing 209" property).
      while (st.sub.appendIdx < st.sub.missing.length) {
        const chunk = st.sub.missing.slice(st.sub.appendIdx, st.sub.appendIdx + PUSH_CHUNK);
        await am('POST', `/v1/me/library/playlists/${encodeURIComponent(st.sub.targetId)}/tracks`,
          { devToken, userToken, body: { data: chunk.map((id) => ({ id, type: 'songs' })) } });
        st.sub.appendIdx += chunk.length;
        st.sub.added += chunk.length;
        await checkpoint({ label: `Adding to “${pl.name}” (${st.sub.appendIdx}/${st.sub.missing.length})`, done: st.i, total: incoming.length });
        if (low()) return suspend(progress());
      }
      st.results.push({ name: pl.name, id: st.sub.targetId, created: st.sub.created, added: st.sub.added, total: ids.length });
    } catch (e) {
      st.errors.push({ name: pl.name, error: `${e.message}${e.body ? ' ' + JSON.stringify(e.body).slice(0, 300) : ''}` });
    }
    st.sub = null; st.i += 1;
    await checkpoint({ label: 'Pushing playlists', done: st.i, total: incoming.length });
  }

  await writeJob(jobId, {
    status: 'done', op: 'push', hops: hop,
    progress: { label: 'Finished', done: incoming.length, total: incoming.length },
    result: { playlists: st.results, errors: st.errors },
  });
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

export async function handler(event, context) {
  // ── WORKER MODE (async self-invoke): one bounded hop of the job, then chain or finish. ─────────
  if (event && event.worker) {
    const { jobId, op, musicUserToken } = event;
    const hop = event.hop || 1;
    // A missing record is anomalous (submit pre-writes it; only expiry removes it) — drop, never
    // proceed with `{}` (that once produced a false "done, pushed nothing").
    const read = await readJob(jobId);
    if (!read) return { ok: true };
    const job = read.job;
    // Delivery guards — async invokes are at-least-once AND Lambda retries failed ones with the
    // SAME hop number, so the checks must distinguish three cases:
    //   terminal            -> replay of a finished job: drop.
    //   hops >= hop         -> this hop already COMPLETED (chained/finished): drop.
    //   live lease this hop -> a twin of a STILL-RUNNING delivery: drop (the atomic claim below
    //                          closes the read-to-write race).
    //   otherwise           -> first delivery, or the retry of a hop that CRASHED mid-work
    //                          (hops still hop-1, lease expired): run it — resume from checkpoint.
    if (job.status === 'done' || job.status === 'error') return { ok: true };
    if ((job.hops || 0) >= hop) return { ok: true };
    if (job.claimedHop === hop && (job.leaseUntil || 0) > Date.now()) return { ok: true };
    if (hop > MAX_HOPS) {
      await writeJob(jobId, { status: 'error', op, error: 'sync exceeded the continuation limit' });
      return { ok: true };
    }
    const timeLeft = () => context.getRemainingTimeInMillis();
    // Claim the hop ATOMICALLY (S3 conditional put on the record's ETag): of two simultaneous
    // deliveries, exactly one wins; the loser must not run — a twin would double-append tracks.
    const lease = { claimedHop: hop, leaseUntil: Date.now() + timeLeft() + 10_000 };
    try {
      await writeJob(jobId, { ...job, status: 'running', ...lease }, { ifMatch: read.etag });
    } catch (e) {
      if (isPreconditionFailure(e)) return { ok: true };
      throw e; // transient S3 failure -> invocation errors -> Lambda's async retry redelivers
    }
    try {
      const dev = (await mintDeveloperToken()).token;
      const args = { jobId, job, hop, lease, devToken: dev, userToken: musicUserToken, timeLeft };
      if (op === 'pull') await pullChunked(args); else await pushChunked(args);
    } catch (e) {
      await writeJob(jobId, { status: 'error', op, error: e.message, detail: e.body ?? undefined });
    }
    return { ok: true };
  }

  // ── API GATEWAY MODE (fast: submit a job, or poll one) ─────────────────────────────────────────
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

    // Poll a job — public shape only (internal resume state + request stay server-side). A
    // transient S3 failure rethrows out of readJob and lands as a 502 below — the client keeps
    // polling; only a genuinely-missing record 404s (which tells the client to resubmit).
    if (method === 'GET' && path.startsWith('/job/')) {
      const jobId = path.slice('/job/'.length);
      const read = await readJob(jobId);
      if (!read) return reply(404, { error: 'unknown job' }); // expired or never existed -> resubmit
      const job = read.job;
      return reply(200, { status: job.status, progress: job.progress, result: job.result, error: job.error, detail: job.detail });
    }

    // Submit an async pull/push job and return immediately.
    if (method === 'POST' && (path === '/pull' || path === '/push')) {
      const req = event.body
        ? JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body)
        : {};
      if (!req.musicUserToken) return reply(400, { error: 'musicUserToken required' });
      const op = path.slice(1);
      const jobId = randomUUID();
      // Pre-write the record (so /job never 404s a live job); push stores its payload here too.
      await writeJob(jobId, {
        status: 'pending', op, hops: 0,
        progress: { label: 'Starting', done: 0, total: null },
        ...(op === 'push' ? { request: { playlists: req.playlists || [] } } : {}),
      });
      await chain(jobId, op, req.musicUserToken, 1);
      return reply(202, { jobId });
    }

    return reply(404, { error: 'not found', path });
  } catch (e) {
    const status = e.status && e.status >= 400 && e.status < 600 ? e.status : 502;
    return reply(status, { error: e.message, detail: e.body ?? undefined });
  }
}
