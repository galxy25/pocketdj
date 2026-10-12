// Test suite for the LISTENING POCKETS Lambda (scripts/lambda/listening-pockets/). Zero AWS: the
// store points at a temp dir (POCKETS_LOCAL_DIR), features at a small fixture
// (POCKETS_FEATURES_FILE), and uploads compute inline (POCKETS_INLINE_COMPUTE=1). The handler is
// driven with synthetic API-Gateway v2 events, the pure modules directly.
//
//   node --test scripts/lambda/listening-pockets/test-listening-pockets.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const HOME = mkdtempSync(join(tmpdir(), 'listening-pockets-test-'));
const FEATURES = join(HOME, 'features.json');

// ── A small catalog: a house cluster at 118–124 BPM walking neighbouring Camelot keys (six
//    different artists), hip-hop around 90, jazz spread wide, rock fast, a 60-BPM ballad, and
//    songs with no features at all. ─────────────────────────────────────────────────────────────
const catalog = {
  v: 1, songs: [
    { i: 'sng_e00000000001', a: 'Aria', g: 'electronic', y: 2020, b: 118, c: '8A', s: ['driving'], t: { loud: 0.7, punch: 0.7 } },
    { i: 'sng_e00000000002', a: 'Mira', g: 'electronic', y: 2021, b: 119, c: '9A', s: ['driving'], t: { loud: 0.7, punch: 0.72 } },
    { i: 'sng_e00000000003', a: 'Vex', g: 'electronic', y: 2019, b: 120, c: '9B', s: ['euphoric'], t: { loud: 0.68, punch: 0.7 } },
    { i: 'sng_e00000000004', a: 'Halden', g: 'electronic', y: 2022, b: 122, c: '10B', s: ['driving'], t: { loud: 0.72, punch: 0.7 } },
    { i: 'sng_e00000000005', a: 'Okto', g: 'electronic', y: 2020, b: 123, c: '10A', s: ['warm'], t: { loud: 0.7, punch: 0.69 } },
    { i: 'sng_e00000000006', a: 'Saffi', g: 'electronic', y: 2023, b: 124, c: '11A', s: ['driving'], t: { loud: 0.71, punch: 0.7 } },
    { i: 'sng_h00000000001', a: 'Rook', g: 'hip-hop', y: 1998, b: 86, c: '3A', s: ['gritty'], t: { loud: 0.5, punch: 0.4 } },
    { i: 'sng_h00000000002', a: 'Rook', g: 'hip-hop', y: 2004, b: 92, c: '7B', s: ['dark'], t: { loud: 0.45, punch: 0.5 } },
    { i: 'sng_h00000000003', a: 'Tamsin', g: 'hip-hop', y: 2012, b: 95, c: '12A', s: ['gritty'], t: { loud: 0.4, punch: 0.45 } },
    { i: 'sng_h00000000004', a: 'Tamsin', g: 'hip-hop', y: 2016, b: 88, c: '5A', s: ['dark'], t: { loud: 0.48, punch: 0.42 } },
    { i: 'sng_j00000000001', a: 'Bento', g: 'jazz', y: 1962, b: 90, c: '3A', s: ['smooth'], t: { loud: 0.1, punch: 0.2 } },
    { i: 'sng_j00000000002', a: 'Bento', g: 'jazz', y: 1965, b: 140, c: '1B', s: ['smooth'], t: { loud: 0.15, punch: 0.1 } },
    { i: 'sng_j00000000003', a: 'Nell', g: 'jazz', y: 1970, b: 104, c: '6A', s: ['mellow'], t: { loud: 0.12, punch: 0.18 } },
    { i: 'sng_r00000000001', a: 'Glass', g: 'rock', y: 1985, b: 150, c: '6B' },
    { i: 'sng_r00000000002', a: 'Glass', g: 'rock', y: 1990, b: 144, c: '11B' },
    { i: 'sng_b00000000060', a: 'Slow', g: 'soul', y: 1995, b: 60, c: '4B' },
    { i: 'sng_am0000000001', a: 'Captured', g: 'electronic', y: 2021, b: 121, c: '8B', am: '1771724281' },
  ],
};
writeFileSync(FEATURES, JSON.stringify(catalog));

process.env.POCKETS_LOCAL_DIR = HOME;
process.env.POCKETS_FEATURES_FILE = FEATURES;
process.env.POCKETS_INLINE_COMPUTE = '1';
process.env.REC_ENROLL_SECRET = 'enroll-secret-for-tests';
process.env.MAX_PROFILES = '1000';

const { POCKET_PARAMS } = await import('./params.mjs');
const { normalizeEvents, sessionize, detectPockets, detect, pocketIdFor } = await import('./detect.mjs');
const { computeResults, foldBpm, localTimeOf, titleFor, camelotNeighbors, emptyResults } = await import('./analyze.mjs');
const { indexFeatures, resolveSong, identityKeys } = await import('./features.mjs');
const { cleanEvent, mergeEvents, freshEventsDoc, cleanCtx } = await import('./store.mjs');
const { handler, normalizePath, _test } = await import('./index.mjs');
const { historyToUploadEvents, toUpload, buildEventsDoc } = await import('./run-local.mjs');

const FEATS = indexFeatures(catalog);
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const INSTALL = '6F1C2D3E-0000-4000-8000-00000000AAAA';
const IPAD = '0D9E8F7A-1111-4000-8000-00000000BBBB';
const E = (n) => `sng_e0000000000${n}`;
const H = (n) => `sng_h0000000000${n}`;
const J = (n) => `sng_j0000000000${n}`;
const PLACE_A = 'plc_0f1e2d3c4b5a6978';
const PLACE_B = 'plc_8899aabbccddeeff';
const PLACE_X = 'plc_1234567890abcdef';
const TRIP_AB = 'trp_3c9a0b1d2e4f5a6b';
const TRIP_BA = 'trp_b6a5f4e2d1b0a9c3';
const ctxAB = { kind: 'trip', tripId: TRIP_AB, origin: PLACE_A, destination: PLACE_B };
const ctxBA = { kind: 'trip', tripId: TRIP_BA, origin: PLACE_B, destination: PLACE_A };

