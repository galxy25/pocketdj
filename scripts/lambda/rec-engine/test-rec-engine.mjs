// Test suite for scripts/lambda/rec-engine/index.mjs. NO spawning (unlike the jukebox smoke
// suite): the module is imported directly and driven with synthetic API-Gateway v2 events, with
// REC_LOCAL_DIR pointing the state store at a temp dir (zero AWS) and REC_FEATURES_FILE at a
// small fixture (two genres, bpm spread, camelot pairs, two artists sharing an album).
//
//   node --test scripts/lambda/rec-engine/test-rec-engine.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const HOME = mkdtempSync(join(tmpdir(), 'rec-engine-test-'));
const FEATURES = join(HOME, 'rec-features.json');

// ~12-song fixture: electronic cluster around 120 BPM (Aria shares alb_e1), a jazz cluster, and
// camelot pairs (8A neighbors 7A/9A/8B).
const fixture = {
  v: 1, generatedAt: 'test', counts: { songs: 12 },
  songs: [
    { i: 'sng_e1', al: 'alb_e1', a: 'Aria', n: 'Neon', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark', 'moody'] },
    { i: 'sng_e2', al: 'alb_e1', a: 'Aria', n: 'Glow', g: 'electronic', y: 2020, b: 122, c: '8B', s: ['dark', 'euphoric'] },
    { i: 'sng_e3', al: 'alb_e1', a: 'Aria', n: 'Fade', g: 'electronic', y: 2021, b: 118, c: '9A', s: ['moody'] },
    { i: 'sng_e4', al: 'alb_e2', a: 'Mira', n: 'Golden Hour', g: 'electronic', y: 2019, b: 121, c: '7A', s: ['warm'] },
    { i: 'sng_e5', al: 'alb_e2', a: 'Mira', n: 'Dusk', g: 'electronic', y: 2019, b: 124, c: '8A', s: ['dark'] },
    { i: 'sng_e6', al: 'alb_e3', a: 'Vex', n: 'Pulse', g: 'electronic', y: 2022, b: 119, c: '12B', s: ['dark', 'driving'] },
    { i: 'sng_j1', al: 'alb_j1', a: 'Bento', n: 'Brass One', g: 'jazz', y: 1998, b: 90, c: '3A', s: ['smooth'] },
    { i: 'sng_j2', al: 'alb_j1', a: 'Bento', n: 'Brass Two', g: 'jazz', y: 1998, b: 92, c: '3B', s: ['smooth', 'warm'] },
    { i: 'sng_j3', al: 'alb_j2', a: 'Kessel', n: 'Night Cap', g: 'jazz', y: 2001, b: 88, c: '4A', s: ['mellow'] },
    { i: 'sng_x1', al: 'alb_x1', a: 'Noma', n: 'Untagged', y: 2010 },
    { i: 'sng_x2', al: 'alb_x1', a: 'Noma', n: 'Sparse', g: 'rock', y: 2010, b: 140 },
    { i: 'sng_w1', al: 'alb_w1', a: 'Wrap', n: 'Wraparound', g: 'electronic', y: 2020, b: 120, c: '1B' },
  ],
};
writeFileSync(FEATURES, JSON.stringify(fixture));

process.env.REC_LOCAL_DIR = HOME;
process.env.REC_FEATURES_FILE = FEATURES;
process.env.REC_ENROLL_SECRET = 'enroll-secret-for-tests';
/// This suite enrolls a fresh profile per scenario — far more than any real deployment would —
/// so the flood cap is lifted here and driven deliberately in its own test.
process.env.MAX_PROFILES = '1000';

const { handler, camelotNeighbors, mergeBatch, scoreForYou, scoreCollections, shedToFit,
        scoreSimilarToCollections, playCountSignal, recencySignal,
        feedbackOf, feedbackMultiplier } =
  await import('./index.mjs');

const PROFILE = 'profile-test-1234';
const KEY = 'a'.repeat(64);
const OTHER_KEY = 'b'.repeat(64);
const ENROLL = process.env.REC_ENROLL_SECRET;
const NOW = Date.now();
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/// `enroll` defaults to the right secret (every profile in this suite has to enroll once);
/// pass `enroll: null` for "no header" or a wrong string to drive the rejection paths.
function ev(method, path, { profile = PROFILE, key = KEY, enroll = ENROLL, body, qs } = {}) {
  const headers = {};
  if (profile !== null) headers['x-pocketdj-profile'] = profile;
  if (key !== null) headers.authorization = `Bearer ${key}`;
  if (enroll !== null) headers['x-pocketdj-enroll'] = enroll;
  return {
    rawPath: path,
    requestContext: { http: { method } },
    headers,
    queryStringParameters: qs,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  };
}

async function call(method, path, opts) {
  const res = await handler(ev(method, path, opts));
  return { status: res.statusCode, json: JSON.parse(res.body) };
}

let n = 0;
const uid = () => `evt_${String(n++).padStart(6, '0')}`;
const play = (songId, atMs) => ({ id: uid(), songId, atMs, source: 'browser' });

/// U+0001: one UTF-16 unit, SIX characters once JSON-escaped. The cheapest way to make a string
/// whose stored cost is 6× its length — which is exactly what the byte-budget tests need.
const CTRL = String.fromCharCode(1);

/// Where REC_LOCAL_DIR keeps a profile's state object (same layout as the S3 keys).
const statePath = (profile) =>
  join(HOME, 'rec', 'state', `${createHash('sha256').update(profile).digest('hex')}.json`);

test('health ok', async () => {
  const r = await call('GET', '/health', { profile: null, key: null });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true, service: 'rec-engine', version: 1 });
});

test('events requires profile header', async () => {
  const r = await call('POST', '/events', { profile: null, body: {} });
  assert.equal(r.status, 400);
  const r2 = await call('POST', '/events', { profile: 'x', body: {} });   // too short = invalid
  assert.equal(r2.status, 400);
});

test('events requires bearer', async () => {
  const r = await call('POST', '/events', { key: null, body: {} });
  assert.equal(r.status, 401);
});

test('recs/songs empty before any events', async () => {
  const r = await call('GET', '/recs/songs');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.songs, []);
  assert.deepEqual(r.json.seeds, []);
});

test('TOFU binds first key; wrong key 403; same key ok', async () => {
  const first = await call('POST', '/events', { body: { v: 1, plays: [play('sng_e1', NOW - DAY)] } });
  assert.equal(first.status, 200);
  const wrong = await call('POST', '/events', { key: OTHER_KEY, body: { v: 1, plays: [play('sng_e2', NOW)] } });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.json.error, 'key-mismatch');
  const wrongGet = await call('GET', '/recs/songs', { key: OTHER_KEY });
  assert.equal(wrongGet.status, 403);
  const same = await call('POST', '/events', { body: { v: 1 } });
  assert.equal(same.status, 200);
});

// ── Enrollment gate (the fix for "POST /events is an open write endpoint") ──────────────────────

test('creating a profile requires the enrollment secret', async () => {
  const profile = 'profile-enroll-01';
  const body = { v: 1, plays: [play('sng_e1', NOW - DAY)] };
  const none = await call('POST', '/events', { profile, enroll: null, body });
  assert.equal(none.status, 403);
  assert.equal(none.json.error, 'enrollment-required');
  const wrong = await call('POST', '/events', { profile, enroll: 'not-the-secret-xxxxx', body });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.json.error, 'enrollment-required');
  assert.equal(existsSync(statePath(profile)), false, 'a rejected enrollment writes NO state object');

  const ok = await call('POST', '/events', { profile, body });
  assert.equal(ok.status, 200);
  assert.equal(existsSync(statePath(profile)), true);
});

test('an already-bound profile keeps uploading with its key alone', async () => {
  const profile = 'profile-bound-001';
  assert.equal((await call('POST', '/events', { profile, body: { v: 1 } })).status, 200);
  // No enrollment header at all — the TOFU key is the only credential a bound profile needs.
  const later = await call('POST', '/events', {
    profile, enroll: null, body: { v: 1, plays: [play('sng_e1', NOW - DAY)] },
  });
  assert.equal(later.status, 200);
  assert.equal(later.json.accepted.plays, 1);
  // …and a WRONG key on a bound profile is still a key-mismatch, secret or not.
  const wrongKey = await call('POST', '/events', { profile, key: OTHER_KEY, body: { v: 1 } });
  assert.equal(wrongKey.status, 403);
  assert.equal(wrongKey.json.error, 'key-mismatch');
});

test('DELETE /state unwedges a mismatched key with the enrollment secret', async () => {
  const profile = 'profile-wedge-001';
  await call('POST', '/events', { profile, body: { v: 1, plays: [play('sng_e1', NOW - DAY)] } });
  // The wedged device: wrong key, no secret -> the old dead end.
  const blocked = await call('DELETE', '/state', { profile, key: OTHER_KEY, enroll: null });
  assert.equal(blocked.status, 403);
  assert.equal(blocked.json.error, 'key-mismatch');
  // The app ships the secret, so "Delete cloud data" really can reset it.
  const del = await call('DELETE', '/state', { profile, key: OTHER_KEY });
  assert.equal(del.status, 200);
  assert.equal(existsSync(statePath(profile)), false);
  // …and the freed profile re-binds to the new key (enrollment secret still required).
  const rebindNoSecret = await call('POST', '/events', { profile, key: OTHER_KEY, enroll: null, body: { v: 1 } });
  assert.equal(rebindNoSecret.status, 403);
  const rebind = await call('POST', '/events', { profile, key: OTHER_KEY, body: { v: 1 } });
  assert.equal(rebind.status, 200);
});

