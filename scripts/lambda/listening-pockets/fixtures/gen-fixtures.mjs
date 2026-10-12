#!/usr/bin/env node
// Regenerates the SYNTHETIC fixtures beside this file (deterministic: seeded PRNG, fixed clock).
//
//   node scripts/lambda/listening-pockets/fixtures/gen-fixtures.mjs
//   node scripts/lambda/listening-pockets/run-local.mjs --events scripts/lambda/listening-pockets/fixtures/upload.sample.json \
//        --features scripts/lambda/listening-pockets/fixtures/features.sample.json --now 1791831600000 \
//        --out scripts/lambda/listening-pockets/fixtures/results.sample.json
//
// The story (three weeks ending Mon 12 Oct 2026 12:00 PDT, UTC−7):
//   · weekday mornings ~07:40 — the drive from Location A to Location B in CarPlay, Mix, house
//     around 118–124 BPM flowing through neighbouring Camelot keys, the odd hip-hop track skipped.
//     Location was only switched on in week 2, so week 1's drives carry no ctx.
//   · weekday evenings ~18:05 — the drive home B → A, hip-hop, on some days.
//   · weekday middays at B — browser singles, lots of skipping (rarely a pocket).
//   · weekend afternoons at A — jazz from a playlist.
//   · noise: a game session (never pocket material), an iPad stream interleaved in time, unknown /
//     partial outcomes, a `_clean` variant id and an `amrec_` Apple Music capture.
// Nothing here is real listening data — ids, artists and titles are invented.

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const FIXTURE_NOW_MS = 1791831600000;   // 2026-10-12T19:00:00Z = Mon 12:00 PDT
const TZ = -420;
const MIN = 60_000;

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(20261012);
const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
const hex = (n) => Array.from({ length: n }, () => Math.floor(rnd() * 16).toString(16)).join('');
const uuid = () => {
  const h = hex(32).toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};

// ── Catalog ─────────────────────────────────────────────────────────────────────────────────────
const songs = [];
const sid = () => `sng_${hex(12)}`;
const add = (g, artists, n, bpm, keys, extra = {}) => {
  const out = [];
  for (let i = 0; i < n; i++) {
    const row = { i: sid(), al: `alb_${hex(12)}`, a: artists[i % artists.length], n: `${g} track ${i + 1}`, g,
      y: extra.years ? extra.years[0] + Math.floor(rnd() * (extra.years[1] - extra.years[0] + 1)) : 2015,
      b: Math.round((bpm[0] + rnd() * (bpm[1] - bpm[0])) * 10) / 10, c: keys[i % keys.length],
      s: extra.moods ? [pick(extra.moods), pick(extra.moods)].filter((v, j, a) => a.indexOf(v) === j) : undefined };
    if (extra.energy) row.t = { loud: Math.round((extra.energy[0] + rnd() * 0.15) * 1e4) / 1e4, punch: Math.round((extra.energy[1] + rnd() * 0.15) * 1e4) / 1e4 };
    if (row.s === undefined) delete row.s;
    out.push(row);
  }
  songs.push(...out);
  return out;
};
// House: tempos INSIDE 118–124 (the integer ends included), keys walking the wheel 8A→9A→9B→10B→10A→11A.
const house = add('electronic', ['Lumen Drive', 'Kessa', 'Halden', 'Mirae', 'Okto', 'Saffi'], 12, [118, 124],
  ['8A', '9A', '9B', '10B', '10A', '11A'], { years: [2016, 2024], moods: ['driving', 'euphoric', 'warm'], energy: [0.6, 0.65] });
house[0].b = 118; house[1].b = 124;
const hiphop = add('hip-hop', ['Rook Avenue', 'Tamsin Kai', 'Low Orbit', 'DJ Parcel', 'Vela'], 14, [84, 98],
  ['3A', '7B', '12A', '5A', '1B'], { years: [1994, 2022], moods: ['confident', 'dark', 'gritty'], energy: [0.45, 0.5] });
