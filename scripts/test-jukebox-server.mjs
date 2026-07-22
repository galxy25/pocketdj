// Smoke suite for scripts/jukebox-server.mjs. Spawns the real server as a child process on a
// free port with JUKEBOX_DRY_RUN=1 (S3 writes go to <home>/dry-run/<key> — no AWS), a temp
// JUKEBOX_HOME, and JUKEBOX_TOKEN=testtoken. Exercises the full host+guest lifecycle end to end,
// including rate-limiting, decision status flips, dry-run state.json composition, and restart
// persistence (kill + respawn with the same JUKEBOX_HOME).
//
//   node --test scripts/test-jukebox-server.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SERVER = join(__dirname, 'jukebox-server.mjs');
const TOKEN = 'testtoken';
const HOME = mkdtempSync(join(tmpdir(), 'jukebox-test-'));

let child = null;
let PORT = 0;
const BASE = () => `http://127.0.0.1:${PORT}`;

function freePort() {
  return new Promise((res, rej) => {
    const srv = net.createServer();
    srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => { const p = srv.address().port; srv.close(() => res(p)); });
  });
}

function spawnServer() {
  const c = spawn(process.execPath, [SERVER], {
    // JUKEBOX_MIN_GAP_MS=800: an immediate second request from the same client still trips the
    // rate limit (round-trip ≪800ms), but a later request from another client on the same
    // localhost IP (all tests share 127.0.0.1) is not blocked by the shared per-IP clock.
    env: { ...process.env, JUKEBOX_PORT: String(PORT), JUKEBOX_HOME: HOME, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1', JUKEBOX_MIN_GAP_MS: '800' },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  return c;
}

async function waitHealthy(timeoutMs = 5000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const r = await fetch(`${BASE()}/health`); if (r.ok) return; } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not become healthy');
}

async function reqAt(port, method, path, { token, hostKey, body } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (hostKey) headers['Authorization'] = `Bearer ${hostKey}`;
  const r = await fetch(`http://127.0.0.1:${port}${path}`, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined });
  let json = null; try { json = await r.json(); } catch { /* non-json */ }
  return { status: r.status, json };
}
const req = (method, path, opts) => reqAt(PORT, method, path, opts);

function stateFileIn(home, id) { return join(home, 'dry-run', 'jukebox', id, 'state.json'); }
function stateFile(id) { return stateFileIn(HOME, id); }
function readState(id) { return JSON.parse(readFileSync(stateFile(id), 'utf8')); }
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

before(async () => { PORT = await freePort(); child = spawnServer(); await waitHealthy(); });
after(() => { if (child) child.kill('SIGKILL'); });

let jb = null; // main lifecycle jukebox

test('health reports the jukebox service + version', async () => {
  const r = await req('GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.service, 'jukebox');
  assert.ok(r.json.version >= 2, 'v2 = played history — the app detects capabilities via this');
});

test('create requires the token when one is configured', async () => {
  const noauth = await req('POST', '/jukebox', { body: { name: 'Garage Party' } });
  assert.equal(noauth.status, 401);
  const r = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Garage Party' } });
  assert.equal(r.status, 200);
  assert.match(r.json.jukeboxId, /^[a-z2-7]{8}$/);
  assert.match(r.json.hostKey, /^[a-f0-9]{32}$/);
  assert.equal(r.json.name, 'Garage Party'); // app's JukeboxSessionInfo decoder requires name
  // Guest URL ends in /<id>/ ; the /jukebox segment now lives in the CDN origin path
  // (jukebox.pocket-dj.com) rather than the public URL, so assert the id path only.
  assert.ok(r.json.url.endsWith(`/${r.json.jukeboxId}/`));
  jb = r.json;
  assert.equal(r.json.timeless, false);
  assert.equal(typeof r.json.expiresAt, 'number'); // non-timeless → 24h expiry
  // create seeds state.json (dry-run)
  assert.ok(existsSync(stateFile(jb.jukeboxId)));
  const st = readState(jb.jukeboxId);
  assert.equal(st.v, 1);
  assert.equal(st.ended, false);
  assert.equal(st.hear, false);          // view-only by default
  assert.equal(typeof st.expiresAt, 'number');
});

let reqId = null;

test('guest request is accepted, second immediate one from same client is rate-limited', async () => {
  const first = await req('POST', `/jukebox/${jb.jukeboxId}/request`, { body: { title: 'One More Time', artist: 'Daft Punk', clientId: 'guest-A' } });
  assert.equal(first.status, 200);
  assert.match(first.json.requestId, /^rq_[a-f0-9]+$/);
  reqId = first.json.requestId;
  const second = await req('POST', `/jukebox/${jb.jukeboxId}/request`, { body: { title: 'Around the World', artist: 'Daft Punk', clientId: 'guest-A' } });
  assert.equal(second.status, 429);
});

test('empty title is rejected', async () => {
  const r = await req('POST', `/jukebox/${jb.jukeboxId}/request`, { body: { title: '   ', artist: 'x', clientId: 'guest-Z' } });
  assert.equal(r.status, 400);
});

test('host polls requests and sees the pending request', async () => {
  const unauth = await req('GET', `/jukebox/${jb.jukeboxId}/requests?since=0`);
  assert.equal(unauth.status, 401);
  const r = await req('GET', `/jukebox/${jb.jukeboxId}/requests?since=0`, { hostKey: jb.hostKey });
  assert.equal(r.status, 200);
  const found = r.json.requests.find((x) => x.id === reqId);
  assert.ok(found, 'request should be visible to the host');
  assert.equal(found.status, 'pending');
  assert.equal(found.clientId, 'guest-A');
  assert.ok(r.json.seq >= found.seq);
});

test('decision denied flips the request status', async () => {
  const r = await req('POST', `/jukebox/${jb.jukeboxId}/requests/${reqId}/decision`, { hostKey: jb.hostKey, body: { action: 'denied' } });
  assert.equal(r.status, 200);
  assert.equal(r.json.status, 'denied');
  const poll = await req('GET', `/jukebox/${jb.jukeboxId}/requests?since=0`, { hostKey: jb.hostKey });
  assert.equal(poll.json.requests.find((x) => x.id === reqId).status, 'denied');
});

test('state POST merges nowPlaying with request statuses into dry-run state.json', async () => {
  const r = await req('POST', `/jukebox/${jb.jukeboxId}/state`, {
    hostKey: jb.hostKey,
    body: { nowPlaying: { title: 'Harder Better', artist: 'Daft Punk', lengthMs: 224000, positionMs: 61000 }, upNext: [{ title: 'Digital Love', artist: 'Daft Punk' }] },
  });
  assert.equal(r.status, 200);
  await wait(1300); // trailing debounce ≥1s
  const st = readState(jb.jukeboxId);
  assert.equal(st.nowPlaying.title, 'Harder Better');
  assert.equal(st.upNext[0].title, 'Digital Love');
  const merged = st.requests.find((x) => x.id === reqId);
  assert.ok(merged, 'request should appear in state.json');
  assert.equal(merged.status, 'denied');
  assert.equal(merged.clientId, undefined, 'clientId must not leak into public state.json');
});

test('View + Hear threads hear + https streamUrl into state.json (http dropped)', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Hear Party' } });
  const h = created.json;
  const good = 'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com/rips/xyz.mp3';
  await req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { hear: true, nowPlaying: { title: 'One More Time', artist: 'Daft Punk', lengthMs: 320000, positionMs: 1000, streamUrl: good }, upNext: [] } });
  await wait(1300);
  let st = readState(h.jukeboxId);
  assert.equal(st.hear, true);
  assert.equal(st.nowPlaying.streamUrl, good);
  // hear off + a non-https url → hear false, streamUrl dropped to null
  await req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { hear: false, nowPlaying: { title: 'x', artist: 'y', streamUrl: 'http://insecure/rips/x.mp3' }, upNext: [] } });
  await wait(1300);
  st = readState(h.jukeboxId);
  assert.equal(st.hear, false);
  assert.equal(st.nowPlaying.streamUrl, null);
});

