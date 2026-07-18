#!/usr/bin/env node
// e2e of the PUBLIC-mode auth surface (Tailscale Funnel promotion) — no S3, no worker.
// Boots the real rip-server with RIP_PUBLIC=1 + both tokens and asserts the tier map:
// health open · user endpoints 401 without / 200-404 with the user token · admin
// endpoints 403 at user tier, 200 at admin tier · per-IP POST rate limit trips for the
// user tier but never for admin · boot REFUSES public mode with missing/equal tokens.
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
  HOME: join(work, 'home'), // isolate ~/.pocketdj
  RIP_RL_WINDOW_MS: '60000',
  RIP_RL_POST_MAX: '5', // tiny so the rate-limit assertion is fast
};

// A public-mode boot that should die immediately; resolves its exit code.
function bootExpectExit(env) {
  return new Promise((res) => {
    const p = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: 'ignore' });
    const t = setTimeout(() => { p.kill('SIGKILL'); res(null); }, 5000);
    p.on('exit', (code) => { clearTimeout(t); res(code); });
  });
}

console.log('public mode refuses bad token configs…');
ok((await bootExpectExit({ ...baseEnv, RIP_PUBLIC: '1' })) === 1, 'no tokens → exit 1');
ok((await bootExpectExit({ ...baseEnv, RIP_PUBLIC: '1', RIP_TOKEN: USER })) === 1, 'missing admin token → exit 1');
ok((await bootExpectExit({ ...baseEnv, RIP_PUBLIC: '1', RIP_TOKEN: USER, RIP_ADMIN_TOKEN: USER })) === 1, 'equal tokens → exit 1');

// Stub iTunes Search API (hermetic — no network) for the /search proxy assertions.
const SEARCH_PORT = 8797;
const stub = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ results: [{ trackId: 12345, trackName: 'Stub Song', artistName: 'Stub Artist',
    collectionName: 'Stub Album', artworkUrl100: 'https://x/art.jpg', trackTimeMillis: 61_000 }] }));
}).listen(SEARCH_PORT);

console.log('booting rip-server (public mode, both tokens)…');
const srv = spawn('node', [join(REPO, 'scripts/rip-server.mjs')],
  { env: { ...baseEnv, RIP_PUBLIC: '1', RIP_TOKEN: USER, RIP_ADMIN_TOKEN: ADMIN,
    RIP_SEARCH_BASE: `http://localhost:${SEARCH_PORT}/search` }, stdio: ['ignore', 'inherit', 'inherit'] });
const asUser = { 'content-type': 'application/json', Authorization: `Bearer ${USER}` };
const asAdmin = { 'content-type': 'application/json', Authorization: `Bearer ${ADMIN}` };

try {
  let health = null;
  for (let i = 0; i < 50; i++) {
    try { const r = await fetch(`${base}/health`); if (r.ok) { health = await r.json(); break; } } catch { /* not yet */ }
    await sleep(200);
  }
  ok(!!health, 'health is reachable without a token');
  ok(health && health.auth === true && health.public === true, 'health reports auth+public');

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

  // Rate limit: POST cap is 5/window; we already spent 2 user POSTs above. Spend more
  // until 429; admin stays exempt afterwards.
  let limited = false;
  for (let i = 0; i < 10; i++) {
    r = await fetch(`${base}/rip-cancel`, { method: 'POST', headers: asUser, body: JSON.stringify({ songIds: [] }) });
    if (r.status === 429) { limited = true; break; }
  }
  ok(limited, 'user tier trips the per-IP POST rate limit (429)');
  r = await fetch(`${base}/rip-cancel`, { method: 'POST', headers: asAdmin, body: JSON.stringify({ songIds: [] }) });
  ok(r.status === 200, 'admin tier is exempt from the rate limit');
} finally {
  srv.kill('SIGTERM');
  stub.close();
  rmSync(work, { recursive: true, force: true });
}

console.log(fail ? `\n${fail} FAILED` : '\nall auth e2e checks passed');
process.exit(fail ? 1 : 0);