let counter = 0;
const uid = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, '0')}`;

/// A stored-shape row (what cleanEvent produces) — for the pure-module tests.
function row(songId, atMs, { outcome = 'completed', source = 'mix', ctx = null, tz = 0, install = INSTALL, id, ord = 0 } = {}) {
  return { id: id || uid(), songId, atMs, ord, installId: install, tzOffsetMin: tz, source, outcome,
    fraction: outcome === 'completed' ? 0.95 : outcome === 'skipped' ? 0.1 : null, artist: null, carPlay: null, ctx };
}

/// "PPSP|PPP" → rows four minutes apart; `|` inserts a 45-minute gap (a new session).
function seq(pattern, startMs, { songs = [E(1), E(2), E(3), E(4), E(5), E(6)], stepMs = 4 * MIN, ...opts } = {}) {
  const out = []; let t = startMs; let i = 0;
  for (const ch of pattern) {
    if (ch === '|') { t += 45 * MIN; continue; }
    const outcome = ch === 'S' ? 'skipped' : ch === 'U' ? 'unknown' : ch === 'Q' ? 'partial' : 'completed';
    out.push(row(songs[i++ % songs.length], t, { ...opts, outcome }));
    t += stepMs;
  }
  return out;
}
const pocketsOf = (rows, params = POCKET_PARAMS) => detect(rows, { params }).pockets;
const T0 = Date.UTC(2026, 9, 5, 14, 0);   // Mon 5 Oct 2026 14:00 UTC

// ── §6.3 detection ──────────────────────────────────────────────────────────────────────────────

test('PPP → one pocket of 3', () => {
  const p = pocketsOf(seq('PPP', T0));
  assert.equal(p.length, 1);
  assert.equal(p[0].members.length, 3);
  assert.equal(p[0].skippedCount, 0);
  assert.equal(p[0].sessionPlays, 3);
});

test('PPSPP → no pocket (no run of three)', () => {
  assert.equal(pocketsOf(seq('PPSPP', T0)).length, 0);
});

test('PPPSPSP → one pocket of 5 (7-play session, 2 skipped, skips excluded but do not end it)', () => {
  const rows = seq('PPPSPSP', T0);
  const p = pocketsOf(rows);
  assert.equal(p.length, 1);
  assert.equal(p[0].members.length, 5);
  assert.equal(p[0].skippedCount, 2);
  assert.equal(p[0].sessionPlays, 7);
  assert.ok(p[0].members.every((m) => m.outcome !== 'skipped'), 'members are only the plays');
});

test('PPPSSPPP → two pockets of 3 (two skips in a row end it; a new run reopens)', () => {
  const p = pocketsOf(seq('PPPSSPPP', T0));
  assert.deepEqual(p.map((x) => x.members.length), [3, 3]);
  assert.deepEqual(p.map((x) => x.skippedCount), [0, 0], 'the ending skips belong to neither pocket');
});

test('PPPSSPP → one pocket of 3', () => {
  assert.deepEqual(pocketsOf(seq('PPPSSPP', T0)).map((x) => x.members.length), [3]);
});

test('PPP|PP → one pocket of 3 (the gap ends it)', () => {
  const p = pocketsOf(seq('PPP|PP', T0));
  assert.deepEqual(p.map((x) => x.members.length), [3]);
  assert.equal(p[0].sessionPlays, 3);
});

test('PP|PPP → one pocket of 3, in the second session', () => {
  const rows = seq('PP|PPP', T0);
  const p = pocketsOf(rows);
  assert.equal(p.length, 1);
  assert.equal(p[0].members[0].id, rows[2].id);
  assert.equal(p[0].sessionIndex, 1);
});

test('trailing skips at session end are not counted in the pocket', () => {
  const p = pocketsOf(seq('PPPPS', T0));
  assert.equal(p[0].members.length, 4);
  assert.equal(p[0].skippedCount, 0);
  assert.equal(p[0].sessionPlays, 5);
});

test('a gap of EXACTLY 30 minutes is the same session; one ms more splits', () => {
  const a = [row(E(1), T0), row(E(2), T0 + 30 * MIN), row(E(3), T0 + 60 * MIN)];
  assert.equal(sessionize(normalizeEvents(a)).length, 1);
  assert.equal(pocketsOf(a).length, 1);
  const b = [row(E(1), T0), row(E(2), T0 + 30 * MIN + 1), row(E(3), T0 + 60 * MIN + 1)];
  assert.equal(sessionize(normalizeEvents(b)).length, 2);
  assert.equal(pocketsOf(b).length, 0);
});

test('two installs interleaved in time are independent streams', () => {
  // Phone: P P P, iPad: S P S — interleaved minute by minute. Merged into one timeline the
  // iPad's skips would break the phone's run; as separate streams the phone has its pocket.
  const rows = [];
  for (let i = 0; i < 3; i++) {
    rows.push(row(E(i + 1), T0 + i * 4 * MIN, { install: INSTALL }));
    rows.push(row(H(i + 1), T0 + i * 4 * MIN + MIN, { install: IPAD, outcome: i === 1 ? 'completed' : 'skipped' }));
  }
  const p = pocketsOf(rows);
  assert.equal(p.length, 1);
  assert.equal(p[0].stream, INSTALL);
  assert.equal(p[0].members.length, 3);
  // …and the iPad alone at PPP makes a second, separate pocket.
  const more = rows.concat([1, 2, 3].map((k) => row(J(k), T0 + HOUR * 3 + k * 4 * MIN, { install: IPAD })));
  assert.deepEqual(pocketsOf(more).map((x) => x.stream).sort(), [IPAD, INSTALL].sort());
});

test("'unknown' counts as a play by default and as a skip with unknownIsPlay: false", () => {
  assert.equal(pocketsOf(seq('PUP', T0)).length, 1);
  const strict = { ...POCKET_PARAMS, unknownIsPlay: false };
  assert.equal(pocketsOf(seq('PUP', T0), strict).length, 0);
  assert.equal(pocketsOf(seq('PQP', T0)).length, 1, "'partial' is a play by default");
  assert.equal(pocketsOf(seq('PQP', T0), { ...POCKET_PARAMS, partialIsPlay: false }).length, 0);
});

test("'game' source is ignored entirely", () => {
  const rows = seq('PPP', T0, { source: 'game' });
  assert.equal(pocketsOf(rows).length, 0);
  // A game round in the MIDDLE of a run is invisible, not a break.
  const mixed = [row(E(1), T0), row(E(2), T0 + 4 * MIN), ...seq('SS', T0 + 5 * MIN, { source: 'game' }), row(E(3), T0 + 8 * MIN)];
  const p = pocketsOf(mixed);
  assert.equal(p.length, 1);
  assert.equal(p[0].sessionPlays, 3);
});

test('pocket ids: pk_ + 12 hex of the first member, stable under appends and re-ordering', () => {
  const rows = seq('PPPP', T0);
  const id = pocketsOf(rows)[0].id;
  assert.match(id, /^pk_[0-9a-f]{12}$/);
  assert.equal(id, pocketIdFor(rows[0].id));
  const appended = rows.concat(seq('SPP', T0 + 16 * MIN));
  assert.equal(pocketsOf(appended)[0].id, id);
  assert.equal(pocketsOf(appended)[0].members.length, 6);
  const shuffled = appended.slice().reverse();
  assert.deepEqual(pocketsOf(shuffled).map((p) => [p.id, p.members.map((m) => m.id)]),
    pocketsOf(appended).map((p) => [p.id, p.members.map((m) => m.id)]));
});

test('same-minute plays order by ord, then id', () => {
  const a = row(E(1), T0, { ord: 1, id: '00000000-0000-4000-8000-00000000000A' });
  const b = row(E(2), T0, { ord: 0, id: '00000000-0000-4000-8000-00000000000B' });
  assert.deepEqual(normalizeEvents([a, b]).map((e) => e.id), [b.id, a.id]);
});

// ── §6.4 analysis ───────────────────────────────────────────────────────────────────────────────

/// A mixed baseline: ~60 plays over the previous fortnight — hip-hop, jazz, rock — broken up by
/// skips so they are baseline without being pockets.
function mixedBaseline(nowMs) {
  const out = [];
  const pool = [H(1), H(2), H(3), H(4), J(1), J(2), J(3), 'sng_r00000000001', 'sng_r00000000002'];
  for (let d = 1; d <= 14; d++) {
    const t = nowMs - d * DAY - 6 * HOUR;
    for (let k = 0; k < 4; k++) out.push(row(pool[(d * 4 + k) % pool.length], t + k * 4 * MIN, { source: 'browser', outcome: k === 2 ? 'skipped' : 'completed' }));
    out.push(row(pool[(d + 3) % pool.length], t + 20 * MIN, { source: 'browser' }));
  }
  return out;
}

test('an electronic pocket at 118–124 BPM against a mixed baseline: genre + bpm + harmonic defining, artists not', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const pocketStart = Date.UTC(2026, 9, 12, 14, 40);   // 07:40 PDT
  const pocketRows = seq('PPPPPP', pocketStart, { tz: -420, ctx: ctxAB });
  const doc = { events: [...mixedBaseline(nowMs), ...pocketRows], labels: { places: [], trips: [{ id: TRIP_AB, origin: PLACE_A, destination: PLACE_B, label: 'A → B' }] } };
  const res = computeResults(doc, FEATS, { nowMs });
  const p = res.pockets.find((x) => x.members[0].eventId === pocketRows[0].id);
  assert.ok(p, 'the electronic pocket is found');
  const genre = p.features.find((f) => f.dim === 'genre');
  assert.equal(genre.value, 'electronic');
  assert.equal(genre.label, 'Electronic');
  assert.ok(genre.lift > 1.5, `genre lift ${genre.lift}`);
  assert.equal(genre.share, 1);
  assert.equal(p.numeric.bpm.defining, true);
  assert.equal(p.numeric.bpm.lo, 118);
  assert.equal(p.numeric.bpm.hi, 124);
  assert.ok(p.numeric.bpm.dispersionRatio < 0.5);
  assert.equal(p.features.some((f) => f.dim === 'artist'), false, 'six different artists: none defines it');
  assert.equal(p.harmonic.defining, true, 'the Camelot chain 8A→9A→9B→10B→10A→11A flows');
  assert.equal(p.harmonic.rate, 1);
  assert.equal(p.timeBucket, 'morning');
  assert.equal(p.dayType, 'weekday');
  assert.equal(p.localDate, '2026-10-12');
  assert.deepEqual(p.ctx, ctxAB);
  assert.equal(p.title, 'Weekday morning · A → B · 118–124 BPM · Electronic');
  assert.equal(res.baseline.thin, false);
  // features are sorted by score, capped
  for (let i = 1; i < p.features.length; i++) assert.ok(p.features[i - 1].score >= p.features[i].score);
  assert.ok(p.features.length <= POCKET_PARAMS.categorical.maxFeatures);
});

test('a repeated artist IS defining when concentrated (count ≥ 2, lift ≥ 1.5)', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = seq('PPPP', nowMs - 3 * HOUR, { songs: [H(1), H(2), H(1), H(2)] });   // all Rook
  const res = computeResults({ events: [...mixedBaseline(nowMs), ...rows] }, FEATS, { nowMs });
  const p = res.pockets.find((x) => x.members[0].eventId === rows[0].id);
  const artist = p.features.find((f) => f.dim === 'artist');
  assert.equal(artist?.label, 'Rook');
  assert.equal(artist.count, 4);
});

test('60 and 120 BPM fold together', () => {
  assert.equal(foldBpm(60), 120);
  assert.equal(foldBpm(120), 120);
  assert.equal(foldBpm(240), 120);
  assert.equal(foldBpm(170), 85);
  assert.equal(foldBpm(0), null);
  assert.equal(foldBpm(undefined), null);
  // …in analysis too: the 60-BPM ballad sits with the 120s.
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = seq('PPP', nowMs - 2 * HOUR, { songs: ['sng_b00000000060', E(3), E(3)] });
  const p = computeResults({ events: rows }, FEATS, { nowMs }).pockets[0];
  assert.equal(p.numeric.bpm.lo, 120);
  assert.equal(p.numeric.bpm.hi, 120);
});

test('a pocket of songs with no features still analyses; the title falls back', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = seq('PPPP', Date.UTC(2026, 9, 12, 15, 0), { songs: ['sng_nope00000001', 'sng_nope00000002', 'amrec_1', 'x'] });
  const res = computeResults({ events: rows }, FEATS, { nowMs });
  const p = res.pockets[0];
  assert.equal(p.memberCount, 4);
  assert.deepEqual(p.numeric, {});
  assert.equal(p.harmonic, null);
  assert.equal(p.title, 'Weekday afternoon', 'time phrase only — no BPM, no genre');
  assert.equal(titleFor({}), 'Listening pocket');
  assert.equal(res.baseline.thin, true, 'four plays is a thin baseline');
});

test('features resolve through _clean/_explicit variants and amrec_ store ids', () => {
  assert.deepEqual(identityKeys('sng_1a7f6bc854af_clean'), ['sng_1a7f6bc854af']);
  assert.deepEqual(identityKeys('amrec_1771724281'), ['amrec_1771724281', 'am:1771724281']);
  assert.deepEqual(identityKeys('amrec_0000'), ['amrec_0000'], 'placeholder store ids are not identities');
  assert.equal(resolveSong(FEATS.byId, FEATS.byAm, 'sng_e00000000001_explicit').a, 'Aria');
  assert.equal(resolveSong(FEATS.byId, FEATS.byAm, 'amrec_1771724281').a, 'Captured');
  assert.equal(resolveSong(FEATS.byId, FEATS.byAm, 'sng_unknown'), null);
});

test('the artist snapshot is the fallback for songs the catalog does not know', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = seq('PPPP', nowMs - 2 * HOUR, { songs: ['amrec_99990001', 'amrec_99990002', 'amrec_99990003', 'amrec_99990004'] })
    .map((r) => ({ ...r, artist: 'Mystery Act' }));
  const base = mixedBaseline(nowMs);
  const p = computeResults({ events: [...base, ...rows] }, FEATS, { nowMs }).pockets.find((x) => x.members[0].eventId === rows[0].id);
  assert.equal(p.features.find((f) => f.dim === 'artist')?.label, 'Mystery Act');
});

test('local time: tz offset moves the hour across a bucket edge; night wraps midnight; weekday vs weekend', () => {
  const at = Date.UTC(2026, 9, 12, 16, 30);   // Monday 16:30 UTC
  assert.equal(localTimeOf(at, 0).timeBucket, 'afternoon');
  assert.equal(localTimeOf(at, -420).timeBucket, 'morning');   // 09:30 PDT
  assert.equal(localTimeOf(at, -420).hour, 9.5);
  assert.equal(localTimeOf(Date.UTC(2026, 9, 12, 23, 30), 0).timeBucket, 'night');
  assert.equal(localTimeOf(Date.UTC(2026, 9, 13, 1, 0), 0).timeBucket, 'night');
  assert.equal(localTimeOf(Date.UTC(2026, 9, 13, 5, 0), 0).timeBucket, 'morning');
  assert.equal(localTimeOf(Date.UTC(2026, 9, 13, 4, 59), 0).timeBucket, 'night');
  // Sat 10 Oct 23:30 UTC is Sat 16:30 PDT (weekend) — and Mon 12 Oct 02:00 UTC is Sun 19:00 PDT.
  assert.equal(localTimeOf(Date.UTC(2026, 9, 10, 23, 30), -420).dayType, 'weekend');
  assert.equal(localTimeOf(Date.UTC(2026, 9, 12, 2, 0), -420).dow, 0);
  assert.equal(localTimeOf(Date.UTC(2026, 9, 12, 2, 0), -420).localDate, '2026-10-11');
  assert.equal(localTimeOf(Date.UTC(2026, 9, 12, 2, 0), 0).dayType, 'weekday');
});

test('a play uploaded without a tz offset falls back to the profile\'s usual offset', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = [
    ...seq('PPP', Date.UTC(2026, 9, 10, 15, 0), { tz: -420 }),
    ...seq('PPP', Date.UTC(2026, 9, 12, 15, 0), { tz: null }),
  ];
  const latest = computeResults({ events: rows }, FEATS, { nowMs }).pockets[0];
  assert.equal(latest.tzOffsetMin, -420);
  assert.equal(latest.timeBucket, 'morning');
});

test('harmonic: neighbours are itself, ±1 same letter (12↔1 wrap) and the other letter', () => {
  assert.deepEqual([...camelotNeighbors('8A')].sort(), ['7A', '8A', '8B', '9A']);
  assert.deepEqual([...camelotNeighbors('12B')].sort(), ['11B', '12A', '12B', '1B']);
  assert.equal(camelotNeighbors('nope').size, 0);
});

// ── Patterns ────────────────────────────────────────────────────────────────────────────────────

const LABELS = {
  places: [{ id: PLACE_A, rank: 1, label: 'Location A' }, { id: PLACE_B, rank: 2, label: 'Location B' }, { id: PLACE_X, rank: 3, label: 'Location C' }],
  trips: [{ id: TRIP_AB, origin: PLACE_A, destination: PLACE_B, label: 'A → B' }, { id: TRIP_BA, origin: PLACE_B, destination: PLACE_A, label: 'B → A' }],
};
/// Weekday-morning A→B electronic pockets on three dates, plus a B→A evening hip-hop pocket.
function commuteWeek() {
  const rows = [];
  const morning = (day) => Date.UTC(2026, 9, day, 14, 40);    // 07:40 PDT
  for (const day of [6, 7, 8]) rows.push(...seq('PPPSPP', morning(day), { tz: -420, ctx: ctxAB }));
  rows.push(...seq('PPPP', Date.UTC(2026, 9, 7, 1, 10), { tz: -420, ctx: ctxBA, songs: [H(1), H(2), H(3), H(4)] }));   // Tue 6 Oct 18:10 PDT
  return rows;
}

test('three weekday-morning A→B electronic pockets on three dates → one pattern, id stable across runs', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const doc = { events: [...mixedBaseline(nowMs), ...commuteWeek()], labels: LABELS };
  const res = computeResults(doc, FEATS, { nowMs });
  const pt = res.patterns.find((x) => x.key === `weekday|morning|trip:${TRIP_AB}|electronic`);
  assert.ok(pt, `patterns: ${res.patterns.map((x) => x.key)}`);
  assert.match(pt.id, /^pt_[0-9a-f]{12}$/);
  assert.equal(pt.occurrences, 3);
  assert.equal(pt.distinctDays, 3);
  assert.deepEqual(pt.ctx, ctxAB);
  assert.equal(pt.title, 'Weekday mornings · A → B · 118–124 BPM · Electronic');
  assert.ok(pt.topSongs.length > 0 && pt.topSongs.length <= 25);
  assert.ok(pt.topSongs.every((s, i) => i === 0 || pt.topSongs[i - 1].plays >= s.plays));
  for (const id of pt.pocketIds) assert.equal(res.pockets.find((p) => p.id === id).patternId, pt.id);
  // The B→A evening pocket is NOT in it — direction of travel is a feature.
  const evening = res.pockets.find((p) => p.ctx?.tripId === TRIP_BA);
  assert.ok(evening);
  assert.equal(pt.pocketIds.includes(evening.id), false);
  assert.equal(evening.timeBucket, 'evening');
  // Stable: same input, same ids, same document.
  const again = computeResults(JSON.parse(JSON.stringify(doc)), FEATS, { nowMs });
  assert.deepEqual(again, res);
});

test('A→B and B→A at the same time of day are different patterns', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = [];
  for (const day of [6, 7]) rows.push(...seq('PPP', Date.UTC(2026, 9, day, 14, 40), { tz: -420, ctx: ctxAB }));
  for (const day of [8, 9]) rows.push(...seq('PPP', Date.UTC(2026, 9, day, 14, 40), { tz: -420, ctx: ctxBA }));
  const res = computeResults({ events: rows, labels: LABELS }, FEATS, { nowMs });
  const keys = res.patterns.map((p) => p.key).sort();
  assert.deepEqual(keys, [`weekday|morning|trip:${TRIP_AB}|electronic`, `weekday|morning|trip:${TRIP_BA}|electronic`].sort());
});

test('two pockets on the same date never make a pattern', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = [...seq('PPP', Date.UTC(2026, 9, 7, 14, 0), { tz: -420 }), ...seq('PPP', Date.UTC(2026, 9, 7, 16, 0), { tz: -420 })];
  const res = computeResults({ events: rows }, FEATS, { nowMs });
  assert.equal(res.pockets.length, 2);
  assert.equal(res.pockets[0].timeBucket, res.pockets[1].timeBucket);
  assert.deepEqual(res.patterns, []);
});

test('the relaxed pass catches recurring pockets whose contexts differ (or are missing)', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const rows = [
    ...seq('PPP', Date.UTC(2026, 9, 6, 14, 40), { tz: -420 }),                                         // no ctx (location off)
    ...seq('PPP', Date.UTC(2026, 9, 8, 14, 40), { tz: -420, ctx: { kind: 'place', placeId: PLACE_X } }),
  ];
  const res = computeResults({ events: rows, labels: LABELS }, FEATS, { nowMs });
  assert.equal(res.patterns.length, 1);
  assert.equal(res.patterns[0].key, 'weekday|morning|*|electronic');
  assert.equal(res.patterns[0].ctx, null);
  assert.equal(res.patterns[0].occurrences, 2);
});

test('results: newest first, outside resultsDays dropped, deterministic, labels echoed', () => {
  const nowMs = Date.UTC(2026, 9, 12, 19, 0);
  const old = seq('PPP', nowMs - 120 * DAY);
  const recent = seq('PPP', nowMs - 2 * DAY);
  const newer = seq('PPP', nowMs - 1 * DAY);
  const res = computeResults({ events: [...old, ...recent, ...newer], labels: LABELS }, FEATS, { nowMs });
  assert.deepEqual(res.pockets.map((p) => p.members[0].eventId), [newer[0].id, recent[0].id]);
  assert.deepEqual(res.labels.places, LABELS.places);
  assert.equal(res.generatedAtMs, nowMs);
  assert.equal(res.stale, false);
  assert.equal(res.algo.version, POCKET_PARAMS.version);
  assert.equal(res.algo.params.minRun, 3);
});

// ── §5.3 merge ──────────────────────────────────────────────────────────────────────────────────

const NOW = Date.now();
const wire = (over = {}) => ({
  id: over.id || uid(), songId: E(1), atMs: NOW - HOUR, ord: 0, tzOffsetMin: -420, source: 'mix',
  outcome: 'completed', fraction: 0.9, originInstallId: INSTALL, artist: 'Aria', carPlay: true, ctx: null, ...over,
});

test('merge: outcome monotone, fraction max, non-null ctx wins, immutables kept, identical re-upload changes nothing', () => {
  const doc = freshEventsDoc(NOW);
  const id = uid();
  const first = cleanEvent(wire({ id, outcome: 'partial', fraction: 0.3, tzOffsetMin: null, artist: null }), INSTALL, NOW);
  assert.deepEqual(mergeEvents(doc, [first], NOW).accepted, 1);
  // A later verdict: skipped beats partial; fraction rises; ctx arrives; tz/artist fill in.
  const later = cleanEvent(wire({ id, outcome: 'skipped', fraction: 0.45, ctx: ctxAB, atMs: NOW - 2 * HOUR, songId: E(2), ord: 7 }), INSTALL, NOW);
  const m2 = mergeEvents(doc, [later], NOW);
  assert.deepEqual([m2.accepted, m2.updated, m2.unchanged], [0, 1, 0]);
  const stored = doc.events[0];
  assert.equal(stored.outcome, 'skipped');
  assert.equal(stored.fraction, 0.45);
  assert.deepEqual(stored.ctx, ctxAB);
  assert.equal(stored.tzOffsetMin, -420);
  assert.equal(stored.artist, 'Aria');
  assert.equal(stored.songId, E(1), 'songId immutable');
  assert.equal(stored.atMs, Math.floor((NOW - HOUR) / MIN) * MIN, 'atMs immutable');
  assert.equal(stored.ord, 0, 'ord immutable');
  // Skip is monotone: a later "completed" never un-skips; a lower fraction never lowers it; a
  // different ctx never replaces a non-null one.
  const regress = cleanEvent(wire({ id, outcome: 'completed', fraction: 0.2, ctx: ctxBA }), INSTALL, NOW);
  const m3 = mergeEvents(doc, [regress], NOW);
  assert.deepEqual([m3.accepted, m3.updated, m3.unchanged], [0, 0, 1]);
  assert.equal(stored.outcome, 'skipped');
  assert.deepEqual(stored.ctx, ctxAB);
  // Order-independence: applying the two in the other order lands on the same row.
  const doc2 = freshEventsDoc(NOW);
  mergeEvents(doc2, [later], NOW); mergeEvents(doc2, [first], NOW);
  assert.equal(doc2.events[0].outcome, 'skipped');
  assert.equal(doc2.events[0].fraction, 0.45);
});

test('cleanEvent: minute floor, uppercase id, bounded strings, ctx rules, bad rows rejected', () => {
  const r = cleanEvent(wire({ id: 'abcdef01-0000-4000-8000-0000000000ff', atMs: NOW - HOUR + 12_345 }), INSTALL, NOW);
  assert.equal(r.id, 'ABCDEF01-0000-4000-8000-0000000000FF');
  assert.equal(r.atMs % MIN, 0);
  assert.equal(r.installId, INSTALL);
  assert.equal(cleanEvent(wire({ originInstallId: null }), 'UPLOADER-1234', NOW).installId, 'UPLOADER-1234');
  assert.equal(cleanEvent(wire({ artist: 'x'.repeat(5000) }), INSTALL, NOW).artist.length, 256);
  assert.equal(cleanEvent(wire({ outcome: 'teleported' }), INSTALL, NOW).outcome, 'unknown');
  assert.equal(cleanEvent(wire({ fraction: 7 }), INSTALL, NOW).fraction, 1);
  assert.equal(cleanEvent(wire({ tzOffsetMin: 9999 }), INSTALL, NOW).tzOffsetMin, null);
  assert.equal(cleanEvent(wire({ id: 'not-a-uuid' }), INSTALL, NOW), null);
  assert.equal(cleanEvent(wire({ songId: '' }), INSTALL, NOW), null);
  assert.equal(cleanEvent(wire({ atMs: 'yesterday' }), INSTALL, NOW), null);
  assert.equal(cleanEvent(wire({ atMs: NOW + 3 * DAY }), INSTALL, NOW), null);
  assert.equal(cleanEvent(wire({ atMs: NOW - 200 * DAY }), INSTALL, NOW), null);
  assert.deepEqual(cleanCtx({ kind: 'spaceship', placeId: PLACE_A }), { kind: 'none' });
  assert.deepEqual(cleanCtx({ kind: 'place', placeId: 'plc_NOTHEX' }), { kind: 'none' });
  assert.deepEqual(cleanCtx({ kind: 'trip', tripId: TRIP_AB, origin: PLACE_A }), { kind: 'trip', tripId: TRIP_AB, origin: PLACE_A, destination: null });
  assert.equal(cleanCtx(null), null);
});

// ── Handler ─────────────────────────────────────────────────────────────────────────────────────

const PROFILE = 'a'.repeat(64);
const KEY = 'k'.repeat(64);
const OTHER_KEY = 'z'.repeat(64);
const ENROLL = process.env.REC_ENROLL_SECRET;
let profileN = 0;
const freshProfile = () => createHash('sha256').update(`profile-${++profileN}`).digest('hex');
const eventsPath = (p) => join(HOME, 'pockets', 'events', `${createHash('sha256').update(p).digest('hex')}.json`);
const resultsPath = (p) => join(HOME, 'pockets', 'results', `${createHash('sha256').update(p).digest('hex')}.json`);

function ev(method, path, { profile = PROFILE, key = KEY, enroll = ENROLL, body, rawBody } = {}) {
  const headers = { 'x-pocketdj-device': 'D1' };
  if (profile !== null) headers['x-pocketdj-profile'] = profile;
  if (key !== null) headers.authorization = `Bearer ${key}`;
  if (enroll !== null) headers['x-pocketdj-enroll'] = enroll;
  return { rawPath: path, requestContext: { http: { method } }, headers,
    body: rawBody !== undefined ? rawBody : body !== undefined ? JSON.stringify(body) : undefined };
}
async function call(method, path, opts) {
  const res = await handler(ev(method, path, opts));
  return { status: res.statusCode, json: JSON.parse(res.body) };
}
const batch = (events, extra = {}) => ({ v: 1, deviceId: 'D1', installId: INSTALL, sentAtMs: NOW, events, ...extra });
/// A wire-shape session (upload events) relative to now.
function wireSeq(pattern, startMs, opts = {}) {
  return seq(pattern, startMs, opts).map((r) => wire({ id: r.id, songId: r.songId, atMs: r.atMs, outcome: r.outcome, fraction: r.fraction, ctx: r.ctx }));
}

test('health is unauthenticated, on both path shapes', async () => {
  for (const p of ['/health', '/pockets/health', '/pockets/health/']) {
    const r = await call('GET', p, { profile: null, key: null, enroll: null });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, { ok: true, service: 'listening-pockets', version: 1 });
  }
});

test('path normalization strips only a whole /pockets segment', () => {
  assert.equal(normalizePath('/pockets/events/'), '/events');
  assert.equal(normalizePath('/events'), '/events');
  assert.equal(normalizePath('/pockets'), '/');
  assert.equal(normalizePath('/pocketsevents'), '/pocketsevents');
});

test('400 / 401 / 403 auth and validation paths', async () => {
  assert.equal((await call('POST', '/pockets/events', { profile: null, body: batch([]) })).status, 400);
  assert.equal((await call('POST', '/pockets/events', { profile: 'short', body: batch([]) })).status, 400);
  assert.equal((await call('POST', '/pockets/events', { key: null, body: batch([]) })).status, 401);
  const p = freshProfile();
  const noEnroll = await call('POST', '/pockets/events', { profile: p, enroll: null, body: batch([wire()]) });
  assert.equal(noEnroll.status, 403);
  assert.equal(noEnroll.json.error, 'enrollment-required');
  assert.equal(existsSync(eventsPath(p)), false, 'a refused enrollment writes nothing');
  const wrong = await call('POST', '/pockets/events', { profile: p, enroll: 'x'.repeat(ENROLL.length), body: batch([wire()]) });
  assert.equal(wrong.status, 403);
  assert.equal((await call('POST', '/pockets/events', { profile: p, body: batch([wire()]) })).status, 200);
  const mismatch = await call('POST', '/pockets/events', { profile: p, key: OTHER_KEY, body: batch([wire()]) });
  assert.equal(mismatch.status, 403);
  assert.equal(mismatch.json.error, 'key-mismatch');
  const mismatchGet = await call('GET', '/pockets/results', { profile: p, key: OTHER_KEY });
  assert.equal(mismatchGet.status, 403);
  // Bound profiles upload with the key alone.
  assert.equal((await call('POST', '/pockets/events', { profile: p, enroll: null, body: batch([wire()]) })).status, 200);
  // Malformed bodies.
  assert.equal((await call('POST', '/pockets/events', { profile: p, rawBody: '{nope' })).json.error, 'bad-request');
  assert.equal((await call('POST', '/pockets/events', { profile: p, body: { ...batch([]), v: 2 } })).status, 400);
  assert.equal((await call('POST', '/pockets/events', { profile: p, body: { ...batch([]), installId: 'bad id!' } })).status, 400);
  assert.equal((await call('POST', '/pockets/events', { profile: p, body: { v: 1, installId: INSTALL } })).status, 400);
  assert.equal((await call('GET', '/pockets/nope', { profile: p })).status, 404);
});

test('the enrollment cap bounds NEW profiles only', async () => {
  const established = freshProfile();
  assert.equal((await call('POST', '/events', { profile: established, body: batch([]) })).status, 200);
  const prev = process.env.MAX_PROFILES;
  process.env.MAX_PROFILES = '1';
  try {
    const fresh = await call('POST', '/events', { profile: freshProfile(), body: batch([wire()]) });
    assert.equal(fresh.status, 403);
    assert.equal(fresh.json.error, 'profile-cap-reached');
    assert.equal((await call('POST', '/events', { profile: established, body: batch([wire()]) })).status, 200);
  } finally { process.env.MAX_PROFILES = prev; }
});

test('GET before any POST returns the empty shape (never 403)', async () => {
  const r = await call('GET', '/pockets/results', { profile: freshProfile(), key: OTHER_KEY });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, emptyResults());
  assert.deepEqual(validateResults(r.json), []);
});

test('POST then GET returns computed results; /events and /pockets/events both route', async () => {
  const p = freshProfile();
  const start = NOW - 3 * HOUR;
  const first = wireSeq('PPPSPSP', start, { ctx: ctxAB });
  const r1 = await call('POST', '/pockets/events', { profile: p, body: batch(first, LABELS) });
  assert.equal(r1.status, 200);
  assert.deepEqual(r1.json, { ok: true, accepted: 7, updated: 0, unchanged: 0, rejected: 0, total: 7, dirty: true });
  const got = await call('GET', '/pockets/results', { profile: p });
  assert.equal(got.status, 200);
  assert.equal(got.json.stale, false);
  assert.equal(got.json.pockets.length, 1);
  assert.equal(got.json.pockets[0].memberCount, 5);
  assert.equal(got.json.pockets[0].skippedCount, 2);
  assert.equal(got.json.pockets[0].sessionPlays, 7);
  assert.deepEqual(got.json.labels, LABELS);
  assert.deepEqual(validateResults(got.json), []);
  // Same route without the prefix; an identical re-upload changes nothing.
  const again = await call('POST', '/events', { profile: p, body: batch(first, LABELS) });
  assert.deepEqual([again.json.accepted, again.json.updated, again.json.unchanged], [0, 0, 7]);
  // A later skip verdict on an existing event is an UPDATE and recomputes: the pocket loses a member.
  const flipped = { ...first[4], outcome: 'skipped', fraction: 0.2 };
  const upd = await call('POST', '/events', { profile: p, body: batch([flipped]) });
  assert.deepEqual([upd.json.accepted, upd.json.updated], [0, 1]);
  const after = await call('GET', '/results', { profile: p });
  // P P P S S S P → the two skips after the 3rd play end the pocket at 3 members.
  assert.equal(after.json.pockets[0].memberCount, 3);
});

test('stored rows: unknown ctx.kind is stored as none; bad rows are rejected one by one', async () => {
  const p = freshProfile();
  const good = wire({ ctx: { kind: 'hovercraft', placeId: PLACE_A } });
  const bad = [wire({ id: 'nope' }), wire({ songId: null }), { junk: true }, null, wire({ atMs: NOW + 5 * DAY })];
  const r = await call('POST', '/events', { profile: p, body: batch([good, ...bad]) });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted, 1);
  assert.equal(r.json.rejected, 5);
  const stored = JSON.parse(readFileSync(eventsPath(p), 'utf8'));
  assert.deepEqual(stored.events[0].ctx, { kind: 'none' });
  assert.equal(stored.events[0].atMs % MIN, 0, 'coarse time on disk');
  assert.equal(stored.keyHash, createHash('sha256').update(KEY).digest('hex'));
});

test('body and batch limits', async () => {
  const p = freshProfile();
  const big = await call('POST', '/events', { profile: p, rawBody: 'x'.repeat(4 * 1024 * 1024 + 1) });
  assert.equal(big.status, 413);
  assert.equal(big.json.error, 'body-too-large');
  const many = Array.from({ length: 2001 }, () => wire());
  const tooMany = await call('POST', '/events', { profile: p, body: batch(many) });
  assert.equal(tooMany.status, 400);
  assert.equal(tooMany.json.error, 'batch-too-large');
  assert.equal(existsSync(eventsPath(p)), false);
});

test('DELETE /state with the bound key, and with the enrollment secret under a wrong key', async () => {
  const p = freshProfile();
  await call('POST', '/events', { profile: p, body: batch(wireSeq('PPP', NOW - 2 * HOUR)) });
  assert.ok(existsSync(eventsPath(p)) && existsSync(resultsPath(p)));
  assert.equal((await call('DELETE', '/pockets/state', { profile: p })).status, 200);
  assert.equal(existsSync(eventsPath(p)), false);
  assert.equal(existsSync(resultsPath(p)), false);

  const q = freshProfile();
  await call('POST', '/events', { profile: q, body: batch(wireSeq('PPP', NOW - 2 * HOUR)) });
  const blocked = await call('DELETE', '/state', { profile: q, key: OTHER_KEY, enroll: null });
  assert.equal(blocked.status, 403);
  const del = await call('DELETE', '/state', { profile: q, key: OTHER_KEY });
  assert.deepEqual(del.json, { deleted: true });
  assert.equal(existsSync(eventsPath(q)), false);
  // Deleting nothing is fine.
  assert.equal((await call('DELETE', '/state', { profile: freshProfile() })).status, 200);
});

test('async mode: POST marks dirty + invokes compute; the compute job clears it; GET reports stale', async () => {
  const invoked = [];
  _test.setInvoker(async (payload) => { invoked.push(payload); });
  process.env.POCKETS_INLINE_COMPUTE = '0';
  try {
    const p = freshProfile();
    const h = createHash('sha256').update(p).digest('hex');
    const r = await call('POST', '/events', { profile: p, body: batch(wireSeq('PPPP', NOW - 2 * HOUR)) });
    assert.equal(r.json.dirty, true);
    assert.deepEqual(invoked, [{ job: 'compute', p: h }]);
    const pending = await call('GET', '/results', { profile: p });
    assert.equal(pending.json.stale, true);
    assert.equal(pending.json.generatedAtMs, null);
    // Jobs are dispatched before routing, and never through the HTTP surface.
    const out = await handler({ job: 'compute', p: h });
    assert.equal(out.ok, true);
    assert.equal(out.pockets, 1);
    const done = await call('GET', '/results', { profile: p });
    assert.equal(done.json.stale, false);
    assert.equal(done.json.pockets.length, 1);
    // An identical re-send neither dirties nor invokes.
    invoked.length = 0;
    const same = await call('POST', '/events', { profile: p, body: batch(wireSeq('PPPP', NOW - 2 * HOUR)) });
    assert.equal(same.json.accepted, 4, 'fresh ids (wireSeq mints new ones) are new rows');
    invoked.length = 0;
    const stored = JSON.parse(readFileSync(eventsPath(p), 'utf8'));
    const resend = await call('POST', '/events', { profile: p, body: batch(stored.events.map((e) => ({ ...e, fraction: e.fraction }))) });
    assert.equal(resend.json.accepted + resend.json.updated, 0);
    assert.deepEqual(invoked, []);
    // A failed invoke never fails the upload.
    _test.setInvoker(async () => { throw new Error('lambda down'); });
    const stillOk = await call('POST', '/events', { profile: p, body: batch([wire()]) });
    assert.equal(stillOk.status, 200);
    assert.equal(stillOk.json.dirty, true);
    assert.equal((await handler({ job: 'compute', p: 'not-a-hash' })).ok, false);
    assert.equal((await handler({ job: 'teleport' })).ok, false);
  } finally {
    process.env.POCKETS_INLINE_COMPUTE = '1';
    _test.setInvoker(null);
  }
});

test('nightly: recomputes dirty or stale profiles, skips fresh ones, chains when time runs low', async () => {
  const invoked = [];
  _test.setInvoker(async (payload) => { invoked.push(payload); });
  try {
    // Fresh + clean (inline compute ran).
    const fresh = freshProfile();
    await call('POST', '/events', { profile: fresh, body: batch(wireSeq('PPP', NOW - 2 * HOUR)) });
    // Dirty (async upload, nobody computed).
    process.env.POCKETS_INLINE_COMPUTE = '0';
    const dirty = freshProfile();
    await call('POST', '/events', { profile: dirty, body: batch(wireSeq('PPP', NOW - 2 * HOUR)) });
    process.env.POCKETS_INLINE_COMPUTE = '1';
    // Stale results (computed 21 h ago).
    const old = freshProfile();
    await call('POST', '/events', { profile: old, body: batch(wireSeq('PPP', NOW - 2 * HOUR)) });
    const rp = resultsPath(old);
    const doc = JSON.parse(readFileSync(rp, 'utf8'));
    doc.generatedAtMs = Date.now() - 21 * HOUR;
    writeFileSync(rp, JSON.stringify(doc));

    const hashOf = (p) => createHash('sha256').update(p).digest('hex');
    const hashes = [fresh, dirty, old].map(hashOf);
    const out = await handler({ job: 'nightly', hashes }, { getRemainingTimeInMillis: () => 100_000 });
    assert.deepEqual([out.computed, out.skipped, out.failed, out.chained], [2, 1, 0, 0]);
    assert.equal(JSON.parse(readFileSync(eventsPath(dirty), 'utf8')).dirty, false);
    assert.ok(JSON.parse(readFileSync(rp, 'utf8')).generatedAtMs > Date.now() - HOUR);

    // Time running low: nothing computed here, the whole list handed to a continuation.
    invoked.length = 0;
    const low = await handler({ job: 'nightly', hashes, hop: 2 }, { getRemainingTimeInMillis: () => 1_000 });
    assert.equal(low.chained, 3);
    assert.deepEqual(invoked, [{ job: 'nightly', hashes, hop: 3 }]);
    // The hop guard stops a runaway chain.
    assert.equal((await handler({ job: 'nightly', hashes, hop: 99 }, {})).ok, false);
    // Without an explicit list it walks every profile in the store.
    const all = await handler({ job: 'nightly' }, { getRemainingTimeInMillis: () => 100_000 });
    assert.equal(all.failed, 0);
    assert.ok(all.computed + all.skipped >= 3);
  } finally {
    process.env.POCKETS_INLINE_COMPUTE = '1';
    _test.setInvoker(null);
  }
});

// ── Local runner + contract ─────────────────────────────────────────────────────────────────────

const FIXTURE_DIR = join(HERE, 'fixtures');
const FIXTURE_NOW = 1791831600000;

test('run-local on fixtures/upload.sample.json reproduces fixtures/results.sample.json', () => {
  const out = join(HOME, 'results.json');
  const r = spawnSync(process.execPath, [join(HERE, 'run-local.mjs'),
    '--events', join(FIXTURE_DIR, 'upload.sample.json'), '--features', join(FIXTURE_DIR, 'features.sample.json'),
    '--now', String(FIXTURE_NOW), '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const produced = JSON.parse(readFileSync(out, 'utf8'));
  const expected = JSON.parse(readFileSync(join(FIXTURE_DIR, 'results.sample.json'), 'utf8'));
  assert.deepEqual(produced, expected);
  assert.deepEqual(validateResults(expected), []);
  // The story the fixture tells is actually in it.
  assert.ok(expected.patterns.some((p) => p.title === 'Weekday mornings · A → B · 118–124 BPM · Electronic'));
  assert.ok(expected.patterns.some((p) => /^Weekday evenings · B → A/.test(p.title)));
  assert.ok(expected.pockets.every((p) => p.members.every((m) => m.outcome !== 'skipped')));
  assert.match(r.stderr, /pockets: \d+ · patterns: \d+/);
});

test('the upload fixture is a valid upload.v1 batch', () => {
  const up = JSON.parse(readFileSync(join(FIXTURE_DIR, 'upload.sample.json'), 'utf8'));
  assert.equal(up.v, 1);
  assert.ok(up.events.length > 0 && up.events.length <= 2000);
  for (const e of up.events) assert.ok(cleanEvent(e, up.installId, FIXTURE_NOW), `row ${e.id} cleans`);
});

test('a raw PlayHistoryStore document converts on the fly', () => {
  const base = Date.UTC(2026, 9, 12, 15, 0, 20);
  const historyDoc = {
    schemaVersion: 1, installId: INSTALL,
    events: [
      { id: '11111111-0000-4000-8000-000000000001', songId: E(1), playedAt: base + 5_000.5, source: 'mix', artist: 'Aria' },
      { id: '11111111-0000-4000-8000-000000000002', songId: E(2), playedAt: base + 30_000, source: 'mix', listenedFraction: 0.97, tzOffsetMin: -420 },
      { id: '11111111-0000-4000-8000-000000000003', songId: E(3), playedAt: base + 4 * MIN, source: 'mix', wasSkipped: true, listenedFraction: 0.1 },
      { id: '11111111-0000-4000-8000-000000000004', songId: E(4), playedAt: base + 8 * MIN, source: 'playlist', listenedFraction: 0.2,
        listeningContext: { kind: 'place', placeId: PLACE_A }, carPlay: false, originInstallId: IPAD },
    ],
  };
  const up = toUpload(historyDoc);
  assert.equal(up.shape, 'history');
  assert.equal(up.installId, INSTALL);
  const conv = historyToUploadEvents(historyDoc, { tzOffsetAt: () => -480 });
  assert.deepEqual(conv.map((e) => e.outcome), ['unknown', 'completed', 'skipped', 'partial']);
  assert.deepEqual(conv.map((e) => e.atMs % MIN), [0, 0, 0, 0]);
  assert.deepEqual(conv.map((e) => e.ord), [0, 1, 0, 0], 'two plays in one minute are ordered');
  assert.deepEqual(conv.map((e) => e.tzOffsetMin), [-480, -420, -480, -480], 'own tz wins, else the machine\'s');
  assert.deepEqual(conv[3].ctx, { kind: 'place', placeId: PLACE_A });
  assert.equal(conv[3].originInstallId, IPAD);
  assert.equal(conv[3].carPlay, false);
  const { doc, rejected } = buildEventsDoc(up, base + DAY);
  assert.equal(rejected, 0);
  assert.equal(doc.events.length, 4);
  assert.equal(doc.events.find((e) => e.songId === E(4)).installId, IPAD);
  assert.deepEqual(toUpload([wire()]).shape, 'events');
});

// ── A dependency-free validator for results.v1 (§5.2): every required key, every type ─────────

function validateResults(doc) {
  const errs = [];
  const at = (path, cond, msg) => { if (!cond) errs.push(`${path}: ${msg}`); };
  const isInt = Number.isInteger; const isNum = (x) => typeof x === 'number' && Number.isFinite(x);
  const isStr = (x) => typeof x === 'string';
  const req = (path, o, keys) => { for (const k of keys) at(`${path}.${k}`, o && k in o, 'required'); };
  const ctxOk = (path, c) => {
    if (c == null) return;
    at(path, typeof c === 'object' && isStr(c.kind), 'ctx object with kind');
  };
  const feature = (path, f) => {
    req(path, f, ['dim', 'value', 'label', 'share', 'lift', 'score']);
    at(`${path}.dim`, isStr(f.dim), 'string'); at(`${path}.value`, isStr(f.value), 'string');
    at(`${path}.label`, isStr(f.label), 'string');
    for (const k of ['share', 'lift', 'score']) at(`${path}.${k}`, isNum(f[k]), 'number');
    if ('baselineShare' in f) at(`${path}.baselineShare`, isNum(f.baselineShare), 'number');
    if ('count' in f) at(`${path}.count`, isInt(f.count), 'integer');
  };
  const numeric = (path, n) => {
    at(path, n && typeof n === 'object', 'object');
    for (const [k, v] of Object.entries(n || {})) {
      req(`${path}.${k}`, v, ['center', 'lo', 'hi', 'coverage', 'dispersionRatio', 'defining']);
      for (const f of ['center', 'lo', 'hi', 'coverage']) at(`${path}.${k}.${f}`, isNum(v[f]), 'number');
      at(`${path}.${k}.dispersionRatio`, v.dispersionRatio === null || isNum(v.dispersionRatio), 'number|null');
      at(`${path}.${k}.defining`, typeof v.defining === 'boolean', 'boolean');
    }
  };
  req('$', doc, ['v', 'generatedAtMs', 'stale', 'algo', 'pockets', 'patterns']);
  at('$.v', doc.v === 1, 'const 1');
  at('$.generatedAtMs', doc.generatedAtMs === null || isInt(doc.generatedAtMs), 'integer|null');
  at('$.stale', typeof doc.stale === 'boolean', 'boolean');
  req('$.algo', doc.algo, ['version', 'params']);
  at('$.algo.version', isInt(doc.algo?.version), 'integer');
  at('$.algo.params', doc.algo?.params && typeof doc.algo.params === 'object', 'object');
  if (doc.baseline) {
    at('$.baseline.plays', isInt(doc.baseline.plays), 'integer');
    at('$.baseline.windowDays', isNum(doc.baseline.windowDays), 'number');
    at('$.baseline.thin', typeof doc.baseline.thin === 'boolean', 'boolean');
  }
  if (doc.labels) {
    at('$.labels.places', Array.isArray(doc.labels.places), 'array');
    at('$.labels.trips', Array.isArray(doc.labels.trips), 'array');
  }
  at('$.pockets', Array.isArray(doc.pockets), 'array');
  at('$.patterns', Array.isArray(doc.patterns), 'array');
  (doc.pockets || []).forEach((p, i) => {
    const P = `$.pockets[${i}]`;
    req(P, p, ['id', 'startMs', 'endMs', 'memberCount', 'members', 'features', 'numeric', 'title']);
    at(`${P}.id`, /^pk_[0-9a-f]{12}$/.test(p.id), 'pattern');
    for (const k of ['startMs', 'endMs', 'tzOffsetMin', 'dow', 'skippedCount', 'sessionPlays']) at(`${P}.${k}`, isInt(p[k]), 'integer');
    at(`${P}.memberCount`, isInt(p.memberCount) && p.memberCount >= 3, 'integer ≥ 3');
    at(`${P}.localDate`, /^\d{4}-\d{2}-\d{2}$/.test(p.localDate), 'date');
    at(`${P}.localStartHour`, isNum(p.localStartHour), 'number');
    at(`${P}.dow`, p.dow >= 0 && p.dow <= 6, '0…6');
    at(`${P}.dayType`, ['weekday', 'weekend'].includes(p.dayType), 'enum');
    at(`${P}.timeBucket`, ['night', 'morning', 'midday', 'afternoon', 'evening'].includes(p.timeBucket), 'enum');
    at(`${P}.installId`, isStr(p.installId), 'string');
    at(`${P}.members`, Array.isArray(p.members) && p.members.length === p.memberCount, 'array of memberCount');
    (p.members || []).forEach((m, j) => {
      req(`${P}.members[${j}]`, m, ['eventId', 'songId', 'atMs']);
      at(`${P}.members[${j}]`, isStr(m.eventId) && isStr(m.songId) && isInt(m.atMs) && (m.outcome === undefined || isStr(m.outcome)), 'types');
    });
    ctxOk(`${P}.ctx`, p.ctx);
    at(`${P}.features`, Array.isArray(p.features), 'array');
    (p.features || []).forEach((f, j) => feature(`${P}.features[${j}]`, f));
    numeric(`${P}.numeric`, p.numeric);
    if (p.harmonic != null) at(`${P}.harmonic`, isNum(p.harmonic.rate) && isNum(p.harmonic.baselineRate) && typeof p.harmonic.defining === 'boolean', 'shape');
    at(`${P}.title`, isStr(p.title) && p.title.length > 0, 'non-empty string');
    at(`${P}.patternId`, p.patternId === null || p.patternId === undefined || isStr(p.patternId), 'string|null');
  });
  (doc.patterns || []).forEach((t, i) => {
    const P = `$.patterns[${i}]`;
    req(P, t, ['id', 'key', 'title', 'pocketIds', 'occurrences', 'distinctDays', 'features', 'numeric', 'topSongs']);
    at(`${P}.id`, /^pt_[0-9a-f]{12}$/.test(t.id), 'pattern');
    at(`${P}.key`, isStr(t.key), 'string'); at(`${P}.title`, isStr(t.title) && t.title.length > 0, 'string');
    at(`${P}.pocketIds`, Array.isArray(t.pocketIds) && t.pocketIds.every(isStr), 'string[]');
    for (const k of ['occurrences', 'distinctDays', 'firstMs', 'lastMs']) at(`${P}.${k}`, isInt(t[k]), 'integer');
    at(`${P}.dayType`, isStr(t.dayType), 'string'); at(`${P}.timeBucket`, isStr(t.timeBucket), 'string');
    ctxOk(`${P}.ctx`, t.ctx);
    (t.features || []).forEach((f, j) => feature(`${P}.features[${j}]`, f));
    numeric(`${P}.numeric`, t.numeric);
    at(`${P}.topSongs`, Array.isArray(t.topSongs) && t.topSongs.every((s) => isStr(s.songId) && isInt(s.plays)), 'shape');
  });
  return errs;
}

test('the contract validator itself catches a broken document', () => {
  const broken = JSON.parse(readFileSync(join(FIXTURE_DIR, 'results.sample.json'), 'utf8'));
  delete broken.pockets[0].title;
  broken.patterns[0].occurrences = 'many';
  broken.stale = 'no';
  const errs = validateResults(broken);
  assert.ok(errs.some((e) => e.startsWith('$.pockets[0].title')));
  assert.ok(errs.some((e) => e.startsWith('$.patterns[0].occurrences')));
  assert.ok(errs.some((e) => e.startsWith('$.stale')));
});
