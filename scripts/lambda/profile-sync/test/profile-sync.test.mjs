// node --test scripts/lambda/profile-sync/test/profile-sync.test.mjs
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { handler, setStore } from '../index.mjs';

class MemStore {
  constructor() { this.m = new Map(); }
  async get(k) { const v = this.m.get(k); return v ? { body: v.body, meta: { ...v.meta } } : null; }
  async head(k) { const v = this.m.get(k); return v ? { meta: { ...v.meta } } : null; }
  async put(k, body, meta) { this.m.set(k, { body, meta: { ...meta } }); }
  async del(k) { this.m.delete(k); }
  async list(p) { return [...this.m.keys()].filter((k) => k.startsWith(p)); }
}

const TOKEN = 'cap-token';
const sha = (s) => createHash('sha256').update(s).digest('hex');
const P = '11111111-aaaa-bbbb-cccc-222222222222';
const SECRET = 'secret-one';
let st;

beforeEach(() => {
  st = new MemStore(); setStore(st);
  process.env.ENROLL_SECRET = TOKEN; delete process.env.MAX_PROFILES;
});

const call = (method, path, { headers = {}, body, query } = {}) =>
  handler({ rawPath: path, requestContext: { http: { method } }, headers, body, queryStringParameters: query });
const auth = (profile = P, secret = SECRET, extra = {}) =>
  ({ 'x-pocketdj-profile': profile, authorization: `Bearer ${secret}`, ...extra });
const enroll = (profileId = P, secret = SECRET, token = TOKEN) =>
  call('POST', '/enroll', { headers: token === null ? {} : { 'x-pocketdj-enroll': token }, body: JSON.stringify({ profileId, secretHash: sha(secret) }) });

test('health needs no auth', async () => {
  assert.equal((await call('GET', '/health')).statusCode, 200);
});

test('enroll: requires capability token (missing, wrong, unset env = fail closed)', async () => {
  assert.equal((await enroll(P, SECRET, null)).statusCode, 401);
  assert.equal((await enroll(P, SECRET, 'nope')).statusCode, 401);
  delete process.env.ENROLL_SECRET;
  assert.equal((await enroll(P, SECRET, '')).statusCode, 401);
  assert.equal(st.m.size, 0);
});

test('enroll: creates, is idempotent for same secret, 409 for different secret', async () => {
  let r = await enroll(); assert.equal(r.statusCode, 200); assert.equal(JSON.parse(r.body).created, true);
  r = await enroll(); assert.equal(r.statusCode, 200); assert.equal(JSON.parse(r.body).created, false);
  r = await enroll(P, 'other-secret'); assert.equal(r.statusCode, 409);
  // original secret still works
  assert.equal((await call('GET', '/meta', { headers: auth() })).statusCode, 200);
  assert.equal((await call('GET', '/meta', { headers: auth(P, 'other-secret') })).statusCode, 401);
});

test('enroll: validates profileId and hash; stores only the hash', async () => {
  let r = await call('POST', '/enroll', { headers: { 'x-pocketdj-enroll': TOKEN }, body: JSON.stringify({ profileId: '../x', secretHash: sha('a') }) });
  assert.equal(r.statusCode, 400);
  r = await call('POST', '/enroll', { headers: { 'x-pocketdj-enroll': TOKEN }, body: JSON.stringify({ profileId: P, secretHash: 'short' }) });
  assert.equal(r.statusCode, 400);
  await enroll();
  const stored = st.m.get(`profiles/${P}/_auth.json`).body;
  assert.ok(stored.includes(sha(SECRET)));
  assert.ok(!stored.includes(SECRET));
});

test('enroll: uppercase iOS-style UUIDs normalize to lowercase', async () => {
  await enroll(P.toUpperCase());
  assert.ok(st.m.has(`profiles/${P}/_auth.json`));
  assert.equal((await call('GET', '/meta', { headers: auth(P.toUpperCase()) })).statusCode, 200);
});

test('enroll: MAX_PROFILES cap', async () => {
  process.env.MAX_PROFILES = '1';
  assert.equal((await enroll()).statusCode, 200);
  assert.equal((await enroll('other-profile')).statusCode, 429);
  assert.equal((await enroll()).statusCode, 200); // existing profile unaffected
});

test('auth matrix: every doc route 401s without a valid bearer for that profile', async () => {
  await enroll(); await enroll('second-profile', 'secret-two');
  const routes = [['GET', '/meta'], ['GET', '/doc/prefs'], ['PUT', '/doc/prefs'], ['DELETE', '/doc/prefs'], ['DELETE', '/profile']];
  const bad = [
    {},                                                           // nothing
    { 'x-pocketdj-profile': P },                                  // no bearer
    { authorization: `Bearer ${SECRET}` },                        // no profile
    auth(P, 'wrong'),                                             // wrong secret
    auth('second-profile', SECRET),                               // other profile's id, this secret
    auth('ghost-profile', SECRET),                                // unknown profile
    { 'x-pocketdj-profile': P, authorization: SECRET },           // not Bearer
    auth('../etc', SECRET),                                       // bad profile id
  ];
  for (const [m, p] of routes) for (const h of bad) {
    const r = await call(m, p, { headers: h, body: '{}' });
    assert.equal(r.statusCode, 401, `${m} ${p} ${JSON.stringify(h)}`);
  }
  assert.ok(st.m.has(`profiles/${P}/_auth.json`)); // nothing was wiped
});

