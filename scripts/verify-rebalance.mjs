#!/usr/bin/env node
// ADVERSARIAL VERIFICATION of the three candidate rebalances, on the REAL catalog.
// Faithful JS ports of each branch's Swift scorer. Nothing here ships.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { genreCategory } from './build-rec-features.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, '..', 'public');
const INDEXES = ['current-index.json', 'apple-music-index.json', 'digital-index.json'];

const songs = [];
for (const file of INDEXES) {
  const p = join(PUBLIC, file);
  if (!existsSync(p)) continue;
  const doc = JSON.parse(readFileSync(p, 'utf8'));
  const albums = new Map((doc.albums || []).map((a) => [a.id, a]));
  for (const s of doc.songs || []) {
    const al = albums.get(s.albumId);
    const g = al?.genre ? genreCategory(al.genre) : null;
    const y = Number(s.year ?? al?.year);
    const bpm = Number(s.bpm);
    songs.push({
      id: s.id,
      artist: artistKey(s.artist || ''),
      genre: g,
      year: Number.isFinite(y) && y > 0 ? y : null,
      bpm: Number.isFinite(bpm) && bpm > 0 ? bpm : null,
      camelot: typeof s.camelot === 'string' && s.camelot ? s.camelot.trim().toUpperCase() : null,
      src: file,
    });
  }
}
function artistKey(a) {
  let s = a.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  if (s.startsWith('the ')) s = s.slice(4);
  return s;
}
const N = songs.length;
const analyzed = (s) => !!(s.bpm || s.camelot);
const BASE_ANALYZED = songs.filter(analyzed).length / N;
console.log(`catalog ${N.toLocaleString()} songs · analyzed (bpm or camelot) ${(100 * BASE_ANALYZED).toFixed(2)}%`);

// ── profile ─────────────────────────────────────────────────────────────────────
function buildProfile(seed) {
  const artistShare = new Map(), genreShare = new Map();
  const years = [], bpms = [], camelots = new Set();
  let n = 0;
  for (const s of seed) {
    n++;
    artistShare.set(s.artist, (artistShare.get(s.artist) || 0) + 1);
    if (s.genre) genreShare.set(s.genre, (genreShare.get(s.genre) || 0) + 1);
    if (s.year) years.push(s.year);
    if (s.bpm) bpms.push(s.bpm);
    if (s.camelot) camelots.add(s.camelot);
  }
  for (const [k, v] of artistShare) artistShare.set(k, v / n);
  for (const [k, v] of genreShare) genreShare.set(k, v / n);
  const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
  const sd = (a, m) => Math.sqrt(a.reduce((x, y) => x + (y - m) * (y - m), 0) / a.length);
  const ym = years.length ? mean(years) : null;
  const bm = bpms.length ? mean(bpms) : null;
  return {
    artistShare, maxArtist: artistShare.size ? Math.max(...artistShare.values()) : 0,
    genreShare, maxGenre: genreShare.size ? Math.max(...genreShare.values()) : 0,
    yearMean: ym, yearSigma: years.length ? Math.max(8, sd(years, ym)) : 8,
    bpmMean: bm, bpmSigma: bpms.length ? Math.max(8, sd(bpms, bm)) : 8,
    camelots,
  };
}

// ── shared sub-terms ────────────────────────────────────────────────────────────
const aT = (s, p) => Math.min(1, (p.artistShare.get(s.artist) || 0) / Math.max(0.05, p.maxArtist));
const gT = (s, p) => (p.maxGenre > 0 ? Math.min(1, (s.genre ? p.genreShare.get(s.genre) || 0 : 0) / p.maxGenre) : 0);
const yT = (s, p) => (p.yearMean != null && s.year ? Math.exp(-Math.abs(s.year - p.yearMean) / Math.max(8, p.yearSigma)) : 0);
function camAff(code, set) {
  if (!code || !set.size) return 0;
  const m = /^(\d{1,2})([AB])$/.exec(code);
  if (!m) return 0;
  const n = Number(m[1]), l = m[2];
  if (n < 1 || n > 12) return 0;
  if (set.has(`${n}${l}`)) return 1;
  if (set.has(`${n}${l === 'A' ? 'B' : 'A'}`)) return 0.75;
  const up = (n % 12) + 1, down = ((n + 10) % 12) + 1;
  if (set.has(`${up}${l}`) || set.has(`${down}${l}`)) return 0.6;
  return 0;
}
// exact-distance bpm (main, B1, B2)
const bpmPlain = (bpm, mean, sigma) => (bpm && mean ? Math.exp(-Math.abs(bpm - mean) / Math.max(6, sigma)) : 0);
// metrical bpm (B3)
function bpmMetrical(bpm, mean, sigma) {
  if (!bpm || !mean) return 0;
  const s = Math.max(6, sigma);
  const rel = [[bpm, 1], [bpm / 2, 1], [bpm * 2, 1], [(bpm * 2) / 3, 0.6], [(bpm * 3) / 2, 0.6]];
  let best = 0;
  for (const [c, k] of rel) best = Math.max(best, k * Math.exp(-Math.abs(c - mean) / s));
  return Math.min(1, best);
}

