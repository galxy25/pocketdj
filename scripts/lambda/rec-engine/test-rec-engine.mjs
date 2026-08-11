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
        feedbackOf, feedbackMultiplier, identityKeys,
        primaryArtistKey, artistKey, artistFamiliarityOf, auxMix, mergeAudioFeatures,
        eraWindow, eraFit,
        timbreDistance, timbreProfile, timbreFit, timbreNetFit, timbreAdjectives } =
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

// ── "Already in that collection" — BY IDENTITY, not by string ───────────────────────────────────
//
// The owner's rule is that a suggestion tile never offers back a song the collection already has.
// A membership test on raw ids gets that wrong for the two id forms one recording can also wear:
// the `_clean`/`_explicit` variant and the `amrec_<storeId>` ad-hoc capture. The device filters
// too (it can also join through the catalog's `appleMusicId`, which this route has no access to) —
// this is the half the server can decide from the id string alone, so the answer does not come
// back full of rows the client is about to throw away.

test('identityKeys folds variants and ad-hoc captures onto one recording', () => {
  assert.deepEqual(identityKeys('sng_e1'), ['sng_e1'], 'a plain id is its own identity');
  assert.deepEqual(identityKeys('sng_0123456789ab_clean'), ['sng_0123456789ab']);
  assert.deepEqual(identityKeys('sng_0123456789ab_explicit'), ['sng_0123456789ab']);
  assert.deepEqual(identityKeys('amrec_944459436'), ['amrec_944459436', 'am:944459436']);
  // A placeholder store id must NOT become a shared key — that would fold unrelated songs into
  // one identity and silently delete real suggestions.
  assert.deepEqual(identityKeys('amrec_0000'), ['amrec_0000']);
  assert.deepEqual(identityKeys('amrec_12'), ['amrec_12']);
  assert.deepEqual(identityKeys('amrec_nope'), ['amrec_nope']);
  assert.deepEqual(identityKeys(''), []);
});

/// An index with REAL-SHAPED ids — the shared fixture uses short readable ones, and the
/// `sng_<12 hex>_clean` variant convention deliberately does not match those. Three distinct
/// artists so the max-2-per-artist diversity cap cannot be what trims the answer.
///
/// `sng_anchor…` is the crate's RESOLVABLE member (it builds the taste profile), `sng_0123…` is
/// the twin the crate holds under another id, `sng_free…` is the genuine candidate.
const identityIndex = () => new Map([
  ['sng_0123456789ab', { i: 'sng_0123456789ab', al: 'alb_i1', a: 'Twinner', n: 'Twin',
                         g: 'electronic', y: 2020, b: 120, c: '8A' }],
  ['sng_aaaaaaaaaaaa', { i: 'sng_aaaaaaaaaaaa', al: 'alb_i2', a: 'Anchor', n: 'Anchor',
                         g: 'electronic', y: 2020, b: 121, c: '8A' }],
  ['sng_ffffffffffff', { i: 'sng_ffffffffffff', al: 'alb_i3', a: 'Freeman', n: 'Free',
                         g: 'electronic', y: 2020, b: 122, c: '8A' }],
]);
const identityState = (songIds) => ({
  v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
  collections: { atMs: 0, list: [{ id: 'pkt_i', kind: 'pocket', name: 'Crate', songIds }] },
});

test('scoreSimilarToCollections excludes the BASE of a variant member', () => {
  const state = identityState(['sng_aaaaaaaaaaaa', 'sng_0123456789ab_clean']);
  const ids = scoreSimilarToCollections(state, identityIndex(), ['pkt_i'], { nowMs: NOW })
    .songs.map((s) => s.songId);
  assert.ok(!ids.includes('sng_0123456789ab'), 'the clean rip in the crate IS this recording');
  assert.deepEqual(ids, ['sng_ffffffffffff'], 'and the genuinely-absent song keeps its slot');
});

test('scoreSimilarToCollections excludes a variant of a plain member', () => {
  const withVariant = new Map(identityIndex());
  withVariant.set('sng_aaaaaaaaaaaa_explicit',
                  { ...withVariant.get('sng_aaaaaaaaaaaa'), i: 'sng_aaaaaaaaaaaa_explicit' });
  const ids = scoreSimilarToCollections(identityState(['sng_aaaaaaaaaaaa']), withVariant,
                                        ['pkt_i'], { nowMs: NOW }).songs.map((s) => s.songId);
  assert.ok(!ids.includes('sng_aaaaaaaaaaaa_explicit'), 'the sibling edition is the same song');
  assert.deepEqual(ids.sort(), ['sng_0123456789ab', 'sng_ffffffffffff']);
});

