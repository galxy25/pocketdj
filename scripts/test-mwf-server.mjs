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
import { mkdtempSync, readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
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

/// Run `fn(port)` against a THROWAWAY server with extra env (its own port + home), so a
/// test can shrink a limit the shared server keeps at its default. Always reaped.
async function withServer(env, fn) {
  const home = mkdtempSync(join(tmpdir(), 'mwf-alt-'));
  const port = await freePort();
  const c = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      JUKEBOX_PORT: String(port), JUKEBOX_HOME: home, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1',
      JUKEBOX_MWF_MIN_TURN_S: '1', JUKEBOX_MWF_SUGGEST_GAP_MS: '0',
      APNS_KEY_FILE: '', APNS_KEY_ID: '', APNS_TEAM_ID: '',
      ...env,
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  try {
    await waitHealthyAt(port);
    await fn(port, home);
  } finally {
    c.kill('SIGKILL');
  }
}

async function waitHealthyAt(port, timeoutMs = 5000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`); if (r.ok) return; } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not become healthy');
}

async function reqAt(port, method, path, { token, bearer, body, headers: extraHeaders } = {}) {
  const headers = { ...(extraHeaders || {}) };
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

test('join is idempotent by joinSecret — no double turn slot', async () => {
  const s = await createSession();
  const first = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', joinSecret: 'beth-secret' } });
  const second = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth again', joinSecret: 'beth-secret' } });
  assert.equal(second.status, 200);
  assert.equal(second.json.memberId, first.json.memberId, 'same member returned');
  assert.equal(second.json.memberKey, first.json.memberKey);
  const st = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(st.json.members.length, 2, 'no duplicate member row');
  // The secret itself is never stored in the clear (only its sha256) — a leaked
  // session.json must not hand anybody a re-join credential.
  const persisted = readFileSync(join(HOME, 'mwf', s.sessionId, 'session.json'), 'utf8');
  assert.ok(!persisted.includes('beth-secret'), 'the join secret is hashed at rest');
});

test('a bare clientId is NOT a credential: join never hands back an existing memberKey', async () => {
  const s = await createSession({ clientId: 'leader-device-uuid' });
  const first = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', clientId: 'beth-device-uuid', joinSecret: 'beth-s' } });
  assert.equal(first.status, 200);
  // An attacker who read the X-PocketDJ-Device UUID off any first-party log replays it…
  const replay = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Mallory', clientId: 'beth-device-uuid' } });
  assert.equal(replay.status, 200);
  assert.notEqual(replay.json.memberId, first.json.memberId, 'a clientId never resolves an existing member');
  assert.notEqual(replay.json.memberKey, first.json.memberKey, 'and never yields their memberKey');
  // …the leader's device id likewise buys nothing.
  const replayLeader = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Mallory2', clientId: 'leader-device-uuid' } });
  assert.notEqual(replayLeader.json.memberKey, s.memberKey, "the leader's key is not reachable by clientId");

  // Re-join by KEY POSSESSION works (bearer or body); a wrong key is 401, never a new member.
  const rejoinBearer = await req('POST', `/mwf/${s.sessionId}/join`, { bearer: first.json.memberKey, body: { name: 'Beth' } });
  assert.equal(rejoinBearer.status, 200);
  assert.equal(rejoinBearer.json.memberId, first.json.memberId);
  const rejoinBody = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: 'Beth', memberKey: first.json.memberKey } });
  assert.equal(rejoinBody.json.memberId, first.json.memberId);
  const before = (await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey })).json.members.length;
  const wrong = await req('POST', `/mwf/${s.sessionId}/join`, { bearer: 'f'.repeat(32), body: { name: 'Mallory3' } });
  assert.equal(wrong.status, 401, 'a presented-but-unknown key is unauthorized, not a silent new member');
  const after = (await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey })).json.members.length;
  assert.equal(after, before, 'the failed re-join added nobody');
});

// ---------------- join abuse: member cap + per-IP window ----------------

test('join enforces the member cap (env-tunable) with 429 "session is full"', async () => {
  await withServer({ JUKEBOX_MWF_MAX_MEMBERS: '3' }, async (port) => {
    const created = await reqAt(port, 'POST', '/mwf', {
      token: TOKEN, body: { theme: 'Capped', leaderName: 'Ada', settings: { turnSeconds: 60 } },
    });
    const s = created.json;
    for (const n of ['one', 'two']) {
      const r = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: n, joinSecret: `s-${n}` } });
      assert.equal(r.status, 200, `join ${n} accepted below the cap`);
    }
    const full = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'three', joinSecret: 's-three' } });
    assert.equal(full.status, 429, 'the 4th member (cap 3) is refused');
    assert.equal(full.json.error, 'session is full');
    const st = await reqAt(port, 'GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
    assert.equal(st.json.members.length, 3, 'no ghost turn slots were appended');
    // An EXISTING member can always rebind, even at the cap.
    const rebind = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'one', joinSecret: 's-one' } });
    assert.equal(rebind.status, 200, 'a full session still lets its own members re-join');
  });
});

test('join pays the same per-IP sliding window as the guest-request path', async () => {
  await withServer({ JUKEBOX_IP_WINDOW_MAX: '2', JUKEBOX_IP_WINDOW_MS: '60000' }, async (port) => {
    const created = await reqAt(port, 'POST', '/mwf', {
      token: TOKEN, body: { theme: 'Flooded', leaderName: 'Ada', settings: { turnSeconds: 60 } },
    });
    const s = created.json;
    const a = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'a', joinSecret: 'ja' } });
    const b = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'b', joinSecret: 'jb' } });
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    const c = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'c', joinSecret: 'jc' } });
    assert.equal(c.status, 429, 'the window caps a join flood from one IP');
    assert.match(c.json.error, /too many joins/);
    // Re-joins are not new members, so the window never locks an existing player out.
    const rejoin = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'a', joinSecret: 'ja' } });
    assert.equal(rejoin.status, 200);
    assert.equal(rejoin.json.memberId, a.json.memberId);
  });
});

// ---------------- XSS: hostile text never reaches the landing page live ----------------

/// The landing page's own escaper, lifted out of the shipped template so the test asserts
/// the REAL function rather than a copy of it.
function templateEsc() {
  const src = readFileSync(join(__dirname, 'jukebox-site', 'mwf-template.html'), 'utf8');
  const m = src.match(/const esc = ([\s\S]*?);\n/);
  assert.ok(m, 'mwf-template.html still defines an esc()');
  return new Function(`return (${m[1]});`)();
}

test('the landing page esc() actually escapes (no innerHTML sink can execute)', () => {
  const esc = templateEsc();
  assert.equal(esc('<img src=x onerror=alert(1)>'),
    '&lt;img src=x onerror=alert(1)&gt;');
  assert.equal(esc('a & b'), 'a &amp; b');
  assert.equal(esc(`"'`), '&quot;&#39;');
  assert.equal(esc(null), '');
});

