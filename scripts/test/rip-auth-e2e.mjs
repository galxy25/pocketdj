#!/usr/bin/env node
// e2e of the PUBLIC auth surface (Tailscale Funnel promotion) — no S3, no worker.
// Public posture is the server's DEFAULT (beta doctrine: always boots; tokens enforced
// when provided; rate limiting is a feature flag, default OFF). Asserts: posture
// defaults (public on by default, RIP_PUBLIC=0 opt-out, tokenless boot allowed) · the
// tier map (health open · user endpoints 401 without / 200-404 with the user token ·
// admin endpoints 403 at user tier, 200 at admin tier) · rate limiting OFF by default
// even past the POST cap, and tripping only under RIP_RATE_LIMIT=1 (admin exempt).
//
//   node scripts/test/rip-auth-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8798;
const USER = 'user-secret';
const ADMIN = 'admin-secret';
const base = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-auth-'));
const catalog = join(work, 'catalog.json');
writeFileSync(catalog, JSON.stringify({
  manifest: { sourceType: 'digital', sourceName: 'Test' },
  albums: [], songs: [],
}));

const baseEnv = {
  ...process.env,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-nonexistent-bucket-xyz', // loadManifest fails → empty manifest, no real S3
  RIP_SOURCES: catalog,
  HOME: join(work, 'home'), // isolate ~/.pocketdj (incl. any real rip-server.env)
  RIP_RL_WINDOW_MS: '60000',
  RIP_RL_POST_MAX: '5', // tiny so the rate-limit assertions are fast
};
delete baseEnv.RIP_PUBLIC; delete baseEnv.RIP_TOKEN; delete baseEnv.RIP_ADMIN_TOKEN;
delete baseEnv.RIP_RATE_LIMIT;

// Boot a server with `env`, wait for /health, run `fn(health)`, then tear down fully
// (sequential boots share PORT, so each must exit before the next starts).
async function withServer(env, fn) {
  const p = spawn('node', [join(REPO, 'scripts/rip-server.mjs')],
    { env, stdio: ['ignore', 'inherit', 'inherit'] });
  try {
    let health = null;
    for (let i = 0; i < 50; i++) {
      try { const r = await fetch(`${base}/health`); if (r.ok) { health = await r.json(); break; } } catch { /* not yet */ }
      await sleep(200);
    }
    await fn(health);
  } finally {
    // A child that already died (boot crash, port clash) fired 'exit' before this
    // listener could attach — resolve immediately or the harness wedges forever.
    if (p.exitCode !== null || p.signalCode !== null) {
      // already gone
    } else {
      const gone = new Promise((r) => p.once('exit', r));
      p.kill('SIGTERM');
      await gone;
    }
  }
}

// Stub iTunes Search API (hermetic — no network) for the /search proxy assertions.
const SEARCH_PORT = 8797;
const stub = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ results: [{ trackId: 12345, trackName: 'Stub Song', artistName: 'Stub Artist',
    collectionName: 'Stub Album', artworkUrl100: 'https://x/art.jpg', trackTimeMillis: 61_000 }] }));
}).listen(SEARCH_PORT);

const asUser = { 'content-type': 'application/json', Authorization: `Bearer ${USER}` };
const asAdmin = { 'content-type': 'application/json', Authorization: `Bearer ${ADMIN}` };