/// The enrollment secret ships inside the app binary, so "extractable" is a when, not an if. The
/// profile cap is what turns a leaked token from "unbounded objects in a bucket with no lifecycle
/// expiry" into "at most MAX_PROFILES of them" — and it must never touch a profile that already
/// exists, or the real user's own devices would be the ones locked out.
test('the enrollment cap bounds NEW profiles and leaves existing ones alone', async () => {
  const established = 'profile-cap-prior';
  assert.equal((await call('POST', '/events', { profile: established, body: { v: 1 } })).status, 200);

  const previous = process.env.MAX_PROFILES;
  process.env.MAX_PROFILES = '1';   // the bucket already holds far more than one
  try {
    const fresh = await call('POST', '/events', {
      profile: 'profile-cap-new01', body: { v: 1, plays: [play('sng_e1', NOW - DAY)] },
    });
    assert.equal(fresh.status, 403);
    assert.equal(fresh.json.error, 'profile-cap-reached');
    assert.equal(fresh.json.max, 1, 'the response names the cap it hit');
    assert.equal(existsSync(statePath('profile-cap-new01')), false, 'no object was created');

    // The cap gates ENROLLMENT only: an already-bound profile keeps uploading straight through it.
    const existing = await call('POST', '/events', {
      profile: established, body: { v: 1, plays: [play('sng_e2', NOW - DAY)] },
    });
    assert.equal(existing.status, 200);
    assert.equal(existing.json.accepted.plays, 1);
  } finally {
    if (previous === undefined) delete process.env.MAX_PROFILES;
    else process.env.MAX_PROFILES = previous;
  }

  // Cap lifted -> the same new profile enrolls normally.
  const after = await call('POST', '/events', { profile: 'profile-cap-new01', body: { v: 1 } });
  assert.equal(after.status, 200);
});

// ── Payload / state size limits ─────────────────────────────────────────────────────────────────

test('an oversized body is rejected before parsing', async () => {
  const profile = 'profile-huge-0001';
  const res = await handler(ev('POST', '/events', { profile, body: { v: 1, pad: 'x'.repeat(4.2 * 1024 * 1024) } }));
  assert.equal(res.statusCode, 413);
  assert.equal(JSON.parse(res.body).error, 'body-too-large');
  assert.equal(existsSync(statePath(profile)), false, 'nothing was written');
});

test('a snapshot-only batch cannot grow the state without bound', async () => {
  const profile = 'profile-snapcap-1';
  const collections = [];
  for (let c = 0; c < 600; c++) {
    collections.push({ id: `pls_${c}`, kind: 'playlist', name: `C${c}`,
                       songIds: Array.from({ length: 300 }, (_, i) => `s${c}_${i}`) });
  }
  const r = await call('POST', '/events', { profile, body: { v: 1, collectionsSnapshot: { atMs: NOW, collections } } });
  assert.equal(r.status, 200, 'the snapshot batch is accepted (it bypasses MAX_BATCH_EVENTS by design)');
  assert.equal(r.json.totals.collections, 500, 'stored collections truncated to MAX_COLLECTIONS');
  const stored = JSON.parse(readFileSync(statePath(profile), 'utf8'));
  const ids = stored.collections.list.reduce((n, c) => n + c.songIds.length, 0);
  assert.equal(ids, 100_000, 'total stored songIds truncated to MAX_SNAPSHOT_SONGIDS');

  // …and one fat collection is capped per-collection.
  const fat = { atMs: NOW + 1, collections: [{ id: 'pls_fat', kind: 'playlist', name: 'Fat',
                                               songIds: Array.from({ length: 6000 }, (_, i) => `f${i}`) }] };
  await call('POST', '/events', { profile, body: { v: 1, collectionsSnapshot: fat } });
  const after = JSON.parse(readFileSync(statePath(profile), 'utf8'));
  assert.equal(after.collections.list[0].songIds.length, 5000, 'per-collection songIds capped');
});

test('favorites are capped like the event streams (OLDEST evicted, not tombstones)', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  const favorites = [];
  for (let i = 0; i < 5100; i++) {
    favorites.push({ songId: `sng_${i}`, favorited: i % 2 === 0, atMs: NOW - i });
  }
  mergeBatch(state, { favorites });
  const keys = Object.keys(state.favorites);
  assert.equal(keys.length, 5000, 'the favorites MAP is capped, not unbounded');
  // atMs decreases with i, so the OLDEST rows are exactly i = 5000…5099 — hearts and tombstones
  // alike. Eviction follows the same time order the merge does; nothing else.
  const evicted = [...Array(5100).keys()].filter((i) => !(`sng_${i}` in state.favorites));
  assert.deepEqual(evicted, [...Array(100).keys()].map((k) => 5000 + k),
                   'exactly the 100 oldest rows, regardless of favorited/tombstone');
});

/// The reason eviction may not prefer hearts: doing so INVERTS last-writer-wins. A device that
/// has been offline for a week still carries the old heart inside its 30-day overlap window, so
/// an eviction that keeps the stale heart and drops the fresh un-heart hands that device a
/// resurrection on its very next upload — the user's un-favorite undoes itself.
test('capFavorites keeps a fresh tombstone over a stale heart (LWW is not inverted)', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  const favorites = [];
  // 5000 middle-aged hearts fill the cap exactly…
  for (let i = 0; i < 5000; i++) favorites.push({ songId: `mid_${i}`, favorited: true, atMs: NOW - DAY });
  // …then one ancient heart and one just-now un-heart arrive. Only one of the 5002 can be cut.
  favorites.push({ songId: 'sng_stale_heart', favorited: true, atMs: NOW - 400 * DAY });
  favorites.push({ songId: 'sng_fresh_unheart', favorited: false, atMs: NOW });
  mergeBatch(state, { favorites });

  assert.equal(Object.keys(state.favorites).length, 5000);
  assert.equal(state.favorites.sng_fresh_unheart?.favorited, false,
               'the newest write survives — a lagging device cannot resurrect the un-favorite');
  assert.equal('sng_stale_heart' in state.favorites, false,
               'the oldest row goes, even though it is a heart');
});

test('stored strings are truncated', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  const long = 'z'.repeat(5000);
  mergeBatch(state, {
    plays: [{ id: `p_${long}`, songId: `s_${long}`, atMs: NOW, source: long }],
    collectionsSnapshot: { atMs: NOW, collections: [{ id: `c_${long}`, kind: 'playlist', name: long, songIds: [long] }] },
  });
  assert.equal(state.plays[0].id.length, 256);
  assert.equal(state.plays[0].songId.length, 256);
  assert.equal(state.plays[0].source.length, 256);
  assert.equal(state.collections.list[0].name.length, 256);
  assert.equal(state.collections.list[0].songIds[0].length, 256);
});

/// The bound is SERIALIZED BYTES, not UTF-16 units. `'\u0001'` is one unit but six characters
/// once JSON-escaped, so a unit-based slice(0,256) stored 1536 bytes per "256-character" string —
/// 6× the intended budget on every field of every row, which is how a legal-looking batch used to
/// push the state object past MAX_STATE_BYTES.
test('string truncation bounds serialized BYTES, not UTF-16 units', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  const cost = (s) => JSON.stringify(s).length - 2;
  mergeBatch(state, {
    plays: [
      { id: CTRL.repeat(5000), songId: CTRL.repeat(5000), atMs: NOW, source: '\u201c'.repeat(5000) },
      { id: 'p_multibyte', songId: '\ud834\udd1e'.repeat(5000), atMs: NOW + 1, source: 'ok' },
    ],
  });
  for (const p of state.plays) {
    for (const field of [p.id, p.songId, p.source]) {
      if (field == null) continue;
      assert.ok(cost(field) <= 256, `serialized cost ${cost(field)} must stay within 256`);
    }
  }
  assert.ok(state.plays[0].id.length < 256, 'escaped control chars cut the stored length well below 256');
  // …and an honest ASCII string is untouched by the byte rule.
  const plain = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  mergeBatch(plain, { plays: [{ id: 'z'.repeat(300), songId: 'sng_ok', atMs: NOW }] });
  assert.equal(plain.plays[0].id.length, 256);
});