test('a hostile member name round-trips ESCAPED into the rendered landing page', async () => {
  const hostile = '<img src=x onerror=alert(1)>';
  const s = await createSession({ name: `Party ${hostile}`, theme: `Theme ${hostile}` });
  const joined = await req('POST', `/mwf/${s.sessionId}/join`, { body: { name: hostile, joinSecret: 'xss-1' } });
  assert.equal(joined.status, 200);
  const sug = await req('POST', `/mwf/${s.sessionId}/suggest`, { bearer: s.memberKey, body: { title: hostile, artist: hostile } });
  await req('POST', `/mwf/${s.sessionId}/suggestions/${sug.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'accepted' },
  });

  // 1. Nothing executable reaches the rendered page: the server's escHtml entity-escapes
  //    every template slot (escape-on-render — a destructive strip-on-ingest broke real
  //    titles, see the segue test below).
  const page = readFileSync(join(HOME, 'dry-run', 'jukebox', 'mwf', s.sessionId, 'index.html'), 'utf8');
  assert.ok(!page.includes('<img src=x'), 'no raw tag in the rendered page');
  assert.ok(page.includes('Party &lt;img src=x onerror=alert(1)&gt;'),
            'the name renders FULLY, entity-escaped');

  // 2. The POLLED payload carries the text VERBATIM (JSON is not HTML — fidelity is the
  //    contract; escaping belongs to the renderers, and every consumer escapes).
  await wait(1300); // the join/suggest publish is debounced 1 s
  const victim = readMwfPublicState(s.sessionId).members.find((m) => m.name === hostile);
  assert.ok(victim, 'the member name round-trips exactly');
  assert.equal(readMwfPublicState(s.sessionId).collection[0].title, hostile);

  // 3. …and the page's renderer escapes what it receives: the exact leaderboard/
  //    collection concatenation cannot produce an executable tag.
  const esc = templateEsc();
  const row = '<span class="grow t">' + esc(victim.name) + '</span>' +
              '<span class="t">' + esc(readMwfPublicState(s.sessionId).collection[0].title) + '</span>';
  assert.ok(!/<(img|svg|script|iframe)/i.test(row), `rendered row stays inert: ${row}`);
});

test('a segue title with angle brackets survives INTACT for catalog matching', async () => {
  // "Scarlet Begonias > Fire on the Mountain" — the '>' is part of the real title. The old
  // ingest strip mangled it ("Scarlet Begonias  Fire on the Mountain"), which broke the
  // leader-side catalog match of exactly these suggestions. Fidelity end-to-end now.
  const segue = 'Scarlet Begonias > Fire on the Mountain';
  const s = await createSession({ settings: { acceptOutsideTurn: true } });
  const sug = await req('POST', `/mwf/${s.sessionId}/suggest`, {
    bearer: s.memberKey, body: { title: segue, artist: 'Grateful Dead' },
  });
  assert.equal(sug.status, 200);
  const dec = await req('POST', `/mwf/${s.sessionId}/suggestions/${sug.json.suggestionId}/decision`, {
    bearer: s.leaderKey, body: { action: 'accepted', match: { title: segue, artist: 'Grateful Dead' } },
  });
  assert.equal(dec.status, 200);
  await wait(1300);
  const pub = readMwfPublicState(s.sessionId);
  assert.equal(pub.suggestions.find((g) => g.id === sug.json.suggestionId).title, segue,
               'the suggestion title is byte-identical');
  assert.equal(pub.collection[0].title, segue, 'the accepted match keeps the segue too');
  // And the renderer still neutralizes it on the way INTO html.
  const esc = templateEsc();
  assert.equal(esc(segue), 'Scarlet Begonias &gt; Fire on the Mountain');
});

test('a session PERSISTED with hostile text (pre-fix bytes) still renders ESCAPED', async () => {
  // loadMwfSessions trusts what is on disk, and the boot sweep re-puts index.html — so the
  // renderer itself, not just the input filter, has to hold. This is the pre-fix session.json
  // an upgraded broker would inherit.
  const home = mkdtempSync(join(tmpdir(), 'mwf-legacy-'));
  const id = 'legacyaa';
  const hostile = '<img src=x onerror=alert(1)>';
  const dir = join(home, 'mwf', id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'session.json'), JSON.stringify({
    id, name: `Party ${hostile}`, theme: `Theme ${hostile}`, leaderKey: 'ab'.repeat(16),
    createdAt: Date.now(), expiresAt: Date.now() + 3600_000, ended: false,
    settings: { turnSeconds: 60, acceptOutsideTurn: false, turnEndsOnFirstSuggestion: true },
    members: [{ memberId: 'mb_legacy', memberKey: 'cd'.repeat(16), name: `Ada ${hostile}`,
                clientId: null, joinedAt: Date.now(), deviceToken: null, devicePlatform: null }],
    turn: { index: 0, deadline: Date.now() + 60_000 }, seqCounter: 0,
  }));
  await withServer({ JUKEBOX_HOME: home }, async (port) => {
    const st = await reqAt(port, 'GET', `/mwf/${id}/state`, { bearer: 'cd'.repeat(16) });
    assert.equal(st.status, 200, 'the legacy session reloaded');
    const page = readFileSync(join(home, 'dry-run', 'jukebox', 'mwf', id, 'index.html'), 'utf8');
    assert.ok(!page.includes('<img src=x'), 'the boot re-put escapes the persisted name/theme');
    assert.ok(page.includes('&lt;img src=x onerror=alert(1)&gt;'), '…as HTML entities');
    // And the page's own renderer neutralizes the persisted MEMBER name it polls.
    const esc = templateEsc();
    assert.equal(esc(st.json.members[0].name), 'Ada &lt;img src=x onerror=alert(1)&gt;');
  });
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

// ---------------- hardening: credentials, rate-limit keys, body caps, storage caps ----------------

test('leaderKey/memberKey in the URL query are REFUSED — headers only (no secrets in access logs)', async () => {
  const s = await createSession();
  const memberQuery = await req('GET', `/mwf/${s.sessionId}/state?memberKey=${s.memberKey}`);
  assert.equal(memberQuery.status, 401, 'a query-string memberKey is not a credential');
  const leaderQuery = await req('POST', `/mwf/${s.sessionId}/config?leaderKey=${s.leaderKey}`,
                                { body: { turnSeconds: 90 } });
  assert.equal(leaderQuery.status, 401, 'a query-string leaderKey is not a credential');
  const viaHeader = await req('GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
  assert.equal(viaHeader.status, 200, 'the Authorization bearer still authenticates');
});

test('a forged leftmost X-Forwarded-For cannot mint fresh rate-limit windows', async () => {
  await withServer({ JUKEBOX_IP_WINDOW_MAX: '2', JUKEBOX_IP_WINDOW_MS: '60000' }, async (port) => {
    const created = await reqAt(port, 'POST', '/mwf', {
      token: TOKEN, body: { theme: 'Spoofed', leaderName: 'Ada', settings: { turnSeconds: 60 } },
    });
    const s = created.json;
    // The funnel model: the client controls the LEFTMOST entries; the trusted hop appends
    // the real address LAST. Rotating the forged leftmost value must not reset the window.
    const join = (n, forged) => reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, {
      body: { name: n, joinSecret: `spoof-${n}` },
      headers: { 'X-Forwarded-For': `${forged}, 10.0.0.7` },
    });
    assert.equal((await join('a', '9.9.9.1')).status, 200);
    assert.equal((await join('b', '9.9.9.2')).status, 200);
    const third = await join('c', '9.9.9.3');
    assert.equal(third.status, 429,
      'the limiter keys on the trusted rightmost hop, never the attacker-chosen leftmost');
  });
});

test('oversized bodies answer 413 on the public routes and create nothing', async () => {
  await withServer({ JUKEBOX_MAX_BODY_BYTES: '1024' }, async (port) => {
    const created = await reqAt(port, 'POST', '/mwf', {
      token: TOKEN, body: { theme: 'Bounded', leaderName: 'Ada', settings: { turnSeconds: 60 } },
    });
    const s = created.json;
    const big = 'x'.repeat(4096);
    const joined = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`,
                               { body: { name: big, joinSecret: 'j1' } });
    assert.equal(joined.status, 413, 'the unauthenticated join buffers nothing past the cap');
    const st = await reqAt(port, 'GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey });
    assert.equal(st.json.members.length, 1, 'no ghost member from the oversized body');
    // The pre-existing public jukebox guest route is capped by the same reader.
    const jb = (await reqAt(port, 'POST', '/jukebox', { token: TOKEN, body: { name: 'JB' } })).json;
    const guest = await reqAt(port, 'POST', `/jukebox/${jb.jukeboxId}/request`,
                              { body: { title: big, clientId: 'g1' } });
    assert.equal(guest.status, 413);
    const polled = await reqAt(port, 'GET', `/jukebox/${jb.jukeboxId}/requests?since=0`, { bearer: jb.hostKey });
    assert.equal(polled.json.requests.length, 0, 'no request row from the oversized body');
    // Normal-sized traffic is untouched.
    const ok = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'ok', joinSecret: 'j2' } });
    assert.equal(ok.status, 200);
  });
});