try {
  console.log('posture defaults…');
  await withServer(baseEnv, async (health) => {
    ok(!!health, 'tokenless boot is ALLOWED (no refusal — beta doctrine)');
    ok(health && health.public === true, 'public posture is the DEFAULT (no RIP_PUBLIC set)');
    ok(health && health.auth === false && health.rateLimit === false,
      'tokenless default: auth off, rate limit off');
    // /health is unauthenticated even when auth is ON — prove openness on a REAL
    // endpoint (user-tier POST that would 401 under auth).
    const r = await fetch(`${base}/rip-cancel`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ songIds: [] }) });
    ok(r.status === 200, 'tokenless: unauthenticated POST reaches the real handler (200)');
  });
  await withServer({ ...baseEnv, RIP_PUBLIC: '0' }, async (health) => {
    ok(health && health.public === false, 'RIP_PUBLIC=0 opts out of public posture');
  });

  console.log('tier map + search + rate-limit-off (default boot, both tokens)…');
  await withServer({ ...baseEnv, RIP_TOKEN: USER, RIP_ADMIN_TOKEN: ADMIN,
    RIP_SEARCH_BASE: `http://localhost:${SEARCH_PORT}/search` }, async (health) => {
    ok(!!health, 'health is reachable without a token');
    ok(health && health.auth === true && health.public === true, 'health reports auth+public');
    ok(health && health.rateLimit === false, 'rate limiting is OFF by default');

    let r = await fetch(`${base}/rip`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ songId: 'sng_x' }) });
    ok(r.status === 401, 'POST /rip without token → 401');
    r = await fetch(`${base}/rip`, { method: 'POST', headers: asUser, body: JSON.stringify({ songId: 'sng_x' }) });
    ok(r.status === 404, 'POST /rip with user token passes auth (404 unknown song)');

    r = await fetch(`${base}/ingest-digital`, { method: 'POST', headers: asUser, body: JSON.stringify({ entries: [] }) });
    ok(r.status === 403, 'admin endpoint at user tier → 403');
    r = await fetch(`${base}/ingest-digital`, { method: 'POST', headers: asAdmin, body: JSON.stringify({ entries: [] }) });
    ok(r.status === 200, 'admin endpoint at admin tier → 200');
    r = await fetch(`${base}/backfill-stems`, { method: 'POST', headers: asUser, body: '{}' });
    ok(r.status === 403, 'backfill-stems at user tier → 403');

    // /search (Browse ▸ Discover): user-tier, proxied through the stub, annotated with amrec_ ids.
    r = await fetch(`${base}/search?q=stub`);
    ok(r.status === 401, 'GET /search without token → 401');
    r = await fetch(`${base}/search?q=stub`, { headers: asUser });
    const sr = r.ok ? await r.json() : null;
    ok(r.status === 200 && sr?.results?.length === 1, 'GET /search with user token → results');
    const hit = sr?.results?.[0] || {};
    ok(hit.songId === 'amrec_12345' && hit.ripped === false && hit.title === 'Stub Song'
      && hit.appleMusicId === '12345' && hit.durationMs === 61_000, 'search hit mapped + amrec_ id + not ripped');
    r = await fetch(`${base}/search?q=`, { headers: asUser });
    ok(r.status === 400, 'GET /search without q → 400');

    // Default boot: blow well past the tiny POST cap and never see a 429.
    let limited = false;
    for (let i = 0; i < 10; i++) {
      r = await fetch(`${base}/rip-cancel`, { method: 'POST', headers: asUser, body: JSON.stringify({ songIds: [] }) });
      if (r.status === 429) { limited = true; break; }
    }
    ok(!limited, 'user tier is NEVER rate-limited without the flag (10 POSTs > cap, no 429)');
  });

  console.log('rate limiting under RIP_RATE_LIMIT=1…');
  await withServer({ ...baseEnv, RIP_TOKEN: USER, RIP_ADMIN_TOKEN: ADMIN, RIP_RATE_LIMIT: '1' }, async (health) => {
    ok(health && health.rateLimit === true, 'health reports the armed rate limit');
    // Deterministic cap semantics (fresh process, 60s window ≫ this loop): the first
    // POST_MAX(5) user POSTs must SUCCEED, the 6th must 429 — "some 429 happened"
    // would also pass under an over-aggressive limiter that denies everything.
    const statuses = [];
    let r;
    for (let i = 0; i < 6; i++) {
      r = await fetch(`${base}/rip-cancel`, { method: 'POST', headers: asUser, body: JSON.stringify({ songIds: [] }) });
      statuses.push(r.status);
    }
    ok(statuses.slice(0, 5).every((s) => s === 200) && statuses[5] === 429,
      `armed cap is exact: 5×200 then 429 (got ${statuses.join(',')})`);
    r = await fetch(`${base}/rip-cancel`, { method: 'POST', headers: asAdmin, body: JSON.stringify({ songIds: [] }) });
    ok(r.status === 200, 'admin tier is exempt from the rate limit');
  });
} finally {
  stub.close();
  rmSync(work, { recursive: true, force: true });
}

console.log(fail ? `\n${fail} FAILED` : '\nall auth e2e checks passed');
process.exit(fail ? 1 : 0);