const jazz = add('jazz', ['Bento Quartet', 'Nell Ardent', 'Kessel Trio'], 9, [90, 150],
  ['3A', '4A', '3B', '2A'], { years: [1958, 1975], moods: ['smooth', 'mellow'], energy: [0.15, 0.2] });
const rock = add('rock', ['Glass Harbor', 'The Wexfords'], 6, [128, 152], ['6B', '11B'], { years: [1978, 2005] });
const pop = add('pop', ['Ivy Sol', 'Marlo', 'Penny Arcade'], 9, [100, 128], ['1A', '5B', '8B', '2B'], { years: [2010, 2025], moods: ['bright', 'upbeat'] });
const rnb = add('r&b', ['Cassia June', 'Darnell Moss'], 6, [62, 76], ['4B', '9B'], { years: [1992, 2001], moods: ['smooth', 'romantic'] });
// An Apple Music capture of a house song: the device plays it as `amrec_<storeId>`.
house[5].am = '1771724281';
const features = { v: 1, generatedAt: 'synthetic-fixture', counts: { songs: songs.length }, songs };

// ── Places and trips (opaque ids, as the device would mint them) ───────────────────────────────
const A = `plc_${hex(16)}`; const B = `plc_${hex(16)}`; const C = `plc_${hex(16)}`;
const AB = `trp_${hex(16)}`; const BA = `trp_${hex(16)}`;
const places = [
  { id: A, rank: 1, label: 'Location A', share: 0.62 },
  { id: B, rank: 2, label: 'Location B', share: 0.27 },
  { id: C, rank: 3, label: 'Location C', share: 0.04 },
];
const trips = [
  { id: AB, origin: A, destination: B, label: 'A → B', occurrences: 14 },
  { id: BA, origin: B, destination: A, label: 'B → A', occurrences: 12 },
];

