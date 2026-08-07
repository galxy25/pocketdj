// Smoke suite for the jukebox broker's Music with Friends routes (jukebox-server.mjs v3)
// + the dependency-free APNs JWT math (apns.mjs). Harness copied from
// test-jukebox-server.mjs: the real server as a child process, JUKEBOX_DRY_RUN=1 (S3
// writes mirror to <home>/dry-run/<key>), a temp JUKEBOX_HOME, JUKEBOX_TOKEN=testtoken.
// MwF-specific shrinkage: turn floor 1 s, suggest gap 0.
//
//   node --test scripts/test-mwf-server.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { generateKeyPairSync, createSign, verify as cryptoVerify } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

import { derToJose, enabled as apnsEnabled } from './apns.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SERVER = join(__dirname, 'jukebox-server.mjs');
const TOKEN = 'testtoken';
const HOME = mkdtempSync(join(tmpdir(), 'mwf-test-'));

let child = null;
let PORT = 0;

function freePort() {
  return new Promise((res, rej) => {
    const srv = net.createServer();
    srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => { const p = srv.address().port; srv.close(() => res(p)); });
  });
}

function spawnServer(extraEnv = {}) {
  return spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      JUKEBOX_PORT: String(PORT), JUKEBOX_HOME: HOME, JUKEBOX_TOKEN: TOKEN,
      JUKEBOX_DRY_RUN: '1', JUKEBOX_MWF_MIN_TURN_S: '1', JUKEBOX_MWF_SUGGEST_GAP_MS: '0',
      // A test process env must never accidentally enable APNs.
      APNS_KEY_FILE: '', APNS_KEY_ID: '', APNS_TEAM_ID: '',
      ...extraEnv,
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
}

async function waitHealthyAt(port, timeoutMs = 5000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`); if (r.ok) return; } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not become healthy');
}

async function reqAt(port, method, path, { token, bearer, body } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (bearer) headers['Authorization'] = `Bearer ${bearer}`;
  const r = await fetch(`http://127.0.0.1:${port}${path}`, {
    method, headers, body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let json = null; try { json = await r.json(); } catch { /* non-json */ }
  return { status: r.status, json };
}
const req = (method, path, opts) => reqAt(PORT, method, path, opts);

const mwfStateFileIn = (home, id) => join(home, 'dry-run', 'jukebox', 'mwf', id, 'state.json');
const readMwfPublicState = (id) => JSON.parse(readFileSync(mwfStateFileIn(HOME, id), 'utf8'));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/// Create a session with the given settings; returns the create JSON.
async function createSession(overrides = {}) {
  const r = await req('POST', '/mwf', {
    token: TOKEN,
    body: {
      name: overrides.name ?? 'Test Session',
      theme: overrides.theme ?? '90s road-trip anthems',
      leaderName: overrides.leaderName ?? 'Ada',
      clientId: overrides.clientId ?? `leader-${Math.random().toString(36).slice(2)}`,
      settings: { turnSeconds: 60, acceptOutsideTurn: false, turnEndsOnFirstSuggestion: true,
                  ...(overrides.settings || {}) },
    },
  });
  assert.equal(r.status, 200, `create failed: ${JSON.stringify(r.json)}`);
  return r.json;
}

before(async () => { PORT = await freePort(); child = spawnServer(); await waitHealthyAt(PORT); });
after(() => { if (child) child.kill('SIGKILL'); });

// ---------------- apns.mjs unit (no server needed) ----------------

test('derToJose converts a hand-built DER signature to the 64-byte r‖s form', () => {
  // r = 0x80 then 31×0x11 (high bit set ⇒ DER sign-pads with 0x00); s = 0x7f (1 byte,
  // JOSE left-pads to 32). SEQUENCE: 30 26 02 21 00 <r:32> 02 01 7f.
  const r = Buffer.concat([Buffer.from([0x80]), Buffer.alloc(31, 0x11)]);
  const der = Buffer.concat([
    Buffer.from([0x30, 0x26, 0x02, 0x21, 0x00]), r, Buffer.from([0x02, 0x01, 0x7f]),
  ]);
  const jose = derToJose(der);
  assert.equal(jose.length, 64);
  assert.deepEqual(jose.subarray(0, 32), r);
  const expectedS = Buffer.concat([Buffer.alloc(31, 0x00), Buffer.from([0x7f])]);
  assert.deepEqual(jose.subarray(32), expectedS);
});