test('played history: now-playing transitions accumulate; position ticks do not', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'History Party' } });
  const h = created.json;
  const post = (np) => req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { nowPlaying: np, upNext: [] } });
  await post({ title: 'Track One', artist: 'Alpha', lengthMs: 180000, positionMs: 0 });
  await post({ title: 'Track One', artist: 'Alpha', lengthMs: 180000, positionMs: 60000 }); // same track: a position tick
  await post({ title: 'Track Two', artist: 'Beta', lengthMs: 180000, positionMs: 0 });      // transition → Track One played
  await wait(1300); // trailing debounce
  let st = readState(h.jukeboxId);
  assert.equal(st.played.length, 1, 'exactly one transition should be logged');
  assert.equal(st.played[0].title, 'Track One');
  assert.equal(st.played[0].artist, 'Alpha');
  assert.equal(typeof st.played[0].endedAt, 'number');
  // Stopping playback (nowPlaying → null) logs the outgoing track too.
  await post(null);
  await wait(1300);
  st = readState(h.jukeboxId);
  assert.equal(st.played.length, 2);
  assert.equal(st.played[1].title, 'Track Two');
  // The log rides session.json (not in-memory only), so it can survive a restart.
  const meta = JSON.parse(readFileSync(join(HOME, h.jukeboxId, 'session.json'), 'utf8'));
  assert.equal(meta.played.length, 2);
});