test('scoreCollections never offers a collection the song is already in, under any id', () => {
  // The crate resolves through `sng_aaaa…` (so it genuinely scores) and ALSO holds `sng_0123…`
  // as its clean variant — so "add it to this crate" is a suggestion to do what is already done.
  const already = scoreCollections(identityState(['sng_aaaaaaaaaaaa', 'sng_0123456789ab_clean']),
                                   identityIndex(), 'sng_0123456789ab',
                                   { nowMs: NOW, threshold: 0 });
  assert.deepEqual(already.suggestions.map((s) => s.id), []);
  // Control: the same crate WITHOUT that song does suggest it, so the exclusion is what moved.
  const offered = scoreCollections(identityState(['sng_aaaaaaaaaaaa']), identityIndex(),
                                   'sng_0123456789ab', { nowMs: NOW, threshold: 0 });
  assert.deepEqual(offered.suggestions.map((s) => s.id), ['pkt_i']);
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
  // The collection member is the JAZZ song on purpose: an era-matching member (sng_e2, 2020,
  // window 2018–2022 around sng_e3's 2021) saturates the era term at 0.5 — tying the puzzle term
  // and, being pushed first, displacing it from the top-3 reasons this test reads.
  const state = {
    v: 1, plays: [], favorites: {}, activity: [],
    puzzle: [{ id: 'p1', atMs: NOW, songId: 'sng_e1', collectionId: 'pls_x', action: 'added' }],
    collections: { atMs: 0, list: [{ id: 'pls_x', kind: 'playlist', name: 'X', songIds: ['sng_j1'] }] },
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
  // TAIL — where a real 56k-row baseline leaves ~55,800 songs.
  //
  // ── WHY THIS ISOLATES BY SWAPPING RATHER THAN BY ADDING ─────────────────────────────────────
  // Since the novelty rebalance, giving a song plays does TWO things: it raises that song's own
  // play component AND it makes its ARTIST more familiar, which lowers the artist-novelty term
  // that now carries three quarters of the aux mix. Simply adding plays therefore measures the
  // sum of both, and on a one-song-per-artist fixture the artist effect wins — which is the
  // engine working as designed, not a regression.
  //
  // So the two states move the SAME 200 plays between Mira's two songs. Her artist total is 200
  // either way, which pins the novelty term exactly, and the only thing left moving is sng_e4's
  // own count. That is a strictly cleaner isolation than the version this replaces.
  const opts = { nowMs: NOW, limit: 20, playCountSeedLimit: 1 };
  const state = (counts) => ({ v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {},
                               activity: [], puzzle: [], collections: { atMs: 0, list: [] },
                               playCounts: { atMs: NOW, counts } });
  const base = state({ sng_e1: 500 });
  const before = scoreForYou(base, featureIndex(), opts);
  const scoreOf = (out, id) => out.songs.find((s) => s.songId === id)?.score ?? 0;

  const e4Carries = scoreForYou(state({ sng_e1: 500, sng_e4: 200 }), featureIndex(), opts);
  const e5Carries = scoreForYou(state({ sng_e1: 500, sng_e5: 200 }), featureIndex(), opts);
  assert.deepEqual(e4Carries.seeds, e5Carries.seeds,
                   'the seed set — and so the taste profile — is identical');
  assert.ok(scoreOf(e4Carries, 'sng_e4') > scoreOf(e5Carries, 'sng_e4'),
            'same artist familiarity, more of its own plays ⇒ lifetime plays lift the score');
  assert.ok(scoreOf(e5Carries, 'sng_e5') > scoreOf(e4Carries, 'sng_e5'),
            '…and symmetrically for the sibling, so this is the axis and not the fixture');

  const loved = { ...base,
                  playCounts: { atMs: NOW, counts: { sng_e1: 500, sng_e4: 200, sng_x1: 200 } } };
  const after = scoreForYou(loved, featureIndex(), opts);

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

  // ── HOW THIS ISOLATES, AND WHY IT NO LONGER COMPARES TWO SONGS INSIDE ONE RUN ──────────────
  // Both axes are read by SWAPPING the input between two runs and comparing ONE song to ITSELF.
  // The previous version compared sng_j1 against sng_j2 in a single run on the grounds that they
  // share an artist, album, genre and year — but they differ in bpm, key and mood keywords, so
  // that was never quite "everything else equal". It passed only because the additive play term
  // (0.75, larger than the whole artist term) was big enough to swamp the metadata difference.
  // That domination is exactly what the owner reported, so a test resting on it would now be
  // pinning the bug rather than the axis.
  //
  // The pair is Mira's two songs, which sit inside the seed's genre and so carry a similarity
  // large enough for a 0…1 aux component to move the score by more than the output's 2-decimal
  // rounding. On the jazz pair the same true difference is ~0.007 and rounds away — the axis is
  // still there, it is simply below the resolution of the number the API returns.
  //
  // Mira's ARTIST total is identical across each pair of runs, which pins the novelty term and
  // leaves exactly one thing moving.

  // AXIS 1 — the same song, the same count, the only change being its own date.
  const e4Old = run({ sng_e4: 20, sng_e5: 20 },
                    { sng_e4: dayOf(NOW) - 1825, sng_e5: dayOf(NOW) - 1 });
  const e4New = run({ sng_e4: 20, sng_e5: 20 },
                    { sng_e4: dayOf(NOW) - 1, sng_e5: dayOf(NOW) - 1825 });
  assert.ok(scoreOf(e4New, 'sng_e4') > scoreOf(e4Old, 'sng_e4'),
            'equal plays, fresher date ⇒ ranks higher');

  // AXIS 2 — the same song, the same date, the only change being its own count. The order must
  // flip back, which is what proves recency did not simply replace the play count.
  const sameDay = { sng_e4: dayOf(NOW) - 400, sng_e5: dayOf(NOW) - 400 };
  const heavyE4 = run({ sng_e4: 200, sng_e5: 2 }, sameDay);
  const heavyE5 = run({ sng_e4: 2, sng_e5: 200 }, sameDay);
  assert.ok(scoreOf(heavyE4, 'sng_e4') > scoreOf(heavyE5, 'sng_e4'),
            'equal dates, more plays ⇒ ranks higher');
  assert.ok(scoreOf(heavyE5, 'sng_e5') > scoreOf(heavyE4, 'sng_e5'),
            '…and symmetrically, so the ordering is the axis and not the pair');
  const plays = heavyE4;

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

// ════════════════════════════════════════════════════════════════════════════════════════════════
// THE NOVELTY REBALANCE — the owner's report: "it is biasing too much on play count so each tile
// is recommending multiple Drake songs … value novelty over similarity … so that thumbs up and
// thumbs down build a second reliable signal source apart from pure play count."
//
// The tests below are the claims that rebalance has to be able to make: the cap cannot be walked
// around, novelty can actually beat familiarity, novelty CANNOT beat similarity, the 47.8% of a
// real library with no play data is neither buried nor promoted wholesale, and Gem Collector's
// shipped ranking is untouched.
// ════════════════════════════════════════════════════════════════════════════════════════════════

test('the per-artist cap keys on the PRIMARY artist, so a collaboration cannot claim a second budget', () => {
  assert.equal(primaryArtistKey('Drake'), 'drake');
  assert.equal(primaryArtistKey('Drake & Future'), 'drake');
  assert.equal(primaryArtistKey('Drake feat. Future'), 'drake');
  assert.equal(primaryArtistKey('Drake ft Lil Wayne'), 'drake');
  assert.equal(primaryArtistKey('Drake, Future'), 'drake');
  assert.equal(primaryArtistKey('Drake x Future'), 'drake');
  assert.equal(primaryArtistKey('Drake / Future'), 'drake');
  assert.equal(primaryArtistKey('DJ Khaled Featuring Drake'), 'dj khaled');
  assert.equal(primaryArtistKey('Nick Cave with Kylie Minogue'), 'nick cave');
  assert.equal(primaryArtistKey('Blur vs. Oasis'), 'blur');

  // NOT separators: a comma inside a NAME, and a word that merely CONTAINS a separator.
  assert.equal(primaryArtistKey('Tyler, The Creator'), 'tyler, the creator',
               'a list item never begins with "the" — this is one artist');
  assert.equal(primaryArtistKey('Xavier Rudd'), 'xavier rudd', '"x" needs its own word boundary');
  assert.equal(primaryArtistKey('Fetty Wap'), 'fetty wap', '"with" must not match mid-word');
  assert.equal(primaryArtistKey('Withered Hand'), 'withered hand');

  // Agrees with the device's artist normalizer on the trivial cases (case, diacritics, "The ").
  assert.equal(primaryArtistKey('The Beatles'), artistKey('The Beatles'));
  assert.equal(primaryArtistKey('BEYONCÉ'), 'beyonce');
});

test('the cap holds under adversarial input: one artist owning the entire top of the ranking', () => {
  // Every row in this catalog is the SAME artist wearing a different credit string — the shape
  // that defeated the shipped cap, since "Drake & Future" was a different key from "Drake".
  const credits = ['Drake', 'Drake & Future', 'Drake feat. 21 Savage', 'Drake, Rihanna',
                   'Drake x Lil Baby', 'Drake ft. Travis Scott', 'Drake / Partynextdoor',
                   'Drake with Sampha', 'DRAKE', 'Drake feat. Nobody'];
  const rows = credits.map((a, i) => ({
    i: `adv_${i}`, al: `alb_adv_${i}`, a, n: `Track ${i}`, g: 'electronic', y: 2020,
    b: 120, c: '8A', s: ['dark', 'moody'],
  }));
  // Plus the seed, which is a different artist so the profile has something to be built from.
  rows.push({ i: 'adv_seed', al: 'alb_seed', a: 'Aria', n: 'Seed', g: 'electronic', y: 2020,
              b: 120, c: '8A', s: ['dark', 'moody'] });
  const featuresById = new Map(rows.map((r) => [r.i, r]));

  const out = scoreForYou({
    v: 1, plays: [play('adv_seed', NOW - 2 * DAY)], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
    // He has played this artist into the ground — the exact input that produced the report.
    playCounts: { atMs: NOW, counts: Object.fromEntries(credits.map((_, i) => [`adv_${i}`, 500])) },
  }, featuresById, { nowMs: NOW, limit: 50, playCountSeedLimit: 0 });

  assert.ok(out.songs.length > 0, 'the ranking is not empty');
  assert.ok(out.songs.every((s) => primaryArtistKey(s.artist) === 'drake'),
            'this fixture has only one real artist besides the seed');
  assert.equal(out.songs.length, 2,
               'one artist gets at most 2 rows however many credit strings they wear '
               + `(got ${JSON.stringify(out.songs.map((s) => s.artist))})`);
});

test('a never-played song can outrank a heavily-played one when similarity is comparable', () => {
  // Two songs identical on every SIMILARITY field — same genre, year, bpm, key, mood — differing
  // only in artist and in play history. This is the head-to-head the owner's instruction is about.
  const rows = [
    { i: 'nv_seed', al: 'alb_s', a: 'Aria', n: 'Seed', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'nv_known', al: 'alb_k', a: 'Worn Out', n: 'Played To Death', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'nv_new', al: 'alb_n', a: 'Never Heard', n: 'Untouched', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
  ];
  const featuresById = new Map(rows.map((r) => [r.i, r]));
  const out = scoreForYou({
    v: 1, plays: [play('nv_seed', NOW - 2 * DAY)], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
    playCounts: { atMs: NOW, counts: { nv_known: 400 } },
  }, featuresById, { nowMs: NOW, limit: 20, playCountSeedLimit: 0 });

  const ids = out.songs.map((s) => s.songId);
  assert.ok(ids.indexOf('nv_new') < ids.indexOf('nv_known'),
            `the unknown artist leads when similarity is equal (got ${JSON.stringify(ids)})`);
  // …and the row SAYS so, which is what makes a 👍 on it a verdict the engine can read back.
  const row = out.songs.find((s) => s.songId === 'nv_new');
  assert.ok(row.reasons.some((r) => r.startsWith("An artist you've never played")),
            `the novelty reason is user-visible: ${JSON.stringify(row.reasons)}`);
});

test('novelty CANNOT outrank a genuinely more similar song — the bound is 1.40x, not a hope', () => {
  // `b_far` is brand new but in the WRONG genre, wrong era, wrong key, wrong tempo. Novelty is
  // maxed for it and near zero for the well-matched, heavily-played row. If novelty were ADDED
  // rather than applied as a bounded multiplier, an unrelated song could float to the top of the
  // tile — which is worse than a familiar suggestion, and is the failure this shape rules out.
  const rows = [
    { i: 'b_seed', al: 'alb_s', a: 'Aria', n: 'Seed', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'b_near', al: 'alb_k', a: 'Worn Out', n: 'Great Fit', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'b_far', al: 'alb_n', a: 'Never Heard', n: 'Wrong Everything', g: 'polka', y: 1932, b: 200, c: '2B', s: ['jolly'] },
  ];
  const featuresById = new Map(rows.map((r) => [r.i, r]));
  const out = scoreForYou({
    v: 1, plays: [play('b_seed', NOW - 2 * DAY)], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] },
    playCounts: { atMs: NOW, counts: { b_near: 500 } },
  }, featuresById, { nowMs: NOW, limit: 20, playCountSeedLimit: 0 });

  const ids = out.songs.map((s) => s.songId);
  assert.ok(ids.indexOf('b_near') === 0,
            `similarity still decides the tier (got ${JSON.stringify(ids)})`);
  // The bound stated as arithmetic, so it is checked rather than asserted by comment: the best a
  // maximally-novel row can do is 1.40x its own similarity.
  const near = out.songs.find((s) => s.songId === 'b_near');
  const far = out.songs.find((s) => s.songId === 'b_far');
  if (far) assert.ok(far.score <= near.score * 1.4001, 'no row escapes the aux band');
});

test('a profile with NO play data at all is scored on similarity alone, not shifted wholesale', () => {
  // The renormalization rule. 47.8% of the owner's real catalog has no play data; a novelty term
  // that scored those rows 1.0 by default would promote half the library for a missing field, and
  // one that scored them 0 would bury it. With NO counts anywhere the axis is dead and drops out
  // of the denominator entirely — the ranking is exactly what it was before novelty existed.
  const featuresById = featureIndex();
  const base = { v: 1, plays: [play('sng_e1', NOW - 5 * DAY)], favorites: {}, activity: [],
                 puzzle: [], collections: { atMs: 0, list: [] } };
  const noCounts = scoreForYou({ ...base, playCounts: { atMs: NOW, counts: {} } },
                               featuresById, { nowMs: NOW, limit: 20 });
  const noSnapshot = scoreForYou(base, featuresById, { nowMs: NOW, limit: 20 });
  assert.deepEqual(noCounts.songs, noSnapshot.songs,
                   'an absent snapshot and an empty one rank identically');
  // Every score is the bare similarity sum — no multiplier was applied at all.
  assert.ok(noCounts.songs.every((s) => s.reasons.every((r) => !r.startsWith('An artist you'))),
            'a dead axis says nothing rather than saying everything');
});

test('artist novelty is an ARTIST aggregate, so a never-played song is not automatically novel', () => {
  // The property that keeps the term from collapsing back into "1 - play count": a deep cut by an
  // artist he wears out is FAMILIAR even though that particular song has never been played, and a
  // heavily-played track by an artist he otherwise ignores is not novel. Measured on the real
  // catalog the two distributions overlap heavily (never-played rows mean 0.679, played 0.523)
  // rather than partitioning, which is what stops the 47.8% moving as a block.
  const rows = [
    { i: 'ag_a1', a: 'Huge', g: 'electronic' }, { i: 'ag_a2', a: 'Huge', g: 'electronic' },
    { i: 'ag_b1', a: 'Ignored', g: 'electronic' },
  ];
  const featuresById = new Map(rows.map((r) => [r.i, r]));
  // ag_a1 carries all of Huge's plays; ag_a2 has never been played at all.
  const fam = artistFamiliarityOf(featuresById, { ag_a1: 500, ag_b1: 1 });
  assert.ok(fam.live);
  assert.ok(fam.novelty('huge') < 0.05, 'the artist is known, so the unplayed deep cut is not novel');
  assert.ok(fam.novelty('ignored') > 0.85, 'one play does not make an artist familiar');
  assert.equal(fam.novelty('huge'), fam.novelty(primaryArtistKey('Huge')),
               "both of Huge's songs — played and unplayed — get the SAME novelty");
  assert.ok(fam.isUnknown('nobody at all'), 'an artist with no plays is the strongest case');

  // And with nothing to measure from, the axis reports dead rather than reporting 1.0 for all.
  const dead = artistFamiliarityOf(featuresById, {});
  assert.equal(dead.live, false);
  assert.equal(dead.novelty('huge'), 0);
  assert.equal(auxMix({ novelty: 1, plays: 0, recency: 0,
                        hasNovelty: false, hasPlays: false, hasRecency: false }), 0,
               'no live signal ⇒ aux 0 ⇒ the multiplier is exactly 1');
});

test('Gem Collector (/recs/similar) is NOT rebalanced — familiarity still leads there', () => {
  // The constraint: the puzzle's shipped ranking must not move. `/recs/similar` keeps play count
  // as an ADDITIVE term and has no novelty term at all, so between two equally-fitting cards the
  // one the player actually listens to is still the better card.
  const rows = [
    { i: 'gc_m1', al: 'alb_g', a: 'Aria', n: 'Member', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'gc_known', al: 'alb_k', a: 'Worn Out', n: 'Played', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    { i: 'gc_new', al: 'alb_n', a: 'Never Heard', n: 'Untouched', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] },
    // A sparse row (year only), where the genre/key/BPM terms that normally outrank a play signal
    // are absent — so the shipped play-count REASON is reachable and can be pinned verbatim.
    { i: 'gc_sparse', al: 'alb_sp', a: 'Sparse Guy', n: 'Bare', y: 2020 },
  ];
  const featuresById = new Map(rows.map((r) => [r.i, r]));
  const out = scoreSimilarToCollections({
    v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: NOW, list: [{ id: 'col_g', kind: 'playlist', name: 'Crate', songIds: ['gc_m1'] }] },
    playCounts: { atMs: NOW, counts: { gc_known: 400, gc_sparse: 400 } },
  }, featuresById, ['col_g'], { nowMs: NOW, limit: 20 });

  const ids = out.songs.map((s) => s.songId);
  assert.ok(ids.indexOf('gc_known') < ids.indexOf('gc_new'),
            `the played card still leads in the puzzle route (got ${JSON.stringify(ids)})`);
  const sparse = out.songs.find((s) => s.songId === 'gc_sparse');
  assert.ok(sparse.reasons.some((r) => r === "You've played this 400 times"),
            `and it still says so, in the shipped words: ${JSON.stringify(sparse.reasons)}`);
  assert.ok(out.songs.every((s) => s.reasons.every((r) => !r.startsWith('An artist you'))),
            'no novelty reason reaches the puzzle route at all');
});

test('on real-SHAPED input the tile stops being one artist and starts proposing unknowns', () => {
  // A synthetic library with the owner's shape: one artist owning a large slice of the catalog AND
  // essentially all of the plays (his real top artist is #1 by both — 449 songs and 2,796 plays),
  // against a long tail of artists he has never touched. Every row is equally similar, so the only
  // things deciding the list are the aux mix and the cap.
  const rows = [{ i: 'rs_seed', al: 'alb_s', a: 'Aria', n: 'Seed', g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] }];
  const counts = {};
  for (let i = 0; i < 40; i++) {
    rows.push({ i: `rs_dom_${i}`, al: `alb_d${i}`, a: i % 4 === 0 ? 'Dominant & Guest' : 'Dominant',
                n: `D${i}`, g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] });
    counts[`rs_dom_${i}`] = 300 - i;   // …and he has played every one of them
  }
  for (let i = 0; i < 40; i++) {
    rows.push({ i: `rs_tail_${i}`, al: `alb_t${i}`, a: `Tail ${i}`, n: `T${i}`,
                g: 'electronic', y: 2020, b: 120, c: '8A', s: ['dark'] });
  }
  const featuresById = new Map(rows.map((r) => [r.i, r]));
  const out = scoreForYou({
    v: 1, plays: [play('rs_seed', NOW - 2 * DAY)], favorites: {}, activity: [], puzzle: [],
    collections: { atMs: 0, list: [] }, playCounts: { atMs: NOW, counts },
  }, featuresById, { nowMs: NOW, limit: 25, playCountSeedLimit: 0 });

  const artists = out.songs.map((s) => primaryArtistKey(s.artist));
  const distinct = new Set(artists).size;
  const dominant = artists.filter((a) => a === 'dominant').length;
  // `<= 2` rather than `=== 2`: with every candidate EXACTLY as similar as every other, novelty is
  // the only thing left deciding and the unknown tail takes the whole tile. That is the extreme of
  // the calibration, not its typical behaviour — on the real catalog the never-played share lands
  // at 48.7% (against a 48.6% base rate) precisely because similarity does vary there.
  assert.ok(dominant <= 2, 'the dominant artist is held to the cap across ALL their credits '
                           + `(got ${dominant} of ${artists.length})`);
  assert.ok(distinct >= 20, `the tile is many artists, not one discography (got ${distinct})`);
  const neverPlayed = out.songs.filter((s) => s.songId.startsWith('rs_tail_')).length;
  assert.ok(neverPlayed >= out.songs.length / 2,
            'at equal similarity the never-played tail is what fills the tile — that is the '
            + `headroom a thumbs-up now carries information about (got ${neverPlayed}/${out.songs.length})`);
});