test('derToJose output verifies as a raw ieee-p1363 P-256 signature (round-trip)', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const payload = Buffer.from('header.claims');
  const signer = createSign('SHA256');
  signer.update(payload);
  signer.end();
  const der = signer.sign(privateKey);
  const jose = derToJose(der);
  assert.equal(jose.length, 64);
  const ok = cryptoVerify('sha256', payload, { key: publicKey, dsaEncoding: 'ieee-p1363' }, jose);
  assert.equal(ok, true, 'the converted signature must verify in raw r‖s form');
});

test('apns.enabled() is false without key config', () => {
  assert.equal(apnsEnabled(), false);
});

// ---------------- health + create/join ----------------

test('health reports version 3 + mwf:true + apns:false', async () => {
  const r = await req('GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.json.version, 3);
  assert.equal(r.json.mwf, true);
  assert.equal(r.json.apns, false);
});

test('create clamps the theme to 144 and mints leader member #1; joins rotate in join order', async () => {
  const longTheme = 'x'.repeat(200);
  const s = await createSession({ theme: longTheme });
  assert.equal(s.theme.length, 144, 'theme hard-clamped to 144');
  assert.match(s.sessionId, /^[a-z2-7]{8}$/);
  assert.match(s.leaderKey, /^[a-f0-9]{32}$/);
  assert.match(s.memberKey, /^[a-f0-9]{32}$/);
  assert.ok(s.url.endsWith(`/mwf/${s.sessionId}/`), `guest url carries /mwf/: ${s.url}`);
  assert.equal(typeof s.expiresAt, 'number', 'MwF sessions ALWAYS expire (no timeless)');

  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'client-B' } });
  assert.equal(b.status, 200);
  const c = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: '', clientId: 'client-C' } });
  assert.equal(c.status, 200);
  assert.equal(c.json.name, 'Player 3', 'empty name defaults to Player <n>');

  const st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.status, 200);
  assert.equal(st.json.members.length, 3);
  assert.equal(st.json.members[0].isLeader, true);
  assert.equal(st.json.members[1].isLeader, false);
  assert.equal(st.json.turn.memberId, st.json.members[0].memberId, 'turn starts on the leader');
  assert.equal(st.json.you.memberId, s.memberId);
  // The leaderKey also reads state (as the leader member).
  const stL = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.leaderKey });
  assert.equal(stL.status, 200);
  assert.equal(stL.json.you.memberId, s.memberId);
});

test('join is idempotent by clientId — no double turn slot', async () => {
  const s = await createSession();
  const first = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'same-client' } });
  const second = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth again', clientId: 'same-client' } });
  assert.equal(second.status, 200);
  assert.equal(second.json.memberId, first.json.memberId, 'same member returned');
  assert.equal(second.json.memberKey, first.json.memberKey);
  const st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.json.members.length, 2, 'no duplicate member row');
});