/// The wedge this closes: writeState used to REFUSE (413) a state that outgrew MAX_STATE_BYTES.
/// Since every later upload re-read the same too-big object, re-merged and hit the same refusal,
/// the profile could never write again — a permanent, silent dead end. Now the oldest rows are
/// SHED instead, and the profile stays writable.
test('an adversarial batch sheds old rows instead of wedging the profile', async () => {
  const profile = 'profile-shed-0001';
  // 300 control chars per field: 1800 serialized bytes each ON THE WIRE, so 500 rows per batch
  // stays comfortably under MAX_BODY_BYTES. The old UTF-16 slice(0,256) then STORED 1536 bytes of
  // them per field — ~4.6 KB a row, and the 5000-row plays cap put the object at ~23 MB, past
  // MAX_STATE_BYTES. Every upload from that point on 413'd forever.
  const pad = CTRL.repeat(300);
  const fat = (i) => ({ id: `fat_${String(i).padStart(6, '0')}_${pad}`, songId: `s_${pad}`,
                        atMs: NOW - (100000 - i), source: pad });
  for (let batch = 0; batch < 10; batch++) {
    const plays = Array.from({ length: 500 }, (_, i) => fat(batch * 500 + i));
    const r = await call('POST', '/events', { profile, body: { v: 1, plays } });
    assert.equal(r.status, 200, `batch ${batch} must be accepted, not 413`);
  }
  const stored = JSON.parse(readFileSync(statePath(profile), 'utf8'));
  assert.equal(stored.plays.length, 5000, 'the row cap still holds');
  assert.ok(Buffer.byteLength(JSON.stringify(stored), 'utf8') <= 20 * 1024 * 1024,
            'the stored object stays inside MAX_STATE_BYTES');

  // The profile is still WRITABLE, which is the whole point — a fresh, ordinary play lands.
  const after = await call('POST', '/events', { profile, body: { v: 1, plays: [play('sng_e1', NOW)] } });
  assert.equal(after.status, 200);
  assert.equal(after.json.accepted.plays, 1, 'a normal upload still works after the adversarial load');
});

test('shedToFit drops oldest rows first and leaves the state under budget', () => {
  const state = {
    v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
  };
  for (let i = 0; i < 4000; i++) state.plays.push({ id: `p${i}`, songId: 'x'.repeat(200), atMs: i });
  const before = Buffer.byteLength(JSON.stringify(state), 'utf8');
  const { bytes, shed } = shedToFit(state, Math.floor(before / 2));
  assert.ok(shed > 0, 'rows were shed');
  assert.ok(bytes <= Math.floor(before / 2), 'the result fits the budget');
  assert.equal(state.plays[0].atMs > 0, true, 'the surviving rows are the NEWEST (oldest shed first)');
  assert.equal(shedToFit(state, 50 * 1024 * 1024).shed, 0, 'an already-fitting state is untouched');
});

test('events dedupe by id and enforce caps', async () => {
  const profile = 'profile-caps-0001';
  const batch = { v: 1, plays: [play('sng_e1', NOW - 2 * DAY), play('sng_e2', NOW - DAY)] };
  const a = await call('POST', '/events', { profile, body: batch });
  assert.equal(a.status, 200);
  assert.equal(a.json.accepted.plays, 2);
  const b = await call('POST', '/events', { profile, body: batch });   // exact re-upload
  assert.equal(b.status, 200);
  assert.equal(b.json.accepted.plays, 0, 'identical ids must be deduped');
  assert.equal(b.json.totals.plays, 2, 'totals unchanged on a re-upload');

  // 5001 plays across batches -> capped at 5000 NEWEST (the two old ones above fall out first).
  let sent = 2;
  let seq = 0;
  while (sent < 5001) {
    const chunk = [];
    const take = Math.min(1999, 5001 - sent);
    for (let i = 0; i < take; i++) {
      chunk.push({ id: `cap_${String(seq++).padStart(6, '0')}`, songId: 'sng_e3', atMs: NOW - HOUR + seq });
    }
    const r = await call('POST', '/events', { profile, body: { v: 1, plays: chunk } });
    assert.equal(r.status, 200);
    sent += take;
  }
  const last = await call('POST', '/events', { profile, body: { v: 1 } });
  assert.equal(last.json.totals.plays, 5000, 'capped at 5000');

  const tooBig = { v: 1, plays: Array.from({ length: 2001 }, (_, i) => play('sng_e1', NOW - i)) };
  const rej = await call('POST', '/events', { profile, body: tooBig });
  assert.equal(rej.status, 400, 'a single batch > 2000 events is rejected');
});

test('collections snapshot replaces wholesale', async () => {
  const profile = 'profile-snap-0001';
  const snap1 = { atMs: NOW, collections: [{ id: 'pls_a', kind: 'playlist', name: 'A', songIds: ['sng_e1'] }] };
  const r1 = await call('POST', '/events', { profile, body: { v: 1, collectionsSnapshot: snap1 } });
  assert.equal(r1.status, 200);
  assert.equal(r1.json.accepted.collectionsSnapshot, true);
  const snap2 = { atMs: NOW + 1, collections: [{ id: 'pls_b', kind: 'playlist', name: 'B', songIds: ['sng_e2'] }] };
  await call('POST', '/events', { profile, body: { v: 1, collectionsSnapshot: snap2 } });
  // Prove the replace via scoring: a song-suggestion request for sng_e1 must see only pls_b now.
  const rec = await call('GET', '/recs/collections', { profile, qs: { songId: 'sng_e1' } });
  assert.equal(rec.status, 200);
  assert.ok(!rec.json.suggestions.some((s) => s.id === 'pls_a'), 'pls_a was replaced wholesale');
});

test('unknown batch fields (songFeatures) are accepted and dropped', async () => {
  const profile = 'profile-fwd-00001';
  const r = await call('POST', '/events', {
    profile,
    body: { v: 1, songFeatures: [{ anything: true }], mystery: 42, plays: [play('sng_e1', NOW - DAY)] },
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted.plays, 1);
});

test('recs/songs ranks same-genre similar-bpm candidate first and excludes songs played <72h', async () => {
  const profile = 'profile-rank-0001';
  // Seed: electronic plays around 120 BPM, 5-10 days old (outside the 72 h exclusion), plus a
  // RECENT play of sng_e5 (inside 72 h -> excluded from candidates).
  const body = {
    v: 1,
    plays: [
      play('sng_e1', NOW - 5 * DAY), play('sng_e2', NOW - 6 * DAY), play('sng_e3', NOW - 7 * DAY),
      play('sng_e5', NOW - HOUR),
    ],
    favorites: [{ songId: 'sng_e1', favorited: true, atMs: NOW - 5 * DAY }],
  };
  await call('POST', '/events', { profile, body });
  const r = await call('GET', '/recs/songs', { profile, qs: { limit: '10' } });
  assert.equal(r.status, 200);
  const ids = r.json.songs.map((s) => s.songId);
  assert.ok(ids.length > 0, 'ranked candidates exist');
  assert.ok(!ids.includes('sng_e5'), 'a song played <72h ago is excluded');
  assert.ok(!ids.includes('sng_e1'), 'seeds are excluded');
  const top = r.json.songs[0];
  assert.equal(fixture.songs.find((s) => s.i === top.songId).g, 'electronic',
               'top candidate matches the seed genre');
  const e4 = ids.indexOf('sng_e4'); const j3 = ids.indexOf('sng_j3');
  assert.ok(e4 !== -1, 'the similar-bpm electronic candidate ranks');
  assert.ok(j3 === -1 || e4 < j3, 'electronic ~120 BPM outranks the jazz cluster');
  assert.ok(top.name && top.artist, 'name/artist ride the response');
  assert.ok(Array.isArray(top.reasons) && top.reasons.length >= 1 && top.reasons.length <= 3);
});

test('diversity cap max 2 per artist', async () => {
  const profile = 'profile-divers-01';
  // Heavy electronic seed with NO recent plays: Aria has three album mates (e1 seed, e2/e3
  // candidates) — without a third Aria song the cap needs a wider fixture, so seed on Mira
  // instead: candidates then include all three Aria songs.
  const body = {
    v: 1,
    plays: [play('sng_e4', NOW - 5 * DAY), play('sng_e5', NOW - 6 * DAY)],
  };
  await call('POST', '/events', { profile, body });
  const r = await call('GET', '/recs/songs', { profile, qs: { limit: '50' } });
  const byArtist = {};
  for (const s of r.json.songs) {
    const artist = fixture.songs.find((f) => f.i === s.songId)?.a;
    byArtist[artist] = (byArtist[artist] || 0) + 1;
  }
  assert.ok(Object.values(byArtist).every((c) => c <= 2), `max 2 per artist: ${JSON.stringify(byArtist)}`);
  assert.equal(byArtist.Aria, 2, 'Aria capped at 2 of her 3 candidates');
});

test('recs/collections ranks the genre-matching collection and skips collections already containing the song', async () => {
  const profile = 'profile-cols-0001';
  const body = {
    v: 1,
    plays: [play('sng_e1', NOW - 2 * HOUR), play('sng_e2', NOW - 2 * HOUR + 10 * 60 * 1000)],
    activity: [{ id: uid(), atMs: NOW - DAY, kind: 'add', itemId: 'sng_e2', collectionId: 'pls_elec',
                 collectionKind: 'playlist', collectionName: 'Late Night' }],
    collectionsSnapshot: {
      atMs: NOW,
      collections: [
        { id: 'pls_elec', kind: 'playlist', name: 'Late Night', songIds: ['sng_e2', 'sng_e3', 'sng_e5'] },
        { id: 'pls_jazz', kind: 'playlist', name: 'Smoke', songIds: ['sng_j1', 'sng_j2', 'sng_j3'] },
        { id: 'pls_has', kind: 'playlist', name: 'Already In', songIds: ['sng_e1', 'sng_j1'] },
        { id: 'pkt_empty', kind: 'pocket', name: 'Empty', songIds: [] },
      ],
    },
  };
  await call('POST', '/events', { profile, body });
  const r = await call('GET', '/recs/collections', { profile, qs: { songId: 'sng_e1' } });
  assert.equal(r.status, 200);
  const ids = r.json.suggestions.map((s) => s.id);
  assert.ok(!ids.includes('pls_has'), 'a collection already containing the song is skipped');
  assert.ok(!ids.includes('pkt_empty'), 'empty collections are skipped');
  assert.ok(ids.includes('pls_elec'), 'the genre+bpm+coplay match surfaces');
  if (ids.includes('pls_jazz')) {
    assert.ok(ids.indexOf('pls_elec') < ids.indexOf('pls_jazz'), 'electronic outranks jazz for an electronic song');
  }
  const top = r.json.suggestions[0];
  assert.equal(top.id, 'pls_elec');
  assert.ok(top.score >= 0.8, 'meets the threshold');
  assert.ok(top.reasons.length >= 1);
});

test('recs/collections unknown songId returns empty suggestions', async () => {
  const r = await call('GET', '/recs/collections', { qs: { songId: 'sng_nope' } });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.suggestions, []);
});

