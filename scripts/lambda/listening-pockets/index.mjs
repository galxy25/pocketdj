// PocketDJ LISTENING POCKETS Lambda — mounted on the EXISTING rec-engine HTTP API as the routes
// `ANY /pockets` + `ANY /pockets/{proxy+}` (the rec engine keeps `$default`), so the app keeps one
// base URL (`Config.recEngineBase`).
//
// The app uploads play events (song id, minute-floored start, local UTC offset, finished / skipped
// / partial + listened fraction, surface, CarPlay, optional opaque place/trip ids); a job runs
// pocket DETECTION (detect.mjs) then ANALYSIS (analyze.mjs) per profile and stores a results
// document the app fetches. Every knob is in params.mjs; the design is docs/design/listening-pockets.md.
//
// ── Auth (the rec engine's model, its own binding) ─────────────────────────────────────────────
// Same bearer key, same SCOPED profile id (`HMAC-SHA256(profileId, key: bearerKey)`), same
// enrollment secret (`REC_ENROLL_SECRET` — must equal `Config.recEngineEnrollSecret`; deploy.sh
// copies it from the rec-engine function, never mints one). The trust-on-first-use keyHash binding
// lives in THIS service's own events object, so the two services can never wedge each other.
// Creating state needs the enrollment secret and is capped at MAX_PROFILES (counted over
// `pockets/events/`); an already-bound profile never touches that branch. DELETE accepts the bound
// key OR the secret (the in-app "Delete cloud data" unwedges a bad key, as on the rec engine).
//
// ── Routes (a leading `/pockets` and trailing slashes are stripped first, so `/pockets/events` and
//    `/events` both route — the API mount passes the full path, a curl against the bare function
//    URL does not, and a prefix that silently 404s is the rip-server bug we are not repeating) ──
//   GET    /health    -> { ok:true, service:'listening-pockets', version:1 }   (unauthenticated)
//   POST   /events    -> merge an upload.v1 batch, mark dirty, async-invoke the compute job
//   GET    /results   -> the stored results.v1 document (stale = events changed since compute)
//   DELETE /state     -> delete both objects
//
// ── Jobs (NOT HTTP: dispatched on `event.job` before any routing, never reachable from the API) ─
//   { job:'compute', p:<profileHash> }          one profile: detect + analyze + store results
//   { job:'nightly', hashes?:[…], hop?:n }      EventBridge 04:30 PDT: recompute every profile that
//                                               is dirty or whose results are older than 20 h;
//                                               chains a continuation when time runs low
//
// ── Test seams (zero AWS) ──────────────────────────────────────────────────────────────────────
//   POCKETS_LOCAL_DIR       filesystem store instead of S3
//   POCKETS_FEATURES_FILE   local features file instead of FEATURES_URL
//   POCKETS_INLINE_COMPUTE  =1: run the compute job synchronously inside the POST (no self-invoke)
//   REC_ENROLL_SECRET / MAX_PROFILES are read per request so a test can flip them.

import { createHash, timingSafeEqual } from 'node:crypto';
import { POCKET_PARAMS, POCKET_LIMITS } from './params.mjs';
import { computeResults, emptyResults } from './analyze.mjs';
import { loadFeatures } from './features.mjs';
import {
  Precondition, readEvents, writeEvents, readResults, writeResults, deleteProfile,
  countProfiles, listProfileHashes, cleanEvent, cleanLabels, mergeEvents, freshEventsDoc, INSTALL_RE,
} from './store.mjs';

const REGION = process.env.AWS_REGION || 'us-west-2';
const PROFILE_RE = /^[A-Za-z0-9._-]{8,64}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const sha256 = (s) => createHash('sha256').update(s).digest('hex');

const defaultMaxProfiles = () => {
  const n = Number(process.env.MAX_PROFILES);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : POCKET_LIMITS.maxProfilesDefault;
};
const inlineCompute = () => process.env.POCKETS_INLINE_COMPUTE === '1';

// ── Self-invoke (async compute + nightly continuations) ─────────────────────────────────────────
// Injectable so the tests can watch what would have been invoked without an AWS client.
let _invoker = null;
async function invokeSelf(payload) {
  if (_invoker) return _invoker(payload);
  const fn = process.env.POCKETS_SELF_FUNCTION || process.env.AWS_LAMBDA_FUNCTION_NAME;
  if (!fn) return;   // not running in Lambda (local runner, tests without a hook): nothing to call
  const { LambdaClient, InvokeCommand } = await import('@aws-sdk/client-lambda');
  const lambda = new LambdaClient({ region: REGION });
  await lambda.send(new InvokeCommand({
    FunctionName: fn, InvocationType: 'Event', Payload: Buffer.from(JSON.stringify(payload)),
  }));
}
export const _test = { setInvoker(fn) { _invoker = fn; } };