// ── TARGETED AUDIO ANALYSIS (F10) ───────────────────────────────────────────────────────────────
// The queue is what carries the device's shortlist to the nightly librosa job, and the feature
// store is where the vectors land. Both are new SURFACES on an object that is read-modify-written
// on every upload, so the tests here are mostly about what must NOT happen: no unbounded growth,
// no second copy of an id, no leftover corpus after a deletion, no open door without the secret.

const AUDIO_PROFILE = 'profile-audio-1234';
const audioHash = (p) => createHash('sha256').update(p).digest('hex');

test('audio queue: ids ride the /events flush and are a SET, not a log', async () => {
  const opts = { profile: AUDIO_PROFILE };
  const r1 = await call('POST', '/events', {
    ...opts, body: { audioQueue: { atMs: NOW, songIds: ['sng_e1', 'sng_e2'] } },
  });
  assert.equal(r1.status, 200);
  assert.equal(r1.json.accepted.audioQueue, 2);

  // Re-proposing the same ids is a NO-OP — the idempotence the whole refresh protocol rests on:
  // a client that lost its `pendingIds` (a reinstall, a restore) must not double-queue the night.
  const r2 = await call('POST', '/events', {
    ...opts, body: { audioQueue: { atMs: NOW + 1, songIds: ['sng_e1', 'sng_e2', 'sng_e3'] } },
  });
  assert.equal(r2.json.accepted.audioQueue, 1, 'only the genuinely new id counts');

  const state = JSON.parse(readFileSync(statePath(AUDIO_PROFILE), 'utf8'));
  assert.deepEqual(state.audioQueue, ['sng_e1', 'sng_e2', 'sng_e3']);
});