test('DELETE /state then recs empty again', async () => {
  const profile = 'profile-del-00001';
  await call('POST', '/events', { profile, body: { v: 1, plays: [play('sng_e1', NOW - DAY)] } });
  const before = await call('GET', '/recs/songs', { profile });
  assert.ok(before.json.songs.length > 0);
  const del = await call('DELETE', '/state', { profile });
  assert.equal(del.status, 200);
  assert.deepEqual(del.json, { deleted: true });
  const after = await call('GET', '/recs/songs', { profile });
  assert.equal(after.status, 200);
  assert.deepEqual(after.json.songs, []);
  // A different key can now bind fresh (state is gone).
  const rebind = await call('POST', '/events', { profile, key: OTHER_KEY, body: { v: 1 } });
  assert.equal(rebind.status, 200);
});

// ── Pure function tests ─────────────────────────────────────────────────────────────────────────

test('camelotNeighbors wraps 12B↔1B', () => {
  assert.deepEqual([...camelotNeighbors('12B')].sort(), ['11B', '12A', '12B', '1B'].sort());
  assert.deepEqual([...camelotNeighbors('1B')].sort(), ['12B', '1A', '1B', '2B'].sort());
  assert.deepEqual([...camelotNeighbors('8A')].sort(), ['7A', '8A', '8B', '9A'].sort());
  assert.equal(camelotNeighbors('nope').size, 0);
  assert.equal(camelotNeighbors(null).size, 0);
});

test('scoreForYou deterministic ordering', () => {
  const byId = new Map(fixture.songs.map((s) => [s.i, s]));
  const state = {
    v: 1, plays: [play('sng_e1', NOW - 5 * DAY), play('sng_e2', NOW - 6 * DAY)],
    favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] },
  };
  const a = scoreForYou(state, byId, { nowMs: NOW, limit: 20 });
  const b = scoreForYou(state, byId, { nowMs: NOW, limit: 20 });
  assert.deepEqual(a.songs, b.songs, 'same inputs -> identical ordering');
  assert.ok(a.songs.length > 0);
});

test('mergeBatch favorites newer atMs wins', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  mergeBatch(state, { favorites: [{ songId: 'sng_e1', favorited: true, atMs: 100 }] });
  mergeBatch(state, { favorites: [{ songId: 'sng_e1', favorited: false, atMs: 50 }] });
  assert.equal(state.favorites.sng_e1.favorited, true, 'older tombstone must not clobber the newer heart');
  mergeBatch(state, { favorites: [{ songId: 'sng_e1', favorited: false, atMs: 200 }] });
  assert.equal(state.favorites.sng_e1.favorited, false, 'newer edit wins');
});

test('scoreCollections coPlay window counts member plays near the song plays', () => {
  const byId = new Map(fixture.songs.map((s) => [s.i, s]));
  const state = {
    v: 1,
    plays: [
      play('sng_e1', NOW - 2 * HOUR),
      play('sng_e2', NOW - 2 * HOUR + 5 * 60 * 1000),      // within 30 min of the sng_e1 play
      play('sng_e3', NOW - 20 * HOUR),                     // far away — no co-play credit
    ],
    favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [{ id: 'pls_x', kind: 'playlist', name: 'X', songIds: ['sng_e2', 'sng_e3'] }] },
  };
  const withCo = scoreCollections(state, byId, 'sng_e1', { nowMs: NOW, threshold: 0 });
  const noCoState = { ...state, plays: state.plays.filter((p) => p.songId !== 'sng_e2') };
  const withoutCo = scoreCollections(noCoState, byId, 'sng_e1', { nowMs: NOW, threshold: 0 });
  assert.ok(withCo.suggestions[0].score > withoutCo.suggestions[0].score,
            'the ±30 min co-play adds score');
});

// ── Gem Collector: GET /recs/similar (songs similar to a SET of collections) ─────────────────────

const featureIndex = () => new Map(fixture.songs.map((s) => [s.i, s]));

/// A state whose one target collection is the electronic Aria cluster.
function similarState(extra = {}) {
  return {
    v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [
      { id: 'pkt_target', kind: 'pocket', name: 'Crate', songIds: ['sng_e1', 'sng_e2'] },
      ...(extra.extraCollections || []),
    ] },
    ...extra.overrides,
  };
}

test('scoreSimilarToCollections excludes the collection’s existing members', () => {
  const out = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const ids = out.songs.map((s) => s.songId);
  assert.ok(!ids.includes('sng_e1'), 'a song already filed is a card the player cannot score');
  assert.ok(!ids.includes('sng_e2'));
  assert.ok(ids.length > 0, 'and it still returns candidates');
});

test('scoreSimilarToCollections ranks same-artist / same-genre above unrelated', () => {
  const out = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const rank = (id) => out.songs.findIndex((s) => s.songId === id);
  assert.ok(rank('sng_e3') >= 0, 'the third Aria track is a candidate');
  assert.ok(rank('sng_j1') === -1 || rank('sng_e3') < rank('sng_j1'),
            'same-artist electronic outranks unrelated jazz');
  assert.ok(rank('sng_e4') === -1 || rank('sng_e3') < rank('sng_e4'),
            'same artist outranks same-genre-different-artist');
});

test('scoreSimilarToCollections honours the max-2-per-artist diversity cap', () => {
  const wide = {
    v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [{ id: 'pkt_t', kind: 'pocket', name: 'T', songIds: ['sng_x1'] }] },
  };
  const out = scoreSimilarToCollections(wide, featureIndex(), ['pkt_t'], { nowMs: NOW, limit: 50 });
  const perArtist = new Map();
  for (const s of out.songs) perArtist.set(s.artist, (perArtist.get(s.artist) || 0) + 1);
  for (const [artist, n] of perArtist) assert.ok(n <= 2, `${artist} appears ${n} times (cap is 2)`);
});

test('scoreSimilarToCollections returns an empty list for unknown collection ids', () => {
  const out = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_nope'], { nowMs: NOW });
  assert.deepEqual(out.songs, []);
  assert.equal(out.v, 1);
});

test('scoreSimilarToCollections co-membership and co-play lift a song', () => {
  const base = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const lifted = scoreSimilarToCollections(
    similarState({
      extraCollections: [{ id: 'pkt_other', kind: 'pocket', name: 'Other',
                           songIds: ['sng_e1', 'sng_j3'] }],
      overrides: { plays: [play('sng_e1', NOW - 2 * HOUR),
                           play('sng_j3', NOW - 2 * HOUR + 5 * 60 * 1000)] },
    }),
    featureIndex(), ['pkt_target'], { nowMs: NOW });
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;
  assert.ok(scoreOf(lifted, 'sng_j3') > scoreOf(base, 'sng_j3'),
            'sharing another crate + a listening session with a member raises the score');
});

test('scoreSimilarToCollections is deterministic', () => {
  const a = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const b = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  assert.deepEqual(a.songs, b.songs);
});

test('GET /recs/similar: 400 without ids, 200+empty without state, then real rows', async () => {
  const profile = 'profile-similar-1';
  const bad = await call('GET', '/recs/similar', { profile });
  assert.equal(bad.status, 400, 'no collectionIds is a bad request');

  const empty = await call('GET', '/recs/similar', { profile, qs: { collectionIds: 'pkt_a' } });
  assert.equal(empty.status, 200, 'no state object is not an error');
  assert.deepEqual(empty.json.songs, []);

  const up = await call('POST', '/events', {
    profile,
    body: { v: 1, collectionsSnapshot: { atMs: NOW, collections: [
      { id: 'pkt_a', kind: 'pocket', name: 'A', songIds: ['sng_e1', 'sng_e2'] }] } },
  });
  assert.equal(up.status, 200);
  assert.equal(up.json.totals.collections, 1, 'the snapshot landed');
  const real = await call('GET', '/recs/similar', { profile, qs: { collectionIds: 'pkt_a' } });
  assert.equal(real.status, 200);
  assert.ok(real.json.songs.length > 0, 'similar songs come back');
  assert.ok(!real.json.songs.some((s) => s.songId === 'sng_e1'), 'members excluded');

  // A mismatched key is refused exactly like the other read routes.
  const wrong = await call('GET', '/recs/similar',
                           { profile, key: OTHER_KEY, qs: { collectionIds: 'pkt_a' } });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.json.error, 'key-mismatch');
});