test('played history: replaying/rewinding the current track does NOT stack duplicate rows', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Replay Party' } });
  const h = created.json;
  const post = (np) => req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { nowPlaying: np, upNext: [] } });
  await post({ title: 'Encore', artist: 'Alpha', lengthMs: 180000, positionMs: 170000 }); // near the end
  await post({ title: 'Encore', artist: 'Alpha', lengthMs: 180000, positionMs: 2000 });   // ⏮ back to intro: a restart, not history
  await post({ title: 'Encore', artist: 'Alpha', lengthMs: 180000, positionMs: 6000 });   // small forward tick
  await wait(1300);
  let st = readState(h.jukeboxId);
  assert.equal(st.played.length, 0, 'a track still playing (even replayed) is not history yet');
  // Only a move to a DIFFERENT track logs Encore — exactly once, despite the replay.
  await post({ title: 'Closer', artist: 'Beta', lengthMs: 180000, positionMs: 0 });
  await wait(1300);
  st = readState(h.jukeboxId);
  assert.equal(st.played.length, 1, 'the replayed song is logged once, on the real transition');
  assert.equal(st.played[0].title, 'Encore');
});

test('played history: pause/resume (now-playing → null → same track) logs one row per track, not one per play', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Pause Party' } });
  const h = created.json;
  const post = (np) => req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { nowPlaying: np, upNext: [] } });
  const bear = { title: 'Bear', artist: '6LACK', lengthMs: 200000, positionMs: 1000 };
  await post(bear);            // playing
  await post(null);           // pause clears now-playing → logs Bear (append)
  await post(bear);           // resume
  await post(null);           // pause again → same as last logged: fold, don't stack
  await post(bear);           // resume
  await post(null);           // pause again → fold
  await wait(1300);
  let st = readState(h.jukeboxId);
  assert.equal(st.played.length, 1, 'four pause/resume cycles on one song = a single history row');
  assert.equal(st.played[0].title, 'Bear');
  // A genuinely different track still logs normally after all that pausing.
  await post({ title: 'Free', artist: '6LACK', lengthMs: 200000, positionMs: 0 });
  await wait(1300);
  st = readState(h.jukeboxId);
  assert.equal(st.played.length, 1, 'Bear is still one row; Free is now playing, not yet history');
});

test('played history: the SAME song replayed after other tracks gets its own row (non-consecutive is not a dup)', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Radio Party' } });
  const h = created.json;
  const post = (t, a) => req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { nowPlaying: { title: t, artist: a, lengthMs: 180000, positionMs: 0 }, upNext: [] } });
  await post('Bear', '6LACK');   // now playing
  await post('Free', '6LACK');   // → Bear logged
  await post('Bear', '6LACK');   // → Free logged
  await post('Pretty', '6LACK'); // → Bear logged again (Free sat between the two Bears)
  await wait(1300);
  const st = readState(h.jukeboxId);
  assert.deepEqual(st.played.map((x) => x.title), ['Bear', 'Free', 'Bear'], 'only CONSECUTIVE repeats collapse');
});

test('played history: a legacy log with consecutive duplicates is collapsed in state.json', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Legacy Party' } });
  const h = created.json;
  // Simulate a session.json written before the dedup shipped: a played log riddled with
  // consecutive duplicates (what the old rewind heuristic + pause/null posts produced).
  const file = join(HOME, h.jukeboxId, 'session.json');
  const meta = JSON.parse(readFileSync(file, 'utf8'));
  meta.played = [
    { title: 'Bear', artist: '6LACK', endedAt: 1 }, { title: 'Bear', artist: '6LACK', endedAt: 2 },
    { title: 'Bear', artist: '6LACK', endedAt: 3 }, { title: 'Bulletproof', artist: 'La Roux', endedAt: 4 },
    { title: 'Bulletproof', artist: 'La Roux', endedAt: 5 }, { title: 'Quicksand', artist: 'La Roux', endedAt: 6 },
  ];
  writeFileSync(file, JSON.stringify(meta));
  child.kill('SIGKILL');
  await new Promise((r) => child.on('exit', r));
  child = spawnServer();
  await waitHealthy();
  // A post-restart state POST republishes state.json from the reloaded (still-polluted) log.
  await req('POST', `/jukebox/${h.jukeboxId}/state`, { hostKey: h.hostKey, body: { nowPlaying: { title: 'Fascination', artist: 'La Roux', positionMs: 0 }, upNext: [] } });
  await wait(1300);
  const st = readState(h.jukeboxId);
  assert.deepEqual(st.played.map((x) => x.title), ['Bear', 'Bulletproof', 'Quicksand'], 'consecutive dups folded for guests');
  assert.equal(st.played[0].endedAt, 3, 'the folded row keeps the latest endedAt');
});