test('funnel-prefixed /jukebox/mwf paths dispatch identically', async () => {
  const s = await createSession();
  const st = await req('GET', `/jukebox/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.status, 200);
  assert.equal(st.json.sessionId, s.sessionId);
});

// ---------------- turn rules ----------------

test('suggest outside turn is 409 when acceptOutsideTurn=false; allowed after /config flips it', async () => {
  const s = await createSession({ settings: { acceptOutsideTurn: false, turnEndsOnFirstSuggestion: false } });
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'turn-B' } });
  // Turn is the leader's — Beth is rejected.
  const denied = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Torn', artist: 'Natalie Imbruglia' } });
  assert.equal(denied.status, 409);
  // Leader flips acceptOutsideTurn live → takes effect immediately.
  const cfg = await req('POST', `/mwf/${s.sessionId}/config`, { bearer: s.leaderKey, body: { acceptOutsideTurn: true } });
  assert.equal(cfg.status, 200);
  assert.equal(cfg.json.settings.acceptOutsideTurn, true);
  const allowed = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Torn', artist: 'Natalie Imbruglia' } });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.json.turnAdvanced, false, 'a non-turn suggestion never advances the turn');
});

test('turnEndsOnFirstSuggestion=true advances the turn on suggest; false does not', async () => {
  // TRUE: the leader's suggestion hands the turn to member 2.
  const a = await createSession({ settings: { turnEndsOnFirstSuggestion: true } });
  await req('POST', `/mwf/${a.sessionId}/join`, { body: { name: 'Beth', clientId: 'adv-B' } });
  const sug = await req('POST', `/mwf/${a.sessionId}/suggest`, { bearer: a.memberKey, body: { title: 'One', artist: 'U2' } });
  assert.equal(sug.status, 200);
  assert.equal(sug.json.turnAdvanced, true);
  let st = await req('GET', `/mwf/${a.sessionId}/state`, { bearer: a.memberKey });
  assert.equal(st.json.turn.index, 1, 'turn moved to the second member');
  assert.notEqual(st.json.turn.memberId, a.memberId);

  // FALSE: the member may suggest repeatedly until the deadline.
  const b = await createSession({ settings: { turnEndsOnFirstSuggestion: false } });
  await req('POST', `/mwf/${b.sessionId}/join`, { body: { name: 'Beth', clientId: 'noadv-B' } });
  const s1 = await req('POST', `/mwf/${b.sessionId}/suggest`, { bearer: b.memberKey, body: { title: 'Two', artist: 'X' } });
  assert.equal(s1.json.turnAdvanced, false);
  const s2 = await req('POST', `/mwf/${b.sessionId}/suggest`, { bearer: b.memberKey, body: { title: 'Three', artist: 'Y' } });
  assert.equal(s2.status, 200, 'the same member may suggest again inside their turn');
  st = await req('GET', `/mwf/${b.sessionId}/state`, { bearer: b.memberKey });
  assert.equal(st.json.turn.index, 0, 'turn never moved');
});

test('turn expiry auto-advances (1 s turns) and re-arms the deadline; single member rotates onto itself', async () => {
  const s = await createSession({ settings: { turnSeconds: 1, turnEndsOnFirstSuggestion: false } });
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'exp-B' } });
  let st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.json.turn.index, 0);
  await wait(1300);
  st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.json.turn.index, 1, 'expiry advanced to member 2');
  assert.equal(st.json.turn.memberId, b.json.memberId);
  assert.ok(st.json.turn.deadline > Date.now() - 200, 'deadline re-armed into the future');
  // Rotation wraps back to the leader on the next expiry.
  await wait(1300);
  st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.json.turn.index, 0, 'wrapped back to the leader');

  // A single-member session rotates onto itself harmlessly.
  const solo = await createSession({ settings: { turnSeconds: 1, turnEndsOnFirstSuggestion: false } });
  await wait(1300);
  const stSolo = await req('GET', `/mwf/${solo.sessionId}/state`, { bearer: solo.memberKey });
  assert.equal(stSolo.status, 200);
  assert.equal(stSolo.json.turn.memberId, solo.memberId);
});

// ---------------- decisions / scores / +1 ----------------

test('accepted suggestion scores the suggester; +1s add points; repeat/self +1 are 409; collection in accept order', async () => {
  const s = await createSession({ settings: { acceptOutsideTurn: true, turnEndsOnFirstSuggestion: false } });
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'sc-B' } });
  const c = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Cleo', clientId: 'sc-C' } });

  const sug1 = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Alpha', artist: 'A' } });
  const sug2 = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: c.json.memberKey, body: { title: 'Beta', artist: 'B' } });

  // Reject leaves score untouched; accept scores 1 (with the leader's match attached).
  const rej = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug2.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'rejected' },
  });
  assert.equal(rej.status, 200);
  const acc = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug1.json.suggestionId}/decision`, {
    bearer: s.leaderKey,
    body: { action: 'accepted', match: { songId: 'sng_1', appleMusicId: '12345', title: 'Alpha', artist: 'A', lengthMs: 200000 } },
  });
  assert.equal(acc.status, 200);
  // Deciding twice is a 409 (pending-only).
  const again = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug1.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'rejected' },
  });
  assert.equal(again.status, 409);

  let st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: b.json.memberKey });
  const score = (state, memberId) => state.members.find((m) => m.memberId === memberId).score;
  assert.equal(score(st.json, b.json.memberId), 1, 'accepted = 1 point to the suggester');
  assert.equal(score(st.json, c.json.memberId), 0, 'rejected = no points');

  // +1: peer adds a point to the SUGGESTER; repeat is 409; self is 409; pending is 409.
  const p1 = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug1.json.suggestionId}/plusone`, { bearer: c.json.memberKey });
  assert.equal(p1.status, 200);
  assert.equal(p1.json.plusOnes, 1);
  const p1again = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug1.json.suggestionId}/plusone`, { bearer: c.json.memberKey });
  assert.equal(p1again.status, 409, 'one +1 per member per suggestion');
  const p1self = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug1.json.suggestionId}/plusone`, { bearer: b.json.memberKey });
  assert.equal(p1self.status, 409, 'no self +1');
  const p1rej = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug2.json.suggestionId}/plusone`, { bearer: b.json.memberKey });
  assert.equal(p1rej.status, 409, '+1 only lands on accepted suggestions');

  st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: b.json.memberKey });
  assert.equal(score(st.json, b.json.memberId), 2, 'the +1 goes to the suggester');

  // The accepted match lands in the collection, accept order, match fields present.
  const sug3 = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: c.json.memberKey, body: { title: 'Gamma', artist: 'G' } });
  await req('POST', `/mwf/${s.sessionId}/suggestions/${sug3.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'accepted' },
  });
  st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: b.json.memberKey });
  assert.equal(st.json.collection.length, 2);
  assert.equal(st.json.collection[0].songId, 'sng_1');
  assert.equal(st.json.collection[0].appleMusicId, '12345');
  assert.equal(st.json.collection[0].lengthMs, 200000);
  assert.equal(st.json.collection[1].title, 'Gamma', 'no-match accept falls back to the request text');
  assert.equal(st.json.collection[1].songId, null);
});

// ---------------- privacy + public state ----------------

test('member state + public state.json never leak keys/clientIds/tokens; public omits `you`', async () => {
  const s = await createSession();
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'priv-B' } });
  // Register a device token so a leak would be visible.
  const token64 = 'ab'.repeat(32);
  const reg = await req('POST', `/mwf/${s.sessionId}/register-device`, { bearer: b.json.memberKey, body: { platform: 'ios', token: token64 } });
  assert.equal(reg.status, 200);

  const st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: b.json.memberKey });
  const raw = JSON.stringify(st.json);
  assert.ok(!raw.includes(s.leaderKey), 'leaderKey never serialized');
  assert.ok(!raw.includes(s.memberKey), 'memberKey never serialized');
  assert.ok(!raw.includes(b.json.memberKey), 'peer memberKey never serialized');
  assert.ok(!raw.includes('priv-B'), 'clientId never serialized');
  assert.ok(!raw.includes(token64), 'deviceToken never serialized');
  assert.equal(st.json.you.memberId, b.json.memberId);

  await wait(1300); // join/register publish is debounced 1 s
  assert.ok(existsSync(mwfStateFileIn(HOME, s.sessionId)), 'dry-run public state.json exists under jukebox/mwf/<id>/');
  const pub = readMwfPublicState(s.sessionId);
  assert.equal(pub.you, undefined, 'public state omits `you`');
  assert.equal(pub.members.length, 2);
  assert.equal(typeof pub.apiBase, 'string', 'public state carries the broker apiBase (join without pre-config)');
  const pubRaw = JSON.stringify(pub);
  assert.ok(!pubRaw.includes(s.leaderKey) && !pubRaw.includes(token64) && !pubRaw.includes('priv-B'));
  // The landing page uploaded too.
  const page = readFileSync(join(HOME, 'dry-run', 'jukebox', 'mwf', s.sessionId, 'index.html'), 'utf8');
  assert.ok(page.includes(`pocketdj://mwf/${s.sessionId}`), 'landing page carries the Open in PocketDJ deep link');
});