/// The renamed reason string RENDERS INSIDE THE APP (AddToCollectionView's Suggested section),
/// so it is user-visible server output. Assert the literal so the rename can't silently regress.
test('the Gem Collector reason string is the one the app renders', () => {
  const state = {
    v: 1, plays: [], favorites: {}, activity: [],
    puzzle: [{ id: 'p1', atMs: NOW, songId: 'sng_e1', collectionId: 'pls_x', action: 'added' }],
    collections: { atMs: 0, list: [{ id: 'pls_x', kind: 'playlist', name: 'X', songIds: ['sng_e2'] }] },
  };
  const out = scoreCollections(state, featureIndex(), 'sng_e3', { nowMs: NOW, threshold: 0 });
  const reasons = out.suggestions.flatMap((s) => s.reasons);
  assert.ok(reasons.includes('Matches your Gem Collector picks'),
            `renamed reason string missing: ${JSON.stringify(reasons)}`);
  assert.ok(!reasons.some((r) => r.includes('Puzzle')), 'the old name is gone');
});

// ── LIFETIME play counts (the imported Apple baseline as a ranking signal) ───────────────────────
//
// The signal exists because a 30-day play window is structurally blind to the thing that actually
// describes this user's taste: ~144k plays Apple accumulated long before PocketDJ existed, against
// ~900 the app has seen itself. These tests pin the two properties that make importing it safe —
// it is a SNAPSHOT (replaced, never summed) and it is bounded — and the two that make it useful.

test('playCounts are a SNAPSHOT: replaced wholesale, never summed', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  mergeBatch(state, { playCounts: { atMs: 100, counts: { sng_e1: 5, sng_e2: 2 } } });
  assert.deepEqual(state.playCounts.counts, { sng_e1: 5, sng_e2: 2 });

  // THE invariant. Re-uploading the same snapshot must not double it — the server-side twin of
  // the device's SET-never-ADD rule.
  mergeBatch(state, { playCounts: { atMs: 100, counts: { sng_e1: 5, sng_e2: 2 } } });
  assert.deepEqual(state.playCounts.counts, { sng_e1: 5, sng_e2: 2 }, 're-upload is a no-op');

  // A newer snapshot replaces WHOLESALE, downward moves included and dropped songs gone.
  mergeBatch(state, { playCounts: { atMs: 200, counts: { sng_e1: 6 } } });
  assert.deepEqual(state.playCounts.counts, { sng_e1: 6 });

  // A STALE snapshot (an out-of-order device) must not walk the numbers backwards.
  mergeBatch(state, { playCounts: { atMs: 150, counts: { sng_e1: 1, sng_e9: 99 } } });
  assert.deepEqual(state.playCounts.counts, { sng_e1: 6 }, 'older snapshot dropped');
});

test('playCounts reject junk rows and cap at the most-played', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  const r = mergeBatch(state, { playCounts: { atMs: 10, counts: {
    sng_ok: 3, sng_zero: 0, sng_neg: -5, sng_nan: 'lots', sng_null: null,
  } } });
  assert.deepEqual(state.playCounts.counts, { sng_ok: 3 }, 'only positive finite counts survive');
  assert.equal(r.accepted.playCounts, 1);

  // The cap keeps the HEAD of the distribution — the rows that carry the signal.
  const many = {};
  for (let i = 0; i < 25_000; i++) many[`sng_${i}`] = i + 1;
  const big = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  mergeBatch(big, { playCounts: { atMs: 1, counts: many } });
  const kept = Object.keys(big.playCounts.counts);
  assert.equal(kept.length, 20_000, 'truncated to MAX_PLAYCOUNT_SONGS');
  assert.ok(big.playCounts.counts.sng_24999 === 25_000, 'the most-played row survived');
  assert.ok(big.playCounts.counts.sng_0 === undefined, 'the 1-play tail was dropped');
});

test('playCountSignal is log-scaled, normalised, and 0 for absent', () => {
  assert.equal(playCountSignal(0, 100), 0);
  assert.equal(playCountSignal(5, 0), 0);
  assert.equal(playCountSignal(undefined, 100), 0);
  assert.equal(playCountSignal(100, 100), 1, 'the top of the distribution is full strength');
  // Log-scaled: 10× the plays is far from 10× the signal.
  const ten = playCountSignal(10, 1000);
  const hundred = playCountSignal(100, 1000);
  assert.ok(hundred > ten);
  assert.ok(hundred < 10 * ten, 'a linear term would have made the top songs the only ones scoring');
  // Comparable across users: full strength at each library's own maximum.
  assert.equal(playCountSignal(10, 10), playCountSignal(5000, 5000));
});

test('lifetime plays alone can seed For You (the cold-start an imported baseline fixes)', () => {
  // NO recent plays at all — exactly a fresh install that just imported its Apple baseline.
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] },
                  playCounts: { atMs: NOW, counts: { sng_e1: 244, sng_e2: 60 } } };
  const out = scoreForYou(state, featureIndex(), { nowMs: NOW, limit: 20 });
  assert.ok(out.seeds.includes('sng_e1'), 'the most-played song of all time is a seed');
  assert.ok(out.songs.length > 0, 'and recommendations come back instead of an empty list');
  // Taste followed the seeds: the electronic cluster, not the jazz one.
  assert.equal(out.songs[0].songId.slice(0, 5), 'sng_e');

  // Without the signal the SAME state produces nothing at all — that is the whole gap it closes.
  const blind = { ...state, playCounts: { atMs: 0, counts: {} } };
  assert.equal(scoreForYou(blind, featureIndex(), { nowMs: NOW, limit: 20 }).songs.length, 0);
});

test('a song in the most-played HEAD becomes a seed, so it is not recommended back', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] },
                  playCounts: { atMs: NOW, counts: { sng_e1: 244 } } };
  const out = scoreForYou(state, featureIndex(), { nowMs: NOW, limit: 20 });
  assert.ok(out.seeds.includes('sng_e1'));
  assert.ok(!out.songs.some((s) => s.songId === 'sng_e1'),
            'a seed is what the list is built FROM; suggesting it back is not a recommendation');
});

test('a played candidate outside the seed head is lifted, with the reason shown', () => {
  // `playCountSeedLimit: 1` puts sng_e1 (the most-played) in the head and leaves sng_e4 in the
  // TAIL — where a real 56k-row baseline leaves ~55,800 songs. Both states share the same seeds
  // and the same maximum, so the ONLY difference is sng_e4's own candidate term.
  const opts = { nowMs: NOW, limit: 20, playCountSeedLimit: 1 };
  const base = { v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {}, activity: [],
                 puzzle: [], collections: { atMs: 0, list: [] },
                 playCounts: { atMs: NOW, counts: { sng_e1: 500 } } };
  const before = scoreForYou(base, featureIndex(), opts);
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;

  const loved = { ...base,
                  playCounts: { atMs: NOW, counts: { sng_e1: 500, sng_e4: 200, sng_x1: 200 } } };
  const after = scoreForYou(loved, featureIndex(), opts);
  assert.deepEqual(after.seeds, before.seeds, 'the seed set — and so the taste profile — is identical');
  assert.ok(scoreOf(after, 'sng_e4') > scoreOf(before, 'sng_e4'), 'lifetime plays lift the score');

  // The reason surfaces on `sng_x1` — a sparse row (year only) where plays IS the leading term.
  // On a fully-tagged song the genre/key/BPM terms outrank it, which is the intent: familiarity
  // supports a recommendation, it doesn't explain one on its own.
  const row = after.songs.find((s) => s.songId === 'sng_x1');
  assert.ok(row.reasons.some((r) => r === "You've played this 200 times"),
            `the play-count reason is user-visible: ${JSON.stringify(row.reasons)}`);

  // A song with no lifetime plays is untouched — the term must contribute exactly 0, not a penalty.
  assert.equal(scoreOf(after, 'sng_e6'), scoreOf(before, 'sng_e6'));
});

test('an EMPTY playCounts snapshot leaves every existing score byte-identical', () => {
  // The signal must be strictly additive: a profile that never uploads counts ranks exactly as it
  // did before this feature existed.
  const legacy = { v: 1, plays: [play('sng_e1', NOW - 5 * DAY), play('sng_e2', NOW - 6 * DAY)],
                   favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] } };
  const withEmpty = { ...legacy, playCounts: { atMs: NOW, counts: {} } };
  assert.deepEqual(scoreForYou(withEmpty, featureIndex(), { nowMs: NOW, limit: 20 }).songs,
                   scoreForYou(legacy, featureIndex(), { nowMs: NOW, limit: 20 }).songs);
});

