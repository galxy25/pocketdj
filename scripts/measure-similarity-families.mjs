#!/usr/bin/env node
// MEASURE the three similarity families on the REAL catalog before choosing their weights.
//
// The owner asked for recommendations balanced "evenly" across
//   A. artist            B. genre + year            C. genre + bpm + key/camelot
// but "evenly by WEIGHT" is not "evenly by EFFECT": a family whose fields are only 40% covered,
// or that fires for 60% of the library, does not move a ranking as much as its weight suggests.
// This script produces the numbers that decision has to be made from:
//
//   1. COVERAGE      — what share of songs can each field speak at all.
//   2. GENRE LABELS  — the raw-label variants ("Hip-Hop/Rap" vs "Hip Hop/Rap") and what they
//                      collapse to under the shipped `Genre.category` matcher.
//   3. DISCRIMINATION— per family, over random seed profiles: selectivity (share of the catalog
//                      that scores at all), the score distribution, and Gini — how much of the
//                      family's total score mass sits in how few songs.
//   4. INDEPENDENCE  — Jaccard overlap of each family's top-500 against the others. Two families
//                      that agree are one family with extra steps.
//   5. EFFECT        — with EQUAL weights, each family's realized share of the blended score, and
//                      the coverage-corrected weights that would equalize it.
//
//   node scripts/measure-similarity-families.mjs [--seeds 40] [--json out.json]

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { genreCategory } from './build-rec-features.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, '..', 'public');
const INDEXES = ['current-index.json', 'apple-music-index.json', 'digital-index.json'];

const arg = (flag, dflt) => {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
};
const SEEDS = Number(arg('--seeds', 40));
const JSON_OUT = arg('--json', null);

// ── Load ────────────────────────────────────────────────────────────────────────────────────────
const songs = [];
const rawGenreCount = new Map();
for (const file of INDEXES) {
  const p = join(PUBLIC, file);
  if (!existsSync(p)) continue;
  const doc = JSON.parse(readFileSync(p, 'utf8'));
  const albums = new Map((doc.albums || []).map((a) => [a.id, a]));
  for (const s of doc.songs || []) {
    const al = albums.get(s.albumId);
    const rawGenre = al?.genre ?? null;
    if (rawGenre) rawGenreCount.set(rawGenre, (rawGenreCount.get(rawGenre) || 0) + 1);
    songs.push({
      id: s.id,
      artist: artistKey(s.artist || ''),
      genre: rawGenre ? genreCategory(rawGenre) : null,
      rawGenre,
      year: num(s.year ?? al?.year),
      bpm: num(s.bpm),
      camelot: typeof s.camelot === 'string' && s.camelot ? s.camelot.toUpperCase() : null,
      source: file,
    });
  }
}
function num(v) { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; }
function artistKey(a) {
  let s = a.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  if (s.startsWith('the ')) s = s.slice(4);
  return s;
}

const N = songs.length;
const pct = (n) => `${((100 * n) / N).toFixed(1)}%`;

// ── 1. Coverage ─────────────────────────────────────────────────────────────────────────────────
const cov = {
  artist: songs.filter((s) => s.artist).length,
  genre: songs.filter((s) => s.genre).length,
  year: songs.filter((s) => s.year).length,
  bpm: songs.filter((s) => s.bpm).length,
  camelot: songs.filter((s) => s.camelot).length,
  bpmOrCamelot: songs.filter((s) => s.bpm || s.camelot).length,
  bpmAndCamelot: songs.filter((s) => s.bpm && s.camelot).length,
};
// A family can only speak when EVERY field it is made of can.
const famCov = {
  A_artist: cov.artist,
  B_genreYear: songs.filter((s) => s.genre && s.year).length,
  C_genreMusical: songs.filter((s) => s.genre && (s.bpm || s.camelot)).length,
};