// ---------------- register-device + end ----------------

test('register-device validates the token and stores it; all routes 410 after end', async () => {
  const s = await createSession();
  const bad = await req('POST', `/mwf/${s.sessionId}/register-device`, { bearer: s.memberKey, body: { platform: 'ios', token: 'nope' } });
  assert.equal(bad.status, 400);
  const ok = await req('POST', `/mwf/${s.sessionId}/register-device`, { bearer: s.memberKey, body: { platform: 'macos', token: 'cd'.repeat(32) } });
  assert.equal(ok.status, 200);

  const end = await req('POST', `/mwf/${s.sessionId}/end`, { bearer: s.leaderKey });
  assert.equal(end.status, 200);
  assert.equal(end.json.ended, true);
  await wait(200);
  assert.equal(readMwfPublicState(s.sessionId).ended, true, 'final public state is ended');
  for (const [method, path, opts] of [
    ['GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey }],
    ['POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Late', clientId: 'late' } }],
    ['POST', `/mwf/${s.sessionId}/suggest`, { bearer: s.memberKey, body: { title: 'x' } }],
    ['POST', `/mwf/${s.sessionId}/register-device`, { bearer: s.memberKey, body: { platform: 'ios', token: 'ab'.repeat(32) } }],
  ]) {
    const r = await req(method, path, opts);
    assert.equal(r.status, 410, `${method} ${path} answers 410 once ended`);
  }
});