test('lifetime plays are a tiebreak inside /recs/similar too', () => {
  const plain = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const loved = scoreSimilarToCollections(
    similarState({ overrides: { playCounts: { atMs: NOW, counts: { sng_e6: 150 } } } }),
    featureIndex(), ['pkt_target'], { nowMs: NOW });
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;
  assert.ok(scoreOf(loved, 'sng_e6') > scoreOf(plain, 'sng_e6'));
  assert.ok(loved.songs.find((s) => s.songId === 'sng_e6').reasons
              .some((r) => r === "You've played this 150 times"));
});

test('playCounts ride a real /events flush and are reported in totals', async () => {
  const profile = 'profile-plays-001';
  const r = await call('POST', '/events', {
    profile,
    body: { v: 1, plays: [play('sng_e1', NOW - DAY)],
            playCounts: { atMs: NOW, counts: { sng_e1: 244, sng_e2: 60, sng_e3: 12 } } },
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted.playCounts, 3);
  assert.equal(r.json.totals.playCounts, 3);

  const recs = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.equal(recs.status, 200);
  assert.ok(recs.json.seeds.includes('sng_e2'), 'a lifetime-played song seeded through the route');
});

test('shedToFit drops the LEAST-played counts, keeping the head of the distribution', () => {
  const counts = {};
  for (let i = 0; i < 400; i++) counts[`sng_${String(i).padStart(4, '0')}${CTRL.repeat(30)}`] = i + 1;
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 1, counts } };
  const before = Object.keys(state.playCounts.counts).length;
  const { bytes, shed } = shedToFit(state, 4000);
  assert.ok(bytes <= 4000, 'the state came back under budget');
  assert.ok(shed > 0);
  const remaining = Object.values(state.playCounts.counts);
  const dropped = before - remaining.length;
  assert.ok(dropped > 0);
  if (remaining.length) {
    // Everything kept must be at least as played as the largest dropped row would have been.
    assert.ok(Math.min(...remaining) > 1, 'the 1-play tail went first, not the most-played rows');
  }
});

// ── LAST-PLAYED recency: the second play axis ───────────────────────────────────────────────────
//
// Recency is deliberately NOT a refinement of the play count. These tests pin the property that
// makes it worth storing at all: the two axes are SEPARABLE — either one can move a ranking while
// the other is held fixed. A design that collapsed them into one score fails the last two tests.

/// Whole days since the epoch, the unit the client sends (`RecPlayCountsWire.lastPlayedDays`).
const dayOf = (ms) => Math.floor(ms / DAY);
const HALF_LIFE_DAYS = 730;

test('recencySignal: absent is 0, today is 1, and one half-life is exactly 0.5', () => {
  // ABSENT ≡ NEVER PLAYED, not "unknown" — the same convention playCountSignal uses for a
  // missing count. It must contribute nothing rather than a penalty.
  assert.equal(recencySignal(undefined, NOW), 0);
  assert.equal(recencySignal(0, NOW), 0);
  assert.equal(recencySignal('yesterday', NOW), 0);
  assert.equal(recencySignal(NaN, NOW), 0);

  assert.ok(Math.abs(recencySignal(dayOf(NOW), NOW) - 1) < 1e-9, 'played today ⇒ full strength');
  const oneHalfLife = recencySignal(dayOf(NOW) - HALF_LIFE_DAYS, NOW);
  assert.ok(Math.abs(oneHalfLife - 0.5) < 1e-6, `two years ⇒ 0.5, got ${oneHalfLife}`);
  const twoHalfLives = recencySignal(dayOf(NOW) - 2 * HALF_LIFE_DAYS, NOW);
  assert.ok(Math.abs(twoHalfLives - 0.25) < 1e-6, `four years ⇒ 0.25, got ${twoHalfLives}`);
});

test('recencySignal decays MONOTONICALLY and clamps a future date to 1', () => {
  // Monotone over the whole realistic range — a cliff (e.g. "played in the last 30 days") would
  // score the owner's median song (last played 5.8 years ago) identically to one from 1998.
  let prev = Infinity;
  for (const ageDays of [0, 1, 7, 30, 90, 180, 365, 730, 1095, 1825, 2117, 3650, 10_000]) {
    const v = recencySignal(dayOf(NOW) - ageDays, NOW);
    assert.ok(v <= prev, `not monotone at ${ageDays}d: ${v} > ${prev}`);
    assert.ok(v >= 0 && v <= 1, `out of range at ${ageDays}d: ${v}`);
    prev = v;
  }
  // The MEDIAN of the owner's real library must still be a live number, not a rounding artifact:
  // this is the whole reason the half-life is 2 years rather than 30 days.
  assert.ok(recencySignal(dayOf(NOW) - 2117, NOW) > 0.1,
            'the median real song still carries signal');

  // Clock skew must not let one bad row outweigh the library.
  assert.equal(recencySignal(dayOf(NOW) + 500, NOW), 1);
});

test('an ABSENT lastPlayedDays map leaves every existing score byte-identical', () => {
  // The strict additivity guarantee, mirroring the empty-playCounts test above: a profile that
  // has never uploaded dates (every client before this build) ranks exactly as it did.
  const counts = { sng_e1: 40, sng_e2: 10, sng_x1: 200 };
  const legacy = { v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {}, activity: [],
                   puzzle: [], collections: { atMs: 0, list: [] },
                   playCounts: { atMs: NOW, counts } };
  const withEmpty = { ...legacy, playCounts: { atMs: NOW, counts, lastPlayedDays: {} } };
  assert.deepEqual(scoreForYou(withEmpty, featureIndex(), { nowMs: NOW, limit: 20 }).songs,
                   scoreForYou(legacy, featureIndex(), { nowMs: NOW, limit: 20 }).songs);
});

test('recency and plays are SEPARABLE axes in For You', () => {
  const featuresById = featureIndex();
  // `playCountSeedLimit: 0` keeps the counted songs OUT of the seed set (seeds are excluded from
  // the candidate list), so this isolates exactly what we mean to measure: the CANDIDATE terms.
  // Seeding is driven by the 30-day play log instead, and gets its own test below.
  const base = (counts, lastPlayedDays) => ({
    v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
    playCounts: { atMs: NOW, counts, lastPlayedDays },
  });
  const run = (counts, days) =>
    scoreForYou(base(counts, days), featuresById, { nowMs: NOW, limit: 20, playCountSeedLimit: 0 });
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;

  // AXIS 1 — hold plays EQUAL, vary only the date. sng_j1 and sng_j2 are the same artist, album,
  // genre and year in the fixture, so the date is genuinely the only thing that differs.
  const recency = run({ sng_j1: 20, sng_j2: 20 },
                      { sng_j1: dayOf(NOW) - 1825, sng_j2: dayOf(NOW) - 1 });
  assert.ok(scoreOf(recency, 'sng_j2') > scoreOf(recency, 'sng_j1'),
            'equal plays, fresher date ⇒ ranks higher');

  // AXIS 2 — hold the DATE equal, vary only the count. The order must flip back, which is what
  // proves recency did not simply replace the play count.
  const sameDay = { sng_j1: dayOf(NOW) - 400, sng_j2: dayOf(NOW) - 400 };
  const plays = run({ sng_j1: 200, sng_j2: 2 }, sameDay);
  assert.ok(scoreOf(plays, 'sng_j1') > scoreOf(plays, 'sng_j2'),
            'equal dates, more plays ⇒ ranks higher');

  // THE POINT: one collapsed score could not produce both orderings from the same engine.
  // "Played a lot long ago" and "played once yesterday" stay distinguishable.
  const mixed = run({ sng_j1: 200, sng_j2: 2 },
                    { sng_j1: dayOf(NOW) - 2500, sng_j2: dayOf(NOW) - 1 });
  assert.ok(scoreOf(mixed, 'sng_j1') > 0 && scoreOf(mixed, 'sng_j2') > 0,
            'the heavy-but-old and light-but-recent songs both survive scoring');
});

test('the recency reason is user-visible on a candidate', () => {
  // `sng_x1` is the fixture's sparse row (year only), so the genre/BPM/key terms that normally
  // outrank a play signal are absent and recency reaches the top-3 reasons. On a fully-tagged
  // song it stays a supporting term, which is the intent.
  const out = scoreForYou(
    { v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {}, activity: [], puzzle: [],
      collections: { atMs: 0, list: [] },
      playCounts: { atMs: NOW, counts: { sng_x1: 4 }, lastPlayedDays: { sng_x1: dayOf(NOW) } } },
    featureIndex(), { nowMs: NOW, limit: 20, playCountSeedLimit: 0 });
  const row = out.songs.find((s) => s.songId === 'sng_x1');
  assert.ok(row, 'the sparse row scored');
  assert.ok(row.reasons.includes('You played this recently'),
            `the recency reason surfaces: ${JSON.stringify(row.reasons)}`);
});