test('played history caps: state.json publishes the newest 30, session.json keeps 100', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Marathon Party' } });
  const h = created.json;
  for (let i = 0; i < 106; i++) {
    await req('POST', `/jukebox/${h.jukeboxId}/state`, {
      hostKey: h.hostKey,
      body: { nowPlaying: { title: `Track ${i}`, artist: 'Cap', lengthMs: 1000, positionMs: 0 }, upNext: [] },
    });
  }
  await wait(1300); // 105 transitions logged (Track 105 is still "playing")
  const st = readState(h.jukeboxId);
  assert.equal(st.played.length, 30, 'guests get the newest 30');
  assert.equal(st.played[29].title, 'Track 104', 'newest last');
  assert.equal(st.played[0].title, 'Track 75');
  const meta = JSON.parse(readFileSync(join(HOME, h.jukeboxId, 'session.json'), 'utf8'));
  assert.equal(meta.played.length, 100, 'disk log capped at 100');
  assert.equal(meta.played[99].title, 'Track 104');
});

test('timeless create has no expiry; config flips the lifecycle mode', async () => {
  const t = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Forever Party', timeless: true } });
  assert.equal(t.status, 200);
  assert.equal(t.json.timeless, true);
  assert.equal(t.json.expiresAt, null);
  await wait(50);
  const st = readState(t.json.jukeboxId);
  assert.equal(st.timeless, true);
  assert.equal(st.expiresAt, null);
  // flip timeless OFF → gains a numeric expiry; back ON → null again
  const off = await req('POST', `/jukebox/${t.json.jukeboxId}/config`, { hostKey: t.json.hostKey, body: { timeless: false } });
  assert.equal(off.status, 200);
  assert.equal(off.json.timeless, false);
  assert.equal(typeof off.json.expiresAt, 'number');
  const on = await req('POST', `/jukebox/${t.json.jukeboxId}/config`, { hostKey: t.json.hostKey, body: { timeless: true } });
  assert.equal(on.json.timeless, true);
  assert.equal(on.json.expiresAt, null);
  // config requires the host key
  const unauth = await req('POST', `/jukebox/${t.json.jukeboxId}/config`, { body: { timeless: false } });
  assert.equal(unauth.status, 401);
});

test('end marks the jukebox ended in state.json', async () => {
  const r = await req('POST', `/jukebox/${jb.jukeboxId}/end`, { hostKey: jb.hostKey });
  assert.equal(r.status, 200);
  assert.equal(r.json.ended, true);
  await wait(200);
  assert.equal(readState(jb.jukeboxId).ended, true);
});

test('sessions + requests + played history survive a restart (durable, reloaded on boot)', async () => {
  // A separate, still-live jukebox (ended ones are intentionally not reloaded).
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Persist Party' } });
  const live = created.json;
  const made = await req('POST', `/jukebox/${live.jukeboxId}/request`, { body: { title: 'Voyager', artist: 'Daft Punk', clientId: 'guest-P' } });
  assert.equal(made.status, 200);
  // One now-playing transition before the crash → one played entry on disk.
  await req('POST', `/jukebox/${live.jukeboxId}/state`, { hostKey: live.hostKey, body: { nowPlaying: { title: 'Overture', artist: 'Daft Punk' }, upNext: [] } });
  await req('POST', `/jukebox/${live.jukeboxId}/state`, { hostKey: live.hostKey, body: { nowPlaying: { title: 'Voyager', artist: 'Daft Punk' }, upNext: [] } });

  child.kill('SIGKILL');
  await new Promise((r) => child.on('exit', r));
  child = spawnServer();
  await waitHealthy();

  const poll = await req('GET', `/jukebox/${live.jukeboxId}/requests?since=0`, { hostKey: live.hostKey });
  assert.equal(poll.status, 200);
  assert.ok(poll.json.requests.find((x) => x.id === made.json.requestId), 'request should reload after restart');
  // A post-restart state POST republishes state.json — with the reloaded played log. The
  // reloaded nowPlaying is null, so this re-post must NOT double-log the in-flight track.
  await req('POST', `/jukebox/${live.jukeboxId}/state`, { hostKey: live.hostKey, body: { nowPlaying: { title: 'Voyager', artist: 'Daft Punk' }, upNext: [] } });
  await wait(1300);
  const st = readState(live.jukeboxId);
  assert.equal(st.played.length, 1, 'played history should reload after restart, without duplicates');
  assert.equal(st.played[0].title, 'Overture');
});