test('suggestion storage caps: per-member 429; per-session evicts rejected-then-pending, never accepted', async () => {
  await withServer({ JUKEBOX_MWF_SUGGEST_MAX_PER_MEMBER: '3',
                     JUKEBOX_MWF_SUGGEST_MAX_PER_SESSION: '3' }, async (port, home) => {
    const created = await reqAt(port, 'POST', '/mwf', {
      token: TOKEN, body: { theme: 'Capped feed', leaderName: 'Ada',
                            settings: { turnSeconds: 60, acceptOutsideTurn: true } },
    });
    const s = created.json;
    const suggest = (bearer, title) =>
      reqAt(port, 'POST', `/mwf/${s.sessionId}/suggest`, { bearer, body: { title, artist: 'X' } });
    const sgFile = (id) => join(home, 'mwf', s.sessionId, 'suggestions', `${id}.json`);

    const a1 = (await suggest(s.memberKey, 'A1')).json.suggestionId;
    const a2 = (await suggest(s.memberKey, 'A2')).json.suggestionId;
    const a3 = (await suggest(s.memberKey, 'A3')).json.suggestionId;
    // Per-member ceiling: the 4th from the same member is refused outright.
    const fourth = await suggest(s.memberKey, 'A4');
    assert.equal(fourth.status, 429);
    assert.match(fourth.json.error, /suggestion limit/);
    // Reject A1, then a second member pushes the session past the cap → the REJECTED row
    // is evicted first (map + file), never an accepted one.
    await reqAt(port, 'POST', `/mwf/${s.sessionId}/suggestions/${a1}/decision`,
                { bearer: s.leaderKey, body: { action: 'rejected' } });
    await reqAt(port, 'POST', `/mwf/${s.sessionId}/suggestions/${a2}/decision`,
                { bearer: s.leaderKey, body: { action: 'accepted' } });
    const b = await reqAt(port, 'POST', `/mwf/${s.sessionId}/join`, { body: { name: 'B', joinSecret: 'jb' } });
    const b1 = (await suggest(b.json.memberKey, 'B1')).json.suggestionId;
    let st = (await reqAt(port, 'GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey })).json;
    let ids = st.suggestions.map((g) => g.id);
    assert.ok(!ids.includes(a1), 'the rejected row was evicted first');
    assert.ok(ids.includes(a2) && ids.includes(a3) && ids.includes(b1), 'accepted + newer rows survive');
    assert.ok(!existsSync(sgFile(a1)), 'the evicted suggestion file is unlinked');
    // Ada is back under her ceiling (A1 evicted) — her next push evicts the OLDEST PENDING.
    const a5 = (await suggest(s.memberKey, 'A5')).json.suggestionId;
    st = (await reqAt(port, 'GET', `/mwf/${s.sessionId}/state`, { bearer: s.memberKey })).json;
    ids = st.suggestions.map((g) => g.id);
    assert.ok(!ids.includes(a3), 'with no rejected rows left, the oldest PENDING goes');
    assert.ok(ids.includes(a2), 'the accepted row is NEVER evicted (it is the collection)');
    assert.ok(ids.includes(b1) && ids.includes(a5));
    assert.ok(!existsSync(sgFile(a3)));
    assert.equal(st.collection.length, 1, 'the session collection is intact');
  });
});

test('an over-cap persisted roster still rotates within the PUBLISHED members', async () => {
  // A session persisted by an older build (or an env cap lowered between restarts) can
  // carry more members than the cap. The published members[] is capped — the turn pointer
  // must never name a member outside that list (guests would render an unknown "whose
  // turn" while a hidden member burns an invisible slot).
  const home = mkdtempSync(join(tmpdir(), 'mwf-overcap-'));
  const id = 'overcap2';
  const member = (n) => ({ memberId: `mb_${n}`, memberKey: `key_${n}`, name: `P${n}`,
                           clientId: null, profileId: null, joinHash: null, joinedAt: n,
                           deviceToken: null, devicePlatform: null });
  mkdirSync(join(home, 'mwf', id), { recursive: true });
  writeFileSync(join(home, 'mwf', id, 'session.json'), JSON.stringify({
    id, name: 'Over-cap', theme: 'T', leaderKey: 'lk_over',
    createdAt: Date.now(), expiresAt: Date.now() + 3_600_000, ended: false,
    settings: { turnSeconds: 60, acceptOutsideTurn: false, turnEndsOnFirstSuggestion: true },
    members: [member(1), member(2), member(3)],
    turn: { index: 2, deadline: Date.now() + 60_000 },   // the OLD rotation: index 2 ⇒ hidden mb_3
    seqCounter: 0,
  }));
  const port = await freePort();
  const c = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      JUKEBOX_PORT: String(port), JUKEBOX_HOME: home, JUKEBOX_TOKEN: TOKEN, JUKEBOX_DRY_RUN: '1',
      JUKEBOX_MWF_MIN_TURN_S: '1', JUKEBOX_MWF_SUGGEST_GAP_MS: '0', JUKEBOX_MWF_MAX_MEMBERS: '2',
      APNS_KEY_FILE: '', APNS_KEY_ID: '', APNS_TEAM_ID: '',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  try {
    await waitHealthyAt(port);
    for (let i = 0; i < 4; i++) {
      const st = (await reqAt(port, 'GET', `/mwf/${id}/state`, { bearer: 'key_1' })).json;
      const publishedIds = st.members.map((m) => m.memberId);
      assert.equal(publishedIds.length, 2, 'the published roster is capped');
      assert.ok(publishedIds.includes(st.turn.memberId),
        `turn.memberId ${st.turn.memberId} must be in the published roster (round ${i})`);
      // Advance the rotation: the on-turn member suggests (turnEndsOnFirstSuggestion).
      const key = st.turn.memberId.replace('mb_', 'key_');
      const sug = await reqAt(port, 'POST', `/mwf/${id}/suggest`,
                              { bearer: key, body: { title: `S${i}`, artist: 'X' } });
      assert.equal(sug.status, 200);
    }
  } finally {
    c.kill('SIGKILL');
  }
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