test('a recently played song can SEED For You with FEWER lifetime plays than one that cannot', () => {
  // Seeding used to sort by raw count alone, so songs untouched for a decade always won the
  // shortlist and a song played three times last week could never seed. The shortlist now ranks
  // by the COMBINED signal, so either axis can qualify a song.
  //
  // Note sng_e6 has FEWER plays than sng_j2 (3 vs 6) — it seeds purely on being played
  // yesterday, and sng_j2, untouched for a decade, does not.
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] },
                  playCounts: { atMs: NOW, counts: { sng_j1: 500, sng_j2: 6, sng_e6: 3 },
                                lastPlayedDays: {
                                  sng_j1: dayOf(NOW) - 3650, sng_j2: dayOf(NOW) - 3650,
                                  sng_e6: dayOf(NOW) - 1,
                                } } };
  const out = scoreForYou(state, featureIndex(), { nowMs: NOW, limit: 20, playCountSeedLimit: 2 });
  assert.ok(out.seeds.includes('sng_e6'),
            `the 3-play song played yesterday seeded: ${JSON.stringify(out.seeds)}`);
  assert.ok(!out.seeds.includes('sng_j2'),
            'the 6-play song untouched for a decade did not displace it');
});

test('recency raises the score inside /recs/similar too', () => {
  const plain = scoreSimilarToCollections(similarState(), featureIndex(), ['pkt_target'], { nowMs: NOW });
  const fresh = scoreSimilarToCollections(
    similarState({ overrides: { playCounts: {
      atMs: NOW, counts: { sng_e6: 5 }, lastPlayedDays: { sng_e6: dayOf(NOW) },
    } } }),
    featureIndex(), ['pkt_target'], { nowMs: NOW });
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;
  // The lift must be strictly larger than the play-count term alone would give: the two terms
  // are additive, not alternatives.
  const stale = scoreSimilarToCollections(
    similarState({ overrides: { playCounts: { atMs: NOW, counts: { sng_e6: 5 } } } }),
    featureIndex(), ['pkt_target'], { nowMs: NOW });
  assert.ok(scoreOf(stale, 'sng_e6') > scoreOf(plain, 'sng_e6'), 'plays alone lift it');
  assert.ok(scoreOf(fresh, 'sng_e6') > scoreOf(stale, 'sng_e6'), 'recency lifts it further');
});

test('lastPlayedDays are bounded by the SAME truncation as the counts', () => {
  // The dates map would otherwise be unbounded: a real library carries 56k dates against a 20k
  // count cap. A date whose songId did not survive describes a row nothing else stores.
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  const counts = {}; const lastPlayedDays = {};
  for (let i = 0; i < 25_000; i++) {
    counts[`sng_${i}`] = i + 1;                 // sng_0 is the LEAST played ⇒ truncated away
    lastPlayedDays[`sng_${i}`] = dayOf(NOW) - 1;
  }
  lastPlayedDays.sng_ghost = dayOf(NOW);        // a date with no count at all
  mergeBatch(state, { playCounts: { atMs: 10, counts, lastPlayedDays } });

  const kept = state.playCounts.counts;
  const dates = state.playCounts.lastPlayedDays;
  assert.equal(Object.keys(dates).length, Object.keys(kept).length,
               'exactly one date per surviving count');
  assert.ok(!('sng_ghost' in dates), 'a date with no surviving count is dropped');
  for (const id of Object.keys(dates)) assert.ok(id in kept, `${id} has a count`);
});

