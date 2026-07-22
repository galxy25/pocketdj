#!/usr/bin/env node
// PocketDJ Jukebox Hero session broker (runs on the iMac; later a Lambda). Sibling of
// scripts/rip-server.mjs — dependency-free node:http, launchd KeepAlive, wildcard CORS,
// AWS-credentialed S3 writes via the `aws` CLI (profile levi). It does NO ripping and NO
// matching: it owns session lifecycle + the durable request queue, and is the only party
// with AWS creds (the app has none), so it renders the guest page and writes state.json.
//
// Guests only ever GET static S3 objects (jukebox/<id>/index.html + state.json behind
// CloudFront); any number of listeners, zero load on the host. The host app POSTs player
// snapshots + polls new requests + decides them; every decision republishes state.json so
// guests see the request status flip. See docs/design/jukebox-hero.md.
//
//   JUKEBOX_TOKEN=secret node scripts/jukebox-server.mjs
//   curl localhost:8788/health
//
// Public exposure (interim): tailscale funnel path-mount /jukebox → this port; the funnel
// strips the /jukebox mount, and the rendered page's fetch paths carry /jukebox too, so the
// server strips a leading /jukebox segment before dispatch (works direct AND behind funnel).
import http from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, writeFileSync, renameSync, readdirSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { homedir, hostname } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Bump when the server gains capabilities the app must detect (health.version).
// v2: per-session played history (now-playing transitions logged; state.json `played`).
const VERSION = 2;

const CFG = {
  port: parseInt(process.env.JUKEBOX_PORT || '8788', 10),
  token: process.env.JUKEBOX_TOKEN || '',            // bearer for host/create endpoints; empty = open (local dev)
  profile: process.env.AWS_PROFILE || 'levi',
  region: process.env.AWS_REGION || 'us-west-2',
  bucket: process.env.JUKEBOX_WEB_BUCKET || 'pocketdj-dev-web-011183829623', // per-env web bucket
  // Public base for guest URLs + state.json. Default is the dedicated jukebox
  // distribution (jukebox.pocket-dj.com), whose origin path is /jukebox — so the
  // public path is /<id>/ while the S3 keys stay jukebox/<id>/... (unchanged below).
  // Override with a bucket-root CloudFront (e.g. the dev PWA domain) only together
  // with JUKEBOX_GUEST_PREFIX=jukebox.
  siteBase: (process.env.JUKEBOX_SITE_BASE || 'https://jukebox.pocket-dj.com').replace(/\/$/, ''),
  // Path segment between siteBase and <id>/ in the PUBLIC guest URL. Empty for a
  // distribution whose origin path already points at the jukebox/ subtree.
  guestPrefix: (process.env.JUKEBOX_GUEST_PREFIX ?? '').replace(/^\/|\/$/g, ''),
  // :8443 — Funnel is per-PORT, and 443 already serves the Tailnet-only rip server;
  // funneling /jukebox on 443 would expose the rip server publicly too. The jukebox
  // gets Funnel's second HTTPS port so the rip server's boundary is untouched.
  publicBase: (process.env.JUKEBOX_PUBLIC_BASE || 'https://levis-imac.tail2e2bdf.ts.net:8443/jukebox').replace(/\/$/, ''), // API base baked into the page
  home: (process.env.JUKEBOX_HOME || join(homedir(), '.pocketdj', 'jukebox')).replace(/^~/, homedir()),
  dryRun: process.env.JUKEBOX_DRY_RUN === '1',       // tests: write what WOULD upload under home/dry-run/<key> instead of calling aws
  template: process.env.JUKEBOX_TEMPLATE || join(__dirname, 'jukebox-site', 'template.html'),
  // Session lifecycle (all env-overridable so the test can shrink them). A non-timeless
  // jukebox auto-ends ttlMs after creation, and its S3 objects are deleted deleteMs after
  // creation; the sweeper runs every sweepMs (plus once at boot).
  ttlMs: parseInt(process.env.JUKEBOX_TTL_MS || String(24 * 60 * 60 * 1000), 10),
  deleteMs: parseInt(process.env.JUKEBOX_DELETE_MS || String(7 * 24 * 60 * 60 * 1000), 10),
  sweepMs: parseInt(process.env.JUKEBOX_SWEEP_MS || String(10 * 60 * 1000), 10),
};