test('PUT stores body + modified-at + device; GET round-trips', async () => {
  await enroll();
  const body = JSON.stringify({ a: 1 });
  const r = await call('PUT', '/doc/prefs', { headers: auth(P, SECRET, { 'x-pocketdj-modified-at': '1700000000123', 'x-pocketdj-device': 'Pixel 9' }), body });
  assert.equal(r.statusCode, 200);
  assert.equal(JSON.parse(r.body).modifiedAtMs, 1700000000123);
  const o = st.m.get(`profiles/${P}/prefs.json`);
  assert.equal(o.body, body);
  assert.deepEqual(o.meta, { 'modified-at-ms': '1700000000123', device: 'Pixel 9' });
  const g = await call('GET', '/doc/prefs', { headers: auth() });
  assert.equal(g.statusCode, 200); assert.equal(g.body, body);
  assert.equal(g.headers['x-pocketdj-modified-at'], '1700000000123');
  assert.equal((await call('GET', '/doc/missing', { headers: auth() })).statusCode, 404);
});

test('PUT: missing modified-at defaults to now; bad json / empty / oversize rejected; base64 body decoded', async () => {
  await enroll();
  const before = Date.now();
  const r = await call('PUT', '/doc/a', { headers: auth(), body: '{}' });
  assert.ok(JSON.parse(r.body).modifiedAtMs >= before);
  assert.equal((await call('PUT', '/doc/a', { headers: auth(), body: 'not json' })).statusCode, 400);
  assert.equal((await call('PUT', '/doc/a', { headers: auth(), body: '' })).statusCode, 400);
  assert.equal((await call('PUT', '/doc/a', { headers: auth(), body: '"' + 'x'.repeat(5 * 1024 * 1024) + '"' })).statusCode, 413);
  const r64 = await handler({ rawPath: '/doc/b64', requestContext: { http: { method: 'PUT' } }, headers: auth(), isBase64Encoded: true, body: Buffer.from('{"z":2}').toString('base64') });
  assert.equal(r64.statusCode, 200);
  assert.equal(st.m.get(`profiles/${P}/b64.json`).body, '{"z":2}');
});

test('key validation: [a-z0-9-]{1,40} only', async () => {
  await enroll();
  for (const k of ['UPPER', 'has_underscore', '_auth', 'a.b', 'a%2Fb', 'x'.repeat(41), 'sp ace']) {
    for (const m of ['GET', 'PUT', 'DELETE']) {
      const r = await call(m, `/doc/${k}`, { headers: auth(), body: '{}' });
      assert.equal(r.statusCode, 400, `${m} ${k}`);
    }
  }
  assert.equal((await call('PUT', `/doc/${'x'.repeat(40)}`, { headers: auth(), body: '{}' })).statusCode, 200);
  assert.equal((await call('GET', '/meta', { headers: auth(), query: { keys: 'ok,BAD' } })).statusCode, 400);
});

test('GET /meta returns only existing keys; without ?keys lists all (never _auth)', async () => {
  await enroll();
  await call('PUT', '/doc/one', { headers: auth(P, SECRET, { 'x-pocketdj-modified-at': '100' }), body: '{}' });
  await call('PUT', '/doc/two', { headers: auth(P, SECRET, { 'x-pocketdj-modified-at': '200' }), body: '{}' });
  let r = await call('GET', '/meta', { headers: auth(), query: { keys: 'one,ghost,two' } });
  assert.deepEqual(JSON.parse(r.body), { one: 100, two: 200 });
  r = await call('GET', '/meta', { headers: auth() });
  assert.deepEqual(JSON.parse(r.body), { one: 100, two: 200 });
});

test('profiles are isolated from each other', async () => {
  await enroll(); await enroll('second-profile', 'secret-two');
  await call('PUT', '/doc/one', { headers: auth(), body: '{"mine":true}' });
  const r = await call('GET', '/doc/one', { headers: auth('second-profile', 'secret-two') });
  assert.equal(r.statusCode, 404);
});

test('DELETE /doc is idempotent', async () => {
  await enroll();
  await call('PUT', '/doc/one', { headers: auth(), body: '{}' });
  assert.equal((await call('DELETE', '/doc/one', { headers: auth() })).statusCode, 200);
  assert.equal((await call('DELETE', '/doc/one', { headers: auth() })).statusCode, 200);
  assert.equal((await call('GET', '/doc/one', { headers: auth() })).statusCode, 404);
});

test('DELETE /profile removes the whole prefix (incl. auth) and only that prefix', async () => {
  await enroll(); await enroll('second-profile', 'secret-two');
  await call('PUT', '/doc/one', { headers: auth(), body: '{}' });
  await call('PUT', '/doc/one', { headers: auth('second-profile', 'secret-two'), body: '{}' });
  const r = await call('DELETE', '/profile', { headers: auth() });
  assert.equal(r.statusCode, 200); assert.equal(JSON.parse(r.body).deleted, 2);
  assert.deepEqual([...st.m.keys()].filter((k) => k.startsWith(`profiles/${P}/`)), []);
  assert.ok(st.m.has('profiles/second-profile/one.json'));
  // credentials are gone, and the profileId can be re-enrolled with a new secret
  assert.equal((await call('GET', '/meta', { headers: auth() })).statusCode, 401);
  assert.equal((await enroll(P, 'fresh')).statusCode, 200);
});

test('unknown route 404, wrong method 405', async () => {
  await enroll();
  assert.equal((await call('GET', '/nope')).statusCode, 404);
  assert.equal((await call('POST', '/doc/one', { headers: auth(), body: '{}' })).statusCode, 405);
});
