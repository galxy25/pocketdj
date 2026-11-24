// node --test scripts/test/jukebox-remote-routes.test.mjs
// Spawns the real broker on a free port (isolated JUKEBOX_HOME, dry-run, no AWS) and drives the /remote relay.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, '..', 'jukebox-server.mjs');

function freePort() {
  return new Promise((res) => { const s = net.createServer().listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
}

async function boot(extraEnv = {}) {
  const port = await freePort();
  const home = mkdtempSync(join(tmpdir(), 'pdj-remote-'));
  const child = spawn(process.execPath, [serverPath], {
    env: { ...process.env, JUKEBOX_PORT: String(port), JUKEBOX_HOME: home, JUKEBOX_DRY_RUN: '1', JUKEBOX_REMOTE_POLL_MS: '700', JUKEBOX_REMOTE_JOIN_WINDOW_MAX: '1000', ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(base + '/health')).ok) break; } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 50));
  }
  return { base, stop: () => { child.kill(); rmSync(home, { recursive: true, force: true }); } };
}

const call = async (base, method, path, { body, token, headers } = {}) => {
  const r = await fetch(base + path, {
    method, body: body === undefined ? undefined : JSON.stringify(body),
    headers: { ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
  });
  let json = null; try { json = await r.json(); } catch { /* empty */ }
  return { status: r.status, json };
};
const env = (kind, payload = 'e30=') => ({ v: 1, kind, payload });

async function room(base, names = ['host', 'guest']) {
  const c = await call(base, 'POST', '/remote', { body: {} });
  assert.equal(c.status, 200);
  const { roomId, joinCode, hostSecret } = c.json;
  const host = await call(base, 'POST', `/remote/${roomId}/join`, { body: { participantId: 'a-host', name: names[0] }, token: hostSecret });
  assert.equal(host.status, 200);
  const guest = await call(base, 'POST', `/remote/${roomId}/join`, { body: { participantId: 'b-guest', name: names[1], joinCode } });
  assert.equal(guest.status, 200);
  return { roomId, joinCode, hostSecret, host: host.json, guest: guest.json };
}

let srv;
before(async () => { srv = await boot(); });
after(() => srv.stop());

test('health advertises the remote broker', async () => {
  const h = await call(srv.base, 'GET', '/health');
  assert.equal(h.json.remote, true);
  assert.ok(h.json.version >= 4);
});

test('create returns roomId, joinCode, hostSecret; roomId is the lower-cased code', async () => {
  const c = await call(srv.base, 'POST', '/remote', { body: {} });
  assert.equal(c.status, 200);
  assert.match(c.json.joinCode, /^[A-Z2-9]{8}$/);
  assert.equal(c.json.roomId, c.json.joinCode.toLowerCase());
  assert.ok(c.json.hostSecret.length >= 16);
});

test('also reachable under the /jukebox funnel mount', async () => {
  const c = await call(srv.base, 'POST', '/jukebox/remote', { body: {} });
  assert.equal(c.status, 200);
});

test('join needs the code (or host secret); a wrong code is 401, unknown room 404', async () => {
  const c = (await call(srv.base, 'POST', '/remote', { body: {} })).json;
  assert.equal((await call(srv.base, 'POST', `/remote/${c.roomId}/join`, { body: { joinCode: 'WRONGONE' } })).status, 401);
  assert.equal((await call(srv.base, 'POST', `/remote/zzzzzzzz/join`, { body: { joinCode: c.joinCode } })).status, 404);
  const ok = await call(srv.base, 'POST', `/remote/${c.roomId}/join`, { body: { joinCode: c.joinCode.toLowerCase(), name: 'x' } });
  assert.equal(ok.status, 200);
  assert.ok(ok.json.participantId && ok.json.secret);
});

test('a duplicate participantId is 409', async () => {
  const r = await room(srv.base);
  const dup = await call(srv.base, 'POST', `/remote/${r.roomId}/join`, { body: { participantId: 'b-guest', joinCode: r.joinCode } });
  assert.equal(dup.status, 409);
});

test('send to all reaches the other participant, never the sender; sender is stamped by the server', async () => {
  const r = await room(srv.base);
  const s = await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'all', reliable: true, env: env('state'), from: 'spoof' } });
  assert.equal(s.status, 200);
  const g = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
  assert.equal(g.status, 200);
  assert.equal(g.json.events.length, 1);
  assert.equal(g.json.events[0].from, 'a-host');
  assert.deepEqual(g.json.events[0].env, env('state'));
  assert.deepEqual(g.json.roster.map((p) => p.id).sort(), ['a-host', 'b-guest']);
  const h = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0&rev=${g.json.rev}`, { token: r.host.secret });
  assert.deepEqual(h.json.events, []); // own message is not echoed (timed out after the 700 ms test poll window)
});

test('directed sends reach only the addressee; unknown recipient is 404; env may be a JSON string', async () => {
  const r = await room(srv.base);
  const third = (await call(srv.base, 'POST', `/remote/${r.roomId}/join`, { body: { participantId: 'c-third', joinCode: r.joinCode } })).json;
  assert.equal((await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'nobody', env: env('x') } })).status, 404);
  await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'b-guest', reliable: false, env: JSON.stringify(env('ping')) } });
  const g = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
  assert.equal(g.json.events.length, 1);
  assert.equal(g.json.events[0].env.kind, 'ping');
  const t = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0&rev=-1`, { token: third.secret });
  assert.deepEqual(t.json.events, []);
});