// ── HTTP plumbing (rec-engine shapes) ───────────────────────────────────────────────────────────

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

/// Constant-time compare against `REC_ENROLL_SECRET`. FAIL-CLOSED: unset → every enrollment and
/// every secret-authorized delete is refused.
export function enrollOk(event) {
  const want = process.env.REC_ENROLL_SECRET || '';
  if (!want) return false;
  const h = event.headers || {};
  const got = h['x-pocketdj-enroll'] || h['X-PocketDJ-Enroll'] || '';
  if (typeof got !== 'string' || got.length !== want.length) return false;
  return timingSafeEqual(Buffer.from(got, 'utf8'), Buffer.from(want, 'utf8'));
}

function bodyBytes(event) {
  if (!event.body) return 0;
  return event.isBase64Encoded ? Math.floor((event.body.length * 3) / 4) : Buffer.byteLength(event.body, 'utf8');
}
function parseBody(event) {
  if (!event.body) return {};
  const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
  return JSON.parse(text);
}

/// `/pockets/events/` → `/events`; `/pockets` → `/`. Only a whole `/pockets` segment is stripped.
export function normalizePath(raw) {
  let p = (raw || '/').replace(/\/+$/, '') || '/';
  p = p.replace(/^\/pockets(?=\/|$)/, '') || '/';
  return p;
}

// ── Jobs ────────────────────────────────────────────────────────────────────────────────────────

/**
 * Recompute one profile: read events (with ETag), detect + analyze, store results, then clear
 * `dirty` CONDITIONALLY on the ETag we computed from — an upload that landed meanwhile changed the
 * ETag, so its rows stay dirty for the next run instead of being silently marked computed.
 */
export async function computeProfile(h, { nowMs = Date.now() } = {}) {
  const read = await readEvents(h);
  if (!read) return { computed: false };
  const features = await loadFeatures();
  const results = computeResults(read.doc, features, { nowMs });
  await writeResults(h, results);
  if (read.doc.dirty) {
    read.doc.dirty = false;
    read.doc.computedAtMs = nowMs;
    try { await writeEvents(h, read.doc, { ifMatch: read.etag }); } catch (e) {
      if (!(e instanceof Precondition)) throw e;
    }
  }
  return { computed: true, pockets: results.pockets.length, patterns: results.patterns.length };
}

async function runJob(event, context) {
  if (event.job === 'compute') {
    if (typeof event.p !== 'string' || !HASH_RE.test(event.p)) return { ok: false, error: 'bad-job' };
    return { ok: true, ...(await computeProfile(event.p)) };
  }
  if (event.job === 'nightly') {
    const hop = Number.isInteger(event.hop) ? event.hop : 1;
    if (hop > POCKET_LIMITS.nightlyMaxHops) return { ok: false, error: 'too-many-hops' };
    const todo = Array.isArray(event.hashes)
      ? event.hashes.filter((x) => typeof x === 'string' && HASH_RE.test(x))
      : await listProfileHashes();
    const timeLeft = () => (typeof context?.getRemainingTimeInMillis === 'function'
      ? context.getRemainingTimeInMillis() : Infinity);
    let computed = 0; let skipped = 0; let failed = 0;
    for (let i = 0; i < todo.length; i++) {
      if (timeLeft() < POCKET_LIMITS.nightlyLowTimeMs) {
        await invokeSelf({ job: 'nightly', hashes: todo.slice(i), hop: hop + 1 });
        return { ok: true, computed, skipped, failed, chained: todo.length - i };
      }
      const h = todo[i];
      try {
        const read = await readEvents(h);
        if (!read) { skipped += 1; continue; }
        const results = read.doc.dirty ? null : await readResults(h);
        const fresh = results?.generatedAtMs != null
          && Date.now() - results.generatedAtMs < POCKET_PARAMS.nightlyRecomputeAfterMs;
        if (!read.doc.dirty && fresh) { skipped += 1; continue; }
        await computeProfile(h);
        computed += 1;
      } catch (e) {
        // One bad profile must not starve the rest of the night; it stays dirty for tomorrow.
        failed += 1;
        console.error(`[listening-pockets] nightly compute failed for ${h.slice(0, 8)}…: ${e.message}`);
      }
    }
    return { ok: true, computed, skipped, failed, chained: 0 };
  }
  return { ok: false, error: 'unknown-job' };
}

// ── Handler ─────────────────────────────────────────────────────────────────────────────────────