test('audio queue: the worker routes need the enrollment secret and nothing else', async () => {
  // No secret ⇒ 403, even holding a valid bearer key for a real profile.
  const bad = await handler({ rawPath: '/audio/queue', requestContext: { http: { method: 'GET' } },
                              headers: {} });
  assert.equal(bad.statusCode, 403);

  // …and WITH it, no profile header and no bearer key are needed: the worker is profile-blind and
  // gets back opaque hashes it relays verbatim.
  const ok = await handler({ rawPath: '/audio/queue', requestContext: { http: { method: 'GET' } },
                             headers: { 'x-pocketdj-enroll': ENROLL } });
  assert.equal(ok.statusCode, 200);
  const doc = JSON.parse(ok.body);
  const mine = doc.profiles.find((p) => p.p === audioHash(AUDIO_PROFILE));
  assert.ok(mine, 'the enrolled profile with a pending queue is listed');
  assert.deepEqual(mine.songIds, ['sng_e1', 'sng_e2', 'sng_e3']);
  assert.equal(doc.timbreVersion, 1, 'the worker is told which calibration this engine expects');
});

test('audio features: posting vectors stores them AND drains the queue', async () => {
  const post = (body) => handler({
    rawPath: '/audio/features', requestContext: { http: { method: 'POST' } },
    headers: { 'x-pocketdj-enroll': ENROLL }, body: JSON.stringify(body),
  });

  const r = await post({
    p: audioHash(AUDIO_PROFILE),
    features: [{ songId: 'sng_e1', v: 1, f: { bright: 0.4, punch: 0.9 } }],
    // Reported-but-unanalysable: no local audio and no way to get any. It MUST drain too, or it
    // sits at the head of the queue forever and every night retries it first.
    done: ['sng_e2'],
  });
  assert.equal(r.statusCode, 200);
  const ack = JSON.parse(r.body);
  assert.equal(ack.accepted, 1);
  assert.equal(ack.drained, 2, 'both the analysed id and the drained one leave the queue');

  const state = JSON.parse(readFileSync(statePath(AUDIO_PROFILE), 'utf8'));
  assert.deepEqual(state.audioQueue, ['sng_e3'], 'only the un-worked id is left for tomorrow');

  const corpus = JSON.parse(readFileSync(
    join(HOME, 'rec', 'audio', `${audioHash(AUDIO_PROFILE)}.json`), 'utf8'));
  assert.deepEqual(corpus.songs.sng_e1.f, { bright: 0.4, punch: 0.9 });

  // A re-analysis REPLACES rather than accumulating: one recording, one vector, whichever
  // calibration produced it last.
  await post({ p: audioHash(AUDIO_PROFILE),
               features: [{ songId: 'sng_e1', v: 2, f: { bright: 0.1 } }] });
  const again = JSON.parse(readFileSync(
    join(HOME, 'rec', 'audio', `${audioHash(AUDIO_PROFILE)}.json`), 'utf8'));
  assert.deepEqual(again.songs.sng_e1, { v: 2, f: { bright: 0.1 }, atMs: again.songs.sng_e1.atMs });
});