// ── BASE (main): PuzzleSimilarity.score, artist/genre/year only ─────────────────
const W = { artist: 0.30, genre: 0.25, year: 0.15 };
function scoreBase(s, p) {
  let local = 0, den = 0;
  if (p.artistShare.size) { local += W.artist * aT(s, p); den += W.artist; }
  if (p.genreShare.size && p.maxGenre > 0) { local += W.genre * gT(s, p); den += W.genre; }
  if (p.yearMean != null) { den += W.year; if (s.year) local += W.year * yT(s, p); }
  return den > 0 ? Math.min(1, Math.max(0, local / den)) : 0;
}
// main's aux multiplier, tempo/key half only (dormancy/familiarity held constant)
function auxMain(s, p, dorm, fam) {
  const wd = 0.40, wf = 0.30, wm = 0.30;
  let num = dorm * wd + fam * wf, den = wd + wf;
  const fit = musicalFitPlain(s, p);
  if (!p.bpmMean && !p.camelots.size) return den > 0 ? num / den : 0;
  if (fit != null) { num += wm * fit; den += wm; }
  return den > 0 ? num / den : 0;
}
function musicalFitPlain(s, p) {
  const t = [];
  if (p.bpmMean != null && s.bpm) t.push(bpmPlain(s.bpm, p.bpmMean, p.bpmSigma));
  if (p.camelots.size && s.camelot) t.push(camAff(s.camelot, p.camelots));
  return t.length ? t.reduce((a, b) => a + b, 0) / t.length : null;
}
function musicalFitMetrical(s, p) {
  const t = [];
  if (p.bpmMean != null && s.bpm) t.push(bpmMetrical(s.bpm, p.bpmMean, p.bpmSigma));
  if (p.camelots.size && s.camelot) t.push(camAff(s.camelot, p.camelots));
  return t.length ? t.reduce((a, b) => a + b, 0) / t.length : null;
}

// ── B1: RecSimilarity.score (1:1:1, per-song mean WITHIN each family) ───────────
function availB1(p, catalogHasMusical) {
  return {
    artist: p.artistShare.size > 0,
    genreYear: p.yearMean != null,
    genreMusical: catalogHasMusical && (p.bpmMean != null || p.camelots.size > 0),
  };
}
function scoreB1(s, p, av, w = { artist: 1, genreYear: 1, genreMusical: 1 }) {
  const den = (av.artist ? w.artist : 0) + (av.genreYear ? w.genreYear : 0) + (av.genreMusical ? w.genreMusical : 0);
  if (den <= 0) return 0;
  let total = 0;
  if (av.artist && p.artistShare.size) total += w.artist * aT(s, p);
  const g = p.maxGenre > 0 && s.genre ? Math.min(1, (p.genreShare.get(s.genre) || 0) / p.maxGenre) : null;
  const mean = (arr) => { const v = arr.filter((x) => x != null); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };
  const year = p.yearMean != null && s.year ? Math.exp(-Math.abs(s.year - p.yearMean) / Math.max(8, p.yearSigma)) : null;
  if (av.genreYear) { const b = mean([g, year]); if (b != null) total += w.genreYear * b; }
  if (av.genreMusical) {
    const b = p.bpmMean != null && s.bpm ? bpmPlain(s.bpm, p.bpmMean, p.bpmSigma) : null;
    const k = p.camelots.size && s.camelot ? camAff(s.camelot, p.camelots) : null;
    const c = mean([g, b, k]);
    if (c != null) total += w.genreMusical * c;
  }
  return Math.min(1, Math.max(0, total / den));
}