test('end requires the leaderKey; a memberKey cannot end or decide', async () => {
  const s = await createSession({ settings: { acceptOutsideTurn: true, turnEndsOnFirstSuggestion: false } });
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'auth-B' } });
  const sug = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Q', artist: 'W' } });
  const decide = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug.json.suggestionId}/decision`, {
    bearer: b.json.memberKey, body: { action: 'accepted' },
  });
  assert.equal(decide.status, 401, 'decision is leader-only');
  const end = await req('POST', `/mwf/${s.sessionId}/end`, { bearer: b.json.memberKey });
  assert.equal(end.status, 401, 'end is leader-only');
  const cfg = await req('POST', `/mwf/${s.sessionId}/config`, { bearer: b.json.memberKey, body: { turnSeconds: 30 } });
  assert.equal(cfg.status, 401, 'config is leader-only');
});

// ---------------- lifecycle: TTL expiry ----------------

test('shrunken TTL expires the session: 410 on all routes, then deleted (404 + dirs gone)', async () => {
  const HOME2 = mkdtempSync(join(tmpdir(), 'mwf-ttl-'));
  const PORT2 = await freePort();
  const c2 = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      JUKEBOX_PORT: String(PORT2), JUKEBOX_HOME: HOME2, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1',
      JUKEBOX_MWF_MIN_TURN_S: '1', JUKEBOX_MWF_SUGGEST_GAP_MS: '0',
      JUKEBOX_TTL_MS: '300', JUKEBOX_DELETE_MS: '1200', JUKEBOX_SWEEP_MS: '120',
      APNS_KEY_FILE: '', APNS_KEY_ID: '', APNS_TEAM_ID: '',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  try {
    await waitHealthyAt(PORT2);
    const created = await reqAt(PORT2, 'POST', '/mwf', {
      token: TOKEN,
      body: { theme: 'Ephemeral', leaderName: 'Ada', clientId: 'ttl-A', settings: { turnSeconds: 60 } },
    });
    assert.equal(created.status, 200);
    const e = created.json;
    await wait(550);
    const stGone = await reqAt(PORT2, 'GET', `/mwf/${e.sessionId}/state`, { bearer: e.memberKey });
    assert.equal(stGone.status, 410);
    const joinGone = await reqAt(PORT2, 'POST', `/mwf/${e.sessionId}/join`, { body: { name: 'x', clientId: 'y' } });
    assert.equal(joinGone.status, 410);
    assert.equal(JSON.parse(readFileSync(mwfStateFileIn(HOME2, e.sessionId), 'utf8')).ended, true);
    await wait(900);
    assert.equal(existsSync(mwfStateFileIn(HOME2, e.sessionId)), false, 'dry-run S3 objects removed');
    assert.equal(existsSync(join(HOME2, 'mwf', e.sessionId)), false, 'local session dir removed');
    const after410 = await reqAt(PORT2, 'GET', `/mwf/${e.sessionId}/state`, { bearer: e.memberKey });
    assert.equal(after410.status, 404);
  } finally {
    c2.kill('SIGKILL');
  }
});

// ---------------- restart persistence ----------------

test('restart: session, members, suggestions, scores, deadline reload; jukebox loadSessions skips the mwf dir', async () => {
  const s = await createSession({ settings: { turnSeconds: 3600, acceptOutsideTurn: true, turnEndsOnFirstSuggestion: false } });
  const b = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'rs-B' } });
  const sug = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Persist', artist: 'P' } });
  await req('POST', `/mwf/${s.sessionId}/suggestions/${sug.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'accepted', match: { songId: 'sng_9' } },
  });
  const before = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  const deadlineBefore = before.json.turn.deadline;

  // Also count live jukebox sessions before the restart (mwf dirs must not inflate it).
  const healthBefore = await req('GET', '/health');

  child.kill('SIGKILL');
  await new Promise((r) => child.on('exit', r));
  child = spawnServer();
  await waitHealthyAt(PORT);

  const health = await req('GET', '/health');
  assert.equal(health.json.sessions, healthBefore.json.sessions,
    'jukebox loadSessions must skip the mwf dir (no phantom jukebox sessions)');

  const st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.status, 200);
  assert.equal(st.json.members.length, 2, 'members reloaded');
  assert.equal(st.json.suggestions.length, 1, 'suggestions reloaded');
  assert.equal(st.json.suggestions[0].status, 'accepted');
  assert.equal(st.json.members.find((m) => m.memberId === b.json.memberId).score, 1, 'derived score survives');
  assert.equal(st.json.turn.deadline, deadlineBefore, 'un-expired deadline reloads intact');
  assert.equal(st.json.collection[0].songId, 'sng_9');

  // A member key still works for a NEW suggestion after restart.
  const sug2 = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: b.json.memberKey, body: { title: 'Again', artist: 'P' } });
  assert.equal(sug2.status, 200);
});

// ---------------- jukebox regression (same server binary) ----------------

test('existing jukebox routes are untouched: create → request → decide round-trip', async () => {
  const created = await req('POST', '/jukebox', { token: TOKEN, body: { name: 'Regression Party' } });
  assert.equal(created.status, 200);
  const jb = created.json;
  assert.match(jb.jukeboxId, /^[a-z2-7]{8}$/);
  const made = await req('POST', `/jukebox/${jb.jukeboxId}/request`, { body: { title: 'One More Time', artist: 'Daft Punk', clientId: 'reg-guest' } });
  assert.equal(made.status, 200);
  const poll = await req('GET', `/jukebox/${jb.jukeboxId}/requests?since=0`, { bearer: jb.hostKey });
  assert.equal(poll.status, 200);
  const row = poll.json.requests.find((x) => x.id === made.json.requestId);
  assert.ok(row, 'request visible to the host');
  const dec = await req('POST', `/jukebox/${jb.jukeboxId}/requests/${made.json.requestId}/decision`, { bearer: jb.hostKey, body: { action: 'next' } });
  assert.equal(dec.status, 200);
  assert.equal(dec.json.status, 'queued');
});