export async function handler(event, context) {
  // Jobs first: an async self-invoke / EventBridge payload has no HTTP shape at all.
  if (event && typeof event.job === 'string' && !event.requestContext) return runJob(event, context);

  const method = event.requestContext?.http?.method || 'GET';
  const path = normalizePath(event.rawPath);

  if (method === 'GET' && path === '/health') {
    return reply(200, { ok: true, service: 'listening-pockets', version: 1 });
  }

  const auth = authOf(event);
  if (auth.fail) return auth.fail;

  try {
    if (method === 'POST' && path === '/events') {
      if (bodyBytes(event) > POCKET_LIMITS.maxBodyBytes) {
        return reply(413, { error: 'body-too-large', max: POCKET_LIMITS.maxBodyBytes });
      }
      let body;
      try { body = parseBody(event); } catch { return reply(400, { error: 'bad-request' }); }
      if (!body || typeof body !== 'object' || body.v !== 1 || !Array.isArray(body.events)
          || typeof body.installId !== 'string' || !INSTALL_RE.test(body.installId)) {
        return reply(400, { error: 'bad-request' });
      }
      if (body.events.length > POCKET_LIMITS.maxBatchEvents) {
        return reply(400, { error: 'batch-too-large', max: POCKET_LIMITS.maxBatchEvents });
      }
      const nowMs = Date.now();
      const rows = []; let rejected = 0;
      for (const e of body.events) {
        const r = cleanEvent(e, body.installId, nowMs);
        if (r) rows.push(r); else rejected += 1;
      }
      const carriesLabels = Array.isArray(body.places) || Array.isArray(body.trips);
      const labels = carriesLabels ? cleanLabels(body.places, body.trips) : null;

      // Read-merge-write with ETag-conditional puts; on a conflict re-read and re-merge (3×), then
      // 503 — the app records fingerprints only on 2xx, so it simply re-sends next flush.
      for (let attempt = 0; attempt < 3; attempt++) {
        const read = await readEvents(auth.profileHash);
        const doc = read ? read.doc : freshEventsDoc(nowMs);
        if (!doc.keyHash) {
          if (!enrollOk(event)) return reply(403, { error: 'enrollment-required' });
          const maxProfiles = defaultMaxProfiles();
          if (await countProfiles(maxProfiles) >= maxProfiles) {
            return reply(403, { error: 'profile-cap-reached', max: maxProfiles });
          }
          doc.keyHash = auth.keyHash;   // trust-on-first-use bind
        } else if (doc.keyHash !== auth.keyHash) {
          return reply(403, { error: 'key-mismatch' });
        }
        const merged = mergeEvents(doc, rows, nowMs);
        let labelsChanged = false;
        if (labels) {
          const prev = JSON.stringify({ places: doc.labels?.places || [], trips: doc.labels?.trips || [] });
          labelsChanged = prev !== JSON.stringify(labels);
          doc.labels = { ...labels, atMs: nowMs };
        }
        const changed = merged.changed || labelsChanged;
        // An identical re-send changes nothing and must not trigger a recompute.
        if (changed) doc.dirty = true;
        doc.updatedAtMs = nowMs;
        try {
          await writeEvents(auth.profileHash, doc, { ifMatch: read?.etag });
        } catch (e) {
          if (e instanceof Precondition) continue;
          throw e;
        }
        if (changed) {
          // Best-effort either way: the nightly run picks up anything still dirty, so a failed
          // compute or invoke must never fail an upload the store already accepted.
          try {
            if (inlineCompute()) await computeProfile(auth.profileHash, { nowMs });
            else await invokeSelf({ job: 'compute', p: auth.profileHash });
          } catch (e) {
            console.error(`[listening-pockets] compute ${inlineCompute() ? 'run' : 'invoke'} failed: ${e.message}`);
          }
        }
        return reply(200, {
          ok: true, accepted: merged.accepted, updated: merged.updated, unchanged: merged.unchanged,
          rejected, total: doc.events.length, dirty: !!doc.dirty,
        });
      }
      return reply(503, { error: 'conflict-retry' });
    }

    if (method === 'GET' && path === '/results') {
      const read = await readEvents(auth.profileHash);
      if (!read) return reply(200, emptyResults());
      if (read.doc.keyHash && read.doc.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const results = await readResults(auth.profileHash);
      const stale = !!read.doc.dirty;
      if (!results) return reply(200, emptyResults({ stale, labels: read.doc.labels }));
      return reply(200, { ...results, stale });
    }

    if (method === 'DELETE' && path === '/state') {
      const read = await readEvents(auth.profileHash);
      if (read && read.doc.keyHash && read.doc.keyHash !== auth.keyHash && !enrollOk(event)) {
        return reply(403, { error: 'key-mismatch' });
      }
      await deleteProfile(auth.profileHash);
      return reply(200, { deleted: true });
    }

    return reply(404, { error: 'not-found' });
  } catch (e) {
    const status = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 502;
    return reply(status, { error: e.message || 'internal' });
  }
}