// ── B2: PuzzleSimilarity.familyScore (.30/.30/.30 + .10 context, sonicGenre .5) ─
function scoreB2(s, p, w = { artist: 0.30, era: 0.30, sonic: 0.30, context: 0.10, sonicGenreShare: 0.5 }) {
  let num = 0, den = 0;
  if (p.artistShare.size) { num += w.artist * aT(s, p); den += w.artist; }
  const hasGenre = p.genreShare.size > 0 && p.maxGenre > 0;
  const hasYear = p.yearMean != null, hasBpm = p.bpmMean != null, hasKey = p.camelots.size > 0;
  if (hasGenre || hasYear) {
    let n = 0, d = 0;
    if (hasGenre) { n += gT(s, p); d += 1; }
    if (hasYear) { n += yT(s, p); d += 1; }
    num += w.era * (n / d); den += w.era;
  }
  if (hasGenre || hasBpm || hasKey) {
    const mus = Math.max(0, (1 - w.sonicGenreShare) / 2);
    let n = 0, d = 0;
    if (hasGenre) { n += w.sonicGenreShare * gT(s, p); d += w.sonicGenreShare; }
    if (hasBpm) { n += mus * bpmPlain(s.bpm, p.bpmMean, p.bpmSigma); d += mus; }
    if (hasKey) { n += mus * camAff(s.camelot, p.camelots); d += mus; }
    if (d > 0) { num += w.sonic * (n / d); den += w.sonic; }
  }
  // context family: nothing live in this harness (no co-member / lyrics / co-play / recency)
  return den > 0 ? Math.min(1, Math.max(0, num / den)) : 0;
}

// ── B3: PuzzleSimilarity.score with SimilarityFamilies term weights ────────────
const FAMILY_TOTAL = 0.30 + 0.25 + 0.15;
function termWeights(balance, hasGenre, hasYear, hasMusical, total = FAMILY_TOTAL) {
  let artist = balance.artist, genre = 0, year = 0, musical = 0;
  const bLive = (hasGenre ? 1 : 0) + (hasYear ? 1 : 0);
  if (bLive > 0) { const e = balance.genreYear / bLive; if (hasGenre) genre += e; if (hasYear) year += e; }
  const cLive = (hasGenre ? 1 : 0) + (hasMusical ? 1 : 0);
  if (cLive > 0) { const e = balance.genreMusical / cLive; if (hasGenre) genre += e; if (hasMusical) musical += e; }
  const sum = artist + genre + year + musical;
  if (sum <= 0) return { artist: 0, genre: 0, year: 0, musical: 0 };
  const k = total / sum;
  return { artist: artist * k, genre: genre * k, year: year * k, musical: musical * k };
}
const NEUTRAL = 0.40;
function scoreB3(s, p, t) {
  let local = 0, den = 0;
  if (p.artistShare.size) { local += t.artist * aT(s, p); den += t.artist; }
  if (p.genreShare.size && p.maxGenre > 0) { local += t.genre * gT(s, p); den += t.genre; }
  if (p.yearMean != null) { den += t.year; if (s.year) local += t.year * yT(s, p); }
  den += t.musical;
  if (t.musical > 0) {
    const fit = musicalFitMetrical(s, p);
    local += t.musical * (fit == null ? NEUTRAL : fit);
  }
  return den > 0 ? Math.min(1, Math.max(0, local / den)) : 0;
}