// Public guest URL for a session, e.g. https://jukebox.pocket-dj.com/<id>/ .
// The S3 keys are always jukebox/<id>/… — the distribution's origin path supplies
// the jukebox/ segment, so guestPrefix is empty for jukebox.pocket-dj.com.
const guestUrl = (id) => `${CFG.siteBase}${CFG.guestPrefix ? '/' + CFG.guestPrefix : ''}/${id}/`;

// Rate limiting for the public request endpoint. Per CLIENT: a hard ≥minGapMs gap between one
// guest's requests. Per IP: a SLIDING WINDOW (≤ipWindowMax requests per ipWindowMs), NOT a gap —
// a venue-wifi crowd all NATs to one public IP, so a per-IP gap would throttle the whole room;
// the window caps abuse while letting a busy party request freely. All env-tunable (tests shrink them).
const RL = {
  minGapMs: parseInt(process.env.JUKEBOX_MIN_GAP_MS || '15000', 10),    // ≥Ns between one client's requests
  ipWindowMs: parseInt(process.env.JUKEBOX_IP_WINDOW_MS || '60000', 10), // per-IP sliding window span…
  ipWindowMax: parseInt(process.env.JUKEBOX_IP_WINDOW_MAX || '12', 10),  // …and its request cap
  maxPending: parseInt(process.env.JUKEBOX_MAX_PENDING || '5', 10),      // ≤N pending requests per client at once
  maxLen: 120,        // title/artist cap
};
const STATE_DEBOUNCE_MS = 1_000; // trailing debounce on host state snapshots
const PLAYED_KEEP = 100;    // played-history entries persisted per session…
const PLAYED_PUBLISH = 30;  // …and how many of the newest ride state.json for guests

mkdirSync(CFG.home, { recursive: true });
const log = (...a) => console.log(`[jukebox ${new Date().toISOString()}]`, ...a);

// ---------------- helpers ----------------
const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
function genId(n) { let s = ''; for (const b of randomBytes(n)) s += B32[b & 31]; return s; }
const clean = (s, max = RL.maxLen) => String(s == null ? '' : s).replace(/[\x00-\x1f]/g, ' ').trim().slice(0, max);
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

function writeAtomic(file, body) {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, body);
  renameSync(tmp, file);
}
function writeJson(file, obj) { writeAtomic(file, JSON.stringify(obj)); }
function readJsonFile(file) { try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; } }