test('audio features: hostile shapes are dropped, not stored', async () => {
  const { doc } = mergeAudioFeatures(null, [
    { songId: 'ok', f: { bright: 0.5, 'Bad Key!': 1, huge: 99, neg: -3, nan: NaN } },
    { songId: 'nofeatures', f: {} },
    { songId: '', f: { bright: 1 } },
    { f: { bright: 1 } },
    'garbage',
  ]);
  assert.deepEqual(Object.keys(doc.songs), ['ok']);
  assert.deepEqual(doc.songs.ok.f, { bright: 0.5, huge: 1, neg: 0 },
                   'axis names are validated and values clamped to 0…1');
});

test('audio queue: bounded, oldest evicted', async () => {
  const state = { plays: [], favorites: {}, activity: [], puzzle: [], feedback: [], audioQueue: [] };
  mergeBatch(state, { audioQueue: { songIds: Array.from({ length: 500 }, (_, i) => `q${i}`) } });
  assert.equal(state.audioQueue.length, 400);
  assert.equal(state.audioQueue[0], 'q100', 'the OLDEST requests are the ones shed');
});

test('audio features: DELETE /state removes the corpus too', async () => {
  const corpusPath = join(HOME, 'rec', 'audio', `${audioHash(AUDIO_PROFILE)}.json`);
  assert.ok(existsSync(corpusPath));
  const r = await call('DELETE', '/state', { profile: AUDIO_PROFILE });
  assert.equal(r.status, 200);
  assert.ok(!existsSync(corpusPath),
            '"Delete cloud data" has to mean all of it — a per-profile corpus derived from '
            + 'listening cannot survive the deletion of the state it was derived from');
});

// ── THE ERA WINDOW (owner: "also factor in year range for recommendation along with genre as a
//    feature, eg some playlist like 808 & swinging is very new jack swing 88-94 r&b") ────────────
//
// The pocket histograms below are REAL DATA, not invented: the member years of the owner's actual
// pockets (source-backup.pocketdj, 2026-08-11) joined against public/rec-features.json, whose
// year field is song year with album-year fallback (106,879 of 107,757 rows dated = 99.2%).

const yearsOf = (hist) => Object.entries(hist).flatMap(([y, k]) => Array(k).fill(Number(y)));

/// "808 and Swinging" — 87 members, 86 dated. The owner remembers this pocket as ≈1988–1994 new
/// jack swing. Its year data is verified correct song-by-song (Keith Sweat 1987 ✓, SWV 1992 ✓,
/// Kodak Black 2023 ✓), and the membership genuinely spans 1986–2025: a ~30-song 1986–1998
/// founding core, two whole 2001/2003 albums, and a modern R&B tail he added himself. So the
/// window is honestly WIDE — narrowing it to 88–94 would score the very songs he filed as
/// misfits. The new-jack-swing SOUND is the genre term's job; the era term reports the years the
/// crate actually holds.
const P808_AND_SWINGING = {
  1986: 1, 1987: 9, 1988: 2, 1989: 1, 1990: 2, 1992: 4, 1993: 1, 1994: 1, 1995: 2, 1996: 3,
  1997: 1, 1998: 1, 2000: 3, 2001: 12, 2003: 15, 2005: 2, 2007: 1, 2008: 2, 2011: 1, 2013: 1,
  2015: 2, 2016: 1, 2018: 2, 2019: 1, 2020: 1, 2021: 1, 2022: 2, 2023: 8, 2025: 3,
};
/// "Bad Bitch Radio" — 35 members, all dated 2015–2026: a tight, modern pocket.
const P_BAD_BITCH_RADIO = { 2015: 1, 2018: 3, 2019: 1, 2022: 2, 2023: 15, 2024: 1, 2025: 11, 2026: 1 };
/// "🏋🏾‍♀️" (workout) — 500 members, 486 dated, and one member tagged year **1012** — an obvious
/// tagging error, kept in the fixture on purpose: it is the real catalog's own argument for a
/// percentile window over min/max.
const P_WORKOUT = {
  1012: 1, 1967: 1, 1976: 2, 1977: 1, 1978: 1, 1980: 3, 1981: 3, 1982: 2, 1983: 3, 1984: 2,
  1986: 3, 1987: 1, 1989: 2, 1990: 3, 1991: 1, 1993: 2, 1996: 6, 1997: 1, 1998: 7, 1999: 5,
  2000: 5, 2001: 18, 2002: 7, 2003: 9, 2004: 11, 2005: 8, 2006: 18, 2007: 21, 2008: 27, 2009: 32,
  2010: 38, 2011: 41, 2012: 29, 2013: 28, 2014: 26, 2015: 26, 2016: 29, 2017: 22, 2018: 12,
  2019: 5, 2020: 2, 2021: 5, 2022: 1, 2023: 10, 2024: 2, 2025: 2, 2026: 2,
};

test('eraWindow: the real "808 and Swinging" pocket → 1987–2024 (wide, and honestly so)', () => {
  assert.deepEqual(eraWindow(yearsOf(P808_AND_SWINGING)), { lo: 1987, hi: 2024 });
});

test('eraWindow: real pockets with different eras get distinct windows', () => {
  const w808 = eraWindow(yearsOf(P808_AND_SWINGING));
  const wBbr = eraWindow(yearsOf(P_BAD_BITCH_RADIO));
  const wGym = eraWindow(yearsOf(P_WORKOUT));
  assert.deepEqual(wBbr, { lo: 2020, hi: 2027 }, 'modern pocket → tight modern window');
  assert.deepEqual(wGym, { lo: 1999, hi: 2018 }, '2000s–2010s pocket → 2000s–2010s window');
  const keys = new Set([w808, wBbr, wGym].map((w) => `${w.lo}:${w.hi}`));
  assert.equal(keys.size, 3, 'three pockets, three distinct eras');
});

test('eraWindow: the percentile shrugs off the year-1012 tagging error where min/max would not', () => {
  const ys = yearsOf(P_WORKOUT);
  assert.equal(Math.min(...ys), 1012, 'the outlier really is in the input');
  const w = eraWindow(ys);
  assert.equal(w.lo, 1999, 'a min/max window would start at 1010; the percentile ignores it');
});

test('eraWindow: undated → null, junk filtered, weights pull the window', () => {
  assert.equal(eraWindow([]), null);
  assert.equal(eraWindow([null, undefined, 0, -3, NaN]), null, 'no usable year ⇒ no window (fail open)');
  // Uniform weights are the device's unweighted nearest-rank exactly.
  const ys = yearsOf(P808_AND_SWINGING);
  assert.deepEqual(eraWindow(ys, ys.map(() => 1)), eraWindow(ys));
  // A heavily-weighted modern seed drags the window toward it; at uniform weight the same seed
  // is a p85 outlier and says nothing.
  const years = [1990, 1991, 1992, 1993, 1994, 1995, 2024];
  assert.deepEqual(eraWindow(years), { lo: 1989, hi: 1997 });
  assert.deepEqual(eraWindow(years, [1, 1, 1, 1, 1, 1, 10]), { lo: 1990, hi: 2026 });
});

test('eraFit: flat inside the window (an era is a RANGE), exponential decay outside', () => {
  const w = { lo: 1988, hi: 1994 };
  assert.equal(eraFit(1988, w), 1);
  assert.equal(eraFit(1991, w), 1, '1991 is not "more 88–94" than 1993');
  assert.equal(eraFit(1994, w), 1);
  assert.ok(Math.abs(eraFit(1996, w) - Math.exp(-2 / 4)) < 1e-12, '2y out keeps 61%');
  assert.ok(eraFit(2020, w) < 0.002, 'a 2020 track against an 88–94 window is buried on era');
  assert.equal(eraFit(null, w), 0);
  assert.equal(eraFit(1990, null), 0);
});

// ── Era as a SCORING feature (fail open, renormalized — never a hard filter) ────────────────────