// ── seeds ───────────────────────────────────────────────────────────────────────
let rng = 20260809;
const rand = () => ((rng = (rng * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const SEEDS = Number(process.argv.includes('--seeds') ? process.argv[process.argv.indexOf('--seeds') + 1] : 40);

const top = (rows, k = 90) => rows.slice().sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, k);

const results = {};
const SCORERS = ['base', 'B1', 'B2', 'B2+aux', 'B3'];
for (const k of SCORERS) results[k] = { analyzedTop90: [], analyzedTop500: [], srcTop90: {}, seedArtist: [], surv: { A: [], B: [], C: [] } };
const jac = (a, b) => { const B = new Set(b); let i = 0; for (const x of a) if (B.has(x)) i++; return i / (a.length + b.length - i); };

// ablation: same song, with vs without bpm/camelot
const ablation = {}; for (const k of SCORERS) ablation[k] = [];
const matched = {}; for (const k of SCORERS) matched[k] = { yes: [], no: [] };

rng = 20260809;
for (let t = 0; t < SEEDS; t++) {
  const anchor = songs[Math.floor(rand() * N)];
  const sameArtist = songs.filter((s) => s.artist === anchor.artist).slice(0, 8);
  const seed = [...sameArtist];
  while (seed.length < 25) seed.push(songs[Math.floor(rand() * N)]);
  const p = buildProfile(seed);
  const av = availB1(p, true);
  const tw = termWeights({ artist: 1 / 3, genreYear: 1 / 3, genreMusical: 1 / 3 },
    p.genreShare.size > 0, p.yearMean != null, p.bpmMean != null || p.camelots.size > 0);

  const rows = { base: [], B1: [], B2: [], 'B2+aux': [], B3: [] };
  for (const s of songs) {
    const b = scoreBase(s, p);
    rows.base.push([s.id, b, s]);
    rows.B1.push([s.id, scoreB1(s, p, av), s]);
    const s2 = scoreB2(s, p);
    rows.B2.push([s.id, s2, s]);
    // B2's shipped pipeline: sim × (1 + 0.6·aux) with the tempo/key term STILL in aux.
    rows['B2+aux'].push([s.id, s2 * (1 + 0.6 * auxMain(s, p, 0.5, 0.5)), s]);
    rows.B3.push([s.id, scoreB3(s, p, tw), s]);
  }
  // Common yardstick: each family scored ALONE, same definition for every branch, so
  // "survival" means the same thing across the table.
  const soloA = [], soloB = [], soloC = [];
  for (const s of songs) {
    soloA.push([s.id, aT(s, p)]);
    const yr = p.yearMean != null && s.year ? yT(s, p) : null;
    soloB.push([s.id, yr == null ? gT(s, p) : (gT(s, p) + yr) / 2]);
    const mf = musicalFitMetrical(s, p);
    soloC.push([s.id, (gT(s, p) + (mf == null ? NEUTRAL : mf)) / 2]);
  }
  const soloTop = { A: top(soloA).map((r) => r[0]), B: top(soloB).map((r) => r[0]), C: top(soloC).map((r) => r[0]) };
  const seedArtists = new Set(seed.map((s) => s.artist));

  for (const k of SCORERS) {
    const t90 = top(rows[k], 90), t500 = top(rows[k], 500);
    results[k].analyzedTop90.push(t90.filter((r) => analyzed(r[2])).length / 90);
    results[k].analyzedTop500.push(t500.filter((r) => analyzed(r[2])).length / 500);
    results[k].seedArtist.push(t90.filter((r) => seedArtists.has(r[2].artist)).length / 90);
    const ids = t90.map((r) => r[0]);
    for (const f of ['A', 'B', 'C']) results[k].surv[f].push(jac(ids, soloTop[f]));
    for (const r of t90) results[k].srcTop90[r[2].src] = (results[k].srcTop90[r[2].src] || 0) + 1;
  }

  // ── HEAD-TO-HEAD at a STRONG genre match: the only comparison the top of a queue makes.
  // Two songs, identical genre fit, one analyzed and one not. Who wins?
  for (const s of songs) {
    if (gT(s, p) < 0.99) continue;
    const bucket = analyzed(s) ? 'yes' : 'no';
    for (const k of SCORERS) {
      const v = k === 'base' ? scoreBase(s, p)
        : k === 'B1' ? scoreB1(s, p, av)
        : k === 'B2' ? scoreB2(s, p)
        : k === 'B2+aux' ? scoreB2(s, p) * (1 + 0.6 * auxMain(s, p, 0.5, 0.5))
        : scoreB3(s, p, tw);
      (matched[k][bucket] ||= []).push(v);
    }
  }

  // ── ABLATION: pick 400 songs that DO carry bpm+camelot, score them as-is and with the
  // musical fields stripped. Positive delta ⇒ the branch REWARDS missing metadata.
  const withData = songs.filter(analyzed);
  for (let i = 0; i < 200; i++) {
    const s = withData[Math.floor(rand() * withData.length)];
    const stripped = { ...s, bpm: null, camelot: null };
    ablation.base.push(scoreBase(stripped, p) - scoreBase(s, p));
    ablation.B1.push(scoreB1(stripped, p, av) - scoreB1(s, p, av));
    ablation.B2.push(scoreB2(stripped, p) - scoreB2(s, p));
    ablation['B2+aux'].push(
      scoreB2(stripped, p) * (1 + 0.6 * auxMain(stripped, p, 0.5, 0.5))
      - scoreB2(s, p) * (1 + 0.6 * auxMain(s, p, 0.5, 0.5)));
    ablation.B3.push(scoreB3(stripped, p, tw) - scoreB3(s, p, tw));
  }
}
const avg = (a) => a.reduce((x, y) => x + y, 0) / a.length;

console.log(`\n════ TOP-OF-QUEUE COMPOSITION (${SEEDS} seeds) ══════════════════════════════`);
console.log(`  base rate of analyzed (bpm/key-bearing) songs in the catalog: ${(100 * BASE_ANALYZED).toFixed(2)}%`);
console.log('  scorer     analyzed share of top-90   of top-500     lift vs base');
for (const k of SCORERS) {
  const a90 = avg(results[k].analyzedTop90), a500 = avg(results[k].analyzedTop500);
  console.log(`  ${k.padEnd(9)} ${(100 * a90).toFixed(1).padStart(10)}%  ${(100 * a500).toFixed(1).padStart(12)}%  ${(a90 / BASE_ANALYZED).toFixed(2).padStart(12)}×`);
}
console.log('\n  IS IT STILL ARTIST-BASED?  (common family yardstick, identical for every branch)');
console.log('  scorer     top-90 by a SEED artist   survival vs solo A   vs solo B   vs solo C');
for (const k of SCORERS) {
  const r = results[k];
  console.log(`  ${k.padEnd(9)} ${(100 * avg(r.seedArtist)).toFixed(1).padStart(20)}%  ${avg(r.surv.A).toFixed(3).padStart(17)}  ${avg(r.surv.B).toFixed(3).padStart(10)}  ${avg(r.surv.C).toFixed(3).padStart(10)}`);
}

console.log('\n  top-90 picks by source index:');
for (const k of SCORERS) {
  const s = results[k].srcTop90; const tot = Object.values(s).reduce((a, b) => a + b, 0);
  console.log(`  ${k.padEnd(9)} ${Object.entries(s).map(([f, n]) => `${f.replace('-index.json', '')} ${(100 * n / tot).toFixed(1)}%`).join('  ')}`);
}

console.log(`\n════ ABLATION: strip bpm+camelot from a song that HAS them ══════════════════`);
console.log('  Δscore = score(no bpm/key) − score(with bpm/key).  >0 ⇒ missing metadata is REWARDED,');
console.log('  <0 ⇒ missing metadata is PENALIZED (buried).  ≈0 ⇒ neutral / renormalized.');
console.log('  scorer      mean Δ     median Δ    p10 Δ      p90 Δ    %rewarded  %penalized');
for (const k of SCORERS) {
  const a = ablation[k].slice().sort((x, y) => x - y);
  const q = (f) => a[Math.floor(a.length * f)];
  const rew = a.filter((x) => x > 1e-9).length / a.length, pen = a.filter((x) => x < -1e-9).length / a.length;
  console.log(`  ${k.padEnd(9)} ${avg(a).toFixed(4).padStart(9)} ${q(0.5).toFixed(4).padStart(11)} ${q(0.1).toFixed(4).padStart(10)} ${q(0.9).toFixed(4).padStart(10)}  ${(100 * rew).toFixed(1).padStart(8)}%  ${(100 * pen).toFixed(1).padStart(9)}%`);
}

// ── SYNTHETIC CEILING: the structural question, free of catalog noise ─────────────
{
  console.log(`\n════ STRUCTURAL CEILING (one synthetic profile, hand-built candidates) ══════`);
  const seedSongs = [
    { id: 'x1', artist: 'seedartist', genre: 'hip-hop', year: 2000, bpm: 96, camelot: '8A' },
    { id: 'x2', artist: 'seedartist', genre: 'hip-hop', year: 2001, bpm: 98, camelot: '8A' },
    { id: 'x3', artist: 'other', genre: 'hip-hop', year: 1999, bpm: 94, camelot: '9A' },
    { id: 'x4', artist: 'other2', genre: 'soul', year: 2002, bpm: 100, camelot: '8B' },
  ];
  const p = buildProfile(seedSongs);
  const av = availB1(p, true);
  const tw = termWeights({ artist: 1 / 3, genreYear: 1 / 3, genreMusical: 1 / 3 }, true, true, true);
  const cases = [
    ['artist+genre+year perfect, NO bpm/key data   ', { artist: 'seedartist', genre: 'hip-hop', year: 2000, bpm: null, camelot: null }],
    ['artist+genre+year perfect, bpm/key PERFECT   ', { artist: 'seedartist', genre: 'hip-hop', year: 2000, bpm: 97, camelot: '8A' }],
    ['artist+genre+year perfect, bpm/key WRONG     ', { artist: 'seedartist', genre: 'hip-hop', year: 2000, bpm: 175, camelot: '3B' }],
    ['genre perfect only,        NO bpm/key data   ', { artist: 'nobody', genre: 'hip-hop', year: 1930, bpm: null, camelot: null }],
    ['genre perfect only,        bpm/key PERFECT   ', { artist: 'nobody', genre: 'hip-hop', year: 1930, bpm: 97, camelot: '8A' }],
    ['genre perfect only,        bpm/key WRONG     ', { artist: 'nobody', genre: 'hip-hop', year: 1930, bpm: 175, camelot: '3B' }],
    ['no genre at all,           bpm/key PERFECT   ', { artist: 'nobody', genre: null, year: 1930, bpm: 97, camelot: '8A' }],
  ];
  console.log('  candidate                                        base      B1      B2      B3');
  for (const [label, c] of cases) {
    const s = { id: 'c', ...c };
    console.log(`  ${label}  ${scoreBase(s, p).toFixed(3).padStart(6)}  ${scoreB1(s, p, av).toFixed(3).padStart(6)}  ${scoreB2(s, p).toFixed(3).padStart(6)}  ${scoreB3(s, p, tw).toFixed(3).padStart(6)}`);
  }
  console.log('\n  bpm distance curve (profile mean 97, sigma floored at 8) — real distance or exact match?');
  console.log('  candidate bpm   B1/B2 term   B3 term');
  for (const b of [97, 100, 110, 130, 145, 194, 48.5, 64.7]) {
    console.log(`  ${String(b).padStart(13)}   ${bpmPlain(b, p.bpmMean, p.bpmSigma).toFixed(3).padStart(10)}   ${bpmMetrical(b, p.bpmMean, p.bpmSigma).toFixed(3).padStart(7)}`);
  }
  console.log('\n  camelot affinity from a profile holding {8A, 9A, 8B} (all branches share this):');
  for (const c of ['8A', '8B', '9A', '7A', '10A', '3B', 'bogus']) {
    console.log(`    ${c.padEnd(6)} ${camAff(c, p.camelots).toFixed(2)}`);
  }
}

console.log(`\n════ HEAD-TO-HEAD at an IDENTICAL, PERFECT genre match ══════════════════════`);
console.log('  Every candidate whose genre fit is 1.0 — the songs that actually compete for the top');
console.log('  of a tile. Analyzed = carries bpm/camelot; unanalyzed = does not.');
console.log('  scorer     n(analyzed)  mean   p90    max   |  n(unanalyzed)  mean   p90    max   | ceiling gap');
for (const k of SCORERS) {
  const y = matched[k].yes.slice().sort((a, b) => a - b), n = matched[k].no.slice().sort((a, b) => a - b);
  if (!y.length || !n.length) continue;
  const q = (a, f) => a[Math.min(a.length - 1, Math.floor(a.length * f))];
  console.log(`  ${k.padEnd(9)} ${String(y.length).padStart(11)} ${avg(y).toFixed(3)} ${q(y, 0.9).toFixed(3)} ${y[y.length - 1].toFixed(3)}  | ${String(n.length).padStart(13)} ${avg(n).toFixed(3)} ${q(n, 0.9).toFixed(3)} ${n[n.length - 1].toFixed(3)}  | ${(y[y.length - 1] - n[n.length - 1] >= 0 ? '+' : '')}${(y[y.length - 1] - n[n.length - 1]).toFixed(3)}`);
}