console.log('════ 1. COVERAGE ════════════════════════════════════════════════════════════');
console.log(`catalog: ${N.toLocaleString()} songs from ${INDEXES.filter((f) => existsSync(join(PUBLIC, f))).join(', ')}`);
for (const [k, v] of Object.entries(cov)) console.log(`  ${k.padEnd(16)} ${String(v).padStart(7)}  ${pct(v)}`);
console.log('  ── family-level (every field the family needs) ──');
for (const [k, v] of Object.entries(famCov)) console.log(`  ${k.padEnd(16)} ${String(v).padStart(7)}  ${pct(v)}`);
const perSource = {};
for (const s of songs) {
  const b = (perSource[s.source] ||= { n: 0, bpm: 0, camelot: 0, genre: 0, year: 0 });
  b.n++; if (s.bpm) b.bpm++; if (s.camelot) b.camelot++; if (s.genre) b.genre++; if (s.year) b.year++;
}
console.log('  ── by source ──');
for (const [src, b] of Object.entries(perSource)) {
  const p = (x) => `${((100 * x) / b.n).toFixed(1)}%`;
  console.log(`  ${src.padEnd(24)} n=${String(b.n).padStart(6)}  genre ${p(b.genre).padStart(6)}  year ${p(b.year).padStart(6)}  bpm ${p(b.bpm).padStart(6)}  camelot ${p(b.camelot).padStart(6)}`);
}