function aws(args) {
  return new Promise((res, rej) => {
    execFile('aws', [...args, '--profile', CFG.profile, '--region', CFG.region], { maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => (err ? rej(new Error(stderr || err.message)) : res(stdout)));
  });
}
// Upload one object to the web bucket (no-cache: the guest page polls state.json, and the
// page itself is rewritten per jukebox). JUKEBOX_DRY_RUN mirrors the write to home/dry-run/<key>
// instead of shelling to aws, so the test suite runs with zero AWS access.
async function s3Put(key, body, contentType) {
  if (CFG.dryRun) { writeAtomic(join(CFG.home, 'dry-run', key), body); return; }
  const tmp = join(CFG.home, 'tmp', key.replace(/[/]/g, '__'));
  writeAtomic(tmp, body);
  await aws(['s3', 'cp', tmp, `s3://${CFG.bucket}/${key}`, '--content-type', contentType, '--cache-control', 'no-cache']);
}

// ---------------- storage layer (filesystem today; drops into a Lambda/DynamoDB adapter later) ----------------
// One session dir per jukebox: <home>/<id>/session.json + <home>/<id>/requests/<reqId>.json.
// The persisted session is exactly {id,name,hostKey,createdAt,ended,seqCounter,timeless,played};
// the live object also carries in-memory-only fields (nowPlaying/upNext, rate maps, save chain, timer).
const sessions = new Map(); // id -> live session

const sessionDir = (id) => join(CFG.home, id);
const sessionFile = (id) => join(sessionDir(id), 'session.json');
const requestsDir = (id) => join(sessionDir(id), 'requests');
const requestFile = (id, reqId) => join(requestsDir(id), `${reqId}.json`);

function persistSession(s) {
  writeJson(sessionFile(s.id), { id: s.id, name: s.name, hostKey: s.hostKey, createdAt: s.createdAt, ended: s.ended, seqCounter: s.seqCounter, timeless: !!s.timeless, played: s.played || [] });
}
function persistRequest(s, r) { writeJson(requestFile(s.id, r.id), r); }

// Derived expiry: non-timeless sessions expire ttlMs after creation (timeless → null).
const expiryOf = (s) => (s.timeless ? null : s.createdAt + CFG.ttlMs);

function newSession(name, timeless) {
  const s = {
    id: genId(8), name: clean(name) || 'PocketDJ Jukebox', hostKey: randomBytes(16).toString('hex'),
    createdAt: Date.now(), ended: false, seqCounter: 0, timeless: !!timeless, played: [],
    requests: new Map(), nowPlaying: null, upNext: [], hear: false,
    lastByClient: new Map(), ipHits: new Map(),
    saveChain: Promise.resolve(), stateTimer: null,
  };
  s.expiresAt = expiryOf(s);
  sessions.set(s.id, s);
  persistSession(s);
  return s;
}

// Reload sessions on boot (a mid-life restart resumes them). ENDED tombstones are reloaded
// too — not to serve them (endpoints answer 410) but so the sweeper can still delete their
// S3 objects at the 7-day mark across a restart. The boot sweep drops anything already aged
// out. Rate-limit clocks are rebuilt from the persisted requests so a restart can't reopen a
// spam window.
function loadSessions() {
  let ids = [];
  try { ids = readdirSync(CFG.home, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name); } catch { return; }
  let n = 0;
  for (const id of ids) {
    const meta = readJsonFile(sessionFile(id));
    if (!meta || !meta.id) continue;
    const s = {
      id: meta.id, name: meta.name, hostKey: meta.hostKey, createdAt: meta.createdAt,
      ended: !!meta.ended, seqCounter: meta.seqCounter || 0, timeless: !!meta.timeless,
      played: Array.isArray(meta.played) ? meta.played : [],
      requests: new Map(), nowPlaying: null, upNext: [], hear: false,
      lastByClient: new Map(), ipHits: new Map(),
      saveChain: Promise.resolve(), stateTimer: null,
    };
    s.expiresAt = expiryOf(s);
    let reqFiles = [];
    try { reqFiles = readdirSync(requestsDir(id)).filter((f) => f.endsWith('.json')); } catch { /* none */ }
    for (const f of reqFiles) {
      const r = readJsonFile(join(requestsDir(id), f));
      if (!r || !r.id) continue;
      s.requests.set(r.id, r);
      if (r.clientId) s.lastByClient.set(r.clientId, Math.max(s.lastByClient.get(r.clientId) || 0, r.createdAt || 0));
      if (r.ip) { const a = s.ipHits.get(r.ip) || []; a.push(r.createdAt || 0); s.ipHits.set(r.ip, a); }
    }
    sessions.set(id, s);
    n++;
  }
  if (n) log(`resumed ${n} jukebox session(s)`);
}

// ---------------- state.json composition + publishing ----------------
function sanitizeNowPlaying(np) {
  if (!np || typeof np !== 'object') return null;
  // streamUrl (View + Hear): a PUBLIC rips-bucket mp3. Only https survives (the guest page is
  // served over https, so an http url would be mixed-content-blocked anyway) — never a DRM'd
  // Apple Music stream; the host only ever sends a durable public rip URL here.
  const su = clean(np.streamUrl, 600);
  return {
    title: clean(np.title, 200), artist: clean(np.artist, 200),
    lengthMs: num(np.lengthMs), positionMs: num(np.positionMs),
    streamUrl: /^https:\/\//i.test(su) ? su : null,
  };
}
function sanitizeUpNext(list) {
  if (!Array.isArray(list)) return [];
  return list.slice(0, 50).map((x) => ({ title: clean(x && x.title, 200), artist: clean(x && x.artist, 200) }));
}
// Played history: derived server-side from now-playing TRANSITIONS — when a state POST
// replaces one (sanitized) track with a DIFFERENT one (or with nothing), the outgoing track
// is appended to the session's played log. Deriving here (instead of trusting a client-sent
// list) covers every host source — setlist deck, Auto-DJ mix, single rip plays — with zero
// wire-protocol change, and logs what guests actually saw as Now Playing (a DJ skipping back
// re-logs the re-played track, radio-style). Same title+artist = a position tick, not a
// transition. Persisted in session.json so the log survives restarts; a restart only ever
// costs the one in-flight track (nowPlaying reloads as null → no bogus append either).
function notePlayed(s, next) {
  const prev = s.nowPlaying;
  if (!prev || !prev.title) return;
  if (next && next.title === prev.title && next.artist === prev.artist) {
    // Same track: a position tick — EXCEPT a hard rewind to the intro, which is a
    // back-to-back replay (the DJ queued the same song again, or ⏮ at the top of the
    // set): that first spin deserves its own history entry. Small nudges and forward
    // ticks are not transitions; Mix broadcasts post no position (0 → 0, never trips).
    const rewound = num(prev.positionMs) > 30_000 && num(next.positionMs) < 10_000;
    if (!rewound) return;
  }
  s.played = [...(s.played || []), { title: prev.title, artist: prev.artist, endedAt: Date.now() }].slice(-PLAYED_KEEP);
  persistSession(s);
}
// state.json = host player snapshot ⊕ the last 30 requests' statuses (clientId/ip NOT leaked).
function composeState(s) {
  const requests = [...s.requests.values()].sort((a, b) => a.seq - b.seq).slice(-30)
    .map((r) => ({ id: r.id, title: r.title, artist: r.artist, status: r.status }));
  return {
    v: 1, jukeboxId: s.id, name: s.name, updatedAt: Date.now(), ended: s.ended,
    timeless: !!s.timeless, expiresAt: s.timeless ? null : (s.expiresAt ?? null),
    hear: !!s.hear, nowPlaying: s.nowPlaying || null, upNext: s.upNext || [],
    played: (s.played || []).slice(-PLAYED_PUBLISH), requests,
  };
}
// Serialize per-jukebox S3 writes on the session's own chain (like rip-server's saveManifest)
// so an immediate publish (decision/end) and a debounced one can't upload out of order.
function publishState(s) {
  const key = `jukebox/${s.id}/state.json`;
  const body = JSON.stringify(composeState(s));
  s.saveChain = s.saveChain.then(() => s3Put(key, body, 'application/json'))
    .catch((e) => log(`publishState ${s.id} failed:`, e.message));
  return s.saveChain;
}
function scheduleState(s) {
  if (s.stateTimer) return; // trailing debounce: coalesce a burst into one write ≥1s later
  s.stateTimer = setTimeout(() => { s.stateTimer = null; publishState(s); }, STATE_DEBOUNCE_MS);
  s.stateTimer.unref?.();
}

// ---------------- handlers ((store, params, body, ctx) → {status, json}) ----------------
// Pure-ish over the session store + the S3 writer so the same module lifts into a Lambda
// handler later. Auth is enforced by the HTTP layer before these run.
async function createJukebox(body) {
  const s = newSession(body && body.name, body && body.timeless);
  const page = renderPage(s);
  await s3Put(`jukebox/${s.id}/index.html`, page, 'text/html');
  await publishState(s); // seed state.json so the page has something to poll immediately
  log(`created jukebox ${s.id} "${s.name}"${s.timeless ? ' (timeless)' : ''}`);
  return { status: 200, json: { jukeboxId: s.id, hostKey: s.hostKey, name: s.name, url: guestUrl(s.id), timeless: !!s.timeless, expiresAt: s.timeless ? null : s.expiresAt } };
}

// Flip the lifecycle mode on a live session. Turning timeless OFF recomputes expiresAt from
// the original createdAt, so an already-old session simply expires on the next sweep.
function configJukebox(s, body) {
  s.timeless = !!(body && body.timeless);
  s.expiresAt = expiryOf(s);
  persistSession(s);
  publishState(s); // republish so state.json's timeless/expiresAt reflect the change
  log(`config ${s.id}: timeless=${s.timeless}`);
  return { status: 200, json: { timeless: s.timeless, expiresAt: s.timeless ? null : s.expiresAt } };
}

function endJukebox(s) {
  s.ended = true;
  persistSession(s);
  publishState(s); // final state (ended:true) so guests flip to the ended screen
  log(`ended jukebox ${s.id}`);
  return { status: 200, json: { ok: true, ended: true } };
}

function postState(s, body) {
  s.hear = !!(body && body.hear); // View + Hear toggle (opaque passthrough into state.json)
  const next = sanitizeNowPlaying(body && body.nowPlaying);
  notePlayed(s, next); // log the outgoing track before the snapshot replaces it
  s.nowPlaying = next;
  s.upNext = sanitizeUpNext(body && body.upNext);
  scheduleState(s); // debounced ≥1s (composeState re-merges the live request statuses at write time)
  return { status: 200, json: { ok: true } };
}

function postRequest(s, body, ip) {
  const clientId = clean(body && body.clientId, 100) || 'anon';
  const title = clean(body && body.title);
  const artist = clean(body && body.artist);
  if (!title) return { status: 400, json: { error: 'title required' } };
  const now = Date.now();
  // Per-client gap.
  const lastClient = s.lastByClient.get(clientId) || 0;
  if (now - lastClient < RL.minGapMs) return { status: 429, json: { error: 'too many requests — wait a moment' } };
  // Per-IP sliding window: keep only hits inside the window, reject once the cap is reached.
  const hits = (s.ipHits.get(ip) || []).filter((t) => now - t < RL.ipWindowMs);
  if (hits.length >= RL.ipWindowMax) { s.ipHits.set(ip, hits); return { status: 429, json: { error: 'this network is sending too many requests' } }; }
  const pending = [...s.requests.values()].filter((r) => r.clientId === clientId && r.status === 'pending').length;
  if (pending >= RL.maxPending) return { status: 429, json: { error: 'too many pending requests' } };
  const r = { id: `rq_${randomBytes(6).toString('hex')}`, seq: ++s.seqCounter, jukeboxId: s.id, title, artist, clientId, ip, createdAt: now, status: 'pending' };
  s.requests.set(r.id, r);
  s.lastByClient.set(clientId, now);
  hits.push(now);
  s.ipHits.set(ip, hits);
  persistRequest(s, r);
  persistSession(s); // seqCounter advanced
  scheduleState(s);  // so guests see the new request appear (pending)
  log(`request ${r.id} on ${s.id}: "${title}" — "${artist}"`);
  return { status: 200, json: { requestId: r.id, status: 'pending' } };
}

function getRequests(s, since) {
  const from = Number.isFinite(since) ? since : 0;
  const requests = [...s.requests.values()].filter((r) => r.seq > from).sort((a, b) => a.seq - b.seq)
    .map((r) => ({ id: r.id, seq: r.seq, title: r.title, artist: r.artist, clientId: r.clientId, createdAt: r.createdAt, status: r.status }));
  return { status: 200, json: { requests, seq: s.seqCounter } };
}

function decideRequest(s, reqId, body) {
  const r = s.requests.get(reqId);
  if (!r) return { status: 404, json: { error: 'unknown request' } };
  const action = clean(body && body.action, 20);
  if (!['denied', 'next', 'end', 'random'].includes(action)) return { status: 400, json: { error: 'bad action' } };
  r.status = action === 'denied' ? 'denied' : 'queued';
  r.action = action;
  r.decidedAt = Date.now();
  r.seq = ++s.seqCounter; // bump so the host's next since-poll picks up the flip
  if (body && (body.matchedTitle || body.matchedArtist)) {
    r.matchedTitle = clean(body.matchedTitle, 200);
    r.matchedArtist = clean(body.matchedArtist, 200);
  }
  persistRequest(s, r);
  persistSession(s);
  publishState(s); // immediate republish so guests see the status flip promptly
  log(`decision ${reqId} on ${s.id}: ${action} → ${r.status}`);
  return { status: 200, json: { ok: true, requestId: reqId, status: r.status } };
}

// ---------------- session lifecycle (server-owned expiry + deletion) ----------------
// True once a session is gone (host-ended OR past its expiry). Lazily flips a just-expired
// session to ended + publishes the final state so the window between expiry and the next sweep
// is tight; endpoints then answer 410 (the app folds its local session). A deleted session id
// is simply absent from the map → 404.
function ensureExpiry(s) {
  if (s.ended) return true;
  if (!s.timeless && s.expiresAt != null && Date.now() > s.expiresAt) {
    s.ended = true;
    persistSession(s);
    publishState(s);
    log(`expired jukebox ${s.id}`);
    return true;
  }
  return false;
}
// Purge a session: drop from memory FIRST (no further writes), then remove its S3 prefix +
// the local session dir. In DRY_RUN there's no S3 — remove the mirror dir instead.
function deleteSession(s) {
  sessions.delete(s.id);
  if (CFG.dryRun) { try { rmSync(join(CFG.home, 'dry-run', 'jukebox', s.id), { recursive: true, force: true }); } catch { /* best-effort */ } }
  else aws(['s3', 'rm', `s3://${CFG.bucket}/jukebox/${s.id}/`, '--recursive']).catch((e) => log(`s3 rm ${s.id} failed:`, e.message));
  try { rmSync(sessionDir(s.id), { recursive: true, force: true }); } catch { /* best-effort */ }
  log(`deleted jukebox ${s.id}`);
}
// Sweep every sweepMs (+ once at boot): non-timeless sessions end at ttlMs and are deleted at
// deleteMs (delete wins when both are due). Timeless sessions are never auto-ended or deleted.
function sweep() {
  const now = Date.now();
  for (const s of [...sessions.values()]) {
    if (!s.timeless) {
      if (now > s.createdAt + CFG.deleteMs) { deleteSession(s); continue; }
      if (!s.ended && s.expiresAt != null && now > s.expiresAt) {
        s.ended = true; persistSession(s); publishState(s); log(`swept-expired ${s.id}`);
      }
    }
    // SELF-HEAL the guest page for every live session. The page normally uploads once
    // at create — but an external pruner can delete it (lesson: nightly catalog deploys
    // run `deploy.sh --delete` from main-branch clones that predate the jukebox/*
    // exclude, wiping live pages overnight; state.json self-healed via the host
    // heartbeat, index.html silently 404'd guests into the PWA shell). Re-putting each
    // sweep (boot + every 10 min) is one tiny idempotent upload per live session and
    // makes the page survive ANY future prune, not just that one.
    if (!s.ended) {
      s3Put(`jukebox/${s.id}/index.html`, renderPage(s), 'text/html')
        .catch((e) => log(`page re-put ${s.id} failed:`, e.message));
    }
  }
}

// ---------------- page render ----------------
let templateCache = null;
function renderPage(s) {
  if (templateCache == null) {
    try { templateCache = readFileSync(CFG.template, 'utf8'); }
    catch (e) { log('template read failed:', e.message); templateCache = '<!doctype html><title>__JUKEBOX_NAME__</title><body>Jukebox __JUKEBOX_ID__</body>'; }
  }
  const esc = (x) => String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  return templateCache
    .replace(/__JUKEBOX_ID__/g, esc(s.id))
    .replace(/__JUKEBOX_NAME__/g, esc(s.name))
    .replace(/__API_BASE__/g, esc(CFG.publicBase))
    .replace(/__STATE_URL__/g, esc(`${guestUrl(s.id)}state.json`));
}

// ---------------- HTTP ----------------
function send(res, status, body) {
  const payload = body == null || typeof body === 'string' ? (body || '') : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': typeof body === 'string' ? 'text/plain' : 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization,content-type',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  });
  res.end(payload);
}
async function readJson(req) {
  return new Promise((res) => { let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => { try { res(b ? JSON.parse(b) : {}); } catch { res({}); } }); });
}
function bearer(req) { const m = (req.headers['authorization'] || '').match(/^Bearer\s+(.+)$/i); return m ? m[1] : ''; }
function clientIp(req) { return (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress || 'unknown'; }
const tokenOk = (req) => !CFG.token || bearer(req) === CFG.token;
const hostKeyOf = (req, url) => bearer(req) || url.searchParams.get('hostKey') || '';
const hostOk = (s, req, url) => !!s && hostKeyOf(req, url) === s.hostKey;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'OPTIONS') return send(res, 204, '');

  // Prefix normalization: behind `tailscale funnel --set-path /jukebox` the funnel strips the
  // mount, but the rendered page's fetch paths ALSO carry /jukebox, so requests land here with
  // a leading /jukebox. Strip one so both direct (/jukebox/<id>/…) and funnel access dispatch
  // against the same un-prefixed routes below.
  let path = url.pathname;
  if (path === '/jukebox') path = '/';
  else if (path.startsWith('/jukebox/')) path = path.slice('/jukebox'.length);

  if (path === '/health') {
    return send(res, 200, { ok: true, service: 'jukebox', version: VERSION, host: hostname(), bucket: CFG.bucket, sessions: sessions.size, auth: !!CFG.token });
  }

  // POST / (create) — token-gated when JUKEBOX_TOKEN is set.
  if ((path === '/' || path === '') && req.method === 'POST') {
    if (!tokenOk(req)) return send(res, 401, { error: 'unauthorized' });
    const r = await createJukebox(await readJson(req));
    return send(res, r.status, r.json);
  }

  // Everything else is /:id/… — resolve the session first.
  const m = path.match(/^\/([a-z2-7]{4,32})(\/.*)?$/);
  if (!m) return send(res, 404, { error: 'not found' });
  const s = sessions.get(m[1]);
  const rest = m[2] || '';

  // Public guest request — no host key, but rate-limited. An unknown id → 404; an
  // ended/expired one → 410 (the app folds its local session on either).
  if (rest === '/request' && req.method === 'POST') {
    if (!s) return send(res, 404, { error: 'unknown jukebox' });
    if (ensureExpiry(s)) return send(res, 410, { error: 'jukebox ended' });
    const r = postRequest(s, await readJson(req), clientIp(req));
    return send(res, r.status, r.json);
  }

  // All remaining routes are host-only (host key via Bearer or ?hostKey=).
  if (!hostOk(s, req, url)) return send(res, s ? 401 : 404, { error: s ? 'unauthorized' : 'unknown jukebox' });
  // Once ended/expired, host endpoints answer 410 (config can't un-expire — the DJ starts anew).
  if (ensureExpiry(s)) return send(res, 410, { error: 'jukebox ended' });

  if (rest === '/end' && req.method === 'POST') return finish(res, endJukebox(s));
  if (rest === '/state' && req.method === 'POST') return finish(res, postState(s, await readJson(req)));
  if (rest === '/config' && req.method === 'POST') return finish(res, configJukebox(s, await readJson(req)));
  if (rest === '/requests' && req.method === 'GET') return finish(res, getRequests(s, parseInt(url.searchParams.get('since') || '0', 10)));
  const dm = rest.match(/^\/requests\/(rq_[a-f0-9]+)\/decision$/);
  if (dm && req.method === 'POST') return finish(res, decideRequest(s, dm[1], await readJson(req)));

  return send(res, 404, { error: 'not found' });

  function finish(r, out) { return send(r, out.status, out.json); }
});

// ---------------- boot ----------------
if (process.argv.includes('--version')) { console.log(VERSION); process.exit(0); }
log('PocketDJ jukebox-server starting…');
loadSessions();
sweep(); // end/delete anything that aged out while we were down
setInterval(sweep, CFG.sweepMs).unref?.();
server.listen(CFG.port, () => {
  log(`✓ listening on http://localhost:${CFG.port}  (bucket=${CFG.bucket}, siteBase=${CFG.siteBase}, auth=${CFG.token ? 'on' : 'off'}, dryRun=${CFG.dryRun})`);
});