test('sweeper: a non-timeless session expires (410) and is then deleted (404 + dirs gone)', async () => {
  // A dedicated server with tiny lifecycle TTLs: end at 300ms, delete at 1200ms, sweep 120ms.
  const HOME2 = mkdtempSync(join(tmpdir(), 'jukebox-sweep-'));
  const PORT2 = await freePort();
  const c2 = spawn(process.execPath, [SERVER], {
    env: { ...process.env, JUKEBOX_PORT: String(PORT2), JUKEBOX_HOME: HOME2, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1',
      JUKEBOX_TTL_MS: '300', JUKEBOX_DELETE_MS: '1200', JUKEBOX_SWEEP_MS: '120' },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  try {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) { try { const r = await fetch(`http://127.0.0.1:${PORT2}/health`); if (r.ok) break; } catch { /* not up */ } await wait(100); }
    const created = await reqAt(PORT2, 'POST', '/jukebox', { token: TOKEN, body: { name: 'Ephemeral' } });
    const e = created.json;
    assert.equal(typeof e.expiresAt, 'number');

    // (a) past the 300ms TTL → session is ended; host + guest endpoints answer 410.
    await wait(550);
    const hostGone = await reqAt(PORT2, 'GET', `/jukebox/${e.jukeboxId}/requests?since=0`, { hostKey: e.hostKey });
    assert.equal(hostGone.status, 410);
    const guestGone = await reqAt(PORT2, 'POST', `/jukebox/${e.jukeboxId}/request`, { body: { title: 'too late', clientId: 'g' } });
    assert.equal(guestGone.status, 410);
    assert.equal(JSON.parse(readFileSync(stateFileIn(HOME2, e.jukeboxId), 'utf8')).ended, true, 'final state.json is ended');

    // (b) past the 1200ms delete mark → S3 objects + the local session dir are purged; 404.
    await wait(900);
    assert.equal(existsSync(stateFileIn(HOME2, e.jukeboxId)), false, 'dry-run S3 objects removed');
    assert.equal(existsSync(join(HOME2, e.jukeboxId)), false, 'local session dir removed');
    const after = await reqAt(PORT2, 'GET', `/jukebox/${e.jukeboxId}/requests?since=0`, { hostKey: e.hostKey });
    assert.equal(after.status, 404);
  } finally {
    c2.kill('SIGKILL');
  }
});

test('per-IP sliding window: distinct clients on one IP pass up to the cap, then 429', async () => {
  // Dedicated server with a tiny per-IP window (cap 4 / 60s) — all test requests share 127.0.0.1.
  // A NAT'd crowd = many distinct clientIds on one IP, so the per-client gap never fires here;
  // only the per-IP window caps them.
  const HOME3 = mkdtempSync(join(tmpdir(), 'jukebox-ipwin-'));
  const PORT3 = await freePort();
  const c3 = spawn(process.execPath, [SERVER], {
    env: { ...process.env, JUKEBOX_PORT: String(PORT3), JUKEBOX_HOME: HOME3, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1',
      JUKEBOX_IP_WINDOW_MAX: '4', JUKEBOX_IP_WINDOW_MS: '60000' },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  try {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) { try { const r = await fetch(`http://127.0.0.1:${PORT3}/health`); if (r.ok) break; } catch { /* not up */ } await wait(100); }
    const created = await reqAt(PORT3, 'POST', '/jukebox', { token: TOKEN, body: { name: 'Crowd' } });
    const id = created.json.jukeboxId;
    // Four distinct guests on the shared IP all get through (per-client gap doesn't apply).
    for (let i = 0; i < 4; i++) {
      const r = await reqAt(PORT3, 'POST', `/jukebox/${id}/request`, { body: { title: `song ${i}`, clientId: `crowd-${i}` } });
      assert.equal(r.status, 200, `request ${i} should pass`);
    }
    // The fifth distinct guest trips the per-IP window cap.
    const capped = await reqAt(PORT3, 'POST', `/jukebox/${id}/request`, { body: { title: 'song 5', clientId: 'crowd-5' } });
    assert.equal(capped.status, 429, 'fifth request on the same IP is window-capped');
  } finally {
    c3.kill('SIGKILL');
  }
});