test('a malformed envelope is 400; bad bearer is 401', async () => {
  const r = await room(srv.base);
  assert.equal((await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'all', env: { kind: 1 } } })).status, 400);
  assert.equal((await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: 'nope', body: { to: 'all', env: env('x') } })).status, 401);
  assert.equal((await call(srv.base, 'GET', `/remote/${r.roomId}/poll`, { token: r.hostSecret })).status, 401);
});

test('long-poll parks, then wakes on a send', async () => {
  const r = await room(srv.base);
  const first = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
  const t0 = Date.now();
  const pending = call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=${first.json.cursor}&rev=${first.json.rev}`, { token: r.guest.secret });
  await new Promise((x) => setTimeout(x, 150));
  await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'all', env: env('late') } });
  const out = await pending;
  assert.equal(out.json.events.length, 1);
  assert.ok(Date.now() - t0 < 600, 'woke before the long-poll timeout');
});

test('an idle long-poll returns empty at the poll timeout', async () => {
  const r = await room(srv.base);
  const first = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
  const t0 = Date.now();
  const out = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=${first.json.cursor}&rev=${first.json.rev}`, { token: r.guest.secret });
  assert.equal(out.status, 200);
  assert.deepEqual(out.json.events, []);
  assert.ok(Date.now() - t0 >= 600);
});

test('leave wakes the others with a new roster; the last leave closes the room', async () => {
  const r = await room(srv.base);
  const first = await call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
  const pending = call(srv.base, 'GET', `/remote/${r.roomId}/poll?since=${first.json.cursor}&rev=${first.json.rev}`, { token: r.guest.secret });
  await new Promise((x) => setTimeout(x, 100));
  assert.equal((await call(srv.base, 'POST', `/remote/${r.roomId}/leave`, { token: r.host.secret })).status, 200);
  const out = await pending;
  assert.deepEqual(out.json.roster.map((p) => p.id), ['b-guest']);
  assert.ok(out.json.rev > first.json.rev);
  await call(srv.base, 'POST', `/remote/${r.roomId}/leave`, { token: r.guest.secret });
  assert.equal((await call(srv.base, 'GET', `/remote/${r.roomId}/poll`, { token: r.guest.secret })).status, 404);
});

test('a client that left is told 410/401 on its next poll', async () => {
  const r = await room(srv.base);
  await call(srv.base, 'POST', `/remote/${r.roomId}/leave`, { token: r.guest.secret });
  assert.equal((await call(srv.base, 'GET', `/remote/${r.roomId}/poll`, { token: r.guest.secret })).status, 401);
});