// ── Plays ───────────────────────────────────────────────────────────────────────────────────────
const PHONE = '6F1C2D3E-0000-4000-8000-00000000AAAA';
const IPAD = '0D9E8F7A-1111-4000-8000-00000000BBBB';
const events = [];
const ordByMinute = new Map();
const songIdFor = (row, variant) => (variant === 'clean' ? `${row.i}_clean` : variant === 'am' ? `amrec_${row.am}` : row.i);
function play(atMs, row, { outcome = 'completed', fraction, source = 'mix', ctx = null, carPlay = null, install = PHONE, variant } = {}) {
  const at = Math.floor(atMs / MIN) * MIN;
  const key = `${install}|${at}`;
  const ord = ordByMinute.get(key) || 0; ordByMinute.set(key, ord + 1);
  events.push({
    id: uuid(), songId: songIdFor(row, variant), atMs: at, ord, tzOffsetMin: TZ, source, outcome,
    fraction: fraction ?? (outcome === 'completed' ? Math.round((0.85 + rnd() * 0.15) * 100) / 100
      : outcome === 'skipped' ? Math.round(rnd() * 0.3 * 100) / 100 : outcome === 'partial' ? 0.3 : null),
    originInstallId: install === PHONE ? PHONE : install, artist: row.a, carPlay,
    ctx,
  });
}
/// A session: `pattern` is a string of P (play from `pool`), S (skip something from `skipPool`),
/// U (unknown-outcome play), Q (partial play). Songs are ~3.5 min apart.
function session(startLocal, pattern, pool, { skipPool = hiphop, gapMin = 3.5, ...opts } = {}) {
  let t = startLocal - TZ * MIN;
  let i = Math.floor(rnd() * pool.length);
  for (const ch of pattern) {
    if (ch === 'S') play(t, pick(skipPool), { ...opts, outcome: 'skipped' });
    else play(t, pool[i++ % pool.length], { ...opts, outcome: ch === 'U' ? 'unknown' : ch === 'Q' ? 'partial' : 'completed' });
    t += (ch === 'S' ? 0.6 : gapMin + rnd()) * MIN;
  }
}
const localMs = (y, m, d, h, min) => Date.UTC(y, m - 1, d, h, min);
const START = Date.UTC(2026, 8, 21);   // Mon 21 Sep 2026
for (let day = 0; day < 22; day++) {
  const date = new Date(START + day * 86_400_000);
  const [y, m, d] = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()];
  const dow = date.getUTCDay();
  const weekend = dow === 0 || dow === 6;
  const locationOn = day >= 7;
  const at = (h, min) => localMs(y, m, d, h, min);
  if (day === 21) {   // Monday 12 Oct, up to noon: just the morning drive so far
    session(at(7, 38), 'PPPSPPSP', house, { ctx: { kind: 'trip', tripId: AB, origin: A, destination: B }, carPlay: true });
    break;
  }
  if (!weekend) {
    const drive = locationOn ? { kind: 'trip', tripId: AB, origin: A, destination: B } : null;
    // The morning drive: mostly house, an isolated skip or two (a hip-hop track that doesn't fit).
    const shapes = ['PPPSPP', 'PPPPSPSP', 'PPSPPPP', 'PPPPP', 'PPPSPPP'];
    session(at(7, 35 + Math.floor(rnd() * 15)), pick(shapes), house, { ctx: drive, carPlay: true });
    // Midday at B: hunting through singles.
    const atB = locationOn ? { kind: 'place', placeId: B } : null;
    session(at(12, 10 + Math.floor(rnd() * 20)), pick(['PSSPSP', 'SPPSSP', 'PPSSPS']), [...pop, ...rock],
      { source: 'browser', ctx: atB, skipPool: [...pop, ...rock, ...rnb] });
    // The drive home, three evenings a week: hip-hop.
    if (dow === 1 || dow === 3 || dow === 4) {
      const home = locationOn ? { kind: 'trip', tripId: BA, origin: B, destination: A } : null;
      session(at(18, 2 + Math.floor(rnd() * 10)), pick(['PPPPSP', 'PPPPP', 'PPPSPP']), hiphop,
        { ctx: home, carPlay: true, source: 'playlist', skipPool: pop });
    }
    // Evenings at A: a little of everything, on the iPad twice a week (a separate stream).
    if (dow === 2 || dow === 4) {
      session(at(20, 15), 'PUPSQPP', [...rnb, ...pop, ...jazz], { source: 'playlist', install: IPAD, skipPool: rock });
    }
  } else {
    const atA = locationOn ? { kind: 'place', placeId: A } : null;
    session(at(14, 20 + Math.floor(rnd() * 30)), pick(['PPPPPP', 'PPPSPPP', 'PPPPSPP']), jazz,
      { ctx: atA, source: 'playlist', skipPool: rock });
    // A game round on Saturdays: short snippets that must never become pocket material.
    if (dow === 6) session(at(19, 0), 'PPPPPP', pop, { source: 'game', gapMin: 0.5 });
    // A trip to Location C one Sunday.
    if (dow === 0 && locationOn && day < 14) {
      session(at(11, 5), 'PPSSPP', rock, { ctx: { kind: 'place', placeId: C }, source: 'album', skipPool: pop });
    }
  }
}
// One play of the `_clean` variant and one Apple Music capture, inside a pocket.
session(localMs(2026, 10, 9, 21, 30), 'PPPP', [house[0], house[5], house[2], house[3]], { source: 'mix' });
const tail = events.slice(-4);
tail[0].songId = `${house[0].i}_clean`;
tail[1].songId = `amrec_${house[5].am}`;

events.sort((a, b) => a.atMs - b.atMs || a.ord - b.ord);
const upload = { v: 1, deviceId: 'D1', installId: PHONE, sentAtMs: FIXTURE_NOW_MS, events, places, trips };

writeFileSync(join(HERE, 'features.sample.json'), `${JSON.stringify(features, null, 1)}\n`);
writeFileSync(join(HERE, 'upload.sample.json'), `${JSON.stringify(upload, null, 1)}\n`);
console.error(`[gen-fixtures] ${songs.length} songs, ${events.length} events → features.sample.json, upload.sample.json`);
