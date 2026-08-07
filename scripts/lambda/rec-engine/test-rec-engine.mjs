// Test suite for scripts/lambda/rec-engine/index.mjs. NO spawning (unlike the jukebox smoke
// suite): the module is imported directly and driven with synthetic API-Gateway v2 events, with
// REC_LOCAL_DIR pointing the state store at a temp dir (zero AWS) and REC_FEATURES_FILE at a
// small fixture (two genres, bpm spread, camelot pairs, two artists sharing an album).
//
//   node --test scripts/lambda/rec-engine/test-rec-engine.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
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

const { handler, camelotNeighbors, mergeBatch, scoreForYou, scoreCollections } =
  await import('./index.mjs');

const PROFILE = 'profile-test-1234';
const KEY = 'a'.repeat(64);
const OTHER_KEY = 'b'.repeat(64);
const NOW = Date.now();
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

function ev(method, path, { profile = PROFILE, key = KEY, body, qs } = {}) {
  const headers = {};
  if (profile !== null) headers['x-pocketdj-profile'] = profile;
  if (key !== null) headers.authorization = `Bearer ${key}`;
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