test('the ring buffer is bounded and a lagging poller is told events were dropped', async () => {
  const small = await boot({ JUKEBOX_REMOTE_RING: '5' });
  try {
    const r = await room(small.base);
    for (let i = 0; i < 9; i++) await call(small.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'all', env: env('m' + i) } });
    const g = await call(small.base, 'GET', `/remote/${r.roomId}/poll?since=0`, { token: r.guest.secret });
    assert.equal(g.json.events.length, 5);
    assert.equal(g.json.dropped, true);
    assert.equal(g.json.events[0].env.kind, 'm4');
    const caughtUp = await call(small.base, 'GET', `/remote/${r.roomId}/poll?since=${g.json.cursor}&rev=${g.json.rev}`, { token: r.guest.secret });
    assert.equal(caughtUp.json.dropped, false);
  } finally { small.stop(); }
});

test('per-room participant cap and the global room cap', async () => {
  const tiny = await boot({ JUKEBOX_REMOTE_MAX_PARTICIPANTS: '2', JUKEBOX_REMOTE_MAX_ROOMS: '2' });
  try {
    const r = await room(tiny.base);
    const third = await call(tiny.base, 'POST', `/remote/${r.roomId}/join`, { body: { joinCode: r.joinCode } });
    assert.equal(third.status, 403);
    assert.equal((await call(tiny.base, 'POST', '/remote', { body: {} })).status, 200);
    assert.equal((await call(tiny.base, 'POST', '/remote', { body: {} })).status, 503);
  } finally { tiny.stop(); }
});

test('per-IP sliding window limits create/join; X-Forwarded-For rightmost is the key', async () => {
  const lim = await boot({ JUKEBOX_REMOTE_JOIN_WINDOW_MAX: '3' });
  try {
    const h = { 'x-forwarded-for': '9.9.9.9, 1.1.1.1' };
    for (let i = 0; i < 3; i++) assert.equal((await call(lim.base, 'POST', '/remote', { body: {}, headers: h })).status, 200);
    assert.equal((await call(lim.base, 'POST', '/remote', { body: {}, headers: h })).status, 429);
    // a forged leftmost entry does not buy a fresh window; a different trusted hop does
    assert.equal((await call(lim.base, 'POST', '/remote', { body: {}, headers: { 'x-forwarded-for': '8.8.8.8, 1.1.1.1' } })).status, 429);
    assert.equal((await call(lim.base, 'POST', '/remote', { body: {}, headers: { 'x-forwarded-for': '9.9.9.9, 2.2.2.2' } })).status, 200);
  } finally { lim.stop(); }
});

test('the TTL sweep drops a silent participant and an emptied room', async () => {
  const ttl = await boot({ JUKEBOX_REMOTE_PARTICIPANT_TTL_MS: '300', JUKEBOX_REMOTE_SWEEP_MS: '100' });
  try {
    const r = await room(ttl.base);
    await new Promise((x) => setTimeout(x, 900));
    assert.equal((await call(ttl.base, 'GET', `/remote/${r.roomId}/poll`, { token: r.guest.secret })).status, 404);
  } finally { ttl.stop(); }
});

test('create honours JUKEBOX_TOKEN; join does not need it', async () => {
  const locked = await boot({ JUKEBOX_TOKEN: 'sekrit' });
  try {
    assert.equal((await call(locked.base, 'POST', '/remote', { body: {} })).status, 401);
    const c = await call(locked.base, 'POST', '/remote', { body: {}, token: 'sekrit' });
    assert.equal(c.status, 200);
    assert.equal((await call(locked.base, 'POST', `/remote/${c.json.roomId}/join`, { body: { joinCode: c.json.joinCode } })).status, 200);
  } finally { locked.stop(); }
});

test('an oversized body is 413', async () => {
  const r = await room(srv.base);
  const big = await call(srv.base, 'POST', `/remote/${r.roomId}/send`, { token: r.host.secret, body: { to: 'all', env: env('state', 'A'.repeat(70 * 1024)) } });
  assert.equal(big.status, 413);
});