test('lastPlayedDays reject junk and are replaced WHOLESALE with the snapshot', () => {
  const state = { v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  mergeBatch(state, { playCounts: { atMs: 10, counts: { sng_a: 3, sng_b: 2, sng_c: 1 },
                                    lastPlayedDays: { sng_a: 20_000, sng_b: -5, sng_c: 'friday' } } });
  assert.deepEqual(state.playCounts.lastPlayedDays, { sng_a: 20_000 },
                   'only positive finite days survive');

  // A newer snapshot replaces both maps together — stale dates must not outlive their counts.
  mergeBatch(state, { playCounts: { atMs: 20, counts: { sng_a: 4 },
                                    lastPlayedDays: { sng_a: 20_100 } } });
  assert.deepEqual(state.playCounts.counts, { sng_a: 4 });
  assert.deepEqual(state.playCounts.lastPlayedDays, { sng_a: 20_100 });

  // A snapshot with NO dates clears them rather than carrying the old ones under new counts.
  mergeBatch(state, { playCounts: { atMs: 30, counts: { sng_a: 5 } } });
  assert.equal(state.playCounts.lastPlayedDays, undefined, 'dates do not outlive their snapshot');
});

test('lastPlayedDays ride a real /events flush end to end', async () => {
  const profile = 'profile-recency-001';
  const r = await call('POST', '/events', {
    profile,
    body: { v: 1, plays: [play('sng_e1', NOW - DAY)],
            playCounts: { atMs: NOW, counts: { sng_j1: 40, sng_j2: 40 },
                          lastPlayedDays: { sng_j1: dayOf(NOW) - 2000, sng_j2: dayOf(NOW) - 1 } } },
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted.playCounts, 2);

  const recs = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.equal(recs.status, 200);
  // Both counted songs seed (a 12-song fixture is far under the 50-seed cap), and `seeds` is
  // ordered by weight — so the fresher of two EQUALLY-played songs must come first. That is the
  // date surviving the wire, the clean, the store and the scorer.
  const rank = (id) => recs.json.seeds.indexOf(id);
  assert.ok(rank('sng_j2') >= 0 && rank('sng_j1') >= 0, 'both seeded');
  assert.ok(rank('sng_j2') < rank('sng_j1'),
            `equal counts, fresher date seeds higher: ${JSON.stringify(recs.json.seeds)}`);
});

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Explicit accept / reject — the recommendation tuning loop
//
// The failure mode these guard against is not "the endpoint 500s". It is a thumbs-down that is
// accepted, stored, echoed back in `totals` — and then quietly ignored by the ranking, so the
// rejected song keeps coming back and the user concludes the button does nothing.
// ════════════════════════════════════════════════════════════════════════════════════════════════

const fb = (songId, action, atMs = NOW) => ({ id: uid(), atMs, songId, action, surface: 'tile' });

test('feedback rows ingest, dedupe by id, and are reported in totals', async () => {
  const profile = 'profile-feedback-001';
  const row = fb('sng_e1', 'rejected');
  const r = await call('POST', '/events', { profile, body: { v: 1, feedback: [row] } });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted.feedback, 1);
  assert.equal(r.json.totals.feedback, 1);
  // The SAME row again is idempotent — the client re-sends its whole overlap window every flush.
  const again = await call('POST', '/events', { profile, body: { v: 1, feedback: [row] } });
  assert.equal(again.json.accepted.feedback, 0);
  assert.equal(again.json.totals.feedback, 1);
});

test('malformed feedback rows are dropped, not stored', () => {
  const state = { plays: [], favorites: {}, activity: [], puzzle: [], feedback: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  const { accepted } = mergeBatch(state, {
    feedback: [
      { id: 'a', atMs: 1, songId: 's1', action: 'rejected' },        // ok
      { id: 'b', atMs: 1, songId: 's1' },                             // no action
      { id: 'c', atMs: 1, songId: 's1', action: 'thumbs-sideways' },  // not a known action
      { id: 'd', atMs: 1, action: 'rejected' },                       // no songId
      { atMs: 1, songId: 's1', action: 'rejected' },                  // no id
    ],
  });
  assert.equal(accepted.feedback, 1);
  assert.deepEqual(state.feedback.map((e) => e.id), ['a']);
});

test('a state object written BEFORE feedback existed still merges', () => {
  // The upgrade path: `state.feedback` is simply absent. Reading it must not throw, and the new
  // stream must land — otherwise the first flush after an app update wedges the profile.
  const state = { plays: [], favorites: {}, activity: [], puzzle: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  const { accepted } = mergeBatch(state, { feedback: [{ id: 'a', atMs: 1, songId: 's1', action: 'accepted' }] });
  assert.equal(accepted.feedback, 1);
  assert.equal(state.feedback.length, 1);
});

test('feedbackOf folds last-writer-wins per song, and cleared undoes', () => {
  const features = new Map([['s1', { i: 's1', a: 'Aria', g: 'electronic' }]]);
  const one = feedbackOf({ feedback: [
    { id: '1', atMs: 10, songId: 's1', action: 'rejected' },
  ] }, features);
  assert.ok(one.rejected.has('s1'));

  const flipped = feedbackOf({ feedback: [
    { id: '1', atMs: 10, songId: 's1', action: 'rejected' },
    { id: '2', atMs: 20, songId: 's1', action: 'accepted' },
  ] }, features);
  assert.ok(!flipped.rejected.has('s1'), 'the later accept wins');
  assert.ok(flipped.accepted.has('s1'));

  const cleared = feedbackOf({ feedback: [
    { id: '1', atMs: 10, songId: 's1', action: 'rejected' },
    { id: '2', atMs: 20, songId: 's1', action: 'cleared' },
  ] }, features);
  assert.ok(!cleared.rejected.has('s1'), 'an undo really undoes');
  assert.ok(!cleared.accepted.has('s1'));

  // Out-of-order arrival (a peer device's rows merged behind the cursor) must not win.
  const outOfOrder = feedbackOf({ feedback: [
    { id: '2', atMs: 20, songId: 's1', action: 'accepted' },
    { id: '1', atMs: 10, songId: 's1', action: 'rejected' },
  ] }, features);
  assert.ok(outOfOrder.accepted.has('s1'), 'the NEWER row wins regardless of ingest order');
});

test('the artist/genre penalty SATURATES rather than max-normalising', () => {
  const features = new Map([
    ['s1', { i: 's1', a: 'Aria', g: 'electronic' }],
    ['s2', { i: 's2', a: 'Aria', g: 'electronic' }],
    ['s3', { i: 's3', a: 'Mira', g: 'electronic' }],
  ]);
  // THE REGRESSION THIS PINS: with max-normalisation a single rejection made its genre the
  // maximum and therefore full-strength, so one thumbs-down cut every song in that genre by the
  // full penalty. On this library that is a third of the catalog, from one tap.
  const one = feedbackOf({ feedback: [fb('s1', 'rejected', 1)] }, features);
  assert.equal(one.rejectedGenres.get('electronic'), 1 / 8, 'one reject barely moves a genre');
  assert.ok(feedbackMultiplier(one, 'Mira', 'electronic') > 0.9,
            'an unrelated artist in the same genre is nudged, not demoted');

  const three = feedbackOf({ feedback: [
    fb('s1', 'rejected', 1), fb('s2', 'rejected', 2), fb('s3', 'rejected', 3),
  ] }, features);
  assert.equal(three.rejectedArtists.get('Aria'), 2 / 3, 'two of three rejects were Aria');
  assert.equal(three.rejectedArtists.get('Mira'), 1 / 3);
  assert.equal(three.rejectedGenres.get('electronic'), 3 / 8, 'but not yet a genre');
  // The artist penalty must be DISTINGUISHABLE from the genre one, or the finer signal is dead.
  assert.ok(feedbackMultiplier(three, 'Aria', 'electronic')
            < feedbackMultiplier(three, 'Mira', 'electronic'));
  // Bounded and never negative, however hard the user leans on the button.
  const worst = feedbackMultiplier(three, 'Aria', 'electronic');
  assert.ok(worst > 0 && worst < 1, `bounded demotion, got ${worst}`);
  assert.equal(feedbackMultiplier(three, 'Nobody', 'jazz'), 1,
               'untouched neighbourhoods are untouched');
});

test('a rejected song is NEVER recommended again', async () => {
  const profile = 'profile-feedback-reject';
  await call('POST', '/events', { profile, body: { v: 1, plays: [play('sng_e1', NOW - HOUR * 80)] } });
  const before = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  const victim = before.json.songs[0]?.songId;
  assert.ok(victim, 'the fixture recommends something to reject');

  await call('POST', '/events', { profile, body: { v: 1, feedback: [fb(victim, 'rejected')] } });
  const after = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.ok(!after.json.songs.some((s) => s.songId === victim),
            `${victim} came back after a thumbs-down`);

  // …and clearing the decision brings it back, so the undo is real end to end.
  await call('POST', '/events', { profile, body: { v: 1, feedback: [fb(victim, 'cleared', NOW + 1000)] } });
  const restored = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.ok(restored.json.songs.some((s) => s.songId === victim), 'cleared restores the song');
});

test('a rejection demotes the ARTIST, not just the one song', async () => {
  const profile = 'profile-feedback-artist';
  // Seed on jazz so both Aria tracks are candidates rather than seeds.
  await call('POST', '/events', { profile, body: { v: 1, plays: [play('sng_j1', NOW - HOUR * 80)] } });
  await call('POST', '/events', {
    profile,
    body: { v: 1, feedback: [fb('sng_e1', 'rejected'), fb('sng_e2', 'rejected')] },
  });
  const r = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  const rank = (id) => {
    const i = r.json.songs.findIndex((s) => s.songId === id);
    return i < 0 ? Infinity : i;
  };
  // Both rejected Aria tracks are gone outright, and the surviving Aria track (same artist, never
  // individually rejected) must rank below a comparable track by an artist with no rejections.
  assert.equal(rank('sng_e1'), Infinity);
  assert.equal(rank('sng_e2'), Infinity);
  // sng_e3 is Aria's surviving track; sng_e6 is a comparable electronic track by an artist with
  // no rejections. Both take the same (small) genre penalty, so the ONLY thing that can separate
  // them is the artist term — which is exactly what this asserts. Before the rebalance sng_e3
  // outranked sng_e6 on raw similarity.
  assert.ok(rank('sng_e3') > rank('sng_e6'),
            `the rejected artist's other track should sink: ${JSON.stringify(r.json.songs.map((s) => s.songId))}`);
});

test('an accepted song seeds the profile even with no plays at all', async () => {
  const profile = 'profile-feedback-accept';
  // NO plays, NO play counts — only a thumbs-up. A tuning loop that needs listening history first
  // is useless on the surface it lives on.
  const r = await call('POST', '/events', { profile, body: { v: 1, feedback: [fb('sng_j1', 'accepted')] } });
  assert.equal(r.status, 200);
  const recs = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.ok(recs.json.seeds.includes('sng_j1'), 'the accepted song shapes the taste profile');
  assert.ok(recs.json.songs.some((s) => s.songId === 'sng_j2'),
            'and its neighbours are recommended');
});

test('a reject beats a favorite and a play count — the explicit instruction wins', async () => {
  const profile = 'profile-feedback-override';
  await call('POST', '/events', {
    profile,
    body: {
      v: 1,
      plays: [play('sng_e1', NOW - DAY)],
      favorites: [{ songId: 'sng_j1', favorited: true, atMs: NOW - DAY }],
      playCounts: { atMs: NOW, counts: { sng_j1: 500 } },
      feedback: [fb('sng_j1', 'rejected')],
    },
  });
  const recs = await call('GET', '/recs/songs', { profile, qs: { limit: '20' } });
  assert.ok(!recs.json.seeds.includes('sng_j1'),
            'a rejected song must not seed, however favourited or played');
  assert.ok(!recs.json.songs.some((s) => s.songId === 'sng_j1'));
});

test('rejected songs are excluded from /recs/similar too', async () => {
  const profile = 'profile-feedback-similar';
  await call('POST', '/events', {
    profile,
    body: { v: 1, collectionsSnapshot: { atMs: NOW, collections: [
      { id: 'pkt_1', kind: 'pocket', name: 'Crate', songIds: ['sng_e1', 'sng_e2'] },
    ] } },
  });
  const before = await call('GET', '/recs/similar', { profile, qs: { collectionIds: 'pkt_1' } });
  const victim = before.json.songs[0]?.songId;
  assert.ok(victim, 'the fixture returns similar songs');
  await call('POST', '/events', { profile, body: { v: 1, feedback: [fb(victim, 'rejected')] } });
  const after = await call('GET', '/recs/similar', { profile, qs: { collectionIds: 'pkt_1' } });
  assert.ok(!after.json.songs.some((s) => s.songId === victim),
            'a thumbs-down holds on every surface that could offer the song back');
});

test('feedback counts toward the batch cap and is capped in the store', async () => {
  const profile = 'profile-feedback-caps';
  const tooMany = Array.from({ length: 2001 }, (_, i) => fb(`sng_${i}`, 'rejected', NOW + i));
  const r = await call('POST', '/events', { profile, body: { v: 1, feedback: tooMany } });
  assert.equal(r.status, 400);
  assert.equal(r.json.error, 'batch-too-large');

  // The per-stream cap drops the OLDEST rows, like every other stream.
  const state = { plays: [], favorites: {}, activity: [], puzzle: [], feedback: [],
                  collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} } };
  for (let batch = 0; batch < 3; batch++) {
    mergeBatch(state, {
      feedback: Array.from({ length: 1500 }, (_, i) => ({
        id: `f_${batch}_${i}`, atMs: batch * 10000 + i, songId: `s${i}`, action: 'rejected',
      })),
    });
  }
  assert.equal(state.feedback.length, 3000, 'held at CAPS.feedback');
  assert.ok(state.feedback.every((e) => !e.id.startsWith('f_0_')),
            'the oldest batch is what was shed');
});

test('shedToFit drops feedback only after plays, activity and puzzle', () => {
  const big = CTRL.repeat(200);
  const state = {
    plays: [{ id: 'p1', songId: `s${big}`, atMs: 1 }],
    activity: [{ id: 'a1', atMs: 1, kind: 'add', itemId: `i${big}` }],
    puzzle: [{ id: 'z1', atMs: 1, action: `x${big}` }],
    feedback: [{ id: 'f1', atMs: 1, songId: `s${big}`, action: 'rejected' }],
    favorites: {}, collections: { atMs: 0, list: [] }, playCounts: { atMs: 0, counts: {} },
  };
  // A budget that forces exactly three drops: plays, activity, puzzle — feedback survives.
  shedToFit(state, 1400);
  assert.equal(state.feedback.length, 1, 'the deliberate signal outlives the incidental ones');
});