/// One genre across the board so genre cannot separate the candidates — the era term has to do
/// the separating, or fail open trying. Seed years are the 808 pocket's real founding core.
const eraScoringFeatures = (opts = {}) => new Map([
  ['sng_s1', { i: 'sng_s1', a: 'Keith Sweat', n: 'I Want Her', g: 'soul', y: opts.undatedSeeds ? undefined : 1987 }],
  ['sng_s2', { i: 'sng_s2', a: 'Luther Vandross', n: 'Any Love', g: 'soul', y: opts.undatedSeeds ? undefined : 1988 }],
  ['sng_s3', { i: 'sng_s3', a: 'Tony! Toni! Toné!', n: 'Feels Good', g: 'soul', y: opts.undatedSeeds ? undefined : 1990 }],
  ['sng_s4', { i: 'sng_s4', a: 'SWV', n: 'Weak', g: 'soul', y: opts.undatedSeeds ? undefined : 1992 }],
  ['sng_s5', { i: 'sng_s5', a: 'Outkast', n: 'Southernplayalistic', g: 'soul', y: opts.undatedSeeds ? undefined : 1994 }],
  ['sng_in', { i: 'sng_in', a: 'Jodeci', n: 'Inside the Era', g: 'soul', y: 1992 }],
  ['sng_out', { i: 'sng_out', a: 'Talii', n: 'Far Outside', g: 'soul', y: 2022 }],
  ['sng_nd', { i: 'sng_nd', a: 'Zhané', n: 'Undated', g: 'soul' }],
]);

const eraSeedState = () => ({
  v: 1,
  plays: ['sng_s1', 'sng_s2', 'sng_s3', 'sng_s4', 'sng_s5'].map((id) => play(id, NOW - 5 * DAY)),
  favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] },
});

test('scoreForYou: same-genre candidate inside the seed era outranks one far outside', () => {
  // Seeds 1987–1994 → window 1985–1996. All three candidates are identical on genre.
  const out = scoreForYou(eraSeedState(), eraScoringFeatures(), { nowMs: NOW });
  const rank = out.songs.map((s) => s.songId);
  assert.ok(rank.indexOf('sng_in') < rank.indexOf('sng_out'),
            `inside-era must outrank far-outside, got ${JSON.stringify(rank)}`);
  const inside = out.songs.find((s) => s.songId === 'sng_in');
  assert.ok(inside.reasons.some((r) => r.includes('1985–1996 era')),
            `the era reason names the window: ${JSON.stringify(inside.reasons)}`);
});

test('scoreForYou: an undated candidate is NOT structurally buried (round-neutral imputation)', () => {
  const out = scoreForYou(eraSeedState(), eraScoringFeatures(), { nowMs: NOW });
  const rank = out.songs.map((s) => s.songId);
  // Fail open: the undated candidate scores the round neutral on the era term — comfortably
  // above a candidate 26 years outside the window, below one inside it. Zeroing it (the old
  // behavior) would have ranked it WITH the far-outside candidate for a missing tag.
  assert.ok(rank.indexOf('sng_nd') < rank.indexOf('sng_out'),
            `undated must not sink to the bottom: ${JSON.stringify(rank)}`);
  assert.ok(rank.indexOf('sng_in') < rank.indexOf('sng_nd'),
            'the neutral is a mean, not a reward — real fit still wins');
});

test('scoreForYou: no dated seed ⇒ the era term drops and its weight renormalizes (never a dead denominator)', () => {
  const out = scoreForYou(eraSeedState(), eraScoringFeatures({ undatedSeeds: true }), { nowMs: NOW });
  const inside = out.songs.find((s) => s.songId === 'sng_in');
  const outside = out.songs.find((s) => s.songId === 'sng_out');
  assert.ok(inside && outside, 'candidates still surface with the era term dead');
  assert.equal(inside.score, outside.score,
               'with no window, a year can neither help nor hurt');
  // genre 2.0 scaled by 7.75/7.25 — the dead term's weight redistributed over the live axes,
  // NOT silently vanished (the audio-term lesson: an unearnable term must leave the denominator).
  assert.equal(inside.score, Math.round(2.0 * (7.75 / 7.25) * 100) / 100);
  assert.ok(!inside.reasons.some((r) => r.includes('era')), 'no era reason without a window');
});

// ── scoreCollections: the era is the COLLECTION's, matched against the song ─────────────────────

const eraColState = () => ({
  v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
  collections: {
    atMs: 0,
    list: [
      { id: 'col_old', kind: 'pocket', name: 'NJS Core', songIds: ['sng_s1', 'sng_s2', 'sng_s3', 'sng_s4', 'sng_s5'] },
      { id: 'col_new', kind: 'pocket', name: 'Modern', songIds: ['sng_out'] },
      { id: 'col_und', kind: 'pocket', name: 'Undated', songIds: ['sng_nd'] },
    ],
  },
});

test('scoreCollections: the era-matching collection outranks the era-mismatched one', () => {
  const feats = eraScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Guy', n: 'Query 1991', g: 'soul', y: 1991 });
  const out = scoreCollections(eraColState(), feats, 'sng_q', { nowMs: NOW, threshold: 0 });
  const ids = out.suggestions.map((s) => s.id);
  assert.ok(ids.indexOf('col_old') < ids.indexOf('col_new'),
            `1991 belongs to the 1985–1996 crate, not the 2020–2024 one: ${JSON.stringify(ids)}`);
  const old = out.suggestions.find((s) => s.id === 'col_old');
  assert.ok(old.reasons.some((r) => r.includes('1985–1996 era')),
            `the reason names the crate's window: ${JSON.stringify(old.reasons)}`);
});

test('scoreCollections: an undated COLLECTION fails open — imputed at the round neutral, not zeroed', () => {
  const feats = eraScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Guy', n: 'Query 1991', g: 'soul', y: 1991 });
  const out = scoreCollections(eraColState(), feats, 'sng_q', { nowMs: NOW, threshold: 0 });
  const score = (id) => out.suggestions.find((s) => s.id === id).score;
  // The neutral is the mean of the song's fit across the dated crates (≈(1.0 + 0)/2), so the
  // undated crate lands BETWEEN the era-matching and era-mismatched ones — visible, unbiased.
  assert.ok(score('col_old') > score('col_und'), 'a real era match still beats the imputation');
  assert.ok(score('col_und') > score('col_new'), 'no member years ≠ buried');
});

test('scoreCollections: an undated SONG renormalizes the round instead of quietly raising the bar', () => {
  const feats = eraScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Guy', n: 'Query Undated', g: 'soul' });
  const out = scoreCollections(eraColState(), feats, 'sng_q', { nowMs: NOW });
  // The default threshold (0.8) still passes on genre alone: the era term's 0.5 redistributes
  // (×7.5/7.0) rather than sitting unearnable in front of a fixed bar.
  const ids = out.suggestions.map((s) => s.id);
  assert.ok(ids.includes('col_old') && ids.includes('col_new') && ids.includes('col_und'),
            `an undated song still gets collection suggestions: ${JSON.stringify(out.suggestions)}`);
  const scores = new Set(out.suggestions.map((s) => s.score));
  assert.equal(scores.size, 1, 'with no era anywhere, the genre-identical crates tie exactly');
});

// ── TIMBRE (audio-similarity v2): the sound of a crate / seed set as a ranking signal ───────────
//
// One genre and one year across every fixture row, deliberately: genre and era cannot separate
// the candidates, so the timbre term has to do the separating — or fail open trying. Sound A is
// "punchy, busy, dark" (the new-jack shape F10's axes were picked for); the mismatched sound
// flips every axis.

const TAXES = ['bright', 'brightVar', 'air', 'width', 'noisy', 'fizz', 'punch', 'busy',
               'dynamic', 'loud', 'm1', 'm2', 'm3', 'm4'];