// ── 2. Genre labels ─────────────────────────────────────────────────────────────────────────────
console.log('\n════ 2. GENRE LABELS ════════════════════════════════════════════════════════');
const rawSorted = [...rawGenreCount.entries()].sort((a, b) => b[1] - a[1]);
console.log(`  distinct RAW album-genre strings: ${rawGenreCount.size}`);
console.log('  top 12 raw labels:');
for (const [g, n] of rawSorted.slice(0, 12)) console.log(`    ${String(n).padStart(6)}  ${g}  →  ${genreCategory(g)}`);
// Punctuation/space variants that are the SAME label modulo separators.
const byNorm = new Map();
for (const [g, n] of rawSorted) {
  const k = g.toLowerCase().replace(/[^a-z0-9]/g, '');
  if (!byNorm.has(k)) byNorm.set(k, []);
  byNorm.get(k).push([g, n]);
}
const variantGroups = [...byNorm.values()].filter((v) => v.length > 1);
console.log(`  raw labels that are punctuation variants of another: ${variantGroups.reduce((a, v) => a + v.length, 0)} in ${variantGroups.length} groups`);
for (const g of variantGroups.sort((a, b) => b.reduce((x, y) => x + y[1], 0) - a.reduce((x, y) => x + y[1], 0)).slice(0, 6)) {
  console.log(`    ${g.map(([l, n]) => `"${l}"(${n})`).join(' ≡ ')}  →  ${[...new Set(g.map(([l]) => genreCategory(l)))].join('/')}`);
}
const catCount = new Map();
for (const s of songs) if (s.genre) catCount.set(s.genre, (catCount.get(s.genre) || 0) + 1);
console.log('  → after Genre.category collapse:');
for (const [c, n] of [...catCount.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(`    ${String(n).padStart(6)}  ${pct(n).padStart(6)}  ${c}`);
}
const top = [...catCount.values()].sort((a, b) => b - a);
console.log(`  concentration: top category ${pct(top[0])}, top 2 ${pct(top[0] + top[1])}, top 3 ${pct(top[0] + top[1] + top[2])}`);

// ── 3+4. Per-family discrimination + independence ───────────────────────────────────────────────
// The family scorers, matching what the Swift `SimilarityFamilies` implements.
function camelotAffinity(code, set) {
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
function bpmAffinity(bpm, mean, sigma) {
  if (!bpm || !mean) return 0;
  // half/double time: the closest of bpm, bpm/2, bpm*2 (a 140 track and a 70 track ARE mixable).
  const cands = [bpm, bpm / 2, bpm * 2, (bpm * 2) / 3, (bpm * 3) / 2];
  let best = 0;
  for (const c of cands) best = Math.max(best, Math.exp(-Math.abs(c - mean) / Math.max(6, sigma)));
  return best;
}
function buildProfile(seed) {
  const artistShare = new Map(); let n = 0;
  const genreShare = new Map();
  const years = []; const bpms = []; const camelots = new Set();
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
    artistShare, maxArtist: Math.max(...artistShare.values()),
    genreShare, maxGenre: genreShare.size ? Math.max(...genreShare.values()) : 0,
    yearMean: ym, yearSigma: years.length ? Math.max(8, sd(years, ym)) : 8,
    bpmMean: bm, bpmSigma: bpms.length ? Math.max(6, sd(bpms, bm)) : 6,
    camelots,
  };
}
const famA = (s, p) => Math.min(1, (p.artistShare.get(s.artist) || 0) / Math.max(0.05, p.maxArtist));
function famB(s, p) {
  const parts = [];
  if (p.maxGenre > 0) parts.push(s.genre ? Math.min(1, (p.genreShare.get(s.genre) || 0) / p.maxGenre) : 0);
  if (p.yearMean != null) parts.push(s.year ? Math.exp(-Math.abs(s.year - p.yearMean) / p.yearSigma) : null);
  const live = parts.filter((x) => x != null);
  return live.length ? live.reduce((a, b) => a + b, 0) / live.length : null;
}
function famC(s, p) {
  const parts = [];
  if (p.maxGenre > 0) parts.push(s.genre ? Math.min(1, (p.genreShare.get(s.genre) || 0) / p.maxGenre) : 0);
  if (p.bpmMean != null && s.bpm) parts.push(bpmAffinity(s.bpm, p.bpmMean, p.bpmSigma));
  if (p.camelots.size && s.camelot) parts.push(camelotAffinity(s.camelot, p.camelots));
  // musical half absent entirely on this song ⇒ the family cannot speak (renormalize, not zero).
  if (!s.bpm && !s.camelot) return null;
  return parts.length ? parts.reduce((a, b) => a + b, 0) / parts.length : null;
}

function gini(xs) {
  const a = xs.filter((x) => x > 0).sort((x, y) => x - y);
  if (!a.length) return 0;
  let cum = 0, s = 0;
  for (let i = 0; i < a.length; i++) { cum += a[i]; s += cum; }
  return (a.length + 1 - (2 * s) / cum) / a.length;
}
const jaccard = (a, b) => {
  const B = new Set(b); let i = 0;
  for (const x of a) if (B.has(x)) i++;
  return i / (a.length + b.length - i);
};

// Deterministic RNG so the report is reproducible.
let rng = 20260809;
const rand = () => ((rng = (rng * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);

console.log('\n════ 3. DISCRIMINATION (per family, over random 25-song seed profiles) ══════');
const acc = { A: [], B: [], C: [] };
const overlap = { AB: [], AC: [], BC: [] };
const effect = { A: [], B: [], C: [] };
for (let t = 0; t < SEEDS; t++) {
  // A realistic seed: one artist binge + a spread, the shape a week of listening has.
  const anchor = songs[Math.floor(rand() * N)];
  const sameArtist = songs.filter((s) => s.artist === anchor.artist).slice(0, 8);
  const seed = [...sameArtist];
  while (seed.length < 25) seed.push(songs[Math.floor(rand() * N)]);
  const p = buildProfile(seed);

  const scored = { A: [], B: [], C: [] };
  const sums = { A: 0, B: 0, C: 0 };
  const live = { A: 0, B: 0, C: 0 };
  for (const s of songs) {
    const a = famA(s, p), b = famB(s, p), c = famC(s, p);
    scored.A.push([s.id, a]); sums.A += a; live.A++;
    if (b != null) { scored.B.push([s.id, b]); sums.B += b; live.B++; }
    if (c != null) { scored.C.push([s.id, c]); sums.C += c; live.C++; }
  }
  for (const k of ['A', 'B', 'C']) {
    const vals = scored[k].map((x) => x[1]);
    const nonzero = vals.filter((v) => v > 0.001).length;
    const strong = vals.filter((v) => v > 0.5).length;
    acc[k].push({
      selectivity: nonzero / N, strong: strong / N,
      mean: sums[k] / Math.max(1, live[k]), gini: gini(vals), speaks: live[k] / N,
    });
    effect[k].push(sums[k] / Math.max(1, live[k]));
  }
  const topOf = (k) => scored[k].sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1)).slice(0, 500).map((x) => x[0]);
  const tA = topOf('A'), tB = topOf('B'), tC = topOf('C');
  overlap.AB.push(jaccard(tA, tB)); overlap.AC.push(jaccard(tA, tC)); overlap.BC.push(jaccard(tB, tC));
}
const avg = (a) => a.reduce((x, y) => x + y, 0) / a.length;
const names = { A: 'A artist', B: 'B genre+year', C: 'C genre+bpm+key' };
console.log('  family            speaks   selectivity   share>0.5    mean     gini');
for (const k of ['A', 'B', 'C']) {
  const m = acc[k];
  console.log(`  ${names[k].padEnd(18)}${(100 * avg(m.map((x) => x.speaks))).toFixed(1).padStart(5)}%  ${(100 * avg(m.map((x) => x.selectivity))).toFixed(2).padStart(9)}%  ${(100 * avg(m.map((x) => x.strong))).toFixed(2).padStart(9)}%  ${avg(m.map((x) => x.mean)).toFixed(4).padStart(7)}  ${avg(m.map((x) => x.gini)).toFixed(3).padStart(6)}`);
}

console.log('\n════ 4. INDEPENDENCE (Jaccard of top-500 picks) ═════════════════════════════');
console.log(`  A vs B: ${avg(overlap.AB).toFixed(4)}   A vs C: ${avg(overlap.AC).toFixed(4)}   B vs C: ${avg(overlap.BC).toFixed(4)}`);

console.log('\n════ 5. EFFECT AT EQUAL WEIGHTS ═════════════════════════════════════════════');
const meanA = avg(effect.A), meanB = avg(effect.B), meanC = avg(effect.C);
const tot = meanA + meanB + meanC;
console.log(`  mean per-song contribution at w=1/3 each →  A ${(100 * meanA / tot).toFixed(1)}%  B ${(100 * meanB / tot).toFixed(1)}%  C ${(100 * meanC / tot).toFixed(1)}%`);
const inv = { A: 1 / meanA, B: 1 / meanB, C: 1 / meanC };
const invTot = inv.A + inv.B + inv.C;
console.log(`  weights that EQUALIZE realized influence →  A ${(inv.A / invTot).toFixed(3)}  B ${(inv.B / invTot).toFixed(3)}  C ${(inv.C / invTot).toFixed(3)}`);
console.log('  (equalizing the MEAN would hand the rarest-firing family the biggest weight and make');
console.log('   it dominate the TOP of the ranking, which is the only part a 90-song queue reads —');
console.log('   see the note in SimilarityFamilies.swift for the weights actually shipped.)');

// ── 6. WHAT "EVENLY" HAS TO MEAN: the top of the ranking ────────────────────────────────────────
// A 90-song queue only ever reads the TOP of the ranking, so the honest balance metric is not the
// mean contribution (section 5) but: of the songs that actually get picked, how many are there
// because of each family. Two readouts per candidate weight vector:
//   ATTRIBUTION — the family holding the largest weighted term for that pick.
//   SURVIVAL    — Jaccard(blended top-90, that family's SOLO top-90): how much of what the family
//                 wanted actually survived the blend.
console.log('\n════ 6. TOP-OF-RANKING BALANCE (the metric that matters for a 90-song queue) ═');
const CANDIDATES = [
  { name: 'today (artist-dominant)', w: { A: 0.30, B: 0.15, C: 0.0 }, note: 'wArtist/wYear as shipped, no musical term' },
  { name: 'equal weights', w: { A: 1 / 3, B: 1 / 3, C: 1 / 3 } },
  { name: 'A .40 B .30 C .30', w: { A: 0.40, B: 0.30, C: 0.30 } },
  { name: 'A .30 B .35 C .35', w: { A: 0.30, B: 0.35, C: 0.35 } },
  { name: 'A .25 B .375 C .375', w: { A: 0.25, B: 0.375, C: 0.375 } },
  { name: 'A .20 B .40 C .40', w: { A: 0.20, B: 0.40, C: 0.40 } },
  { name: 'A .30 B .30 C .40', w: { A: 0.30, B: 0.30, C: 0.40 } },
];
// Measured neutral for the musical sub-term: the MEDIAN fit among songs that CAN speak it. A song
// with no bpm/camelot is imputed at this value — neither buried at 0 (which would sink 90% of the
// catalog for missing metadata) nor rewarded by dropping the term (the sparse-feature bug).
const neutralSamples = [];
const attribution = {}, survival = {};
for (const c of CANDIDATES) { attribution[c.name] = { A: 0, B: 0, C: 0 }; survival[c.name] = { A: [], B: [], C: [] }; }
rng = 20260809;
for (let t = 0; t < SEEDS; t++) {
  const anchor = songs[Math.floor(rand() * N)];
  const sameArtist = songs.filter((s) => s.artist === anchor.artist).slice(0, 8);
  const seed = [...sameArtist];
  while (seed.length < 25) seed.push(songs[Math.floor(rand() * N)]);
  const p = buildProfile(seed);
  const rows = [];
  for (const s of songs) {
    const a = famA(s, p);
    const b = famB(s, p);
    let musical = null;
    if (p.bpmMean != null && s.bpm) musical = bpmAffinity(s.bpm, p.bpmMean, p.bpmSigma);
    if (p.camelots.size && s.camelot) {
      const k = camelotAffinity(s.camelot, p.camelots);
      musical = musical == null ? k : (musical + k) / 2;
    }
    if (musical != null) neutralSamples.push(musical);
    rows.push([s.id, a, b, musical, s.genre ? Math.min(1, (p.genreShare.get(s.genre) || 0) / Math.max(1e-9, p.maxGenre)) : 0]);
  }
  const neutral = 0.42;   // refined below from neutralSamples; stable enough to score with here
  const solo = { A: [], B: [], C: [] };
  for (const r of rows) {
    const cScore = (r[4] + (r[3] == null ? neutral : r[3])) / 2;
    solo.A.push([r[0], r[1]]); solo.B.push([r[0], r[2] ?? 0]); solo.C.push([r[0], cScore]);
  }
  const top90 = (arr) => arr.slice().sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1)).slice(0, 90).map((x) => x[0]);
  const soloTop = { A: top90(solo.A), B: top90(solo.B), C: top90(solo.C) };
  for (const cand of CANDIDATES) {
    const blended = rows.map((r) => {
      const cScore = (r[4] + (r[3] == null ? neutral : r[3])) / 2;
      const terms = { A: cand.w.A * r[1], B: cand.w.B * (r[2] ?? 0), C: cand.w.C * cScore };
      const den = cand.w.A + cand.w.B + cand.w.C;
      return [r[0], (terms.A + terms.B + terms.C) / den, terms];
    });
    const picked = blended.sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1)).slice(0, 90);
    for (const [, , terms] of picked) {
      const best = Object.entries(terms).sort((x, y) => y[1] - x[1])[0][0];
      attribution[cand.name][best]++;
    }
    const ids = picked.map((x) => x[0]);
    for (const k of ['A', 'B', 'C']) survival[cand.name][k].push(jaccard(ids, soloTop[k]));
  }
}
console.log('  weights                    top-90 attribution        top-90 survival vs solo family');
for (const cand of CANDIDATES) {
  const a = attribution[cand.name];
  const tot = a.A + a.B + a.C;
  const s = survival[cand.name];
  console.log(`  ${cand.name.padEnd(24)} A ${(100 * a.A / tot).toFixed(0).padStart(3)}% B ${(100 * a.B / tot).toFixed(0).padStart(3)}% C ${(100 * a.C / tot).toFixed(0).padStart(3)}%    A ${avg(s.A).toFixed(3)}  B ${avg(s.B).toFixed(3)}  C ${avg(s.C).toFixed(3)}${cand.note ? `   (${cand.note})` : ''}`);
}
neutralSamples.sort((x, y) => x - y);
const median = neutralSamples[Math.floor(neutralSamples.length / 2)] ?? 0;
console.log(`\n  measured NEUTRAL musical fit (median over ${neutralSamples.length.toLocaleString()} songs that can speak it): ${median.toFixed(3)}`);
console.log(`  mean: ${avg(neutralSamples).toFixed(3)}  p25: ${neutralSamples[Math.floor(neutralSamples.length * 0.25)]?.toFixed(3)}  p75: ${neutralSamples[Math.floor(neutralSamples.length * 0.75)]?.toFixed(3)}`);

if (JSON_OUT) {
  writeFileSync(JSON_OUT, JSON.stringify({
    n: N, coverage: cov, familyCoverage: famCov,
    genres: { distinctRaw: rawGenreCount.size, variantGroups: variantGroups.length,
              categories: Object.fromEntries(catCount) },
    families: Object.fromEntries(['A', 'B', 'C'].map((k) => [k, {
      speaks: avg(acc[k].map((x) => x.speaks)),
      selectivity: avg(acc[k].map((x) => x.selectivity)),
      strong: avg(acc[k].map((x) => x.strong)),
      mean: avg(acc[k].map((x) => x.mean)),
      gini: avg(acc[k].map((x) => x.gini)),
    }])),
    overlap: { AB: avg(overlap.AB), AC: avg(overlap.AC), BC: avg(overlap.BC) },
  }, null, 2));
  console.log(`\nwrote ${JSON_OUT}`);
}