/// All 14 axes at `base`, with named overrides, then `shift` added everywhere (clamped 0…1).
const tvec = (base, overrides = {}, shift = 0) => Object.fromEntries(TAXES.map((k) => {
  const v = (overrides[k] ?? base) + shift;
  return [k, Math.min(1, Math.max(0, Math.round(v * 10000) / 10000))];
}));
const SOUND_A = { punch: 0.9, busy: 0.8 };            // over base 0.2 → punchy/busy/dark/quiet…
const soundA = (shift = 0) => tvec(0.2, SOUND_A, shift);
const soundAFlipped = (shift = 0) => tvec(0.8, { punch: 0.1, busy: 0.2 }, shift);

const timbreScoringFeatures = (opts = {}) => new Map([
  // Five seeds, sound A ±0.01 — a tight, live profile (spread ≈ 0.01). `unanalysedSeeds`
  // strips their vectors to drive the term-drop round.
  ...['s1', 's2', 's3', 's4', 's5'].map((n, i) => [`sng_t${n}`, {
    i: `sng_t${n}`, a: `Seed ${n}`, n: `Seed ${n}`, g: 'soul', y: 1990,
    ...(opts.unanalysedSeeds ? {} : { t: soundA((i - 2) * 0.005) }),
  }]),
  ['sng_tzz_in', { i: 'sng_tzz_in', a: 'Guy', n: 'Sounds Like The Zone', g: 'soul', y: 1990, t: soundA(0.004) }],
  ['sng_taa_out', { i: 'sng_taa_out', a: 'Sade', n: 'Sounds Nothing Like It', g: 'soul', y: 1990, t: soundAFlipped() }],
  // Two more of the flipped sound so `col_off` below is a TIGHT crate of it — a crate of mixed
  // opposite sounds has an honestly huge spread and accepts everything, which is the
  // self-regulating behavior, not a test of discrimination.
  ['sng_tout2', { i: 'sng_tout2', a: 'Ambre', n: 'Flipped Two', g: 'soul', y: 1990, t: soundAFlipped(0.01) }],
  ['sng_tout3', { i: 'sng_tout3', a: 'Cleo', n: 'Flipped Three', g: 'soul', y: 1990, t: soundAFlipped(-0.01) }],
  ['sng_tnv', { i: 'sng_tnv', a: 'Zhané', n: 'Never Analysed', g: 'soul', y: 1990 }],
  // The rejected-sound trio: `sng_trej` is the 👎'd song; `sng_tb` sounds exactly like it,
  // `sng_tc` sits the SAME distance from the seed centroid in the opposite direction.
  ['sng_trej', { i: 'sng_trej', a: 'Reject', n: 'Thumbed Down', g: 'soul', y: 1990, t: soundA(0.06) }],
  ['sng_tb', { i: 'sng_tb', a: 'NearRej', n: 'Near The Rejected Sound', g: 'soul', y: 1990, t: soundA(0.06) }],
  ['sng_tc', { i: 'sng_tc', a: 'FarRej', n: 'Same Fit, Other Direction', g: 'soul', y: 1990, t: soundA(-0.06) }],
]);

const timbreSeedState = (extra = {}) => ({
  v: 1,
  plays: ['sng_ts1', 'sng_ts2', 'sng_ts3', 'sng_ts4', 'sng_ts5'].map((id) => play(id, NOW - 5 * DAY)),
  favorites: {}, activity: [], puzzle: [], collections: { atMs: 0, list: [] },
  ...extra,
});

test('timbreDistance: RMS over shared axes, null under the 8-axis bar', () => {
  const a = soundA();
  assert.equal(timbreDistance(a, a), 0);
  // One axis moved by 0.14 → RMS = sqrt(0.14² / 14).
  const b = { ...a, punch: a.punch - 0.14 };
  assert.ok(Math.abs(timbreDistance(a, b) - Math.sqrt(0.14 ** 2 / 14)) < 1e-12);
  // A 6-axis fragment is not comparable — half a vector is a different instrument.
  const sparse = Object.fromEntries(TAXES.slice(0, 6).map((k) => [k, 0.5]));
  assert.equal(timbreDistance(a, sparse), null);
  assert.equal(timbreDistance(null, a), null);
});

test('timbreProfile: the liveness bar is 3 vectors (1 for the negative), spread is the members\' own', () => {
  assert.equal(timbreProfile([{ f: soundA(), w: 1 }, { f: soundA(0.1), w: 1 }]), null,
               'a centroid of two songs is those two songs, not a sound');
  const neg = timbreProfile([{ f: soundA(), w: 1 }], 1);
  assert.ok(neg, 'one 👎 is already a sound to drift from');
  assert.equal(neg.spread, 0);
  const p = timbreProfile([{ f: soundA(0.01), w: 1 }, { f: soundA(-0.01), w: 1 }, { f: soundA(), w: 1 }]);
  assert.ok(p);
  assert.equal(p.vectors, 3);
  assert.ok(p.spread > 0 && p.spread < 0.02, `spread is the mean member distance, got ${p.spread}`);
});

test('timbreFit: saturates inside the profile\'s own spread (a sound is a REGION), decays outside', () => {
  const p = timbreProfile([{ f: soundA(0.01), w: 1 }, { f: soundA(-0.01), w: 1 }, { f: soundA(), w: 1 }]);
  assert.equal(timbreFit(soundA(), p), 1, 'the centroid itself');
  assert.equal(timbreFit(soundA(0.005), p), 1, 'inside the spread is not "less the sound"');
  const far = timbreFit(soundAFlipped(), p);
  assert.ok(far < 0.01, `the flipped sound is buried on timbre (${far}) — and still free to win on genre/artist`);
  const mid = timbreFit(soundA(0.06), p);
  assert.ok(mid > 0.2 && mid < 0.6, `a nearby sound keeps a graded share, got ${mid}`);
});

test('timbreAdjectives: named axes only, ≥0.15 off the middle, strongest first', () => {
  assert.deepEqual(timbreAdjectives({ punch: 0.9, bright: 0.2, m1: 0.99, brightVar: 0.99 }),
                   ['punchy', 'dark'],
                   'm1/brightVar never speak — a why-string must not say things the owner cannot hear');
  assert.deepEqual(timbreAdjectives({ punch: 0.64, bright: 0.36 }), [],
                   'inside the threshold nothing is claimed');
  assert.deepEqual(timbreAdjectives(timbreProfile([{ f: soundA(), w: 1 }], 1).centroid),
                   ['punchy', 'busy', 'clean'],
                   'ties break on the word so the sentence is deterministic');
});

test('scoreForYou: the candidate that SOUNDS like the seeds outranks the same-genre one that does not', () => {
  const out = scoreForYou(timbreSeedState(), timbreScoringFeatures(), { nowMs: NOW });
  const rank = out.songs.map((s) => s.songId);
  assert.ok(rank.indexOf('sng_tzz_in') < rank.indexOf('sng_taa_out'),
            `same genre, same year — the sound is the only separator: ${JSON.stringify(rank)}`);
  const tin = out.songs.find((s) => s.songId === 'sng_tzz_in');
  assert.ok(tin.reasons.some((r) => r.startsWith('Sounds like your recent plays:')),
            `the timbre reason names the sound: ${JSON.stringify(tin.reasons)}`);
  const tout = out.songs.find((s) => s.songId === 'sng_taa_out');
  assert.ok(!tout.reasons.some((r) => r.startsWith('Sounds like')),
            'a mismatched sound must not carry the reason');
});

test('scoreForYou: an UNANALYSED candidate is NOT structurally buried (round-neutral multiplier)', () => {
  const out = scoreForYou(timbreSeedState(), timbreScoringFeatures(), { nowMs: NOW });
  const rank = out.songs.map((s) => s.songId);
  // Fail open: the vectorless candidate rides the round-neutral multiplier — above the analysed
  // candidate whose sound genuinely mismatches, below the one that genuinely fits. Zeroing it
  // would have ranked 86% of the catalog below every analysed row, which is the incomparability
  // that deferred this term at 1.75% coverage.
  assert.ok(rank.indexOf('sng_tnv') < rank.indexOf('sng_taa_out'),
            `no vector must not sink below a bad fit: ${JSON.stringify(rank)}`);
  assert.ok(rank.indexOf('sng_tzz_in') < rank.indexOf('sng_tnv'),
            'the neutral is a mean, not a reward — a real fit still wins');
  assert.ok(!out.songs.find((s) => s.songId === 'sng_tnv').reasons.some((r) => r.startsWith('Sounds like')),
            'an imputed fit never claims a sound nothing measured');
});

test('scoreForYou: fewer than 3 analysed seeds ⇒ the timbre term drops for the round (ranking-neutral)', () => {
  const withT = scoreForYou(timbreSeedState(), timbreScoringFeatures({ unanalysedSeeds: true }), { nowMs: NOW });
  const stripped = new Map([...timbreScoringFeatures({ unanalysedSeeds: true })]
    .map(([id, row]) => { const { t, ...rest } = row; return [id, rest]; }));
  const noT = scoreForYou(timbreSeedState(), stripped, { nowMs: NOW });
  assert.deepEqual(withT.songs.map((s) => [s.songId, s.score]),
                   noT.songs.map((s) => [s.songId, s.score]),
                   'an unearnable term leaves the round entirely — candidate vectors alone change nothing');
});

test('scoreForYou: a 👎 on an analysed song pushes its SOUND away, not just its artist', () => {
  const feats = timbreScoringFeatures();
  const state = timbreSeedState({
    feedback: [{ id: 'fb1', atMs: NOW - DAY, songId: 'sng_trej', action: 'rejected' }],
  });
  const out = scoreForYou(state, feats, { nowMs: NOW });
  const rank = out.songs.map((s) => s.songId);
  assert.ok(!rank.includes('sng_trej'), 'the rejected song itself is excluded outright');
  // sng_tb and sng_tc sit at the SAME distance from the seed centroid (equal positive fit, same
  // genre/year, both artists unknown to the profile) — only the rejected sound tells them apart.
  assert.ok(rank.indexOf('sng_tc') < rank.indexOf('sng_tb'),
            `the candidate that sounds like the 👎 must drop below its twin: ${JSON.stringify(rank)}`);
  const clean = scoreForYou(timbreSeedState(), feats, { nowMs: NOW });
  const scoreOf = (res, id) => res.songs.find((s) => s.songId === id)?.score;
  assert.equal(scoreOf(clean, 'sng_tb'), scoreOf(clean, 'sng_tc'),
               'without the verdict the twins tie exactly — the drop is the 👎 and nothing else');
});

// ── scoreCollections: the sound is the COLLECTION's, matched against the song ──────────────────

const timbreColState = () => ({
  v: 1, plays: [], favorites: {}, activity: [], puzzle: [],
  collections: {
    atMs: 0,
    list: [
      { id: 'col_snd', kind: 'pocket', name: 'Sound A', songIds: ['sng_ts1', 'sng_ts2', 'sng_ts3', 'sng_ts4', 'sng_ts5'] },
      { id: 'col_off', kind: 'pocket', name: 'Other Sound', songIds: ['sng_taa_out', 'sng_tout2', 'sng_tout3'] },
      { id: 'col_unk', kind: 'pocket', name: 'Unanalysed Crate', songIds: ['sng_tnv'] },
    ],
  },
});

test('scoreCollections: the crate that shares the song\'s SOUND outranks the one that does not', () => {
  const feats = timbreScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Query', n: 'Query', g: 'soul', y: 1990, t: soundA(0.004) });
  const out = scoreCollections(timbreColState(), feats, 'sng_q', { nowMs: NOW, threshold: 0 });
  const score = (id) => out.suggestions.find((s) => s.id === id)?.score;
  assert.ok(score('col_snd') > score('col_off'),
            `sound A belongs in the sound-A crate: ${JSON.stringify(out.suggestions)}`);
  const snd = out.suggestions.find((s) => s.id === 'col_snd');
  assert.ok(snd.reasons.some((r) => r.startsWith('Sounds like this crate:')),
            `the reason names the crate's sound: ${JSON.stringify(snd.reasons)}`);
});

test('scoreCollections: a crate whose MEMBERS are unanalysed fails open at the round neutral', () => {
  const feats = timbreScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Query', n: 'Query', g: 'soul', y: 1990, t: soundA(0.004) });
  const out = scoreCollections(timbreColState(), feats, 'sng_q', { nowMs: NOW, threshold: 0 });
  const score = (id) => out.suggestions.find((s) => s.id === id)?.score;
  // The neutral is the mean of the song's fit across the PROFILED crates (≈(1+0)/2), so the
  // unanalysed crate lands between the matching and mismatched ones — visible, unbiased.
  assert.ok(score('col_snd') > score('col_unk'), 'a real sound match still beats the imputation');
  assert.ok(score('col_unk') > score('col_off'), 'unanalysed members ≠ a buried crate');
});

test('scoreCollections: an unanalysed SONG renormalizes the round instead of quietly raising the bar', () => {
  const feats = timbreScoringFeatures();
  feats.set('sng_q', { i: 'sng_q', a: 'Query', n: 'Query No Vector', g: 'soul', y: 1990 });
  const out = scoreCollections(timbreColState(), feats, 'sng_q', { nowMs: NOW });
  // Default threshold (0.8): the dead term's 0.5 redistributes (×8.0/7.5 here — era stays live)
  // rather than sitting unearnable in front of a fixed bar.
  const ids = out.suggestions.map((s) => s.id);
  assert.ok(ids.includes('col_snd') && ids.includes('col_off') && ids.includes('col_unk'),
            `an unanalysed song still gets collection suggestions: ${JSON.stringify(out.suggestions)}`);
  const scores = new Set(out.suggestions.map((s) => s.score));
  assert.equal(scores.size, 1, 'with no vector on the song, the sound-distinct crates tie exactly');
});

// ── The cloud/device parity fixture — one law, two implementations ──────────────────────────────

test('timbre parity fixture: the Lambda reproduces every value the device is held to', async () => {
  const { fileURLToPath } = await import('node:url');
  const { dirname } = await import('node:path');
  const fx = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)),
                                          '..', '..', '..', 'apple', 'Tests', 'Fixtures',
                                          'timbre-parity.json'), 'utf8'));
  assert.ok(fx.distances.length >= 50 && fx.profiles.length >= 20, 'the fixture is not a stub');
  for (const c of fx.distances) {
    const d = timbreDistance(c.a, c.b);
    if (c.d == null) assert.equal(d, null);
    else assert.ok(Math.abs(d - c.d) < 1e-12, `distance drift: ${d} vs ${c.d}`);
  }
  for (const c of fx.profiles) {
    const p = timbreProfile(c.members, c.minVectors);
    if (!c.profile) { assert.equal(p, null); continue; }
    assert.equal(p.vectors, c.profile.vectors);
    assert.ok(Math.abs(p.spread - c.profile.spread) < 1e-12);
    for (const [k, v] of Object.entries(c.profile.centroid)) {
      assert.ok(Math.abs(p.centroid[k] - v) < 1e-12, `centroid drift on ${k}`);
    }
    const f = timbreFit(c.probe, p);
    if (c.fit == null) assert.equal(f, null);
    else assert.ok(Math.abs(f - c.fit) < 1e-12, `fit drift: ${f} vs ${c.fit}`);
    if (c.negative?.profile && c.netFit != null) {
      const nf = timbreNetFit(c.probe, p, timbreProfile(c.negative.members, 1));
      assert.ok(Math.abs(nf - c.netFit) < 1e-12, `net-fit drift: ${nf} vs ${c.netFit}`);
    }
    assert.deepEqual(timbreAdjectives(p.centroid), c.adjectives);
  }
  for (const c of fx.adjectiveCases) assert.deepEqual(timbreAdjectives(c.centroid), c.words);
});
